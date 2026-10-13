# Contributing

## Development

- `dart test` runs the tests, including the golden files shared with the
  Rust core (`test/goldens`).
- `dart analyze --fatal-infos` must be clean.
- Decoding and the lock / loss / jump rules live in the Rust core
  ([timecode-tools-rs](https://github.com/ShowBuildLaboratories/timecode-tools-rs)).
  Changes to them belong there; this package wraps the core's C interface.
- Files copied from the core (the C header, the prebuilt libraries and the
  goldens) are listed with their SHA-256 in `core_copies.json`:
  - `dart run tool/sync_core.dart <timecode-tools-rs>` copies the header,
    the Apple libraries (`target/ffi-dist`) and the goldens.
  - `dart run tool/add_native.dart <dir> <source>` adds libraries built by
    CI (the core's Release artifacts, or the `native` jobs here) for
    Linux, Windows and Android.
  - `dart run tool/check_copies.dart [--core <dir>]` checks them.
  - `dart run tool/ffigen.dart` regenerates the bindings after a header
    change.

## Releasing

Releases are published to pub.dev by GitHub Actions
(`.github/workflows/publish.yml`) when a version tag is pushed.

1. Update `version` in `pubspec.yaml` and add a `## <version>` section at
   the top of `CHANGELOG.md`. If the core changed, copy its files again
   (see above) and run `dart test`.
2. Commit, push to `main`, and wait for CI to pass.
3. Tag the commit and push the tag (the tag must be `v` + the version):

   ```sh
   git tag v0.1.1
   git push origin v0.1.1
   ```

4. The Publish workflow runs the checks (tag and version match, the
   CHANGELOG entry, analysis, the copy check, the tests on Linux, macOS
   and Windows, and a dry run). It then waits for approval in the
   `release` environment: open the run on GitHub and approve it. The
   package is published to pub.dev with a short-lived OIDC token; no
   credentials are stored in the repository.
