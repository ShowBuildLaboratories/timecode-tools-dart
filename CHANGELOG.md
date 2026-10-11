## 0.1.0

- Initial release.
- Decoding and the lock / loss / jump rules run in the timecode-tools Rust
  core through `dart:ffi`; the native library ships prebuilt for macOS,
  iOS, Android, Linux and Windows and is bundled by a build hook. On the
  web, receivers and the decoder throw `UnsupportedError`.
- `LtcReceiver`: reads LTC from a `Stream<PcmChunk>` of audio, with
  channel selection (1-based).
- `MtcReceiver`: reads MTC from a `Stream<MidiChunk>` of raw MIDI bytes
  (quarter-frame and full-frame messages).
- Both implement the `TimecodeReceiver` interface: `frames`, `events`
  (`StateEvent`: `lock` / `lost` / `jump` / `end`, input errors as stream
  errors), `isClosed`, `waitFor`, `positionAt` / `framesAt`,
  `offsetFrames` latency compensation, and `Backpressure.latest` (default)
  / `Backpressure.all` for slow listeners. `frames` carries the followed
  timeline while locked; jumps are confirmed by two contiguous frames.
- Golden files shared with the Rust core (`test/goldens`) are replayed in
  the tests.
- `FrameRate` (`auto`, 24, 25, 29.97 drop-frame, 30) and `Timecode`
  (parse, format, `frameRate`, frame index, `addFrames`, `compareTo`).
- `LtcDecoder`: low-level streaming LTC decoder (`push`, `pushBytes`);
  each `LtcFrame` carries `locked` and `estimatedFps`.
- `LtcClockModel`: least-squares clock over the input clock.
- `encodeLtcSequence`: a small LTC synthesizer for tests.
