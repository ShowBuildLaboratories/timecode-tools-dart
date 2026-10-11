// Bundles the timecode-tools native library for the target being built.
//
// By default the library is taken from the prebuilt copies in
// `native/<rust target>/` inside this package; nothing is downloaded.
//
// For development, build it from a checkout of the Rust core instead by
// adding this to the pubspec.yaml of the app (or package) you run:
//
//   hooks:
//     user_defines:
//       timecode_tools:
//         rust_source: ../timecode-tools-rs   # relative to that pubspec.yaml
//
// This runs `cargo build --release -p timecode-tools-ffi --target <target>`
// (Rust and the target's toolchain must be installed).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _crate = 'timecode-tools-ffi';
const _assetName = 'src/ffi/bindings.g.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final target = rustTarget(code);
    final fileName = code.targetOS.dylibFileName('timecode_tools_ffi');

    final Uri library;
    final source = input.userDefines.path('rust_source');
    if (source != null) {
      library = await _cargoBuild(input, output, source, target, fileName);
    } else {
      library = input.packageRoot.resolve('native/$target/$fileName');
      if (!File.fromUri(library).existsSync()) {
        throw UnsupportedError(
          'timecode_tools has no prebuilt native library for $target '
          '(${library.toFilePath()}). Build it from the Rust core with the '
          '`rust_source` user define (see hook/build.dart).',
        );
      }
    }
    output.dependencies.add(library);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );
  });
}

/// The Rust target triple for the code being built.
String rustTarget(CodeConfig code) {
  final os = code.targetOS;
  final arch = code.targetArchitecture;
  final triple = switch ((os, arch)) {
    (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
    (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
    (OS.iOS, Architecture.arm64) =>
      code.iOS.targetSdk == IOSSdk.iPhoneSimulator
          ? 'aarch64-apple-ios-sim'
          : 'aarch64-apple-ios',
    (OS.iOS, Architecture.x64) => 'x86_64-apple-ios',
    (OS.android, Architecture.arm64) => 'aarch64-linux-android',
    (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
    (OS.android, Architecture.x64) => 'x86_64-linux-android',
    (OS.android, Architecture.ia32) => 'i686-linux-android',
    (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
    (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
    (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
    (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
    _ => null,
  };
  if (triple == null) {
    throw UnsupportedError('timecode_tools does not support $os $arch');
  }
  return triple;
}

Future<Uri> _cargoBuild(
  BuildInput input,
  BuildOutputBuilder output,
  Uri sourceUri,
  String target,
  String fileName,
) async {
  // A directory: make sure relative paths resolve inside it.
  final source = sourceUri.path.endsWith('/')
      ? sourceUri
      : sourceUri.replace(path: '${sourceUri.path}/');
  final sourceDir = Directory.fromUri(source);
  if (!File.fromUri(source.resolve('Cargo.toml')).existsSync()) {
    throw ArgumentError(
      'rust_source (${sourceDir.path}) is not a Cargo workspace',
    );
  }
  final targetDir = input.outputDirectoryShared.resolve('cargo/');
  final result = await Process.run(
    'cargo',
    [
      'build',
      '--release',
      '--package',
      _crate,
      '--target',
      target,
      '--target-dir',
      targetDir.toFilePath(),
    ],
    workingDirectory: sourceDir.path,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      'cargo',
      ['build', '--package', _crate, '--target', target],
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  // Rebuild when the Rust sources change.
  for (final dir in ['crates/', 'Cargo.toml', 'Cargo.lock']) {
    final uri = source.resolve(dir);
    if (FileSystemEntity.isDirectorySync(uri.toFilePath())) {
      for (final f in Directory.fromUri(uri).listSync(recursive: true)) {
        if (f is File && !f.path.contains('${Platform.pathSeparator}target')) {
          output.dependencies.add(f.uri);
        }
      }
    } else if (File.fromUri(uri).existsSync()) {
      output.dependencies.add(uri);
    }
  }
  return targetDir.resolve('$target/release/$fileName');
}
