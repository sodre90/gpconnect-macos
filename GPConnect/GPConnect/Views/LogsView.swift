import SwiftUI
import AppKit

struct LogsView: View {
    @EnvironmentObject var vpnManager: VPNManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connection Log")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(vpnManager.connectionLog.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") {
                    vpnManager.connectionLog.removeAll()
                }
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vpnManager.connectionLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: vpnManager.connectionLog.count) {
                    proxy.scrollTo(vpnManager.connectionLog.count - 1, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(vpnManager.connectionLog.count - 1, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
