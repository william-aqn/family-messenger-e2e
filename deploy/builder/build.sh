#!/bin/sh
# Build targets for the builder container (deploy/builder). The repository is
# mounted at /src; artifacts land in /src/dist. Web and Flutter builds run on
# staging copies under /tmp so the host checkout keeps its own node_modules,
# .dart_tool and build directories intact.
set -eu

SRC=/src
OUT=$SRC/dist
cd "$SRC"
mkdir -p "$OUT"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
LDFLAGS="-s -w -X github.com/william-aqn/family-messenger-e2e/internal/api.Version=$VERSION"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

usage() {
  cat <<EOF
Usage: build <target>...

  web         web client -> web/dist (embedded into the server binaries)
  server      server binaries for linux/amd64, linux/arm64, windows/amd64 -> dist/
  apk         Android APK (release) -> dist/
  appbundle   Android App Bundle (release, for Google Play) -> dist/
  linux       Flutter Linux desktop bundle -> dist/*.tar.gz
  test        go test, web unit tests, flutter analyze + test
  all         web server apk linux
  shell       interactive shell inside the container

Version stamp: $VERSION
EOF
}

stage_web() {
  rm -rf /tmp/web && mkdir -p /tmp/web
  tar -C "$SRC/web" --exclude=node_modules --exclude=dist --exclude=test-results --exclude=playwright-report -cf - . | tar -C /tmp/web -xf -
}

stage_app() {
  rm -rf /tmp/app && mkdir -p /tmp/app
  tar -C "$SRC/app" --exclude=build --exclude=.dart_tool --exclude=.idea -cf - . | tar -C /tmp/app -xf -
  # The app reads the shared vectors from ../protocol during tests.
  rm -rf /tmp/protocol && cp -r "$SRC/protocol" /tmp/protocol
}

web() {
  say "web client"
  stage_web
  (cd /tmp/web && npm ci --no-audit --no-fund && npm run build)
  rm -rf "$SRC/web/dist" && cp -r /tmp/web/dist "$SRC/web/dist"
  mkdir -p "$SRC/internal/webui/dist"
  find "$SRC/internal/webui/dist" -mindepth 1 -not -name .keep -exec rm -rf {} + 2>/dev/null || true
  cp -r /tmp/web/dist/. "$SRC/internal/webui/dist/"
}

server() {
  [ -f "$SRC/internal/webui/dist/index.html" ] || web
  for target in linux/amd64 linux/arm64 windows/amd64; do
    os=${target%/*}
    arch=${target#*/}
    ext=""
    [ "$os" = windows ] && ext=.exe
    say "server $os/$arch"
    CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/server-$os-$arch$ext" ./cmd/server
  done
}

apk() {
  say "Android APK"
  stage_app
  (cd /tmp/app && flutter pub get && flutter build apk --release)
  cp /tmp/app/build/app/outputs/flutter-apk/app-release.apk "$OUT/family-messenger-$VERSION.apk"
}

appbundle() {
  say "Android App Bundle"
  stage_app
  (cd /tmp/app && flutter pub get && flutter build appbundle --release)
  cp /tmp/app/build/app/outputs/bundle/release/app-release.aab "$OUT/family-messenger-$VERSION.aab"
}

linux() {
  say "Flutter Linux desktop"
  stage_app
  (cd /tmp/app && flutter pub get && flutter build linux --release)
  tar -C /tmp/app/build/linux/x64/release -czf "$OUT/family-messenger-linux-x64-$VERSION.tar.gz" bundle
}

test() {
  say "go test"
  go vet ./... && go test ./...
  say "web unit tests"
  stage_web
  (cd /tmp/web && npm ci --no-audit --no-fund && npm test)
  say "flutter analyze + test"
  stage_app
  (cd /tmp/app && flutter pub get && flutter analyze && flutter test)
}

[ $# -gt 0 ] || { usage; exit 1; }
for target in "$@"; do
  case "$target" in
    web) web ;;
    server) server ;;
    apk) apk ;;
    appbundle) appbundle ;;
    linux) linux ;;
    test) test ;;
    all) web; server; apk; linux ;;
    shell) exec /bin/bash ;;
    help | -h | --help) usage ;;
    *) echo "unknown target: $target" >&2; usage; exit 1 ;;
  esac
done
say "done: $(ls -1 "$OUT" 2>/dev/null | tr '\n' ' ')"
