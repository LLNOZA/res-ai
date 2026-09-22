#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_APPROVAL=0

if [[ "${1:-}" == "--require-approval" ]]; then
  REQUIRE_APPROVAL=1
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--require-approval]" >&2
  exit 2
fi

failures=0

fail() {
  printf 'BLOCKED: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Required security scanner is not installed: $1"
    return 1
  fi
}

cd "$ROOT_DIR"

if require_command gitleaks; then
  if ! gitleaks git --redact=100 --no-banner --no-color --log-level error "$ROOT_DIR"; then
    fail "gitleaks detected a secret in Git history. Values remain redacted."
  fi

  if ! gitleaks dir --redact=100 --no-banner --no-color --log-level error --max-target-megabytes 200 "$ROOT_DIR"; then
    fail "gitleaks detected a secret in the current repository directory or generated artifacts. Values remain redacted."
  fi

  while IFS= read -r blob_sha; do
    [[ -z "$blob_sha" ]] && continue
    if ! git cat-file blob "$blob_sha" \
      | gitleaks stdin --redact=100 --no-banner --no-color --log-level error >/dev/null 2>&1; then
      fail "gitleaks detected a secret in an unreachable Git object: $blob_sha"
    fi
  done < <(
    git fsck --full --no-reflogs --unreachable --no-progress 2>/dev/null \
      | awk '$2 == "blob" { print $3 }'
  )

  while IFS= read -r -d '' artifact; do
    if ! strings "$artifact" \
      | gitleaks stdin --redact=100 --no-banner --no-color --log-level error >/dev/null 2>&1; then
      relative_artifact="${artifact#"$ROOT_DIR"/}"
      fail "gitleaks detected a secret in a generated binary: $relative_artifact"
    fi
  done < <(
    find "$ROOT_DIR/.build" "$ROOT_DIR/dist" "$ROOT_DIR/artifacts" \
      -type f -perm -111 -print0 2>/dev/null || true
  )
fi

if require_command rg; then
  sensitive_name_pattern='(^|/)(\.env($|\.)|.*\.(pem|key|p8|p12|pfx|jks|keystore|mobileprovision)$|credentials?[^/]*\.json$|service[-_]?account[^/]*\.json$|secrets?[^/]*\.json$)'
  publication_files=()
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "scripts/check_publication_safety.sh" ]] && continue
    publication_files+=("$candidate")
  done < <(git ls-files -co --exclude-standard -z)

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    fail "Sensitive filename requires removal or explicit safe-template review: $candidate"
  done < <(git ls-files -co --exclude-standard | rg -i "$sensitive_name_pattern" || true)

  if ((${#publication_files[@]} > 0)) \
    && rg -n --quiet --pcre2 "https://[^[:space:]\"'<>]+\\.run\\.app\\b" "${publication_files[@]}" 2>/dev/null; then
    fail "A concrete Cloud Run endpoint remains in public-facing source or documentation."
  fi

  if ((${#publication_files[@]} > 0)) \
    && rg -n --quiet --pcre2 '\b[0-9]{10,12}\b' "${publication_files[@]}" 2>/dev/null; then
    fail "A project/account-style long numeric identifier remains in public-facing files."
  fi

  if ((${#publication_files[@]} > 0)) \
    && rg -n --quiet --pcre2 '(/Users/|GoogleDrive-|共有ドライブ|インストーラ_resai)' \
      "${publication_files[@]}" 2>/dev/null; then
    fail "A local absolute path or internal delivery location remains in public-facing files."
  fi
fi

config_file="$ROOT_DIR/Sources/ResAICore/VertexAIConfig.swift"
if [[ -f "$config_file" ]]; then
  if ! awk '
    /enum BundledDefaults/ { inside = 1 }
    inside && /static let (projectID|proxyURLString|proxyAuthToken)[[:space:]]*=/ {
      if ($0 !~ /=[[:space:]]*""[[:space:]]*$/) bad = 1
    }
    inside && /^    }/ { inside = 0 }
    END { exit bad ? 1 : 0 }
  ' "$config_file"; then
    fail "BundledDefaults still contains a real project ID, proxy URL, or proxy authentication token."
  fi
fi

if [[ "$REQUIRE_APPROVAL" -eq 1 ]]; then
  if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    fail "The working tree is not clean. Commit or remove every publication candidate before approval."
  fi

  if [[ -n "$(git for-each-ref --format='%(refname)' refs/codex/)" ]]; then
    fail "Local Codex snapshot refs remain. Remove them before approving a public push."
  fi

  if git log --all --format='%ae%n%ce' \
    | awk 'NF && $0 !~ /@users\.noreply\.github\.com$/ { bad = 1 } END { exit bad ? 0 : 1 }'; then
    fail "Git history contains a direct author or committer email address."
  fi

  approval_file="$(git rev-parse --git-path publication-approved)"
  current_head="$(git rev-parse HEAD)"
  approved_head=""
  if [[ -f "$approval_file" ]]; then
    IFS= read -r approved_head < "$approval_file" || true
  fi
  if [[ "$approved_head" != "$current_head" ]]; then
    fail "The exact HEAD commit has not been explicitly approved for public publication."
  fi
fi

if [[ "$failures" -ne 0 ]]; then
  printf '\nPublication security gate failed with %d blocking condition(s).\n' "$failures" >&2
  exit 1
fi

echo "Publication security gate passed."
