# ResponseAi

Mac-first proof of concept for an AI reply assistant.

The app runs as a menu bar utility. Press the global hotkey while a reply box is focused, and it:

1. Reads the focused input field through macOS Accessibility.
2. Collects nearby text above the input field as conversation context.
3. Builds a context-aware rewrite prompt with a configurable output language.
4. Sends the prompt to Vertex AI Gemini when credentials are configured.
5. Replaces the focused input text with the generated reply.

If Vertex AI credentials are not configured yet, the app uses a local preview rewriter so the native flow can be tested before auth is wired.

## Public Repository Publication Gate

Publishing or pushing this repository to a public remote is prohibited until every mandatory condition in [`docs/publication-security-gate.md`](docs/publication-security-gate.md) is complete. The gate includes excluding credentials from every object being published, current-tree and public-history cleanup, infrastructure and personal-information review, automated secret scanning, and explicit approval of the exact commit being published.

Run the gate with:

```bash
./scripts/check_publication_safety.sh --require-approval
```

The repository's pre-push hook runs the same gate automatically.

The UI is intentionally small:

- a menu bar item
- a tiny non-activating HUD while it reads, writes, and replaces
- a mode submenu for tone changes
- one global restore hotkey for the last replaced draft
- a readiness check that verifies permissions and the AI proxy before use

## Build And Run

Build the native menu bar app:

```bash
./scripts/build_app.sh
```

Install it:

```bash
./scripts/install_app.sh
```

Open it:

```bash
open /Applications/ResponseAi.app
```

If you want the app to inherit shell environment variables during development:

```bash
./scripts/run_app.sh
```

For development, the Swift Package executable still works:

```bash
swift run ResponseAi
```

## Build Installer

App updates are not complete until both the current-version PKG and DMG are built and verified against the final app build. Verify the delivered files' sizes and SHA-256 hashes against the local originals, then copy them to your private release destination according to your deployment process. `dist/installer/` is local build output only. Preserve existing installers before running `build_pkg.sh`, which currently removes the local installer output directory.

Build a macOS installer package:

```bash
./scripts/build_pkg.sh
```

Build a drag-and-drop DMG:

```bash
./scripts/build_dmg.sh
```

Run the full local release verification:

```bash
./scripts/verify_release.sh
```

Build both release artifacts:

```bash
./scripts/build_release.sh
```

The generated installers are written to:

```text
dist/installer/ResponseAi-0.3.6.pkg
dist/installer/ResponseAi-0.3.6.dmg
```

If a `Developer ID Application` certificate is installed, `scripts/build_app.sh` uses it for the app bundle and `scripts/build_dmg.sh` signs the DMG. If a `Developer ID Installer` certificate is installed, `scripts/build_pkg.sh` signs the installer package. Without those certificates, the scripts still build unsigned local-testing installers.

For public distribution outside the Mac App Store, notarize and staple the signed artifacts:

```bash
RESAI_NOTARY_KEYCHAIN_PROFILE="notary-profile" \
RESAI_NOTARIZE=1 \
./scripts/build_release.sh
```

or:

```bash
RESAI_NOTARY_APPLE_ID="apple-id@example.com" \
RESAI_NOTARY_TEAM_ID="TEAMID1234" \
RESAI_NOTARY_PASSWORD="app-specific-password" \
RESAI_NOTARIZE=1 \
./scripts/build_release.sh
```

You can also notarize one artifact directly:

```bash
./scripts/notarize_pkg.sh dist/installer/ResponseAi-0.3.6.pkg
./scripts/notarize_dmg.sh dist/installer/ResponseAi-0.3.6.dmg
```

On first app run, grant Accessibility permission to `ResponseAi`:

`System Settings > Privacy & Security > Accessibility`

For browser apps such as Facebook Messenger, Gmail, and other web messengers, ResponseAi can optionally use visible text recognition to read context above the focused reply box. Grant Screen Recording permission when prompted, or from the menu:

```text
ResponseAi > Request Screen Recording Permission
```

Text previews are not written to logs by default. For debugging a bad context capture, enable:

```text
Settings > Privacy > Log text previews for debugging
```

You can also save a local writing profile:

```text
Settings > Profile
```

The profile can include your name, company, department, role, contact details, service description, form-fill notes, preferred style, phrases to use, and phrases to avoid. You can turn profile use on or off, clear it, or import/export it as JSON. ResponseAi sends the enabled profile with each rewrite request as style guidance, but contact fields such as email, phone, address, website, and social URL are reserved for explicit form filling. The prompt instructs the model not to disclose profile details unless the conversation requires it.

Choose the reply language in `Settings > Rewrite`: `日本語`, `English`, or `Auto`.

Then focus a Slack, Messenger, Gmail, or similar reply box and press:

```text
Command + Shift + J
```

### 音声入力

Dictate into the focused field with:

```text
Command + Shift + Space
```

Press the shortcut once to start listening and press it again to confirm and insert. Escape cancels an active session. A hold-to-talk mode (hold to listen, release to confirm) is available in `Settings > Voice`. Requires macOS 14 or later (best on macOS 26+ with on-device Apple SpeechAnalyzer; earlier versions use SFSpeechRecognizer, on-device when the locale supports it). Optional Gemini cleanup uses `gemini-3.8-flash` by default; set the API key in Settings. After cleanup, Restore (`Command + Shift + U`) reverts the last cleanup for 60 seconds, then falls back to the previous rewritten draft.

To restore the previous draft after a replacement:

```text
Command + Shift + U
```

To fill an open form from your profile, focus any field in the form and press:

```text
Command + Shift + K
```

The first press previews the fields ResponseAi can fill. Press the same shortcut again within 20 seconds to apply the values. It skips existing values, passwords, payment fields, authentication codes, and consent-like fields, and it never presses Submit.

Shortcut keys can be changed from `Settings > Shortcuts`. Command + Shift stays fixed; the letter key can be changed for Voice, Rewrite, Restore, Form Fill, and Quick Menu.

The menu bar item also has manual Rewrite, Restore, Fill Form, Mode, Settings, and permission commands.

If anything feels inactive, run:

```text
ResponseAi > Run Readiness Check
```

The check shows whether Accessibility is active, whether Screen Recording is available for browser context OCR, whether the Cloud Run proxy health endpoint responds, whether the local writing profile is enabled, whether voice input is ready, and which hotkeys are active.

## Vertex AI config

The preferred path is the Cloud Run proxy. It keeps Vertex AI credentials and model selection off the Mac app, so every installed app uses the same centrally configured AI backend.

Deploy or update the proxy:

```bash
./scripts/deploy_vertex_proxy.sh
```

The script is idempotent. Set the following values to resources in your own GCP project before running it; existing resources with those names are reused:

```text
RESAI_CLOUD_RUN_SERVICE=<your-cloud-run-service>
RESAI_CLOUD_RUN_SA=<your-service-account-name>
RESAI_PROXY_SECRET_NAME=<your-secret-manager-secret>
RESAI_CLOUD_RUN_REGION=<your-cloud-run-region>
```

To preview what it would do without creating or updating resources:

```bash
RESAI_DRY_RUN=1 ./scripts/deploy_vertex_proxy.sh
```

The older direct-Vertex development path still works when needed:

```bash
./scripts/configure_gcp_project.sh
export VERTEX_AI_ACCESS_TOKEN="$(gcloud auth print-access-token)"
./scripts/run_app.sh
```

Configure your own project and proxy endpoint through environment variables or another local secret/configuration mechanism. Do not commit these values:

```text
RESAI_VERTEX_PROJECT_ID=<your-gcp-project-id>
RESAI_GCP_PROJECT_NUMBER=<your-gcp-project-number>
RESAI_VERTEX_PROXY_URL=<your-cloud-run-url>/v1/rewrite
```

`open dist/ResponseAi.app` is best for normal local testing. `scripts/run_app.sh` is best when using token environment variables. For proxy mode, provide `RESAI_VERTEX_PROXY_URL` and `RESAI_PROXY_SHARED_SECRET` through a local secret manager or environment. Public builds must not include a proxy credential or shared key; never commit or bundle one. Rotate any credential that may have been exposed before publishing and complete the publication security gate.

Clipboard history excludes concealed, transient, and autogenerated pasteboard items, preserves whitespace, skips oversized text rather than truncating it, and expires entries after seven days. History still uses local UserDefaults storage; disable it when persistent clipboard storage is inappropriate.

Model, project, and location are common settings owned by Cloud Run:

```text
VERTEX_PROJECT_ID
VERTEX_LOCATION
VERTEX_MODEL
```

The Mac app does not send model/project/location overrides to the proxy. Users only change local UX settings such as rewrite mode, privacy, and profile.

For direct-Vertex development without the bundled proxy fallback:

```bash
RESAI_DISABLE_BUNDLED_PROXY=1 ./scripts/run_app.sh
```

## Current scope

- Mac menu bar app
- Native `.app` bundle build script
- `.pkg` installer build
- drag-and-drop `.dmg` build
- one-command release verification script
- one-command release build with optional pkg/dmg notarization
- Global hotkey
- Voice input on macOS 14+ (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer fallback earlier; press to start / press to confirm, optional hold-to-talk, Escape to cancel, on-device transcription plus optional Gemini cleanup)
- Restore-last-draft hotkey (also reverts the last voice cleanup within 60 seconds)
- Profile-based form-fill hotkey with preview-before-fill confirmation
- Configurable Command+Shift shortcut keys for Rewrite, Restore, and Form Fill
- Lightweight HUD
- Quick mode menu
- Accessibility permission prompt
- Focused input text read
- Nearby on-screen context extraction
- ScreenCaptureKit + Vision OCR fallback for browser contexts
- Local writing profile for style, role, company, contact fields, service notes, preferred phrases, and avoided phrases
- Form filling from local profile through Accessibility-scanned fields, with AI JSON planning and local deterministic fallback
- Sensitive-field and already-filled-field skipping for password, payment, authentication, and consent-like form inputs
- Context capture diagnostics in the HUD, including AX/OCR source labels
- Slack, browser, email, Discord, Teams, and LINE extraction profiles
- Vertex AI Gemini `generateContent` request builder
- Cloud Run Vertex proxy with shared-secret protection and centrally owned model config
- Input replacement through Accessibility, with clipboard paste fallback
- Replacement verification; if insertion cannot be verified, generated text remains copied for manual paste
- Browser paste focusing via input-frame click before clipboard fallback
- Generated reply cleanup for labels, quotes, list markers, and code fences
- Local no-auth preview mode

## Next milestones

- Add deeper app-specific extractors for Slack, Chrome Messenger, Gmail, LINE, Teams, and Discord.
- Replace development shared secret with user/team auth before public release.
- Package with Developer ID signing and notarization.
