# ResponseAi Mac MVP Architecture

## Product loop

```text
User focuses a reply box
        |
Command + Shift + J
        |
AccessibilityReader captures:
- focused input element
- current draft
- foreground app/window
- nearby text above the input
        |
Tiny HUD shows read/write status
        |
RewritePromptBuilder creates a compact prompt
including optional local writing profile and output language
        |
RewriteService routes:
- Vertex AI Gemini when configured
- local preview rewriter when auth is missing
        |
TextReplacer writes the generated reply back
        |
User reviews and sends manually
```

The app never presses Send. It only replaces the draft text.

`Command + Shift + U` restores the last replaced draft while the target field is still reachable.

`Command + Shift + K` starts profile-based form fill. The first press scans the focused form and previews suggested values; the second press within 20 seconds fills the approved fields. This path also never presses Submit.

If replacement cannot be verified after the app attempts to insert text, ResponseAi leaves the generated reply on the clipboard and reports a manual-paste fallback instead of claiming success.

`Run Readiness Check` verifies Accessibility, Screen Recording, Cloud Run proxy health, profile state, and the active hotkeys from the menu bar or Settings window.

## Native layers

### App Bundle

`scripts/build_app.sh` produces `dist/ResponseAi.app` from the Swift Package release binary. The bundle is configured as a menu bar app with `LSUIElement`, so it stays out of the Dock and only exposes the menu bar item plus HUD.

`scripts/run_app.sh` launches the bundled executable directly for development so shell environment variables, including temporary Vertex AI tokens, are inherited.

`scripts/build_pkg.sh` creates a `/Applications` installer package, and `scripts/build_dmg.sh` creates a drag-and-drop DMG with the app bundle and an Applications symlink. `scripts/verify_release.sh` runs the local release gate: Swift tests, script checks, Node syntax, app/pkg/dmg builds, signature checks, DMG verification, and Cloud Run proxy probing. `scripts/build_release.sh` builds both artifacts and can notarize/staple the package and DMG when `RESAI_NOTARIZE=1` plus Apple notary credentials are configured.

### AccessibilityReader

Uses `AXUIElement` to inspect the focused element and foreground window. The initial context heuristic is intentionally simple:

- find the input field frame
- collect visible text elements in the active window
- keep text above or near the input field
- rank nearby lines by distance from the input
- dedupe and trim noise
- pass the most recent lines to the model

This maps to the product idea: "look at the text above the input box."

The filter has small app profiles:

- Slack: wider horizontal padding and more chat lines
- Chrome/Safari/Arc: wider capture for web messengers and Gmail
- Mail/Outlook: deeper lookback for quoted threads
- Discord/Teams/LINE: chat-like lookback

For browser apps, ResponseAi can optionally use ScreenCaptureKit plus Vision OCR over the visible area above the focused input when Accessibility context is weak. This requires Screen Recording permission and is intended as a fallback, not the primary extraction path.

Each capture includes diagnostics:

- AX line count
- OCR line count
- whether OCR was attempted
- whether Screen Recording is authorized
- a compact HUD source label: `AX`, `OCR`, `OCR+AX`, or `No context`

### TextReplacer

Attempts direct `AXValue` replacement first. If the target app does not support that, it falls back to:

- raise the owning application
- click the captured input frame to restore focus in browser contenteditable fields
- copy generated text to the pasteboard
- send Command+A
- send Command+V
- restore the pasteboard shortly after

This fallback is useful for browser contenteditable fields and Electron apps.

After replacement, the app tries to read both the original target element and the currently focused element. If the generated text cannot be verified, the generated reply is kept on the clipboard and the UI reports that the user should paste manually.

### VoiceInputController

Typeless-style dictation into the focused field. On macOS 26+, Apple SpeechAnalyzer transcribes on-device. On macOS 14/15, `SFSpeechRecognizer` is the fallback (on-device when the locale supports it). Gemini only cleans the resulting text. Gemini never receives audio.

```text
hotkey ──> SpeechAnalyzer (macOS 26+) or SFSpeechRecognizer (macOS 14/15)
           ja_JP default, volatile preview in the voice pill
      ──> UserDictionary.apply
      ──> TextReplacer.insertAtCaret            (raw text lands instantly)
      ──> Gemini gemini-3.8-flash cleanup        (fillers / punctuation / homophones / dictionary)
      ──> TextReplacer.replaceInsertedText       (swap only the inserted range, skip if field changed)
```

Default shortcut is `Command + Shift + Space`. Default mode is toggle: one press starts listening, the next press confirms. An optional hold mode (≥ 250 ms hold listens while held and confirms on release; a quicker tap falls back to toggle) can be selected in Settings. Escape cancels while listening. After cleanup, Restore (`Command + Shift + U`) reverts to the raw transcript for 60 seconds before falling through to rewrite-draft restore.

### FormReader and FormFillPlanner

`FormReader` uses Accessibility to start from the focused element, find the owning app/window, traverse nearby AX nodes, collect text fields, text areas, and combo boxes, and pair them with likely labels from titles, placeholders, descriptions, and nearby static text.

`FormFillPlanner` sends the scanned field snapshots plus the form-fill profile to the Cloud Run proxy and asks for JSON candidates only. The Mac app filters the response locally, removes low-confidence or duplicate suggestions, skips non-empty fields, and blocks password, payment, authentication, and consent-like labels. If the proxy is unavailable or the model returns nothing usable, `LocalFormFillPlanner` fills obvious fields such as name, company, email, phone, website, address, service, and free-text purpose from the local profile.

Application still goes through `TextReplacer`, one field at a time, after the second shortcut press. Failed or unverified fields are reported in the HUD instead of being silently treated as complete.

### HUDController

Uses a non-activating `NSPanel` with a compact SwiftUI view. It does not steal focus from Slack, Chrome, or the current text field. It shows reading, generating, replaced, demo mode, restore, and error states.

### RewriteService

Keeps model access behind a small protocol:

```swift
public protocol TextRewriting {
    func rewrite(_ request: RewriteRequest) async throws -> RewriteResult
}
```

The default router prefers the Cloud Run proxy when configured. In proxy mode, the Mac app sends only the prompt payload; project, location, and model are intentionally not sent by the client. If no proxy is configured, the older direct-Vertex development path can still use local config and a bearer token. If neither path is available, local preview mode is used.

Builds must not bundle a Cloud Run proxy endpoint or shared key. Configure `RESAI_VERTEX_PROXY_URL` and `RESAI_PROXY_SHARED_SECRET` through a local environment or secret manager before using proxy mode. Direct-Vertex development can opt out with `RESAI_DISABLE_BUNDLED_PROXY=1`.

Generated replies pass through a final sanitizer that removes common model wrappers such as `返信文:`, surrounding quotes, single list markers, and Markdown code fences before insertion.

Rewrite language is stored locally and can be set to Japanese, English, or Auto. Japanese remains the default for existing behavior; English instructs the model to translate Japanese draft/context intent into natural English; Auto follows the dominant language in the visible context and draft.

### User Profile

The local writing profile stores optional fields in user defaults:

- display name
- company
- department
- role
- email
- phone
- website
- address
- social/profile URL
- background
- service description
- form-fill notes
- writing style
- preferred phrases
- avoided phrases

The user can enable or disable profile use per rewrite session from Settings. The profile can be imported or exported as JSON, and cleared locally. When enabled for rewrites, the prompt includes writing guidance and business context, but contact fields are not included in normal reply rewrites. Contact details are included only in explicit form-fill requests. The system instruction tells the model not to disclose profile details unless the conversation requires it.

### Shortcuts

Rewrite, Restore, and Form Fill each use a global Command + Shift shortcut. Users can change the letter key in Settings. Shortcut settings are stored locally, sanitized to avoid duplicates, used by the menu key equivalents, and re-registered immediately when changed.

### Vertex AI

The request shape targets the publisher model endpoint:

```text
POST /v1/projects/{project}/locations/{location}/publishers/google/models/{model}:generateContent
```

For production-style use, the model is configured centrally through Cloud Run environment variables. The default is `gemini-3.5-flash`, because this use case benefits from stronger reply quality while keeping latency reasonable. The Mac app UI does not expose project, location, or model selection to users.

The deployment project is supplied by the operator and must not be committed to the repository:

```text
RESAI_VERTEX_PROJECT_ID=<your-gcp-project-id>
RESAI_GCP_PROJECT_NUMBER=<your-gcp-project-number>
```

`scripts/configure_gcp_project.sh` writes these values into the `ai.res.resai` app defaults and sets the active `gcloud` project when the CLI is available.

### Cloud Run Proxy

`services/vertex-proxy` is a dependency-free Node service deployed to Cloud Run. It checks `X-ResAI-Proxy-Key`, obtains a service-account token from Cloud Run metadata, ignores client-side model/project/location overrides, calls Vertex AI with a request timeout, sanitizes model wrappers, and returns only the generated text.

The deployment script is idempotent and uses operator-supplied resource names:

- Cloud Run service: `RESAI_CLOUD_RUN_SERVICE`
- Service account: `RESAI_CLOUD_RUN_SA`
- Secret Manager secret: `RESAI_PROXY_SECRET_NAME`
- Region: `RESAI_CLOUD_RUN_REGION`

If these resources already exist, the script reuses them. It does not create a new secret version unless `RESAI_ROTATE_PROXY_SECRET=1` is set.

## Expansion plan

### Mac beta

- app-specific extractors
- preview overlay
- richer profile field validation
- privacy controls
- user/team auth instead of shared-secret distribution

### Windows

- .NET + UI Automation
- same prompt and backend contract
- Windows overlay and hotkey implementation

### iOS

- custom keyboard extension
- input-text-only rewrite
- no cross-app context unless the user manually provides it

### Android

- Accessibility Service + overlay
- similar context model to Mac/Windows
- strict user confirmation before replacement
