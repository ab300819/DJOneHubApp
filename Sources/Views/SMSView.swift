import SwiftUI

struct SMSView: View {
    @Environment(AppModel.self) private var model

    @State private var messages: [ReceivedSMS] = []
    @State private var status: SMSStatus?
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var confirmingClear = false

    /// How often the page re-reads the inbox. The core polls the module on its
    /// own schedule; without this the status line would promise automatic
    /// polling while the list only ever changed on an explicit refresh.
    private static let reloadInterval = Duration.seconds(5)

    /// The thread on the right. Nil with `composingNew` set is a blank thread
    /// waiting for a number; nil without it is nothing selected.
    @State private var selectedPeer: String?
    @State private var composingNew = false

    private var conversations: [SMSConversation] { SMSConversation.group(messages) }

    var body: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: 260)
            Divider()
            thread
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar }
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: Self.reloadInterval)
            }
        }
        .confirmationDialog(
            "清空模块内存储的旧短信？", isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { Task { await clearModule() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清理模块 ME 存储里的历史短信，不影响此处已收取的内容。此操作不可撤销。")
        }
    }

    @ViewBuilder
    private var conversationList: some View {
        Group {
            if conversations.isEmpty {
                ContentUnavailableView(
                    "没有短信", systemImage: "tray",
                    description: Text("收到的短信会出现在这里。点刷新可立即向模块查询一次。"))
            } else {
                List(conversations, selection: $selectedPeer) { conversation in
                    ConversationRow(conversation: conversation)
                        .tag(conversation.peer)
                }
                .listStyle(.sidebar)
                .onChange(of: selectedPeer) { _, peer in
                    if peer != nil { composingNew = false }
                }
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { footer }
    }

    @ViewBuilder
    private var thread: some View {
        if let peer = selectedPeer, let conversation = conversations.first(where: { $0.peer == peer }) {
            ThreadView(conversation: conversation, busy: busy) { text in
                await send(phone: peer, message: text)
            }
        } else if composingNew {
            NewThreadView(busy: busy) { phone, text in
                guard await send(phone: phone, message: text) else { return false }
                composingNew = false
                selectedPeer = phone
                return true
            }
        } else {
            ContentUnavailableView(
                "选择一个会话", systemImage: "bubble.left.and.bubble.right",
                description: Text("或点工具栏的新短信按钮发一条。"))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(busy)

            Button {
                selectedPeer = nil
                composingNew = true
            } label: {
                Label("新短信", systemImage: "square.and.pencil")
            }

            Menu {
                Button("清空模块旧短信…", role: .destructive) { confirmingClear = true }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error {
            banner(error, tint: .red)
        } else if let notice {
            banner(notice, tint: .secondary)
        } else if let status {
            banner(status.summary, tint: .secondary)
        }
    }

    private func banner(_ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func reload() async {
        guard let transport = model.transport else { return }
        do {
            async let list = transport.listSMS()
            async let state = transport.smsStatus()
            messages = try await list.sorted { $0.timestamp > $1.timestamp }
            status = try await state
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        guard let transport = model.transport else { return }
        busy = true
        defer { busy = false }
        do {
            notice = nil
            _ = try await transport.refreshSMS()
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reports whether the module accepted the message, so a composer keeps
    /// its text when it did not.
    @discardableResult
    private func send(phone: String, message: String) async -> Bool {
        guard let transport = model.transport else { return false }
        busy = true
        defer { busy = false }
        do {
            let result = try await transport.sendSMS(phone: phone, message: message)
            error = nil
            notice = result.segments > 1 ? "已发送，分 \(result.segments) 段" : "已发送"
            await reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func clearModule() async {
        guard let transport = model.transport else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await transport.clearModuleSMS()
            error = nil
            notice = "模块存储已清理：\(result.before) → \(result.after)"
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ConversationRow: View {
    let conversation: SMSConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.peer)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let latest = conversation.latest {
                    Text(latest.timestamp, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let latest = conversation.latest {
                Text((latest.isOutgoing ? "我：" : "") + latest.content)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let code = conversation.latestCode {
                CodeChip(code: code)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A verification code that copies itself when clicked.
private struct CodeChip: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            copied = true
        } label: {
            Label(copied ? "已复制" : code, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassEffect(.regular.tint(.accentColor.opacity(0.25)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("复制验证码")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct ThreadView: View {
    let conversation: SMSConversation
    let busy: Bool
    let onSend: (String) async -> Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(conversation.messages) { Bubble(message: $0).id($0.id) }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.latest?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .safeAreaBar(edge: .bottom) { Composer(busy: busy, onSend: onSend) }
        .navigationSubtitle(conversation.peer)
    }
}

private struct Bubble: View {
    let message: ReceivedSMS

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(message.isOutgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(
                        message.isOutgoing ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 16))
                HStack(spacing: 6) {
                    if !message.isOutgoing, let code = message.code, !code.isEmpty {
                        CodeChip(code: code)
                    }
                    Text(message.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !message.isOutgoing { Spacer(minLength: 60) }
        }
    }
}

/// The text field under a thread. The text is cleared only once the module has
/// accepted it, so a failed send can be retried without retyping.
private struct Composer: View {
    let busy: Bool
    let onSend: (String) async -> Bool
    @State private var text = ""

    private var sendable: Bool {
        !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("短信", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(in: .rect(cornerRadius: 16))
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!sendable)
                .help("发送")
            }
        }
        .padding(12)
    }

    private func submit() {
        guard sendable else { return }
        let message = text
        Task {
            if await onSend(message) { text = "" }
        }
    }
}

/// A thread that does not exist yet: the number is asked for first.
private struct NewThreadView: View {
    let busy: Bool
    let onSend: (String, String) async -> Bool
    @State private var phone = ""

    var body: some View {
        Color.clear
            .safeAreaBar(edge: .top) {
                HStack {
                    Text("收件人：").foregroundStyle(.secondary)
                    TextField("号码，国际号码请写 +86138…", text: $phone)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(in: .capsule)
                .padding(12)
            }
            .safeAreaBar(edge: .bottom) {
                Composer(busy: busy) { text in
                    let number = phone.trimmingCharacters(in: .whitespaces)
                    guard !number.isEmpty else { return false }
                    return await onSend(number, text)
                }
            }
    }
}

#Preview("会话") {
    let json = #"""
        [{"sender":"10086","content":"CXLL","timestamp":"2026-10-28T10:00:00Z","outgoing":true},
         {"sender":"10086","content":"【DJOneHub 演示】本月套餐剩余流量 18.6GB。","timestamp":"2026-10-28T10:01:00Z"},
         {"sender":"10086","content":"您的验证码是 482913，10 分钟内有效。","code":"482913","timestamp":"2026-10-28T10:05:00Z"}]
        """#
    let messages = try! CoreJSON.decoder.decode([ReceivedSMS].self, from: Data(json.utf8))
    ThreadView(conversation: SMSConversation.group(messages)[0], busy: false) { _ in true }
        .frame(width: 560, height: 420)
}
