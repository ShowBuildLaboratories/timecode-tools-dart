import 'dart:async';

import 'clock.dart';
import 'midi_chunk.dart';
import 'native/core.dart';
import 'pcm_chunk.dart';
import 'timecode.dart';

part 'ltc_receiver.dart';
part 'mtc_receiver.dart';

/// The kinds of [StateEvent] (the same names as the Node.js events).
enum StateEventType {
  /// Several consecutive frames arrived in order: the timecode is trusted.
  /// The first frame on [TimecodeReceiver.frames] follows.
  lock,

  /// Nothing followed for [TimecodeReceiver.lostAfter], the stream was
  /// detached or ended, the input format changed, or (MTC) a full-frame
  /// locate stopped the chase.
  lost,

  /// While locked, the timecode moved discontinuously (confirmed by two
  /// contiguous readings; a single stray frame is ignored), or (MTC) a
  /// full-frame message set a new position.
  jump,

  /// The attached input stream finished (after a [lost], if it was locked).
  end,
}

/// A state change on [TimecodeReceiver.events].
class StateEvent {
  const StateEvent(this.type, {this.timecode, this.frameRate, this.channel});

  final StateEventType type;

  /// [StateEventType.lock]: the first followed frame. [StateEventType.jump]:
  /// the new position. Otherwise `null`.
  final Timecode? timecode;

  /// [StateEventType.lock]: the rate in use.
  final FrameRate? frameRate;

  /// [StateEventType.lock] from [LtcReceiver]: the channel read (1-based).
  final int? channel;

  @override
  String toString() => switch (type) {
    StateEventType.lock => 'lock $timecode ${frameRate?.label}',
    StateEventType.jump => 'jump $timecode',
    _ => type.name,
  };
}

/// What a paused listener of [TimecodeReceiver.frames] receives.
enum Backpressure {
  /// Keep only the newest frame while paused.
  latest,

  /// Queue every frame while paused.
  all,
}

/// The common interface of [LtcReceiver] (audio, [PcmChunk]) and
/// [MtcReceiver] (MIDI, [MidiChunk]): attach a stream of input chunks [T],
/// get [frames], [events], [waitFor] and [positionAt].
///
/// ```dart
/// Future<void> follow(TimecodeReceiver<Object?> rx) async {
///   rx.events.listen(print);
///   await for (final tc in rx.frames) {
///     print(tc);
///   }
/// }
/// ```
abstract interface class TimecodeReceiver<T> {
  /// The frame rate to use; [FrameRate.auto] takes it from the signal.
  FrameRate get frameRate;

  /// Latency compensation in frames, added to every reported timecode.
  /// Positive when the signal reaches you late (the usual case): the
  /// receiver then reports a later timecode than the one it just read.
  int get offsetFrames;
  set offsetFrames(int value);

  /// What [frames] keeps for a listener that is paused (for example an
  /// `await for` loop whose body is still running). [Backpressure.latest]
  /// (the default) keeps only the newest frame; [Backpressure.all] queues
  /// every frame. [events] always queues every event.
  Backpressure get backpressure;

  /// How long without a frame before a locked signal is
  /// [StateEventType.lost].
  Duration get lostAfter;

  /// Every frame on the followed timeline while locked (with [offsetFrames]
  /// applied and [Timecode.timestamp] set to when the frame began). Each
  /// listener gets its own subscription.
  Stream<Timecode> get frames;

  /// Lock, loss and jump events, and [StateEventType.end] when the attached
  /// input finishes. An error from the input stream is delivered as an
  /// error on this stream.
  Stream<StateEvent> get events;

  /// Whether the signal is currently locked.
  bool get isLocked;

  /// The frame rate in use ([frameRate], or the detected one); `null` until
  /// known.
  FrameRate? get detectedRate;

  /// The most recent frame on [frames], or the position of an MTC locate.
  Timecode? get current;

  /// Whether a stream is attached.
  bool get isAttached;

  /// Whether [close] has been called.
  bool get isClosed;

  /// Starts reading [input]. Throws [StateError] if a stream is already
  /// attached ([detach] it first).
  void attach(Stream<T> input);

  /// Stops reading (the input stream is cancelled). Reports
  /// [StateEventType.lost] if the signal was locked. Pending [waitFor] calls
  /// stay pending; attach another stream to continue.
  Future<void> detach();

  /// Completes when the received timecode (with [offsetFrames]) passes
  /// [target] during normal playback: the first frame at or after [target]
  /// that directly continues a frame before it. A jump over (or onto)
  /// [target] does not count. Fails with a [StateError] if the receiver is
  /// closed first.
  Future<Timecode> waitFor(Timecode target);

  /// The timecode at [timestamp] (same clock as the chunk timestamps),
  /// interpolated or extrapolated from the recent signal, with
  /// [offsetFrames] applied. `null` until the signal is locked long enough
  /// to fit a clock, or after it is lost.
  Timecode? positionAt(Duration timestamp);

  /// [positionAt] as a fractional frame count since 00:00:00:00 (not
  /// wrapped at midnight).
  double? framesAt(Duration timestamp);

  /// Detaches, closes [frames] and [events], and fails pending [waitFor]
  /// calls with a [StateError]. The receiver cannot be used again.
  Future<void> close();
}

/// Shared implementation of [TimecodeReceiver]. Decoding and the lock,
/// jump and loss rules run in the timecode-tools Rust core; this class
/// turns what the core reports into streams, and implements [waitFor] and
/// the stopped-input watchdog.
abstract class _ReceiverBase<T> implements TimecodeReceiver<T> {
  _ReceiverBase({
    required this.frameRate,
    required int offsetFrames,
    required this.lostAfter,
    required this.backpressure,
    Duration Function()? now,
  }) : _offsetFrames = offsetFrames,
       _now = now ?? monotonicMicrosNowAsDuration;

  @override
  final FrameRate frameRate;

  int _offsetFrames;

  @override
  int get offsetFrames => _offsetFrames;

  @override
  set offsetFrames(int value) {
    _offsetFrames = value;
    _native.offsetFrames = value;
  }

  @override
  final Duration lostAfter;

  @override
  final Backpressure backpressure;

  final Duration Function() _now;

  /// The core receiver; created by the subclass.
  NativeReceiver get _native;

  final List<_FrameSink> _frameSinks = [];
  bool _closed = false;
  final StreamController<StateEvent> _events =
      StreamController<StateEvent>.broadcast();
  StreamSubscription<T>? _sub;
  final List<_Waiter> _waiters = [];

  // Kept for the getters after close (when the core receiver is freed).
  Timecode? _lastCurrent;
  FrameRate? _lastRate;

  Timer? _watchdog;
  final Stopwatch _sinceChunk = Stopwatch();
  Duration _chunkGap = Duration.zero;

  @override
  Stream<Timecode> get frames {
    late final _FrameSink sink;
    final c = StreamController<Timecode>(
      onCancel: () => _frameSinks.remove(sink),
      onResume: () => sink.flush(),
    );
    sink = _FrameSink(c, backpressure);
    if (_closed) {
      c.close();
    } else {
      _frameSinks.add(sink);
    }
    return c.stream;
  }

  @override
  Stream<StateEvent> get events => _events.stream;

  @override
  bool get isLocked => !_closed && _native.locked;

  @override
  FrameRate? get detectedRate => frameRate != FrameRate.auto
      ? frameRate
      : (_closed ? _lastRate : _native.detectedRate);

  @override
  Timecode? get current => _closed ? _lastCurrent : _native.current;

  @override
  bool get isAttached => _sub != null;

  @override
  bool get isClosed => _closed;

  @override
  void attach(Stream<T> input) {
    if (_closed) throw StateError('Receiver closed');
    if (_sub != null) {
      throw StateError('A stream is already attached; detach() it first');
    }
    late final StreamSubscription<T> sub;
    sub = input.listen(
      (chunk) {
        _onChunk(chunk);
        _armWatchdog();
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_sub, sub) && !_events.isClosed) {
          _events.addError(error, stack);
        }
      },
      onDone: () {
        if (identical(_sub, sub)) {
          _sub = null;
          _lost();
          _emitEvent(const StateEvent(StateEventType.end));
        }
      },
    );
    _sub = sub;
  }

  @override
  Future<void> detach() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    _lost();
  }

  @override
  Future<Timecode> waitFor(Timecode target) {
    if (_closed) return Future.error(StateError('Receiver closed'));
    final w = _Waiter(target);
    _waiters.add(w);
    return w.completer.future;
  }

  @override
  Timecode? positionAt(Duration timestamp) {
    final rate = detectedRate;
    final f = framesAt(timestamp);
    if (rate == null || f == null) return null;
    return Timecode.fromFrameIndex(f.floor(), rate, timestamp: timestamp);
  }

  @override
  double? framesAt(Duration timestamp) =>
      _closed ? null : _native.framesAt(timestamp.inMicroseconds * 1000);

  @override
  Future<void> close() async {
    if (_closed) return;
    await detach();
    _lastCurrent = _native.current;
    _lastRate = _native.detectedRate;
    _closed = true;
    _native.dispose();
    _watchdog?.cancel();
    for (final sink in List.of(_frameSinks)) {
      sink.close();
    }
    _frameSinks.clear();
    for (final w in _waiters) {
      if (!w.completer.isCompleted) {
        w.completer.completeError(StateError('Receiver closed'));
      }
    }
    _waiters.clear();
    await _events.close();
  }

  // --- for subclasses ----------------------------------------------------

  void _onChunk(T chunk);

  /// Delivers what the core reported for one chunk (or a loss).
  void _dispatch(List<NativeEvent> events) {
    for (final e in events) {
      switch (e.kind) {
        case NativeEventKind.lock:
          final tc = e.timecode!;
          _emitEvent(
            StateEvent(
              StateEventType.lock,
              timecode: tc,
              frameRate: tc.frameRate,
              channel: e.channel,
            ),
          );
        case NativeEventKind.frame:
          _emitFrame(e.timecode!, e.previous);
        case NativeEventKind.jump:
          _emitEvent(StateEvent(StateEventType.jump, timecode: e.timecode));
        case NativeEventKind.lost:
          _watchdog?.cancel();
          _watchdog = null;
          _emitEvent(const StateEvent(StateEventType.lost));
      }
    }
  }

  void _emitEvent(StateEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  /// The input stopped, was detached or ended: ends the chase now.
  void _lost() {
    _watchdog?.cancel();
    _watchdog = null;
    if (_closed) return;
    _dispatch(_native.signalLost());
  }

  // Also detects loss when chunks stop arriving altogether: no chunk for
  // [lostAfter] plus twice the usual gap between chunks (so input delivered
  // in large blocks is not mistaken for a stop).
  void _armWatchdog() {
    if (_sinceChunk.isRunning) {
      final gap = _sinceChunk.elapsed;
      _chunkGap = gap > const Duration(seconds: 5)
          ? const Duration(seconds: 5)
          : gap;
    }
    _sinceChunk
      ..reset()
      ..start();
    _watchdog?.cancel();
    _watchdog = null;
    if (_closed || !_native.locked) return;
    _watchdog = Timer(lostAfter + _chunkGap * 2, _lost);
  }

  void _emitFrame(Timecode tc, int? previous) {
    for (final sink in List.of(_frameSinks)) {
      sink.add(tc);
    }
    if (previous == null || _waiters.isEmpty) return;
    final rate = tc.frameRate!;
    final day = rate.framesPerDay;
    final index = tc.frameIndex(rate);
    final step = (index - previous) % day;
    if (step <= 0) return;
    _waiters.removeWhere((w) {
      final target = Timecode.tryParse(w.target.toString(), frameRate: rate);
      if (target == null) return false;
      if ((index - target.frameIndex(rate)) % day < step) {
        w.completer.complete(tc);
        return true;
      }
      return false;
    });
  }
}

class _Waiter {
  _Waiter(this.target);
  final Timecode target;
  final Completer<Timecode> completer = Completer<Timecode>();
}

class _FrameSink {
  _FrameSink(this.controller, this.mode);
  final StreamController<Timecode> controller;
  final Backpressure mode;
  Timecode? _pending;

  void add(Timecode tc) {
    if (controller.isClosed) return;
    if (mode == Backpressure.latest && controller.isPaused) {
      _pending = tc;
      return;
    }
    controller.add(tc);
  }

  void flush() {
    final p = _pending;
    _pending = null;
    if (p != null && !controller.isClosed) controller.add(p);
  }

  void close() {
    flush();
    controller.close();
  }
}
