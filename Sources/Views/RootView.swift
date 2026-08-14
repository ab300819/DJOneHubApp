import SwiftUI

/// The pages the app exposes, in the order they appear in the sidebar.
enum Page: String, CaseIterable, Identifiable {
    case status
    case sms
    case at

    var id: Self { self }

    var title: String {
        switch self {
        case .status: "模块状态"
        case .sms: "短信"
        case .at: "AT 调试"
        }
    }

    var symbol: String {
        switch self {
        case .status: "antenna.radiowaves.left.and.right"
        case .sms: "message"
        case .at: "terminal"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Page = .status

    var body: some View {
        switch model.phase {
        case .starting:
            ProgressView("正在启动 DJOneHub 核心…")
                .frame(minWidth: 720, minHeight: 460)
        case let .failed(message):
            FailureView(message: message)
                .frame(minWidth: 720, minHeight: 460)
        case .ready:
            NavigationSplitView {
                List(Page.allCases, selection: $selection) { page in
                    Label(page.title, systemImage: page.symbol)
                        .tag(page)
                }
                .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 240)
            } detail: {
                detail
                    .navigationTitle(selection.title)
            }
            .frame(minWidth: 720, minHeight: 460)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .status: StatusView()
        case .sms: SMSView()
        case .at: ATConsoleView()
        }
    }
}

struct FailureView: View {
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
