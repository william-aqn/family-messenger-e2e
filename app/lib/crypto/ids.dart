import 'dart:typed_data';

import 'bytes.dart';

final RegExp _uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Parses a canonical UUID string into its 16 bytes.
Uint8List uuidToBytes(String id) {
  final s = id.toLowerCase();
  if (!_uuidRe.hasMatch(s)) throw FormatException('invalid uuid: $id');
  return hexToBytes(s.replaceAll('-', ''));
}

String bytesToUuid(List<int> b) {
  if (b.length != 16) throw const FormatException('uuid must be 16 bytes');
  final h = bytesToHex(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Random UUID version 4.
String newUuid() {
  final b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  return bytesToUuid(b);
}
