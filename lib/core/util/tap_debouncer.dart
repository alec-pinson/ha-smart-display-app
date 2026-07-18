/// Rate-limits repeated taps on a single control.
///
/// Taps fire real Home Assistant automations, so an accidental double-tap on
/// the touchscreen must not run an automation twice. Only accepted taps
/// advance the window — otherwise continuous tapping could hold it open
/// forever.
class TapDebouncer {
  final Duration window;
  final DateTime Function() _now;

  DateTime? _lastAccepted;

  TapDebouncer({
    this.window = const Duration(milliseconds: 500),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Returns true if this tap should be acted on.
  bool accept() {
    final now = _now();
    final last = _lastAccepted;
    if (last != null && now.difference(last) < window) {
      return false;
    }
    _lastAccepted = now;
    return true;
  }
}
