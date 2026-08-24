import SwiftUI

/// What the module's data path looks like from the host: whether an interface is
/// up, how much has gone through it, what is using it, and whether the machine
/// actually routes through it.
struct NetworkView: View {
    @Environment(AppModel.self) private var model

    @State private var traffic: TrafficSnapshot?
    @State private var local: LocalConnection?
    @State private var activity: ActivitySnapshot?
    @State private var diagnostic: NetworkDiagnostic?
    @State private var routeCheck: NetworkCheckResult?
    @State private var proxyCheck: NetworkCheckResult?
    @State private var busy = false
    @State private var error: String?

    /// The counters and the flow list both move on their own, so the page keeps
    /// itself current rather than waiting to be revisited.
    private static let reloadInterval = Duration.seconds(5)

    var body: some View {
        Form {
            connectionSection
            trafficSection
            activitySection
            checkSection
            moduleSection
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error {
                MessageBar(text: error, tint: .red)
            }
        }
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: Self.reloadInterval)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var connectionSection: some View {
        Section("模块网卡") {
            if let local {
                LabeledContent("接口", value: local.interface)
                LabeledContent("IP 地址", value: local.ipv4.isEmpty ? "—" : local.ipv4)
                LabeledContent("是否默认出口", value: local.isDefault ? "是" : "否")
            } else {
                Text("模块没有可用的网络接口")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var trafficSection: some View {
        Section("流量") {
            if let traffic, traffic.available {
                LabeledContent("接口", value: traffic.interface ?? "—")
                LabeledContent("本次会话", value: ByteCount.describe(traffic.sessionTotal))
                LabeledContent(
                    "下行 / 上行",
                    value: "\(ByteCount.describe(traffic.sessionRX)) / \(ByteCount.describe(traffic.sessionTX))")
                LabeledContent(
                    "开机累计",
                    value: "\(ByteCount.describe(traffic.rxBytes)) / \(ByteCount.describe(traffic.txBytes))")
            } else if let message = traffic?.error, !message.isEmpty {
                Text(message).foregroundStyle(.secondary)
            } else {
                // Counters belonging to some other interface would be worse than
                // none at all, which is why the core reports nothing here.
                Text("模块网卡未启用，没有可统计的流量")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        Section("联网活动") {
            if let activity, activity.available {
                if let tunnel = activity.tunnelInterface,
                    let physical = activity.physicalInterface,
                    tunnel != physical
                {
                    Text("流量经隧道 \(tunnel) 转发，以下连接读自该接口")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                let connections = activity.connections ?? []
                if connections.isEmpty {
                    Text("当前没有连接").foregroundStyle(.secondary)
                } else {
                    ForEach(connections) { record in
                        ActivityRow(record: record)
                    }
                }
            } else {
                Text("模块未联网")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var checkSection: some View {
        Section("连通性") {
            CheckRow(title: "是否走 4G 模块", result: routeCheck)
            CheckRow(title: "本地代理", result: proxyCheck)
            HStack {
                Button("检测") {
                    Task { await runChecks() }
                }
                .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var moduleSection: some View {
        if let diagnostic {
            Section("模块数据配置") {
                LabeledContent("USB 组合", value: diagnostic.usbcfg.isEmpty ? "—" : diagnostic.usbcfg)
                LabeledContent("usbnet", value: diagnostic.usbnetMode.isEmpty ? "—" : diagnostic.usbnetMode)
                LabeledContent(
                    "默认出口",
                    value: diagnostic.defaultRoute.interface.isEmpty
                        ? "—" : diagnostic.defaultRoute.interface)
                ForEach(diagnostic.pdpContexts ?? []) { context in
                    LabeledContent("承载 \(context.id)", value: "\(context.apn)（\(context.pdn)）")
                        .foregroundStyle(
                            (diagnostic.activeContexts ?? []).contains(context.id) ? .primary : .secondary)
                }
                if let addresses = diagnostic.pdpAddresses, !addresses.isEmpty {
                    LabeledContent("分配地址", value: addresses.joined(separator: "、"))
                }
            }
            if let errors = diagnostic.errors, !errors.isEmpty {
                Section("读取失败的项") {
                    ForEach(errors.sorted(by: { $0.key < $1.key }), id: \.key) { key, message in
                        LabeledContent(key, value: message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func reload() async {
        guard let transport = model.transport else { return }
        do {
            // Sampled together so the page describes one moment rather than four.
            async let traffic = transport.networkTraffic()
            async let local = transport.networkLocal()
            async let activity = transport.networkActivity()
            async let diagnostic = transport.networkDiagnostic()
            self.traffic = try await traffic
            self.local = try await local
            self.activity = try await activity
            self.diagnostic = try await diagnostic
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runChecks() async {
        guard let transport = model.transport else { return }
        busy = true
        defer { busy = false }
        do {
            routeCheck = try await transport.check4GRoute()
            proxyCheck = try await transport.checkProxyRoute()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct CheckRow: View {
    let title: String
    let result: NetworkCheckResult?

    var body: some View {
        LabeledContent(title) {
            if let result {
                VStack(alignment: .trailing, spacing: 2) {
                    Label(result.summary, systemImage: result.ok ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(result.ok ? Color.green : Color.orange)
                    Text(result.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                Text("未检测").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ActivityRow: View {
    let record: ActivityRecord

    var body: some View {
        LabeledContent {
            Text("\(ByteCount.describe(record.rxBytes)) ↓  \(ByteCount.describe(record.txBytes)) ↑")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.process)
                Text("\(record.protocolName)  \(record.remote)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A one-line message pinned under a page.
struct MessageBar: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack {
            Text(text)
                .font(.callout)
                .foregroundStyle(tint)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Byte counts, rendered the way a person reads them.
///
/// Written out rather than delegated to ByteCountFormatter, which is not
/// Sendable and so cannot be held in a shared constant under strict
/// concurrency — and building one per row to render a number is not a trade
/// worth making.
enum ByteCount {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

    static func describe(_ bytes: UInt64) -> String {
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit + 1 < units.count {
            value /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(bytes) B"
        }
        return String(format: value < 10 ? "%.2f %@" : "%.1f %@", value, units[unit])
    }
}
