# Decisions

Short records of design decisions that are not obvious from the code. Newest first.

## 2026-11-26: Hebrew content rules: inline in both skills, not a shared skill

**Decision:** tfs-access and outlook-access each get their own short "Hebrew content" section in SKILL.md. The shared rules (display is not corruption, strip bidi marks and niqqud, geresh/gershayim, Hebrew answers) are written in both. The tfs section has the HTML and search rules, the outlook section the reply-chain and date rules.

**Alternatives considered:** one new shared skill `hebrew-content` that both SKILL.md files point to.

**Why:** the work-side model is small-context and weak, and follows a pointer to another skill unreliably. Inline rules are always in the context that is already loaded. Cost accepted: 3-4 shared bullets are duplicated, so a change to one of them must be made in both skills (keep them in sync). The outlook date rule differs on purpose: `read-mail.ps1` prints month/day/year (invariant culture), not the Hebrew day/month order.

## 2026-11-26: build-check hook: Stop event, bash, CRLF-proof command

**Decision:** `check-build.sh` is a bash hook on the Stop event. It parses stdin with grep/sed, runs only tools already in the project (`dotnet build --no-restore`, local `node_modules/.bin/tsc` and `eslint`), and is started by `bash -c 'bash <(sed "s/\r$//" ~/.claude/hooks/check-build.sh)'` with timeout 300.

**Alternatives considered:** PostToolUse (a `dotnet build` per edit is too slow on that machine); a PowerShell hook (SR9 says the work side runs through Git Bash, and PowerShell needs `-EncodedCommand` tricks); `jq` for JSON (not installed, SR3); `npx tsc` (may download, SR2/SR3); a plain `bash ~/.claude/hooks/check-build.sh` (a CRLF copy of the script, as Windows copying can produce, failed and exited 2 on every turn in verify).

**Why:** Stop gives one check per turn, bash fits Git Bash with no extra runtime, and stripping `\r` at launch makes the hook survive a CRLF copy (`.gitattributes` keeps the repo copy LF). `--no-restore` avoids network and slow restores. Accepted cost: it runs on every Stop while the tree has relevant changes; `CLAUDE_SKIP_CHECK=1` opts out.

## 2026-11-26: sql-access dry run: OUTPUT injection and T-SQL text transactions

**Decision:** the write dry run captures old/new values by injecting an `OUTPUT` clause into the INSERT/UPDATE, inside a transaction that is always rolled back. Count-only fallback on errors such as 334 or 4186. `BEGIN TRAN` / `ROLLBACK` are sent as T-SQL text batches, not `SqlTransaction`. Stored procedures are a separate `Invoke-SqlProc`.

**Alternatives considered:** SELECT before and after by primary key (needs a PK and loses rows whose WHERE stops matching after the update); `SqlTransaction` (cannot survive a procedure that commits or rolls back internally, and is harder to order and test); EXEC inside `Invoke-SqlWrite` (needs SQL text parsing and invites dynamic SQL).

**Why:** the text-batch transaction lets the module see `@@TRANCOUNT` after a procedure and report Kind TXN; OUTPUT shows exactly the rows the statement touched.

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
