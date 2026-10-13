# timecode_tools

SMPTE timecode reader for Dart and Flutter.

- **LTC** (linear timecode) from a stream of PCM audio.
- **MTC** (MIDI timecode) from a stream of raw MIDI bytes.

The package does no audio or MIDI I/O itself: you attach a stream from
whatever capture API you use (a Flutter plugin, a platform channel, a file,
a socket).

Decoding and the lock / loss / jump rules run in the
[timecode-tools](https://github.com/ShowBuildLaboratories/timecode-tools-rs)
Rust core, called through `dart:ffi`; the streams, backpressure and
`waitFor` are Dart. The Node.js package `timecode-tools` uses the same
core, so both give the same answers.

## Platforms

The native library ships prebuilt inside the package and is bundled by a
[build hook](https://dart.dev/tools/hooks) (nothing is downloaded at build
time). It needs Dart 3.10 or later.

| Platform | Architectures |
|---|---|
| macOS | arm64, x64 |
| iOS | arm64 (device), arm64 and x64 (simulator) |
| Android | arm64-v8a, armeabi-v7a, x86_64 |
| Linux | x64, arm64 |
| Windows | x64, arm64 |

The web is not supported: there, creating a receiver or decoder throws an
`UnsupportedError` (`Timecode` and `FrameRate` still work).

## Features

- **Frame rates**: 24, 25, 29.97 drop-frame and 30 fps, chosen with
  `FrameRate` or detected from the signal (`FrameRate.auto`).
- **One interface for both**: `LtcReceiver` and `MtcReceiver` implement
  `TimecodeReceiver` — `attach` / `detach` / `close`, `frames`, `events`
  (`lock` / `lost` / `jump` / `end`, the same names as the Node.js version), `waitFor`, `positionAt`, `frameRate`,
  `offsetFrames` and `backpressure`.
- **Accurate timing**: every timecode carries the moment its frame began,
  computed from the input timestamps rather than from when your code
  happened to receive it. `positionAt` gives the timecode at any instant
  from a least-squares fit of the signal, free of callback jitter.
- **Latency offset**: `offsetFrames` shifts every reported timecode to
  compensate for input latency.
- **LTC decoding**: either signal polarity, any chunk size, multi-channel
  input (pick the channel), and a robust start wherever capture begins.
- **MTC decoding**: quarter-frame messages (reported once per frame) and
  full-frame (locate) SysEx; real-time bytes and other MIDI traffic are
  skipped, and SysEx may be split across chunks.
- **Same answers everywhere**: golden files shared with the Rust core
  (`test/goldens`) are replayed through this package, event for event.

## LTC

```dart
import 'package:timecode_tools/timecode_tools.dart';

final rx = LtcReceiver(frameRate: FrameRate.auto, offsetFrames: 0);
rx.attach(pcmStream); // Stream<PcmChunk>

rx.frames.listen((tc) => print(tc)); // 01:02:03:04 (01:02:03;04 for DF)
rx.events.listen((e) => print(e.type)); // StateEventType.lock / lost / jump / end

await rx.waitFor(Timecode.parse('01:00:10:00'));

await rx.detach();
```

Each `PcmChunk` holds signed 16-bit samples (interleaved when
`channels > 1`; choose the LTC channel, 1-based, with
`LtcReceiver(channel: n)`; the default is 1), the
sample rate, and a `timestamp`: when the chunk's first sample was
captured, on a monotonic clock. If your capture API cannot tell you that,
leave it `null` and the receiver uses the time it received the chunk
(less accurate). `PcmChunk.fromFloat32` converts float audio.

## MTC

```dart
final rx = MtcReceiver();
rx.attach(midiStream); // Stream<MidiChunk>, raw MIDI bytes from one input
rx.frames.listen((tc) => print(tc));
```

A full set of eight quarter-frame messages spans two frames; the receiver
reports every frame, each stamped with the time it began. Give each
`MidiChunk` the arrival time of its bytes (`timestamp`) for accurate
timing. A full-frame message (a locate) ends any chase (`lost` if
locked), is reported as a `jump`, and sets `current` to the new position.

## One interface

`LtcReceiver` and `MtcReceiver` both implement `TimecodeReceiver<T>`
(`T` is `PcmChunk` for LTC, `MidiChunk` for MTC), so code that follows
timecode does not need to know where it comes from:

```dart
Future<void> follow<T>(TimecodeReceiver<T> rx, Stream<T> input) async {
  rx.events.listen((e) => print(e));
  rx.attach(input);
  await rx.waitFor(Timecode.parse('01:00:10:00'));
  print('passed 01:00:10:00 at ${rx.detectedRate?.label} fps');
  await rx.detach();
}

await follow(LtcReceiver(), pcmStream);
await follow(MtcReceiver(), midiStream);
```

Only the source-specific parts differ: `LtcReceiver` has `channel` and
`level`; `MtcReceiver` reports full-frame (locate) messages as a `jump`.

## Lock, loss and jumps

- `frames` carries every frame on the followed timeline **while locked**.
  `StateEventType.lock` comes first, when the source has been stable for a
  few frames (LTC: four contiguous frames; MTC: two complete quarter-frame
  sets in a row).
- A single corrupt frame is ignored. A real relocation is reported as
  `jump` once two contiguous frames confirm it, and the receiver keeps
  following the new timeline.
- `lost` comes when nothing was followed for `lostAfter` (default 300 ms),
  when the input stops arriving, or when the stream is detached or ends.
- `waitFor` completes when normal playback passes the target (also across
  midnight). A jump over or onto the target does not count. It survives
  `detach` (attach another stream to continue) and fails on `close`.

## Streams

`frames` and `events` are ordinary Dart streams, so `await for` works too.
A slow `frames` listener (one that is paused, such as an `await for` loop
still busy with the previous frame) gets only the newest frame by default;
pass `backpressure: Backpressure.all` to queue every frame instead.
`events` always delivers every event. Each is a `StateEvent` with a
`type` (`lock`, `lost`, `jump`, or `end` when the attached input finishes),
plus the `timecode` for `lock` and `jump`, and `frameRate` (and, for LTC,
`channel`) for `lock`. An error from the input stream arrives as an error
on `events`. `isClosed` tells whether `close` was called.

`Timecode.timestamp`, `positionAt` and `framesAt` use the same clock as
your chunk timestamps.

## Low-level LTC decoder

```dart
final dec = LtcDecoder(sampleRate: 48000);
final frames = dec.push(pcm); // Int16List in, decoded frames out
print(dec.locked);
print(dec.estimatedFps); // 24, 25 or 30 (LtcFrame.dropFrame marks 29.97 DF)
```

`LtcFrame.sampleIndex` is the sample at which the frame's sync word ended,
which is where the next frame begins.

See [`example/main.dart`](example/main.dart) for a runnable example.

## Building the native library yourself

To use a local checkout of the Rust core instead of the prebuilt library
(Rust and the target's toolchain must be installed), add this to the
`pubspec.yaml` of the app or package you run:

```yaml
hooks:
  user_defines:
    timecode_tools:
      rust_source: ../timecode-tools-rs # relative to this pubspec.yaml
```

The build hook then runs `cargo build --release -p timecode-tools-ffi`
for the target being built.

## Development

- `dart test` runs the tests, including the shared goldens.
- `dart run tool/sync_core.dart <timecode-tools-rs>` copies the C header,
  the prebuilt libraries and the goldens from the core repository and
  records their SHA-256 in `core_copies.json`;
  `dart run tool/check_copies.dart [--core <dir>]` checks them.
- `dart run tool/add_native.dart <dir> <source>` adds libraries built by
  CI (a Release of the core, or the `native` jobs here) and records them
  in `core_copies.json`.
- `dart run tool/ffigen.dart` regenerates the bindings from
  `native/include/timecode_tools.h`.

## Releasing

Versions are published to pub.dev from GitHub Actions: update the version
and the changelog, push a `v<version>` tag, and approve the run in the
`release` environment. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
