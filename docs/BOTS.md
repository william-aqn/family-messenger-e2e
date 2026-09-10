# Bot API

Bots are accounts that talk to your code instead of a person. Any user can
create bots (unless the administrator turned that off), add them to groups or
chat with them 1:1. Bot usernames end with `bot` (for example `weatherbot`).

**Security model.** The server holds a bot's encryption keys and acts as its
end-to-end endpoint: it decrypts what users send to the bot and encrypts the
bot's replies. Everything in a conversation that includes a bot is therefore
readable by the server, and clients show a "🤖 includes a bot" notice there.
Do not add bots to conversations that must stay private from the server.

## Creating a bot

In the web client: *Settings → My bots → Create bot*. Or with the API, as a
signed-in user:

```bash
curl -X POST https://chat.example.com/api/v1/bots \
  -H "Authorization: Bearer <your device token>" \
  -H "Content-Type: application/json" \
  -d '{"username":"weatherbot","display_name":"Weather","webhook_url":"https://example.com/hook"}'
```

Response (the token and the webhook secret are shown only once):

```json
{"bot":{"id":"…","username":"weatherbot","display_name":"Weather","webhook_url":"https://example.com/hook"},
 "token":"<bot token>","webhook_secret":"<hex secret>"}
```

Owner endpoints: `GET /api/v1/bots`, `PATCH /api/v1/bots/{id}`
(`display_name`, `webhook_url`), `POST /api/v1/bots/{id}/rotate` (new token
and secret), `DELETE /api/v1/bots/{id}`.

## Authentication

Every Bot API request carries the bot token:

```
Authorization: Bearer <bot token>
```

`GET /api/v1/bot/me` returns the bot, its owner and whether a webhook is set.
Bots can also call the regular read endpoints (`GET /api/v1/conversations`,
`GET /api/v1/conversations/{id}`).

## Receiving updates

An update is created when a user (not another bot) sends a message in a
conversation the bot belongs to, or when the bot is added to a conversation.

```json
{
  "id": 42,
  "type": "message",            // message | command | file | joined | edited | deleted
  "created_at": 1757400000000,   // ms since epoch
  "bot": {"id": "…", "username": "weatherbot"},
  "conversation": {"id": "…", "kind": "direct", "members": 2},
  "from": {"id": "…", "username": "alice"},
  "message": {
    "id": "…",                   // client message id
    "seq": 7,                    // position in the conversation
    "ts": 1757400000000,
    "text": "/forecast berlin", // for message and command
    "command": "forecast",       // for command: text starting with "/"
    "args": "berlin",
    "file": {                    // for file
      "blob": "…", "key": "…", "nonce": "…",
      "name": "photo.jpg", "mime": "image/jpeg", "size": 12345,
      "download_url": "/api/v1/bot/files/<blob>?key=…&nonce=…&mime=…&name=…"
    }
  }
}
```

`/start@weatherbot` is parsed as command `start`. Updates are kept for seven
days.

Two update types concern earlier messages: `edited` carries the new `text` of
a message the user rewrote (`message.id` is the id of that message, `seq` the
position of the edit), and `deleted` reports a message a user or an
administrator removed (`message.id` and `message.seq` identify it, `from` is
who removed it).

### Option A: webhook (push)

Set `webhook_url` and the server POSTs each update as JSON with these headers:

```
Content-Type: application/json
X-Messenger-Bot: weatherbot
X-Messenger-Signature: sha256=<hex HMAC-SHA256(webhook_secret, raw body)>
```

Verify the signature before trusting the body. Respond with 2xx within 10
seconds; 5xx and 429 are retried after 1 s, 5 s and 30 s. A response body of

```json
{"reply": "Sunny, 24 °C"}
```

is sent back into the same conversation as the bot, which is the simplest way
to build a request/response bot.

Minimal Node.js webhook:

```js
import { createServer } from 'node:http';
import { createHmac, timingSafeEqual } from 'node:crypto';
const secret = process.env.WEBHOOK_SECRET;
createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const expected = 'sha256=' + createHmac('sha256', secret).update(body).digest('hex');
    const got = req.headers['x-messenger-signature'] ?? '';
    if (got.length !== expected.length || !timingSafeEqual(Buffer.from(got), Buffer.from(expected))) {
      res.writeHead(401).end();
      return;
    }
    const update = JSON.parse(body);
    res.setHeader('Content-Type', 'application/json');
    if (update.type === 'command' && update.message.command === 'forecast') {
      res.end(JSON.stringify({ reply: `Forecast for ${update.message.args}: sunny` }));
    } else {
      res.end('{}');
    }
  });
}).listen(8090);
```

### Option B: polling (pull)

Without a public URL, fetch updates with optional long polling
(`wait` up to 30 seconds):

```bash
curl "https://chat.example.com/api/v1/bot/updates?after=42&limit=100&wait=25" \
  -H "Authorization: Bearer <bot token>"
```

```json
{"updates":[{"id":43, "...":"..."}], "next":43}
```

Pass the returned `next` as `after` in the following request.

## Sending messages

```bash
curl -X POST https://chat.example.com/api/v1/bot/messages \
  -H "Authorization: Bearer <bot token>" \
  -H "Content-Type: application/json" \
  -d '{"conversation_id":"<id>","text":"Hello from the bot"}'
```

Use `"username":"alice"` instead of `conversation_id` to message a user
directly (the direct conversation is created if needed). Text is limited to
16000 characters. The response contains `conversation_id`, `seq` and
`message_id`.

## Files

Users' attachments arrive as `file` updates. The server can decrypt them for
the bot: `GET <download_url>` (with the bot token) streams the plaintext with
the original MIME type and file name. The raw encrypted blob is also available
at `GET /api/v1/blobs/{blob}`; decrypt it with XChaCha20-Poly1305 using the
`key`, `nonce` and the associated data `msgr-blob-v1`.

## Limits and behaviour

- Bots never receive messages from other bots.
- Bots cannot create groups or other bots and cannot sign in with a password.
- Disabling the account in the admin panel stops the bot; deleting the owner
  deletes their bots.
- Rotating credentials invalidates the old token immediately.
