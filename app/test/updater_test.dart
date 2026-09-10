import 'package:family_messenger_e2e/state/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
