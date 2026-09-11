import 'package:family_messenger_e2e/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every step is itself', () {
    for (final double step in AppState.textScales) {
      expect(AppState.nearestTextScale(step), step);
    }
  });

  test('a size from outside the list lands on a step', () {
    // What a build with a different list, or a hand-edited keystore, can
    // leave behind. Anything else would ring none of the buttons in the
    // settings sheet and leave no way back to a known size.
    expect(AppState.nearestTextScale(1.37), 1.3);
    expect(AppState.nearestTextScale(1.4), 1.45);
    expect(AppState.nearestTextScale(0.5), 1.0);
    expect(AppState.nearestTextScale(9.0), 1.6);
    expect(AppState.nearestTextScale(double.nan), AppState.textScales.first);
  });

  test('the steps only ever grow, and start at the size the design draws', () {
    expect(AppState.textScales.first, 1.0);
    for (int i = 1; i < AppState.textScales.length; i++) {
      expect(AppState.textScales[i], greaterThan(AppState.textScales[i - 1]));
    }
  });
}
