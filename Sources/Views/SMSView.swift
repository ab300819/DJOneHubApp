import SwiftUI

struct SMSView: View {
    @EnvironmentObject private var model: AppModel

    @State private var messages: [ReceivedSMS] = []
    @State private var status: SMSStatus?
    @State private var error: String?
    @State private var busy = false
    @State private var composing = false
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if messages.isEmpty {
                EmptyInbox()
            } else {
                List(messages) { message in
                    MessageRow(message: message)
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .toolbar { toolbar }
        .task { await reload() }
        .sheet(isPresented: $composing) {
            ComposeSheet { phone, text in
                await send(phone: phone, message: text)
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
                composing = true
            } label: {
                Label("发送", systemImage: "square.and.pencil")
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
        } else if let status {
            banner(statusLine(status), tint: .secondary)
        }
    }

    private func banner(_ text: String, tint: Color) -> some View {
        HStack {
            Text(text)
                .font(.callout)
                .foregroundStyle(tint)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func statusLine(_ status: SMSStatus) -> String {
        var parts = ["共 \(status.count) 条"]
        parts.append(status.polling ? "每 \(status.pollIntervalS) 秒自动查询" : "未自动查询")
        if !status.lastPollError.isEmpty {
            parts.append("上次查询出错：\(status.lastPollError)")
        }
        return parts.joined(separator: " · ")
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
            _ = try await transport.refreshSMS()
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send(phone: String, message: String) async {
        guard let transport = model.transport else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await transport.sendSMS(phone: phone, message: message)
            error = result.segments > 1 ? "已发送，分 \(result.segments) 段" : nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clearModule() async {
        guard let transport = model.transport else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await transport.clearModuleSMS()
            error = "模块存储已清理：\(result.before) → \(result.after)"
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Hand-rolled rather than ContentUnavailableView, which needs macOS 14 while
/// the app still targets 13 to match what the core supports.
private struct EmptyInbox: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("没有短信")
                .font(.title3.weight(.medium))
            Text("收到的短信会出现在这里。点刷新可立即向模块查询一次。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageRow: View {
    let message: ReceivedSMS

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.sender)
                    .font(.headline)
                if let code = message.code, !code.isEmpty {
                    Text(code)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        .textSelection(.enabled)
                }
                Spacer()
                Text(message.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.content)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

private struct ComposeSheet: View {
    let onSend: (String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var message = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("发送短信").font(.headline)
            TextField("号码", text: $phone)
                .textFieldStyle(.roundedBorder)
            Text("国际号码请填完整格式，例如 +86138XXXXXXXX")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("发送") {
                    sending = true
                    Task {
                        await onSend(phone, message)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || phone.trimmingCharacters(in: .whitespaces).isEmpty
                    || message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
