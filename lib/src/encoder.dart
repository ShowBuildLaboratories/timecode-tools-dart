/// A minimal biphase-mark LTC synthesizer for tests and demos.
///
/// Produces PCM16 little-endian mono audio that `LtcDecoder` can decode.
/// It is a testing aid, not a full timecode generator: user bits and
/// polarity-correction bits are left at zero.
library;

import 'dart:typed_data';

import 'native/core.dart';

/// Synthesizes biphase-mark-encoded PCM16 little-endian mono audio for
/// [frameCount] consecutive SMPTE LTC frames starting at the given
/// timecode. A short preamble and postamble of filler bit-cells are added
/// so the very first and very last real bits have the leading/trailing
/// signal transitions a real decoder needs to measure their intervals —
/// exactly like a real LTC feed, which is never a bare single frame with no
/// surrounding signal.
Uint8List encodeLtcSequence({
  required int sampleRate,
  required int fps,
  required int startHours,
  required int startMinutes,
  required int startSeconds,
  required int startFrames,
  required int frameCount,
  bool dropFrame = false,
  int amplitude = 20000,
  int preambleBit = 1,
}) {
  final samples = nativeEncodeLtc(
    sampleRate: sampleRate,
    fps: fps,
    dropFrame: dropFrame,
    hours: startHours,
    minutes: startMinutes,
    seconds: startSeconds,
    frames: startFrames,
    frameCount: frameCount,
    amplitude: amplitude,
    preambleBit: preambleBit,
  );
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.view(bytes.buffer);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}
