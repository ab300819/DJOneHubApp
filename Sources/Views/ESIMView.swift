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

    /// Notes read from the module's own phonebook, keyed by ICCID. Absent when
    /// the module has no writable phonebook, which is a capability rather than
    /// a failure — so it is kept apart from `error`.
    @State private var notes: ModuleNotes?
    @State private var editingNote: ModuleProfileNote?
    @State private var probe: PhonebookProbe?
    @State private var probing = false

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
            } else if let overview, overview.physicalSIM {
                physicalSIMSection(overview.message)
            } else {
                healthSection
                cardSection
                profileSections
                phonebookSection
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
            DownloadSheet(euiccs: overview?.card?.chipInfo?.eids ?? []) { request in
                Task { await download(request) }
            }
        }
        .sheet(item: $editingNote) { note in
            ModuleNoteSheet(note: note) { edited in
                Task { await saveNote(edited) }
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
                    LabeledContent(
                        "Profile", value: active.name.isEmpty ? Identifier.masked(active.iccid) : active.name)
                    LabeledContent("ICCID") { IdentifierText(value: active.iccid) }
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

    /// A module with an ordinary SIM has no eUICC to enumerate. Saying so is
    /// the whole content of the page in that case; without it the page is blank
    /// and reads as a failure.
    @ViewBuilder
    private func physicalSIMSection(_ message: String?) -> some View {
        Section {
            ContentUnavailableView(
                "这是实体 SIM 卡", systemImage: "simcard",
                description: Text(message ?? "模块中没有可管理的 eUICC，Profile 操作不适用。"))
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
            if let euiccs = chip.eids, !euiccs.isEmpty {
                Section(euiccs.count > 1 ? "已识别 eUICC（\(euiccs.count) 个）" : "已识别 eUICC") {
                    ForEach(euiccs) { EUICCRow(euicc: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private var profileSections: some View {
        if let groups = overview?.card?.profiles, !groups.isEmpty {
            ForEach(groups) { group in
                Section {
                    let profiles = group.profiles ?? []
                    if profiles.isEmpty {
                        Text("卡上没有 Profile").foregroundStyle(.secondary)
                    } else {
                        ForEach(profiles) { profile in
                            ProfileRow(
                                profile: profile,
                                note: notes?.notes?[profile.iccid],
                                busy: rowBusy(profile.iccid),
                                onEnable: { Task { await enable(profile, aid: group.aidHex) } },
                                onEditNote: notes == nil
                                    ? nil
                                    : {
                                        editingNote = notes?.notes?[profile.iccid]
                                            ?? ModuleProfileNote(
                                                iccid: profile.iccid, label: "", phone: "", tags: "")
                                    },
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
                } header: {
                    Text(groups.count > 1 ? "eUICC \(group.aidHex.prefix(16))" : "Profile")
                } footer: {
                    if let notes, group.id == groups.last?.id {
                        Text("模块资料库已用 \(notes.used)/\(notes.total) 条")
                    }
                }
            }
        } else if busy == .loading {
            Section { ProgressView("正在读取卡片…") }
        }
    }

    /// Asks the module what its card-side phonebook can do, using queries
    /// only. Nothing is written, so running this leaves no contact behind.
    @ViewBuilder
    private var phonebookSection: some View {
        Section {
            if let probe {
                CapabilityRow(
                    title: "SIM 通讯录", ok: probe.storageSupported,
                    detail: probe.storageSupported ? "支持 SM 卡内存储" : "未发现 SM 卡内存储")
                CapabilityRow(
                    title: "选中存储", ok: probe.storageSelected,
                    detail: probe.storageSelected ? "已选中 SM 存储" : "无法选中 SM 存储")
                CapabilityRow(
                    title: "读取能力", ok: probe.readSupported,
                    detail: probe.readSupported ? "支持读取卡内联系人" : "模块未确认读取命令")
                CapabilityRow(
                    title: "写入接口", ok: probe.writeSupported,
                    detail: probe.writeSupported ? "声明支持写入接口" : "模块未确认写入命令")
                CapabilityRow(
                    title: "当前状态", ok: probe.storageUsable,
                    detail: probe.capacityLine)
            }
            HStack {
                Button(probe == nil ? "检测" : "重新检测") {
                    Task { await runProbe() }
                }
                .disabled(probing)
                if probing {
                    ProgressView().controlSize(.small)
                }
            }
        } header: {
            Text("卡内通讯录")
        } footer: {
            if let probe {
                Text(
                    probe.portable
                        ? "当前 Profile 支持卡内通讯录读写；检测过程没有写入任何联系人。"
                        : "当前 Profile 未完整确认卡内通讯录读写能力；不会进行写入。")
            } else {
                Text("只发送查询命令，不会写入联系人。")
            }
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
        // A module without a writable phonebook simply cannot hold notes; that
        // reads as nil here and hides the editor rather than raising an error.
        notes = try? await transport.moduleNotes()
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

    /// Writes the note into the module's own phonebook. Clearing every field
    /// deletes the record, which is the only way to remove one.
    private func saveNote(_ note: ModuleProfileNote) async {
        guard let transport = model.transport else { return }
        do {
            let result = try await transport.saveModuleNote(note)
            notice = result.message
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        notes = try? await transport.moduleNotes()
    }

    private func runProbe() async {
        guard let transport = model.transport else { return }
        probing = true
        defer { probing = false }
        do {
            probe = try await transport.probePhonebook()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
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
    let note: ModuleProfileNote?
    let busy: Bool
    let onEnable: () -> Void
    /// Nil when the module has no phonebook to write to, which is what removes
    /// the menu item rather than leaving a control that cannot work.
    let onEditNote: (() -> Void)?
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
                    if let onEditNote {
                        Button("模块资料…", action: onEditNote)
                    }
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
                if !profile.serviceProviderName.isEmpty {
                    Text(profile.serviceProviderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                IdentifierText(value: profile.iccid)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let note, !note.isEmpty {
                    Text(Self.describe(note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func describe(_ note: ModuleProfileNote) -> String {
        [note.label, note.phone, note.tags]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// One answer from the phonebook probe.
private struct CapabilityRow: View {
    let title: String
    let ok: Bool
    let detail: String

    var body: some View {
        LabeledContent(title) {
            Label(detail, systemImage: ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.callout)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Edits the note the module itself stores for a profile.
///
/// Worth the round trip to the module rather than a local file: the record
/// lives in the module's phonebook, so it is still there when the same card is
/// read from another machine.
private struct ModuleNoteSheet: View {
    let note: ModuleProfileNote
    let onSubmit: (ModuleProfileNote) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var phone: String
    @State private var tags: String

    init(note: ModuleProfileNote, onSubmit: @escaping (ModuleProfileNote) -> Void) {
        self.note = note
        self.onSubmit = onSubmit
        _label = State(initialValue: note.label)
        _phone = State(initialValue: note.phone)
        _tags = State(initialValue: note.tags)
    }

    private var edited: ModuleProfileNote {
        ModuleProfileNote(
            index: note.index, iccid: note.iccid,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: phone.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: tags.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Form {
            Section {
                TextField("模块内名称", text: $label, prompt: Text("可选"))
                TextField("模块号码", text: $phone, prompt: Text("可选"))
                TextField("用途标签", text: $tags, prompt: Text("例如：英国验证码"))
            } header: {
                Text("模块资料")
            } footer: {
                Text("保存在模块自己的通讯录里，按 ICCID 关联 Profile \(note.iccid)。三项都留空即删除这条记录。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(edited.isEmpty ? "删除" : "保存") {
                    onSubmit(edited)
                    dismiss()
                }
            }
        }
    }
}

/// Collects what an SM-DP+ needs. The activation code carries the server and the
/// matching id together, so pasting one fills both.
private struct DownloadSheet: View {
    /// With more than one eUICC on the card the target has to be chosen; left
    /// empty, the core picks.
    let euiccs: [ESIMEUICC]
    let onSubmit: (ESIMDownloadRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var activationCode = ""
    @State private var smdp = ""
    @State private var matchingID = ""
    @State private var confirmationCode = ""
    @State private var aid = ""

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
                if euiccs.count > 1 {
                    Picker("目标 eUICC", selection: $aid) {
                        Text("自动").tag("")
                        ForEach(euiccs) { Text("\($0.aid) · EID \(Identifier.masked($0.eid))").tag($0.aid) }
                    }
                }
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
                                in: .whitespacesAndNewlines),
                            aid: aid))
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

/// One eUICC application, with what the card reports about it.
private struct EUICCRow: View {
    let euicc: ESIMEUICC

    var body: some View {
        LabeledContent {
            Text(euicc.specLabel).foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("EID \(euicc.eid)")
                    .font(.callout.monospacedDigit())
                    .textSelection(.enabled)
                Text(
                    [("AID", euicc.aid), ("可用空间", euicc.freeNvram), ("固件", euicc.firmware)]
                        .compactMap { label, value in
                            value.flatMap { $0.isEmpty ? nil : "\(label) \($0)" }
                        }
                        .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }
}

/// An identifier shown masked by default, with a toggle to reveal it and a
/// button that copies the full value either way.
private struct IdentifierText: View {
    let value: String
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(revealed ? value : Identifier.masked(value))
                .monospacedDigit()
                .textSelection(.enabled)
            Button(revealed ? "隐藏" : "显示") { revealed.toggle() }
            Button(copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
            }
        }
        .buttonStyle(.link)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Masks the middle of an identifier such as an ICCID, so a screenshot does
/// not carry it whole while the ends still tell two apart.
enum Identifier {
    static func masked(_ value: String, keep: Int = 4) -> String {
        guard value.count > keep * 2 else { return value }
        let dots = String(repeating: "•", count: max(4, value.count - keep * 2))
        return "\(value.prefix(keep)) \(dots) \(value.suffix(keep))"
    }
}
