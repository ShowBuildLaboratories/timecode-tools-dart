// Checks that the files copied from the Rust core (see tool/sync_core.dart)
// are unchanged: each must match the SHA-256 recorded in core_copies.json.
//
//   dart run tool/check_copies.dart                          # the copies
//   dart run tool/check_copies.dart --core ../timecode-tools-rs  # and the core
import 'dart:io';

import 'copies.dart';

void main(List<String> args) {
  String? core;
  if (args.length == 2 && args.first == '--core') {
    core = args.last;
  } else if (args.isNotEmpty) {
    stderr.writeln('usage: dart run tool/check_copies.dart [--core <dir>]');
    exit(2);
  }
  final root = File.fromUri(Platform.script).parent.parent.path;
  final problems = checkCopies(root, core: core);
  for (final p in problems) {
    stderr.writeln(p);
  }
  if (problems.isNotEmpty) exit(1);
  stdout.writeln(
    'copies match core_copies.json'
    '${core == null ? '' : ' and $core'}',
  );
}
