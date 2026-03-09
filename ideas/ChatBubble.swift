import SwiftUI
import Textual

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .tool:
            toolResultBubble
        }
    }

    // MARK: - User

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("you")
                .font(.custom("Switzer-Medium", size: 10))
                .foregroundStyle(Color.fg.opacity(0.2))
                .textCase(.uppercase)
                .tracking(1.5)

            // Show attached image
            #if os(macOS)
            if let imageData = message.imageData, let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            #else
            if let imageData = message.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            #endif

            if !message.content.isEmpty {
                Text(message.content)
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.fg.opacity(0.85))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.fg.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text(message.timestamp.formatted(.dateTime.hour().minute()))
                .font(.custom("Switzer-Light", size: 10))
                .foregroundStyle(Color.fg.opacity(0.15))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Assistant

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Show tool call cards if this message triggered tools
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                ForEach(toolCalls) { tc in
                    ToolCallCard(toolCall: tc)
                }
            }

            // Show text content if any
            if !message.content.isEmpty {
                Text("ai")
                    .font(.custom("Switzer-Medium", size: 10))
                    .foregroundStyle(Color.fg.opacity(0.2))
                    .textCase(.uppercase)
                    .tracking(1.5)

                StructuredText(markdown: message.content)
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.fg.opacity(0.7))
                    .textual.textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.fg.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(message.timestamp.formatted(.dateTime.hour().minute()))
                    .font(.custom("Switzer-Light", size: 10))
                    .foregroundStyle(Color.fg.opacity(0.15))
            } else if message.toolCalls == nil {
                // Empty streaming placeholder
                Text("ai")
                    .font(.custom("Switzer-Medium", size: 10))
                    .foregroundStyle(Color.fg.opacity(0.2))
                    .textCase(.uppercase)
                    .tracking(1.5)

                Text("...")
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.fg.opacity(0.3))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.fg.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tool Result

    private var toolResultBubble: some View {
        Group {
            if let status = message.toolResultStatus {
                HStack(spacing: 8) {
                    Image(systemName: status.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(status.success ? Color.green.opacity(0.5) : Color.red.opacity(0.5))

                    Text(status.message)
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle(Color.fg.opacity(0.35))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.fg.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Tool Call Card

struct ToolCallCard: View {
    let toolCall: ChatMessage.ToolCall

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toolCall.icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.fg.opacity(0.4))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(toolCall.displayName)
                    .font(.custom("Switzer-Medium", size: 11))
                    .foregroundStyle(Color.fg.opacity(0.45))

                if let summary = toolCall.summary {
                    Text(summary)
                        .font(.custom("Switzer-Light", size: 10))
                        .foregroundStyle(Color.fg.opacity(0.25))
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.fg.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.fg.opacity(0.06), lineWidth: 1)
        )
    }
}
