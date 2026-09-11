import 'dart:io';

import 'package:family_messenger_e2e/state/updater.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // messageFor() goes through the dictionary, which reads the platform locale.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('release tags compare numerically', () {
    expect(Updater.isNewer('v0.2.0', 'v0.1.9'), isTrue);
    expect(Updater.isNewer('v0.10.0', 'v0.9.1'), isTrue);
    expect(Updater.isNewer('v1.0.0', 'v0.99.99'), isTrue);
    expect(Updater.isNewer('v0.2.0', 'v0.2.0'), isFalse);
    expect(Updater.isNewer('v0.1.0', 'v0.2.0'), isFalse);
    expect(Updater.isNewer('0.3.0', 'v0.2.0'), isTrue);
  });

  test('development builds are never outdated', () {
    expect(Updater.isNewer('v9.9.9', 'dev'), isFalse);
    expect(Updater.isNewer('v9.9.9', '8260434'), isFalse);
    expect(Updater.isNewer('v9.9.9', 'v0.1.0-3-g8260434'), isTrue);
    expect(Updater('dev').isReleaseBuild, isFalse);
    expect(Updater('v0.2.0').isReleaseBuild, isTrue);
  });

  test('a malformed latest tag is ignored', () {
    expect(Updater.isNewer('latest', 'v0.1.0'), isFalse);
    expect(Updater.isNewer('', 'v0.1.0'), isFalse);
  });

  test('every platform picks its own asset out of one release', () {
    const List<String> assets = <String>[
      'family-messenger-v0.2.0.aab',
      'family-messenger-v0.2.0.apk',
      'family-messenger-linux-x64-v0.2.0.tar.gz',
      'family-messenger-windows-x64-v0.2.0.zip',
      'sha256sums.txt',
    ];
    String pick(String platform) => assets.firstWhere((String a) => Updater.matchesAsset(a, platform), orElse: () => '');

    // The .aab sorts first and belongs to a store: a phone cannot install it.
    expect(pick('android'), 'family-messenger-v0.2.0.apk');
    expect(pick('windows'), 'family-messenger-windows-x64-v0.2.0.zip');
    expect(pick('linux'), 'family-messenger-linux-x64-v0.2.0.tar.gz');
    expect(pick('ios'), '');
    expect(pick('web'), '');
    expect(Updater.matchesAsset('family-messenger-macos-v0.2.0.zip', 'macos'), isTrue);
    expect(Updater.matchesAsset('sha256sums.txt', 'android'), isFalse);
    // A per-ABI split release would publish these; none of them is ours.
    expect(Updater.matchesAsset('app-arm64-v8a-release.apk', 'android'), isFalse);
  });

  test('only Windows and Linux come back on their own', () {
    expect(Updater.installsFromApp('android'), isTrue);
    expect(Updater.installsFromApp('windows'), isTrue);
    expect(Updater.installsFromApp('linux'), isTrue);
    expect(Updater.installsFromApp('macos'), isFalse);
    expect(Updater.installsFromApp('ios'), isFalse);
    expect(Updater.installsFromApp('web'), isFalse);
    // The Android installer stops the app and leaves it stopped, so nothing
    // may promise a restart there.
    expect(Updater.restartsAfterInstall('android'), isFalse);
    expect(Updater.restartsAfterInstall('windows'), isTrue);
    expect(Updater.restartsAfterInstall('linux'), isTrue);
  });

  test('the release answer is read per platform', () {
    final Map<String, dynamic> json = <String, dynamic>{
      'tag_name': 'v0.2.0',
      'html_url': 'https://github.com/o/r/releases/tag/v0.2.0',
      'assets': <Map<String, dynamic>>[
        <String, dynamic>{'name': 'family-messenger-v0.2.0.aab', 'browser_download_url': 'https://x/aab', 'size': 1},
        <String, dynamic>{'name': 'family-messenger-v0.2.0.apk', 'browser_download_url': 'https://x/apk', 'size': 2},
      ],
    };
    final ReleaseInfo android = Updater.parseRelease(json, 'android');
    expect(android.tag, 'v0.2.0');
    expect(android.assetName, 'family-messenger-v0.2.0.apk');
    expect(android.assetUrl, 'https://x/apk');
    expect(android.assetSize, 2);
    final ReleaseInfo ios = Updater.parseRelease(json, 'ios');
    expect(ios.assetUrl, isNull);
    expect(ios.url, 'https://github.com/o/r/releases/tag/v0.2.0');
    expect(Updater.parseRelease(<String, dynamic>{}, 'android').assetName, isNull);
  });

  test('checksums are matched by asset name', () {
    const String body = 'aaa  family-messenger-v0.2.0.apk\n'
        'bbb  family-messenger-windows-x64-v0.2.0.zip\n'
        'ccc *family-messenger-v0.2.0.aab\n';
    expect(Updater.expectedSum(body, 'family-messenger-v0.2.0.apk'), 'aaa');
    // sha256sum marks a name it read in binary mode with a star.
    expect(Updater.expectedSum(body, 'family-messenger-v0.2.0.aab'), 'ccc');
    expect(Updater.expectedSum(body, 'family-messenger-v0.3.0.apk'), isNull);
    expect(Updater.expectedSum('', 'family-messenger-v0.2.0.apk'), isNull);
  });

  test('the streamed digest is the one sha256sum publishes', () async {
    final Directory dir = Directory.systemTemp.createTempSync('fm-updater');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File f = File('${dir.path}${Platform.pathSeparator}a.bin');
    await f.writeAsBytes(<int>[0x61, 0x62, 0x63]); // "abc"
    expect(await Updater.sha256OfFile(f), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  test('the installer refusals become one line each', () {
    expect(Updater.messageFor(PlatformException(code: Updater.errNotAllowed)), isNotNull);
    expect(Updater.messageFor(PlatformException(code: Updater.errSignature)), isNotNull);
    expect(
      Updater.messageFor(PlatformException(code: Updater.errNotAllowed)),
      isNot(Updater.messageFor(PlatformException(code: Updater.errSignature))),
    );
    // Closing the system dialog is an answer, not a failure worth reporting.
    expect(Updater.messageFor(PlatformException(code: Updater.errAborted)), isNull);
    // Anything else is reported as a failure carrying the system's own wording,
    // which names the actual refusal.
    expect(
      Updater.messageFor(PlatformException(code: Updater.errFailed, message: 'INSTALL_FAILED_INSUFFICIENT_STORAGE')),
      contains('INSTALL_FAILED_INSUFFICIENT_STORAGE'),
    );
    expect(Updater.messageFor(PlatformException(code: 'weird')), contains('weird'));
    // Our own refusals read as a sentence, without Dart's exception wrapper
    // ("Bad state: …" is what a StateError would have put in front of it).
    final String? ours = Updater.messageFor(const UpdateException('the checksum did not match'));
    expect(ours, contains('the checksum did not match'));
    expect(ours, isNot(contains('Exception')));
    expect(ours, isNot(contains('Bad state')));
    // Every line stands on its own: nothing is wrapped twice.
    for (final String? line in <String?>[
      Updater.messageFor(PlatformException(code: Updater.errNotAllowed)),
      Updater.messageFor(PlatformException(code: Updater.errSignature)),
      Updater.messageFor(PlatformException(code: Updater.errFailed, message: 'x')),
    ]) {
      expect(line, isNotNull);
      expect(line!.trim(), isNotEmpty);
    }
  });
}
