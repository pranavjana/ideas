import SwiftUI

struct NodeView: View {
    @Environment(\.tagColors) private var tagColors
    let idea: Idea
    let isSelected: Bool

    private var nodeAccent: Color? {
        guard let firstTag = idea.tags.first,
              let hex = tagColors[firstTag], !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        let accent = nodeAccent
        VStack(alignment: .leading, spacing: 4) {
            Text(idea.text)
                .font(.custom("Switzer-Regular", size: 12))
                .foregroundStyle(accent?.opacity(isSelected ? 1.0 : 0.85)
                    ?? Color.white.opacity(isSelected ? 1.0 : 0.85))
                .lineLimit(3)

            if !idea.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(idea.tags, id: \.self) { tag in
                        let tagColor = tagColors[tag].flatMap { Color(hex: $0) }
                        Text(tag)
                            .font(.custom("Switzer-Light", size: 9))
                            .foregroundStyle((tagColor ?? .white).opacity(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((tagColor ?? .white).opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
            }

            // Connection count
            let linkCount = idea.allLinks.count
            if linkCount > 0 {
                HStack(spacing: 3) {
                    Circle()
                        .fill((accent ?? .white).opacity(isSelected ? 0.5 : 0.25))
                        .frame(width: 5, height: 5)
                    Text("\(linkCount) link\(linkCount == 1 ? "" : "s")")
                        .font(.custom("Switzer-Light", size: 9))
                        .foregroundStyle((accent ?? .white).opacity(0.25))
                }
            }

            // Due date
            if let formatted = idea.formattedDueDate {
                HStack(spacing: 3) {
                    Image(systemName: idea.recurring != nil ? "arrow.trianglehead.2.clockwise" : "calendar")
                        .font(.system(size: 8))
                    Text(formatted)
                        .font(.custom("Switzer-Light", size: 9))
                }
                .foregroundStyle(idea.dueStatus.color.opacity(0.8))
            }
        }
        .padding(12)
        .frame(maxWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((accent ?? .white).opacity(isSelected ? 0.1 : 0.05))
                .stroke((accent ?? .white).opacity(isSelected ? 0.4 : 0.12), lineWidth: isSelected ? 1.5 : 1)
        )
    }
}
