# QB

A private iOS streaming client (iOS 26+) built around a Rust core (`QBCore`) and a SwiftUI front-end. It aggregates catalogs and streams from Stremio-compatible addons, ranks sources by health, and plays them with a native AVPlayer or VLC fallback.

## Features

- **Home** — hero banner, continue-watching shelf, catalog shelves from every installed addon, pull-to-refresh.
- **Discover / Search** — genre chips, debounced live search, results streamed in as addons respond.
- **Details** — backdrop, seasons/episodes, sources with live health dots, similar titles.
- **Player** — native + VLC, gestures (double-tap skip, swipe brightness/volume, pinch zoom, swipe-to-dismiss), scrubber with frame preview, ±10s, skip-intro, auto-next with countdown, PiP, AirPlay, subtitles (SRT/VTT) with live styling, recovery ladder.
- **Library** — favorites + history, sort/filter, export/import as JSON.
- **Addons** — install by URL, drag-to-reorder, enable/disable.
- **Settings** — preferred quality/engine, subtitles (size/weight/style/position), skip-intro seconds, auto-PiP, appearance, language (Arabic/English), clear cache.
- **Widget** — continue-watching widget.

## Build (unsigned IPA)

Requires Xcode 26, Rust + iOS target, XcodeGen, CocoaPods (MobileVLCKit).

```sh
./scripts/build-core.sh          # Rust -> QBCore XCFramework
xcodegen generate
pod install
xcodebuild -workspace QB.xcworkspace -scheme QB \
  -sdk iphoneos -configuration Release \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath build/DerivedData
# package Payload/QB.app -> QB.ipa
```

CI: `.github/workflows/ipa.yml` builds on `macos-15` and uploads the `qb-build` artifact.

## Sideload

The IPA is **unsigned**. Install with Sideloadly / AltStore / TrollStore (7-day free signing with a free Apple ID).

## Stack

- Rust (`rust/`) — protocol parsing, ranking, progress, settings.
- Swift Package `QBCore` — UniFFI bindings.
- SwiftUI app (`App/QB`) + widget (`App/QBWidget`).
- MobileVLCKit for exotic containers.

## License

MIT — see `LICENSE`.
