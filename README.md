# Discord Orb Client

Flutter client for Android, macOS, and Windows that displays a floating always-on-top orb and a read-only preview panel showing up to 10 latest messages from a selected Discord server text channel.

## Features & Security Behavior

- **HTTPS-only backend connection**: Rejects plain `http://` URLs, invalid TLS certificates, and HTTP downgrade redirects. Changing the backend URL wipes local session tokens, selected channel state, and in-memory messages.
- **RFC 8252 Discord OAuth + PKCE**:
  - **macOS & Windows**: Starts a temporary loopback listener on `http://127.0.0.1:<port>/callback` and opens the system browser.
  - **Android**: Uses the `discordorb://auth/callback` custom URL scheme registered in `AndroidManifest.xml`.
  - Exchanges the backend's single-use `ticket` + PKCE `code_verifier` for a 15-minute access token and 30-day rotating refresh token.
- **Floating Orb & Panel**:
  - Two-tap toggle (open / close), drag positioning clamped inside screen bounds, automatic above/below panel flipping, and read-only display of up to 10 newest messages.
  - Device lock, sleep, or app background/inactive transitions immediately close the panel and clear in-memory message data.
  - Real-time permission revocation (`403`) prompts channel reselection; session revocation (`401`) prompts Discord sign-in.

## Prerequisites

- Flutter SDK (tested with Flutter `3.44.9`, Dart `3.12.2`)
- Platform toolchains as needed:
  - **Android**: Android SDK / JDK
  - **macOS**: Xcode + CocoaPods
  - **Windows**: Visual Studio with C++ Desktop workload

Install Dart/Flutter dependencies and verify static analysis and tests:

```sh
flutter pub get
flutter analyze
flutter test
```

## Direct Install & Update Guide

Discord Orb is distributed for direct installation without app stores.

### Android (APK)

1. Build a release APK:
   ```sh
   flutter build apk --release
   ```
   Output: `build/app/outputs/flutter-apk/app-release.apk`
2. Transfer the APK to the Android device and install it (enable **Install unknown apps** for your file manager/browser if prompted).
3. Launch **Discord Orb**, grant **Display over other apps** (`SYSTEM_ALERT_WINDOW`) when prompted, enter your backend `https://<ORB_DOMAIN>` URL, sign in with Discord, and choose a channel.
4. **Updating**: Build or download a newer APK signed with the same signing key and install it over the existing app to preserve local configuration.

### macOS (`.app`)

1. Build the macOS app (debug or release):
   ```sh
   flutter build macos --release
   ```
   Output: `build/macos/Build/Products/Release/discord_orb.app`
2. Copy `discord_orb.app` to `/Applications` (or run directly). If macOS Gatekeeper blocks an unsigned/ad-hoc local build, right-click the app and choose **Open** (or clear quarantine if you built it on another machine).
3. **Updating**: Quit Discord Orb, replace `/Applications/discord_orb.app` with the newer build, and relaunch.

### Windows (`.exe`)

1. Build the Windows release bundle on a Windows host:
   ```sh
   flutter build windows --release
   ```
   Output: `build/windows/x64/runner/Release/` (keep `discord_orb.exe`, `flutter_windows.dll`, and the `data/` directory together).
2. Copy the entire `Release/` folder to a target directory (for example, `%LOCALAPPDATA%\Programs\DiscordOrb`) and run `discord_orb.exe`.
3. **Updating**: Exit Discord Orb and overwrite the folder contents with the new `Release/` bundle.

## CI

Pull requests and pushes to `main` run `flutter pub get`, `flutter analyze`, and `flutter test` via [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
