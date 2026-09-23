# Contributing

## Branches

- `main` is **protected**: changes land via pull request with passing CI and a review.
- Branch names: `feature/*`, `fix/*`, `docs/*`, `chore/*`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), e.g.:

```
feat(compose): add mailpit profile
docs(runbooks): add quarterly restore test checklist
fix(scripts): verify dump completion before pruning
chore(ci): pin actionlint version
```

## Rules

1. **No secrets.** Never commit passwords, API keys, tokens, certificates (`*.pem`, `*.key`,
   `*.pfx`), backups or real `.env` files. Use `<secret>` / `change-me` placeholders.
   If a secret is committed by mistake: rotate it immediately, then clean history.
2. **Templates stay complete.** Any new setting used by the Laravel API must appear in
   `env/local.env.example` and/or `env/cloud.env.example` with a comment (placeholders only), in step with `007resort-api/.env.example`.
3. **Scripts** read credentials from protected files or generate them, never take secrets as parameters, support
   `-DryRun` (PowerShell) / `--dry-run` (bash), are idempotent, and pass shellcheck / PSScriptAnalyzer.
4. **Network** changes must keep the site server/database unreachable from the internet; sync
   and backups are outbound-only.
5. **Runbooks** are living documents: update them with every procedure change and after each
   incident review. Mark unapproved content as **DRAFT**.
6. Production site identifiers (public IPs, hostnames, serials) belong in the private site
   record, not in this repository.
