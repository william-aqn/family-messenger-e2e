// Thin async wrappers over package:cryptography so that the protocol code
// reads like PROTOCOL.md. Every function has an exact counterpart in the Go
// reference implementation (pkg/e2e) and the web client.
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bytes.dart';

const int nonceSize = 24;
const int tagSize = 16;
const int keySize = 32;

final Ed25519 _ed25519 = Ed25519();
final X25519 _x25519 = X25519();
final Xchacha20 _aead = Xchacha20.poly1305Aead();
final Sha256 _sha256 = Sha256();

class KdfParams {
  const KdfParams({required this.t, required this.m, required this.p});

  factory KdfParams.fromJson(Map<String, dynamic> j) => KdfParams(t: j['t'] as int, m: j['m'] as int, p: j['p'] as int);

  /// Iterations, memory in KiB, parallelism.
  final int t;
  final int m;
  final int p;
}

Future<Uint8List> ed25519Public(List<int> seed) async {
  final kp = await _ed25519.newKeyPairFromSeed(seed);
  return Uint8List.fromList((await kp.extractPublicKey()).bytes);
}

Future<Uint8List> sign(List<int> seed, List<int> message) async {
  final kp = await _ed25519.newKeyPairFromSeed(seed);
  return Uint8List.fromList((await _ed25519.sign(message, keyPair: kp)).bytes);
}

Future<bool> verify(List<int> publicKey, List<int> message, List<int> signature) async {
  if (signature.length != 64 || publicKey.length != 32) return false;
  try {
    return await _ed25519.verify(
      message,
      signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

Future<Uint8List> x25519Public(List<int> priv) async {
  final kp = await _x25519.newKeyPairFromSeed(priv);
  return Uint8List.fromList((await kp.extractPublicKey()).bytes);
}

/// X25519 shared secret; rejects low-order public keys like Go's crypto/ecdh.
Future<Uint8List> x25519Shared(List<int> priv, List<int> pub) async {
  final kp = await _x25519.newKeyPairFromSeed(priv);
  final secret = await _x25519.sharedSecretKey(
    keyPair: kp,
    remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
  );
  final ss = Uint8List.fromList(await secret.extractBytes());
  var acc = 0;
  for (final b in ss) {
    acc |= b;
  }
  if (acc == 0) throw StateError('invalid public key (low order point)');
  return ss;
}

/// Returns ciphertext || 16-byte tag.
Future<Uint8List> aeadEncrypt(List<int> key, List<int> nonce, List<int> aad, List<int> plaintext) async {
  final box = await _aead.encrypt(plaintext, secretKey: SecretKey(key), nonce: nonce, aad: aad);
  return concat([box.cipherText, box.mac.bytes]);
}

/// Throws on authentication failure.
Future<Uint8List> aeadDecrypt(List<int> key, List<int> nonce, List<int> aad, List<int> ciphertext) async {
  if (ciphertext.length < tagSize) throw const FormatException('ciphertext too short');
  final ct = ciphertext.sublist(0, ciphertext.length - tagSize);
  final mac = Mac(ciphertext.sublist(ciphertext.length - tagSize));
  final pt = await _aead.decrypt(SecretBox(ct, nonce: nonce, mac: mac), secretKey: SecretKey(key), aad: aad);
  return Uint8List.fromList(pt);
}

Future<Uint8List> hkdfSha256(List<int> ikm, List<int> salt, String info, int length) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  final out = await hkdf.deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: utf8Encode(info));
  return Uint8List.fromList(await out.extractBytes());
}

Future<Uint8List> sha256(List<int> data) async => Uint8List.fromList((await _sha256.hash(data)).bytes);

Future<Uint8List> argon2idHash(String password, List<int> salt, KdfParams params, int length) async {
  final algo = Argon2id(parallelism: params.p, memory: params.m, iterations: params.t, hashLength: length);
  final key = await algo.deriveKey(secretKey: SecretKey(utf8Encode(password)), nonce: salt);
  return Uint8List.fromList(await key.extractBytes());
}
