// Copies the files this package takes from the Rust core repository
// (timecode-tools-rs) and records their SHA-256 in core_copies.json:
//
// - native/include/timecode_tools.h  (the C interface; ffigen input)
// - native/<target>/*                (prebuilt libraries from target/ffi-dist)
// - test/goldens/**                  (the shared golden files)
//
//   dart run tool/sync_core.dart ../timecode-tools-rs
//
// Then regenerate the bindings (dart run tool/ffigen.dart) if the header
// changed, and run the tests. tool/check_copies.dart (and the test suite)
// verify the copies against core_copies.json; with --core it also compares
// them with the core repository.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/sync_core.dart <timecode-tools-rs>');
    exit(2);
  }
  final core = Directory(args.single).absolute.path;
  final root = File.fromUri(Platform.script).parent.parent.path;
  final copies = <Map<String, String>>[];
  // Keep the libraries added from CI builds (tool/add_native.dart).
  final manifest = File('$root/core_copies.json');
  final kept = manifest.existsSync()
      ? [
          for (final e
              in (jsonDecode(manifest.readAsStringSync())
                      as Map<String, Object?>)['files']!
                  as List)
            if (((e as Map)['from'] as String).startsWith('ci:'))
              e.cast<String, String>(),
        ]
      : <Map<String, String>>[];

  void copy(String from, String to) {
    final src = File('$core/$from');
    final dst = File('$root/$to')..parent.createSync(recursive: true);
    src.copySync(dst.path);
    copies.add({
      'path': to,
      'from': from,
      'sha256': sha256.convert(dst.readAsBytesSync()).toString(),
    });
  }

  copy(
    'crates/timecode-tools-ffi/include/timecode_tools.h',
    'native/include/timecode_tools.h',
  );

  final dist = Directory('$core/target/ffi-dist');
  for (final dir
      in dist.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path))) {
    final target = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final sums = _readSums(File('${dir.path}/SHA256SUMS'));
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name == 'SHA256SUMS') continue;
      final digest = sha256.convert(f.readAsBytesSync()).toString();
      if (sums[name] != digest) {
        stderr.writeln('$target/$name does not match its SHA256SUMS');
        exit(1);
      }
      copy('target/ffi-dist/$target/$name', 'native/$target/$name');
    }
  }

  final goldens = Directory('$core/goldens');
  final files =
      goldens
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.substring(goldens.path.length + 1))
          .toList()
        ..sort();
  for (final rel in files) {
    copy('goldens/$rel', 'test/goldens/$rel');
  }

  for (final e in kept) {
    if (!copies.any((c) => c['path'] == e['path'])) copies.add(e);
  }
  copies.sort((a, b) => a['path']!.compareTo(b['path']!));
  File('$root/core_copies.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'files': copies})}\n',
  );
  stdout.writeln('copied ${copies.length} files; wrote core_copies.json');
}

Map<String, String> _readSums(File f) => {
  for (final line in f.readAsLinesSync())
    if (line.trim().isNotEmpty)
      line.split(RegExp(r'\s+')).last.replaceFirst('*', ''): line
          .split(RegExp(r'\s+'))
          .first,
};
