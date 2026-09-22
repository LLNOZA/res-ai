# Public Repository Maintainer Operations

These controls apply to the public `LLNOZA/res-ai` repository. They complement the mandatory publication gate in [`publication-security-gate.md`](publication-security-gate.md).

## 1. Protected change flow

- Treat `main` as protected and releasable.
- Make every change through a pull request, including maintainer changes.
- Require the publication-safety, Swift-test, and proxy-test status checks.
- Do not force-push or delete `main`.
- Resolve review conversations before merge and use linear history.
- Obtain another maintainer's review when one is available. If only one maintainer is available, the maintainer may merge only after all required checks pass and the pull request records the self-review and verification performed.
- Keep `CODEOWNERS` current as maintainership changes.

## 2. Public and private boundaries

The public repository may contain source, synthetic tests, architecture documentation, reproducible build instructions, and sanitized examples. It must not contain:

- API keys, tokens, passwords, private keys, signing or notarization credentials;
- real proxy endpoints, cloud project or account identifiers, internal resource names, or authenticated URLs;
- real user text, accessibility captures, recordings, contact data, or unredacted logs;
- internal delivery paths, private operational notes, incident details under embargo, or unpublished security findings; or
- built artifacts that have not passed the release and publication gates.

Store runtime secrets in an approved secret manager or local keychain. Use placeholders in documentation and synthetic values in tests. Rotate a credential immediately if exposure cannot be ruled out.

## 3. Issues and pull requests

- Route vulnerability reports to GitHub private vulnerability reporting.
- Triage new issues for accidental sensitive data before normal discussion.
- Ask the author to remove exposed data, then preserve only the minimum private evidence needed for incident handling.
- Require every pull request to describe its security, privacy, and user-data impact.
- Reject changes that silently expand collection, retention, transmission, or logging of user data.
- Pin third-party GitHub Actions to immutable commit SHAs and keep workflow permissions read-only unless a documented job requires more.

## 4. Continuous verification

Required checks run on pull requests and on pushes to `main`:

- Swift unit tests;
- dependency-free proxy tests; and
- the publication-safety gate, including full-history secret scanning.

Dependabot checks GitHub Actions dependencies weekly. Review dependency updates for provenance, permissions, release notes, and behavior changes before merge. Never merge a failing or skipped required check.

## 5. Release control

1. Start from a clean, reviewed commit on protected `main`.
2. Run the complete test and release verification procedures.
3. Build the DMG and PKG from the same final source commit and version.
4. Verify embedded executables, versions, signatures, notarization, package contents, integrity, and SHA-256 hashes.
5. Publish only artifacts approved for public distribution. Never describe unsigned or unnotarized local artifacts as public releases.
6. Record the source commit, version, checksums, verification result, and known limitations in the release record.
7. Preserve the corresponding symbols and enough provenance to investigate crashes and reproduce the release.

## 6. Access and settings review

At least quarterly, and whenever a maintainer leaves or a credential incident occurs:

- review repository collaborators and remove access that is no longer needed;
- review branch protection, required checks, Actions permissions, deploy keys, webhooks, environments, and repository secrets;
- confirm secret scanning, push protection, Dependabot security updates, and private vulnerability reporting remain enabled; and
- confirm the default branch and release process still match this document.

Use least privilege. Do not share accounts, tokens, signing identities, or program benefits.

## 7. Security incident procedure

1. Stop the affected release or deployment path without destroying evidence.
2. Revoke or rotate exposed credentials and invalidate compromised artifacts.
3. Determine the affected commits, refs, releases, logs, users, and systems.
4. Remove sensitive material from the current tree and all publishable Git objects. Do not rely on deletion alone when a credential was exposed.
5. Fix the root cause and add a regression test or automated guard.
6. Re-run the full publication and release gates before restoring distribution.
7. Coordinate private reporting, user notification, and public disclosure according to [`SECURITY.md`](../SECURITY.md).

## 8. Exceptions

An exception must be explicit, time-bounded, documented in the relevant private operational record, and approved by the repository owner. An exception never permits publishing credentials, personal data, or unauthorized third-party information.
