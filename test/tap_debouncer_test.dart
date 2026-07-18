import 'package:flutter_test/flutter_test.dart';
import 'package:ha_smart_display/core/util/tap_debouncer.dart';

void main() {
  group('TapDebouncer', () {
    late DateTime clock;
    late TapDebouncer debouncer;

    setUp(() {
      clock = DateTime(2026, 7, 18, 12, 0, 0);
      debouncer = TapDebouncer(
        window: const Duration(milliseconds: 500),
        now: () => clock,
      );
    });

    test('accepts the first tap', () {
      expect(debouncer.accept(), isTrue);
    });

    test('rejects a second tap inside the window', () {
      expect(debouncer.accept(), isTrue);
      clock = clock.add(const Duration(milliseconds: 100));
      expect(debouncer.accept(), isFalse);
    });

    test('accepts again once the window has passed', () {
      expect(debouncer.accept(), isTrue);
      clock = clock.add(const Duration(milliseconds: 501));
      expect(debouncer.accept(), isTrue);
    });

    test('a rejected tap does not extend the window', () {
      expect(debouncer.accept(), isTrue);
      clock = clock.add(const Duration(milliseconds: 400));
      expect(debouncer.accept(), isFalse);
      clock = clock.add(const Duration(milliseconds: 101));
      expect(debouncer.accept(), isTrue);
    });

    test('a tap exactly on the window boundary is accepted', () {
      expect(debouncer.accept(), isTrue);
      clock = clock.add(const Duration(milliseconds: 500));
      expect(debouncer.accept(), isTrue);
    });

    test('defaults to a 500ms window', () {
      expect(TapDebouncer().window, const Duration(milliseconds: 500));
    });
  });
}
