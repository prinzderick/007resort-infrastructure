## Summary

<!-- What does this PR change and why? Link the issue / ADR / runbook. -->

## Type of change

- [ ] feat (new config / script / template)
- [ ] fix
- [ ] docs / runbook
- [ ] chore / ci

## Checklist

- [ ] Title follows Conventional Commits (e.g. `docs(runbooks): add restore test checklist`)
- [ ] **No secrets**: no passwords, keys, tokens, certificates, real hostnames/IPs of production sites, or `.env` files
- [ ] New variables added to `env/local.env.example` / `env/cloud.env.example` with placeholder values and comments
- [ ] Scripts read credentials from protected files / secret store (never inline or as parameters)
- [ ] Scripts support `-DryRun` / `--dry-run`, are idempotent, and pass shellcheck / PSScriptAnalyzer
- [ ] Network changes keep the site server unreachable from the internet (outbound-only sync)
- [ ] Runbooks updated if behaviour/procedure changed
- [ ] CI green (compose validate, yamllint/actionlint, shellcheck, PSScriptAnalyzer, gitleaks)
