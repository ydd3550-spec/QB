import SwiftUI
import QBCore

/// زر دائري زجاجي (للأزرار العائمة والمشغّل)
struct GlassCircleButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var label: String = ""
    /// زجاج شفاف أكثر (فوق الفيديو)
    var clear = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect((clear ? Glass.player : Glass.regular).interactive(), in: .circle)
        .accessibilityLabel(label.isEmpty ? systemImage : label)
    }
}

/// مقاسات الأزرار في كل التطبيق: مدمجة، ونفس الارتفاع للكل
enum ButtonMetrics {
    static let height: CGFloat = 40
    /// الزر العريض الوحيد (تشغيل في صفحة التفاصيل)
    static let wideHeight: CGFloat = 46
    static let horizontalPadding: CGFloat = 16
    /// عرض موحّد للأزرار اللي تنحط جنب بعض
    static let pairWidth: CGFloat = 150
    static let font = Typo.button
}

/// الزر الرئيسي (تشغيل): زجاج ملوّن بالذهبي
struct PrimaryButton: View {
    let title: String
    var systemImage: String = "play.fill"
    var expand = false
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(ButtonMetrics.font)
                .foregroundStyle(Palette.onAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, ButtonMetrics.horizontalPadding)
                .frame(width: width)
                .frame(maxWidth: expand ? .infinity : nil)
                .frame(height: expand ? ButtonMetrics.wideHeight : ButtonMetrics.height)
                // ذهبي صريح عشان النص الغامق ينقرأ بوضوح، مع لمعة زجاجية فوق
                .background {
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(SoftPressStyle())
        .shadow(color: Palette.accent.opacity(0.25), radius: 10, y: 4)
    }
}

/// زر ثانوي زجاجي بنص
struct GlassButton: View {
    let title: String
    var systemImage: String?
    var expand = false
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(ButtonMetrics.font)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.22), value: title)
            .foregroundStyle(.primary)
            .padding(.horizontal, ButtonMetrics.horizontalPadding)
            .frame(width: width)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: ButtonMetrics.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// شريحة اختيار زجاجية (الأنواع، المواسم، الكتالوجات)
struct Chip: View {
    let title: String
    var selected = false
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.caption.weight(.bold)) }
                Text(title).lineLimit(1)
            }
            .font(Typo.infoMedium)
            .foregroundStyle(selected ? Palette.onAccent : .primary)
            .padding(.horizontal, 15)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Palette.accent).interactive() : .regular.interactive(), in: .capsule)
        .animation(Motion.snappy, value: selected)
    }
}

/// عنوان القسم مع زر "الكل" اختياري
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    // خط ذهبي صغير قبل العنوان
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: 16)
                    Text(title).font(Typo.section).lineLimit(1)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(L("الكل"))
                        Image(systemName: "chevron.forward").font(.system(size: 10, weight: .bold))
                    }
                    .font(Typo.caption)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(.horizontal, 20)
    }
}

/// شارة التقييم
struct RatingBadge: View {
    let rating: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
            Text(rating).font(Typo.badge).monospacedDigit()
        }
    }
}

/// شارة نصية صغيرة (الجودة، المشغّل)
struct TagBadge: View {
    let text: String
    var color: Color = .secondary
    var filled = false
    var body: some View {
        Text(text)
            .font(Typo.badge)
            .foregroundStyle(filled ? Palette.onAccent : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                if filled {
                    Capsule().fill(Palette.accent)
                } else {
                    Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)
                }
            }
    }
}

/// نبضة تحميل خفيفة بدل الدوّارة
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 14
    @State private var dim = false
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Palette.surface)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// رف تحميل (هيكل)
struct SkeletonShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(cornerRadius: 6).frame(width: 140, height: 18).padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonBlock().frame(width: PosterCard.width, height: PosterCard.width * 1.5)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollDisabled(true)
        }
    }
}

/// حالة فاضية أو خطأ، بنفس الشكل في كل الشاشات
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.accent)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: .circle)
            Text(title).font(Typo.title).multilineTextAlignment(.center)
            if let message {
                Text(message).font(Typo.info).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                GlassButton(title: actionTitle, systemImage: "arrow.clockwise", action: action).padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// شعار QB داخل التطبيق
struct QBLogo: View {
    var size: CGFloat = 34
    var showWordmark = true
    var body: some View {
        HStack(spacing: 9) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            if showWordmark {
                Text(verbatim: "QB")
                    .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("QB")
    }
}

/// شريط التقدّم الرفيع
struct ProgressLine: View {
    let fraction: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(Palette.accent).frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// رسالة عابرة أعلى الشاشة
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typo.infoMedium)
            .lineLimit(1)
            .fixedSize()
            // النص يتبدّل بتلاشي، ما يتمطّط ولا يهتز
            .contentTransition(.opacity)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.top, 8)
    }
}

/// مكان الرسالة العابرة: ثابت دايم، ويدخل ويطلع بتلاشي وحركة خفيفة لتحت/فوق بس.
/// النص يبقى نفسه وقت الخروج (ما يختفي وسط الحركة)، ورسالة جديدة تتبدّل بتلاشي بدون قفزة بالمقاس.
struct ToastHost: View {
    let toast: String?
    @State private var shown = ""
    @State private var visible = false

    var body: some View {
        ToastView(text: shown)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -14)
            .animation(.smooth(duration: 0.28), value: shown)
            .allowsHitTesting(false)
            .accessibilityHidden(!visible)
            .onChange(of: toast) { _, new in
                if let new {
                    if visible {
                        withAnimation(.smooth(duration: 0.22)) { shown = new }
                    } else {
                        shown = new
                        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { visible = true }
                    }
                } else {
                    withAnimation(.smooth(duration: 0.3)) { visible = false }
                }
            }
    }
}

extension View {
    /// خلفية الشاشات الموحّدة
    func qbScreenBackground() -> some View {
        background {
            ZStack(alignment: .top) {
                Palette.background
                // توهّج ذهبي خفيف جدًا فوق يعطي عمق
                RadialGradient(colors: [Palette.accent.opacity(0.10), .clear], center: .top, startRadius: 0, endRadius: 420)
                    .frame(height: 420)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
    }
}


/// كم سحبت لتحت فوق أول الصفحة (صفر وقت التمرير العادي). الصورة اللي فوق تتمطّط بهالمقدار
struct OverscrollReader: ViewModifier {
    @Binding var pull: CGFloat

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geo in
            max(0, -(geo.contentOffset.y + geo.contentInsets.top))
        } action: { _, new in
            // نقرّب لنص نقطة عشان ما نحدّث الواجهة على فروقات ما تنشاف
            let v = (new * 2).rounded() / 2
            if v != pull { pull = v }
        }
    }
}

extension View {
    func trackOverscroll(_ pull: Binding<CGFloat>) -> some View { modifier(OverscrollReader(pull: pull)) }
}


extension Glass {
    /// زجاج أبل الشفاف فوق الفيديو، مع لمسة غامقة خفيفة عشان الأيقونات تنقرأ على المشاهد الفاتحة
    static var player: Glass { .clear.tint(.black.opacity(0.14)) }
}
