// The files copied from the Rust core (the C header, the prebuilt
// libraries and the goldens) must be unchanged; see tool/sync_core.dart.
import 'package:test/test.dart';

import '../tool/copies.dart';

void main() {
  test('copies from the core match core_copies.json', () {
    expect(checkCopies('.'), isEmpty);
  });
}
