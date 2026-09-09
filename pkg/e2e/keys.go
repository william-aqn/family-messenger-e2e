package e2e

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
)

// ErrInvalidKey is returned for malformed or weak public keys.
var ErrInvalidKey = errors.New("e2e: invalid key")

// AccountKeys is the long-term key material of an account. All devices of an
// account share it (see PROTOCOL.md §3).
type AccountKeys struct {
	SignSeed [32]byte // Ed25519 seed
	SignPub  [32]byte // Ed25519 public key
	EncPriv  [32]byte // X25519 private key
	EncPub   [32]byte // X25519 public key
}

// GenerateAccountKeys creates fresh random account keys.
func GenerateAccountKeys() (*AccountKeys, error) {
	var seed, encPriv [32]byte
	if _, err := rand.Read(seed[:]); err != nil {
		return nil, err
	}
	if _, err := rand.Read(encPriv[:]); err != nil {
		return nil, err
	}
	return AccountKeysFromSecrets(seed, encPriv)
}

// AccountKeysFromSecrets derives the public keys from the two secrets.
func AccountKeysFromSecrets(signSeed, encPriv [32]byte) (*AccountKeys, error) {
	k := &AccountKeys{SignSeed: signSeed, EncPriv: encPriv}
	priv := ed25519.NewKeyFromSeed(signSeed[:])
	copy(k.SignPub[:], priv[ed25519.SeedSize:])
	pub, err := X25519Public(encPriv)
	if err != nil {
		return nil, err
	}
	k.EncPub = pub
	return k, nil
}

// Sign signs msg with the account's Ed25519 key.
func (k *AccountKeys) Sign(msg []byte) []byte {
	return ed25519.Sign(ed25519.NewKeyFromSeed(k.SignSeed[:]), msg)
}

// Verify checks an Ed25519 signature made by signPub over msg.
func Verify(signPub [32]byte, msg, sig []byte) bool {
	if len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(signPub[:]), msg, sig)
}

// X25519Public returns the X25519 public key for a private scalar.
func X25519Public(priv [32]byte) ([32]byte, error) {
	var pub [32]byte
	p, err := ecdh.X25519().NewPrivateKey(priv[:])
	if err != nil {
		return pub, ErrInvalidKey
	}
	copy(pub[:], p.PublicKey().Bytes())
	return pub, nil
}

// x25519 computes the shared secret; it fails on low-order public keys.
func x25519(priv, pub [32]byte) ([]byte, error) {
	p, err := ecdh.X25519().NewPrivateKey(priv[:])
	if err != nil {
		return nil, ErrInvalidKey
	}
	q, err := ecdh.X25519().NewPublicKey(pub[:])
	if err != nil {
		return nil, ErrInvalidKey
	}
	ss, err := p.ECDH(q)
	if err != nil {
		return nil, ErrInvalidKey
	}
	return ss, nil
}
