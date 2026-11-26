# Boards: work items, queries, backlogs, sprints

Prerequisite: import the module (SKILL.md section 2). API version `6.0` unless stated.

## Contents
1. Concepts and process templates
2. Discovery: types, states, fields, area/iteration, teams
3. Querying with WIQL
4. Reading work items
5. Creating work items
6. Updating work items
7. Links (parent/child, related, commits)
8. Comments
9. Attachments
10. Deleting
11. Teams, backlogs, sprints, taskboard
12. Saved queries
13. Method: specification to work items
14. Pitfalls

## 1. Concepts and process templates
- A work item has an integer ID, a type (`System.WorkItemType`), a state (`System.State`), fields, and relations (links).
- The process template decides the available types and states:
  - Agile: Epic, Feature, User Story, Task, Bug, Issue
  - Scrum: Epic, Feature, Product Backlog Item, Task, Bug, Impediment
  - CMMI: Epic, Feature, Requirement, Task, Bug, Change Request, Risk, Issue
  - Basic: Epic, Issue, Task
  - The organization may use a customized template. ALWAYS discover (section 2); never assume.
- Common fields (reference names):
  - `System.Title` (required), `System.Description` (HTML), `System.State`, `System.Reason`
  - `System.AssignedTo`, `System.AreaPath`, `System.IterationPath`, `System.Tags` (semicolon-separated string)
  - `Microsoft.VSTS.Common.Priority` (1-4), `Microsoft.VSTS.Common.Severity` (bugs)
  - `Microsoft.VSTS.Scheduling.StoryPoints` (Agile), `Microsoft.VSTS.Scheduling.Effort` (Scrum), `OriginalEstimate`, `RemainingWork`, `CompletedWork`
  - `Microsoft.VSTS.Common.AcceptanceCriteria`, `Microsoft.VSTS.TCM.ReproSteps` (Bug), `Microsoft.VSTS.TCM.SystemInfo`
  - Read-only: `System.Id`, `System.Rev`, `System.CreatedDate`, `System.CreatedBy`, `System.ChangedDate`, `System.ChangedBy`

## 2. Discovery
```powershell
# types (large response, about 700 KB; `Invoke-Tfs` converts it. Always select only the names)
(Invoke-Tfs "$Proj/_apis/wit/workitemtypes").value | Select-Object name
# if that returns nothing, read the categories instead: (Invoke-Tfs "$Proj/_apis/wit/workitemtypecategories").value | Select-Object name

# one type: states and fields
$t = Invoke-Tfs "$Proj/_apis/wit/workitemtypes/Task"
$t.states | Select-Object name, category          # valid states
$t.fields | Where-Object alwaysRequired | Select-Object referenceName, name   # required fields
$t.fields | Select-Object referenceName, name | Select-Object -First 50      # all fields

# area and iteration trees
Invoke-Tfs "$Proj/_apis/wit/classificationnodes?`$depth=4"

# all fields in the collection
(Invoke-Tfs "_apis/wit/fields").value | Select-Object referenceName, name, type | Select-Object -First 60

# teams
(Invoke-Tfs "_apis/projects/$Proj/teams").value | Select-Object name, id
```
- A "State" the user names (e.g. "Done") must exist in `$t.states`. Use the exact spelling.
- Field `type` tells the value format: string, integer, double, dateTime, html, identity, treePath.

## 3. Querying with WIQL
My open items (assigned to me, not closed): `Get-TfsMyItems [-Top N]` returns Id, Type, State, Title. Everything below is for any OTHER query.

Two steps: (1) WIQL returns IDs only, (2) fetch the details in batches.
```powershell
$q = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.AssignedTo] = @Me AND [System.State] NOT IN ('Closed','Done','Removed') ORDER BY [System.ChangedDate] DESC" }
$ids = (Invoke-Tfs "$Proj/_apis/wit/wiql?`$top=100" -Method POST -Body $q).workItems.id
```
Then fetch details (max 200 IDs per call):
```powershell
$body = @{ ids = @($ids | Select-Object -First 100); fields = @("System.Id","System.Title","System.State","System.WorkItemType","System.AssignedTo") }
(Invoke-Tfs "_apis/wit/workitemsbatch" -Method POST -Body $body).value | ForEach-Object { $_.fields } | Select-Object 'System.Id','System.Title','System.State'
```
Alternative GET form: `_apis/wit/workitems?ids=1,2,3&fields=System.Id,System.Title`.

WIQL syntax:
- Operators: `=`, `<>`, `>`, `<`, `>=`, `<=`, `IN`, `NOT IN`, `CONTAINS`, `NOT CONTAINS`, `UNDER` (area/iteration trees), `EVER` (`[System.AssignedTo] EVER @Me`), `IS EMPTY`/`IS NOT EMPTY`.
- Macros: `@Me`, `@Project`, `@Today`, `@Today - 7`, `@StartOfWeek`, `@CurrentIteration` (needs team context: URL `$Proj/<team>/_apis/wit/wiql`).
- Dates: `'2026-11-01'` or `@Today - 3`.
- Always filter by `[System.TeamProject] = @project` when the URL is project-level.
- The SELECT field list is ignored over the API for flat queries: you only get IDs. Fetch fields with the batch call.
- Examples:
  - Active bugs: `... WHERE [System.WorkItemType] = 'Bug' AND [System.State] <> 'Closed'`
  - Changed in the last week: `... AND [System.ChangedDate] >= @Today - 7`
  - By title: `... AND [System.Title] CONTAINS 'login'`
  - By tag: `... AND [System.Tags] CONTAINS 'urgent'`
  - In a sprint: `... AND [System.IterationPath] UNDER '$Proj\Sprint 12'` (inside a double-quoted PowerShell string `$Proj` is expanded)
  - In an area: `... AND [System.AreaPath] UNDER '$Proj\TeamA'`
- Hierarchy query (tree): use `Get-TfsTree -Id N [-Depth N] [-Top N] [-Summary]` (Id, ParentId, Level, Type, State, Title; `-Summary` = counts by state). Raw form: `SELECT [System.Id] FROM WorkItemLinks WHERE ([Source].[System.Id] = 1234) AND ([System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward') MODE (Recursive)`.
  - A link query MUST select `FROM WorkItemLinks` and end with `MODE (Recursive)` (or another MODE); a `FROM WorkItems` query cannot filter by links.
  - The id is an integer literal (`= 1234`), never a string such as `'$Proj\1234'`.
  - The result is in `.workItemRelations` (source/target pairs; the first entry has no source and is the root), not `.workItems`. Fetch the fields of the target ids with the batch call.
- Limits: a query returning more than 20,000 items fails (400). Narrow it.
- Text in WIQL strings: escape a single quote by doubling it (`''`).

## 4. Reading work items
One item: `Get-TfsItem -Id N` (Id, Type, State, Title, AreaPath, IterationPath, Tags, Changed, Rev; `-Fields 'System.AssignedTo'` adds fields). With links: `Get-TfsItem -Id N -Links` adds `Relations` (Rel, TargetId, Target, Name; parent = `System.LinkTypes.Hierarchy-Reverse`). Raw REST for everything else:
```powershell
Invoke-Tfs "_apis/wit/workitems/1234"                          # fields only
Invoke-Tfs "_apis/wit/workitems/1234?`$expand=relations"       # plus links
Invoke-Tfs "_apis/wit/workitems/1234?`$expand=all"
(Invoke-Tfs "_apis/wit/workItems/1234/revisions").value | Select-Object rev, @{n='changed';e={$_.fields.'System.ChangedDate'}}
(Invoke-Tfs "_apis/wit/workItems/1234/updates").value        # field-level history
```
- Cannot combine `fields=` with `$expand=` in one call.
- With a variable id write `"_apis/wit/workitems/${id}?`$expand=relations"`. Without the braces PowerShell reads `$id?` as one variable and the call returns 404.
- Field access with dots in the name: `$wi.fields.'System.Title'`.
- `System.AssignedTo` is an object (displayName, uniqueName). Use `.displayName`.
- Relations: `$wi.relations | Select-Object rel, url` (the work item ID is the last segment of `url`).

## 5. Creating work items
Use `New-TfsItem`. It is a dry run by default (always sends `validateOnly=true`, saves nothing); the real create needs `-Commit`.
```powershell
# dry run: shows the planned fields; nothing is saved
New-TfsItem -Type Task -Title "Task title" -ParentId 1234 -Fields @{ 'Microsoft.VSTS.Common.Priority' = 2; 'System.Description' = '<p>Description</p>' }
# real create (only after approval): validates again, creates, re-reads and returns the stored values
New-TfsItem -Type Task -Title "Task title" -ParentId 1234 -Fields @{ 'Microsoft.VSTS.Common.Priority' = 2 } -Commit
```
- The type is any type that exists (section 2); a type with a space (`User Story`) is fine.
- `-ParentId` adds the `Hierarchy-Reverse` link in the same call (a work item can have only one parent).
- Area and iteration: pass `'System.AreaPath' = $Proj` / `'System.IterationPath' = "$Proj\Sprint 12"` in `-Fields` (omitted means the project default).
- Assign: `System.AssignedTo` value = display name or unique name (e.g. `DOMAIN\user`). Copy the exact format from an existing work item's `AssignedTo.uniqueName`.
- Description and repro steps are HTML. Plain text with newlines collapses; use `<br>` or `<p>`.
- Tags: `"tag1; tag2"`.
- Creating work items "in the past" or with another creator (`bypassRules=true`) needs special permission. Do not use it.
- Raw form (only if the function does not fit): POST to `$Proj/_apis/wit/workitems/` plus the type after a `$` (in double quotes write a backtick before the `$`), with `-ContentType "application/json-patch+json"`, and `?validateOnly=true` first.

## 6. Updating work items
Use `Set-TfsItem` (ONE item per call). Dry run by default: it reads the item, validates with `validateOnly=true` and shows old and new values; `-Commit` writes, re-reads and reports what is stored (`Match` per field).
```powershell
Set-TfsItem -Id 1234 -Fields @{ 'System.State' = 'Active'; 'System.Title' = 'New title' }              # dry run
Set-TfsItem -Id 1234 -Fields @{ 'System.State' = 'Active' } -ExpectedRev 7 -Commit                      # optimistic lock, real write
Set-TfsItem -Id 1234 -Fields @{ 'Microsoft.VSTS.Common.Priority' = $null }                              # $null removes the field
Set-TfsItem -Id 1234 -AddTag 'reviewed', 'urgent' -Commit                                               # merges into existing tags
```
- `System.Tags` inside `-Fields` REPLACES the whole string (the output note says so). Use `-AddTag` to add tags.
- State changes must follow the workflow. If the state is rejected, read `transitions` or move through intermediate states.
- Bulk update: run the dry run on ONE item first, show the user the list of IDs and the change, wait for approval, then loop with a short pause. Report successes and failures per ID.
- Raw form (only if the function does not fit): PATCH `_apis/wit/workitems/1234` with ops `add`/`replace`/`remove`/`test` and `-ContentType "application/json-patch+json"`.

## 7. Links
Add:
```powershell
@{ op="add"; path="/relations/-"; value=@{ rel="System.LinkTypes.Hierarchy-Reverse"; url="$Base/_apis/wit/workItems/<parentId>"; attributes=@{ comment="optional" } } }
```
Remove (needs the relation's index from `$expand=relations`):
```powershell
@{ op="remove"; path="/relations/<index>" }
```
Link types:
| Meaning | rel |
|---|---|
| This item's parent is X | `System.LinkTypes.Hierarchy-Reverse` |
| This item's child is X | `System.LinkTypes.Hierarchy-Forward` |
| Related | `System.LinkTypes.Related` |
| Predecessor / Successor | `System.LinkTypes.Dependency-Reverse` / `System.LinkTypes.Dependency-Forward` |
| Duplicate of / Duplicates | `System.LinkTypes.Duplicate-Forward` / `System.LinkTypes.Duplicate-Reverse` |
| Hyperlink | `Hyperlink` (url = any URL) |
| Commit / PR / build / branch | `ArtifactLink` (see git-and-prs.md section 9) |
| Attachment | `AttachedFile` |
- A work item can have only one parent. Adding a second `Hierarchy-Reverse` fails.
- The parent-child hierarchy must respect the backlog levels (e.g. a Task under a User Story, not directly under an Epic, unless the template allows it).

## 8. Comments
```powershell
Invoke-Tfs "$Proj/_apis/wit/workItems/1234/comments" -Method POST -Body @{ text = "Comment text (HTML allowed)" } -Ver "6.0-preview.3"
(Invoke-Tfs "$Proj/_apis/wit/workItems/1234/comments" -Ver "6.0-preview.3").comments | Select-Object id, text
```
- If the comments API returns 404/400, fall back to history discussion: add `@{ op="add"; path="/fields/System.History"; value="Comment" }` in a normal PATCH.
- Mention a user: `<a href="#" data-vss-mention="version:2.0,<identity guid>">@Name</a>`. Avoid unless the user asks.

## 9. Attachments
```powershell
# step 1: upload the bytes, get a url
$bytes = [IO.File]::ReadAllBytes("C:\path\file.pdf")
$u = Invoke-RestMethod -Uri "$Base/_apis/wit/attachments?fileName=file.pdf&api-version=6.0" -Method POST -Body $bytes -ContentType "application/octet-stream" -UseDefaultCredentials
# step 2: link it to the work item
$ops = @( @{ op="add"; path="/relations/-"; value=@{ rel="AttachedFile"; url=$u.url; attributes=@{ comment="file" } } } )
Invoke-Tfs "_apis/wit/workitems/1234" -Method PATCH -Body $ops -ContentType "application/json-patch+json"
```
- Maximum attachment size is limited by the server (often 4 MB by default). Do not upload anything the user did not ask for.

## 10. Deleting
- `Invoke-Tfs "_apis/wit/workitems/1234" -Method DELETE` moves the item to the recycle bin (recoverable).
- `?destroy=true` deletes permanently. NEVER use it.
- Deleting always requires explicit confirmation naming the ID and the title.

## 11. Teams, backlogs, sprints, taskboard
Team-level paths use the team name or id: `$Proj/<team>/_apis/work/...`
```powershell
$team = "<team name>"
# team settings (default iteration, backlog levels)
Invoke-Tfs "$Proj/$team/_apis/work/teamsettings"
# sprints
(Invoke-Tfs "$Proj/$team/_apis/work/teamsettings/iterations").value | Select-Object name, id, path
(Invoke-Tfs "$Proj/$team/_apis/work/teamsettings/iterations?`$timeframe=current").value
# items in a sprint
Invoke-Tfs "$Proj/$team/_apis/work/teamsettings/iterations/<iterationId>/workitems" -Ver "6.0-preview.1"   # 6.0 gives 400
# sprint capacity
Invoke-Tfs "$Proj/$team/_apis/work/teamsettings/iterations/<iterationId>/capacities" -Ver "6.0-preview.2"
# backlogs and boards
(Invoke-Tfs "$Proj/$team/_apis/work/backlogs" -Ver "6.0-preview.1").value | Select-Object id, name   # 6.0 gives 400
(Invoke-Tfs "$Proj/$team/_apis/work/boards").value | Select-Object id, name
```
- Moving an item to a sprint = update `System.IterationPath` to that sprint's path.
- Some teams have no iterations configured: their `teamsettings/iterations` is empty and `iterations?$timeframe=current`, `@CurrentIteration` WIQL and boards return 404 or 500. That is a team setup issue, not a permission or version problem. Try another team.
- This server has 100+ teams. List with `$top` and pick by name; do not loop over all.
- Board columns are stored in `System.BoardColumn` (read-only via normal PATCH for most templates; change `System.State` instead).
- `@CurrentIteration` in WIQL needs the team in the URL: `$Proj/$team/_apis/wit/wiql`.

## 12. Saved queries
```powershell
Invoke-Tfs "$Proj/_apis/wit/queries?`$depth=2"                       # folders and queries
Invoke-Tfs "$Proj/_apis/wit/queries/My Queries/Open Bugs?`$expand=wiql"   # one query by path
Invoke-Tfs "$Proj/_apis/wit/wiql/<queryId>"                           # run a saved query
```

## 13. Method: specification to work items
1. Read the whole specification. Identify goals, features, requirements, acceptance criteria.
2. Discover types, required fields, area and iteration (section 2). Use only types that exist.
3. Propose the hierarchy as a numbered tree: type, title, short description, estimate, priority. Show it to the user. Wait for approval and corrections.
4. Dry run `New-TfsItem` (no `-Commit`) for the first item of each type.
5. Create top-down with `New-TfsItem ... -Commit`: parents first. Save each returned `Id` in a table (`$map`).
6. Create children with `New-TfsItem ... -ParentId <parent id from $map> -Commit`.
7. Verify: WIQL for the new items or `$expand=relations` on the top item. Print a summary table: ID, type, title, parent.
8. If something fails midway, stop, report which items were created, and ask before retrying. Never create duplicates.
Writing guidance: titles short and action-like; description states the goal and scope; acceptance criteria as a bulleted list in `Microsoft.VSTS.Common.AcceptanceCriteria` (User Story / PBI); one task = a unit of work of at most about one day.

## 14. Pitfalls
- 400 on create: a required field is missing, or the state/area/iteration value does not exist. Use `validateOnly=true` and read the error message.
- AssignedTo rejected: the identity string format is wrong. Copy the format from an existing item.
- `$Task` in double quotes without a backtick gets expanded to empty. Use `` `$Task ``.
- ConvertTo-Json depth: use `-Depth 20` (`Invoke-Tfs` does).
- A one-element `$ops` must stay an array: write `@( ... )`, and pass it via `ConvertTo-Json -InputObject`.
- `$var?` pitfall: any URL string like `"...$id?..."` must be written `"...${id}?..."`.
- WIQL results ordering is by the ORDER BY only. IDs from the batch call may come back in a different order; sort by `System.Id` or by your own list.
