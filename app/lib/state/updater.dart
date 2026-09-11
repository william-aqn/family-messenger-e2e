// Checks GitHub Releases for a newer build. On Windows and Linux the matching
// asset is downloaded, verified against the release's sha256sums.txt and
// swapped in by a small script once the app has exited (then the app is
// started again). Android downloads the release APK, verifies it the same way
// and hands it to the system package installer, which asks the user and
// replaces this very package — no store anywhere in the path; other platforms
// open the release page in the browser.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.dart';

/// The hand-over to the Android package installer (see ApkInstaller.kt). Every
/// other platform finishes the install without leaving Dart.
const MethodChannel _installer = MethodChannel('family_messenger/updater');

/// An update refused for a reason of ours rather than the platform's. Its
/// [toString] is the sentence the user reads, with no exception boilerplate
/// wrapped around it.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

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

  /// The two GitHub hosts, overridable the way UPDATE_REPO already is: a fork
  /// points them at its own mirror, and the device check of an update that ends
  /// in the system installer points them at a release served from the machine
  /// running the check. The asset itself is fetched from whatever URL the
  /// release names.
  static const String apiBase = String.fromEnvironment('UPDATE_API_BASE', defaultValue: 'https://api.github.com');
  static const String downloadBase = String.fromEnvironment('UPDATE_DOWNLOAD_BASE', defaultValue: 'https://github.com');

  final String currentVersion;

  /// Result of the last check.
  ReleaseInfo? latest;

  /// A release newer than this build, if any.
  ReleaseInfo? available;
  bool checking = false;
  bool installing = false;

  /// Set once the APK is with the Android package installer: the app has
  /// nothing left to do, it is waiting for the user to answer the system.
  bool handedOver = false;

  /// Download progress 0..1 while installing; null when there is nothing left
  /// to measure.
  double? progress;

  /// Why the last check failed. Install failures are kept apart in
  /// [installError]: the dialog words the two differently, and on Android an
  /// install is refused often enough — the switch that allows it is off until
  /// the user turns it on — for "could not check for updates" to be a lie the
  /// owner would read regularly.
  String? error;
  String? installError;

  /// The platform code behind [installError], for a UI that wants to react to
  /// one particular refusal.
  String? installErrorCode;
  DateTime? checkedAt;
  bool dismissed = false;
  Timer? _timer;

  /// What the Android side answers with when it will not install.
  static const String errNotAllowed = 'install_not_allowed';
  static const String errSignature = 'install_signature_mismatch';
  static const String errAborted = 'install_aborted';
  static const String errFailed = 'install_failed';

  /// Whether this build is a published release (a tag) rather than a dev build.
  bool get isReleaseBuild => _parse(currentVersion) != null;

  /// Platforms that install an update from inside the app: Windows and Linux
  /// replace the portable folder they run from, Android hands the APK to the
  /// system installer. Everywhere else the button only opens the release page.
  static bool get canSelfInstall => installsFromApp(currentPlatform);

  /// Only the desktop swap closes the app and starts the new build itself. The
  /// Android installer stops the app and leaves it stopped, with the system
  /// offering to open it, so the UI must not promise a restart there.
  static bool get restartsItself => restartsAfterInstall(currentPlatform);

  /// The platform the asset names and the install route are chosen by, as a
  /// plain string: the decisions themselves are then functions a test can ask
  /// about any platform, not only about the one it runs on.
  static String get currentPlatform {
    if (kIsWeb) return 'web';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'other';
  }

  static bool installsFromApp(String platform) => platform == 'windows' || platform == 'linux' || platform == 'android';

  static bool restartsAfterInstall(String platform) => platform == 'windows' || platform == 'linux';

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

  /// The release asset for a platform, by name. The Android release carries an
  /// .aab next to the .apk, which is for a store and cannot be installed on a
  /// phone, and the prefix keeps out any other .apk a release might gain.
  static bool matchesAsset(String name, String platform) {
    switch (platform) {
      case 'windows':
        return name.startsWith('family-messenger-windows-x64-') && name.endsWith('.zip');
      case 'linux':
        return name.startsWith('family-messenger-linux-x64-') && name.endsWith('.tar.gz');
      case 'macos':
        return name.startsWith('family-messenger-macos-') && name.endsWith('.zip');
      case 'android':
        return name.startsWith('family-messenger-') && name.endsWith('.apk');
      default:
        return false;
    }
  }

  /// Reads the /releases/latest answer. Pure, so a test can ask what each
  /// platform would take from one and the same release.
  static ReleaseInfo parseRelease(Map<String, dynamic> json, String platform) {
    String? assetName;
    String? assetUrl;
    int? assetSize;
    for (final a in ((json['assets'] as List<dynamic>?) ?? const []).cast<Map<String, dynamic>>()) {
      final name = a['name'] as String? ?? '';
      if (matchesAsset(name, platform)) {
        assetName = name;
        assetUrl = a['browser_download_url'] as String?;
        assetSize = (a['size'] as num?)?.toInt();
        break;
      }
    }
    return ReleaseInfo(
      tag: (json['tag_name'] as String?) ?? '',
      url: (json['html_url'] as String?) ?? 'https://github.com/$repo/releases',
      assetName: assetName,
      assetUrl: assetUrl,
      assetSize: assetSize,
    );
  }

  Future<void> check({bool manual = false}) async {
    if (checking) return;
    checking = true;
    error = null;
    notifyListeners();
    try {
      final res = await http.get(
        Uri.parse('$apiBase/repos/$repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'family-messenger-app/$currentVersion'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 404) {
        latest = null;
        available = null;
        return;
      }
      if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
      latest = parseRelease(jsonDecode(res.body) as Map<String, dynamic>, currentPlatform);
      final tag = latest!.tag;
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

  /// Downloads and installs [latest]. Returns a line for the user, or null when
  /// there is nothing to say: on the desktop the app is about to exit, and on
  /// Android the system installer now owns the APK — a user who closed its
  /// dialog has answered, not failed.
  Future<String?> install() async {
    final rel = latest;
    if (rel == null || rel.assetUrl == null || rel.assetName == null) {
      return t('update_failed', <String, Object?>{'error': 'no download for this platform'});
    }
    // Ahead of the platform branch: on Android the button stays on screen for
    // the length of the download, and two taps must not start two of them.
    if (installing) return null;
    if (!canSelfInstall) {
      await openReleasePage();
      return null;
    }
    // Android installs nothing on behalf of an app the user has not allowed as
    // a source. Ask before spending the download, and put the switch in front
    // of them in the same tap.
    if (Platform.isAndroid && !await _allowedToInstall()) {
      await openInstallSettings();
      installErrorCode = errNotAllowed;
      installError = t('update_install_not_allowed');
      notifyListeners();
      return installError;
    }
    installing = true;
    handedOver = false;
    progress = 0;
    installError = null;
    installErrorCode = null;
    notifyListeners();
    File? file;
    try {
      file = await _stage(rel);
      await _download(Uri.parse(rel.assetUrl!), file, rel.assetSize);
      await _verify(rel, file);
      if (Platform.isAndroid) {
        handedOver = true;
        progress = null;
        notifyListeners();
        // Answers only once the package manager has a verdict, which is after
        // the user has read its confirmation screen. On a yes it kills this
        // process first, so the happy path never answers at all.
        await _installer.invokeMethod<void>('installApk', <String, Object?>{'path': file.path});
        return null;
      }
      await _handOver(file);
      return null;
    } catch (e) {
      // A failed attempt would otherwise leave a release-sized file behind.
      if (file != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
      installErrorCode = e is PlatformException ? e.code : null;
      installError = messageFor(e);
      return installError;
    } finally {
      installing = false;
      handedOver = false;
      progress = null;
      notifyListeners();
    }
  }

  /// The finished line for the user, or null when nothing needs saying. The
  /// answers a person can act on get a sentence of ours, which stands on its
  /// own; everything else is reported as a failure carrying the system's own
  /// wording, which names the actual refusal.
  static String? messageFor(Object e) {
    if (e is! PlatformException) return t('update_failed', <String, Object?>{'error': e.toString()});
    switch (e.code) {
      case errAborted:
        return null;
      case errNotAllowed:
        return t('update_install_not_allowed');
      case errSignature:
        return t('update_signature_mismatch');
      default:
        return t('update_failed', <String, Object?>{'error': e.message ?? e.code});
    }
  }

  /// Whether Android lets this app install packages at all. A channel fault is
  /// read as yes: better to let the installer itself refuse than to block the
  /// update on a question that could not be asked.
  Future<bool> _allowedToInstall() async {
    try {
      return await _installer.invokeMethod<bool>('canInstall') ?? true;
    } catch (e) {
      debugPrint('install permission unknown: $e');
      return true;
    }
  }

  /// Opens the Android screen where this app is allowed to install packages.
  Future<void> openInstallSettings() async {
    try {
      await _installer.invokeMethod<void>('openInstallSettings');
    } catch (e) {
      debugPrint('install settings: $e');
    }
  }

  /// A fresh file for the download. Whatever an earlier attempt left is dropped
  /// first: a release is tens of megabytes and nobody sweeps the cache for us.
  Future<File> _stage(ReleaseInfo rel) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}${rel.assetName}');
  }

  Future<void> _download(Uri url, File file, int? expectedSize) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', url)..headers['User-Agent'] = 'family-messenger-app/$currentVersion');
      if (res.statusCode != 200) throw HttpException('download failed: ${res.statusCode}');
      final total = res.contentLength ?? expectedSize;
      final sink = file.openWrite();
      var got = 0;
      var shown = -1;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total != null && total > 0) {
            // The whole home screen listens to this object and a release
            // arrives in thousands of chunks: only a changed percent is worth
            // rebuilding it for.
            final percent = got * 100 ~/ total;
            if (percent != shown) {
              shown = percent;
              progress = got / total;
              notifyListeners();
            }
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
    final sumsUrl = Uri.parse('$downloadBase/$repo/releases/download/${rel.tag}/sha256sums.txt');
    http.Response sums;
    try {
      sums = await http.get(sumsUrl, headers: {'User-Agent': 'family-messenger-app/$currentVersion'}).timeout(const Duration(seconds: 20));
    } catch (_) {
      return; // no checksum file reachable: the download came over HTTPS from GitHub
    }
    if (sums.statusCode != 200) return;
    final expected = expectedSum(sums.body, rel.assetName!);
    if (expected == null) return;
    if (await sha256OfFile(file) != expected) throw UpdateException(t('update_checksum_mismatch'));
  }

  /// The hash listed for [assetName], or null when the file does not name it.
  /// `sha256sum` writes `<hash>  <name>`, with a star before a name it read in
  /// binary mode.
  static String? expectedSum(String body, String assetName) {
    String? expected;
    for (final line in const LineSplitter().convert(body)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final name = parts.last.startsWith('*') ? parts.last.substring(1) : parts.last;
      if (name == assetName) expected = parts.first;
    }
    return expected;
  }

  /// Hashes in chunks. The Android release is a hundred megabytes, and reading
  /// all of it into one list before hashing has no reason to fit on a phone.
  static Future<String> sha256OfFile(File file) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final digest = await sink.hash();
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Windows and Linux only: writes the swap-in script, starts it detached and
  /// exits the app. Android never arrives here — an installed app may only be
  /// replaced by the package manager, which ApkInstaller.kt hands the APK to.
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
