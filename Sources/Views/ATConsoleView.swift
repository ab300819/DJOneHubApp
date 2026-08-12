import SwiftUI

/// A console for sending raw AT commands.
///
/// The core accepts anything starting with "AT" and passes it through, so this
/// page can change network registration, USB composition and SIM state. It is
/// deliberately plain: no command builder, because guessing at intent here
/// would be worse than showing exactly what was sent and what came back.
struct ATConsoleView: View {
    @EnvironmentObject private var model: AppModel

    @State private var command = ""
    @State private var entries: [Entry] = []
    @State private var sending = false

    struct Entry: Identifiable {
        let id = UUID()
        let command: String
        let response: String
        let failed: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            warning
        }
    }

    private var warning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("指令会直接作用于模块。不清楚含义的命令不要执行，尤其是写入类。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty {
                        Text("试试 ATI、AT+CSQ、AT+QCFG=\"usbnet\"")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 48)
                    }
                    ForEach(entries) { entry in
                        EntryView(entry: entry).id(entry.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: entries.count) { _ in
                if let last = entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("AT 指令", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(send)
                .disabled(sending)
            Button(action: send) {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Text("发送")
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(sending || command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
    }

    private func send() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !sending, let transport = model.transport else { return }
        sending = true
        command = ""
        Task {
            do {
                let response = try await transport.executeAT(text)
                entries.append(Entry(command: text, response: response, failed: false))
            } catch {
                entries.append(
                    Entry(command: text, response: error.localizedDescription, failed: true))
            }
            sending = false
        }
    }
}

private struct EntryView: View {
    let entry: ATConsoleView.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                Text(entry.command)
                    .font(.system(.body, design: .monospaced).weight(.medium))
            }
            Text(entry.response)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(entry.failed ? .red : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
