import SwiftUI
import QBCore

/// المشغّل المصغّر فوق شريط التبويبات: ضغطة تفتح المشغّل، والسحب لتحت يخفيه
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    private var player: PlayerModel { app.player }

    var body: some View {
        HStack(spacing: 10) {
            // الوضع المصغّر جدًا: صورة العمل (الفيديو الحي يطلع أسود بهالحجم)، والعادي: الفيديو نفسه
            ZStack {
                EngineSurface(surface: player.isPresented ? nil : player.surface)
                if placement == .inline {
                    RemoteImage(url: player.context?.meta?.background ?? player.context?.ref.background ?? player.context?.ref.poster, maxPixel: 200)
                }
            }
            .frame(width: placement == .inline ? 40 : 58, height: placement == .inline ? 24 : 33)
            .background(Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(player.context?.title ?? "").font(Typo.caption).lineLimit(1)
                if placement != .inline, let sub = player.context?.subtitle {
                    Text(sub).font(Typo.font(.medium, 10, .caption2)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // بعيد عن خط التقدّم اللي تحت
            .padding(.bottom, placement == .inline ? 0 : 5)
            Spacer(minLength: 4)
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? L("إيقاف مؤقت") : L("تشغيل"))
            Button {
                player.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: placement == .inline ? 12 : 14, weight: .bold))
                    .frame(width: placement == .inline ? 26 : 32, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("إغلاق"))
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { player.expand() }
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { v in
                if v.translation.height > 24 { player.hideMini() }
                if v.translation.height < -24 { player.expand() }
            }
        )
        .overlay(alignment: .bottom) {
            if let d = player.duration, d > 0 {
                ProgressLine(fraction: player.elapsed / d, height: 2)
                    .padding(.horizontal, 14)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .accessibilityAction(named: L("فتح المشغّل")) { player.expand() }
    }
}
