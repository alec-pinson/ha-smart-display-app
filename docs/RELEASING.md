# Releasing the app

## The two numbers in `pubspec.yaml`

`version: 1.1.1+7` is two values for two different audiences:

- **`1.1.1` — versionName.** Human-facing. Broadcast to Home Assistant as
  `app_version`, shown in the update entity, and must match the git tag.
- **`+7` — versionCode.** An integer only Android reads, to decide whether an
  install is an upgrade or a downgrade. It appears in no UI, no tag, and no
  release name. `android/app/build.gradle.kts:36` takes it straight from
  Flutter, which reads it from pubspec.

## Rules

1. **versionCode strictly increases on every published build**, beta or stable,
   forever. Never reuse a number. Android refuses an APK whose versionCode is
   lower than the installed one — the OTA overlay just never completes, and
   recovering needs an uninstall over USB.
2. **Never omit the `+N`.** `version: 1.1.1` makes Flutter fall back to
   `versionCode = 1`, which reads as a downgrade from any real build.
3. **The git tag is exactly `v` + the versionName.** If they disagree, the
   device shows a permanent phantom "update available" that installing never
   clears, because the integration compares the tag against the broadcast
   `app_version`.
4. **Betas get `--prerelease`; stables do not.**

## Cutting a beta

```bash
# 1. Bump pubspec.yaml, e.g. version: 1.1.1-beta.1+5
# 2. Build
flutter build apk --release
# 3. Publish
gh release create v1.1.1-beta.1 \
  build/app/outputs/flutter-apk/app-release.apk \
  --prerelease \
  --title "v1.1.1-beta.1" \
  --notes "Test build"
```

Devices with **Beta app updates** enabled pick it up on the next daily poll, or
immediately via the **Check for Updates** button on the device in Home
Assistant.

## Promoting to stable

```bash
# 1. Bump pubspec.yaml to version: 1.1.1+8  (higher than every beta above)
# 2. Build
flutter build apk --release
# 3. Publish with no --prerelease flag
gh release create v1.1.1 \
  build/app/outputs/flutter-apk/app-release.apk \
  --title "v1.1.1" \
  --notes "Release notes"
```

GitHub marks it latest automatically, and both channels converge on it.

## Worked example

| pubspec `version:` | git tag | `gh release create` |
|---|---|---|
| `1.1.1-beta.1+5` | `v1.1.1-beta.1` | `--prerelease` |
| `1.1.1-beta.2+6` | `v1.1.1-beta.2` | `--prerelease` |
| `1.1.1+7` | `v1.1.1` | *(no flag)* |

## Caveat

Pre-releases do not expire. If you cut betas for a version and then abandon it
without shipping a stable release, beta devices stay on that beta indefinitely.
They will not drift back to stable on their own.
