import SwiftUI

/// The card's profiles, and the operations on them.
///
/// This is also where the core's progress events land. A profile download runs
/// for tens of seconds and the core reports how far along it is; until this page
/// existed there was nothing listening, so the events were produced and thrown
/// away.
struct ESIMView: View {
    @Environment(AppModel.self) private var model

    @State private var overview: ESIMOverviewResult?
    @State private var health: ESIMHealthResult?
    @State private var unavailable: String?
    @State private var notice: String?
    @State private var error: String?

    @State private var busy: Busy?

    @State private var renaming: ESIMProfile?
    @State private var renameText = ""
    @State private var confirmingDelete: ProfileRef?
    @State private var showingDownload = false

    /// Which operation is in flight, so only the affected row is disabled rather
    /// than the whole page.
    private enum Busy: Equatable {
        case loading
        case switching(String)
        case deleting(String)
        case renaming(String)
        case downloading
    }

    /// A profile is identified by its ICCID together with the eUICC it lives in.
    private struct ProfileRef: Identifiable, Equatable {
        let iccid: String
        let aid: String
        let name: String
        var id: String { "\(aid)|\(iccid)" }
    }

    var body: some View {
        Form {
            if let progress = model.downloadProgress {
                Section("正在下载 Profile") {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.percent), total: 100)
                        HStack {
                            Text(progress.message.isEmpty ? "进行中…" : progress.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(progress.percent)%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let unavailable {
                Section {
                    ContentUnavailableView(
                        "eSIM 不可用", systemImage: "simcard.2", description: Text(unavailable))
                }
            } else {
                healthSection
                cardSection
                profileSections
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button {
                showingDownload = true
            } label: {
                Label("下载 Profile", systemImage: "arrow.down.circle")
            }
            .disabled(unavailable != nil || busy != nil)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error {
                MessageBar(text: error, tint: .red)
            } else if let notice {
                MessageBar(text: notice, tint: .secondary)
            }
        }
        .sheet(isPresented: $showingDownload) {
            DownloadSheet { request in
                Task { await download(request) }
            }
        }
        .alert("重命名 Profile", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let profile = renaming {
                    let name = renameText
                    renaming = nil
                    Task { await rename(profile, to: name) }
                }
            }
        }
        .alert(
            "删除 Profile",
            isPresented: .init(
                get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
        ) {
            Button("取消", role: .cancel) { confirmingDelete = nil }
            Button("删除", role: .destructive) {
                if let target = confirmingDelete {
                    confirmingDelete = nil
                    Task { await delete(target) }
                }
            }
        } message: {
            Text("删除后无法恢复，需要重新从运营商下载。")
        }
        .task {
            await reload()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var healthSection: some View {
        if let health, !health.physicalSIM {
            Section("当前使用") {
                if let active = health.activeProfile {
                    LabeledContent("Profile", value: active.name.isEmpty ? active.iccid : active.name)
                    LabeledContent("ICCID", value: active.iccid)
                }
                LabeledContent("运营商", value: health.operatorName ?? "—")
                LabeledContent("注册状态", value: health.registration ?? "—")
                if !health.ok, let message = health.message, !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var cardSection: some View {
        if let chip = overview?.card?.chipInfo {
            Section("卡片") {
                LabeledContent("型号", value: chip.skuName ?? "—")
                LabeledContent("序列号", value: chip.serialNumber ?? "—")
                LabeledContent("固件", value: chip.firmware ?? "—")
            }
        }
    }

    @ViewBuilder
    private var profileSections: some View {
        if let groups = overview?.card?.profiles, !groups.isEmpty {
            ForEach(groups) { group in
                Section(groups.count > 1 ? "eUICC \(group.aidHex.prefix(16))" : "Profile") {
                    let profiles = group.profiles ?? []
                    if profiles.isEmpty {
                        Text("卡上没有 Profile").foregroundStyle(.secondary)
                    } else {
                        ForEach(profiles) { profile in
                            ProfileRow(
                                profile: profile,
                                busy: rowBusy(profile.iccid),
                                onEnable: { Task { await enable(profile, aid: group.aidHex) } },
                                onRename: {
                                    renameText = profile.name
                                    renaming = profile
                                },
                                onDelete: {
                                    confirmingDelete = ProfileRef(
                                        iccid: profile.iccid, aid: group.aidHex, name: profile.name)
                                })
                        }
                    }
                }
            }
        } else if busy == .loading {
            Section { ProgressView("正在读取卡片…") }
        }
    }

    private func rowBusy(_ iccid: String) -> Bool {
        switch busy {
        case .switching(iccid), .deleting(iccid), .renaming(iccid): true
        case .downloading: true
        default: false
        }
    }

    // MARK: - Operations

    private func reload() async {
        guard let transport = model.transport else { return }
        busy = .loading
        defer { if busy == .loading { busy = nil } }
        do {
            overview = try await transport.esimOverview()
            unavailable = nil
        } catch {
            // No eUICC is a state, not a fault: a physical SIM or a module
            // without a card reaches here too.
            unavailable = error.localizedDescription
            return
        }
        // Health needs the module's registration as well as the card, so it can
        // fail on its own without the card view being wrong.
        health = try? await transport.esimHealth()
    }

    private func enable(_ profile: ESIMProfile, aid: String) async {
        guard let transport = model.transport else { return }
        busy = .switching(profile.iccid)
        defer { busy = nil }
        do {
            let result = try await transport.esimSwitch(iccid: profile.iccid, aid: aid)
            error = nil
            if let warning = result.moduleRebootWarning, !warning.isEmpty {
                notice = warning
            } else if result.moduleRebootRequested {
                notice = "已切换，模块正在重启，约 \(result.reconnectWaitSeconds) 秒后恢复"
            } else {
                notice = "已切换到 \(profile.name.isEmpty ? profile.iccid : profile.name)"
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        await reload()
    }

    private func rename(_ profile: ESIMProfile, to name: String) async {
        guard let transport = model.transport else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = .renaming(profile.iccid)
        defer { busy = nil }
        do {
            let aid = aidHolding(profile.iccid)
            let result = try await transport.esimRename(iccid: profile.iccid, aid: aid, name: trimmed)
            notice = result.message ?? "已重命名"
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        await reload()
    }

    private func delete(_ target: ProfileRef) async {
        guard let transport = model.transport else { return }
        busy = .deleting(target.iccid)
        defer { busy = nil }
        do {
            let result = try await transport.esimDelete(iccid: target.iccid, aid: target.aid)
            notice = result.message ?? "已删除"
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        await reload()
    }

    private func download(_ request: ESIMDownloadRequest) async {
        guard let transport = model.transport else { return }
        busy = .downloading
        defer {
            busy = nil
            model.clearDownloadProgress()
        }
        var request = request
        request.imei = model.moduleIMEI ?? ""
        guard !request.imei.isEmpty else {
            error = "读不到模块 IMEI，SM-DP+ 下载需要它。请先确认模块状态已就绪。"
            return
        }
        do {
            let result = try await transport.esimDownload(request)
            notice = result.message ?? "下载完成"
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        await reload()
    }

    /// The eUICC a profile lives in, needed by operations that only carry an
    /// ICCID from the UI.
    private func aidHolding(_ iccid: String) -> String? {
        overview?.card?.profiles?
            .first { ($0.profiles ?? []).contains { $0.iccid == iccid } }?
            .aidHex
    }
}

/// The enabled profile cannot be deleted: doing so would leave the module with
/// no subscription and no way back short of downloading one again. Switch to
/// another profile first.
private struct ProfileRow: View {
    let profile: ESIMProfile
    let busy: Bool
    let onEnable: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if profile.isEnabled {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Button("启用", action: onEnable)
                }
                Menu {
                    Button("重命名…", action: onRename)
                    Button("删除…", role: .destructive, action: onDelete)
                        .disabled(profile.isEnabled)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .disabled(busy)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? "未命名" : profile.name)
                Text(profile.serviceProviderName.isEmpty ? profile.iccid : profile.serviceProviderName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(profile.iccid)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Collects what an SM-DP+ needs. The activation code carries the server and the
/// matching id together, so pasting one fills both.
private struct DownloadSheet: View {
    let onSubmit: (ESIMDownloadRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var activationCode = ""
    @State private var smdp = ""
    @State private var matchingID = ""
    @State private var confirmationCode = ""

    var body: some View {
        Form {
            Section("激活码") {
                TextField("LPA:1$rsp.example.com$MATCHING-ID", text: $activationCode)
                    .onChange(of: activationCode) { _, code in parse(code) }
                Text("粘贴运营商给的激活码即可，下面两项会自动填好。模块 IMEI 由 App 自动附上。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("服务器") {
                TextField("SM-DP+ 地址", text: $smdp)
                TextField("Matching ID", text: $matchingID)
                TextField("确认码（可留空）", text: $confirmationCode)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("下载") {
                    onSubmit(
                        ESIMDownloadRequest(
                            smdp: smdp.trimmingCharacters(in: .whitespacesAndNewlines),
                            matchingID: matchingID.trimmingCharacters(in: .whitespacesAndNewlines),
                            confirmationCode: confirmationCode.trimmingCharacters(
                                in: .whitespacesAndNewlines)))
                    dismiss()
                }
                .disabled(smdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Splits `LPA:1$server$matching-id`, tolerating a missing `LPA:` prefix
    /// since QR readers hand it over both ways.
    private func parse(_ code: String) {
        let body = code.hasPrefix("LPA:") ? String(code.dropFirst(4)) : code
        let parts = body.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "1" else { return }
        smdp = parts[1]
        matchingID = parts[2]
        if parts.count >= 5, !parts[4].isEmpty {
            confirmationCode = parts[4]
        }
    }
}
