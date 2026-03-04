import SwiftUI
import SwiftData

struct AIModel: Identifiable, Hashable {
    let id: String  // OpenRouter model ID
    let name: String // Display name

    static let available: [AIModel] = [
        AIModel(id: "anthropic/claude-haiku-4.5", name: "claude haiku"),
        AIModel(id: "openai/gpt-4o-mini", name: "gpt-4o mini"),
        AIModel(id: "openai/gpt-4o", name: "gpt-4o"),
        AIModel(id: "anthropic/claude-sonnet-4", name: "claude sonnet"),
        AIModel(id: "google/gemini-2.5-flash-preview", name: "gemini flash"),
        AIModel(id: "deepseek/deepseek-chat", name: "deepseek v3"),
    ]
}

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    var ideasViewModel: IdeasViewModel?
    @State private var chatViewModel: ChatViewModel?
    @State private var inputText = ""
    @State private var selectedModel: AIModel = AIModel.available[0]
    @FocusState private var isInputFocused: Bool

    var body: some View {
        #if os(macOS)
        chatContent
            .background(Color(red: 0.09, green: 0.09, blue: 0.09))
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
            Color(red: 0.09, green: 0.09, blue: 0.09)
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
            #if os(macOS)
            // Model selector bar
            chatModelSelector
            #endif

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
                        .foregroundStyle(Color.white.opacity(0.3))
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

    // MARK: - Model Selector

    private var chatModelSelector: some View {
        HStack {
            Spacer()
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
                HStack(spacing: 4) {
                    Text(selectedModel.name)
                        .font(.custom("Switzer-Regular", size: 11))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
    }

    // MARK: - Input Bars

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            TextField("ask about your ideas...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.custom("Switzer-Regular", size: 15))
                .foregroundStyle(Color.white.opacity(0.9))
                .focused($isInputFocused)
                .onSubmit { sendMessage() }
                .disabled(chatViewModel?.isStreaming ?? false)

            if chatViewModel?.isStreaming ?? false {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
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
                .foregroundStyle(Color.white.opacity(0.2))
            Text("ask anything about your ideas")
                .font(.custom("Switzer-Light", size: 12))
                .foregroundStyle(Color.white.opacity(0.1))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendMessage() {
        let text = inputText
        inputText = ""
        Task {
            await chatViewModel?.sendMessage(text, model: selectedModel.id)
        }
    }
}
