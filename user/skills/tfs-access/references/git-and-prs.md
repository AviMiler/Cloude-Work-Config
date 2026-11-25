# Repos (Git), Pull Requests, commit linking

Prerequisite: `Invoke-Tfs`, `$Base`, `$Proj` from SKILL.md. API version `6.0`.
`<repo>` = repository name or id. Branch names in URLs are WITHOUT `refs/heads/`; in ref fields they are WITH it.

## Contents
1. Repositories
2. Branches and tags (refs)
3. Commits
4. Files and folders
5. Diffs and changes
6. Pushes and local git
7. Pull requests: read
8. Pull requests: create, update, review, complete
9. Linking commits, branches and PRs to work items
10. Policies (read-only)
11. Pitfalls

## 1. Repositories
```powershell
$repos = (Invoke-Tfs "$Proj/_apis/git/repositories").value
$repos | Select-Object name, id, defaultBranch, size
Invoke-Tfs "$Proj/_apis/git/repositories/<repo>"
Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/stats/branches" | Select-Object -First 20 name, aheadCount, behindCount
```
- Creating or deleting repositories is a write that needs explicit confirmation. Do not do it unprompted.

## 2. Branches and tags
```powershell
(Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/refs?filter=heads/").value | Select-Object name, objectId
(Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/refs?filter=heads/feature").value      # prefix filter
(Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/refs?filter=tags/").value | Select-Object name
```
Create a branch from a commit (WRITE, confirm):
```powershell
$new = @( @{ name="refs/heads/feature/x"; oldObjectId="0000000000000000000000000000000000000000"; newObjectId="<sourceCommitSha>" } )
Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/refs" -Method POST -Body $new
```
- Get `<sourceCommitSha>` from the `objectId` of the source branch ref.
- The response has `success` per ref. Check it.
- Deleting a branch: same POST with `oldObjectId = <current sha>` and `newObjectId = "0000000000000000000000000000000000000000"`. Confirm first. Never delete protected branches (develop, main, master, production).
- Prefer the local `git` command for normal branch work (`git checkout -b`, `git push`).

## 3. Commits
```powershell
$c = (Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/commits?searchCriteria.itemVersion.version=<branch>&searchCriteria.`$top=20").value
$c | Select-Object @{n='sha';e={$_.commitId.Substring(0,8)}}, comment, @{n='date';e={$_.author.date}}
```
Filters (add with `&`): `searchCriteria.author=<name>`, `searchCriteria.fromDate=2026-11-01`, `searchCriteria.toDate=...`, `searchCriteria.itemPath=/src/file.cs`, `searchCriteria.$skip=20` (paging).
```powershell
Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/commits/<sha>"                 # one commit
(Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/commits/<sha>/changes").changes # files changed
```
- Work items linked to a commit: the endpoint `.../commits/<sha>/workitems` returned 404 on this server. Do not use it. Instead read the work item with relations, or the PR work items (`.../pullrequests/<prId>/workitems`, verified).
- Output hygiene: author names and emails are personal data. Print them only if the task needs them.

## 4. Files and folders
```powershell
# list a folder
(Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/items?scopePath=/src&recursionLevel=OneLevel&versionDescriptor.version=<branch>").value | Select-Object path, isFolder
# read a file as text
Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/items?path=/src/file.cs&versionDescriptor.version=<branch>&includeContent=true&`$format=text"
```
- `recursionLevel`: `None`, `OneLevel`, `Full` (Full on large repos is slow; avoid).
- Version types: add `&versionDescriptor.versionType=branch|tag|commit`.
- Binary files: use `-OutFile` with `Invoke-WebRequest` (see powershell-notes.md).
- Changing files through the API (a "push" with changes) is possible but error-prone. Use local `git` for that.

## 5. Diffs and changes
```powershell
Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/diffs/commits?baseVersion=<branchA>&targetVersion=<branchB>&baseVersionType=branch&targetVersionType=branch"
```
- Result: `aheadCount`, `behindCount`, `changes` (file list with `changeType`: add, edit, delete, rename).
- For the content diff of a file, read both versions (section 4) and compare locally.

## 6. Pushes and local git
```powershell
(Invoke-Tfs "$Proj/_apis/git/repositories/<repo>/pushes?`$top=10").value | Select-Object pushId, date
```
- Normal workflow uses local `git`: `git status`, `git add`, `git commit -m "message #1234"`, `git push`.
- Never use `--force` or `git reset --hard` unless the user explicitly asks.
- Remote URL format: `https://<TFS_HOST>/tfs/<COLLECTION>/<PROJECT>/_git/<repo>`.

## 7. Pull requests: read
```powershell
$p = "$Proj/_apis/git/repositories/<repo>/pullrequests"
(Invoke-Tfs "${p}?searchCriteria.status=active").value | Select-Object pullRequestId, title, sourceRefName, targetRefName
Invoke-Tfs "$p/<prId>"                                # details, mergeStatus, reviewers
(Invoke-Tfs "$p/<prId>/commits").value | Select-Object commitId, comment
(Invoke-Tfs "$p/<prId>/workitems").value | Select-Object id, url
(Invoke-Tfs "$p/<prId>/threads").value | Select-Object id, status, @{n='first';e={$_.comments[0].content}}
(Invoke-Tfs "$p/<prId>/iterations").value | Select-Object id, description
```
Filters: `searchCriteria.status` = `active|completed|abandoned|all`, `searchCriteria.targetRefName=refs/heads/develop`, `searchCriteria.sourceRefName=...`, `searchCriteria.creatorId=<guid>`, `searchCriteria.reviewerId=<guid>`, `$top`, `$skip`.
- `mergeStatus`: `succeeded`, `conflicts`, `queued`, `rejectedByPolicy`, `failure`.
- Cross-repo list: `$Proj/_apis/git/pullrequests?searchCriteria.status=active` (all repos in the project).

## 8. Pull requests: create, update, review, complete (WRITES)
Create:
```powershell
$pr = @{
  sourceRefName = "refs/heads/<source>"
  targetRefName = "refs/heads/<target>"
  title = "Title"
  description = "Description (markdown)"
  workItemRefs = @( @{ id = "1234" } )                       # optional: link work items
  reviewers = @( @{ id = "<identityGuid>" } )                # optional
  isDraft = $false
}
Invoke-Tfs "$p" -Method POST -Body $pr
```
- Show the user the title, description, source, target and linked work items before creating.
- Verify the branches exist and that source has commits ahead of target (section 5) so the PR is not empty.
- Reviewer GUIDs come from the identity APIs or from an existing PR's `reviewers[].id`. Do not guess.

Update title/description: `Invoke-Tfs "$p/<prId>" -Method PATCH -Body @{ title="New"; description="New" }`.

Comment (new thread):
```powershell
Invoke-Tfs "$p/<prId>/threads" -Method POST -Body @{ comments=@(@{ parentCommentId=0; content="Text"; commentType=1 }); status=1 }
```
Thread status: 1 active, 2 fixed, 3 wontFix, 4 closed, 5 byDesign, 6 pending.
Reply to a thread: POST `.../threads/<threadId>/comments` with `@{ content="Text"; parentCommentId=1 }`.

Vote (as the signed-in user, needs that user's identity id):
`Invoke-Tfs "$p/<prId>/reviewers/<myIdentityId>" -Method PUT -Body @{ vote = 10 }`
Votes: 10 approved, 5 approved with suggestions, 0 no vote, -5 waiting for author, -10 rejected.
- Voting on behalf of the user is a decision. Do it only on an explicit request ("approve PR 55").

Complete (merge) (WRITE, double confirmation):
```powershell
$pr = Invoke-Tfs "$p/<prId>"
$body = @{
  status = "completed"
  lastMergeSourceCommit = @{ commitId = $pr.lastMergeSourceCommit.commitId }
  completionOptions = @{ deleteSourceBranch = $false; mergeStrategy = "squash"; bypassPolicy = $false }
}
Invoke-Tfs "$p/<prId>" -Method PATCH -Body $body
```
- `mergeStrategy`: `noFastForward`, `squash`, `rebase`, `rebaseMerge`.
- Never set `bypassPolicy = $true`.
- Abandon: PATCH `@{ status = "abandoned" }` (confirm). Re-activate: `@{ status = "active" }`.
- Completion may be asynchronous. Re-read the PR and check `status` and `mergeStatus`.

## 9. Linking commits, branches and PRs to work items
A. At commit time (preferred, no API write needed):
- Put `#<workItemId>` in the commit message: `git commit -m "Fix validation #1234"`.
- After the push, TFS links the commit to work item 1234 automatically.
- Steps for the agent: (1) find the user's open items (boards.md section 3, assigned to `@Me`, active states); (2) if more than one candidate, show them and ask; (3) add `#id` to the message. Never guess the id.
- Multiple items: `#1234 #1235`.

B. Link an already-pushed commit:
```powershell
$projId = (Invoke-Tfs "_apis/projects/$Proj").id
$repoId = (Invoke-Tfs "$Proj/_apis/git/repositories/<repo>").id
$art = "vstfs:///Git/Commit/$projId%2F$repoId%2F<commitSha>"
$ops = @( @{ op="add"; path="/relations/-"; value=@{ rel="ArtifactLink"; url=$art; attributes=@{ name="Fixed in Commit" } } } )
Invoke-Tfs "_apis/wit/workitems/<id>" -Method PATCH -Body $ops -ContentType "application/json-patch+json"
```
C. Link a PR: pass `workItemRefs` when creating the PR (section 8), or add an ArtifactLink with `vstfs:///Git/PullRequestId/<projectId>%2F<repoId>%2F<prId>` and name `Pull Request`.
D. Link a branch: `vstfs:///Git/Ref/<projectId>%2F<repoId>%2FGB<branchName>` (name `Branch`). Slashes inside the branch name must be URL-encoded (`%2F`).
- Verify any link by reading the work item with `$expand=relations`.

## 10. Policies (read-only)
```powershell
(Invoke-Tfs "$Proj/_apis/policy/configurations").value | Select-Object id, isEnabled, @{n='type';e={$_.type.displayName}}
```
- Policies (minimum reviewers, required builds, linked work items) explain why a PR cannot complete. Never change them.

## 11. Pitfalls
- `$p?x=1` is read by PowerShell as the variable `$p?`. Write `${p}?x=1`.
- PR statuses (`.../pullrequests/<id>/statuses`) returned 400 on this server. Skip it.
- This server has about <N> repositories. Never list them all into the output: use `Where-Object name -like '*text*'` and `Select-Object -First 20`.
- 404 on a repo: use the exact name from the repository list (case may matter in the path).
- Branch name with `/` in query strings: it is fine inside `version=` values, but URL-encode other special characters with `[uri]::EscapeDataString()`.
- `refs?filter=heads/x` is a prefix filter, so it may return more than one ref.
- PR create returns 409 if an active PR with the same source and target already exists.
- Empty PR (no diff): the API accepts it but the PR cannot be completed. Check section 5 first.
- Do not print author names or emails unless needed.
