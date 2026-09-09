package e2e

import (
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"

	"golang.org/x/crypto/chacha20poly1305"
)

// SealedKeySize is the size of a sealed message key: eph_pub (32) + key (32) + tag (16).
const SealedKeySize = 32 + 32 + TagSize

const sealInfo = "msgr-seal-v1"

// Seal encrypts a 32-byte message key to one recipient account
// (PROTOCOL.md §4) using a fresh ephemeral X25519 key.
func Seal(recipientEncPub [32]byte, convID, recipientAccount ID, key [32]byte) ([]byte, error) {
	var eph [32]byte
	if _, err := rand.Read(eph[:]); err != nil {
		return nil, err
	}
	return sealWith(eph, recipientEncPub, convID, recipientAccount, key)
}

func sealWith(ephPriv, recipientEncPub [32]byte, convID, recipientAccount ID, key [32]byte) ([]byte, error) {
	ephPub, err := X25519Public(ephPriv)
	if err != nil {
		return nil, err
	}
	ss, err := x25519(ephPriv, recipientEncPub)
	if err != nil {
		return nil, err
	}
	k, err := sealKey(ss, ephPub, recipientEncPub)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.NewX(k)
	if err != nil {
		return nil, err
	}
	var zero [NonceSize]byte
	out := make([]byte, 0, SealedKeySize)
	out = append(out, ephPub[:]...)
	return aead.Seal(out, zero[:], key[:], sealAAD(convID, recipientAccount)), nil
}

// Open recovers the message key from a sealed box addressed to
// recipientAccount in conversation convID.
func Open(encPriv [32]byte, convID, recipientAccount ID, box []byte) ([32]byte, error) {
	var key [32]byte
	if len(box) != SealedKeySize {
		return key, ErrMalformed
	}
	var ephPub [32]byte
	copy(ephPub[:], box[:32])
	rpub, err := X25519Public(encPriv)
	if err != nil {
		return key, err
	}
	ss, err := x25519(encPriv, ephPub)
	if err != nil {
		return key, ErrDecrypt
	}
	k, err := sealKey(ss, ephPub, rpub)
	if err != nil {
		return key, err
	}
	aead, err := chacha20poly1305.NewX(k)
	if err != nil {
		return key, err
	}
	var zero [NonceSize]byte
	pt, err := aead.Open(nil, zero[:], box[32:], sealAAD(convID, recipientAccount))
	if err != nil {
		return key, ErrDecrypt
	}
	copy(key[:], pt)
	return key, nil
}

func sealKey(ss []byte, ephPub, recipientEncPub [32]byte) ([]byte, error) {
	salt := make([]byte, 0, 64)
	salt = append(salt, ephPub[:]...)
	salt = append(salt, recipientEncPub[:]...)
	return hkdf.Key(sha256.New, ss, salt, sealInfo, 32)
}

func sealAAD(convID, recipientAccount ID) []byte {
	aad := make([]byte, 0, 32)
	aad = append(aad, convID[:]...)
	return append(aad, recipientAccount[:]...)
}
