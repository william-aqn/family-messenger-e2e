package e2e

import (
	"crypto/rand"
	"crypto/sha256"
	"errors"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"
)

// KDFParams are the Argon2id parameters used to derive keys from a password.
type KDFParams struct {
	Time      uint32 `json:"t"`
	MemoryKiB uint32 `json:"m"`
	Threads   uint8  `json:"p"`
}

// DefaultKDFParams is the protocol v1 parameter set (64 MiB, 3 passes).
var DefaultKDFParams = KDFParams{Time: 3, MemoryKiB: 64 * 1024, Threads: 1}

const (
	// SaltSize is the size of the per-account password salt.
	SaltSize = 16
	// KeyBundleSize is the size of the encrypted private-key backup.
	KeyBundleSize = NonceSize + 64 + TagSize
)

var keyBundleAAD = []byte("msgr-keybundle-v1")

// ErrKeyBundle is returned when a key bundle cannot be opened or does not
// match the expected public keys.
var ErrKeyBundle = errors.New("e2e: cannot open key bundle")

// DeriveKeys runs Argon2id over the password and splits the 64-byte output
// into the login secret (authKey) and the local bundle key (encKey).
func DeriveKeys(password string, salt []byte, p KDFParams) (authKey, encKey [32]byte) {
	out := argon2.IDKey([]byte(password), salt, p.Time, p.MemoryKiB, p.Threads, 64)
	copy(authKey[:], out[:32])
	copy(encKey[:], out[32:])
	return authKey, encKey
}

// AuthHash is the value the server stores for login verification.
func AuthHash(authKey [32]byte) [32]byte { return sha256.Sum256(authKey[:]) }

// NewKeyBundle encrypts the account secrets with a fresh random nonce.
func NewKeyBundle(encKey [32]byte, keys *AccountKeys) ([]byte, error) {
	var nonce [NonceSize]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	return SealKeyBundle(encKey, nonce, keys), nil
}

// SealKeyBundle encrypts sign_seed || enc_priv under encKey with the given
// nonce. Callers other than tests should use NewKeyBundle.
func SealKeyBundle(encKey [32]byte, nonce [NonceSize]byte, keys *AccountKeys) []byte {
	aead, err := chacha20poly1305.NewX(encKey[:])
	if err != nil {
		panic(err) // key size is fixed
	}
	secrets := make([]byte, 0, 64)
	secrets = append(secrets, keys.SignSeed[:]...)
	secrets = append(secrets, keys.EncPriv[:]...)
	out := make([]byte, 0, KeyBundleSize)
	out = append(out, nonce[:]...)
	return aead.Seal(out, nonce[:], secrets, keyBundleAAD)
}

// OpenKeyBundle decrypts a bundle and checks that the derived public keys
// equal the expected ones (as returned by the server).
func OpenKeyBundle(encKey [32]byte, bundle []byte, signPub, encPub [32]byte) (*AccountKeys, error) {
	if len(bundle) != KeyBundleSize {
		return nil, ErrKeyBundle
	}
	aead, err := chacha20poly1305.NewX(encKey[:])
	if err != nil {
		panic(err)
	}
	secrets, err := aead.Open(nil, bundle[:NonceSize], bundle[NonceSize:], keyBundleAAD)
	if err != nil {
		return nil, ErrKeyBundle
	}
	var seed, encPriv [32]byte
	copy(seed[:], secrets[:32])
	copy(encPriv[:], secrets[32:])
	keys, err := AccountKeysFromSecrets(seed, encPriv)
	if err != nil {
		return nil, ErrKeyBundle
	}
	if keys.SignPub != signPub || keys.EncPub != encPub {
		return nil, ErrKeyBundle
	}
	return keys, nil
}
