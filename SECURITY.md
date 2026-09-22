# Security Policy

ResponseAi reads text through macOS Accessibility APIs, can replace focused input, and can communicate with an operator-managed AI proxy. Please treat suspected data exposure, authentication bypass, unsafe text replacement, prompt or output injection, and release-integrity failures as security issues.

## Supported versions

Security fixes are developed on `main`. Until stable release channels are documented, only the latest commit on `main` and the latest published release are eligible for fixes.

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/LLNOZA/res-ai/security/advisories/new). Do not open a public issue, discussion, or pull request for an undisclosed vulnerability.

Include:

- the affected version or commit;
- impact and realistic attack scenario;
- minimal reproduction steps or a proof of concept;
- suggested remediation, if known; and
- whether any credential or user data may have been exposed.

Use synthetic data and redact credentials, private endpoints, account identifiers, and personal text. Do not access data or systems you do not own or have permission to test.

The maintainers aim to acknowledge a report within three business days, validate and prioritize it, prepare a regression test and fix, and coordinate disclosure after affected users have a reasonable opportunity to update. Timelines vary with severity and complexity.

## Public disclosure

The maintainers will publish an advisory when disclosure is appropriate. Credit is offered unless the reporter prefers anonymity. Never publish an exploit, credential, or sensitive diagnostic before coordinated disclosure is complete.
