package e2e

// Shared cross-language test vectors. Run
//
//	go test ./pkg/e2e -run TestVectors -update
//
// to regenerate protocol/testvectors/*.json. Without -update the tests read
// the inputs from the JSON files, recompute every output and compare, so the
// files stay the contract for the TypeScript and Dart implementations.

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"flag"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "regenerate protocol/testvectors")

const vectorsDir = "../../protocol/testvectors"

type hexBytes []byte

func (h hexBytes) MarshalJSON() ([]byte, error) { return json.Marshal(hex.EncodeToString(h)) }

func (h *hexBytes) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	d, err := hex.DecodeString(s)
	if err != nil {
		return err
	}
	*h = d
	return nil
}

func to32(b []byte) (out [32]byte) { copy(out[:], b); return }
func to24(b []byte) (out [24]byte) { copy(out[:], b); return }
func toID(b []byte) (out ID)       { copy(out[:], b); return }

type kdfVectors struct {
	Params KDFParams `json:"params"`
	Cases  []kdfCase `json:"cases"`
}

type kdfCase struct {
	Password string   `json:"password"`
	Salt     hexBytes `json:"salt"`
	AuthKey  hexBytes `json:"auth_key"`
	EncKey   hexBytes `json:"enc_key"`
	AuthHash hexBytes `json:"auth_hash"`
}

type keysVectors struct {
	Cases []keysCase `json:"cases"`
}

type keysCase struct {
	SignSeed     hexBytes `json:"sign_seed"`
	SignPub      hexBytes `json:"sign_pub"`
	EncPriv      hexBytes `json:"enc_priv"`
	EncPub       hexBytes `json:"enc_pub"`
	Fingerprint  string   `json:"fingerprint"`
	Message      hexBytes `json:"message"`
	Signature    hexBytes `json:"signature"`
	BundleEncKey hexBytes `json:"bundle_enc_key"`
	BundleNonce  hexBytes `json:"bundle_nonce"`
	Bundle       hexBytes `json:"bundle"`
}

type sealVectors struct {
	Cases []sealCase `json:"cases"`
}

type sealCase struct {
	RecipientEncPriv hexBytes `json:"recipient_enc_priv"`
	RecipientEncPub  hexBytes `json:"recipient_enc_pub"`
	EphemeralPriv    hexBytes `json:"ephemeral_priv"`
	ConvID           hexBytes `json:"conv_id"`
	RecipientAccount hexBytes `json:"recipient_account"`
	Key              hexBytes `json:"key"`
	Box              hexBytes `json:"box"`
}

type envVectors struct {
	Cases []envCase `json:"cases"`
}

type envCase struct {
	Name           string         `json:"name"`
	SenderSignSeed hexBytes       `json:"sender_sign_seed"`
	SenderSignPub  hexBytes       `json:"sender_sign_pub"`
	Flags          uint8          `json:"flags"`
	ConvID         hexBytes       `json:"conv_id"`
	SenderAccount  hexBytes       `json:"sender_account"`
	SenderDevice   hexBytes       `json:"sender_device"`
	ClientMsgID    hexBytes       `json:"client_msg_id"`
	TimestampMS    uint64         `json:"ts_ms"`
	Recipients     []envRecipient `json:"recipients"`
	MessageKey     hexBytes       `json:"message_key"`
	Nonce          hexBytes       `json:"nonce"`
	Plaintext      hexBytes       `json:"plaintext"`
	Envelope       hexBytes       `json:"envelope"`
	Signature      hexBytes       `json:"signature"`
}

type envRecipient struct {
	Account       hexBytes `json:"account"`
	EncPriv       hexBytes `json:"enc_priv"`
	EncPub        hexBytes `json:"enc_pub"`
	EphemeralPriv hexBytes `json:"ephemeral_priv"`
}

// det is a deterministic byte source for generating vector inputs.
type det struct{ r *rand.ChaCha8 }

func newDet(tag string) *det {
	var seed [32]byte
	copy(seed[:], tag)
	return &det{r: rand.NewChaCha8(seed)}
}

func (d *det) bytes(n int) hexBytes {
	b := make([]byte, n)
	d.r.Read(b)
	return b
}

func writeVectors(t *testing.T, name string, v any) {
	t.Helper()
	if err := os.MkdirAll(vectorsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vectorsDir, name), append(b, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %s", name)
}

func readVectors(t *testing.T, name string, v any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(vectorsDir, name))
	if err != nil {
		t.Fatalf("%v (run with -update to generate)", err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatal(err)
	}
}

func TestVectorsKDF(t *testing.T) {
	if *update {
		d := newDet("kdf")
		v := kdfVectors{Params: DefaultKDFParams}
		// hash-wasm (web) refuses empty passwords, so the third case is a long one instead.
		for _, pw := range []string{"correct horse battery staple", "пароль 🔐 with unicode", strings.Repeat("long-password-", 12)} {
			c := kdfCase{Password: pw, Salt: d.bytes(SaltSize)}
			auth, enc := DeriveKeys(c.Password, c.Salt, v.Params)
			h := AuthHash(auth)
			c.AuthKey, c.EncKey, c.AuthHash = auth[:], enc[:], h[:]
			v.Cases = append(v.Cases, c)
		}
		writeVectors(t, "kdf.json", v)
		return
	}
	var v kdfVectors
	readVectors(t, "kdf.json", &v)
	for i, c := range v.Cases {
		auth, enc := DeriveKeys(c.Password, c.Salt, v.Params)
		h := AuthHash(auth)
		if !bytes.Equal(auth[:], c.AuthKey) || !bytes.Equal(enc[:], c.EncKey) || !bytes.Equal(h[:], c.AuthHash) {
			t.Errorf("kdf case %d mismatch", i)
		}
	}
}

func TestVectorsKeys(t *testing.T) {
	if *update {
		d := newDet("keys")
		var v keysVectors
		for i := 0; i < 3; i++ {
			c := keysCase{SignSeed: d.bytes(32), EncPriv: d.bytes(32), Message: d.bytes(i * 17), BundleEncKey: d.bytes(32), BundleNonce: d.bytes(NonceSize)}
			k, err := AccountKeysFromSecrets(to32(c.SignSeed), to32(c.EncPriv))
			if err != nil {
				t.Fatal(err)
			}
			c.SignPub, c.EncPub = k.SignPub[:], k.EncPub[:]
			c.Fingerprint = Fingerprint(k.SignPub, k.EncPub)
			c.Signature = k.Sign(c.Message)
			c.Bundle = SealKeyBundle(to32(c.BundleEncKey), to24(c.BundleNonce), k)
			v.Cases = append(v.Cases, c)
		}
		writeVectors(t, "keys.json", v)
		return
	}
	var v keysVectors
	readVectors(t, "keys.json", &v)
	for i, c := range v.Cases {
		k, err := AccountKeysFromSecrets(to32(c.SignSeed), to32(c.EncPriv))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(k.SignPub[:], c.SignPub) || !bytes.Equal(k.EncPub[:], c.EncPub) {
			t.Errorf("keys case %d: public keys mismatch", i)
		}
		if Fingerprint(k.SignPub, k.EncPub) != c.Fingerprint {
			t.Errorf("keys case %d: fingerprint mismatch", i)
		}
		if !bytes.Equal(k.Sign(c.Message), c.Signature) || !Verify(k.SignPub, c.Message, c.Signature) {
			t.Errorf("keys case %d: signature mismatch", i)
		}
		if !bytes.Equal(SealKeyBundle(to32(c.BundleEncKey), to24(c.BundleNonce), k), c.Bundle) {
			t.Errorf("keys case %d: bundle mismatch", i)
		}
		if got, err := OpenKeyBundle(to32(c.BundleEncKey), c.Bundle, k.SignPub, k.EncPub); err != nil || *got != *k {
			t.Errorf("keys case %d: open bundle: %v", i, err)
		}
	}
}

func TestVectorsSeal(t *testing.T) {
	if *update {
		d := newDet("seal")
		var v sealVectors
		for i := 0; i < 3; i++ {
			c := sealCase{RecipientEncPriv: d.bytes(32), EphemeralPriv: d.bytes(32), ConvID: d.bytes(16), RecipientAccount: d.bytes(16), Key: d.bytes(32)}
			pub, err := X25519Public(to32(c.RecipientEncPriv))
			if err != nil {
				t.Fatal(err)
			}
			c.RecipientEncPub = pub[:]
			box, err := sealWith(to32(c.EphemeralPriv), pub, toID(c.ConvID), toID(c.RecipientAccount), to32(c.Key))
			if err != nil {
				t.Fatal(err)
			}
			c.Box = box
			v.Cases = append(v.Cases, c)
		}
		writeVectors(t, "seal.json", v)
		return
	}
	var v sealVectors
	readVectors(t, "seal.json", &v)
	for i, c := range v.Cases {
		box, err := sealWith(to32(c.EphemeralPriv), to32(c.RecipientEncPub), toID(c.ConvID), toID(c.RecipientAccount), to32(c.Key))
		if err != nil || !bytes.Equal(box, c.Box) {
			t.Errorf("seal case %d: box mismatch (%v)", i, err)
		}
		key, err := Open(to32(c.RecipientEncPriv), toID(c.ConvID), toID(c.RecipientAccount), c.Box)
		if err != nil || !bytes.Equal(key[:], c.Key) {
			t.Errorf("seal case %d: open mismatch (%v)", i, err)
		}
	}
}

func TestVectorsEnvelope(t *testing.T) {
	if *update {
		d := newDet("envelope")
		var v envVectors
		specs := []struct {
			name  string
			n     int
			flags uint8
			pt    string
		}{
			{"direct text", 2, 0, `{"t":"text","body":"hello, world"}`},
			{"group call offer", 3, FlagEphemeral | FlagUrgent, `{"t":"call.offer","call":"0f9b1c2e-5d4a-4b3c-8e7f-6a5b4c3d2e1f","sdp":"v=0\r\n"}`},
			{"self only empty", 1, 0, ""},
		}
		for _, s := range specs {
			c := envCase{Name: s.name, SenderSignSeed: d.bytes(32), Flags: s.flags, ConvID: d.bytes(16), SenderDevice: d.bytes(16), ClientMsgID: d.bytes(16), TimestampMS: 1_757_400_000_000 + uint64(len(v.Cases))*1234, MessageKey: d.bytes(32), Nonce: d.bytes(NonceSize), Plaintext: hexBytes(s.pt)}
			for i := 0; i < s.n; i++ {
				rc := envRecipient{Account: d.bytes(16), EncPriv: d.bytes(32), EphemeralPriv: d.bytes(32)}
				pub, err := X25519Public(to32(rc.EncPriv))
				if err != nil {
					t.Fatal(err)
				}
				rc.EncPub = pub[:]
				c.Recipients = append(c.Recipients, rc)
			}
			c.SenderAccount = c.Recipients[0].Account
			sender, err := AccountKeysFromSecrets(to32(c.SenderSignSeed), to32(c.Recipients[0].EncPriv))
			if err != nil {
				t.Fatal(err)
			}
			c.SenderSignPub = sender.SignPub[:]
			env, sig, err := encryptWith(sender, vectorHeader(c), vectorRecipients(c), c.Plaintext, vectorRandomness(c))
			if err != nil {
				t.Fatal(err)
			}
			c.Envelope, c.Signature = env, sig
			v.Cases = append(v.Cases, c)
		}
		writeVectors(t, "envelope.json", v)
		return
	}
	var v envVectors
	readVectors(t, "envelope.json", &v)
	for _, c := range v.Cases {
		sender, err := AccountKeysFromSecrets(to32(c.SenderSignSeed), to32(c.Recipients[0].EncPriv))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(sender.SignPub[:], c.SenderSignPub) {
			t.Errorf("%s: sender public key mismatch", c.Name)
		}
		env, sig, err := encryptWith(sender, vectorHeader(c), vectorRecipients(c), c.Plaintext, vectorRandomness(c))
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		if !bytes.Equal(env, c.Envelope) {
			t.Errorf("%s: envelope mismatch", c.Name)
		}
		if !bytes.Equal(sig, c.Signature) {
			t.Errorf("%s: signature mismatch", c.Name)
		}
		if !VerifyEnvelope(to32(c.SenderSignPub), c.Envelope, c.Signature) {
			t.Errorf("%s: signature does not verify", c.Name)
		}
		parsed, err := Parse(c.Envelope)
		if err != nil {
			t.Fatalf("%s: parse: %v", c.Name, err)
		}
		if parsed.Header != vectorHeader(c) {
			t.Errorf("%s: parsed header mismatch", c.Name)
		}
		for _, rc := range c.Recipients {
			pt, err := parsed.Decrypt(toID(rc.Account), to32(rc.EncPriv))
			if err != nil || !bytes.Equal(pt, c.Plaintext) {
				t.Errorf("%s: decrypt for %x: %v", c.Name, rc.Account, err)
			}
		}
	}
}

func vectorHeader(c envCase) Header {
	return Header{Flags: c.Flags, ConvID: toID(c.ConvID), SenderAccount: toID(c.SenderAccount), SenderDevice: toID(c.SenderDevice), ClientMsgID: toID(c.ClientMsgID), TimestampMS: c.TimestampMS}
}

func vectorRecipients(c envCase) []Recipient {
	out := make([]Recipient, len(c.Recipients))
	for i, rc := range c.Recipients {
		out[i] = Recipient{Account: toID(rc.Account), EncPub: to32(rc.EncPub)}
	}
	return out
}

func vectorRandomness(c envCase) *randomness {
	r := &randomness{Key: to32(c.MessageKey), Nonce: to24(c.Nonce)}
	for _, rc := range c.Recipients {
		r.Ephemeral = append(r.Ephemeral, to32(rc.EphemeralPriv))
	}
	return r
}

type pwChangeVectors struct {
	Cases []pwChangeCase `json:"cases"`
}

type pwChangeCase struct {
	SignSeed      hexBytes `json:"sign_seed"`
	SignPub       hexBytes `json:"sign_pub"`
	EncPriv       hexBytes `json:"enc_priv"`
	Challenge     hexBytes `json:"challenge"`
	Account       hexBytes `json:"account_id"`
	Device        hexBytes `json:"device_id"`
	NewSalt       hexBytes `json:"new_salt"`
	NewAuthKey    hexBytes `json:"new_auth_key"`
	NewKeyBundle  hexBytes `json:"new_key_bundle"`
	SignOutOthers bool     `json:"sign_out_others"`
	Message       hexBytes `json:"message"`
	Signature     hexBytes `json:"signature"`
}

// TestVectorsPasswordChange pins the bytes a client signs to change its
// password without the old one (PROTOCOL.md §3.2): all three clients must
// build the same message, or the server will reject their proof.
func TestVectorsPasswordChange(t *testing.T) {
	if *update {
		d := newDet("pwchange")
		var v pwChangeVectors
		for i := 0; i < 3; i++ {
			c := pwChangeCase{
				SignSeed: d.bytes(32), EncPriv: d.bytes(32), Challenge: d.bytes(PasswordChangeChallengeSize),
				Account: d.bytes(16), Device: d.bytes(16), NewSalt: d.bytes(SaltSize), NewAuthKey: d.bytes(32),
				SignOutOthers: i%2 == 0,
			}
			k, err := AccountKeysFromSecrets(to32(c.SignSeed), to32(c.EncPriv))
			if err != nil {
				t.Fatal(err)
			}
			c.SignPub = k.SignPub[:]
			c.NewKeyBundle = SealKeyBundle(to32(d.bytes(32)), to24(d.bytes(NonceSize)), k)
			msg, err := PasswordChangeMessage(c.Challenge, toID(c.Account), toID(c.Device), c.NewSalt, c.NewAuthKey, c.NewKeyBundle, c.SignOutOthers)
			if err != nil {
				t.Fatal(err)
			}
			c.Message = msg
			c.Signature = k.Sign(msg)
			v.Cases = append(v.Cases, c)
		}
		writeVectors(t, "pwchange.json", v)
		return
	}
	var v pwChangeVectors
	readVectors(t, "pwchange.json", &v)
	for i, c := range v.Cases {
		k, err := AccountKeysFromSecrets(to32(c.SignSeed), to32(c.EncPriv))
		if err != nil {
			t.Fatal(err)
		}
		msg, err := PasswordChangeMessage(c.Challenge, toID(c.Account), toID(c.Device), c.NewSalt, c.NewAuthKey, c.NewKeyBundle, c.SignOutOthers)
		if err != nil {
			t.Fatalf("pwchange case %d: %v", i, err)
		}
		if !bytes.Equal(msg, c.Message) {
			t.Errorf("pwchange case %d: signed message mismatch", i)
		}
		if !bytes.Equal(k.Sign(msg), c.Signature) {
			t.Errorf("pwchange case %d: signature mismatch", i)
		}
		if !VerifyPasswordChange(to32(c.SignPub), c.Signature, c.Challenge, toID(c.Account), toID(c.Device), c.NewSalt, c.NewAuthKey, c.NewKeyBundle, c.SignOutOthers) {
			t.Errorf("pwchange case %d: does not verify", i)
		}
		// Every field is bound: flipping the instruction breaks the proof.
		if VerifyPasswordChange(to32(c.SignPub), c.Signature, c.Challenge, toID(c.Account), toID(c.Device), c.NewSalt, c.NewAuthKey, c.NewKeyBundle, !c.SignOutOthers) {
			t.Errorf("pwchange case %d: sign_out_others is not covered by the signature", i)
		}
		other := append([]byte(nil), c.Challenge...)
		other[0] ^= 1
		if VerifyPasswordChange(to32(c.SignPub), c.Signature, other, toID(c.Account), toID(c.Device), c.NewSalt, c.NewAuthKey, c.NewKeyBundle, c.SignOutOthers) {
			t.Errorf("pwchange case %d: challenge is not covered by the signature", i)
		}
	}
}
