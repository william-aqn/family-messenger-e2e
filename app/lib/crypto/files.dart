// Attachment encryption (PROTOCOL.md §6.1).
import 'dart:typed_data';

import 'bytes.dart';
import 'primitives.dart';

final Uint8List blobAad = utf8Encode('msgr-blob-v1');

class EncryptedFile {
  const EncryptedFile({required this.key, required this.nonce, required this.ciphertext});

  final Uint8List key;
  final Uint8List nonce;
  final Uint8List ciphertext;
}

Future<EncryptedFile> encryptFile(List<int> data) async {
  final key = randomBytes(keySize);
  final nonce = randomBytes(nonceSize);
  return EncryptedFile(key: key, nonce: nonce, ciphertext: await aeadEncrypt(key, nonce, blobAad, data));
}

Future<Uint8List> decryptFile(List<int> key, List<int> nonce, List<int> ciphertext) => aeadDecrypt(key, nonce, blobAad, ciphertext);
