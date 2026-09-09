import 'bytes.dart';
import 'primitives.dart';

/// Safety number of an account, PROTOCOL.md §3.3: 8 groups of 4 hex chars.
Future<String> fingerprint(List<int> signPub, List<int> encPub) async {
  final h = await sha256(concat([utf8Encode('msgr-fp-v1'), signPub, encPub]));
  final hex = bytesToHex(h.sublist(0, 16));
  final groups = <String>[];
  for (var i = 0; i < hex.length; i += 4) {
    groups.add(hex.substring(i, i + 4));
  }
  return groups.join(' ');
}
