// Platforms without dart:ffi (the web): the native core is not available.
import 'dart:typed_data';

import '../timecode.dart';
import 'types.dart';

export 'types.dart';

Never _unsupported() => throw UnsupportedError(
  'timecode_tools needs dart:ffi (its decoder is native code); '
  'it is not available on this platform',
);

String nativeCoreVersion() => _unsupported();

final class NativeReceiver {
  NativeReceiver.ltc({
    required FrameRate frameRate,
    required int offsetFrames,
    required Duration lostAfter,
    required int channel,
  }) {
    _unsupported();
  }

  NativeReceiver.mtc({
    required FrameRate frameRate,
    required int offsetFrames,
    required Duration lostAfter,
  }) {
    _unsupported();
  }

  void dispose() {}
  bool get isDisposed => true;
  List<NativeEvent>? pushPcm(
    Int16List samples,
    int sampleRate,
    int channels,
    int timestampNs,
  ) => _unsupported();
  List<NativeEvent> pushMidi(Uint8List bytes, int timestampNs) =>
      _unsupported();
  List<NativeEvent> signalLost() => const [];
  bool get locked => false;
  FrameRate? get detectedRate => null;
  Timecode? get current => null;
  double get level => 0;
  set offsetFrames(int value) {}
  double? framesAt(int timestampNs) => null;
}

final class NativeDecoder {
  NativeDecoder(int sampleRate) {
    _unsupported();
  }
  List<NativeLtcFrame> push(Int16List samples) => _unsupported();
  List<NativeLtcFrame> pushBytes(Uint8List bytes) => _unsupported();
  bool get locked => _unsupported();
  int? get estimatedFps => _unsupported();
  double get signalLevel => _unsupported();
  int get sampleIndex => _unsupported();
}

final class NativeClock {
  NativeClock(NativeClockConfig c) {
    _unsupported();
  }
  void addObservation(
    double sampleTime,
    double tcFrames,
    int framesPerDay,
    int nowNs,
  ) => _unsupported();
  void noteHostTime(double sampleTime, int hostMicros) => _unsupported();
  NativeClockState state(int nowNs) => _unsupported();
  double? tcAtSampleTime(double sampleTime, int nowNs) => _unsupported();
  double? tcAtHostMicros(int hostMicros, int nowNs) => _unsupported();
  void reset() => _unsupported();
  void onSignalLost() => _unsupported();
}

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
}) => _unsupported();
