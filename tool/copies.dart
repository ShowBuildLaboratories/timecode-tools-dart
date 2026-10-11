// Shared by tool/check_copies.dart and test/copies_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Problems with the copies listed in `<root>/core_copies.json` (empty if
/// none). With [core], each copy is also compared with its source there.
List<String> checkCopies(String root, {String? core}) {
  final manifest =
      jsonDecode(File('$root/core_copies.json').readAsStringSync())
          as Map<String, Object?>;
  final problems = <String>[];
  final listed = <String>{};
  for (final entry in (manifest['files']! as List).cast<Map>()) {
    final path = entry['path'] as String;
    final from = entry['from'] as String;
    final want = entry['sha256'] as String;
    listed.add(path);
    final file = File('$root/$path');
    if (!file.existsSync()) {
      problems.add('$path is missing');
      continue;
    }
    final got = sha256.convert(file.readAsBytesSync()).toString();
    if (got != want) problems.add('$path was changed (sha256 $got)');
    // Libraries built by CI (tool/add_native.dart) have no file in the core.
    if (core != null && !from.startsWith('ci:')) {
      final src = File('$core/$from');
      if (!src.existsSync()) {
        problems.add('$from is missing in $core');
      } else if (sha256.convert(src.readAsBytesSync()).toString() != got) {
        problems.add('$path differs from $core/$from');
      }
    }
  }
  final goldens = Directory('$root/test/goldens');
  if (goldens.existsSync()) {
    for (final f in goldens.listSync(recursive: true).whereType<File>()) {
      final rel = f.path
          .substring(root.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      if (!listed.contains(rel)) {
        problems.add('$rel is not in core_copies.json');
      }
    }
  }
  return problems;
}
