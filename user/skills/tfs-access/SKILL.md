---
name: tfs-access
description: Complete guide to the internal Azure DevOps Server (TFS) via REST API from PowerShell. Use for ANY task involving TFS Boards/work items, Git repos, Pull Requests, Builds, Releases, Library, Agent pools, Test plans, Feeds, or Wiki. Read this file first, then the reference file(s) named in the index below.
---

# TFS access: core (always read this file fully)

Work in small steps. ONE API call at a time. Read the result, then decide the next call.
Before working on an area, READ the reference file listed for it in section 6. Do not rely on memory for endpoints, fields or bodies.

## 1. Environment (facts, do not question them)
- Server: on-premises Azure DevOps Server 2020 (maximum API version 6.0; 7.0 fails). Verified by a full read test on 2026-11-15.
- Read access verified in ALL areas (528 probes, 0 permission denials). Write access is NOT verified.
- Size of this server: about <N> Git repos, <N> TFVC branches, <N> build and release definitions. ALWAYS limit lists (`$top`, `Select-Object -First N`, filters). Never dump a full list.
- Collection URL: `https://<TFS_HOST>/tfs/<COLLECTION>`
- Project: `<PROJECT>`
- Shell: Windows PowerShell 5.1 (not 7). Use the `Invoke-Tfs` helper below, which wraps `Invoke-WebRequest` against `_apis` endpoints.
- `az` CLI is NOT installed. NO internet access. Never suggest installing or downloading anything from outside.
- Authentication: Windows integrated auth (`-UseDefaultCredentials`). No token. The agent has exactly the logged-in user's permissions.
- Never print, store, log or send tokens, passwords or secret values.

## 2. Helper function (define once per session)
```powershell
$Base = "https://<TFS_HOST>/tfs/<COLLECTION>"
$Proj = "<PROJECT>"

function ConvertTo-PsObject($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [System.Collections.IDictionary]) {
    $h = [ordered]@{}
    foreach ($k in @($o.Keys)) {
      $n = [string]$k; $i = 2
      while ($h.Contains($n)) { $n = "${k}_$i"; $i++ }
      $h[$n] = ConvertTo-PsObject $o[$k]
    }
    return [pscustomobject]$h
  }
  if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($x in $o) { $list.Add((ConvertTo-PsObject $x)) }
    return ,($list.ToArray())
  }
  return $o
}

function Invoke-Tfs {
  param(
    [string]$Path,
    [string]$Method = "GET",
    $Body = $null,
    [string]$Ver = "6.0",
    [string]$ContentType = "application/json"
  )
  $sep = if ($Path.Contains("?")) { "&" } else { "?" }
  $req = @{
    Uri = "$Base/$Path${sep}api-version=$Ver"
    Method = $Method
    UseDefaultCredentials = $true
    UseBasicParsing = $true
    ErrorAction = "Stop"
  }
  if ($null -ne $Body) {
    $json = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
    $req.Body = [Text.Encoding]::UTF8.GetBytes($json)
    $req.ContentType = "$ContentType; charset=utf-8"
  }
  try { $resp = Invoke-WebRequest @req }
  catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    $msg = ""
    try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { }
    Write-Error "HTTP $code $Method $Path :: $msg"
    throw
  }
  $text = $resp.Content
  if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $t = $text.TrimStart()
  if ($t.StartsWith("{") -or $t.StartsWith("[")) {
    try { return ($text | ConvertFrom-Json) } catch { }
    if ($PSVersionTable.PSVersion.Major -ge 6) { try { return ConvertTo-PsObject ($text | ConvertFrom-Json -AsHashtable) } catch { } }
    try {
      Add-Type -AssemblyName System.Web.Extensions
      $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
      $js.MaxJsonLength = [int]::MaxValue
      return ConvertTo-PsObject ($js.DeserializeObject($text))
    } catch { }
  }
  return $text
}
```
Rules for this helper:
- Never name a variable `$args` (reserved). Use `$req`.
- Always `ConvertTo-Json -InputObject $x`, never `$x | ConvertTo-Json` (it unrolls one-element arrays).
- The body is sent as UTF-8 bytes so Hebrew stays intact.
- Write `` `$top `` (backtick) or use single quotes so PowerShell does not expand `$top`. `$Proj` is expanded on purpose.
- In `-like`, `?` is a wildcard. Use `.Contains("?")` for a literal question mark.
- CRITICAL: PowerShell treats `?` as part of a variable name. `"...$id?$expand=..."` and `"...$Proj?x=1"` silently build a wrong URL and give 404. ALWAYS write `${id}?...`, `${Proj}?...`. This caused 404 errors on this server.
- The helper exists because on PowerShell 5.1 `Invoke-RestMethod` returns a long raw STRING instead of an object for some big responses (seen with `workitemtypes` and `distributedtask/tasks`). The helper detects this and converts the JSON itself. If a result is a string, do not read `.value` on it.

## 3. API versions (`api-version` ALWAYS required)
| Area | Version |
|---|---|
| Projects, Teams, Team members, Git (repos, refs, commits, pushes, PRs, trees, items) | `6.0` |
| Work items, WIQL, work item types and categories, fields, classification nodes, recycle bin | `6.0` |
| Team settings, field values, iterations, current iteration, days off, boards, columns, rows, card settings | `6.0` |
| Iteration capacities | `6.0-preview.2` |
| Iteration work items, Backlogs (`work/backlogs`) | `6.0-preview.1` (6.0 gives 400) |
| Tags, process configuration, delivery plans, team templates | `6.0-preview.1` |
| Team dashboards, project dashboards | `6.0-preview.2` |
| Build definitions, builds, logs, timeline, changes, artifacts, settings, tags | `6.0` |
| Build properties | `6.0-preview.1` |
| Release definitions, releases, deployments, approvals | `6.0` |
| Release folders | `6.0-preview.2` |
| Release definition revisions, release manual interventions | `6.0-preview.1` |
| Release environment templates | `6.0-preview.3` |
| Release environment detail (GET) | `6.0-preview.6` |
| Agent pools, agents, job requests | `6.0` |
| Agent maintenance definitions, project queues (`distributedtask/queues`) | `6.0-preview.1` |
| Test plans, suites, runs, results | `5.0` only |
| Test configurations | `5.0-preview.2` |
| Test run attachments, result summary by build, code coverage | `5.0-preview.1` |
| Identity (`_apis/connectionData`) | `6.0-preview.1` |
| Variable groups, Task groups, Service endpoints, Secure files, Deployment groups, Library environments | `6.0-preview.1` |
| Packaging feeds, packages, versions, views, retention, permissions | `6.0-preview.1` |
| Work item comments | `6.0-preview.3` |
| PR labels, PR policy evaluations, Git import requests | `6.0-preview.1` |
| Release environment deploy (PATCH) | `6.0-preview.6` (NOT verified; only the GET was tested) |
| Service hooks, security namespaces, notifications, TFVC (branches, changesets, labels, items) | `6.0` |

Full verified list (what works and what failed): `references/verified.md`.

Error meaning: 400 = wrong/missing api-version or malformed body (try the preview version, validate the JSON). 401 = not authenticated. 403 = no permission. 404 = wrong path, project, repo or id. 409 = conflict.
Never conclude "no access" from a 400 or 404.

## 4. URL patterns
- Collection level: `_apis/<area>` (projects, agent pools, feeds, connectionData)
- Project level: `<PROJECT>/_apis/<area>` (git, wit, build, release, test, distributedtask, serviceendpoint)
- Team level: `<PROJECT>/<team>/_apis/work/...`
- Release APIs are on the same host: `<PROJECT>/_apis/release/...` (no separate vsrm host)

## 5. Safety protocol (mandatory)
1. Default is READ ONLY (GET). Never run POST/PATCH/PUT/DELETE unless the user explicitly asked for that action.
2. Before ANY write: show exactly what will change (target, fields, old and new values) and wait for explicit approval.
3. Needs a second, separate confirmation each time: deleting anything, queuing builds, creating or deploying releases, approving or rejecting approvals, completing or abandoning pull requests, editing Library items (variable groups, service endpoints, task groups), changes to many items at once.
4. For work items, first test with `validateOnly=true` (see boards.md).
5. Small batches: do ONE item first, show the result, then continue.
6. After a write, GET the object again and report what is actually stored.
7. Output hygiene: no usernames, server names, emails or secret values in output. Select only the fields needed.
8. Never try to extract secret values (variable group secrets, service endpoint credentials). Never bypass a 403.
9. If something is ambiguous, ask the user. Do not guess IDs, states, field names or branches.
10. Do not create files if possible: run the PowerShell commands directly (define `Invoke-Tfs` in the session, do not save it as a .ps1). No temporary scripts, JSON bodies or scratch files. Write a file only when the user asked for one (export, download), in the location the user approved.

## 6. Index: which file to read
| Task | Read |
|---|---|
| Not sure where to look; full table of contents; endpoint cheat sheet | `references/INDEX.md` |
| Work items, queries, boards, sprints, links, comments, attachments | `references/boards.md` |
| Repos, branches, commits, files, Pull Requests, linking commits | `references/git-and-prs.md` |
| Build definitions, builds, logs, queue, cancel | `references/builds.md` |
| Release definitions, releases, approvals, deploy, deployments | `references/releases.md` |
| Variable groups, task groups, service endpoints, agent pools | `references/library-pools.md` |
| Test plans, feeds/packages, wiki | `references/tests-feeds-wiki.md` |
| Ready-made multi-step workflows | `references/recipes.md` |
| First-time probes: version, permissions, process template | `references/discovery.md` |
| PowerShell pitfalls, paging, encoding, output | `references/powershell-notes.md` |
| Any error, unexpected result | `references/troubleshooting.md` |
| What was verified on THIS server (working endpoints, versions, failed endpoints) | `references/verified.md` |

## 7. Working style
- Discover before acting: list names, types, IDs and states first.
- Keep output short: `Select-Object` only needed fields, `-First N`, `$top`.
- Report what you did, the result, and what you did not verify.
