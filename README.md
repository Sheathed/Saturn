<div align="center">
  <a href="https://github.com/SaturnMusic/">
    <img src="https://github.com/SaturnMusic/.github/blob/main/banner.png?raw=true" alt="Saturn" width="463">
  </a>

  <h1>Saturn</h1>

  <p>A cross-platform music player that brings multiple music services together.</p>

  <p>
    <a href="https://t.me/SaturnReleases"><img src="https://github.com/SaturnMusic/.github/blob/main/telegram.png?raw=true" alt="Telegram" width="64"></a>
    <a href="https://discord.com/invite/fttYFSHPCQ"><img src="https://github.com/SaturnMusic/.github/blob/main/discord.png?raw=true" alt="Discord" width="64"></a>
    <a href="https://saturn.kim/"><img src="https://github.com/SaturnMusic/.github/blob/main/web.png?raw=true" alt="Website" width="64"></a>
  </p>

  <p><a href="https://fund.saturn.kim/">Support Saturn</a></p>
</div>

Saturn combines music libraries, playback, playlists, downloads, lyrics, and listening history in one app. It is built with Flutter and targets Android, iOS, Windows, macOS, and Linux.

## Music services

| Service | Integration |
| --- | --- |
| Deezer | Browse, search, library, playlists, and playback. A Deezer premium account is required. |
| SoundCloud | Browse, search, library, playlists, and playback. A SoundCloud account unlocks account features; Go+ tracks require an eligible subscription for full playback. |
| YouTube Music | Browse, search, library, playlists, and playback, with optional account sign-in. |
| Neurokaraoke | Browse and playback, including community playlists and radio. Guest access is available. |

Available actions vary by service. Saturn is an independent community project and is not affiliated with these services.

## Get Saturn

See the [Saturn website](https://saturn.kim/) or the [releases page](https://github.com/WSOCK32/Saturn/releases) for installable builds and release notes.

## Build from source

### Requirements

- The latest Flutter SDK and its matching Dart SDK.
- Git and the platform toolchain for your target:
  - **Android:** Android SDK and JDK 17.
  - **iOS:** Xcode, CocoaPods, and an iOS 15 or newer deployment target.
  - **macOS:** Xcode, CocoaPods, and macOS 12 or newer.
  - **Windows:** Visual Studio with the C++ desktop development workload.
  - **Linux:** GTK 3, WebKit2GTK 4.1, MPV development files, and Ayatana AppIndicator development files. On Debian or Ubuntu, install them with:

    ```sh
    sudo apt install build-essential cmake ninja-build pkg-config libgtk-3-dev \
      libayatana-appindicator3-dev libmpv-dev libwebkit2gtk-4.1-dev
    ```

### Prepare the checkout

```sh
git clone https://github.com/WSOCK32/Saturn.git
cd Saturn
flutter doctor
flutter pub get
```

Deezer's application credentials are generated into the build and are not committed. Get the project's development credentials and create `lib/.env` in the repository root:

```dotenv
deezerClientId=YOUR_DEEZER_CLIENT_ID
deezerClientSecret=YOUR_DEEZER_CLIENT_SECRET
```

Keep this file private and do not commit it. Generate the Envied source before building:

```sh
dart run build_runner build --delete-conflicting-outputs \
  --build-filter=lib/utils/env.g.dart
```

If you do not have the Deezer development credentials, ask a project maintainer. The normal build cannot generate its required Deezer configuration without them.

### Run locally

Replace the device ID with one shown by `flutter devices`.

```sh
flutter run -d android --flavor stable
flutter run -d ios --dart-define=SATURN_FLAVOR=stable
flutter run -d windows --flavor stable
flutter run -d macos
flutter run -d linux --flavor stable
```
