import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Byte helpers shared by the crypto and API layers.
Uint8List concat(List<List<int>> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

/// Constant-time comparison.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

String bytesToHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexToBytes(String hex) {
  if (hex.length.isOdd) throw const FormatException('odd hex length');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Standard base64 with padding, matching the server's JSON encoding.
String b64encode(List<int> b) => base64.encode(b);

Uint8List b64decode(String s) => Uint8List.fromList(base64.decode(s));

Uint8List utf8Encode(String s) => Uint8List.fromList(utf8.encode(s));

String utf8Decode(List<int> b) => utf8.decode(b);

final Random _rng = Random.secure();

Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}
