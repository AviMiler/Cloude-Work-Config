# Pipelines: Releases

Prerequisite: import the module (SKILL.md section 2). API version `6.0` (exceptions noted).
On this server the Release API is on the same host: `$Proj/_apis/release/...`.

## Contents
1. Concepts
2. Release definitions
3. Listing and reading releases
4. What is deployed where (deployments)
5. Pending approvals and approving (WRITE)
6. Create a release (WRITE)
7. Deploy / redeploy an environment (WRITE)
8. Abandon, cancel (WRITE)
9. Logs and failure investigation
10. Pitfalls

## 1. Concepts
- Release DEFINITION: the pipeline with artifacts (usually a build), environments (stages, e.g. test, production) and approvals.
- RELEASE: one instance created from a definition at specific artifact versions.
- ENVIRONMENT (stage): a deployment target inside a release. Each has its own status.
- Release `status`: `draft`, `active`, `abandoned`.
- Environment `status`: `notStarted`, `inProgress`, `succeeded`, `rejected`, `canceled`, `partiallySucceeded`, `queued`, `scheduled`.
- Approvals can be pre-deployment (before an environment starts) or post-deployment.
- Deploying to production environments is high-risk. Always state release and environment, and get a clear "yes".

## 2. Release definitions
```powershell
(Invoke-Tfs "$Proj/_apis/release/definitions").value | Select-Object id, name, path
(Invoke-Tfs "$Proj/_apis/release/definitions?searchText=Client&`$expand=environments").value | Select-Object id, name
$d = Invoke-Tfs "$Proj/_apis/release/definitions/<defId>"
$d.environments | Select-Object id, name, rank                 # stages
$d.artifacts | Select-Object alias, type, @{n='source';e={$_.definitionReference.definition.name}}
```
- Definition `variables` and variable groups may hold secrets. Never print them.
- `environments[].id` is the DEFINITION environment id. A release has its own environment ids (section 3).

## 3. Listing and reading releases
```powershell
$r = Invoke-Tfs "$Proj/_apis/release/releases?definitionId=<defId>&`$top=10&`$expand=environments&queryOrder=descending"
$r.value | Select-Object id, name, status, createdOn, @{n='stages';e={($_.environments | ForEach-Object { "$($_.name)=$($_.status)" }) -join ", "}}
```
Filters: `definitionId`, `definitionEnvironmentId`, `statusFilter` (`draft|active|abandoned`), `environmentStatusFilter`, `minCreatedTime`, `maxCreatedTime`, `createdBy`, `searchText`, `$top`, `$expand` (`environments`, `artifacts`, `approvals`, `manualInterventions`, `variables`), `queryOrder` (`ascending|descending`).
- Name format in this organization looks like `<Prefix>-yyyyMMdd.N`.
One release:
```powershell
$rel = Invoke-Tfs "$Proj/_apis/release/releases/<releaseId>"
$rel.environments | Select-Object id, name, status
$rel.artifacts | Select-Object alias, @{n='version';e={$_.definitionReference.version.name}}, @{n='branch';e={$_.definitionReference.branch.name}}
```
- The artifact `version` is the build number. `definitionReference.version.id` is the build id (use with builds.md).
- Release environment `id` here is what the deploy call needs.

## 4. What is deployed where
One call: `Get-TfsDeployed -Definition <name text or wildcard> [-Environment 'Prod*'] [-MaxDefinitions N]`. Per environment of the matching definitions (default 3, cap 10) it returns the latest succeeded deployment: Release, ArtifactVersion, Completed (`none` or `error: HTTP n` when there is nothing or the call failed). The ArtifactVersion shape is not verified on this server. Raw form:
```powershell
(Invoke-Tfs "$Proj/_apis/release/deployments?definitionId=<defId>&definitionEnvironmentId=<envDefId>&deploymentStatus=succeeded&operationStatus=Approved&`$top=5").value |
  Select-Object @{n='release';e={$_.release.name}}, @{n='env';e={$_.releaseEnvironment.name}}, deploymentStatus, completedOn
```
- Top 1 succeeded deployment per environment = the version currently deployed there.
- `deploymentStatus`: `succeeded`, `failed`, `partiallySucceeded`, `notDeployed`, `all`.
- Also lets you answer "when was production last updated".

## 5. Approvals
Pending approvals also appear in `Get-TfsDailySummary` (Id, Release, Environment, Type; no approver names). List pending (READ) raw:
```powershell
(Invoke-Tfs "$Proj/_apis/release/approvals?statusFilter=pending&`$top=50").value |
  Select-Object id, approvalType, @{n='release';e={$_.release.name}}, @{n='env';e={$_.releaseEnvironment.name}}, @{n='approver';e={$_.approver.displayName}}
```
- If 400, retry with `-Ver "6.0-preview.3"`.
- Filters: `assignedToFilter=<name>`, `releaseIdsFilter=<id>`, `typeFilter=preDeploy|postDeploy`, `statusFilter=pending|approved|rejected`.
Approve or reject (WRITE, double confirmation, only on explicit request):
```powershell
Invoke-Tfs "$Proj/_apis/release/approvals/<approvalId>" -Method PATCH -Body @{ status = "approved"; comments = "Approved via agent on user request" }
```
- `status`: `approved` or `rejected`.
- Show: release name, environment, approval type, then ask "approve?". An approval is a decision the user owns.
- Verify after: re-read the release and check the environment status moved on.

## 6. Create a release (WRITE)
Step 1, inspect the definition (section 2) to see its artifacts and aliases.
Step 2, pick the artifact version. For a build artifact, find the build id (builds.md section 3).
Step 3, show the user: definition, artifact version, description. Wait for "yes".
```powershell
$body = @{
  definitionId = <defId>
  description = "Created via agent"
  isDraft = $false
  reason = "none"
  artifacts = @( @{ alias = "<artifactAlias>"; instanceReference = @{ id = "<buildId>"; name = "<buildNumber>" } } )
}
Invoke-Tfs "$Proj/_apis/release/releases" -Method POST -Body $body
```
- If `artifacts` is omitted, the latest version is used (when the definition allows it). Prefer explicit values.
- `manualEnvironments = @("<envName>")` makes the listed environments start manually (they will not auto-deploy).
- `isDraft = $true` creates a draft that does not start anything. Safer for first tests.
- If the definition has automatic triggers, environments may begin deploying right after creation. State this to the user beforehand.

## 7. Deploy or redeploy an environment (WRITE)
```powershell
Invoke-Tfs "$Proj/_apis/release/releases/<releaseId>/environments/<releaseEnvId>" -Method PATCH -Body @{ status = "inProgress"; comment = "Triggered via agent" } -Ver "6.0-preview.6"
```
- Redeploy an environment that already ran: same call.
- Optional: `scheduledDeploymentTime = "<ISO date>"` to schedule.
- `-Ver 6.0-preview.6` is the best-known version for this call. If it returns 400/404, try `6.0-preview.5`, then stop and report. Do not loop.
- After the call: poll the environment status every 20-30 seconds (at most 20 times) and report: `inProgress`, `succeeded`, `rejected`, or an approval being required.
- Production: always say "production" explicitly in the confirmation question.

## 8. Abandon, cancel (WRITE)
```powershell
Invoke-Tfs "$Proj/_apis/release/releases/<releaseId>" -Method PATCH -Body @{ status = "abandoned"; comment = "reason" }                  # abandon the whole release
Invoke-Tfs "$Proj/_apis/release/releases/<releaseId>/environments/<releaseEnvId>" -Method PATCH -Body @{ status = "canceled"; comment = "reason" } -Ver "6.0-preview.6"  # cancel one stage
```
- Abandoning is not reversible from the API. Confirm.

## 9. Logs and failure investigation
```powershell
$rel = Invoke-Tfs "$Proj/_apis/release/releases/<releaseId>"
$stage = $rel.environments | Where-Object { $_.status -ne "succeeded" -and $_.status -ne "notStarted" }
$stage | ForEach-Object { $_.name; $_.deploySteps[-1].releaseDeployPhases | ForEach-Object { $_.deploymentJobs.tasks | Select-Object id, name, status, @{n='log';e={$_.logUrl}} } }
```
- Failed task names and statuses are in `environments[].deploySteps[].releaseDeployPhases[].deploymentJobs[].tasks[]`.
- `tasks[].issues` often contains the error message. Show those first.
- A task log URL can be fetched with `Invoke-RestMethod -UseDefaultCredentials` on the `logUrl` value (text). Show only the relevant tail lines.
- All logs of a release as a zip: `GET $Proj/_apis/release/releases/<id>/logs` with `-Ver 6.0-preview.2` and `Invoke-WebRequest -OutFile logs.zip` (see powershell-notes.md).
- Report: environment, failing task, error line, and the artifact version/branch involved. Label hypotheses as such.

## 10. Pitfalls
- Failed on this server: `$Proj/_apis/release/settings`.
- Verified extras: definition revisions (`6.0-preview.1`), folders (`6.0-preview.2`), environment templates (`6.0-preview.3`), manual interventions (`6.0-preview.1`), release environment GET (`6.0-preview.6`).
- Approval lists are capped by `$top` (50 reached for pending/approved/rejected). Always filter by release or definition.
- Three different ids: definition id, release id, release environment id (and a separate definition environment id). Use the right one for each call.
- `$expand=environments` is needed to see stage statuses in a list call.
- A release with `status = draft` has not started. It needs a deploy call or a "start" from the UI.
- Approvals may be assigned to groups. A PATCH can fail with 403 if the signed-in user is not allowed to approve. Report it; never try to bypass.
- Always set `$top`; the default list is short and sorted by newest.
