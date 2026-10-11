// The dart:ffi side of the package: thin wrappers around the handles of the
// timecode-tools Rust core (see native/include/timecode_tools.h).
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ffi/bindings.g.dart' as tt;
import '../timecode.dart';
import 'types.dart';

export 'types.dart';

/// The version of the native core, e.g. `0.1.0`.
String nativeCoreVersion() => tt.tt_version().cast<Utf8>().toDartString();

int _rateCode(FrameRate rate) => switch (rate) {
  FrameRate.auto => tt.TT_RATE_NONE,
  FrameRate.fps24 => tt.TT_RATE_24,
  FrameRate.fps25 => tt.TT_RATE_25,
  FrameRate.fps2997Drop => tt.TT_RATE_2997_DROP,
  FrameRate.fps30 => tt.TT_RATE_30,
};

FrameRate? _rateOf(int code) => switch (code) {
  tt.TT_RATE_24 => FrameRate.fps24,
  tt.TT_RATE_25 => FrameRate.fps25,
  tt.TT_RATE_2997_DROP => FrameRate.fps2997Drop,
  tt.TT_RATE_30 => FrameRate.fps30,
  _ => null,
};

Timecode _timecode(tt.TtTimecode t) => Timecode(
  t.hours,
  t.minutes,
  t.seconds,
  t.frames,
  dropFrame: t.drop_frame != 0,
  frameRate: _rateOf(t.frame_rate),
  // Rounded up to the microsecond, so that the position at this
  // timestamp is never before the frame it belongs to.
  timestamp: t.timestamp_ns < 0
      ? null
      : Duration(microseconds: (t.timestamp_ns + 999) ~/ 1000),
);

int _check(int code) {
  if (code >= 0) return code;
  throw switch (code) {
    tt.TT_ERR_ARGUMENT => ArgumentError('Invalid input for the native core'),
    tt.TT_ERR_NULL => StateError('Native handle missing'),
    _ => StateError('timecode-tools native core failed ($code)'),
  };
}

final _receiverFinalizer = NativeFinalizer(
  tt.addresses.tt_receiver_free.cast(),
);
final _decoderFinalizer = NativeFinalizer(tt.addresses.tt_decoder_free.cast());
final _clockFinalizer = NativeFinalizer(tt.addresses.tt_clock_free.cast());

/// A native receiver (LTC or MTC) with the lock / jump / loss rules.
final class NativeReceiver implements Finalizable {
  NativeReceiver.ltc({
    required FrameRate frameRate,
    required int offsetFrames,
    required Duration lostAfter,
    required int channel,
  }) : _handle = _create(true, frameRate, offsetFrames, lostAfter, channel) {
    _receiverFinalizer.attach(this, _handle.cast(), detach: this);
  }

  NativeReceiver.mtc({
    required FrameRate frameRate,
    required int offsetFrames,
    required Duration lostAfter,
  }) : _handle = _create(false, frameRate, offsetFrames, lostAfter, 1) {
    _receiverFinalizer.attach(this, _handle.cast(), detach: this);
  }

  static Pointer<tt.TtReceiver> _create(
    bool ltc,
    FrameRate frameRate,
    int offsetFrames,
    Duration lostAfter,
    int channel,
  ) {
    final options = calloc<tt.TtReceiverOptions>();
    try {
      options.ref
        ..frame_rate = _rateCode(frameRate)
        ..channel = channel
        ..offset_frames = offsetFrames
        ..lost_after_ns = lostAfter.inMicroseconds * 1000;
      final handle = ltc
          ? tt.tt_receiver_new_ltc(options)
          : tt.tt_receiver_new_mtc(options);
      if (handle == nullptr) {
        throw ArgumentError('Invalid receiver options');
      }
      return handle;
    } finally {
      calloc.free(options);
    }
  }

  Pointer<tt.TtReceiver> _handle;

  /// Frees the handle now. Later calls report nothing.
  void dispose() {
    if (_handle == nullptr) return;
    _receiverFinalizer.detach(this);
    tt.tt_receiver_free(_handle);
    _handle = nullptr;
  }

  bool get isDisposed => _handle == nullptr;

  /// Interleaved PCM16. `null` when the selected channel is not in the
  /// input (the chunk is skipped).
  List<NativeEvent>? pushPcm(
    Int16List samples,
    int sampleRate,
    int channels,
    int timestampNs,
  ) {
    if (_handle == nullptr) return const [];
    final n = tt.tt_receiver_push_pcm_i16(
      _handle,
      samples.address,
      samples.length,
      sampleRate,
      channels,
      timestampNs,
    );
    if (n == tt.TT_ERR_CHANNEL) return null;
    return _events(_check(n));
  }

  List<NativeEvent> pushMidi(Uint8List bytes, int timestampNs) {
    if (_handle == nullptr) return const [];
    final n = tt.tt_receiver_push_midi(
      _handle,
      bytes.address,
      bytes.length,
      timestampNs,
    );
    return _events(_check(n));
  }

  List<NativeEvent> signalLost() {
    if (_handle == nullptr) return const [];
    return _events(_check(tt.tt_receiver_signal_lost(_handle)));
  }

  List<NativeEvent> _events(int count) {
    if (count == 0) return const [];
    final p = tt.tt_receiver_events(_handle);
    return List.generate(count, (i) {
      final e = p[i];
      final kind = switch (e.kind) {
        tt.TT_EVENT_LOCK => NativeEventKind.lock,
        tt.TT_EVENT_FRAME => NativeEventKind.frame,
        tt.TT_EVENT_JUMP => NativeEventKind.jump,
        _ => NativeEventKind.lost,
      };
      return NativeEvent(
        kind,
        timecode: kind == NativeEventKind.lost ? null : _timecode(e.timecode),
        previous: e.has_previous != 0 ? e.previous : null,
        channel: e.timecode.channel > 0 ? e.timecode.channel : null,
      );
    }, growable: false);
  }

  bool get locked => _handle != nullptr && tt.tt_receiver_locked(_handle) == 1;

  FrameRate? get detectedRate => _handle == nullptr
      ? null
      : _rateOf(tt.tt_receiver_detected_rate(_handle));

  Timecode? get current {
    if (_handle == nullptr) return null;
    final out = calloc<tt.TtTimecode>();
    try {
      return tt.tt_receiver_current(_handle, out) == 1
          ? _timecode(out.ref)
          : null;
    } finally {
      calloc.free(out);
    }
  }

  double get level => _handle == nullptr ? 0 : tt.tt_receiver_level(_handle);

  set offsetFrames(int value) {
    if (_handle != nullptr) tt.tt_receiver_set_offset_frames(_handle, value);
  }

  double? framesAt(int timestampNs) {
    if (_handle == nullptr) return null;
    final out = calloc<Double>();
    try {
      return tt.tt_receiver_frames_at(_handle, timestampNs, out) == 1
          ? out.value
          : null;
    } finally {
      calloc.free(out);
    }
  }
}

/// The native low-level LTC decoder.
final class NativeDecoder implements Finalizable {
  NativeDecoder(int sampleRate) : _handle = tt.tt_decoder_new(sampleRate) {
    if (_handle == nullptr) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'must be positive');
    }
    _decoderFinalizer.attach(this, _handle.cast(), detach: this);
  }

  final Pointer<tt.TtDecoder> _handle;

  List<NativeLtcFrame> push(Int16List samples) => _frames(
    _check(tt.tt_decoder_push(_handle, samples.address, samples.length)),
  );

  List<NativeLtcFrame> pushBytes(Uint8List bytes) => _frames(
    _check(tt.tt_decoder_push_bytes(_handle, bytes.address, bytes.length)),
  );

  List<NativeLtcFrame> _frames(int count) {
    if (count == 0) return const [];
    final p = tt.tt_decoder_frames(_handle);
    return List.generate(count, (i) {
      final f = p[i];
      return NativeLtcFrame(
        hours: f.hours,
        minutes: f.minutes,
        seconds: f.seconds,
        frames: f.frames,
        dropFrame: f.drop_frame != 0,
        locked: f.locked != 0,
        estimatedFps: f.estimated_fps < 0 ? null : f.estimated_fps,
        sampleIndex: f.sample_index,
      );
    }, growable: false);
  }

  bool get locked => tt.tt_decoder_locked(_handle) == 1;

  int? get estimatedFps {
    final fps = tt.tt_decoder_estimated_fps(_handle);
    return fps < 0 ? null : fps;
  }

  double get signalLevel => tt.tt_decoder_signal_level(_handle);

  int get sampleIndex => tt.tt_decoder_sample_index(_handle);
}

/// The native regression clock.
final class NativeClock implements Finalizable {
  NativeClock(NativeClockConfig c) : _handle = _create(c) {
    _clockFinalizer.attach(this, _handle.cast(), detach: this);
  }

  static Pointer<tt.TtClock> _create(NativeClockConfig c) {
    final config = calloc<tt.TtClockConfig>();
    try {
      config.ref
        ..max_age_seconds = c.maxAgeSeconds
        ..stale_after_ns = c.staleAfterNs
        ..max_points = c.maxPoints
        ..min_points_for_fit = c.minPointsForFit
        ..min_points_usable = c.minPointsUsable
        ..min_span_seconds = c.minSpanSeconds
        ..max_residual_frames = c.maxResidualFrames
        ..jump_reset_frames = c.jumpResetFrames;
      final handle = tt.tt_clock_new(config);
      if (handle == nullptr) throw ArgumentError('Invalid clock settings');
      return handle;
    } finally {
      calloc.free(config);
    }
  }

  final Pointer<tt.TtClock> _handle;

  void addObservation(
    double sampleTime,
    double tcFrames,
    int framesPerDay,
    int nowNs,
  ) => tt.tt_clock_add_observation(
    _handle,
    sampleTime,
    tcFrames,
    framesPerDay,
    nowNs,
  );

  void noteHostTime(double sampleTime, int hostMicros) =>
      tt.tt_clock_note_host_time(_handle, sampleTime, hostMicros);

  NativeClockState state(int nowNs) {
    final out = calloc<tt.TtClockState>();
    try {
      tt.tt_clock_state(_handle, nowNs, out);
      final s = out.ref;
      return NativeClockState(
        hasFit: s.has_fit != 0,
        usable: s.usable != 0,
        b: s.b,
        residual: s.residual,
        nominalFps: s.nominal_fps < 0 ? null : s.nominal_fps,
        observationCount: s.observation_count,
        windowSpanSeconds: s.window_span_seconds,
      );
    } finally {
      calloc.free(out);
    }
  }

  double? tcAtSampleTime(double sampleTime, int nowNs) {
    final out = calloc<Double>();
    try {
      return tt.tt_clock_tc_at_sample_time(_handle, sampleTime, nowNs, out) == 1
          ? out.value
          : null;
    } finally {
      calloc.free(out);
    }
  }

  double? tcAtHostMicros(int hostMicros, int nowNs) {
    final out = calloc<Double>();
    try {
      return tt.tt_clock_tc_at_host_micros(_handle, hostMicros, nowNs, out) == 1
          ? out.value
          : null;
    } finally {
      calloc.free(out);
    }
  }

  void reset() => tt.tt_clock_reset(_handle);

  void onSignalLost() => tt.tt_clock_on_signal_lost(_handle);
}

/// PCM16 samples of an LTC test signal from the native encoder.
Int16List nativeEncodeLtc({
  required int sampleRate,
  required int fps,
  required bool dropFrame,
  required int hours,
  required int minutes,
  required int seconds,
  required int frames,
  required int frameCount,
  required int amplitude,
  required int preambleBit,
}) {
  final s = tt.tt_encode_ltc(
    sampleRate,
    fps,
    dropFrame ? 1 : 0,
    hours,
    minutes,
    seconds,
    frames,
    frameCount,
    amplitude,
    preambleBit,
  );
  if (s.data == nullptr) {
    if (frameCount == 0) return Int16List(0);
    throw ArgumentError('Invalid LTC encoder settings');
  }
  try {
    return Int16List.fromList(s.data.asTypedList(s.len));
  } finally {
    tt.tt_samples_free(s);
  }
}
