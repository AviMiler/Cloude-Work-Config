# Troubleshooting

Always read the error message first: `Invoke-Tfs` throws `HTTP <code> <method> <path> :: <message>` (code 0 = network).

## Contents
1. Decision table by HTTP status
2. Symptom table
3. Per-area problems
4. Reporting problems to the user
5. What NOT to do

## 1. Decision table by HTTP status
| Status | Meaning | What to do |
|---|---|---|
| 400 | Bad request: wrong or missing api-version, malformed JSON, missing required field, invalid value | Read the message. Try the version table in SKILL.md section 3 (add `-preview.1`). Validate the body. For work items use `validateOnly=true` |
| 401 | Not authenticated | Confirm `-UseDefaultCredentials`. Run the identity check (recipes.md section 1). If the machine is not logged in with the domain account, report it |
| 403 | Authenticated but not allowed | Report which action failed. Do NOT try another route to get around it |
| 404 | Path, project, repo, id or version does not exist | Re-list names/ids (never guess). Check the area/version combination |
| 405 | Wrong HTTP method | Check GET/POST/PATCH/PUT for that endpoint |
| 409 | Conflict (exists already, stale revision) | Read the current state, then decide. Do not retry blindly |
| 412 | Precondition failed (ETag/rev mismatch) | Re-read the object and re-apply the change |
| 413 | Body too large | Split the request (batches of 200 ids, smaller files) |
| 429 | Too many requests | Stop, wait 30-60 seconds, reduce request rate |
| 500/503 | Server error / busy | Wait and retry once. Then report |

## 2. Symptom table
| Symptom | Likely cause | Fix |
|---|---|---|
| Hebrew shows as `????` | body not sent as UTF-8 | use `Invoke-Tfs` (UTF-8 bytes) |
| Array became an object in the body | `$x \| ConvertTo-Json` unrolled it | `ConvertTo-Json -InputObject $x` |
| `$top` missing from the URL | PowerShell expanded `$top` inside double quotes (bash does the same to an unquoted heredoc) | write `` `$top `` or single quotes; from Git Bash use the quoted heredoc `<<'PS'` (SKILL.md section 2) |
| HTTP 400 on `workitemsbatch`; the sent `ids` look like `[[1,2]]` | the id list was nested (`,@(...)` or an array inside an array) | send `@{ ids = @($ids); fields = @(...) }` with a flat int array, or use `Get-TfsMyItems` / `Get-TfsTree` |
| Hebrew shows as `????` or garbage in the output, or a script fails to parse Hebrew | console output encoding is not UTF-8, or a .ps1 without BOM was read as ANSI | importing the module sets UTF-8 output; use `[Console]::OutputEncoding = [Text.Encoding]::UTF8`, not `chcp`; do not write .ps1 files (SKILL.md rule 10) |
| Hebrew letters appear in reversed order, or punctuation sits in the wrong place | the console has no bidi support (display limit); the data is fine | do not reverse or "fix" strings; see SKILL.md "Hebrew content" |
| A text match or WIQL filter finds nothing for a word that is on screen, or entities such as `&nbsp;` show | invisible bidi marks or niqqud in the text, or the field is HTML | strip marks and decode HTML as in SKILL.md "Hebrew content" |
| `powershell -File "$HOME/..."` ends with exit 127 or file not found | Git Bash `$HOME` is not the Windows profile (other drive), and `-File` needs a temp file | run with `-EncodedCommand` and a quoted heredoc (SKILL.md section 2); use `$env:USERPROFILE` inside the PowerShell code |
| Error `... :: PARSE` (status 200), or a section shows `error: PARSE` | the server answered with something that is not JSON (HTML login or error page, redirect target) | check authentication and `CollectionUrl` (`Test-TfsSetup`); for a legitimately non-JSON answer (log text, file content) add `-Raw` |
| Error `... :: REDIRECT not followed` | the server redirected (often to a login page); redirects are never followed so credentials cannot leave | check `CollectionUrl` (http versus https, collection path); report it, do not bypass |
| Error `... :: TOOBIG` | the answer is larger than 5,000,000 characters | narrow the request (`$top`, filters, line ranges) |
| Output arrives as XML starting with `#< CLIXML` | PowerShell wrote its stderr or progress as CLIXML | add `-OutputFormat Text` to the `powershell.exe -EncodedCommand` call (SKILL.md section 2) |
| WIQL link query returns 400 or no relations | not `FROM WorkItemLinks ... MODE (Recursive)`, or the id is a string like `'Proj\123'` instead of an integer | use `Get-TfsTree -Id N`, or fix the query (boards.md section 3) |
| 404 on a URL that contains a variable followed by `?` | `"$id?x=1"` reads `$id?` as one variable name | write `"${id}?x=1"` |
| Result is one very long string, `.value` is empty | PowerShell 5.1 did not parse the JSON | use `Invoke-Tfs` from the Tfs module (SKILL.md section 2) |
| Nested properties missing in the sent JSON | depth too low | `-Depth 20` |
| Response is HTML, not JSON | login/redirect or wrong URL | check `CollectionUrl` in `scripts/tfs-config.psd1` and the `_apis` path (run `Test-TfsSetup`) |
| `The term 'az' is not recognized` | Azure CLI not installed | by design. Use REST |
| Same call works for one project, not another | permissions per project | report; do not bypass |
| List is shorter than expected | default page size | set `$top`, use paging (powershell-notes.md section 5) |
| Empty list but UI shows items | wrong project or team scope, or no permission | check names; try the team-level URL |
| Works in browser, fails in PowerShell | certificate, proxy or auth | test with `Invoke-WebRequest -UseDefaultCredentials`; report TLS errors |
| Timeouts | big queries (`recursionLevel=Full`, huge WIQL) | narrow the query |
| `ConvertFrom-Json` fails on large content | 2 MB limit on 5.1 | see powershell-notes.md section 1 |
| `Invoke-Tfs` / `Get-Tfs...` not recognized, or `$Base`/`$Proj` empty | module not imported in this PowerShell process | start the command block with the `Import-Module` line (SKILL.md section 2) |
| `Import-Module` blocked (execution policy, files from a download) | the policy blocks the copied `.psm1` | report it to the user and suggest `Unblock-File` on the files in `scripts\`; NEVER change the execution policy yourself |
| Warning `Config: placeholder <...> not replaced`, or every function throws `Config: ...` | `scripts/tfs-config.psd1` still has placeholders or an invalid value | run `Test-TfsSetup`; tell the user which key (the message names it); do not guess values |

## 3. Per-area problems
Boards:
- 404 or 500 on current iteration, @CurrentIteration or boards for one team: that team has no iterations configured. Use another team.
- 400 on iteration work items or backlogs: add `-Ver "6.0-preview.1"`.
- 400 on create: missing required field, or invalid state/area/iteration. Run `validateOnly=true`; read the message; check `alwaysRequired` fields (boards.md section 2).
- Invalid `AssignedTo`: copy the format from an existing item (`uniqueName`).
- Parent link rejected: item already has a parent, or the type hierarchy does not allow it.
- WIQL 400 about the query: field name spelled wrong (use reference names like `System.State`), quote not doubled, more than 20,000 results.
Git:
- 404 on repo: use the exact name from the list. 404 on a file: wrong branch or path (leading `/`).
- PR 409: an active PR with the same source/target exists.
- PR cannot complete: policies (reviewers, builds, linked work items) or merge conflicts. Read `mergeStatus` and policies (git-and-prs.md section 10).
Builds:
- Empty timeline: build never started. Check `status`.
- Queue fails with 400: parameter not settable at queue time, or a branch that does not exist.
Releases:
- 400 on approvals: use `6.0-preview.3`.
- Deploy PATCH 400/404: try `6.0-preview.6`, then `6.0-preview.5`, then report.
- Wrong id: definition id vs release id vs environment id (releases.md section 10).
Library:
- 400: add `-Ver "6.0-preview.1"`.
- Secret values missing: expected. Never try to recover them.
Test plans:
- 404/400 with `6.0`: use `-Ver "5.0"`.

## 4. Reporting problems to the user
State: (1) what you tried (endpoint and version, without secrets), (2) the HTTP status and the server message, (3) what you ruled out, (4) what the user can check (permission, UI, admin). Keep it short.

## 5. What NOT to do
- Do not retry writes in a loop. A failed write may have partly succeeded: read the state before retrying.
- Do not escalate (use other credentials, tokens found on disk, other accounts) after a 401/403.
- Do not disable certificate validation or change security settings to make a call pass.
- Do not run broad scans of the server to "see what works". Stay within the user's request.
- Do not paste secrets, tokens or large raw logs into the output.
