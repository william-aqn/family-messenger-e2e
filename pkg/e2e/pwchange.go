package e2e

// Password change without the old password (PROTOCOL.md §3.2).
//
// The key bundle is re-encrypted from the account secrets a signed-in device
// already holds, so the old password is not needed to build it. What the
// server needs instead is proof that the caller really is that device and not
// somebody holding a stolen token: the client signs a server-issued challenge
// together with the new password material, and the server verifies the
// signature under the account's stored sign_pub.

import "errors"

// PasswordChangeChallengeSize is the length of the server's challenge.
const PasswordChangeChallengeSize = 32

// ErrPasswordChangeInput is returned when a field has the wrong size.
var ErrPasswordChangeInput = errors.New("e2e: invalid password change input")

// pwChangePrefix domain-separates this signature from every other one the
// account key makes; see envSigPrefix for the envelope's.
var pwChangePrefix = []byte("msgr-pwchange-v1")

// PasswordChangeMessage builds the bytes both sides sign and verify:
//
//	"msgr-pwchange-v1" (16) || challenge (32) || account_id (16) ||
//	device_id (16) || new_salt (16) || new_auth_key (32) ||
//	new_key_bundle (104) || sign_out_others (1: 0x00 or 0x01)
//
// Every field has a fixed size, so the concatenation is unambiguous. The new
// material is inside the signature, which keeps a captured proof from being
// reused for a different change, and sign_out_others is there so that the
// instruction cannot be flipped on the way.
func PasswordChangeMessage(challenge []byte, account, device ID, newSalt, newAuthKey, newKeyBundle []byte, signOutOthers bool) ([]byte, error) {
	if len(challenge) != PasswordChangeChallengeSize || len(newSalt) != SaltSize || len(newAuthKey) != 32 || len(newKeyBundle) != KeyBundleSize {
		return nil, ErrPasswordChangeInput
	}
	msg := make([]byte, 0, len(pwChangePrefix)+PasswordChangeChallengeSize+16+16+SaltSize+32+KeyBundleSize+1)
	msg = append(msg, pwChangePrefix...)
	msg = append(msg, challenge...)
	msg = append(msg, account[:]...)
	msg = append(msg, device[:]...)
	msg = append(msg, newSalt...)
	msg = append(msg, newAuthKey...)
	msg = append(msg, newKeyBundle...)
	if signOutOthers {
		msg = append(msg, 1)
	} else {
		msg = append(msg, 0)
	}
	return msg, nil
}

// SignPasswordChange signs the message of PasswordChangeMessage.
func (k *AccountKeys) SignPasswordChange(challenge []byte, account, device ID, newSalt, newAuthKey, newKeyBundle []byte, signOutOthers bool) ([]byte, error) {
	msg, err := PasswordChangeMessage(challenge, account, device, newSalt, newAuthKey, newKeyBundle, signOutOthers)
	if err != nil {
		return nil, err
	}
	return k.Sign(msg), nil
}

// VerifyPasswordChange checks the proof against the account's signing key.
func VerifyPasswordChange(signPub [32]byte, sig, challenge []byte, account, device ID, newSalt, newAuthKey, newKeyBundle []byte, signOutOthers bool) bool {
	msg, err := PasswordChangeMessage(challenge, account, device, newSalt, newAuthKey, newKeyBundle, signOutOthers)
	if err != nil {
		return false
	}
	return Verify(signPub, msg, sig)
}
