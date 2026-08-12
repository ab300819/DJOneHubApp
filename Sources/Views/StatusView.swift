import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.status {
            case let .device(status):
                deviceForm(status)
            case let .degraded(status):
                DegradedView(status: status)
            case nil:
                ProgressView("正在读取模块状态…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = model.lastError {
                HStack {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private func deviceForm(_ status: ModemStatus) -> some View {
        Form {
            Section("模块") {
                LabeledContent("IMEI", value: status.imei)
                LabeledContent("固件", value: status.firmware)
                LabeledContent("工作模式", value: status.usbnetModeLabel)
            }
            Section("SIM") {
                LabeledContent("状态", value: status.simInserted ? "已插入" : "未插入")
                if status.simInserted {
                    LabeledContent("ICCID", value: status.iccid)
                    LabeledContent("IMSI", value: status.imsi)
                }
            }
            Section("网络") {
                LabeledContent("运营商", value: status.operatorName.isEmpty ? "—" : status.operatorName)
                LabeledContent("注册状态", value: status.regStatusText)
                LabeledContent("制式", value: "\(status.networkMode) \(status.networkDuplex)")
                LabeledContent("频段", value: status.radioBand.isEmpty ? "—" : status.radioBand)
                LabeledContent("信号", value: "\(status.signalDBm) dBm")
                LabeledContent("RSRP / RSRQ", value: "\(status.signalRSRP) / \(status.signalRSRQ)")
            }
        }
        .formStyle(.grouped)
    }
}

/// Shown when the core sees the USB device but no AT channel answered, which is
/// a normal state right after a mode switch re-enumerates the module.
private struct DegradedView: View {
    let status: DegradedStatus

    var body: some View {
        Form {
            Section("模块") {
                LabeledContent("硬件", value: status.hardwareStatus)
                LabeledContent("状态", value: status.operatorName)
                LabeledContent("网络", value: status.networkMode)
            }
            if !status.discoveryError.isEmpty {
                Section("发现错误") {
                    Text(status.discoveryError)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
