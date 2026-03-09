import SwiftUI
import SwiftData

// MARK: - Chat View

struct IdeaChatView: View {
    @Bindable var idea: Idea
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: IdeaChatViewModel?
    @State private var inputText = ""
    @State private var selectedModel: AIModel = AIModel.available[0]
    @FocusState private var isInputFocused: Bool
    var onNotesChanged: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if let vm = viewModel {
                        if vm.messages.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(vm.messages.filter { $0.role != "tool" && !$0.content.hasPrefix("[auto]") }) { message in
                                    ideaChatBubble(message)
                                        .id(message.id)
                                }

                                // Suggested reply chips
                                if !vm.suggestedReplies.isEmpty && !vm.isStreaming {
                                    suggestedRepliesView(vm: vm)
                                        .id("suggestions")
                                }
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: viewModel?.messages.count) {
                    if let last = viewModel?.messages.filter({ $0.role != "tool" }).last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if let activity = viewModel?.toolActivity {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(activity)
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle(Color.fg.opacity(0.3))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }

            if let error = viewModel?.errorMessage {
                Text(error)
                    .font(.custom("Switzer-Regular", size: 11))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }

            chatInput
        }
        .frame(minHeight: 300)
        .onAppear {
            if viewModel == nil {
                let vm = IdeaChatViewModel(idea: idea, modelContext: modelContext)
                vm.onNotesChanged = onNotesChanged
                viewModel = vm
            }
            isInputFocused = true
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .scaleEffect(0.6)
            Text("thinking about this idea...")
                .font(.custom("Switzer-Light", size: 12))
                .foregroundStyle(Color.fg.opacity(0.15))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .onAppear {
            Task {
                await viewModel?.kickstartIfNeeded(model: selectedModel.id)
            }
        }
    }

    // MARK: - Suggested Replies

    private func suggestedRepliesView(vm: IdeaChatViewModel) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(vm.suggestedReplies, id: \.self) { reply in
                Button {
                    inputText = ""
                    Task {
                        vm.suggestedReplies = []
                        await vm.sendMessage(reply, model: selectedModel.id)
                    }
                } label: {
                    Text(reply)
                        .font(.custom("Switzer-Regular", size: 12))
                        .foregroundStyle(Color.fg.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.fg.opacity(0.04))
                                .stroke(Color.fg.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Chat Input

    private var chatInput: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AIModel.available) { model in
                    Button {
                        selectedModel = model
                    } label: {
                        HStack {
                            Text(model.name)
                            if model.id == selectedModel.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                if viewModel?.messages.isEmpty == false {
                    Button(role: .destructive) {
                        viewModel?.clearChat()
                    } label: {
                        Label("Clear chat", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "sparkle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.fg.opacity(0.25))
                    .frame(width: 28, height: 28)
                    .background(Color.fg.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            TextField("think together...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom("Switzer-Regular", size: 14))
                .foregroundStyle(Color.fg.opacity(0.85))
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit { send() }
                .disabled(viewModel?.isStreaming ?? false)

            if viewModel?.isStreaming ?? false {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.fg.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.fg.opacity(0.03))
                .stroke(Color.fg.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private func ideaChatBubble(_ message: IdeaChatMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer()
                Text(message.content)
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.fg.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.fg.opacity(0.08))
                    )
                    .textSelection(.enabled)
            }
        } else if message.role == "assistant" {
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !message.content.isEmpty {
                        Text(LocalizedStringKey(message.content))
                            .font(.custom("Switzer-Regular", size: 14))
                            .foregroundStyle(Color.fg.opacity(0.75))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .padding(.bottom, 4)
                    }
                    ForEach(toolCalls) { tc in
                        HStack(spacing: 5) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.fg.opacity(0.2))
                            Text(tc.displayName)
                                .font(.custom("Switzer-Light", size: 11))
                                .foregroundStyle(Color.fg.opacity(0.25))
                        }
                    }
                }
            } else if !message.content.isEmpty {
                Text(LocalizedStringKey(message.content))
                    .font(.custom("Switzer-Regular", size: 14))
                    .foregroundStyle(Color.fg.opacity(0.75))
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
        }
    }

    private func send() {
        let text = inputText
        inputText = ""
        Task {
            await viewModel?.sendMessage(text, model: selectedModel.id)
        }
    }
}
