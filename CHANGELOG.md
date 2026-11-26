# Changelog

- 2026-11-26: tfs-access ships module Tfs.psm1 + tfs-config.psd1; docs point to it; spec.md created. Write endpoints and 5.1-only paths unverified until the work smoke test. Deviation: Get-TfsTree and Git Bash EncodedCommand rule added from a field report.

- 2026-11-25: Added outlook-access (latest of 3 duplicates; sends without approval); its scripts and project-map's script now ship as files. All skills: avoid creating files, run commands directly.

- 2026-11-25: Imported skills tfs-access, project-map, microservices-logging-placement; org-specific details replaced with placeholders (filled on the work machine).
- 2026-11-25: Work on `main` only, via enforcing-coding-workflow.
- 2026-11-25: Initial config for the work computer: internal network only, avoid installing packages.
