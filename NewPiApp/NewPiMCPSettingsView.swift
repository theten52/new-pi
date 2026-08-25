import AppKit
import Foundation
import NewPiCore
import SwiftUI

@MainActor
final class MCPPluginManagerBridge: ObservableObject {
    @Published private(set) var serverStatuses: [MCPServerStatus] = []
    @Published var allowMCPTools: Bool = MCPPreferences.allowMCPToolsInChat

    func refresh() async {
        await MCPPluginManager.shared.reloadConfiguration()
        serverStatuses = await MCPPluginManager.shared.serverStatuses()
    }

    func setServerEnabled(_ enabled: Bool, serverId: String) async {
        await MCPPluginManager.shared.setServerEnabled(enabled, serverId: serverId)
        await refresh()
    }

    func restartServer(serverId: String) async {
        await MCPPluginManager.shared.restartServer(serverId: serverId)
        await refresh()
    }

    func reloadConfiguration() async {
        await refresh()
    }

    func shutdownAll() async {
        await MCPPluginManager.shared.shutdownAll()
        await refresh()
    }

    func applyAllowMCPTools(_ enabled: Bool) async {
        MCPPreferences.allowMCPToolsInChat = enabled
        allowMCPTools = enabled
        if !enabled {
            await shutdownAll()
        }
        await refresh()
    }
}

struct NewPiMCPSettingsView: View {
    @ObservedObject var bridge: MCPPluginManagerBridge
    @State private var showConsentAlert = false

    var body: some View {
        Section("MCP Plugins") {
            Toggle("Allow MCP tools in chat", isOn: $bridge.allowMCPTools)
                .onChange(of: bridge.allowMCPTools) { _, enabled in
                    handleAllowMCPToolsChanged(enabled)
                }

            Text("When enabled, NewPi may run third-party commands from ~/.new-pi/agent/mcp.json. MCP servers run with your macOS user permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Reload configuration") {
                    Task { await bridge.reloadConfiguration() }
                }
                Button("Open mcp.json in Finder") {
                    openConfigInFinder()
                }
            }

            if bridge.serverStatuses.isEmpty {
                Text("No MCP servers found. Add servers to ~/.new-pi/agent/mcp.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bridge.serverStatuses) { status in
                    NewPiMCPServerRow(bridge: bridge, status: status)
                }
            }
        }
        .alert("Enable MCP tools?", isPresented: $showConsentAlert) {
            Button("Cancel", role: .cancel) {
                bridge.allowMCPTools = false
            }
            Button("Enable") {
                MCPPreferences.mcpConsentAcknowledged = true
                Task { await bridge.applyAllowMCPTools(true) }
            }
        } message: {
            Text("This will run third-party commands configured in mcp.json on your Mac. Those processes may access files, network, and other resources available to your user account.")
        }
        .task {
            await bridge.refresh()
        }
    }

    private func handleAllowMCPToolsChanged(_ enabled: Bool) {
        if enabled, !MCPPreferences.mcpConsentAcknowledged {
            bridge.allowMCPTools = false
            showConsentAlert = true
            return
        }
        Task {
            await bridge.applyAllowMCPTools(enabled)
        }
    }

    private func openConfigInFinder() {
        let configURL = MCPConfigPaths.configURL()
        try? MCPConfigPaths.ensureConfigDirectory()
        if !FileManager.default.fileExists(atPath: configURL.path) {
            FileManager.default.createFile(
                atPath: configURL.path,
                contents: Data("{\n  \"mcpServers\": {}\n}\n".utf8)
            )
        }
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }
}

private struct NewPiMCPServerRow: View {
    @ObservedObject var bridge: MCPPluginManagerBridge
    let status: MCPServerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status.id)
                    .font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { status.isEnabled },
                    set: { enabled in
                        Task { await bridge.setServerEnabled(enabled, serverId: status.id) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            HStack(spacing: 12) {
                Label(status.state.rawValue, systemImage: stateIcon)
                Text("\(status.toolCount) tools")
                    .foregroundStyle(.secondary)
                if status.isInCooldown {
                    Text("Cooldown")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)

            if let lastError = status.lastError, status.state == .failed {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Restart server") {
                Task { await bridge.restartServer(serverId: status.id) }
            }
            .disabled(!status.isEnabled)
        }
        .padding(.vertical, 4)
    }

    private var stateIcon: String {
        switch status.state {
        case .ready: "checkmark.circle.fill"
        case .starting: "hourglass"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        }
    }
}
