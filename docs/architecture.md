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
- Claude API directly when the user's Claude API key is set (claude-haiku-5-5)
- Cloud Run proxy when configured and no key is set (migration-period compatibility)
- direct Vertex AI Gemini for development
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

`Run Readiness Check` verifies Accessibility, Input Monitoring, Screen Recording, the active AI route, the Claude API key (`GET /v1/models`, no tokens used), Cloud Run proxy health, profile state, and the active hotkeys from the menu bar or Settings window. While a Claude API key is set, a failing proxy health check is reported but not treated as fatal.

Accessibility and Input Monitoring request APIs are invoked only from an explicit permission action in the menu or Settings. Launch, feature attempts, lifecycle recovery, and the permission monitor only preflight the current TCC state; they never trigger another system permission prompt.

The permission monitor polls every second for two minutes, then every 30 seconds until the grant arrives or the app quits, so a grant made later still takes effect without a relaunch. ResponseAi records the signing identity that last held Accessibility and whether a request was made. When Accessibility is missing but a previous grant, an Input Monitoring grant, or an unanswered request exists, it treats the grant as stale: an entry granted to a different signature stays switched on in System Settings but no longer applies, so the guidance tells the user to remove the entry with "−" and add the app again. Every launch logs the version, build, team ID, signer, and bundle path, and logs a separate line when the signing identity differs from the previous launch.

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

Typeless-style dictation into the focused field. On macOS 26+, Apple SpeechAnalyzer transcribes on-device. On macOS 14/15, `SFSpeechRecognizer` is the fallback (on-device when the locale supports it). AI only cleans the resulting text; it never receives audio, only text.

`DictationCleanupRouter` picks the route: the Claude API directly when the user's Claude API key is set (`ClaudeDictationCleaner` → `ClaudeAPIClient`); otherwise the Cloud Run proxy contract shared with rewriting (`ProxyDictationCleaner` → `CloudRunProxyClient`, `{systemInstruction, userPrompt}`), kept for the migration period; otherwise Gemini directly with the user's Gemini API key (`GeminiDictationCleaner`, using the previously saved model setting); with none of them, the raw transcript stays as-is. Timeouts, failures, and rejected output (`DictationCleanupOutputValidator`) also leave the raw transcript in place.

```text
hotkey ──> SpeechAnalyzer (macOS 26+) or SFSpeechRecognizer (macOS 14/15)
           ja_JP default, volatile preview in the voice pill
      ──> UserDictionary.apply
      ──> TextReplacer.insertAtCaret            (raw text lands instantly)
      ──> AI cleanup via Claude API (user's key)  (fillers / punctuation / homophones / dictionary)
          (Cloud Run proxy when no key is set; Gemini API key direct only when neither is configured)
      ──> TextReplacer.replaceInsertedText       (swap only the inserted range, skip if field changed)
```

Default shortcut is `Command + Shift + Space` (changeable in Settings, including modifier-only chords such as `fn + Command`). Default mode is toggle: one press starts listening, the next press confirms. An optional hold mode (≥ 250 ms hold listens while held and confirms on release; a quicker tap falls back to toggle) can be selected in Settings. Escape cancels while listening. After cleanup, Restore (`Command + Shift + U`) reverts to the raw transcript for 60 seconds before falling through to rewrite-draft restore.

### FormReader and FormFillPlanner

`FormReader` uses Accessibility to start from the focused element, find the owning app/window, traverse nearby AX nodes, collect text fields, text areas, and combo boxes, and pair them with likely labels from titles, placeholders, descriptions, and nearby static text.

`FormFillPlanner` sends the scanned field snapshots plus the form-fill profile to the Claude API directly when the user's Claude API key is set (otherwise to the Cloud Run proxy during the migration period) and asks for JSON candidates only. The Mac app filters the response locally, removes low-confidence or duplicate suggestions, skips non-empty fields, and blocks password, payment, authentication, and consent-like labels. If neither backend is available or the model returns nothing usable, `LocalFormFillPlanner` fills obvious fields such as name, company, email, phone, website, address, service, and free-text purpose from the local profile.

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

The default router prefers the Claude API directly (`ClaudeAPIClient`) when the user's Claude API key is set. Otherwise it uses the Cloud Run proxy when configured; the proxy is kept only for the migration period and will be removed later. In proxy mode, the Mac app sends only the prompt payload; project, location, and model are intentionally not sent by the client. If no proxy is configured, the older direct-Vertex development path can still use local config and a bearer token. If neither path is available, local preview mode is used.

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

Voice, Rewrite, Restore, Form Fill, and Quick Menu each use a global shortcut recorded in Settings (click the field, press the combination). A shortcut (`ShortcutTrigger`) is either a virtual key code plus any of Command / Option / Control / Shift, including none (`.key(HotKeyShortcut)`), or one or more modifiers alone including fn (`.modifierChord`). Key labels come from the current keyboard layout via `UCKeyTranslate`, so JIS keyboards show the printed key. Key shortcuts are swallowed by the event tap. Modifier-only chords are detected by `ModifierChordDetector` from `flagsChanged` without swallowing events:

- `.tap` style (every action, and Voice in toggle mode): fires when the chord is let go, only if it was reached on its own (no other modifier on the way), no ordinary key or mouse click came while it was held, and it was held at most 0.6 seconds. Keys swallowed by another shortcut's tap are reported through a shared counter in `GlobalHotKeyManager`, so Command + Shift + J (taken by Rewrite) does not also fire a Command + Shift chord.
- `.hold` style (Voice in hold-to-talk mode): press starts listening and release confirms; an ordinary key (or another modifier) while held emits `.cancelled`, which `GlobalHotKeyManager` delivers once to `onCancel` and `VoiceInputController.hotKeyCancelled()` turns into a quiet cancel (no text, pill/HUD closed). The voice manager's `modifierChordStyle` follows the activation mode.

`AppShortcuts.validationError` refuses only duplicates between actions, an empty chord, and keys that cannot be recorded. `ShortcutTrigger.warning` classifies combinations that take something away (a key alone, Shift plus a character, the `ReservedShortcut.all` list of macOS / common app shortcuts, modifiers alone); Settings asks for confirmation before registering them and keeps the note under the row. While a field records, the event taps stay installed but pass every key through (`GlobalHotKeyManager.isSuspended`), so an already registered combination can be recorded again. If registration fails, the previous shortcuts are restored and the reason is shown under the row.

Settings are stored in `shortcuts.v2` (`{"version":2,"rewrite":{"keyCode":38,"modifiers":["command","shift"]},…,"voice":{"type":"key"|"modifiers",…}}`). Non-voice actions keep the bare key shape and add `"type":"modifiers"` only for modifier-only chords; a missing `"type"` reads as a key. When `shortcuts.v2` has never been written, the 0.4.0 payload in `shortcuts.v1` (Command + Shift + letter, fn + Command, Command + Space) is converted to the same shortcuts; `shortcuts.v1` is left untouched. Unreadable data falls back to the defaults. Loaded settings are sanitized only for shape and duplicates, so a migrated reserved combination such as Command + Space keeps working.

### AI backend

For internal use, each user enters their own Claude API key in `設定 > AI接続`. The key is stored only in the Keychain (account `anthropic.apiKey`); it is never written to UserDefaults, logs, or crash reports and is never embedded in the build. The settings screen shows the active route (Claude API direct / proxy / preview) and offers a connection test via `GET https://api.anthropic.com/v1/models`, which consumes no tokens.

Route priority is shared by reply rewrite, form fill, and dictation cleanup (`AIBackendRoute`):

1. Claude API key set → `ClaudeAPIClient` calls `POST https://api.anthropic.com/v1/messages` directly.
2. No key, proxy configured → the Cloud Run proxy (migration-period compatibility).
3. Neither → local preview (dictation keeps the raw transcript, or uses a Gemini API key if one is set).

`ClaudeAPIClient` sends `x-api-key`, `anthropic-version: 2023-06-01`, the fixed model `claude-haiku-5-5`, `max_tokens` (4096 for rewrite and form fill; the existing length-based budget for dictation cleanup), `system`, and a single user message. It never sends `temperature`, `top_p`, or `top_k` because the model rejects them with HTTP 400. Responses whose `stop_reason` is not `end_turn` / `stop_sequence`, or whose text blocks are empty, are failures; `thinking` and other non-text blocks are discarded. Errors carry only the HTTP status and a coarse classification, never the response body, key, or prompt.

The Cloud Run proxy configuration below applies only while the proxy is still in use. The Mac app UI does not expose provider, project, location, or model selection to users.

- `AI_PROVIDER=anthropic` (default): the proxy calls the Claude API (`POST https://api.anthropic.com/v1/messages`) with `ANTHROPIC_MODEL`, default `claude-haiku-5-5`, for lower cost. `ANTHROPIC_API_KEY` is injected from Secret Manager.
- `AI_PROVIDER=vertex`: rollback path to Vertex AI Gemini with `VERTEX_MODEL`, default `gemini-3.5-flash`.

### Vertex AI

The Vertex request shape targets the publisher model endpoint:

```text
POST /v1/projects/{project}/locations/{location}/publishers/google/models/{model}:generateContent
```

The deployment project is supplied by the operator and must not be committed to the repository:

```text
RESAI_VERTEX_PROJECT_ID=<your-gcp-project-id>
RESAI_GCP_PROJECT_NUMBER=<your-gcp-project-number>
```

`scripts/configure_gcp_project.sh` writes these values into the `ai.res.resai` app defaults and sets the active `gcloud` project when the CLI is available.

### Cloud Run Proxy

`services/vertex-proxy` is a dependency-free Node service deployed to Cloud Run. It checks `X-ResAI-Proxy-Key`, ignores client-side model/project/location overrides, calls the Claude API (default) or Vertex AI (`AI_PROVIDER=vertex`, using a service-account token from Cloud Run metadata) with a request timeout, rejects incomplete model responses, sanitizes model wrappers, and returns only the generated text. The request/response contract with the Mac app is the same for both providers; `location` in the response is `anthropic` for the Claude API.

The deployment script is idempotent and uses operator-supplied resource names:

- Cloud Run service: `RESAI_CLOUD_RUN_SERVICE`
- Service account: `RESAI_CLOUD_RUN_SA`
- Secret Manager secret: `RESAI_PROXY_SECRET_NAME`
- Region: `RESAI_CLOUD_RUN_REGION`
- AI provider: `RESAI_AI_PROVIDER` (`anthropic` default, `vertex` for rollback)
- Claude model: `RESAI_ANTHROPIC_MODEL` (default `claude-haiku-5-5`)
- Anthropic API key secret: `RESAI_ANTHROPIC_SECRET_NAME` (default `resai-anthropic-api-key`)

If these resources already exist, the script reuses them. It does not create a new secret version unless `RESAI_ROTATE_PROXY_SECRET=1` is set. The Anthropic API key secret is never created by the script; register it in Secret Manager before deploying with `RESAI_AI_PROVIDER=anthropic`.

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
