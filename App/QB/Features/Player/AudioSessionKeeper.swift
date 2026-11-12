import AVFoundation
import UIKit

/// Audio session: configured once for movie playback, activated before every play and on foreground,
/// never deactivated by us. If it got deactivated in the background (a call, another app, VLC while
/// paused) and we resumed without reactivating it, the audio dropped for ~2 seconds.
@MainActor
final class AudioSessionKeeper {
    static let shared = AudioSessionKeeper()

    /// Interruption ended; the player decides whether it was playing before it
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    var onInterruptionBegan: (() -> Void)?
    /// Headphones unplugged: pause like Apple does
    var onOutputLost: (() -> Void)?

    private var configured = false
    private var lastActivation = Date.distantPast

    private init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.onInterruptionBegan?()
                case .ended:
                    self.activate(force: true)
                    self.onInterruptionEnded?(options.contains(.shouldResume))
                default:
                    break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.onOutputLost?() }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configured = false
                self?.activate(force: true)
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activate(force: true) }
        }
    }

    func configure() {
        guard !configured else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            configured = true
        } catch {
            print("[QB] audio session category failed: \(error)")
        }
    }

    /// Activates the session before playback. Throttled to once a second unless forced.
    func activate(force: Bool = false) {
        configure()
        let session = AVAudioSession.sharedInstance()
        if !force, Date().timeIntervalSince(lastActivation) < 1 { return }
        lastActivation = Date()
        do {
            try session.setActive(true)
        } catch {
            print("[QB] audio session activate failed: \(error)")
        }
    }
}
