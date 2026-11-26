# Changelog

- 2026-11-26: Added workflow tools for a small-context agent: /plan-task and /next-step skills (PLAN.md, one step per run), project CLAUDE.md template, and a Stop hook that builds/lints changed .NET/React files (CRLF-proof command). Hook unverified on Windows Git Bash.

- 2026-11-26: Added sql-access skill (Sql.psm1, 14 exports): SELECT, schema, performance, INSERT/UPDATE/proc with rolled-back dry run; connection from appsettings.Development.json via a CLAUDE.md registration line. Real behavior unverified until the work smoke test.

- 2026-11-26: tfs-access ships module Tfs.psm1 + tfs-config.psd1; docs point to it; spec.md created. Write endpoints and 5.1-only paths unverified until the work smoke test. Deviation: Get-TfsTree and Git Bash EncodedCommand rule added from a field report.

- 2026-11-25: Added outlook-access (latest of 3 duplicates; sends without approval); its scripts and project-map's script now ship as files. All skills: avoid creating files, run commands directly.

- 2026-11-25: Imported skills tfs-access, project-map, microservices-logging-placement; org-specific details replaced with placeholders (filled on the work machine).
- 2026-11-25: Work on `main` only, via enforcing-coding-workflow.
- 2026-11-25: Initial config for the work computer: internal network only, avoid installing packages.
