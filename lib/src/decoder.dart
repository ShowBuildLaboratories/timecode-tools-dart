/// The low-level streaming SMPTE LTC (linear timecode) decoder.
///
/// Decoding runs in the timecode-tools Rust core (through `dart:ffi`).
///
/// LTC encodes 80 bits per frame using biphase mark code (BMC): a signal
/// transition always occurs at the start of every bit cell, and an
/// additional one at the midpoint if, and only if, the bit is `1`. The
/// decoder looks only at the spacing between zero crossings, so it does not
/// depend on signal polarity. It keeps an adaptive estimate of the bit-cell
/// period (bootstrapped from both half- and full-cell intervals, so it
/// starts correctly wherever capture begins), feeds decoded bits into an
/// 80-bit window, and parses a frame each time the 16-bit sync word
/// (`0011111111111101`) completes.
library;

import 'dart:typed_data';

import 'native/core.dart';

/// One decoded SMPTE LTC frame.
class LtcFrame {
  const LtcFrame({
    required this.hours,
    required this.minutes,
    required this.seconds,
    required this.frames,
    required this.dropFrame,
    this.sampleIndex = 0,
    this.locked = false,
    this.estimatedFps,
  });

  final int hours;
  final int minutes;
  final int seconds;
  final int frames;
  final bool dropFrame;

  /// Cumulative count of PCM samples fed to the decoder (across every
  /// [LtcDecoder.push] call since the decoder was constructed) at the point
  /// this frame's sync word finished. This is the decoder's own sample
  /// clock — it advances only with real audio samples, so it is immune to
  /// host callback/chunk-delivery jitter. [LtcClockModel] divides
  /// this by the sample rate to get the regression's time axis; see its
  /// docs for why that matters.
  ///
  /// Deliberately excluded from [==]/[hashCode] so tests (and any other
  /// code) that compare frames by decoded timecode value alone are
  /// unaffected by exactly which sample the sync word happened to land on.
  final int sampleIndex;

  /// [LtcDecoder.locked] right after this frame was decoded. Not part of
  /// [==]/[hashCode].
  final bool locked;

  /// [LtcDecoder.estimatedFps] right after this frame was decoded. Not part
  /// of [==]/[hashCode].
  final int? estimatedFps;

  /// `hh:mm:ss:ff` for non-drop-frame timecode, `hh:mm:ss;ff` for
  /// drop-frame, matching standard SMPTE display convention.
  String get formatted {
    String two(int value) => value.toString().padLeft(2, '0');
    final frameSeparator = dropFrame ? ';' : ':';
    return '${two(hours)}:${two(minutes)}:${two(seconds)}'
        '$frameSeparator${two(frames)}';
  }

  @override
  String toString() => formatted;

  @override
  bool operator ==(Object other) =>
      other is LtcFrame &&
      other.hours == hours &&
      other.minutes == minutes &&
      other.seconds == seconds &&
      other.frames == frames &&
      other.dropFrame == dropFrame;

  @override
  int get hashCode => Object.hash(hours, minutes, seconds, frames, dropFrame);
}

/// Streaming biphase-mark SMPTE LTC decoder (the low-level interface).
///
/// Push mono PCM16 samples with [push] (or little-endian bytes with
/// [pushBytes]); each call returns the frames whose sync word completed
/// inside that chunk. State (partial samples across a byte boundary,
/// pending half-cell, bit shift register, lock state) is carried between
/// calls, so chunks may be arbitrarily sized and unevenly split.
///
/// For a higher-level interface with frame-rate selection, offset, status
/// and a smoothed clock, see `LtcReceiver`.
class LtcDecoder {
  LtcDecoder({required this.sampleRate}) : _native = NativeDecoder(sampleRate);

  /// The sample rate of the PCM audio passed to [push], in Hz.
  final int sampleRate;

  /// The exact 16-bit LTC sync word, in arrival (transmission) order.
  static const String syncWordBits = '0011111111111101';

  final NativeDecoder _native;
  LtcFrame? _lastFrame;

  /// Cumulative count of samples processed so far. See
  /// [LtcFrame.sampleIndex].
  int get sampleIndex => _native.sampleIndex;

  /// `true` once at least 4 consecutive frames have been decoded with
  /// contiguous timecode (each frame exactly one tick after the last).
  bool get locked => _native.locked;

  /// Recent peak `|sample|`, normalized to 0..1 against full scale.
  double get signalLevel => _native.signalLevel;

  /// Estimated frame rate (24, 25 or 30) derived from the observed bit rate
  /// and cross-checked against the largest frame-number field seen so far.
  /// `null` until enough locked signal has been seen to know — this is
  /// never guessed or defaulted.
  int? get estimatedFps => _native.estimatedFps;

  /// The drop-frame flag of the most recently decoded frame; `null` before
  /// any frame has decoded.
  bool? get lastDropFrame => _lastFrame?.dropFrame;

  /// Decodes the next chunk of mono PCM16 samples and returns the frames
  /// completed in it (empty for silence, noise, or a partial frame).
  List<LtcFrame> push(Int16List samples) => _convert(_native.push(samples));

  /// Like [push], for raw PCM16 little-endian mono bytes. An odd trailing
  /// byte is carried over to the next call. Do not mix with [push] on one
  /// decoder.
  List<LtcFrame> pushBytes(Uint8List pcm16) =>
      _convert(_native.pushBytes(pcm16));

  List<LtcFrame> _convert(List<NativeLtcFrame> frames) {
    final out = [
      for (final f in frames)
        LtcFrame(
          hours: f.hours,
          minutes: f.minutes,
          seconds: f.seconds,
          frames: f.frames,
          dropFrame: f.dropFrame,
          sampleIndex: f.sampleIndex,
          locked: f.locked,
          estimatedFps: f.estimatedFps,
        ),
    ];
    if (out.isNotEmpty) _lastFrame = out.last;
    return out;
  }
}
