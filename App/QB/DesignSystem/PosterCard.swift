import SwiftUI
import QBCore

/// بطاقة البوستر في الرفوف والشبكات
struct PosterCard: View {
    static let width: CGFloat = 122

    let name: String
    let poster: String?
    var year: String?
    var rating: String?
    var width: CGFloat? = PosterCard.width
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { RemoteImage(url: poster, maxPixel: 360) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if let rating, !rating.isEmpty {
                        RatingBadge(rating: rating)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            if showsTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Typo.caption).lineLimit(1).foregroundStyle(.primary)
                    if let year, !year.isEmpty {
                        Text(year).font(Typo.badge).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension PosterCard {
    init(_ item: MetaPreview, width: CGFloat? = PosterCard.width) {
        self.init(name: item.name, poster: item.poster, year: item.releaseInfo, rating: item.imdbRating, width: width)
    }
}
