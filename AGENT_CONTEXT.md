# Agent Context

## Project
Claude Code config for the user's work computer. `user/` is copied to `~/.claude/` there. Structure and install steps: README.md.
Constraints of the target machine: internal network only, no package installs unless unavoidable (ask first), Windows PowerShell 5.1.
No org-specific details in this repo: use placeholders (`<TFS_HOST>`, `<COLLECTION>`, `<PROJECT>`, `<N>`), listed in README.

## Last Changes
- Imported 3 skills with placeholders (tfs-access, project-map, microservices-logging-placement).
- Moved to `main`-only workflow.
- Initial user/CLAUDE.md + user/settings.json.

## Next Steps
- Outlook skill: user picks one of 3 duplicates (outlook-access / send-mail-outlook-work / send-mail-outlook-general); import it with email placeholder.
- Review each skill with the user, one by one.
- Old branch `ccr-9c5c479a-64cg22` still on GitHub: user deletes it manually.
