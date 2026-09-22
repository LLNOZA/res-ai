# Public Repository Security Gate

Publishing this repository, or pushing any branch or tag to a public remote, is prohibited until every condition below is complete.

## Mandatory conditions

1. Remove every credential from the current tree and every Git object or artifact that will be published. An active credential may remain in a trusted deployed or local client temporarily only when its value has never been publicly exposed and is absent from the complete publication candidate.
2. Remove credentials from all reachable and unreachable Git history that could be transferred to the public remote. Do not use mirror or all-ref pushes when local-only refs exist.
3. Exclude affected build outputs from publication. Rebuild distributable artifacts from the sanitized source, and rotate any client credential before distributing replacement clients when the deployment plan requires it.
4. Replace real cloud project IDs, project numbers, service URLs, account names, resource names, and other operational identifiers with documented placeholders unless their publication is explicitly approved.
5. Review test fixtures, commit metadata, signing identities, internal design notes, personal information, and company information for public suitability. Public commits must use a GitHub noreply address rather than a direct email address.
6. Confirm that no private key, service-account file, environment file, signing credential, access token, password, or authenticated URL is present.
7. Run `scripts/check_publication_safety.sh` and obtain a clean result for both the working tree and the complete Git history.
8. Record explicit approval for the exact commit being published. Approval for one commit does not carry forward to a later commit.

No credential may be published merely because its value appears only in an old commit, an ignored directory, or a generated artifact. If a credential was disclosed publicly or to an untrusted party, removal alone is insufficient; it must also be revoked or rotated.

## Approval record

After all remediation and review are complete, the repository owner may approve the exact commit by writing its full commit hash to:

```text
.git/publication-approved
```

The approval file is a local anti-mis-push safety lock, not a GitHub setting or a committed file. Any change to `HEAD` invalidates the approval. The pre-push hook rejects publication when the file is absent, stale, or when any automated check fails.

## Required command

```bash
./scripts/check_publication_safety.sh --require-approval
```

The local remote push URL must remain disabled until the current findings are remediated, the complete history is clean, and the exact commit is approved.
