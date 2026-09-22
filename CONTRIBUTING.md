# Contributing to ResponseAi

Thank you for helping improve ResponseAi. This project handles accessibility data and user-authored text, so privacy and security are part of every change.

## Before opening a change

- Search existing issues and pull requests first.
- Open an issue before a large feature, architecture change, or behavior change.
- Report suspected vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md). Do not open a public security issue.
- Never include credentials, private endpoints, cloud resource identifiers, signing material, personal data, real user conversations, or unredacted logs in an issue, commit, test fixture, or pull request.

## Development workflow

1. Fork the repository and create a focused branch from `main`.
2. Keep the change small enough to review and add regression tests for changed behavior.
3. Use synthetic, anonymized fixtures only.
4. Run the required checks:

   ```bash
   swift test
   npm test --prefix services/vertex-proxy
   ./scripts/check_publication_safety.sh
   ```

5. Use a GitHub-provided `noreply` address for commit author and committer metadata. The publication gate rejects direct email addresses in publishable history.
6. Open a pull request and complete every item in the pull request template.

## Pull request requirements

A pull request must:

- explain the problem, approach, security and privacy impact, and verification;
- avoid unrelated formatting or generated-file changes;
- pass all required status checks;
- resolve review conversations before merge;
- receive maintainer review when a second maintainer is available; and
- be merged without bypassing branch protection or force-pushing `main`.

Maintainers may request changes when a proposal expands data collection, weakens a safety boundary, adds a dependency without a clear need, or cannot be verified with tests.

## AI-assisted contributions

AI assistance is welcome, but the contributor remains responsible for every line submitted. Review generated code, remove confidential prompt or output data, test the result, and disclose substantial generated changes in the pull request when that context helps reviewers.

## License

By contributing, you agree that your contribution is licensed under the repository's [Apache License 2.0](LICENSE).
