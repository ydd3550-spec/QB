import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import QBCore

/// MKV -> HLS على الجهاز: هل مشغّل آبل نفسه (AVPlayer) يقبل الناتج ويشغّله؟
/// كل اختبار يطبع سطر "REMUX-CHECK" بالنتيجة عشان تنقرأ من سجل Codemagic.
@Suite("التحويل للمشغّل الأصلي", .serialized)
@MainActor
struct RemuxPlaybackTests {
    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures"))
        return url.path
    }

    static func log(_ s: String) { print("REMUX-CHECK \(s)") }

    init() { setenv("QB_REMUX_TRACE", "1", 1) }

    /// يشغّل الرابط لين يعدّي `seconds` من الفيديو، ويرجّع المشغّل والعنصر
    /// يطبع اللي يشوفه أي عميل HTTP: القائمة الرئيسية، قائمة الفيديو، init وأول مقطع
    static func probeHTTP(_ master: String) async {
        let base = master.components(separatedBy: "/").dropLast().joined(separator: "/")
        for path in [master, base + "/index.m3u8", base + "/init.mp4", base + "/0.m4s"] {
            guard let u = URL(string: path) else { continue }
            do {
                let (data, resp) = try await URLSession.shared.data(from: u)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let text = path.hasSuffix(".m3u8") ? String(decoding: data.prefix(700), as: UTF8.self).replacingOccurrences(of: "\n", with: " | ") : ""
                log("http \(u.lastPathComponent) \(code) \(data.count)B \(text)")
            } catch {
                log("http \(u.lastPathComponent) ERROR \(error)")
            }
        }
    }

    /// محلّل HLS حق آبل بدون تشغيل: يقبل القائمة؟ وش المسارات؟
    static func probeAsset(_ master: String) async {
        guard let u = URL(string: master) else { return }
        let asset = AVURLAsset(url: u)
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            let tracks = try await asset.load(.tracks)
            log("asset playable=\(playable) duration=\(duration.seconds) tracks=\(tracks.map { $0.mediaType.rawValue })")
            if let g = try await asset.loadMediaSelectionGroup(for: .audible) { log("asset audible=\(g.options.map(\.displayName))") }
            if let g = try await asset.loadMediaSelectionGroup(for: .legible) { log("asset legible=\(g.options.map(\.displayName))") }
        } catch {
            log("asset ERROR \(error)")
        }
    }

    static func play(_ urlString: String, from start: Double = 0, seconds: Double = 2.5) async throws -> (AVPlayer, AVPlayerItem) {
        await probeHTTP(urlString)
        await probeAsset(urlString)
        let item = AVPlayerItem(url: try #require(URL(string: urlString)))
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        player.play()
        var deadline = Date().addingTimeInterval(40)
        while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let err = item.error.map { "\($0)" } ?? "-"
        let access = item.accessLog()?.events.map { "\($0.uri ?? "-") bytes=\($0.numberOfBytesTransferred)" } ?? []
        let errors = item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorDomain) \($0.errorComment ?? "")" } ?? []
        log("status=\(item.status.rawValue) error=\(err) likely=\(item.isPlaybackLikelyToKeepUp) loaded=\(item.loadedTimeRanges.count) access=\(access) errors=\(errors) timeControl=\(player.timeControlStatus.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "-")")
        try #require(item.status == .readyToPlay, "AVPlayer rejected it: \(err)")
        if start > 0 {
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        deadline = Date().addingTimeInterval(30)
        while item.currentTime().seconds < start + seconds, Date() < deadline, item.status != .failed {
            try await Task.sleep(for: .milliseconds(100))
        }
        let events = item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? []
        log("played to \(String(format: "%.2f", item.currentTime().seconds))s rate=\(player.rate) errorLog=\(events)")
        #expect(item.currentTime().seconds >= start + seconds, "playback didn't advance")
        #expect(item.status == .readyToPlay)
        return (player, item)
    }

    struct AudioFormat { let fourCC: String; let channels: UInt32 }

    static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .ascii) ?? "\(v)"
    }

    /// صيغ المسارات اللي المشغّل فعلًا قاعد يشغّلها
    static func formats(_ item: AVPlayerItem, _ type: AVMediaType) async throws -> [AudioFormat] {
        var out: [AudioFormat] = []
        for t in item.tracks where t.isEnabled {
            guard let a = t.assetTrack, a.mediaType == type else { continue }
            for f in try await a.load(.formatDescriptions) {
                let ch = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee.mChannelsPerFrame ?? 0
                out.append(AudioFormat(fourCC: fourCC(CMFormatDescriptionGetMediaSubType(f)), channels: ch))
            }
        }
        return out
    }

    @Test func eac3SevenOneAndSecondAudioAndPGS() async throws {
        let info = try await remuxOpenFile(path: try Self.fixture("fx_h264_eac3_71_multi"))
        defer { remuxClose(playlistUrl: info.playlistUrl) }
        Self.log("multi: video=\(info.videoCodec) audio=\(info.audioCodec) audioTracks=\(info.audioTracks) pgs=\(info.pgs.count) vlcOnly=\(info.vlcOnly.map { "\($0.kind):\($0.codec)" })")
        #expect(info.audioCodec == "E-AC-3")
        #expect(info.audioTracks == 2)
        #expect(info.vlcOnly.contains { $0.kind == "audio" && $0.codec == "DTS" })
        #expect(info.pgs.count == 1)

        let (player, item) = try await Self.play(info.playlistUrl)
        let audio = try await Self.formats(item, .audio)
        Self.log("multi: playing audio \(audio.map { "\($0.fourCC) \($0.channels)ch" })")
        #expect(audio.contains { $0.fourCC == "ec-3" })

        // المسار الثاني (AAC) من قائمة الصوت
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
        Self.log("multi: audible options \(group.options.map { $0.displayName })")
        #expect(group.options.count == 2)
        if group.options.count == 2 {
            item.select(group.options[1], in: group)
            let t0 = item.currentTime().seconds
            let deadline = Date().addingTimeInterval(20)
            while item.currentTime().seconds < t0 + 2, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let after = try await Self.formats(item, .audio)
            Self.log("multi: after switch \(after.map { "\($0.fourCC) \($0.channels)ch" }) t=\(item.currentTime().seconds)")
            #expect(item.currentTime().seconds >= t0 + 2)
            #expect(after.contains { $0.fourCC == "aac " })
        }

        // ترجمة PGS اللي يرسمها التطبيق فوق الفيديو
        remuxPgsSelect(playlistUrl: info.playlistUrl, index: 0)
        var frame: RemuxPgsFrame?
        for _ in 0..<50 {
            frame = remuxPgsAt(playlistUrl: info.playlistUrl, timeMs: 3000, knownId: -1)
            if frame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let f = try #require(frame)
        Self.log("multi: pgs \(f.w)x\(f.h) at \(f.x),\(f.y) on \(f.canvasW)x\(f.canvasH)")
        #expect(f.w > 0 && f.h > 0 && f.rgba.count == Int(f.w * f.h * 4))
        player.pause()
    }

    @Test func hevcTenBitWithAC3() async throws {
        let info = try await remuxOpenFile(path: try Self.fixture("fx_hevc_ac3_strip"))
        defer { remuxClose(playlistUrl: info.playlistUrl) }
        let (player, item) = try await Self.play(info.playlistUrl)
        let video = try await Self.formats(item, .video)
        let audio = try await Self.formats(item, .audio)
        Self.log("hevc: video \(video.map(\.fourCC)) audio \(audio.map { "\($0.fourCC) \($0.channels)ch" }) size=\(item.presentationSize)")
        #expect(video.contains { $0.fourCC == "hvc1" })
        #expect(audio.contains { $0.fourCC == "ac-3" })
        #expect(item.presentationSize.width > 0)
        // تقديم لنص الملف
        await player.seek(to: CMTime(seconds: 6, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        let deadline = Date().addingTimeInterval(15)
        while item.currentTime().seconds < 7.5, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        Self.log("hevc: after seek t=\(item.currentTime().seconds)")
        #expect(item.currentTime().seconds >= 7.5)
        player.pause()
    }

    /// مصدر حقيقي من إضافة (Internet Archive): H.264 + AC-3 بـ MKV، من النت
    @Test func realAddonSource() async throws {
        let url = "https://archive.org/download/jim-hensons-the-storyteller-mkv/Jim%20Henson's%20The%20Storyteller%20-%20S01E01%20-%20The%20Soldier%20and%20Death.mkv"
        let info: RemuxedStream
        do {
            info = try await remuxOpen(url: url, headers: [:])
        } catch {
            Self.log("real: could not open (network?) \(error)")
            return
        }
        defer { remuxClose(playlistUrl: info.playlistUrl) }
        Self.log("real: video=\(info.videoCodec) audio=\(info.audioCodec) duration=\(info.durationS)")
        let (player, item) = try await Self.play(info.playlistUrl, from: 600, seconds: 3)
        Self.log("real: size=\(item.presentationSize)")
        player.pause()
    }
}
