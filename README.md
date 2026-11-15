# Origo X — Local Reader source edition

[中文说明](README.zh-CN.md)

This repository contains a buildable, local-first reader source edition. It reuses the current TXT/EPUB pagination, typography, bookmark, note and system text-to-speech components.

Included: local book import and library, page-turn modes, text search, reading themes and font settings, bookmarks and notes, local reading statistics, operating-system TTS, and an optional self-hosted reading-position sync server.

The source edition does not include account services, payments, advanced source engines, AI, cloud synchronization or developer-operated backend clients. These implementations are absent from the source tree and dependencies, rather than hidden with UI switches. The bundled sync module is opt-in and self-hosted; it exchanges only reading positions and is the single reviewed exception in `tool/check_public_source.py`.

## Run from source

Use Flutter 3.44.4 (Dart 3.12 or newer):

```sh
flutter pub get --enforce-lockfile
flutter gen-l10n
flutter run
```

The generated platform projects use a neutral example application ID and contain no maintainer signing identities. Local builds use your own platform signing setup where required. Android and desktop builds are checked by the public workflow.

## Optional progress sync

The app ships with an opt-in sync client, and `sync_server/` contains a dependency-free self-hosted server for reading positions. Start it with `dart run sync_server/bin/server.dart`, then open the library in the app, tap the cloud-sync icon and enter the server URL plus a shared user ID. See [sync_server/README.md](sync_server/README.md) for environment variables and API details. The server never receives book files, notes or reading statistics. Use HTTPS when the server is reachable beyond your local network.

## Official downloads

Official distribution packages are available from [Releases](https://github.com/miloquinn/origo-x/releases). They may include features outside this local source edition. This source snapshot should not be mistaken for a byte-for-byte build recipe for those packages.

## License and attribution

The reader code is licensed under [AGPL-3.0-only](LICENSE). Existing historical attribution and [earlier MIT licensing](LICENSE-MIT-LEGACY) are retained. Font licenses are kept in `assets/fonts/licenses/`. See [LICENSING.md](LICENSING.md).

## Source boundary

`PUBLIC_SOURCE_SCOPE.md` defines the current source boundary. The public workflow checks the tracked tree for excluded implementations and private operational metadata before compiling it. This policy applies to the current source tree; it does not rewrite historical commits or change another repository's visibility.

System TTS requires a supported operating-system speech engine. The Flutter TTS plugin does not currently support Linux.
