import Foundation
import NewPiCore

@main
enum NewPiCLI {
    static func main() async {
        let resolver = CredentialResolver()
        let hasKey = (try? await resolver.hasAPIKey(for: .anthropic)) ?? false

        print("new-pi")
        print("config: \(NewPiConfig.defaultAgentDirectory.path)")
        print("anthropic key: \(hasKey ? "configured" : "missing")")
        print("")
        print("Set ANTHROPIC_API_KEY or save a key in NewPi Settings (Keychain).")
        print("Phase 3 will add read/bash/edit/write tools to the CLI.")
    }
}
