## Summary

Describe the problem and the smallest change that solves it.

## Security and privacy impact

Describe any change to accessibility access, user text, audio, storage, logging, authentication, network requests, prompts, model output, or release artifacts. Write `None` only after checking each category.

## Verification

List the commands and manual checks performed.

## Checklist

- [ ] I used only synthetic or fully anonymized test data.
- [ ] I did not include credentials, private endpoints, operational identifiers, personal data, real user content, or unredacted logs.
- [ ] I added or updated tests for changed behavior.
- [ ] `swift test` passes.
- [ ] `npm test --prefix services/vertex-proxy` passes.
- [ ] `./scripts/check_publication_safety.sh` passes.
- [ ] I reviewed the diff for unexpected generated files and dependency changes.
- [ ] I documented user-visible, security, privacy, and release implications.
