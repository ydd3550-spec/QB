import MediaPlayer
import UIKit

/// شاشة القفل ومركز التحكم: اسم الفيلم وصورته والوقت، وأزرار تشغيل/إيقاف و±10 ثواني والتقديم بالشريط
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    private weak var player: PlayerModel?
    private var configured = false
    private var artworkKey: String?
    private var artwork: MPMediaItemArtwork?
    private var lastPush = Date.distantPast
    private var lastPlaying: Bool?

    func attach(_ player: PlayerModel) {
        self.player = player
        guard !configured else { return }
        configured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.run { $0.resumeFromRemote() } ?? .commandFailed }
        c.pauseCommand.addTarget { [weak self] _ in self?.run { $0.pauseFromRemote() } ?? .commandFailed }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.run { $0.togglePlay() } ?? .commandFailed }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.run { $0.skip(10) } ?? .commandFailed }
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.run { $0.skip(-10) } ?? .commandFailed }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.run { $0.seek(to: e.positionTime) } ?? .commandFailed
        }
    }

    private func run(_ f: (PlayerModel) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let player, player.context != nil else { return .noActionableNowPlayingItem }
        f(player)
        return .success
    }

    /// يتنادى مع كل تحديث للمشغّل، بس يرسل للنظام مرة بالثانية أو لما تتغيّر حالة التشغيل
    func update(title: String, subtitle: String?, artworkURL: String?, elapsed: Double, duration: Double?, playing: Bool) {
        let now = Date()
        guard playing != lastPlaying || now.timeIntervalSince(lastPush) > 1 else { return }
        lastPush = now
        lastPlaying = playing
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        loadArtwork(artworkURL)
    }

    func clear() {
        lastPlaying = nil
        artworkKey = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func loadArtwork(_ raw: String?) {
        guard let raw, raw != artworkKey, let url = URL(string: raw) else { return }
        artworkKey = raw
        Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(for: url, maxPixel: 600) else { return }
            guard let self, self.artworkKey == raw else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artwork = art
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = art
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
