// Account keys, password-derived keys and the encrypted key bundle,
// PROTOCOL.md §3.
import 'dart:typed_data';

import 'bytes.dart';
import 'primitives.dart';

const int saltSize = 16;
const int keyBundleSize = nonceSize + 64 + tagSize; // 104
const KdfParams defaultKdf = KdfParams(t: 3, m: 64 * 1024, p: 1);
final Uint8List _bundleAad = utf8Encode('msgr-keybundle-v1');

class AccountKeys {
  const AccountKeys({required this.signSeed, required this.signPub, required this.encPriv, required this.encPub});

  final Uint8List signSeed;
  final Uint8List signPub;
  final Uint8List encPriv;
  final Uint8List encPub;
}

class DerivedKeys {
  const DerivedKeys({required this.authKey, required this.encKey});

  /// Sent to the server as the login secret.
  final Uint8List authKey;

  /// Never leaves the device; unlocks the key bundle.
  final Uint8List encKey;
}

Future<AccountKeys> keysFromSecrets(List<int> signSeed, List<int> encPriv) async {
  if (signSeed.length != 32 || encPriv.length != 32) throw ArgumentError('secrets must be 32 bytes');
  return AccountKeys(
    signSeed: Uint8List.fromList(signSeed),
    signPub: await ed25519Public(signSeed),
    encPriv: Uint8List.fromList(encPriv),
    encPub: await x25519Public(encPriv),
  );
}

Future<AccountKeys> generateKeys() => keysFromSecrets(randomBytes(32), randomBytes(32));

Future<DerivedKeys> deriveKeys(String password, List<int> salt, [KdfParams params = defaultKdf]) async {
  final out = await argon2idHash(password, salt, params, 64);
  return DerivedKeys(authKey: out.sublist(0, 32), encKey: out.sublist(32, 64));
}

Future<Uint8List> sealKeyBundle(List<int> encKey, List<int> nonce, AccountKeys keys) async =>
    concat([nonce, await aeadEncrypt(encKey, nonce, _bundleAad, concat([keys.signSeed, keys.encPriv]))]);

Future<Uint8List> newKeyBundle(List<int> encKey, AccountKeys keys) => sealKeyBundle(encKey, randomBytes(nonceSize), keys);

/// Throws when the bundle cannot be opened or does not match the public keys.
Future<AccountKeys> openKeyBundle(List<int> encKey, List<int> bundle, List<int> signPub, List<int> encPub) async {
  if (bundle.length != keyBundleSize) throw const FormatException('malformed key bundle');
  final secrets = await aeadDecrypt(encKey, bundle.sublist(0, nonceSize), _bundleAad, bundle.sublist(nonceSize));
  final keys = await keysFromSecrets(secrets.sublist(0, 32), secrets.sublist(32, 64));
  if (!bytesEqual(keys.signPub, signPub) || !bytesEqual(keys.encPub, encPub)) {
    throw StateError('key bundle does not match the public keys');
  }
  return keys;
}

/// Password change without the old password (PROTOCOL.md §3.2). A signed-in
/// device re-encrypts the key bundle from the account secrets it already
/// holds, and proves it may do so by signing a server-issued challenge
/// together with the new material, instead of knowing the old password.
const int pwChangeChallengeSize = 32;
final Uint8List _pwChangePrefix = utf8Encode('msgr-pwchange-v1');

/// The bytes to sign:
/// "msgr-pwchange-v1" || challenge(32) || account_id(16) || device_id(16) ||
/// new_salt(16) || new_auth_key(32) || new_key_bundle(104) || sign_out_others(1).
/// Every field is fixed size, so the concatenation is unambiguous.
Uint8List passwordChangeMessage(
  List<int> challenge,
  List<int> accountId,
  List<int> deviceId,
  List<int> newSalt,
  List<int> newAuthKey,
  List<int> newKeyBundle, {
  required bool signOutOthers,
}) {
  if (challenge.length != pwChangeChallengeSize ||
      accountId.length != 16 ||
      deviceId.length != 16 ||
      newSalt.length != saltSize ||
      newAuthKey.length != 32 ||
      newKeyBundle.length != keyBundleSize) {
    throw ArgumentError('invalid password change input');
  }
  return concat([
    _pwChangePrefix,
    challenge,
    accountId,
    deviceId,
    newSalt,
    newAuthKey,
    newKeyBundle,
    [signOutOthers ? 1 : 0],
  ]);
}

Future<Uint8List> signPasswordChange(
  List<int> signSeed,
  List<int> challenge,
  List<int> accountId,
  List<int> deviceId,
  List<int> newSalt,
  List<int> newAuthKey,
  List<int> newKeyBundle, {
  required bool signOutOthers,
}) =>
    sign(
      signSeed,
      passwordChangeMessage(challenge, accountId, deviceId, newSalt, newAuthKey, newKeyBundle, signOutOthers: signOutOthers),
    );
