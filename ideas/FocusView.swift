import SwiftUI
import SwiftData

struct FocusView: View {
    @Bindable var viewModel: FocusViewModel
    var onSelectIdea: ((Idea) -> Void)? = nil
    @State private var inputText = ""
    @State private var selectedModel: AIModel = AIModel.available[0]
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack {
            Color.bgBase
                .ignoresSafeArea()

            switch viewModel.phase {
            case .chat:
                chatPhase(vm: viewModel)
            case .confirmed:
                confirmedPhase(vm: viewModel)
            }
        }
    }

    // MARK: - Chat Phase

    private func chatPhase(vm: FocusViewModel) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        welcomeHeader(vm: vm)
                            .padding(.top, 40)
                            .padding(.bottom, 32)

                        if !vm.messages.isEmpty {
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
                            .padding(.bottom, 16)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(vm.messages.isEmpty ? .top : .bottom)
                .onChange(of: vm.messages.count) {
                    if let last = vm.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Tool activity
            if let activity = vm.toolActivity {
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

            if let error = vm.errorMessage {
                Text(error)
                    .font(.custom("Switzer-Regular", size: 12))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            focusInputBar
        }
    }

    // MARK: - Welcome Header

    private func welcomeHeader(vm: FocusViewModel) -> some View {
        VStack(spacing: 12) {
            // Greeting
            let greeting = timeGreeting()
            Text(vm.userName.isEmpty ? "\(greeting)." : "\(greeting), \(vm.userName).")
                .font(.custom("Gambarino-Regular", size: 28))
                .foregroundStyle(Color.fg.opacity(0.85))

            // Date
            Text(todayFormatted())
                .font(.custom("Switzer-Light", size: 14))
                .foregroundStyle(Color.fg.opacity(0.3))

            // Prompt
            if vm.messages.isEmpty {
                Text("what do you want to focus on today?")
                    .font(.custom("Switzer-Regular", size: 15))
                    .foregroundStyle(Color.fg.opacity(0.4))
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Input Bar

    private var focusInputBar: some View {
        HStack(spacing: 8) {
            TextField("i want to focus on...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.custom("Switzer-Regular", size: 15))
                .foregroundStyle(Color.fg.opacity(0.9))
                .focused($isInputFocused)
                .onSubmit { sendMessage() }
                .disabled(viewModel.isStreaming)

            if viewModel.isStreaming {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
        #if os(macOS)
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        #else
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        #endif
    }

    // MARK: - Confirmed Phase

    private func confirmedPhase(vm: FocusViewModel) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("today's focus")
                                .font(.custom("Gambarino-Regular", size: 26))
                                .foregroundStyle(Color.fg.opacity(0.85))
                            Spacer()
                            Button {
                                vm.resetFocus()
                            } label: {
                                Text("reset")
                                    .font(.custom("Switzer-Regular", size: 12))
                                    .foregroundStyle(Color.fg.opacity(0.3))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.fg.opacity(0.04))
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Text(todayFormatted())
                            .font(.custom("Switzer-Light", size: 13))
                            .foregroundStyle(Color.fg.opacity(0.3))

                        // Progress
                        progressBar(vm: vm)
                            .padding(.top, 8)
                    }
                    #if os(macOS)
                    .padding(.horizontal, 32)
                    #else
                    .padding(.horizontal, 20)
                    #endif
                    .padding(.top, 40)
                    .padding(.bottom, 24)

                    // Task list
                    LazyVStack(spacing: 2) {
                        ForEach(vm.focusItems) { item in
                            focusItemRow(item: item, vm: vm)
                        }
                    }
                    #if os(macOS)
                    .padding(.horizontal, 24)
                    #else
                    .padding(.horizontal, 12)
                    #endif
                }
            }
        }
    }

    // MARK: - Progress Bar

    private func progressBar(vm: FocusViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(vm.completedCount) of \(vm.totalCount) completed")
                    .font(.custom("Switzer-Regular", size: 12))
                    .foregroundStyle(Color.fg.opacity(0.4))
                Spacer()
                if vm.totalCount > 0 {
                    Text("\(Int(Double(vm.completedCount) / Double(vm.totalCount) * 100))%")
                        .font(.custom("Switzer-Medium", size: 12))
                        .foregroundStyle(Color.fg.opacity(0.5))
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.fg.opacity(0.06))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.fg.opacity(0.25))
                        .frame(width: vm.totalCount > 0
                            ? geo.size.width * CGFloat(vm.completedCount) / CGFloat(vm.totalCount)
                            : 0,
                               height: 6)
                        .animation(.easeInOut(duration: 0.3), value: vm.completedCount)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Focus Item Row

    private func focusItemRow(item: FocusViewModel.FocusItem, vm: FocusViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main task
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.toggleItem(item)
                    }
                } label: {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.fg.opacity(item.isCompleted ? 0.5 : 0.2))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.idea.text)
                        .font(.custom("Switzer-Regular", size: 15))
                        .foregroundStyle(Color.fg.opacity(item.isCompleted ? 0.3 : 0.8))
                        .strikethrough(item.isCompleted, color: Color.fg.opacity(0.2))
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if item.idea.priority > 0 {
                            Text(item.idea.priorityLevel.label)
                                .font(.custom("Switzer-Light", size: 10))
                                .foregroundStyle(item.idea.priorityLevel.color.opacity(0.7))
                        }
                        if let due = item.idea.formattedDueDate {
                            Text(due)
                                .font(.custom("Switzer-Light", size: 10))
                                .foregroundStyle(Color.fg.opacity(0.3))
                        }
                        if let folder = item.idea.folder {
                            Text(folder.name)
                                .font(.custom("Switzer-Light", size: 10))
                                .foregroundStyle(Color.fg.opacity(0.25))
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.fg.opacity(0.12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.fg.opacity(item.isCompleted ? 0.02 : 0.04))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectIdea?(item.idea)
            }

            // Subtasks
            if !item.subtasks.isEmpty && !item.isCompleted {
                VStack(spacing: 0) {
                    ForEach(Array(item.subtasks.enumerated()), id: \.offset) { index, subtask in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                vm.toggleSubtask(item: item, subtaskIndex: index)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: subtask.isDone ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.fg.opacity(subtask.isDone ? 0.35 : 0.2))

                                Text(subtask.text)
                                    .font(.custom("Switzer-Light", size: 13))
                                    .foregroundStyle(Color.fg.opacity(subtask.isDone ? 0.25 : 0.55))
                                    .strikethrough(subtask.isDone, color: Color.fg.opacity(0.15))
                                    .lineLimit(1)

                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.leading, 30)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private func sendMessage() {
        let text = inputText
        inputText = ""
        Task {
            await viewModel.sendMessage(text, model: selectedModel.id)
        }
    }

    private func timeGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "good morning" }
        if hour < 17 { return "good afternoon" }
        return "good evening"
    }

    private func todayFormatted() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt.string(from: Date()).lowercased()
    }
}
