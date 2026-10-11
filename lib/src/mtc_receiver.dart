part of 'receiver.dart';

/// Reads MTC (MIDI timecode) from a stream of raw MIDI bytes.
///
/// Understands quarter-frame messages (`F1 0nnn dddd`) and full-frame
/// SysEx messages (`F0 7F <device> 01 01 hh mm ss ff F7`). Everything else
/// in the stream (notes, clock, other SysEx, real-time bytes) is skipped.
///
/// ```dart
/// final rx = MtcReceiver();
/// rx.attach(midiStream); // Stream<MidiChunk>
/// rx.frames.listen((tc) => print(tc));
/// rx.events.listen((e) => print(e));
/// await rx.waitFor(Timecode.parse('01:00:10:00'));
/// await rx.detach();
/// ```
///
/// Eight quarter frames, sent over two frames, carry the frame that began at
/// the first of them. Readings come once per frame: at piece 7, the set's
/// second frame (began at piece 4); at piece 3 of the next set, the frame
/// after that (began at its piece 0), if the pieces so far agree with it.
/// The signal locks once two complete sets in a row were two frames apart.
///
/// A full-frame message (a locate) ends any chase ([StateEventType.lost] if
/// locked) and is reported as a [StateEventType.jump], with [current] set to
/// the new position.
///
/// The frame rate comes from the messages (24, 25, 29.97 drop-frame, 30)
/// unless [frameRate] fixes it.
class MtcReceiver extends _ReceiverBase<MidiChunk> {
  MtcReceiver({
    super.frameRate = FrameRate.auto,
    super.offsetFrames = 0,
    super.lostAfter = const Duration(milliseconds: 300),
    super.backpressure = Backpressure.latest,
    super.now,
  }) {
    _native = NativeReceiver.mtc(
      frameRate: frameRate,
      offsetFrames: offsetFrames,
      lostAfter: lostAfter,
    );
  }

  /// Complete, in-order quarter-frame sets needed before [isLocked].
  static const int lockSets = 2;

  @override
  late final NativeReceiver _native;

  @override
  void _onChunk(MidiChunk chunk) {
    final at = chunk.timestamp ?? _now();
    _dispatch(_native.pushMidi(chunk.bytes, at.inMicroseconds * 1000));
  }
}
