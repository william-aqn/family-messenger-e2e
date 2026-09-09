# Family Messenger (E2E)

A minimalist self-hosted messenger with end-to-end encryption, 1:1 voice calls
and screen sharing. One Go binary, one SQLite file, deployable with
`docker compose`.

- **End-to-end encrypted** direct and group chats (up to 100 members) with
  encrypted attachments (photos, documents, any files). The server stores only
  ciphertext; see [protocol/PROTOCOL.md](protocol/PROTOCOL.md).
- **Voice calls with screen sharing** over WebRTC (DTLS-SRTP), signaling inside
  the encrypted channel, NAT traversal through the bundled coturn.
- **Multi-device**: sign in on a phone and a PC with the same account; new
  devices read the full history after login.
- **Disappearing messages** per conversation (1 hour to 30 days) plus an
  optional server-wide retention limit.
- **Bots** with webhooks or long polling, created by any user and usable in
  direct chats and groups ([docs/BOTS.md](docs/BOTS.md)).
- **Admin panel**: users, invites, registration mode, limits, announcement,
  statistics, one-click database backup and a switch for the user directory
  (the user list and name suggestions everyone sees when starting a chat).
- **Group voice channels**: any member joins the group's channel whenever they
  like, no ringing; audio flows peer-to-peer (mesh), so it stays end-to-end
  encrypted.
- **Web client** in English and Russian (more languages are one file away);
  works as a PWA on desktop and mobile browsers.
- **Flutter app** for Android, iOS, Windows, Linux and macOS from one codebase
  (`app/`), sharing the protocol test vectors with the server and the web client.

## One-line install (Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/william-aqn/family-messenger-e2e/main/deploy/install.sh | sudo sh
```

The script clones the repository into `/opt/family-messenger-e2e`, asks how
to run the messenger, asks for the domain and public IP, starts everything
and prints the first invite code. Run it again to update. Two flavours:

- **docker** (default): installs Docker if needed, pulls the prebuilt image
  from GHCR (or builds it locally) and runs Caddy, the server and coturn as
  containers.
- **native**: no Docker. The server is compiled on the machine (Go and Node
  are downloaded into `/opt/family-messenger-e2e/toolchain` unless the system
  already has them; a small VPS gets a temporary swap file for the build),
  Caddy is fetched as a static binary and coturn comes from the distribution.
  Everything runs as systemd units `family-messenger`,
  `family-messenger-caddy` and `coturn` under the `family-messenger` user with
  data in `/var/lib/family-messenger`; `family-messenger invite -n 3` and
  `family-messenger admin list` wrap the server's subcommands. Set
  `MSGR_BINARY_URL` to a prebuilt `server-linux-<arch>` (from a GitHub
  Release) to skip the compilation.

Answers can come from the environment for a non-interactive run:
`INSTALL_MODE=native DOMAIN=chat.example.com EXTERNAL_IP=... | sudo -E sh`
(also `TURN_SECRET`, `MSGR_REGISTRATION`). Running `sudo sh deploy/install.sh`
inside a checkout installs that checkout as it is, which is handy for testing
local changes on a server.

## Manual install (Docker Compose)

Requirements: a Linux host with Docker, a DNS name pointing to it, and open
ports 80, 443 (TCP), 3478 (TCP+UDP) and 49160-49200 (UDP) for calls.

```bash
git clone https://github.com/william-aqn/family-messenger-e2e.git
cd family-messenger-e2e/deploy
cp .env.example .env        # set DOMAIN, EXTERNAL_IP, TURN_SECRET
docker compose up -d
```

Open `https://<DOMAIN>` and create the first account: **the first account
becomes the administrator**. Then open *Settings → Admin panel* to create
invite codes (registration is invite-only by default), change the
registration mode, set an announcement or adjust limits. The same can be done
from the shell:

```bash
docker compose exec server /server invite -n 3 -note friends -days 7
docker compose exec server /server admin grant alice
```

Caddy obtains TLS certificates automatically; with `DOMAIN=localhost` it uses
its own local CA for a LAN test. Backups: download one from the admin panel or
copy the `server_data` volume (one SQLite database, attachments and the server
secret). The compose file uses the prebuilt image `ghcr.io/william-aqn/family-messenger-e2e`;
remove `MSGR_IMAGE` from `.env` and run `docker compose up -d --build` to build from source.

### Server configuration

| Variable | Default | Meaning |
|---|---|---|
| `MSGR_ADDR` | `:8080` | Listen address |
| `MSGR_DATA_DIR` | `./data` | SQLite database, attachments and `server.secret` |
| `MSGR_REGISTRATION` | `invite` | Initial mode: `open`, `invite` or `closed` (the admin panel setting overrides it) |
| `MSGR_TURN_URLS` | – | Comma-separated `turn:` URLs handed to clients |
| `MSGR_TURN_SECRET` | – | coturn `static-auth-secret` (enables TURN credentials) |
| `MSGR_TURN_TTL` | `1h` | Lifetime of issued TURN credentials |
| `MSGR_STUN_URLS` | – | Comma-separated `stun:` URLs |
| `MSGR_PUBLIC_URL` | – | Public origin, informational |
| `MSGR_WEB_DIR` | embedded | Serve the web client from a directory instead of the binary |
| `MSGR_SERVER_SECRET` | generated | HMAC key for anti-enumeration salts (persisted in the data dir when generated) |
| `MSGR_LOG_JSON`, `MSGR_DEBUG` | off | JSON logs, debug logging |

Runtime settings (registration mode, attachment size limit, global retention,
bots on/off, group size, announcement) live in the database and are edited in
the admin panel.

## How the encryption works (short version)

Every account has an Ed25519 signing key and an X25519 encryption key,
generated in the client. The private keys are stored on the server only inside
a bundle encrypted with a key derived from the password (Argon2id, 64 MiB);
the server receives a different, independent Argon2id output as the login
secret and never sees the password or the bundle key.

Each message is encrypted with a fresh random key (XChaCha20-Poly1305). That
key is sealed to every member of the conversation with X25519 + HKDF, and the
whole envelope is signed by the sender. Attachments are encrypted the same way
with their own key carried inside the message. Membership changes are signed
events carrying the full roster, so a server cannot silently add a reader.
Users compare safety numbers to rule out key substitution on first contact.

What the server can see: who talks to whom, when, how much, and the
disappearing-messages timer. What it cannot see: message content, file
content, group names, call media or call SDP. The one deliberate exception is
bots: the server holds their keys, so conversations with bots are readable by
the server and are marked as such in the client.

Known limits of v1 (by design, see the protocol document): no forward secrecy
if the account keys leak, because history must stay readable on new devices;
the password is the only lock on the key backup and cannot be reset; screen
sharing from a phone requires the native app.

## Development

Requirements: Go 1.26+, Node 26+.

```bash
go test ./...                     # protocol, store and API tests (admin, bots, attachments, retention)
cd web && npm install && npm test # TypeScript crypto against the shared vectors
npm run build                     # web/dist
```

Run the server serving the built web client (Windows PowerShell helper, or set
the same variables by hand):

```bash
powershell -ExecutionPolicy Bypass -File scripts/dev-server.ps1
```

Browser end-to-end tests (chats, groups, calls with fake media, attachments,
disappearing messages, language switch, admin panel, a webhook bot):

```bash
cd web && npx playwright install chromium && npx playwright test
# or with an installed browser: PW_CHANNEL=msedge npx playwright test
```

Cross-language test vectors live in `protocol/testvectors/` and are generated
by the Go reference implementation:

```bash
go test ./pkg/e2e -run TestVectors -update
```

Adding a UI language: copy `web/src/i18n/en.ts` to `<code>.ts`, translate,
and register it in `web/src/i18n/index.ts` (mobile strings live in
`app/lib/i18n/strings.dart`).

### Flutter app

```bash
cd app
flutter pub get
flutter test                 # Dart crypto against the shared vectors
flutter analyze
flutter run                  # on a connected Android device / emulator
flutter build apk --release  # Android
flutter build windows        # needs Visual Studio "Desktop development with C++"
flutter build linux          # needs clang, cmake, ninja, pkg-config, libgtk-3-dev
flutter build macos / ios    # needs Xcode
```

The app asks for the server URL on the sign-in screen. Screen sharing works on
Android (a foreground service is started automatically), Windows, Linux and
macOS; on iOS it needs a Broadcast Upload Extension, which is not wired up
yet. Message history is fetched from the server on every start (no local
database yet).

### Builder container

A Docker image with Go, Node, Flutter, the Android SDK/NDK and the Linux
desktop toolchain builds every artifact without installing anything on the
host (for Windows and macOS/iOS binaries see the next section):

```bash
docker compose -f deploy/builder/docker-compose.yml build              # once, the image is large
docker compose -f deploy/builder/docker-compose.yml run --rm builder server apk
docker compose -f deploy/builder/docker-compose.yml run --rm builder all   # web, server, apk, linux
docker compose -f deploy/builder/docker-compose.yml run --rm builder shell
```

Targets: `web`, `server` (linux/amd64, linux/arm64, windows/amd64 with the
web client embedded), `apk` (universal APK with all ABIs, about 90 MB, signed
with the debug key: fine for testing, not for stores), `appbundle`, `linux`
(Flutter desktop bundle), `test`. Artifacts land in `dist/`; Gradle, pub, Go
and npm caches persist in named volumes, so the first APK build takes
several minutes and later ones are fast. The host checkout is left untouched
(builds run on staging copies inside the container).

### Windows desktop binary

Flutter's Windows build needs MSVC, which does not exist for Linux, so the
Linux builder above cannot produce it. Three options:

1. **Native script** (`deploy/builder/build-windows.ps1`, no Docker): run it
   on any Windows 10/11 machine and it fetches whatever is missing. Git, the
   Flutter SDK, Node and Go are downloaded as portable zips into
   `%LOCALAPPDATA%\family-messenger-e2e\tools` (only when nothing usable is
   found on PATH or in the usual places); Visual Studio Build Tools 2022 with
   the C++ workload is installed with Microsoft's bootstrapper, which asks for
   administrator rights once (about 7 GB). Flutter also needs Developer Mode
   (Settings > System > For developers) or an elevated shell for plugin
   symlinks.

   ```powershell
   powershell -ExecutionPolicy Bypass -File deploy\builder\build-windows.ps1            # Windows app
   powershell -ExecutionPolicy Bypass -File deploy\builder\build-windows.ps1 all        # + web client and server binaries
   powershell -ExecutionPolicy Bypass -File deploy\builder\build-windows.ps1 doctor -NoInstall
   ```

   Targets: `windows` (default, writes
   `dist\family-messenger-windows-x64-<version>.zip`: unzip and run
   `family_messenger_e2e.exe`), `web`, `server` (Windows and Linux binaries
   with the web client embedded), `all`, `doctor`. `-NoInstall` only reports
   what is missing, `-Portable` ignores tools on PATH and uses the downloaded
   ones, `-ToolsDir` (or `FM_TOOLS_DIR`) moves the tool folder. The
   executable is unsigned, so SmartScreen shows its warning on first start.
2. **GitHub Actions** (`.github/workflows/release.yml`): pushing a tag such as
   `v0.1.0` (or running the workflow manually from the Actions tab) builds the
   Windows zip, the Linux and macOS desktop bundles, the APK/App Bundle, an
   unsigned iOS app and the server binaries, and attaches them to a GitHub
   Release. Nothing needs to be installed locally.
3. **Windows container** (`deploy/builder/windows/`): a Windows Server Core
   image with Visual Studio Build Tools 2022 and the Flutter SDK. It needs a
   Windows 10/11 Pro or Enterprise host with the Windows features *Hyper-V*
   and *Containers* enabled and Docker Desktop (all-users install) switched to
   Windows containers, so it cannot run on a Linux CI box.

   ```powershell
   & "C:\Program Files\Docker\Docker\DockerCli.exe" -SwitchWindowsEngine   # once; -SwitchLinuxEngine to go back
   powershell -ExecutionPolicy Bypass -File deploy\builder\windows\build.ps1
   ```

   The first run builds the image (about 10 GB, 30-60 minutes; later runs
   reuse it, add `-SkipImageBuild` to skip the check entirely) and writes
   `dist/family-messenger-windows-x64-<version>.zip`. The script also works
   without switching when Docker Desktop exposes a running Windows engine
   next to the Linux one, and explains what is missing otherwise.

The macOS and iOS apps still need a Mac (or the GitHub Actions workflow).

## Layout

```
cmd/server        server binary (+ `invite` and `admin` subcommands)
pkg/e2e           reference implementation of the E2E protocol
internal/         config, SQLite store, settings, auth, HTTP/WebSocket API, bot bridge, TURN credentials
web/              Vite + Preact client (crypto in web/src/crypto, translations in web/src/i18n)
app/              Flutter client for Android, iOS, Windows, Linux, macOS (crypto in app/lib/crypto)
protocol/         PROTOCOL.md and shared test vectors
docs/             BOTS.md (Bot API)
deploy/           docker-compose.yml, Caddyfile, .env.example, install.sh (one-line installer)
deploy/builder/   Linux builder image (server, web, APK, Linux desktop) and windows/ (Flutter Windows build)
.github/          ci.yml (tests), publish.yml (server image to GHCR), release.yml (all client binaries)
```

## Roadmap

Local message database and push notifications for the Flutter app (FCM /
UnifiedPush, APNs); iOS broadcast extension for screen sharing; group calls
through an SFU; recovery keys and device pairing by QR; message editing and
deletion; admin panel and bot management inside the Flutter app.

## License

MIT
