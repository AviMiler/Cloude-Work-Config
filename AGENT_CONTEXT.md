# Agent Context

## Project
Claude Code config for the user's work computer. `user/` is copied to `~/.claude/` there. Structure and install steps: README.md.
Constraints of the target machine: internal network only, no package installs unless unavoidable (ask first), Windows PowerShell 5.1.
No org-specific details in this repo: use placeholders (`<TFS_HOST>`, `<COLLECTION>`, `<PROJECT>`, `<N>`, `<WORK_EMAIL>`), listed in README.
Skills must not create files if possible (run commands directly); needed scripts ship in the skill's `scripts/` folder.

## Last Changes
- Added outlook-access; skills ship their scripts; all skills: no file creation if possible.
- Imported 3 skills with placeholders (tfs-access, project-map, microservices-logging-placement).
- Moved to `main`-only workflow.
- Initial user/CLAUDE.md + user/settings.json.

## Next Steps
- Review each skill with the user, one by one.
- Old branch `ccr-9c5c479a-64cg22` still on GitHub: user deletes it manually.
