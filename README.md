# ResponseAi

Mac-first proof of concept for an AI reply assistant.

The app runs as a menu bar utility. Press the global hotkey while a reply box is focused, and it:

1. Reads the focused input field through macOS Accessibility.
2. Collects nearby text above the input field as conversation context.
3. Builds a context-aware rewrite prompt with a configurable output language.
4. Sends the prompt directly to the Claude API (`claude-haiku-5-5`, fixed in code) with the user's own Claude API key. Without a key, it falls back to the Cloud Run proxy, which is kept only for the migration period.
5. Replaces the focused input text with the generated reply.

If neither a Claude API key nor the proxy is configured yet, the app uses a local preview rewriter so the native flow can be tested before auth is wired.

### 社内向けの設定（Claude API キー）

社内向けは、各自が自分の Claude API キーを設定画面（`設定 > AI接続 > Claude APIキー`）で入力します。キーは macOS のキーチェーンにだけ保存され、UserDefaults・ログ・アプリ本体には含まれません。「接続テスト」はトークンを消費しない `GET /v1/models` でキーを確認します。設定画面には現在の経路（Claude API 直接 / 中継 / プレビュー）が表示されます。

経路の優先順位は 3 機能（返信生成・フォーム入力・音声入力の整え）共通です:

1. Claude API キーが設定済み → Claude API を直接呼ぶ
2. キー未設定で中継（Cloud Run proxy）が設定済み → 中継経由（移行期間の互換用。後日撤去予定）
3. どちらも無い → ローカルプレビュー（音声入力は生テキストのまま。Gemini API キーがあれば従来どおり Gemini で整え）

## Public Repository Publication Gate

Publishing or pushing this repository to a public remote is prohibited until every mandatory condition in [`docs/publication-security-gate.md`](docs/publication-security-gate.md) is complete. The gate includes excluding credentials from every object being published, current-tree and public-history cleanup, infrastructure and personal-information review, automated secret scanning, and explicit approval of the exact commit being published.

Run the gate with:

```bash
./scripts/check_publication_safety.sh --require-approval
```

The repository's pre-push hook runs the same gate automatically.

Public development and maintenance follow these repository-wide policies:

- [`CONTRIBUTING.md`](CONTRIBUTING.md) for changes, tests, and pull requests
- [`SECURITY.md`](SECURITY.md) for private vulnerability reporting
- [`docs/maintainer-operations.md`](docs/maintainer-operations.md) for branch, release, access, and incident controls

The UI is intentionally small:

- a menu bar item
- a tiny non-activating HUD while it reads, writes, and replaces
- a mode submenu for tone changes
- one global restore hotkey for the last replaced draft
- a readiness check that verifies permissions and the AI connection (Claude API key, or the proxy) before use

## Build And Run

Build the native menu bar app. A signing identity is required (certificate name or SHA-1 hash from `security find-identity -v -p codesigning`):

```bash
RESAI_CODESIGN_IDENTITY="<signing identity>" ./scripts/build_app.sh
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
dist/installer/ResponseAi-0.4.1.pkg
dist/installer/ResponseAi-0.4.1.dmg
```

`scripts/build_app.sh` signs the app bundle with the identity in `RESAI_CODESIGN_IDENTITY` and `scripts/build_dmg.sh` signs the DMG with it. If a `Developer ID Installer` certificate is installed, `scripts/build_pkg.sh` signs the installer package. Without those certificates, the scripts still build unsigned local-testing installers.

`RESAI_CODESIGN_IDENTITY` is required for every build, including local ones; `scripts/build_app.sh` stops if it is unset, set to ad-hoc (`-`), or not found in the keychain. It never picks a certificate on its own. macOS matches Accessibility and Input Monitoring grants against the signing identity, so an update signed by a different certificate (another person's Apple Development certificate, or an ad-hoc signature) is treated as a different app and every user's grants stop applying, while System Settings still shows the old entry switched on. Use the same identity for every release; the script prints the team ID and designated requirement it signed with so a change is visible at build time.

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
./scripts/notarize_pkg.sh dist/installer/ResponseAi-0.4.1.pkg
./scripts/notarize_dmg.sh dist/installer/ResponseAi-0.4.1.dmg
```

On first app run, use `ResponseAi > アクセシビリティ／入力監視を開く` (or the `操作権限` button in Settings), then grant Accessibility and Input Monitoring permission to `ResponseAi`:

`System Settings > Privacy & Security > Accessibility`

`System Settings > Privacy & Security > Input Monitoring`

ResponseAi never invokes the macOS permission prompts from launch, feature attempts, wake/unlock recovery, or background monitoring. Permission requests happen only after the user explicitly selects the permission command. The app passively observes the resulting state, waits to register global shortcuts until both permissions are available, and then retries automatically. If macOS asks you to quit and reopen the app after enabling Input Monitoring, restart ResponseAi from its menu.

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

Press the shortcut once to start listening and press it again to confirm and insert. Escape cancels an active session. A hold-to-talk mode (hold to listen, release to confirm) is available in `Settings > Voice`. Requires macOS 14 or later (best on macOS 26+ with on-device Apple SpeechAnalyzer; earlier versions use SFSpeechRecognizer, on-device when the locale supports it). Optional AI cleanup (fillers, punctuation, homophones, dictionary) calls the Claude API directly (`claude-haiku-5-5`) when a Claude API key is set in Settings; otherwise it goes through the Cloud Run proxy (migration-period compatibility). Only when neither is configured does it call Gemini directly with the Gemini API key from Settings; with none of them, the raw transcript is kept. Only text is sent for cleanup, never audio. After cleanup, Restore (`Command + Shift + U`) reverts the last cleanup for 60 seconds, then falls back to the previous rewritten draft.

To restore the previous draft after a replacement:

```text
Command + Shift + U
```

To fill an open form from your profile, focus any field in the form and press:

```text
Command + Shift + K
```

The first press previews the fields ResponseAi can fill. Press the same shortcut again within 20 seconds to apply the values. It skips existing values, passwords, payment fields, authentication codes, and consent-like fields, and it never presses Submit.

Shortcuts can be changed from `Settings > Shortcuts` for Voice, Rewrite, Restore, Form Fill, and Quick Menu. Click a field and press the combination you want: any key with or without Command / Option / Control / Shift, or modifiers alone (for example `fn + Command`, `Command + Shift`, or a single `Control`; press and release them to record). Escape cancels recording; the "Esc を登録" button records Escape itself. Each row (or all rows) can be reset to the defaults. Only duplicates between actions and keys macOS does not pass to apps are refused. Combinations that take something away ask for confirmation first and keep a gray note under the row: a key alone (that character can no longer be typed), Shift plus a character (the uppercase letter or symbol), common system shortcuts (Command + Q / W / C / V / X / Z / A / S, Command + Tab, Command + Space, Control + Space, Command + Shift + 3 / 4 / 5, and others), and modifiers alone. A modifier-only shortcut fires when the modifiers are pressed on their own and released within 0.6 seconds; pressing another key or clicking meanwhile (for example Command + Shift + T) does not fire it. For voice input in hold-to-talk mode it starts listening on press, confirms on release, and is cancelled without inserting anything if another key is pressed while it is held. Settings saved by 0.4.0 and earlier are read as the same shortcuts.

The menu bar item also has manual Rewrite, Restore, Fill Form, Mode, Settings, and permission commands.

If anything feels inactive, run:

```text
ResponseAi > Run Readiness Check
```

The check shows whether Accessibility and Input Monitoring are active, whether Screen Recording is available for browser context OCR, which AI route is active, whether the Claude API key is accepted (`GET /v1/models`, no tokens used), whether the Cloud Run proxy health endpoint responds (informational only while a Claude API key is set), whether the local writing profile is enabled, whether voice input is ready, and which hotkeys are active.

## AI backend config

For internal use, the preferred path is each user's own Claude API key entered in `設定 > AI接続` (see above). The app then calls `https://api.anthropic.com/v1/messages` directly with `claude-haiku-5-5`; the model is fixed in code and sampling parameters such as `temperature` are never sent.

The Cloud Run proxy below is kept only for compatibility during the migration period and is used only when no Claude API key is set. It will be removed in a later change. By default the proxy calls the Claude API with `claude-haiku-5-5`; set `RESAI_AI_PROVIDER=vertex` when deploying to roll back to Vertex AI Gemini.

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
RESAI_AI_PROVIDER=anthropic                         # or vertex
RESAI_ANTHROPIC_MODEL=claude-haiku-5-5
RESAI_ANTHROPIC_SECRET_NAME=resai-anthropic-api-key # Secret Manager secret holding the Anthropic API key
```

With `RESAI_AI_PROVIDER=anthropic`, register the Anthropic API key in Secret Manager before deploying; the script never creates or prints it:

```bash
gcloud secrets create resai-anthropic-api-key --project <your-gcp-project-id> --replication-policy=automatic --data-file=-
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

Provider, model, project, and location are common settings owned by Cloud Run:

```text
AI_PROVIDER
ANTHROPIC_MODEL
ANTHROPIC_API_KEY (from Secret Manager)
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
- Voice input on macOS 14+ (SpeechAnalyzer on macOS 26+, SFSpeechRecognizer fallback earlier; press to start / press to confirm, optional hold-to-talk, Escape to cancel, on-device transcription plus optional AI cleanup via the Claude API directly, the Cloud Run proxy during migration, or a Gemini API key fallback)
- Restore-last-draft hotkey (also reverts the last voice cleanup within 60 seconds)
- Profile-based form-fill hotkey with preview-before-fill confirmation
- Recordable shortcuts (any key combination, or modifiers alone) for Voice, Rewrite, Restore, Form Fill, and Quick Menu
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
- Direct Claude API client (`claude-haiku-5-5`) with the user's own key stored in the Keychain
- Vertex AI Gemini `generateContent` request builder
- Cloud Run proxy with shared-secret protection and centrally owned provider/model config (migration-period compatibility; Claude API by default, Vertex AI rollback)
- Input replacement through Accessibility, with clipboard paste fallback
- Replacement verification; if insertion cannot be verified, generated text remains copied for manual paste
- Browser paste focusing via input-frame click before clipboard fallback
- Generated reply cleanup for labels, quotes, list markers, and code fences
- Local no-auth preview mode

## Next milestones

- Add deeper app-specific extractors for Slack, Chrome Messenger, Gmail, LINE, Teams, and Discord.
- Replace development shared secret with user/team auth before public release.
- Package with Developer ID signing and notarization.

## License

ResponseAi is licensed under the [Apache License 2.0](LICENSE).
