// P4 — firstTicket picks the first non-empty barcode raw value, trimmed, and
// rejects empty/whitespace/null entries. The MobileScanner widget itself needs a
// camera and can't be widget-tested headlessly.
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/src/ui/scan_screen.dart';

void main() {
  test('returns the first non-empty value, trimmed', () {
    expect(firstTicket(['  docTICKET  ']), 'docTICKET');
  });

  test('skips null and whitespace, returns the next real value', () {
    expect(firstTicket([null, '   ', '', '  doc-abc  ']), 'doc-abc');
  });

  test('returns null when nothing scans as a ticket', () {
    expect(firstTicket(<String?>[null, '', '   ']), isNull);
    expect(firstTicket(const <String?>[]), isNull);
  });
}
