// Package-level cache for the app version, initialised once in main() via
// PackageInfo.fromPlatform() before runApp(). Read synchronously by
// DisplayState.toJson() on every WebSocket state broadcast.
String appVersion = '0.0.0';
