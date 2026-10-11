// Adds native libraries built elsewhere (a Release of the Rust core, or the
// `native-*` artifacts of this CI) to native/ and
// records them in core_copies.json.
//
//   dart run tool/add_native.dart <dir with <target>/ folders> <source>
//
// Each <target>/ folder must hold the library and its SHA256SUMS.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/add_native.dart <dir> <source>');
    exit(2);
  }
  final root = File.fromUri(Platform.script).parent.parent.path;
  final manifestFile = File('$root/core_copies.json');
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
  final files = (manifest['files']! as List).cast<Map<String, Object?>>();
  final dirs = Directory(args[0]).listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final dir in dirs) {
    final target = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final sums = {
      for (final line in File('${dir.path}/SHA256SUMS').readAsLinesSync())
        if (line.trim().isNotEmpty)
          line.split(RegExp(r'\s+')).last.replaceFirst('*', ''): line
              .split(RegExp(r'\s+'))
              .first,
    };
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name == 'SHA256SUMS') continue;
      final digest = sha256.convert(f.readAsBytesSync()).toString();
      if (sums[name] != digest) {
        stderr.writeln('$target/$name does not match its SHA256SUMS');
        exit(1);
      }
      final path = 'native/$target/$name';
      File('$root/$path').parent.createSync(recursive: true);
      f.copySync('$root/$path');
      files.removeWhere((e) => e['path'] == path);
      files.add({
        'path': path,
        'from': 'ci:${args[1]}:$target/$name',
        'sha256': digest,
      });
      stdout.writeln('added $path');
    }
  }
  files.sort((a, b) => (a['path']! as String).compareTo(b['path']! as String));
  manifestFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'files': files})}\n',
  );
}
