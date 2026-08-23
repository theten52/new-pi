# NewPi Xcode setup

1. Open Xcode → **File → New → Project → macOS → App**
2. Product Name: **NewPi**
3. Interface: **SwiftUI**, Language: **Swift**
4. Save inside this repository (e.g. `new-pi/NewPi/`)

## Add NewPiCore

1. **File → Add Package Dependencies → Add Local…**
2. Select `Packages/NewPiCore`
3. Link product **NewPiCore** to the NewPi target

## Add app sources

Add existing files to the target:

- `NewPiApp/NewPiApp.swift`
- `NewPiApp/NewPiViewModel.swift`

Remove the template `ContentView.swift` if present.

## Run

```bash
cd Packages/NewPiCore && swift test
```

Then build **NewPi** in Xcode.

1. Open **Settings → NewPi** (or `Cmd+,`)
2. Paste your Anthropic API key → **Save API Key** (stored in Keychain service `com.new-pi.credentials`)
3. Or export `ANTHROPIC_API_KEY` in your shell
4. Open a project folder and chat

Until Phase 3, the agent can converse but has no built-in coding tools yet.

## Config paths

- Global: `~/.new-pi/agent/`
- Project: `<repo>/.new-pi/`
