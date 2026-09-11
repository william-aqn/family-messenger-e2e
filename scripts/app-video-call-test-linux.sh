#!/bin/sh
# Runs the app's video-call scenario on Linux inside the builder container
# (deploy/builder): a virtual X screen (Xvfb), PulseAudio null devices in
# place of a microphone and speakers, the Go server on $PORT and the
# integration test with the screen standing in for the camera. The browser
# peer runs elsewhere, for example Playwright on the Windows host:
#
#   docker run --rm -p 18082:18082 -v E:\ai\messanger:/src:ro -v <shots>:/out family-messenger-e2e-builder sh /src/scripts/app-video-call-test-linux.sh
#   (then, on the host)  cd web && TEST_BASE_URL=http://127.0.0.1:18082 TEST_USER=<app user> TEST_PEER=<peer> PW_CHANNEL=msedge npx playwright test tests/peer/app-peer.spec.ts --config playwright.peer.config.ts
#
# The user names are written to $OUT/peer.env; screenshots of the X screen
# land in $OUT every few seconds while the test runs.
set -eu
PORT=${PORT:-18082}
RUN=${RUN:-$(date +%s | tail -c 6)}
APP_USER=${APP_USER:-appalice$RUN}
PEER=${PEER:-appbob$RUN}
OUT=${OUT:-/out}
SRC=${SRC:-/src}
WORK=${WORK:-/work}
mkdir -p "$OUT"

if ! command -v Xvfb >/dev/null 2>&1; then
  echo "==> installing the virtual screen, audio and screenshot tools"
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends xvfb x11-apps x11-utils imagemagick pulseaudio pulseaudio-utils \
    libpulse0 libasound2t64 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxtst6 libxss1 libgbm1 libnss3 >/dev/null
fi

echo "==> virtual screen and audio"
Xvfb :99 -screen 0 1600x900x24 -nolisten tcp >/dev/null 2>&1 &
export DISPLAY=:99
sleep 1
# PulseAudio as root only warns; a null sink's monitor serves as the microphone.
pulseaudio --daemonize=yes --exit-idle-time=-1 --disallow-exit --log-target=file:/tmp/pulse.log 2>/dev/null || true
sleep 1
pactl load-module module-null-sink sink_name=out || true
pactl set-default-sink out || true
pactl set-default-source out.monitor || true
pactl list short sources || true

echo "==> sources: a clean copy of the repository (the mount is slow and shared with the host)"
if [ ! -d "$WORK/.git" ]; then git clone -q "$SRC" "$WORK"; fi
git -C "$WORK" pull -q 2>/dev/null || true
mkdir -p "$WORK/web/dist" && cp -r "$SRC/web/dist/." "$WORK/web/dist/"

echo "==> server on :$PORT"
cd "$WORK"
MSGR_ADDR="0.0.0.0:$PORT" MSGR_DATA_DIR=/tmp/fm-data MSGR_REGISTRATION=open MSGR_WEB_DIR="$WORK/web/dist" go run ./cmd/server >"$OUT/server.log" 2>&1 &
for i in $(seq 1 120); do
  if curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null
echo "APP_USER=$APP_USER" >"$OUT/peer.env"
echo "PEER=$PEER" >>"$OUT/peer.env"
echo "==> peer names: app=$APP_USER peer=$PEER (written to $OUT/peer.env)"

echo "==> screenshots of the X screen every 3 s"
(
  i=0
  while true; do
    import -window root "$OUT/linux-$(printf %03d $i).png" 2>/dev/null || true
    i=$((i + 1))
    sleep 3
  done
) &
SHOTS=$!

echo "==> app integration test on Linux (the screen is the camera)"
cd "$WORK/app"
flutter pub get >/dev/null
set +e
flutter test integration_test/video_call_test.dart -d linux \
  --dart-define="TEST_SERVER=http://127.0.0.1:$PORT" --dart-define="TEST_USER=$APP_USER" --dart-define="TEST_PEER=$PEER" \
  --dart-define=FAKE_CAMERA=screen
STATUS=$?
set -e
kill $SHOTS 2>/dev/null || true
echo "==> app test exit $STATUS"
exit $STATUS
