# Library (variable groups, task groups, service endpoints, secure files) and agent pools

Prerequisite: `Invoke-Tfs`, `$Base`, `$Proj` from SKILL.md.
SECURITY FIRST: this area holds secrets. Rules:
- List NAMES, IDs and TYPES only.
- Never print variable values marked secret, endpoint authorization data, passwords, tokens or certificates.
- Never try to extract hidden values. A null/empty value for a secret is correct behavior.
- Any write here needs the exact diff shown and an explicit "yes".

## Contents
1. Variable groups
2. Task groups
3. Service endpoints (service connections)
4. Secure files
5. Agent pools and agents
6. Deployment groups and environments
7. Pitfalls

## 1. Variable groups (version `6.0-preview.1`)
```powershell
(Invoke-Tfs "$Proj/_apis/distributedtask/variablegroups" -Ver "6.0-preview.1").value | Select-Object id, name, type
(Invoke-Tfs "$Proj/_apis/distributedtask/variablegroups?groupName=<name>" -Ver "6.0-preview.1").value
```
- One group: `$Proj/_apis/distributedtask/variablegroups/<id>`.
- Group content: `variables` is an object: each property has `value` and `isSecret`. For secrets `value` is absent.
- Safe listing of variable names only:
```powershell
$g = Invoke-Tfs "$Proj/_apis/distributedtask/variablegroups/<id>" -Ver "6.0-preview.1"
$g.variables.PSObject.Properties | Select-Object Name, @{n='secret';e={$_.Value.isSecret}}
```
- Print values only when the user explicitly asks for non-secret values, and only those.
- Update (WRITE, sensitive): PUT `.../variablegroups/<id>` with the FULL group object (name, type, variables). A partial body deletes the other variables. Always read the group first, change one property, and write it back. Secret variables must be re-sent with their value (the API does not return it), which means a PUT can erase a secret. Do NOT update groups containing secrets through the API. Tell the user to use the UI.
- Delete: never.

## 2. Task groups (version `6.0-preview.1`)
```powershell
(Invoke-Tfs "$Proj/_apis/distributedtask/taskgroups" -Ver "6.0-preview.1").value | Select-Object id, name, @{n='ver';e={$_.version.major}}
```
- A task group is a reusable list of steps used by build/release definitions.
- Reading is safe. Changing a task group affects every pipeline that uses it. Do not change without an explicit request and a full diff.

## 3. Service endpoints (version `6.0-preview.1`)
```powershell
(Invoke-Tfs "$Proj/_apis/serviceendpoint/endpoints" -Ver "6.0-preview.1").value | Select-Object id, name, type, isReady
(Invoke-Tfs "$Proj/_apis/serviceendpoint/endpoints?type=git" -Ver "6.0-preview.1").value | Select-Object name
# endpoint types: the project-level path `$Proj/_apis/serviceendpoint/types` returned 404 on this server. Try the collection-level path (not verified):
(Invoke-Tfs "_apis/serviceendpoint/types" -Ver "6.0-preview.1").value | Select-Object name
```
- Select only `id, name, type, isReady`. Do NOT print `authorization`, `data`, `url` credentials or the whole object.
- On this server the endpoint list returned 0 items (none exist, or none visible to this user).
- Creating, editing or deleting endpoints: do not do it via the agent. Tell the user to use the UI.
- Which pipelines use an endpoint: `.../serviceendpoint/<id>/executionhistory` is not available on all versions. Skip if it 404s.

## 4. Secure files
```powershell
(Invoke-Tfs "$Proj/_apis/distributedtask/securefiles" -Ver "6.0-preview.1").value | Select-Object id, name
```
- Names only. File contents are never downloaded.

## 5. Agent pools and agents (version `6.0`)
```powershell
(Invoke-Tfs "_apis/distributedtask/pools").value | Select-Object id, name, poolType, isHosted, size
(Invoke-Tfs "_apis/distributedtask/pools/<poolId>/agents?includeCapabilities=false&includeAssignedRequest=true").value |
  Select-Object id, name, status, enabled, version, @{n='busy';e={[bool]$_.assignedRequest}}
```
- `status`: `online` / `offline`. `enabled`: can take jobs.
- Waiting jobs: `_apis/distributedtask/pools/<poolId>/jobrequests` (read; items without `result` are queued or running).
- Capabilities (`includeCapabilities=true`) list installed software on the agent (node, dotnet, etc.). Use to explain "no agent has capability X". Output can be long; select only needed names.
- Project-level queues (which pools a project may use): `Invoke-Tfs "$Proj/_apis/distributedtask/queues" -Ver "6.0-preview.1"` (6.0 gives 400).
- This server has 1 agent pool with 1 agent.
- Enabling/disabling agents or deleting them: do not do it via the agent.

## 6. Deployment groups and environments
```powershell
(Invoke-Tfs "$Proj/_apis/distributedtask/deploymentgroups" -Ver "6.0-preview.1").value | Select-Object id, name, machineCount
(Invoke-Tfs "$Proj/_apis/distributedtask/environments" -Ver "6.0-preview.1").value | Select-Object id, name
```
- Deployment group targets: `.../deploymentgroups/<id>/targets` (machine names are infrastructure info; print only if needed).

## 7. Pitfalls
- All library endpoints need `-Ver "6.0-preview.1"`. A 400 with `6.0` usually means this.
- Empty result: check the project name, and the permission (a user may see no groups without Library read permission).
- Variable group ids in pipelines may be referenced by name or id. Use the listing to map them.
