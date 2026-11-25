# Boards: work items, queries, backlogs, sprints

Prerequisite: the helper `Invoke-Tfs` and `$Base`, `$Proj` from SKILL.md. API version `6.0` unless stated.

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
# types (large response, about 700 KB; the helper converts it. Always select only the names)
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
  - In a sprint: `... AND [System.IterationPath] UNDER '<PROJECT>\Sprint 12'`
  - In an area: `... AND [System.AreaPath] UNDER '<PROJECT>\TeamA'`
- Hierarchy query (tree): `SELECT [System.Id] FROM WorkItemLinks WHERE ([Source].[System.Id] = 1234) AND ([System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward') MODE (Recursive)`. The result is in `.workItemRelations` (source/target pairs), not `.workItems`.
- Limits: a query returning more than 20,000 items fails (400). Narrow it.
- Text in WIQL strings: escape a single quote by doubling it (`''`).

## 4. Reading work items
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
Content type MUST be `application/json-patch+json`. The type goes in the URL after a `$`.
```powershell
$ops = @(
  @{ op="add"; path="/fields/System.Title"; value="Task title" },
  @{ op="add"; path="/fields/System.Description"; value="<p>Description</p><ul><li>point</li></ul>" },
  @{ op="add"; path="/fields/System.AreaPath"; value="<PROJECT>" },
  @{ op="add"; path="/fields/System.IterationPath"; value="<PROJECT>" },
  @{ op="add"; path="/fields/Microsoft.VSTS.Common.Priority"; value=2 }
)
# dry run: validates, saves nothing
Invoke-Tfs "$Proj/_apis/wit/workitems/`$Task?validateOnly=true" -Method POST -Body $ops -ContentType "application/json-patch+json"
# real create (only after approval)
Invoke-Tfs "$Proj/_apis/wit/workitems/`$Task" -Method POST -Body $ops -ContentType "application/json-patch+json"
```
- `validateOnly=true` runs all rules and returns what would be created, with NO save. Always dry-run first.
- With a parent link in the same call (section 7): add the relation op to `$ops`.
- Assign: `System.AssignedTo` value = display name or unique name (e.g. `DOMAIN\user`). Copy the exact format from an existing work item's `AssignedTo.uniqueName`.
- Description and repro steps are HTML. Plain text with newlines collapses; use `<br>` or `<p>`.
- Tags: `"tag1; tag2"`.
- Creating work items "in the past" or with another creator (`bypassRules=true`) needs special permission. Do not use it.

## 6. Updating work items
```powershell
$ops = @(
  @{ op="test";    path="/rev"; value=7 },                                   # optional optimistic lock
  @{ op="add";     path="/fields/System.State"; value="Active" },
  @{ op="add";     path="/fields/System.AssignedTo"; value="Name" },
  @{ op="replace"; path="/fields/System.Title"; value="New title" },
  @{ op="remove";  path="/fields/Microsoft.VSTS.Common.Priority" }
)
Invoke-Tfs "_apis/wit/workitems/1234?validateOnly=true" -Method PATCH -Body $ops -ContentType "application/json-patch+json"
Invoke-Tfs "_apis/wit/workitems/1234" -Method PATCH -Body $ops -ContentType "application/json-patch+json"
```
- `add` works as set (adds or overwrites a field).
- `System.Tags` REPLACES the whole string. To append: read the current tags first, then write `"old; new"`.
- State changes must follow the workflow. If the state is rejected, read `transitions` or move through intermediate states.
- Bulk update: run the dry run on ONE item first, show the user the list of IDs and the change, wait for approval, then loop with a short pause. Report successes and failures per ID.

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
4. Dry run (`validateOnly=true`) the first item of each type.
5. Create top-down: parents first. Save each returned `id` in a table (`$map`).
6. Create children with a `Hierarchy-Reverse` link to the parent id from `$map`.
7. Verify: WIQL for the new items or `$expand=relations` on the top item. Print a summary table: ID, type, title, parent.
8. If something fails midway, stop, report which items were created, and ask before retrying. Never create duplicates.
Writing guidance: titles short and action-like; description states the goal and scope; acceptance criteria as a bulleted list in `Microsoft.VSTS.Common.AcceptanceCriteria` (User Story / PBI); one task = a unit of work of at most about one day.

## 14. Pitfalls
- 400 on create: a required field is missing, or the state/area/iteration value does not exist. Use `validateOnly=true` and read the error message.
- AssignedTo rejected: the identity string format is wrong. Copy the format from an existing item.
- `$Task` in double quotes without a backtick gets expanded to empty. Use `` `$Task ``.
- ConvertTo-Json depth: use `-Depth 20` (the helper does).
- A one-element `$ops` must stay an array: write `@( ... )`, and pass it via `ConvertTo-Json -InputObject`.
- `$var?` pitfall: any URL string like `"...$id?..."` must be written `"...${id}?..."`.
- WIQL results ordering is by the ORDER BY only. IDs from the batch call may come back in a different order; sort by `System.Id` or by your own list.
