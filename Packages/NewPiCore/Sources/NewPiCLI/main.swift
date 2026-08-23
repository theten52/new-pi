import Foundation
import NewPiCore

@main
enum NewPiCLI {
    static func main() async {
        let configStore = ProviderConfigStore()
        let credentialResolver = ProviderCredentialResolver()

        print("new-pi")
        print("config: \(NewPiConfig.defaultAgentDirectory.path)")
        print("providers: \(configStore.configURL.path)")

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
