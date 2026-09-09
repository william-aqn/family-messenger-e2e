package e2e

import (
	"crypto/rand"
	"encoding/binary"
	"errors"

	"golang.org/x/crypto/chacha20poly1305"
)

const (
	// Version is the envelope format version.
	Version = 1
	// FlagEphemeral marks an envelope the server relays but does not store.
	FlagEphemeral uint8 = 1 << 0
	// FlagUrgent marks call signaling: ring every device, high-priority push.
	FlagUrgent uint8 = 1 << 1

	// MaxRecipients is the maximum number of recipient accounts per envelope.
	MaxRecipients = 100
	// MaxEnvelopeSize is the maximum serialized envelope size.
	MaxEnvelopeSize = 64 * 1024
	// NonceSize is the XChaCha20-Poly1305 nonce size.
	NonceSize = chacha20poly1305.NonceSizeX
	// TagSize is the Poly1305 tag size.
	TagSize = chacha20poly1305.Overhead
	// SignatureSize is the Ed25519 signature size.
	SignatureSize = 64

	fixedHeaderSize    = 1 + 1 + 4*16 + 8 + 2 // 76
	recipientEntrySize = 16 + SealedKeySize   // 96
	minEnvelopeSize    = fixedHeaderSize + recipientEntrySize + NonceSize + 4 + TagSize
)

var (
	envSigPrefix = []byte("msgr-env-v1")

	// ErrMalformed is returned for structurally invalid envelopes or boxes.
	ErrMalformed = errors.New("e2e: malformed envelope")
	// ErrVersion is returned for unsupported envelope versions.
	ErrVersion = errors.New("e2e: unsupported envelope version")
	// ErrRecipients is returned when the recipient count is out of range.
	ErrRecipients = errors.New("e2e: invalid recipient count")
	// ErrTooLarge is returned when an envelope exceeds MaxEnvelopeSize.
	ErrTooLarge = errors.New("e2e: envelope too large")
	// ErrNotRecipient is returned when the account is not among the recipients.
	ErrNotRecipient = errors.New("e2e: account is not a recipient")
	// ErrDecrypt is returned when authentication or decryption fails.
	ErrDecrypt = errors.New("e2e: decryption failed")
)

// Header is the cleartext part of an envelope that the server can read.
type Header struct {
	Flags         uint8
	ConvID        ID
	SenderAccount ID
	SenderDevice  ID
	ClientMsgID   ID
	TimestampMS   uint64
}

// Recipient is an account the message key must be sealed to.
type Recipient struct {
	Account ID
	EncPub  [32]byte
}

// SealedRecipient is a parsed recipient entry.
type SealedRecipient struct {
	Account   ID
	SealedKey [SealedKeySize]byte
}

// Envelope is a parsed envelope. Use Parse to obtain one.
type Envelope struct {
	Header
	Recipients []SealedRecipient
	Nonce      [NonceSize]byte
	Ciphertext []byte

	raw    []byte
	aadLen int
}

// Encrypt builds and signs an envelope for the given recipients
// (PROTOCOL.md §5). It returns the serialized envelope and its signature.
func Encrypt(keys *AccountKeys, hdr Header, recipients []Recipient, plaintext []byte) (env, sig []byte, err error) {
	r := randomness{Ephemeral: make([][32]byte, len(recipients))}
	if _, err := rand.Read(r.Key[:]); err != nil {
		return nil, nil, err
	}
	if _, err := rand.Read(r.Nonce[:]); err != nil {
		return nil, nil, err
	}
	for i := range r.Ephemeral {
		if _, err := rand.Read(r.Ephemeral[i][:]); err != nil {
			return nil, nil, err
		}
	}
	return encryptWith(keys, hdr, recipients, plaintext, &r)
}

// randomness holds every random input of Encrypt so that test vectors are
// deterministic. Production code must never reuse these values.
type randomness struct {
	Key       [32]byte
	Nonce     [NonceSize]byte
	Ephemeral [][32]byte
}

func encryptWith(keys *AccountKeys, hdr Header, recipients []Recipient, plaintext []byte, r *randomness) ([]byte, []byte, error) {
	n := len(recipients)
	if n < 1 || n > MaxRecipients {
		return nil, nil, ErrRecipients
	}
	if len(r.Ephemeral) != n {
		return nil, nil, errors.New("e2e: ephemeral key count mismatch")
	}
	size := fixedHeaderSize + n*recipientEntrySize + NonceSize + 4 + len(plaintext) + TagSize
	if size > MaxEnvelopeSize {
		return nil, nil, ErrTooLarge
	}
	buf := make([]byte, 0, size)
	buf = append(buf, Version, hdr.Flags)
	buf = append(buf, hdr.ConvID[:]...)
	buf = append(buf, hdr.SenderAccount[:]...)
	buf = append(buf, hdr.SenderDevice[:]...)
	buf = append(buf, hdr.ClientMsgID[:]...)
	buf = binary.BigEndian.AppendUint64(buf, hdr.TimestampMS)
	buf = binary.BigEndian.AppendUint16(buf, uint16(n))
	for i, rc := range recipients {
		box, err := sealWith(r.Ephemeral[i], rc.EncPub, hdr.ConvID, rc.Account, r.Key)
		if err != nil {
			return nil, nil, err
		}
		buf = append(buf, rc.Account[:]...)
		buf = append(buf, box...)
	}
	buf = append(buf, r.Nonce[:]...)
	aad := append([]byte(nil), buf...)
	buf = binary.BigEndian.AppendUint32(buf, uint32(len(plaintext)+TagSize))
	aead, err := chacha20poly1305.NewX(r.Key[:])
	if err != nil {
		return nil, nil, err
	}
	buf = aead.Seal(buf, r.Nonce[:], plaintext, aad)
	return buf, keys.Sign(signedBytes(buf)), nil
}

func signedBytes(env []byte) []byte {
	b := make([]byte, 0, len(envSigPrefix)+len(env))
	b = append(b, envSigPrefix...)
	return append(b, env...)
}

// VerifyEnvelope checks the sender's signature over a serialized envelope.
func VerifyEnvelope(senderSignPub [32]byte, env, sig []byte) bool {
	return Verify(senderSignPub, signedBytes(env), sig)
}

// Parse validates the structure of a serialized envelope. It does not verify
// the signature or decrypt anything.
func Parse(env []byte) (*Envelope, error) {
	if len(env) > MaxEnvelopeSize {
		return nil, ErrTooLarge
	}
	if len(env) < minEnvelopeSize {
		return nil, ErrMalformed
	}
	if env[0] != Version {
		return nil, ErrVersion
	}
	e := &Envelope{raw: env}
	e.Flags = env[1]
	copy(e.ConvID[:], env[2:18])
	copy(e.SenderAccount[:], env[18:34])
	copy(e.SenderDevice[:], env[34:50])
	copy(e.ClientMsgID[:], env[50:66])
	e.TimestampMS = binary.BigEndian.Uint64(env[66:74])
	n := int(binary.BigEndian.Uint16(env[74:76]))
	if n < 1 || n > MaxRecipients {
		return nil, ErrRecipients
	}
	off := fixedHeaderSize
	if len(env) < off+n*recipientEntrySize+NonceSize+4+TagSize {
		return nil, ErrMalformed
	}
	e.Recipients = make([]SealedRecipient, n)
	for i := range e.Recipients {
		copy(e.Recipients[i].Account[:], env[off:off+16])
		copy(e.Recipients[i].SealedKey[:], env[off+16:off+recipientEntrySize])
		off += recipientEntrySize
	}
	copy(e.Nonce[:], env[off:off+NonceSize])
	off += NonceSize
	e.aadLen = off
	ctLen := int(binary.BigEndian.Uint32(env[off : off+4]))
	off += 4
	if ctLen < TagSize || len(env)-off != ctLen {
		return nil, ErrMalformed
	}
	e.Ciphertext = env[off:]
	return e, nil
}

// Raw returns the serialized envelope bytes this Envelope was parsed from.
func (e *Envelope) Raw() []byte { return e.raw }

// IsRecipient reports whether account is among the recipients.
func (e *Envelope) IsRecipient(account ID) bool {
	for _, rc := range e.Recipients {
		if rc.Account == account {
			return true
		}
	}
	return false
}

// Decrypt opens the sealed key addressed to account and decrypts the payload.
// It does not verify the signature; call VerifyEnvelope first.
func (e *Envelope) Decrypt(account ID, encPriv [32]byte) ([]byte, error) {
	for _, rc := range e.Recipients {
		if rc.Account != account {
			continue
		}
		key, err := Open(encPriv, e.ConvID, account, rc.SealedKey[:])
		if err != nil {
			return nil, ErrDecrypt
		}
		aead, err := chacha20poly1305.NewX(key[:])
		if err != nil {
			return nil, err
		}
		pt, err := aead.Open(nil, e.Nonce[:], e.Ciphertext, e.raw[:e.aadLen])
		if err != nil {
			return nil, ErrDecrypt
		}
		return pt, nil
	}
	return nil, ErrNotRecipient
}
