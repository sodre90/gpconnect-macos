import SwiftUI

struct IPRangesEditorView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var selection: Set<UUID> = []
    @State private var newCIDR = ""
    @State private var newLabel = ""
    @State private var importText = ""
    @State private var showImport = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            rangesList
            Divider()
            addRangeBar
        }
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showImport) {
            importSheet
        }
    }

    private var toolbar: some View {
        HStack {
            Text("IP Ranges (\(vpnManager.config.ipRanges.count))")
                .font(.headline)
            Spacer()
            Button("Import...") { showImport = true }
            Button("Enable All") {
                for i in vpnManager.config.ipRanges.indices {
                    vpnManager.config.ipRanges[i].enabled = true
                }
                vpnManager.saveConfig()
            }
            Button("Disable All") {
                for i in vpnManager.config.ipRanges.indices {
                    vpnManager.config.ipRanges[i].enabled = false
                }
                vpnManager.saveConfig()
            }
        }
        .padding(12)
    }

    private var rangesList: some View {
        List(selection: $selection) {
            ForEach($vpnManager.config.ipRanges) { $range in
                HStack {
                    Toggle("", isOn: $range.enabled)
                        .toggleStyle(.checkbox)
                        .onChange(of: range.enabled) { vpnManager.saveConfig() }
                    TextField("CIDR", text: $range.cidr)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 160)
                        .onSubmit { vpnManager.saveConfig() }
                    TextField("Label", text: $range.label)
                        .foregroundColor(.secondary)
                        .onSubmit { vpnManager.saveConfig() }
                    Spacer()
                    Button(role: .destructive) {
                        vpnManager.config.ipRanges.removeAll { $0.id == range.id }
                        vpnManager.saveConfig()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onMove { from, to in
                vpnManager.config.ipRanges.move(fromOffsets: from, toOffset: to)
                vpnManager.saveConfig()
            }
        }
    }

    private var addRangeBar: some View {
        HStack {
            TextField("CIDR (e.g. 10.0.0.0/8)", text: $newCIDR)
                .font(.system(.body, design: .monospaced))
                .frame(width: 180)
            TextField("Label (optional)", text: $newLabel)
            Button("Add") {
                guard !newCIDR.isEmpty else { return }
                vpnManager.config.ipRanges.append(IPRange(cidr: newCIDR, label: newLabel))
                vpnManager.saveConfig()
                newCIDR = ""
                newLabel = ""
            }
            .disabled(newCIDR.isEmpty)
        }
        .padding(12)
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import IP Ranges")
                .font(.headline)
            Text("Paste CIDR ranges, one per line. Optionally add a label after a space or comma.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $importText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 200)
            HStack {
                Button("Cancel") { showImport = false }
                Spacer()
                Button("Import") {
                    importRanges()
                    showImport = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450)
    }

    private func importRanges() {
        let lines = importText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: " ,\t"))
                .filter { !$0.isEmpty }
            let cidr = parts[0]
            let label = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
            if cidr.contains("/") || cidr.contains(".") {
                vpnManager.config.ipRanges.append(IPRange(cidr: cidr, label: label))
            }
        }
        vpnManager.saveConfig()
        importText = ""
    }
}
