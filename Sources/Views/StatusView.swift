import SwiftUI

struct StatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                ProgressView("正在启动 DJOneHub 核心…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                FailureView(message: message)
            case .ready:
                content
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    @ViewBuilder
    private var content: some View {
        if let status = model.status {
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
            .overlay(alignment: .bottom) {
                if let error = model.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(8)
                }
            }
        } else {
            ProgressView("正在读取模块状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("核心未能启动")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
