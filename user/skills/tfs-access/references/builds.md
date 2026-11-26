# Pipelines: Builds

Prerequisite: import the module (SKILL.md section 2). API version `6.0`.

## Contents
1. Concepts
2. Build definitions
3. Listing builds (filters)
4. One build: details, changes, work items, artifacts
5. Finding why a build failed (timeline and logs)
6. Queue a build (WRITE)
7. Cancel, retain, delete (WRITE)
8. Latest build per definition
9. Pitfalls

## 1. Concepts
- A build DEFINITION is the pipeline (classic designer or YAML). A BUILD is one run of it.
- `status`: `notStarted`, `inProgress`, `completed`, `cancelling`, `postponed`.
- `result` (only when completed): `succeeded`, `partiallySucceeded`, `failed`, `canceled`.
- `reason`: `manual`, `individualCI`, `batchedCI`, `schedule`, `pullRequest`, ...
- Builds are the input for releases (see releases.md): a release deploys the artifact of a build.

## 2. Build definitions
```powershell
(Invoke-Tfs "$Proj/_apis/build/definitions?`$top=100").value | Select-Object id, name, path, @{n='repo';e={$_.repository.name}}
(Invoke-Tfs "$Proj/_apis/build/definitions?name=*Client*").value | Select-Object id, name      # wildcard by name
Invoke-Tfs "$Proj/_apis/build/definitions/<defId>"                                             # full definition
```
- A full definition includes `repository`, `triggers`, `variables`, `process`/`steps`. Variables marked `isSecret` have no value in the response. Never print variables unless the user asks, and never print secret ones.
- Definition revisions: `$Proj/_apis/build/definitions/<defId>/revisions`.

## 3. Listing builds
```powershell
$b = Invoke-Tfs "$Proj/_apis/build/builds?`$top=10&queryOrder=finishTimeDescending&statusFilter=completed"
$b.value | Select-Object id, buildNumber, status, result, @{n='def';e={$_.definition.name}}, sourceBranch, finishTime
```
Filters (combine with `&`):
| Parameter | Values / example |
|---|---|
| `definitions` | `12` or `12,15` (ids) |
| `statusFilter` | `inProgress`, `completed`, `notStarted`, `cancelling`, `all` |
| `resultFilter` | `succeeded`, `partiallySucceeded`, `failed`, `canceled` |
| `branchName` | `refs/heads/develop` |
| `reasonFilter` | `manual`, `individualCI`, `schedule`, `pullRequest` |
| `requestedFor` | user display name |
| `minTime` / `maxTime` | `2026-11-01T00:00:00Z` |
| `queryOrder` | `finishTimeDescending`, `queueTimeDescending`, `startTimeDescending` |
| `$top` | max results (default is limited, always set it) |
- Failed builds in the last day: `...&resultFilter=failed&minTime=<yesterday ISO>&statusFilter=completed`.
- Currently running: `statusFilter=inProgress`. Waiting: `statusFilter=notStarted`.
- Hebrew or special characters in filter values: use `[uri]::EscapeDataString()`.

## 4. One build
```powershell
$id = <buildId>
Invoke-Tfs "$Proj/_apis/build/builds/$id"
(Invoke-Tfs "$Proj/_apis/build/builds/$id/changes").value | Select-Object id, message          # commits in the build
(Invoke-Tfs "$Proj/_apis/build/builds/$id/workitems").value | Select-Object id               # associated work items
(Invoke-Tfs "$Proj/_apis/build/builds/$id/artifacts").value | Select-Object id, name
```
- Key fields: `buildNumber`, `sourceBranch`, `sourceVersion` (commit sha), `startTime`, `finishTime`, `queueTime`, `requestedFor`, `repository`, `definition`, `_links.web.href` (browser link).
- Duration: `([datetime]$b.finishTime - [datetime]$b.startTime)`.

## 5. Why did a build fail
One call: `Get-TfsBuildFailure -Id <buildId> [-TailLines N]`. It returns the build facts (BuildNumber, Definition, Status, Result, Branch, Sha), `FailedSteps` (tasks first; step, type, result, error issues, secrets masked), `LogStep` (first failed task with a log) and `LogTail` (last N log lines, default 40, cap 200, secrets and server name masked). Report: failing step, error message, branch and commit, and your hypothesis labeled as a hypothesis.

The manual steps (for details the function does not give):

Step 1: the timeline lists stages, jobs and tasks with their results.
```powershell
$tl = Invoke-Tfs "$Proj/_apis/build/builds/$id/timeline"
$tl.records | Where-Object { $_.result -in "failed","canceled" } | Select-Object type, name, result, @{n='logId';e={$_.log.id}}
```
Step 2: the error messages are in `issues`.
```powershell
$tl.records | Where-Object { $_.issues } | ForEach-Object { $_.name; $_.issues | Select-Object type, message }
```
Step 3: read the log of the failing task.
```powershell
Invoke-Tfs "$Proj/_apis/build/builds/$id/logs/<logId>" -Raw   # the log text (-Raw is required: it is not JSON)
```
- Logs are large. Show only the last 40 lines before the error: split by newline and take the tail.
- Always report: failing step name, error message, the commit/branch of the build, and your hypothesis labeled as a hypothesis.
- Log text can contain secrets, paths and usernames. Do not paste long raw logs. Quote only the relevant lines.

## 6. Queue a build (WRITE, confirm first)
```powershell
$body = @{
  definition = @{ id = <defId> }
  sourceBranch = "refs/heads/<branch>"
  parameters = '{"VariableName":"value"}'     # optional: JSON string of variables (only variables marked "settable at queue time")
}
Invoke-Tfs "$Proj/_apis/build/builds" -Method POST -Body $body
```
- Before queuing, state: definition name, branch, parameters. Wait for "yes".
- Never queue builds repeatedly or in loops.
- The response has the new build `id` and `status = notStarted`. Check progress with section 4 (poll every 20-30 seconds, at most about 20 times, then report).
- To build a specific commit add `sourceVersion = "<sha>"`.

## 7. Cancel, retain, delete (WRITE)
```powershell
Invoke-Tfs "$Proj/_apis/build/builds/<id>" -Method PATCH -Body @{ status = "cancelling" }       # cancel a running build
Invoke-Tfs "$Proj/_apis/build/builds/<id>" -Method PATCH -Body @{ keepForever = $true }          # retain build
```
- Deleting builds is not supported for the agent. Do not delete builds or definitions.

## 8. Latest build per definition
```powershell
Invoke-Tfs "$Proj/_apis/build/builds?definitions=<defId>&`$top=1&queryOrder=finishTimeDescending&statusFilter=completed"
```
- Per branch: add `&branchName=refs/heads/<branch>`.
- Status overview for several definitions: loop over the ids and show one row each: definition, last result, finish time, branch.

## 9. Pitfalls
- Failed on this server, do not use: `definitions/<id>/yaml`, `_apis/build/folders`, `_apis/build/options`, `builds/<id>/report`.
- Verified extras: `builds/<id>/properties` (`6.0-preview.1`), `builds/<id>/tags`, `definitions/<id>/revisions`, `definitions/templates`, `_apis/build/settings`, `_apis/build/controllers`.
- Always pass `$top`; without it the default page is small and may hide results.
- `result` is null while a build runs. Check `status` first.
- `sourceBranch` uses the `refs/heads/` prefix in queries and bodies.
- Timeline records can be empty for builds that never started (queued only).
- A definition `id` is not the same as a build `id`. Check which one the user means.
- Classic and YAML definitions return slightly different structures. Do not assume `steps` exists.
