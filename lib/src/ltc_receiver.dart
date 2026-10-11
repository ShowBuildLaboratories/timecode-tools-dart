part of 'receiver.dart';

/// Reads LTC from a stream of PCM audio.
///
/// ```dart
/// final rx = LtcReceiver(frameRate: FrameRate.auto, offsetFrames: 0);
/// rx.attach(pcmStream);
/// rx.frames.listen((tc) => print(tc));
/// rx.events.listen((e) => print(e));
/// await rx.waitFor(Timecode.parse('01:00:10:00'));
/// await rx.detach();
/// ```
///
/// The receiver does no audio capture itself; the app supplies
/// [PcmChunk]s from whatever capture API it uses.
class LtcReceiver extends _ReceiverBase<PcmChunk> {
  LtcReceiver({
    super.frameRate = FrameRate.auto,
    super.offsetFrames = 0,
    int channel = 1,
    super.lostAfter = const Duration(milliseconds: 300),
    super.backpressure = Backpressure.latest,
    super.now,
  }) : _channel = channel {
    _native = _create();
  }

  int _channel;

  @override
  late NativeReceiver _native;

  NativeReceiver _create() => NativeReceiver.ltc(
    frameRate: frameRate,
    offsetFrames: offsetFrames,
    lostAfter: lostAfter,
    channel: _channel,
  );

  /// Which channel (1-based) of multi-channel chunks carries LTC.
  ///
  /// Changing it starts decoding over ([StateEventType.lost] if locked).
  int get channel => _channel;
  set channel(int value) {
    if (value == _channel) return;
    _channel = value;
    if (isClosed) return;
    _lost();
    _native.dispose();
    _native = _create();
  }

  /// Recent peak input level of the LTC channel, 0..1.
  double get level => isClosed ? 0 : _native.level;

  @override
  void _onChunk(PcmChunk chunk) {
    final at = chunk.timestamp ?? _now();
    final events = _native.pushPcm(
      chunk.samples,
      chunk.sampleRate,
      chunk.channels,
      at.inMicroseconds * 1000,
    );
    // null: the selected channel is not in this chunk; it is skipped.
    if (events != null) _dispatch(events);
  }
}
