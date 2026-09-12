// A GitHub-shaped release server, so the app's updater can be driven end to end
// without publishing anything. It answers the three requests the updater makes:
// the /releases/latest metadata, the release's sha256sums.txt, and the asset
// itself.
//
// Android, from the repository root, with an emulator or a phone on adb:
//
//   cd app
//   flutter build apk --release --target-platform android-x64 \
//     --build-name=0.0.1 --build-number=1 --dart-define=APP_VERSION=v0.0.1 \
//     --dart-define=UPDATE_API_BASE=http://127.0.0.1:18099/api \
//     --dart-define=UPDATE_DOWNLOAD_BASE=http://127.0.0.1:18099/dl
//   # …and the same with 0.0.2 / v0.0.2, which becomes the update
//   mkdir -p /tmp/rig && cp <the 0.0.2 apk> /tmp/rig/family-messenger-v0.0.2.apk
//   cd /tmp/rig && sha256sum family-messenger-v0.0.2.apk > sums-v0.0.2.txt
//   node <repo>/scripts/fake-release.mjs          # serves this folder
//   adb reverse tcp:18099 tcp:18099
//   adb install -r <the 0.0.1 apk>
//
// Both builds must be signed with the same key, which they are when both come
// from the same machine. Corrupt sums-<tag>.txt to check that the checksum is
// really enforced (it fails open when the file is unreachable), and serve an
// APK signed with another key to check the "signed with a different key"
// refusal.
//
//   TAG=v0.0.2 PORT=18099 node scripts/fake-release.mjs
//
// Over loopback a release arrives in a second, which is too fast to see what
// the app shows while it downloads. RATE caps the asset in bytes per second,
// so the progress the UI reports can be watched:
//
//   RATE=2000000 node scripts/fake-release.mjs   # 2 MB/s
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const DIR = process.env.DIR ?? process.cwd();
const TAG = process.env.TAG ?? 'v0.0.2';
const PORT = Number(process.env.PORT ?? 18099);
const NAME = `family-messenger-${TAG}.apk`;
const BASE = `http://127.0.0.1:${PORT}`;
const RATE = Number(process.env.RATE ?? 0);
const APK = path.join(DIR, NAME);
const SUMS = path.join(DIR, `sums-${TAG}.txt`);

// Matched by suffix: the repository path the app puts in the middle of the URL
// does not have to be configured here.
http
  .createServer((req, res) => {
    const url = req.url.split('?')[0];
    console.log(new Date().toISOString(), req.method, url);
    if (url.endsWith('/releases/latest')) {
      const size = fs.statSync(APK).size;
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(
        JSON.stringify({
          tag_name: TAG,
          html_url: `${BASE}/dl/releases/tag/${TAG}`,
          assets: [{ name: NAME, size, browser_download_url: `${BASE}/dl/releases/download/${TAG}/${NAME}` }],
        }),
      );
    }
    if (url.endsWith('/sha256sums.txt')) {
      res.writeHead(200, { 'content-type': 'text/plain' });
      return res.end(fs.readFileSync(SUMS));
    }
    if (url.endsWith(`/${NAME}`)) {
      const size = fs.statSync(APK).size;
      res.writeHead(200, { 'content-type': 'application/vnd.android.package-archive', 'content-length': String(size) });
      // A tenth of a second's worth per chunk when RATE asks for a slow one.
      const stream = RATE > 0 ? fs.createReadStream(APK, { highWaterMark: Math.max(1, Math.round(RATE / 10)) }) : fs.createReadStream(APK);
      if (RATE <= 0) return stream.pipe(res);
      stream.on('data', (chunk) => {
        stream.pause();
        if (!res.write(chunk)) res.once('drain', () => setTimeout(() => stream.resume(), 100));
        else setTimeout(() => stream.resume(), 100);
      });
      stream.on('end', () => res.end());
      return;
    }
    res.writeHead(404);
    res.end('not found');
  })
  .listen(PORT, '127.0.0.1', () => console.log(`fake release server on ${PORT}, serving ${NAME} from ${DIR}`));
