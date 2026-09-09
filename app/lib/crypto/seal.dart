// Sealed message keys, PROTOCOL.md §4.
import 'dart:typed_data';

import 'bytes.dart';
import 'primitives.dart';

const int sealedKeySize = 32 + keySize + tagSize; // 80
const String _info = 'msgr-seal-v1';
final Uint8List _zeroNonce = Uint8List(nonceSize);

Future<Uint8List> _sealKey(List<int> ss, List<int> ephPub, List<int> recipientEncPub) =>
    hkdfSha256(ss, concat([ephPub, recipientEncPub]), _info, keySize);

/// Deterministic variant used by the shared test vectors.
Future<Uint8List> sealWith(
  List<int> ephPriv,
  List<int> recipientEncPub,
  List<int> convId,
  List<int> recipientAccount,
  List<int> key,
) async {
  final ephPub = await x25519Public(ephPriv);
  final ss = await x25519Shared(ephPriv, recipientEncPub);
  final k = await _sealKey(ss, ephPub, recipientEncPub);
  return concat([ephPub, await aeadEncrypt(k, _zeroNonce, concat([convId, recipientAccount]), key)]);
}

Future<Uint8List> seal(List<int> recipientEncPub, List<int> convId, List<int> recipientAccount, List<int> key) =>
    sealWith(randomBytes(32), recipientEncPub, convId, recipientAccount, key);

/// Throws when the box is malformed or does not authenticate.
Future<Uint8List> open(List<int> encPriv, List<int> convId, List<int> recipientAccount, List<int> box) async {
  if (box.length != sealedKeySize) throw const FormatException('malformed sealed key');
  final ephPub = box.sublist(0, 32);
  final ss = await x25519Shared(encPriv, ephPub);
  final k = await _sealKey(ss, ephPub, await x25519Public(encPriv));
  return aeadDecrypt(k, _zeroNonce, concat([convId, recipientAccount]), box.sublist(32));
}
