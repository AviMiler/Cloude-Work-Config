# Agent Context

## Project
Claude Code config for the user's work computer. `user/` is copied to `~/.claude/` there. Structure and install steps: README.md. Requirements: spec.md. Decisions: DECISIONS.md.
No org-specific details in this repo (also no user name, drive letter or real project name): use placeholders (`<TFS_HOST>`, `<COLLECTION>`, `<PROJECT>`, `<N>`, `<WORK_EMAIL>`), listed in README.
Skills must not create files if possible (run commands directly); needed scripts ship in the skill's `scripts/` folder.

## Work machine (standing facts)
- Internal network only; no package installs unless unavoidable (ask first).
- One-way: nothing can be copied out; the user retypes short codes/results in words, so keep output short.
- Windows PowerShell 5.1, sqlcmd v15, SqlClient, ODBC 17, SQL Server 2016 (sql-module must avoid 2017+ T-SQL).
- Work-side Claude Code runs commands via Git Bash: PowerShell only with `-EncodedCommand` from a quoted heredoc + `-OutputFormat Text`, no temp .ps1, no `$HOME`.
- Tests (Pester, PSScriptAnalyzer) run only here in the container (`tests/`, never shipped); real behavior is confirmed only on the work machine.

## Last Changes
- tfs-access module (Tfs.psm1 + tfs-config.psd1) shipped; spec.md created; 197 Pester tests, PSSA clean, write paths unverified.
- Added outlook-access; skills ship their scripts; all skills: no file creation if possible.
- Imported 3 skills with placeholders (tfs-access, project-map, microservices-logging-placement).
- Moved to `main`-only workflow.
- Initial user/CLAUDE.md + user/settings.json.

## Next Steps
- User: run `Test-TfsSetup` at work and report PASS/FAIL per area (write paths, 5.1-only paths unverified); run Pester once on Windows 5.1.
- tfs follow-ups: masking gaps (AccountKey=, `--password x`, PEM, short host/IP, titles); truncate-before-mask straddle; empty 200 body -> null; `[` `]` in `-Definition`; batch dropped-ids/encoding warnings; Deployed outer catch drops release name.
- Feature 2 sql-module (next; T-SQL 2016 only), 3 outlook `-AttachAsTxt` + global EncodedCommand rule in user/CLAUDE.md, 4 project-map `--check`, 5 logging lint, 6 install.ps1.
- Old branch `ccr-9c5c479a-64cg22` still on GitHub: user deletes it manually.
