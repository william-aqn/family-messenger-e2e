// Checks GitHub Releases for a newer build. On Windows and Linux the matching
// asset is downloaded, verified against the release's sha256sums.txt and
// swapped in by a small script once the app has exited (then the app is
// started again); other platforms open the release page in the browser.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class ReleaseInfo {
  const ReleaseInfo({required this.tag, required this.url, this.assetName, this.assetUrl, this.assetSize});

  final String tag;
  final String url;
  final String? assetName;
  final String? assetUrl;
  final int? assetSize;
}

class Updater extends ChangeNotifier {
  Updater(this.currentVersion);

  /// GitHub repository holding the releases; forks set UPDATE_REPO at build time.
  static const String repo = String.fromEnvironment('UPDATE_REPO', defaultValue: 'william-aqn/family-messenger-e2e');

  final String currentVersion;

  /// Result of the last check.
  ReleaseInfo? latest;

  /// A release newer than this build, if any.
  ReleaseInfo? available;
  bool checking = false;
  bool installing = false;

  /// Download progress 0..1 while installing.
  double? progress;
  String? error;
  DateTime? checkedAt;
  bool dismissed = false;
  Timer? _timer;

  /// Whether this build is a published release (a tag) rather than a dev build.
  bool get isReleaseBuild => _parse(currentVersion) != null;

  /// Windows and Linux run from a portable folder the app can replace itself.
  static bool get canSelfInstall => !kIsWeb && (Platform.isWindows || Platform.isLinux);

  /// Checks now and every six hours.
  void start() {
    unawaited(check());
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => check());
  }

  void dismiss() {
    dismissed = true;
    notifyListeners();
  }

  static List<int>? _parse(String v) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(v.trim());
    if (m == null) return null;
    return [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)];
  }

  /// True when [tag] is a higher version than [current]; unknown current
  /// versions (development builds) never count as outdated.
  static bool isNewer(String tag, String current) {
    final a = _parse(tag);
    final b = _parse(current);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  /// The release asset for this platform, by name.
  static bool _matchesPlatform(String name) {
    if (kIsWeb) return false;
    if (Platform.isWindows) return name.startsWith('family-messenger-windows-x64-') && name.endsWith('.zip');
    if (Platform.isLinux) return name.startsWith('family-messenger-linux-x64-') && name.endsWith('.tar.gz');
    if (Platform.isMacOS) return name.startsWith('family-messenger-macos-') && name.endsWith('.zip');
    if (Platform.isAndroid) return name.endsWith('.apk');
    return false;
  }

  Future<void> check({bool manual = false}) async {
    if (checking) return;
    checking = true;
    error = null;
    notifyListeners();
    try {
      final res = await http.get(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'family-messenger-app/$currentVersion'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 404) {
        latest = null;
        available = null;
        return;
      }
      if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (j['tag_name'] as String?) ?? '';
      String? assetName;
      String? assetUrl;
      int? assetSize;
      for (final a in ((j['assets'] as List<dynamic>?) ?? const []).cast<Map<String, dynamic>>()) {
        final name = a['name'] as String? ?? '';
        if (_matchesPlatform(name)) {
          assetName = name;
          assetUrl = a['browser_download_url'] as String?;
          assetSize = (a['size'] as num?)?.toInt();
          break;
        }
      }
      latest = ReleaseInfo(tag: tag, url: (j['html_url'] as String?) ?? 'https://github.com/$repo/releases', assetName: assetName, assetUrl: assetUrl, assetSize: assetSize);
      final newer = isNewer(tag, currentVersion);
      if (newer && available?.tag != tag) dismissed = false;
      available = newer ? latest : null;
      checkedAt = DateTime.now();
    } catch (e) {
      error = e.toString();
      if (!manual) debugPrint('update check failed: $e');
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<void> openReleasePage() async {
    final url = latest?.url ?? 'https://github.com/$repo/releases';
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Downloads and installs [latest]. Returns an error message, or null when
  /// the update was handed over and the app is about to exit.
  Future<String?> install() async {
    final rel = latest;
    if (rel == null || rel.assetUrl == null || rel.assetName == null) return 'no download for this platform';
    if (!canSelfInstall) {
      await openReleasePage();
      return null;
    }
    if (installing) return null;
    installing = true;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final tmp = await getTemporaryDirectory();
      final file = File('${tmp.path}${Platform.pathSeparator}${rel.assetName}');
      await _download(Uri.parse(rel.assetUrl!), file, rel.assetSize);
      await _verify(rel, file);
      await _handOver(file);
      return null;
    } catch (e) {
      error = e.toString();
      return error;
    } finally {
      installing = false;
      progress = null;
      notifyListeners();
    }
  }

  Future<void> _download(Uri url, File file, int? expectedSize) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', url)..headers['User-Agent'] = 'family-messenger-app/$currentVersion');
      if (res.statusCode != 200) throw HttpException('download failed: ${res.statusCode}');
      final total = res.contentLength ?? expectedSize;
      final sink = file.openWrite();
      var got = 0;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total != null && total > 0) {
            progress = got / total;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  /// Compares the download with the release's sha256sums.txt when present.
  Future<void> _verify(ReleaseInfo rel, File file) async {
    final sumsUrl = Uri.parse('https://github.com/$repo/releases/download/${rel.tag}/sha256sums.txt');
    http.Response sums;
    try {
      sums = await http.get(sumsUrl).timeout(const Duration(seconds: 20));
    } catch (_) {
      return; // no checksum file reachable: the download came over HTTPS from GitHub
    }
    if (sums.statusCode != 200) return;
    String? expected;
    for (final line in const LineSplitter().convert(sums.body)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts.last == rel.assetName) expected = parts.first;
    }
    if (expected == null) return;
    final digest = await Sha256().hash(await file.readAsBytes());
    final actual = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (actual != expected) throw StateError('checksum mismatch');
  }

  /// Writes the swap-in script, starts it detached and exits the app.
  Future<void> _handOver(File archive) async {
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final tmp = await getTemporaryDirectory();
    if (Platform.isWindows) {
      final script = File('${tmp.path}\\family-messenger-update.ps1');
      await script.writeAsString(r'''
param([int]$AppPid, [string]$Zip, [string]$Dir, [string]$Exe)
$ErrorActionPreference = 'Continue'
try { Wait-Process -Id $AppPid -Timeout 120 } catch {}
Start-Sleep -Seconds 1
$tmp = Join-Path $env:TEMP ("fm-update-" + [guid]::NewGuid())
Expand-Archive -Path $Zip -DestinationPath $tmp -Force
Copy-Item -Path (Join-Path $tmp '*') -Destination $Dir -Recurse -Force
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $Zip -Force -ErrorAction SilentlyContinue
Start-Process -FilePath $Exe -WorkingDirectory $Dir
''');
      await Process.start(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path, '-AppPid', '$pid', '-Zip', archive.path, '-Dir', dir, '-Exe', exe],
        mode: ProcessStartMode.detached,
      );
    } else {
      final script = File('${tmp.path}/family-messenger-update.sh');
      await script.writeAsString(r'''
#!/bin/sh
pid="$1"; tgz="$2"; dir="$3"; exe="$4"
while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
tmp="$(mktemp -d)"
tar -xzf "$tgz" -C "$tmp"
cp -a "$tmp/bundle/." "$dir/"
rm -rf "$tmp" "$tgz"
cd "$dir" && exec "$exe"
''');
      await Process.start('sh', [script.path, '$pid', archive.path, dir, exe], mode: ProcessStartMode.detached);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }
}
