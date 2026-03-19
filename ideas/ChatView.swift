import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AIModel: Identifiable, Hashable {
    let id: String  // OpenRouter model ID
    let name: String // Display name

    static let available: [AIModel] = [
        AIModel(id: "anthropic/claude-haiku-4.5", name: "claude haiku"),
        AIModel(id: "openai/gpt-5.4-mini", name: "gpt-5.4 mini"),
        AIModel(id: "moonshotai/kimi-k2.5", name: "kimi k2.5"),
    ]
}

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    var ideasViewModel: IdeasViewModel?
    @State private var chatViewModel: ChatViewModel?
    @State private var inputText = ""
    @State private var selectedModel: AIModel = AIModel.available[0]
    @State private var selectedImageData: Data? = nil
    @State private var showImagePicker = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        #if os(macOS)
        chatContent
            .background(Color.bgBase)
            .onAppear {
                if chatViewModel == nil {
                    let vm = ChatViewModel(modelContext: modelContext)
                    vm.ideasViewModel = ideasViewModel
                    chatViewModel = vm
                }
                isInputFocused = true
            }
        #else
        ZStack {
            Color.bgBase
                .ignoresSafeArea()

            chatContent
        }
        .safeAreaInset(edge: .bottom) {
            iOSChatInput
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(AIModel.available) { model in
                        Button {
                            selectedModel = model
                        } label: {
                            if model.id == selectedModel.id {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedModel.name)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .onAppear {
            if chatViewModel == nil {
                let vm = ChatViewModel(modelContext: modelContext)
                vm.ideasViewModel = ideasViewModel
                chatViewModel = vm
            }
        }
        #endif
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    if let vm = chatViewModel {
                        if vm.messages.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(vm.messages) { message in
                                    ChatBubble(message: message)
                                        .id(message.id)
                                }
                            }
                            #if os(macOS)
                            .padding(.horizontal, 32)
                            #else
                            .padding(.horizontal, 16)
                            #endif
                            .padding(.top, 16)
                            .padding(.bottom, 16)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: chatViewModel?.messages.count) {
                    if let last = chatViewModel?.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Tool activity
            if let activity = chatViewModel?.toolActivity {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(activity)
                        .font(.custom("Switzer-Light", size: 11))
                        .foregroundStyle(Color.fg.opacity(0.3))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }

            // Error
            if let error = chatViewModel?.errorMessage {
                Text(error)
                    .font(.custom("Switzer-Regular", size: 12))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            #if os(macOS)
            chatInputBar
            #endif
        }
    }

    // MARK: - Input Bar (macOS)

    private var chatInputBar: some View {
        let inputIsEmpty = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            // Image preview
            if let imageData = selectedImageData, let nsImage = NSImage(data: imageData) {
                HStack(spacing: 8) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                selectedImageData = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.fg.opacity(0.6))
                                    .background(Circle().fill(Color.bgElevated))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            // Text field area
            TextField("ask about your ideas...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom("Switzer-Regular", size: 14))
                .foregroundStyle(Color.fg.opacity(0.9))
                .lineLimit(1...6)
                .focused($isInputFocused)
                .onSubmit { sendMessage() }
                .disabled(chatViewModel?.isStreaming ?? false)
                .padding(.horizontal, 16)
                .padding(.top, selectedImageData != nil ? 8 : 14)
                .padding(.bottom, 10)

            // Bottom toolbar row
            HStack(spacing: 0) {
                // Model selector
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
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 9))
                        Text(selectedModel.name)
                            .font(.custom("Switzer-Medium", size: 11))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .foregroundStyle(Color.fg.opacity(0.45))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.fg.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)

                chatToolbarDivider

                // Image attach
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url,
                       let data = try? Data(contentsOf: url) {
                        selectedImageData = data
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 10))
                        Text("image")
                            .font(.custom("Switzer-Medium", size: 11))
                    }
                    .foregroundStyle(Color.fg.opacity(selectedImageData != nil ? 0.6 : 0.3))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                chatToolbarDivider

                // Chat label
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 9))
                    Text("chat")
                        .font(.custom("Switzer-Medium", size: 11))
                }
                .foregroundStyle(Color.fg.opacity(0.3))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Spacer()

                // Streaming indicator or send button
                if chatViewModel?.isStreaming ?? false {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                        .padding(.trailing, 4)
                } else {
                    Button { sendMessage() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(inputIsEmpty
                                ? Color.fg.opacity(0.15)
                                : Color.bgBase)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(inputIsEmpty
                                        ? Color.fg.opacity(0.06)
                                        : Color.fg.opacity(0.7))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(inputIsEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.bgElevated)
                .stroke(Color.fg.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var chatToolbarDivider: some View {
        Rectangle()
            .fill(Color.fg.opacity(0.08))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }

    #if os(iOS)
    private var iOSChatInput: some View {
        HStack(spacing: 8) {
            TextField("ask about your ideas...", text: $inputText)
                .font(.system(size: 15))
                .onSubmit { sendMessage() }
                .disabled(chatViewModel?.isStreaming ?? false)

            if chatViewModel?.isStreaming ?? false {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassInputModifier())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
    #endif

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("chat")
                .font(.custom("Switzer-Medium", size: 16))
                .foregroundStyle(Color.fg.opacity(0.2))
            Text("ask anything about your ideas")
                .font(.custom("Switzer-Light", size: 12))
                .foregroundStyle(Color.fg.opacity(0.1))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendMessage() {
        let text = inputText
        let imageData = selectedImageData
        inputText = ""
        selectedImageData = nil
        Task {
            await chatViewModel?.sendMessage(text, model: selectedModel.id, imageData: imageData)
        }
    }
}
