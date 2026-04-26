import 'package:flutter_test/flutter_test.dart';
import 'package:ha_smart_display/core/device/app_version.dart';
import 'package:ha_smart_display/core/display_state/display_state.dart';

void main() {
  test('DisplayState.toJson() includes app_version field', () {
    appVersion = '2.0.0';
    const state = DisplayState(
      wakeWord: 'alexa',
      ambientMode: 'clock',
      ambientActive: false,
      brightness: 128,
      doNotDisturb: false,
      screenOn: true,
      uptimeSeconds: 0,
      wakeWordCount: 0,
    );
    expect(state.toJson()['app_version'], '2.0.0');
  });
}
