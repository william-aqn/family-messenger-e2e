// Message envelopes, PROTOCOL.md §5.
import 'dart:typed_data';

import 'bytes.dart';
import 'ids.dart';
import 'primitives.dart';
import 'seal.dart';

const int envelopeVersion = 1;
const int flagEphemeral = 1 << 0;
const int flagUrgent = 1 << 1;
const int maxRecipients = 100;
const int maxEnvelopeSize = 64 * 1024;

const int _fixedHeader = 1 + 1 + 4 * 16 + 8 + 2; // 76
const int _recipientEntry = 16 + sealedKeySize; // 96
const int _minEnvelope = _fixedHeader + _recipientEntry + nonceSize + 4 + tagSize;
final Uint8List _sigPrefix = utf8Encode('msgr-env-v1');

class Header {
  const Header({
    required this.flags,
    required this.convId,
    required this.senderAccount,
    required this.senderDevice,
    required this.clientMsgId,
    required this.timestampMs,
  });

  final int flags;
  final String convId;
  final String senderAccount;
  final String senderDevice;
  final String clientMsgId;
  final int timestampMs;
}

class Recipient {
  const Recipient({required this.account, required this.encPub});

  final String account;
  final Uint8List encPub;
}

class SealedRecipient {
  const SealedRecipient({required this.account, required this.sealedKey});

  final String account;
  final Uint8List sealedKey;
}

class ParsedEnvelope {
  const ParsedEnvelope({
    required this.header,
    required this.recipients,
    required this.nonce,
    required this.ciphertext,
    required this.raw,
    required this.aadLen,
  });

  final Header header;
  final List<SealedRecipient> recipients;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List raw;
  final int aadLen;

  bool isRecipient(String account) => recipients.any((r) => r.account == account);
}

class Envelope {
  const Envelope({required this.env, required this.sig});

  final Uint8List env;
  final Uint8List sig;
}

/// Every random input of encrypt(), injectable for the test vectors.
class Randomness {
  const Randomness({required this.key, required this.nonce, required this.ephemeral});

  final Uint8List key;
  final Uint8List nonce;
  final List<Uint8List> ephemeral;
}

// 64-bit big-endian helpers that also work on the web (no setUint64 there).
void _setUint64(ByteData view, int off, int value) {
  view.setUint32(off, value ~/ 0x100000000, Endian.big);
  view.setUint32(off + 4, value & 0xffffffff, Endian.big);
}

int _getUint64(ByteData view, int off) => view.getUint32(off, Endian.big) * 0x100000000 + view.getUint32(off + 4, Endian.big);

Future<Envelope> encryptWith(
  List<int> signSeed,
  Header hdr,
  List<Recipient> recipients,
  List<int> plaintext,
  Randomness r,
) async {
  final n = recipients.length;
  if (n < 1 || n > maxRecipients) throw ArgumentError('invalid recipient count');
  if (r.ephemeral.length != n) throw ArgumentError('ephemeral key count mismatch');
  final size = _fixedHeader + n * _recipientEntry + nonceSize + 4 + plaintext.length + tagSize;
  if (size > maxEnvelopeSize) throw ArgumentError('envelope too large');

  final buf = Uint8List(size);
  final view = ByteData.view(buf.buffer);
  var off = 0;
  buf[off++] = envelopeVersion;
  buf[off++] = hdr.flags & 0xff;
  final convId = uuidToBytes(hdr.convId);
  buf.setRange(off, off + 16, convId);
  off += 16;
  buf.setRange(off, off + 16, uuidToBytes(hdr.senderAccount));
  off += 16;
  buf.setRange(off, off + 16, uuidToBytes(hdr.senderDevice));
  off += 16;
  buf.setRange(off, off + 16, uuidToBytes(hdr.clientMsgId));
  off += 16;
  _setUint64(view, off, hdr.timestampMs < 0 ? 0 : hdr.timestampMs);
  off += 8;
  view.setUint16(off, n, Endian.big);
  off += 2;
  for (var i = 0; i < n; i++) {
    final rc = recipients[i];
    final account = uuidToBytes(rc.account);
    buf.setRange(off, off + 16, account);
    off += 16;
    final box = await sealWith(r.ephemeral[i], rc.encPub, convId, account, r.key);
    buf.setRange(off, off + sealedKeySize, box);
    off += sealedKeySize;
  }
  buf.setRange(off, off + nonceSize, r.nonce);
  off += nonceSize;
  final aad = Uint8List.fromList(buf.sublist(0, off));
  view.setUint32(off, plaintext.length + tagSize, Endian.big);
  off += 4;
  final ct = await aeadEncrypt(r.key, r.nonce, aad, plaintext);
  buf.setRange(off, off + ct.length, ct);
  final sig = await sign(signSeed, concat([_sigPrefix, buf]));
  return Envelope(env: buf, sig: sig);
}

Future<Envelope> encrypt(List<int> signSeed, Header hdr, List<Recipient> recipients, List<int> plaintext) =>
    encryptWith(
      signSeed,
      hdr,
      recipients,
      plaintext,
      Randomness(key: randomBytes(keySize), nonce: randomBytes(nonceSize), ephemeral: [for (final _ in recipients) randomBytes(32)]),
    );

Future<bool> verifyEnvelope(List<int> senderSignPub, List<int> env, List<int> sig) =>
    verify(senderSignPub, concat([_sigPrefix, env]), sig);

/// Structural validation only; verify the signature separately.
ParsedEnvelope parse(Uint8List env) {
  if (env.length > maxEnvelopeSize) throw const FormatException('envelope too large');
  if (env.length < _minEnvelope) throw const FormatException('malformed envelope');
  if (env[0] != envelopeVersion) throw const FormatException('unsupported envelope version');
  final view = ByteData.view(env.buffer, env.offsetInBytes, env.length);
  final n = view.getUint16(74, Endian.big);
  if (n < 1 || n > maxRecipients) throw const FormatException('invalid recipient count');
  var off = _fixedHeader;
  if (env.length < off + n * _recipientEntry + nonceSize + 4 + tagSize) throw const FormatException('malformed envelope');
  final recipients = <SealedRecipient>[];
  for (var i = 0; i < n; i++) {
    recipients.add(SealedRecipient(
      account: bytesToUuid(env.sublist(off, off + 16)),
      sealedKey: env.sublist(off + 16, off + _recipientEntry),
    ));
    off += _recipientEntry;
  }
  final nonce = env.sublist(off, off + nonceSize);
  off += nonceSize;
  final aadLen = off;
  final ctLen = view.getUint32(off, Endian.big);
  off += 4;
  if (ctLen < tagSize || env.length - off != ctLen) throw const FormatException('malformed envelope');
  return ParsedEnvelope(
    header: Header(
      flags: env[1],
      convId: bytesToUuid(env.sublist(2, 18)),
      senderAccount: bytesToUuid(env.sublist(18, 34)),
      senderDevice: bytesToUuid(env.sublist(34, 50)),
      clientMsgId: bytesToUuid(env.sublist(50, 66)),
      timestampMs: _getUint64(view, 66),
    ),
    recipients: recipients,
    nonce: nonce,
    ciphertext: env.sublist(off),
    raw: env,
    aadLen: aadLen,
  );
}

/// Throws when the account is not a recipient or authentication fails.
Future<Uint8List> decrypt(ParsedEnvelope e, String account, List<int> encPriv) async {
  SealedRecipient? rc;
  for (final r in e.recipients) {
    if (r.account == account) {
      rc = r;
      break;
    }
  }
  if (rc == null) throw StateError('not a recipient of this envelope');
  final key = await open(encPriv, uuidToBytes(e.header.convId), uuidToBytes(account), rc.sealedKey);
  return aeadDecrypt(key, e.nonce, e.raw.sublist(0, e.aadLen), e.ciphertext);
}
