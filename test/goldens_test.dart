// Replays the shared golden files (test/goldens, copied from the Rust core
// repository; see tool/sync_core.dart) through the public Dart API and
// requires the same answers.
//
// - receiver/*.json: LTC and MTC inputs, chunk by chunk, with the frames,
//   events and framesAt value after each chunk, the waitFor results and the
//   final state.
// - decoder-clock/*.json: LtcDecoder frames for generated and raw PCM, and
//   LtcClockModel snapshots and probes for scripted observations.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:timecode_tools/timecode_tools.dart';

/// Timestamps: the core works in nanoseconds and the Dart API in
/// microseconds (rounded up); the goldens allow 3 us either way.
const _tsTolerance = 4;

List<File> _files(String dir) =>
    Directory('test/goldens/$dir').listSync().whereType<File>().where((f) {
      return f.path.endsWith('.json');
    }).toList()..sort((a, b) => a.path.compareTo(b.path));

Map<String, Object?> _load(File f) =>
    jsonDecode(f.readAsStringSync()) as Map<String, Object?>;

FrameRate _rate(Object? name) => switch (name) {
  '24' => FrameRate.fps24,
  '25' => FrameRate.fps25,
  '29.97df' => FrameRate.fps2997Drop,
  '30' => FrameRate.fps30,
  null => FrameRate.auto,
  _ => throw ArgumentError('unknown rate $name'),
};

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

Uint8List _bytes(Int16List pcm) {
  final out = Uint8List(pcm.length * 2);
  final data = ByteData.view(out.buffer);
  for (var i = 0; i < pcm.length; i++) {
    data.setInt16(i * 2, pcm[i], Endian.little);
  }
  return out;
}

Int16List _encode({
  required int sampleRate,
  required FrameRate rate,
  required Timecode start,
  required int frameCount,
  int amplitude = 20000,
  int preambleBit = 1,
}) {
  final bytes = encodeLtcSequence(
    sampleRate: sampleRate,
    fps: rate.nominal,
    dropFrame: rate.dropFrame,
    startHours: start.hours,
    startMinutes: start.minutes,
    startSeconds: start.seconds,
    startFrames: start.frames,
    frameCount: frameCount,
    amplitude: amplitude,
    preambleBit: preambleBit,
  );
  return Int16List.view(bytes.buffer, 0, bytes.length ~/ 2);
}

/// The LTC input of a receiver golden, cut into timestamped chunks.
List<PcmChunk> _ltcInput(Map<String, Object?> input) {
  final sampleRate = input['sample_rate']! as int;
  final rate = _rate(input['rate']);
  final channels = input['channels']! as int;
  final ltcChannel = input['ltc_channel']! as int;
  final chunk = input['chunk']! as int;
  final t0 = input['t0_us']! as int;
  final mono = <int>[];
  for (final seg in (input['segments']! as List).cast<Map>()) {
    if (seg.containsKey('silence')) {
      mono.addAll(List.filled(seg['silence'] as int, 0));
    } else {
      mono.addAll(
        _encode(
          sampleRate: sampleRate,
          rate: rate,
          start: Timecode.parse(seg['start'] as String),
          frameCount: seg['frame_count'] as int,
        ),
      );
    }
  }
  final samples = Int16List(mono.length * channels);
  for (var i = 0; i < mono.length; i++) {
    for (var c = 0; c < channels; c++) {
      // Other channels carry a sawtooth.
      samples[i * channels + c] = c + 1 == ltcChannel
          ? mono[i]
          : (i * 37) % 4000 - 2000;
    }
  }
  expect(samples.length, input['sample_count'], reason: 'sample_count');
  final per = chunk * channels;
  return [
    for (var i = 0; i < samples.length; i += per)
      PcmChunk(
        samples: Int16List.sublistView(
          samples,
          i,
          i + per < samples.length ? i + per : samples.length,
        ),
        sampleRate: sampleRate,
        channels: channels,
        timestamp: Duration(
          microseconds: t0 + (i ~/ channels * 1e6 / sampleRate).round(),
        ),
      ),
  ];
}

List<MidiChunk> _mtcInput(Map<String, Object?> input) => [
  for (final c in (input['chunks']! as List).cast<Map>())
    MidiChunk(
      _hex(c['bytes'] as String),
      timestamp: Duration(microseconds: c['t_us'] as int),
    ),
];

void _expectTimecode(Timecode got, Object? want, String context) {
  want as Map;
  expect(got.toString(), want['tc'], reason: '$context: timecode');
  final ts = want['ts_us'] as int?;
  if (ts == null) {
    expect(got.timestamp, isNull, reason: '$context: timestamp');
  } else {
    expect(
      got.timestamp!.inMicroseconds,
      closeTo(ts, _tsTolerance),
      reason: '$context: timestamp',
    );
  }
}

Future<void> _replayReceiver(Map<String, Object?> golden) async {
  final options = golden['options']! as Map;
  final input = golden['input']! as Map<String, Object?>;
  if (golden['kind'] == 'ltc') {
    await _run(
      golden,
      LtcReceiver(
        frameRate: _rate(options['frame_rate']),
        offsetFrames: (options['offset_frames'] as int?) ?? 0,
        channel: (options['channel'] as int?) ?? 1,
      ),
      _ltcInput(input),
    );
  } else {
    await _run(
      golden,
      MtcReceiver(
        frameRate: _rate(options['frame_rate']),
        offsetFrames: (options['offset_frames'] as int?) ?? 0,
      ),
      _mtcInput(input),
    );
  }
}

Future<void> _run<T>(
  Map<String, Object?> golden,
  TimecodeReceiver<T> rx,
  List<T> chunks,
) async {
  final name = golden['name'];
  final steps = (golden['steps']! as List).cast<Map>();
  expect(chunks.length, steps.length, reason: '$name: chunk count');

  final frames = <Timecode>[];
  final events = <String>[];
  rx.frames.listen(frames.add);
  rx.events.listen((e) => events.add(e.type.name));
  final waits = (golden['wait_for']! as Map).cast<String, Object?>();
  final resolved = <String, (int, Timecode)>{};
  var index = 0;
  for (final target in waits.keys) {
    unawaited(
      rx
          .waitFor(Timecode.parse(target))
          .then((tc) => resolved[target] = (index, tc), onError: (_) {}),
    );
  }
  final controller = StreamController<T>();
  rx.attach(controller.stream);
  for (index = 0; index < chunks.length; index++) {
    controller.add(chunks[index]);
    await Future<void>.delayed(Duration.zero);
    final want = steps[index];
    final context = '$name chunk $index';
    final wantFrames = want['frames'] as List;
    expect(frames.map((f) => f.toString()).toList(), [
      for (final f in wantFrames) (f as Map)['tc'],
    ], reason: '$context: frames');
    for (var i = 0; i < frames.length; i++) {
      _expectTimecode(frames[i], wantFrames[i], '$context frame $i');
    }
    expect(events, want['events'], reason: '$context: events');
    final at = want['frames_at'] as Map;
    final got = rx.framesAt(Duration(microseconds: at['t_us'] as int));
    final value = at['value'] as num?;
    if (value == null) {
      expect(got, isNull, reason: '$context: framesAt');
    } else {
      expect(got, closeTo(value, 1e-6), reason: '$context: framesAt');
    }
    frames.clear();
    events.clear();
  }
  for (final MapEntry(key: target, value: want) in waits.entries) {
    final got = resolved[target];
    if (want == null) {
      expect(got, isNull, reason: '$name waitFor $target');
      continue;
    }
    want as Map;
    expect(got, isNotNull, reason: '$name waitFor $target');
    expect(got!.$1, want['chunk'], reason: '$name waitFor $target: chunk');
    _expectTimecode(got.$2, want, '$name waitFor $target');
  }
  expect(rx.isLocked, golden['final_locked'], reason: '$name: final_locked');
  expect(
    rx.detectedRate?.label,
    golden['final_detected_rate'],
    reason: '$name: final_detected_rate',
  );
  expect(
    rx.current?.toString(),
    golden['final_current'],
    reason: '$name: final_current',
  );
  await rx.close();
  await controller.close();
}

void _replayDecoder(Map<String, Object?> golden) {
  final name = golden['name'];
  final sampleRate = golden['sample_rate']! as int;
  final Int16List pcm;
  switch (golden['kind']) {
    case 'encoded':
      final enc = golden['encoder']! as Map;
      final fps = enc['fps'] as int;
      final drop = enc['drop_frame'] as bool;
      final rate = drop
          ? FrameRate.fps2997Drop
          : FrameRate.fromDecoded(fps: fps, dropFrame: false)!;
      pcm = _encode(
        sampleRate: sampleRate,
        rate: rate,
        start: Timecode(
          enc['start_hours'] as int,
          enc['start_minutes'] as int,
          enc['start_seconds'] as int,
          enc['start_frames'] as int,
        ),
        frameCount: enc['frame_count'] as int,
        amplitude: enc['amplitude'] as int,
        preambleBit: enc['preamble_bit'] as int,
      );
      if (enc['invert'] == true) {
        for (var i = 0; i < pcm.length; i++) {
          pcm[i] = -pcm[i];
        }
      }
    case 'silence':
      pcm = Int16List(golden['sample_count']! as int);
    case 'white_noise':
      pcm = Int16List.fromList((golden['pcm_i16']! as List).cast<int>());
    default:
      throw ArgumentError('$name: unknown kind ${golden['kind']}');
  }
  final bytes = _bytes(pcm);
  expect(
    sha256.convert(bytes).toString(),
    golden['pcm_sha256'],
    reason: '$name: generated PCM',
  );
  if (golden['pcm_i16'] case final List samples) {
    expect(pcm, samples, reason: '$name: samples');
  }

  void check(LtcDecoder decoder, List<LtcFrame> frames, String how) {
    final want = (golden['frames']! as List).cast<Map>();
    expect(frames.length, want.length, reason: '$name ($how): frame count');
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      final w = want[i];
      final context = '$name ($how) frame $i';
      expect(f.formatted, w['timecode'], reason: '$context: timecode');
      expect(f.sampleIndex, w['sample_index'], reason: '$context: sample');
      expect(f.locked, w['locked'], reason: '$context: locked');
      expect(f.estimatedFps, w['estimated_fps'], reason: '$context: fps');
    }
    expect(decoder.locked, golden['final_locked'], reason: '$name: locked');
    expect(
      decoder.estimatedFps,
      golden['final_estimated_fps'],
      reason: '$name: estimatedFps',
    );
  }

  // All at once, as bytes.
  final whole = LtcDecoder(sampleRate: sampleRate);
  check(whole, whole.pushBytes(bytes), 'bytes');
  // In uneven sample chunks: the same answers.
  final chunked = LtcDecoder(sampleRate: sampleRate);
  final frames = <LtcFrame>[];
  for (var i = 0, n = 1; i < pcm.length; i += n, n = n * 7 % 1013 + 1) {
    final end = i + n < pcm.length ? i + n : pcm.length;
    frames.addAll(chunked.push(Int16List.sublistView(pcm, i, end)));
  }
  check(chunked, frames, 'chunks');
}

void _expectClose(double? got, Object? want, String context) {
  if (want == null) {
    expect(got, isNull, reason: context);
    return;
  }
  final w = (want as num).toDouble();
  final tolerance = 1e-12 * (w.abs() > 1e-9 ? w.abs() : 1e-9);
  expect(got, closeTo(w, tolerance), reason: context);
}

void _replayClock(Map<String, Object?> golden) {
  final name = golden['name'];
  final config = golden['config']! as Map;
  var nowNs = 0;
  Duration now() {
    expect(nowNs % 1000, 0, reason: '$name: now_ns must be whole microseconds');
    return Duration(microseconds: nowNs ~/ 1000);
  }

  final model = LtcClockModel(
    maxAge: Duration(
      microseconds: ((config['max_age_seconds'] as num) * 1e6).round(),
    ),
    staleAfter: Duration(
      microseconds: (config['stale_after_ns'] as int) ~/ 1000,
    ),
    maxPoints: config['max_points'] as int,
    minPointsForFit: config['min_points_for_fit'] as int,
    minPointsUsable: config['min_points_usable'] as int,
    minSpanUsableSeconds: (config['min_span_seconds'] as num).toDouble(),
    maxResidualUsableFrames: (config['max_residual_frames'] as num).toDouble(),
    jumpResetFrames: (config['jump_reset_frames'] as num).toDouble(),
    elapsedSinceStart: now,
  );
  final steps = (golden['steps']! as List).cast<Map>();
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final context = '$name step $i (${step['op']})';
    nowNs = step['now_ns'] as int;
    switch (step['op']) {
      case 'observe':
        model.addObservation(
          (step['t'] as num).toDouble(),
          (step['tc'] as num).toDouble(),
          framesPerDay: step['frames_per_day'] as int?,
        );
      case 'snapshot':
        expect(model.usable, step['usable'], reason: '$context: usable');
        expect(
          model.nominalFps,
          step['nominal_fps'],
          reason: '$context: nominalFps',
        );
        _expectClose(model.measuredFrameRate, step['b'], '$context: b');
        _expectClose(model.residualRms, step['residual'], '$context: residual');
      case 'probe':
        _expectClose(
          model.tcAtSampleTime((step['t'] as num).toDouble()),
          step['value'],
          '$context: value',
        );
      default:
        fail('$context: unknown op');
    }
  }
}

void main() {
  group('receiver goldens', () {
    for (final f in _files('receiver')) {
      final golden = _load(f);
      test('${golden['name']}', () => _replayReceiver(golden));
    }
  });

  group('decoder goldens', () {
    for (final f in _files('decoder-clock')) {
      if (!f.uri.pathSegments.last.startsWith('decoder_')) continue;
      final golden = _load(f);
      test('${golden['name']}', () => _replayDecoder(golden));
    }
  });

  group('clock goldens', () {
    for (final f in _files('decoder-clock')) {
      if (!f.uri.pathSegments.last.startsWith('clock_')) continue;
      final golden = _load(f);
      test('${golden['name']}', () => _replayClock(golden));
    }
  });
}
