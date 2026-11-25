# Recipes: ready-made multi-step workflows

Prerequisite: `Invoke-Tfs`, `$Base`, `$Proj` from SKILL.md. Each recipe says which reference file holds the details.
All recipes are READ ONLY unless marked (WRITE). Every WRITE step needs the user's explicit approval first.

## Contents
1. Connectivity and identity check
2. Daily summary (my items, failed builds, pending approvals)
3. Specification to work items (WRITE)
4. Commit with the right work item
5. Investigate a failed build
6. What version is deployed where
7. Pull request with linked work items (WRITE)
8. Release status overview
9. Bulk update work items (WRITE)
10. Export work items to CSV
11. Find what changed between two branches
12. Sprint status

## 1. Connectivity and identity check
```powershell
$ok = Invoke-Tfs "_apis/projects?`$top=1"
"Projects reachable: " + ($ok.count -ge 1)
$me = Invoke-Tfs "_apis/connectionData" -Ver "6.0-preview.1"
"Authenticated: " + [bool]$me.authenticatedUser
```
- Report only true/false. Do not print the user's name, id or the server details.

## 2. Daily summary
Goal: one short report with three parts.
1. My open work items (boards.md section 3):
   - WIQL: assigned to `@Me`, state not in the closed states. Fetch id, title, state, type for up to 30.
2. Failed builds in the last 24 hours (builds.md section 3):
   - `resultFilter=failed&statusFilter=completed&minTime=<now - 1 day, ISO>&$top=20`. Show definition, branch, finish time.
3. Pending approvals (releases.md section 5): list release, environment, type.
Output format: three short lists. Counts first. Omit empty sections ("none").
- Do not include personal names beyond what the user needs.

## 3. Specification to work items (WRITE)
Full method: boards.md section 13. Summary of the order of operations:
1. Read the spec. 2. Discover types/states/fields/area/iteration. 3. Present the proposed tree and wait for approval. 4. `validateOnly=true` for one item per type. 5. Create parents first, store ids in `$map`. 6. Create children with parent links. 7. Verify and print a table.
- Create ONE item, show it, ask "continue with the rest?" before the batch.
- On any error: stop, list what exists, ask. Never retry blindly (duplicates).

## 4. Commit with the right work item
1. Find candidates: WIQL assigned to `@Me`, active states (boards.md section 3).
2. Match by the current branch name or the user's wording. If no unique match, list the candidates and ask the user.
3. Commit locally: `git commit -m "<message> #<id>"`.
4. After push, verify the link: `Invoke-Tfs "_apis/wit/workitems/${id}?`$expand=relations"` (braces are required) and look for an `ArtifactLink` of the commit.
- If the commit is already pushed: link it afterwards (git-and-prs.md section 9B).

## 5. Investigate a failed build
1. Get the build (builds.md section 4): result, branch, commit sha, definition.
2. Timeline: failed records and their `issues` (builds.md section 5).
3. Log of the failing task: show only the tail lines around the error.
4. Changes in the build (`/changes`) to see who/what changed (print commit messages, not personal data).
5. Compare with the last succeeded build of the same definition and branch (builds.md section 8).
Report: failing step, error message, probable cause (labeled as hypothesis), suggested next step.

## 6. What version is deployed where
1. Release definitions: find the definition id and its environments (releases.md section 2).
2. For each environment: deployments with `deploymentStatus=succeeded&$top=1` (releases.md section 4).
3. Table: environment, release name, artifact version, completed time.
- Use this to answer "is the fix in production".

## 7. Pull request with linked work items (WRITE)
1. Check source and target branches exist (git-and-prs.md section 2) and that source is ahead (section 5).
2. Show the user: title, description, source, target, linked work item ids.
3. Create the PR with `workItemRefs` (git-and-prs.md section 8).
4. Verify with `$p/<prId>/workitems`. Report the PR id.
- Do not complete (merge) the PR unless the user asks separately.

## 8. Release status overview
1. For each release definition the user names: latest 3 releases with `$expand=environments` (releases.md section 3).
2. Table: release name, each environment status.
3. Pending approvals for those releases.
- Mention any environment in `rejected`, `partiallySucceeded` or long `inProgress`.

## 9. Bulk update work items (WRITE)
1. Build the id list with WIQL. Show count and the first 10 titles.
2. Show the exact change (field, old to new).
3. Dry run on ONE item with `validateOnly=true`. Show the result.
4. After approval, apply to the rest in a loop with a short pause (`Start-Sleep -Milliseconds 300`). Collect `id, ok/failed, error` per item.
5. Print the summary table. Never exceed the approved list.

## 10. Export work items to CSV
```powershell
$rows = (Invoke-Tfs "_apis/wit/workitemsbatch" -Method POST -Body @{ ids = @($ids); fields = @("System.Id","System.WorkItemType","System.Title","System.State") }).value |
  ForEach-Object { [pscustomobject]@{ Id=$_.fields.'System.Id'; Type=$_.fields.'System.WorkItemType'; Title=$_.fields.'System.Title'; State=$_.fields.'System.State' } }
$rows | Export-Csv -Path "C:\temp\items.csv" -NoTypeInformation -Encoding UTF8
```
- UTF8 keeps Hebrew readable in Excel. Batches are limited to 200 ids: split with a loop for more.
- Save only where the user said. Do not export sensitive fields unless asked.

## 11. What changed between two branches
```powershell
$d = Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/diffs/commits?baseVersion=<A>&targetVersion=<B>&baseVersionType=branch&targetVersionType=branch"
"ahead=$($d.aheadCount) behind=$($d.behindCount)"
$d.changes | Select-Object @{n='file';e={$_.item.path}}, changeType | Select-Object -First 50
```
- Then list the commits with `searchCriteria.itemVersion.version=<B>` and a `fromDate`.

## 12. Sprint status
1. Current iteration (boards.md section 11): `$timeframe=current`.
2. Items in it: `.../iterations/<id>/workitems`, then batch fetch fields.
3. Count by state (`Group-Object State`) and by assignee only if asked.
4. Report: total, done, in progress, not started, blocked (by tag or state if the process has one).
