import Foundation
import NewPiCore

@main
enum NewPiCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.first == "sessions" {
            await SessionCommands.run(Array(args.dropFirst()))
            return
        }

        if args.first == "help" || args.first == "-h" || args.first == "--help" {
            printRootUsage()
            return
        }

        if !args.isEmpty {
            fputs("Unknown command: \(args.joined(separator: " "))\n", stderr)
            printRootUsage()
            exit(1)
        }

        await printProviderStatus()
    }

    private static func printRootUsage() {
        print(
            """
            Usage:
              new-pi                         Show provider configuration status
              new-pi sessions list [--project PATH]
              new-pi sessions show <id> [--project PATH]
              new-pi help
            """
        )
    }

    private static func printProviderStatus() async {
        let configStore = ProviderConfigStore()
        let credentialResolver = ProviderCredentialResolver()

        print("new-pi")
        print("config: \(NewPiConfig.defaultAgentDirectory.path)")
        print("providers: \(configStore.configURL.path)")
        print("sessions: \(SessionManager.sessionsRoot().path)")

        do {
            let config = try configStore.load()
            let profile = try config.defaultProfile()
            let ready = await credentialResolver.hasAPIKey(for: profile)
            print("")
            print("default provider: \(profile.name)")
            print("  preset: \(profile.preset.rawValue)")
            print("  model:  \(profile.modelID)")
            print("  key:    \(ready ? "configured" : "missing")")
            print("")
            print("Profiles (\(config.profiles.count)):")
            for item in config.profiles {
                let itemReady = await credentialResolver.hasAPIKey(for: item)
                let mark = item.id == config.defaultProfileID ? "*" : " "
                print(" \(mark) \(item.name) [\(item.preset.rawValue)] \(item.modelID) — key \(itemReady ? "ok" : "missing")")
            }
        } catch {
            print("")
            print("provider config error: \(error.localizedDescription)")
        }
    }
}
