# Scripts

> **DRAFT** - pending architecture approval. Scripts are skeletons: review and test on a
> non-production machine before use.

| Script | Purpose |
| --- | --- |
| [`windows/install-api-service.ps1`](windows/install-api-service.ps1) | Install/update the published Otueke API as a Windows service (delayed auto-start, restart on failure, depends on MySQL). |
| [`windows/backup-mysql.ps1`](windows/backup-mysql.ps1) | Nightly `mysqldump --single-transaction` backup with binlog position, gzip, NAS copy and local retention. |

## Rules

- **No secrets in scripts or parameters.** MySQL credentials come from a protected option file
  (`--defaults-extra-file`); service account passwords via `Get-Credential`.
- Scripts support `-WhatIf` / `-Verbose`; run with `-WhatIf` first.
- Run from an elevated PowerShell session on the site server.
- CI runs PSScriptAnalyzer (severity Error) on everything under `scripts/`.

## Local lint

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Error
```
