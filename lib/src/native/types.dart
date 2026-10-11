// Plain values passed between the native layer and the public classes.
import '../timecode.dart';

enum NativeEventKind { lock, frame, jump, lost }

/// One receiver event from the native core.
class NativeEvent {
  const NativeEvent(this.kind, {this.timecode, this.previous, this.channel});
  final NativeEventKind kind;

  /// lock, frame, jump: the timecode (offset applied, timestamp set).
  final Timecode? timecode;

  /// frame: the index of the reading it continues, if any.
  final int? previous;

  /// LTC: the one-based channel read.
  final int? channel;
}

/// One decoded LTC frame from the native decoder.
class NativeLtcFrame {
  const NativeLtcFrame({
    required this.hours,
    required this.minutes,
    required this.seconds,
    required this.frames,
    required this.dropFrame,
    required this.locked,
    required this.estimatedFps,
    required this.sampleIndex,
  });
  final int hours;
  final int minutes;
  final int seconds;
  final int frames;
  final bool dropFrame;
  final bool locked;
  final int? estimatedFps;
  final int sampleIndex;
}

class NativeClockConfig {
  const NativeClockConfig({
    required this.maxAgeSeconds,
    required this.staleAfterNs,
    required this.maxPoints,
    required this.minPointsForFit,
    required this.minPointsUsable,
    required this.minSpanSeconds,
    required this.maxResidualFrames,
    required this.jumpResetFrames,
  });
  final double maxAgeSeconds;
  final int staleAfterNs;
  final int maxPoints;
  final int minPointsForFit;
  final int minPointsUsable;
  final double minSpanSeconds;
  final double maxResidualFrames;
  final double jumpResetFrames;
}

class NativeClockState {
  const NativeClockState({
    required this.hasFit,
    required this.usable,
    required this.b,
    required this.residual,
    required this.nominalFps,
    required this.observationCount,
    required this.windowSpanSeconds,
  });
  final bool hasFit;
  final bool usable;
  final double b;
  final double residual;
  final int? nominalFps;
  final int observationCount;
  final double windowSpanSeconds;
}
