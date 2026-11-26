# Decisions

Short records of design decisions that are not obvious from the code. Newest first.

## 2026-11-26: Invoke-Tfs keeps POST/PATCH/PUT/DELETE as a raw escape hatch (tfs-access)

**Question:** should the module's raw `Invoke-Tfs` refuse write methods (or require an `-AllowWrite` switch), so that only `New-TfsItem` / `Set-TfsItem` can write?

**Decision:** no. `Invoke-Tfs` accepts every method. The documented raw REST for areas without a function (comments, attachments, PR writes, releases, Library, deletes) needs it, and those calls are explicitly allowed after the extra confirmation in SKILL.md section 5.

**Protection:** the SKILL.md safety protocol (rules 1-5: read-only by default, show old and new values and wait for approval, second confirmation for destructive actions, validateOnly first, one item first). The module cannot enforce human approval either way.

**Alternative considered:** an `-AllowWrite` switch on `Invoke-Tfs`. Rejected because an agent can add the switch as easily as it can choose a method, so it adds friction to every documented raw write without adding real protection.

## 2026-11-26: Tfs module publishes `$global:Base` and `$global:Proj` (tfs-access)

**Question:** after `Import-Module Tfs.psm1`, how do the roughly 130 raw `Invoke-Tfs "$Proj/..."` and `$Base` snippets in `user/skills/tfs-access/references/` get their values: global variables set on import, or a getter function (for example `Get-TfsProject`) that every snippet would have to call?

**Decision:** global variables. `Import-TfsConfig` (private) sets `$global:Base` and `$global:Proj` from `scripts/tfs-config.psd1` when the config is valid, and removes them when it is not.

**Why:**
- The reference files keep working unchanged; a getter would mean rewriting every snippet.
- Module functions never read the globals. They use private `$script:Base` / `$script:Proj` copies, so a user edit of `$Proj` in the session cannot break them.
- The only cost is the PSScriptAnalyzer rule `PSAvoidGlobalVars`; it is suppressed on that one function with a written justification.

**Consequences:** the values live in the PowerShell session and could be printed by a careless command; SKILL.md says never to print them. `Hide-TfsSecret` masks the base URL and host in everything the module outputs.
