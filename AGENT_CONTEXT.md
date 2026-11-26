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
- Container: pwsh 7.4 + Pester + PSScriptAnalyzer must be installed each session (not preinstalled); the full suite takes more than 5 minutes.

## Last Changes
- tfs-access recipe 13 (my items -> email, in-process send-mail.ps1) + outlook-access rule 6; spec SR9 extended; docs only.
- Workflow tools: plan-task/next-step skills, user/templates/project-CLAUDE.md, Stop hook user/hooks/check-build.sh (settings.json hooks.Stop); spec section 4.
- sql-access skill (Sql.psm1, 14 exports) shipped; spec section 3; 338 Pester tests (535 with tfs), PSSA clean; all real-server paths unverified.
- tfs-access module (Tfs.psm1 + tfs-config.psd1) shipped; spec.md created; 197 Pester tests, PSSA clean, write paths unverified.
- Added outlook-access; skills ship their scripts; all skills: no file creation if possible.

## Next Steps
- User: at work, confirm the Stop hook runs under Git Bash (build error -> Claude fixes; `CLAUDE_SKIP_CHECK=1` disables) and its timing on dotnet/tsc.
- User: run `Test-TfsSetup` at work and report PASS/FAIL per area (write paths, 5.1-only paths unverified); run Pester once on Windows 5.1.
- tfs follow-ups: masking gaps (AccountKey=, `--password x`, PEM, short host/IP, titles); truncate-before-mask straddle; empty 200 body -> null; `[` `]` in `-Definition`; batch dropped-ids/encoding warnings; Deployed outer catch drops release name.
- User: run `Test-SqlSetup` at work (see README "first run of sql-access") and report PASS/FAIL per area; write and proc paths unverified.
- User: at work, run recipe 13 once: a successful send must not print "send failed", and its `-ge 200` cap check must stay equal to `MaxTop` in tfs-config.psd1.
- Next features: 2 outlook `-AttachAsTxt` + global EncodedCommand rule in user/CLAUDE.md (the multi-line mail body rule is already done: SR9, outlook rule 6), 3 project-map `--check`, 4 logging lint, 5 install.ps1.
