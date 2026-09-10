# Family Messenger (E2E)

A minimalist self-hosted messenger with end-to-end encryption, 1:1 voice and
video calls, group voice channels and screen sharing. One Go binary, one
SQLite file, installed with one command from a prebuilt release (Docker and
building from source stay as options).

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

## Server requirements

The server is one static Go binary with an embedded SQLite database, so the
requirements are modest. Figures were measured on the reference VPS (1 vCPU,
1 GB RAM, Debian 13) after a day of family use.

| | Minimum | Notes |
|---|---|---|
| CPU and RAM | 1 vCPU, 512 MB | At rest the server holds about 12 MB of memory, Caddy about 50 MB, coturn about 10 MB; the CPU stays idle unless calls are relayed. The default install downloads a prebuilt server, so nothing is compiled; only the *source* flavour needs about 2 GB for the build, which the installer covers with a temporary swap file |
| Disk | 500 MB free | Release install: about 100 MB of binaries (server with the web client inside, Caddy, coturn). Source install adds about 1 GB for the Go and Node toolchain (build time only); Docker install: about 1.2 GB of images. Add the space you expect for attachments, they are stored as files under the data directory |
| System | Linux with systemd, or Docker | The installer handles Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE and Alpine (Docker flavour), on amd64 and arm64 |
| Network | Public IPv4, a DNS name, open ports 80/tcp, 443/tcp+udp, 3478/tcp+udp and 49160-49200/udp | The DNS name gets a Let's Encrypt certificate automatically (a bare IP works with a self-signed one, browsers warn); 3478 and the UDP range serve STUN/TURN for calls |
| Bandwidth | Small | Messages and attachments are tiny. Calls, voice channels and screen streams flow peer to peer and touch the server only when a direct connection is impossible; then TURN relays about 100 kbps per audio stream and 1-3 Mbps per shared screen |

## One-line install (Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/william-aqn/family-messenger-e2e/main/deploy/install.sh | sudo sh
```

The script asks how to run the messenger, asks for the domain and public IP,
starts everything and prints the first invite code. Three flavours (the
answer is remembered in `/opt/family-messenger-e2e/deploy/.env`):

- **release** (default): downloads the newest prebuilt server from
  [GitHub Releases](https://github.com/william-aqn/family-messenger-e2e/releases),
  one static binary with the web client inside, verified against the
  release's `sha256sums.txt`; fetches Caddy as a static binary and installs
  coturn from the distribution. Nothing is compiled and no Docker is needed,
  so a 1 vCPU / 512 MB box is enough. `RELEASE=v0.2.0` pins a version and
  `MSGR_BINARY_URL` points at any other `server-linux-<arch>` binary.
- **docker**: installs Docker if needed, builds the server image from the
  checkout (no prebuilt image is published; `MSGR_IMAGE=` runs one of your
  own) and runs Caddy, the server and coturn as containers.
- **source**: like release, but the server is compiled on the machine from
  the checkout in `/opt/family-messenger-e2e` (Go and Node are downloaded into
  `toolchain/` unless the system already has them; a small VPS gets a
  temporary swap file for the build).

The release and source flavours run as systemd units `family-messenger`,
`family-messenger-caddy` and `coturn` under the `family-messenger` user with
data in `/var/lib/family-messenger`; `family-messenger invite -n 3`,
`family-messenger admin list` and `family-messenger version` wrap the
server's subcommands.

Answers can come from the environment for a non-interactive run:
`INSTALL_MODE=release DOMAIN=chat.example.com EXTERNAL_IP=... | sudo -E sh`
(also `TURN_SECRET`, `MSGR_REGISTRATION`, `RELEASE`). Running
`sudo sh deploy/install.sh` inside a checkout installs that checkout as it is
(source or docker flavour), which is handy for testing local changes on a
server.

### Updating

```bash
sudo family-messenger update
```

fetches the newest installer and updates the installed flavour in place: the
newest release, the newest image, or a fresh build of `main`. The `.env`
answers are kept; `INSTALL_MODE=release family-messenger update` moves a
source or Docker install over to releases. Update detection:

- **Server**: checks GitHub for a new release every six hours (disable with
  `MSGR_UPDATE_CHECK=0`, point forks elsewhere with `MSGR_UPDATE_REPO`). The
  admin panel's overview shows the newest release next to the running version
  with a link to its notes.
- **Web client**: receives the server's version with every connection and
  shows a *reload the page* bar when the page it is running is older than the
  server, so nobody keeps a stale client after an update.
- **Flutter app**: asks GitHub Releases at start and every six hours (and on
  *Settings → Check for updates*). On Windows and Linux it downloads the
  archive for its platform, verifies the checksum, swaps the files in place
  once the app has closed and starts the new version; on Android, macOS and
  iOS it opens the release page. Development builds (version `dev` or a
  commit hash) are never nagged.

## Manual install (Docker Compose)

Requirements: a Linux host with Docker, a DNS name pointing to it, and open
ports 80, 443 (TCP), 3478 (TCP+UDP) and 49160-49200 (UDP) for calls.

```bash
git clone https://github.com/william-aqn/family-messenger-e2e.git
cd family-messenger-e2e/deploy
cp .env.example .env        # set DOMAIN, EXTERNAL_IP, TURN_SECRET
docker compose up -d --build
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
secret). The compose file builds the server image from the checkout; after a
`git pull`, `docker compose up -d --build` rebuilds it. Set `MSGR_IMAGE` in
`.env` to run a prebuilt image of your own instead.

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
| `MSGR_UPDATE_CHECK` | on | `0` stops the six-hourly check of GitHub Releases shown in the admin panel |
| `MSGR_UPDATE_REPO` | `william-aqn/family-messenger-e2e` | GitHub repository whose releases are checked (for forks) |

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

### Releases

Nothing runs on push. The single workflow `.github/workflows/release.yml` is
started by hand from the *Actions* tab with a version such as `v0.2.0` and
two boxes, *pre-release* and *run tests*. It builds the server for
linux/amd64, linux/arm64, windows/amd64, darwin/amd64 and darwin/arm64 with
the web client embedded, the Windows, Linux and macOS desktop apps, the
Android APK and App Bundle and an unsigned iOS app; then it writes
`sha256sums.txt`, creates the tag on the chosen commit and publishes a GitHub
Release. With *run tests* ticked the Go, web unit, browser and Flutter tests
run in parallel with the builds and a failure blocks the release. That
release is what the installer's *release* flavour and the app's updater
download, so the version string is what users see as their build number. The
Linux jobs and the tests run on the repository's self-hosted runner (label
`self-hosted`), the other platforms on GitHub-hosted machines. No Docker
image is published: the Docker flavour builds it on the server.

Every build carries its version: `--dart-define=APP_VERSION` for the app,
`APP_VERSION` at `npm run build` for the web client and the `Version` ldflag
for the server (`family-messenger version` prints it; local builds use
`git describe`).

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

#### Testing video calls without a webcam

- **Built-in test mode**: build with `--dart-define=FAKE_CAMERA=screen` (or
  `build-windows.ps1 -DartDefine FAKE_CAMERA=screen`) and the camera button
  streams the screen instead of a camera, which exercises the whole video
  path on a machine without one.
- **A virtual webcam**: OBS Studio's Virtual Camera shows up as a normal
  camera. `winget install OBSProject.OBSStudio`, then start OBS with
  `obs64.exe --startvirtualcam --minimize-to-tray` from its `bin\64bit`
  folder; any scene (an image, a video file or a browser source with an
  animation) becomes the picture.
- **Automated app-to-browser call**: `scripts\app-video-call-test.ps1` starts a
  throwaway local server, a browser peer with Chromium's fake camera
  (`web/tests/peer`) and the app's integration test
  (`app/integration_test/video_call_test.dart`), which signs up, opens a chat,
  starts a video call and checks that frames flow both ways. Add
  `-Camera screen` to use the built-in test mode instead of a real or virtual
  camera. The test never touches the device's stored session.

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
2. **GitHub Actions** (`.github/workflows/release.yml`): started by hand from
   the Actions tab with a version such as `v0.2.0`; it builds the Windows zip,
   the Linux and macOS desktop bundles, the APK/App Bundle, an unsigned iOS
   app and the server binaries, writes `sha256sums.txt`, creates the tag and
   attaches everything to a GitHub Release (see *Releases* above). Nothing
   needs to be installed locally.
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
.github/          release.yml, the only workflow: manual; tests, every binary and the GitHub Release
```

## Roadmap

Local message database and push notifications for the Flutter app (FCM /
UnifiedPush, APNs); iOS broadcast extension for screen sharing; group calls
through an SFU; recovery keys and device pairing by QR; message editing and
deletion; admin panel and bot management inside the Flutter app.

## License

MIT
