# QB plan notes (from reference page; Nova -> QB)
## Sec 4 SwiftUI
App/: QBApp.swift (@main + init QBCore), AppModel.swift (@Observable: tab, current player, addons), Core/ (async wrappers + SourceStream),
DesignSystem/: Palette, Type, Motion, Haptics; Components/: PosterCard, Shelf, GlassChip, SourceRow, LiveDot, Skeleton
Features/: Home (hero banner, continue watching, catalog shelves, skeleton progressive), Discover (type+genre glass chips, poster grid),
Search (Tab(role:.search), results from all addons as they arrive), Library (favorites + history, sort & filter),
Details (animated backdrop, info, seasons/episodes, sources with scores, similar), Player (PlayerHost, NativeEngine, VLCEngine, Controls, Gestures, SubtitleOverlay),
MiniPlayer (tabViewBottomAccessory, X + swipe down to hide), Addons (install by URL, drag reorder, enable/disable), Settings (preferred quality, player, subtitles, clear cache)
Resources/: Localizable.xcstrings (Arabic first), Assets.xcassets
Design: warm near-black bg, one calm accent, rest system colors (light+dark). Font SF Arabic via Dynamic Type (.largeTitle titles, .subheadline info).
Motion: standard spring(0.35,bounce .12); snappy snappy(0.22) buttons/playpause; sheet spring(0.45,.08); soft smooth(0.3) scroll-to-top.
Glass: glassEffect only floating buttons, player, chips. GlassEffectContainer + .glassEffect(.regular.interactive()); Button .buttonStyle(.glassProminent)
Haptics: light sensoryFeedback on play, source select, end of drag.
RTL: leading/trailing only; direction icons flip; time scrubber stays LTR.
Perf: LazyVStack/LazyHStack, downsampled images, no AnyView.
Zoom transition: matchedTransitionSource + navigationTransition(.zoom)
Tab lesson: each tab NavigationStack + first ScrollView directly. Re-tap tab: subpage->pop to root; at top nothing; scrolled -> scroll to top with Motion.soft. No pull-to-refresh conflicting; don't rebuild page on tab tap.
## Sec 5 Player
1 engine from Rust: Native mp4/HLS, VLC mkv/TS/anything AVPlayer can't. 2 play/pause instant UI, don't wait. 3 after readyToPlay watch 6s: stuck waitingToPlay & time not moving, or presentationSize zero, or item failed/fatal errorLog -> switch to VLC same second + mark source needs VLC.
4 "Try another" appears under loader after 5s -> next alive source. 5 save progress every 10s + on pause + exit via save_progress.
PiP: AVPictureInPictureController canStartPictureInPictureAutomaticallyFromInline; return continues inside player. VLC: no PiP -> on background pause + save.
Mini player: tabViewBottomAccessory, X, swipe down hide. AirPlay: AVRoutePickerView on AVPlayer only. Subtitles: Rust parses srt/vtt -> Cues; SwiftUI overlay same for any engine.
Seek: horizontal drag like YouTube with time preview; double tap edge 10s. Close: swipe from edge or down -> shrinks to mini player in one motion.
Similar: button in player opens strip of similar without stopping. Unknown duration: show elapsed; bar fades in when known.
protocol PlaybackEngine (@MainActor): timeline (elapsed, duration?), state loading/playing/paused/stalled/failed, load(source,startAt) async throws, play, pause, seek(to:precise:) async
Duration: item.duration -> if indefinite/NaN seekableTimeRanges.last.end; VLC media.length -> if 0 max position reached.
CI note: simulator audio fake; test on readyToPlay/state not time progress.
## Sec 6 build: build-core.sh, Package.swift (QBCore binaryTarget QBCoreFFI + Sources/QBCore swift5 mode), project.yml XcodeGen (bundleIdPrefix, iOS 26, developmentLanguage ar, UIBackgroundModes audio, CFBundleDevelopmentRegion ar, ATS arbitrary loads, CODE_SIGNING_ALLOWED NO, SWIFT_VERSION 6.0), Podfile MobileVLCKit ~>3.7 use_frameworks, codemagic.yaml (mac_mini_m2, 60min, xcode 26.6, cocoapods default, cache cargo/target/pods, steps rust install, rust tests, build core, xcodegen+pod install, xcodebuild unsigned + zip Payload)
## Sec 1: iPhone only, iOS 26 min, Liquid Glass + poster zoom + springs; source memory learning; tab-button native behavior in all tabs; out of plan: iCloud, live TV, Jellyfin, torrent/debrid.
## Sec 8 phases: P0 repo rust/App/scripts, hello(), build-core.sh XCFramework, XcodeGen+Podfile+QBCore, IPA. P1 install addon by url+save, home shelves+search, details seasons/episodes, sources ranked live dot, AVPlayer + progress + continue watching. P2 VLC auto-switch, unknown duration, PiP mini player AirPlay, subtitle layer, seek/close gestures + try another. P3 Liquid Glass + poster zoom, haptics + skeletons, full RTL review, Instruments perf. P4 similar inside player, auto next episode + skip intro, Continue Watching WIDGET, export/import library as file (instead of iCloud).
## Sec 7 tests: addon tour script (report alive count per engine; manual/weekly); CI simulator: test readyToPlay/state not time progress.
## Sec 9 risks: start w/ protocol; size: lto strip cg-units=1 native-tls; one tokio runtime in core, no block_on; MainActor for callbacks; QBCore package Swift5 mode, app Swift 6; cancel Task on leave + cancel_all; tolerant deserialize; sideload. Closing: measure before optimizing, pin versions in Cargo.lock (commit it), every feature with its test.
## Sec 7 tests (more): Rust unit (manifest/stream parsing, ranking, ...)... ; manual row ...
