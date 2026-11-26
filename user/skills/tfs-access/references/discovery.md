# Discovery: first-time probes (safe, read-only)

Run these once to learn what this server supports. They send only GET requests and print only generic results.
Ask the user before running the version probe: it sends many requests in a short time (about 100) and a security monitor could notice it.

## Contents
1. Connectivity and authentication
2. Server API version probe
3. Per-area API version probe
4. Permission probe (read) and dry-run write probe
5. Process template probe
6. What is already known about this server

## 1. Connectivity and authentication
```powershell
Test-TfsSetup
```
- Prints Area, Result (PASS/FAIL/SKIP) and Code only (config, connectivity, auth, project, WIQL, repos, builds, deployments). On FAIL see troubleshooting.md.

## 2. Server API version probe
```powershell
foreach ($v in "4.1","5.0","5.1","6.0","6.1","7.0") {
  try { Invoke-Tfs "_apis/projects?`$top=1" -Ver $v | Out-Null; "API $v : OK" }
  catch { "API $v : FAIL" }
}
```
- The highest OK version tells the server generation: 4.1 = TFS 2018, 5.0 = 2019, 6.0 = 2020, 7.0 = 2022.
- Already measured on this server: 6.0 works, 7.0 fails.

## 3. Per-area API version probe (sanitized output)
```powershell
$vers = "4.1","5.0","5.0-preview.1","5.1","5.1-preview.1","6.0","6.0-preview.1","7.0"
$areas = [ordered]@{
  "Projects"="_apis/projects"; "Repos"="$Proj/_apis/git/repositories"; "WorkItemTypes"="$Proj/_apis/wit/workitemtypes"
  "Builds"="$Proj/_apis/build/builds?`$top=1"; "ReleaseDefs"="$Proj/_apis/release/definitions"; "Releases"="$Proj/_apis/release/releases?`$top=1"
  "AgentPools"="_apis/distributedtask/pools"; "TestPlans"="$Proj/_apis/test/plans"; "VariableGroups"="$Proj/_apis/distributedtask/variablegroups"
  "Feeds"="_apis/packaging/feeds"
}
foreach ($a in $areas.GetEnumerator()) {
  $sep = if ($a.Value.Contains("?")) { "&" } else { "?" }
  $ok = @()
  foreach ($v in $vers) {
    try { Invoke-RestMethod -Uri "$Base/$($a.Value)${sep}api-version=$v" -UseDefaultCredentials -ErrorAction Stop | Out-Null; $ok += $v } catch { }
  }
  "{0,-16} {1}" -f $a.Key, $(if ($ok) { $ok -join ", " } else { "NONE" })
}
```
- Prints only area names and version lists. Nothing else.
- Measured on this server (summary in SKILL.md section 3).

## 4. Permission probe
READ probe: a GET that returns 200 means read permission. 401 = not authenticated. 403 = no permission.
WRITE probe (no data is saved): work items support a dry run.
```powershell
$ops = @( @{ op="add"; path="/fields/System.Title"; value="permission probe" } )
try { Invoke-Tfs "$Proj/_apis/wit/workitems/`$Task?validateOnly=true" -Method POST -Body $ops -ContentType "application/json-patch+json" | Out-Null; "Create work item: allowed (dry run)" }
catch { "Create work item: not allowed or invalid (see error code)" }
```
- A dry run that fails with a missing required field still proves the permission exists (the error is about validation, not 403).
- There is no dry run for builds, releases or PRs. Do NOT test those permissions by performing the action. Ask the user to check in the UI, or rely on a 403 when a real, approved action is attempted.

## 5. Process template probe
```powershell
(Invoke-Tfs "$Proj/_apis/wit/workitemtypes").value | Select-Object -ExpandProperty name   # needs Invoke-Tfs: on PS 5.1 the raw call returns a string
```
- This server uses a customized process template (names did not match Agile, Scrum, CMMI or Basic in the earlier guess, which also failed because of the string issue). Read the real names first.
- Names tell the template: `User Story` = Agile, `Product Backlog Item` = Scrum, `Requirement` = CMMI, `Issue` only = Basic. Extra names = customization.
- Then read states for the types in use (boards.md section 2).

## 6. Known about this server (verified by a full read test, 2026-11-15)
- Azure DevOps Server 2020 (max API 6.0). Collection and project are set in `scripts/tfs-config.psd1`. Windows PowerShell 5.1.
- Windows integrated authentication works. 528 read probes: 415 OK, 0 permission denials, 24 not available, 22 failures (all explained by wrong version, wrong path, team setup, or script bugs).
- The exact working version of each endpoint is in `references/verified.md`.
- Write permissions have NOT been verified. Treat every write as untested until it succeeds once with the user's approval.
