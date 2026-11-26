# Index: complete TFS guide

Start with `../SKILL.md` (environment, the Tfs module and its ready-made functions, API versions, safety rules). This file is the master index.

## A. Which file for which task
| I want to... | File | Section |
|---|---|---|
| Check the connection / config (first run) | `Test-TfsSetup` (recipes.md 1) | SKILL.md 2 |
| Learn what this server supports | discovery.md | 2, 3 |
| Query my open tasks | `Get-TfsMyItems` | boards.md 3 |
| Read one work item with links | `Get-TfsItem -Id N -Links` | boards.md 4 |
| See all children below an item / counts by state | `Get-TfsTree -Id N [-Summary]` | boards.md 3 |
| Create a task / story / bug | `New-TfsItem` (dry run, `-Commit`) | boards.md 5 |
| Turn a specification into work items | boards.md | 13 (and recipes.md 3) |
| Change state, assignee, title, tags | `Set-TfsItem` (dry run, `-Commit`) | boards.md 6 |
| Link items (parent, related) | boards.md | 7 |
| Add a comment | boards.md | 8 |
| Attach a file | boards.md | 9 |
| Sprints, backlog, taskboard | boards.md | 11 |
| Saved queries | boards.md | 12 |
| List repos / branches | `Find-TfsRepo` / git-and-prs.md | 1 / 2 |
| See commits / diffs, files | `Get-TfsCommits` / git-and-prs.md | 3 / 4, 5 |
| Create a branch | git-and-prs.md | 2 |
| List / read pull requests | `Get-TfsPR` / git-and-prs.md | 7 |
| Create / review / complete a PR | git-and-prs.md | 8 |
| Link a commit to a work item | git-and-prs.md | 9 (and recipes.md 4) |
| List build definitions / builds | builds.md | 2, 3 |
| Why did a build fail | `Get-TfsBuildFailure -Id N` | builds.md 5 (and recipes.md 5) |
| Queue / cancel a build | builds.md | 6, 7 |
| List releases and their stages | releases.md | 3 |
| What is deployed where | `Get-TfsDeployed -Definition X` | releases.md 4 (and recipes.md 6) |
| Pending approvals / approve | releases.md | 5 |
| Create a release | releases.md | 6 |
| Deploy an environment | releases.md | 7 |
| Variable groups, task groups, endpoints | library-pools.md | 1, 2, 3 |
| Agent pools and agents | library-pools.md | 5 |
| Test plans, runs, results | tests-feeds-wiki.md | 1, 2 |
| Feeds and packages | tests-feeds-wiki.md | 3, 4 |
| Wiki | tests-feeds-wiki.md | 5 |
| Daily summary | `Get-TfsDailySummary` | recipes.md 2 |
| Bulk update | recipes.md | 9 |
| Export to CSV | recipes.md | 10 |
| An error happened | troubleshooting.md | 1, 2 |
| Which endpoint and version works on THIS server | verified.md | all |
| PowerShell quoting, JSON, paging | powershell-notes.md | all |

## B. Table of contents by file
- `../SKILL.md`: 1 Environment, 2 The Tfs module (functions and raw-snippet rules), 3 API versions, 4 URL patterns, 5 Safety protocol, 6 Index, 7 Working style
- `boards.md`: 1 Concepts, 2 Discovery, 3 WIQL, 4 Reading, 5 Creating, 6 Updating, 7 Links, 8 Comments, 9 Attachments, 10 Deleting, 11 Teams/sprints, 12 Saved queries, 13 Spec to items, 14 Pitfalls
- `git-and-prs.md`: 1 Repositories, 2 Branches/tags, 3 Commits, 4 Files, 5 Diffs, 6 Pushes/local git, 7 PRs read, 8 PRs write, 9 Linking to work items, 10 Policies, 11 Pitfalls
- `builds.md`: 1 Concepts, 2 Definitions, 3 Listing, 4 One build, 5 Failure investigation, 6 Queue, 7 Cancel/retain, 8 Latest build, 9 Pitfalls
- `releases.md`: 1 Concepts, 2 Definitions, 3 Releases, 4 Deployments, 5 Approvals, 6 Create release, 7 Deploy, 8 Abandon/cancel, 9 Logs, 10 Pitfalls
- `library-pools.md`: 1 Variable groups, 2 Task groups, 3 Service endpoints, 4 Secure files, 5 Agent pools, 6 Deployment groups/environments, 7 Pitfalls
- `tests-feeds-wiki.md`: 1 Test plans, 2 Runs/results, 3 Feeds, 4 npm/NuGet usage, 5 Wiki, 6 Pitfalls
- `recipes.md`: 1-12 workflows
- `discovery.md`: 1 Connectivity, 2 Server version, 3 Per-area versions, 4 Permission probe, 5 Process template, 6 Known facts
- `powershell-notes.md`: 1 Versions, 2 Escaping, 3 JSON, 4 Error bodies, 5 Paging, 6 Headers/binary, 7 Dates/encoding, 8 Output/performance
- `verified.md`: endpoints that worked (with versions) and endpoints that failed on this server
- `troubleshooting.md`: 1 By status, 2 By symptom, 3 Per area, 4 Reporting, 5 What not to do

## C. Endpoint cheat sheet
Base: `$Base`. `P` = `$Proj` (both set by importing the module from `scripts/tfs-config.psd1`). Versions per SKILL.md section 3.
| Area | Method | Path |
|---|---|---|
| Projects | GET | `_apis/projects` |
| Teams | GET | `_apis/projects/P/teams` |
| Identity | GET | `_apis/connectionData` (preview) |
| WIQL | POST | `P/_apis/wit/wiql` |
| Work items batch | POST | `_apis/wit/workitemsbatch` |
| Work item | GET / PATCH / DELETE | `_apis/wit/workitems/{id}` |
| Create work item | POST | `P/_apis/wit/workitems/$Type` |
| Work item types | GET | `P/_apis/wit/workitemtypes[/{type}]` |
| Area/iteration tree | GET | `P/_apis/wit/classificationnodes` |
| Comments | GET / POST | `P/_apis/wit/workItems/{id}/comments` (preview.3) |
| Attachments | POST | `_apis/wit/attachments?fileName=` |
| Saved queries | GET | `P/_apis/wit/queries` |
| Team iterations | GET | `P/{team}/_apis/work/teamsettings/iterations` |
| Repos | GET | `P/_apis/git/repositories` |
| Refs (branches/tags) | GET / POST | `P/_apis/git/repositories/{repo}/refs` |
| Commits | GET | `P/_apis/git/repositories/{repo}/commits` |
| Items (files) | GET | `P/_apis/git/repositories/{repo}/items` |
| Diffs | GET | `P/_apis/git/repositories/{repo}/diffs/commits` |
| Pull requests | GET / POST | `P/_apis/git/repositories/{repo}/pullrequests` |
| PR threads | GET / POST | `.../pullrequests/{id}/threads` |
| PR reviewers/vote | PUT | `.../pullrequests/{id}/reviewers/{identityId}` |
| Policies | GET | `P/_apis/policy/configurations` |
| Build definitions | GET | `P/_apis/build/definitions` |
| Builds | GET / POST | `P/_apis/build/builds` |
| Build timeline | GET | `P/_apis/build/builds/{id}/timeline` |
| Build logs | GET | `P/_apis/build/builds/{id}/logs[/{logId}]` |
| Release definitions | GET | `P/_apis/release/definitions` |
| Releases | GET / POST | `P/_apis/release/releases` |
| Release environment | PATCH | `P/_apis/release/releases/{id}/environments/{envId}` (preview.6) |
| Deployments | GET | `P/_apis/release/deployments` |
| Release approvals | GET / PATCH | `P/_apis/release/approvals[/{id}]` |
| Variable groups | GET | `P/_apis/distributedtask/variablegroups` (preview.1) |
| Task groups | GET | `P/_apis/distributedtask/taskgroups` (preview.1) |
| Service endpoints | GET | `P/_apis/serviceendpoint/endpoints` (preview.1) |
| Agent pools | GET | `_apis/distributedtask/pools` |
| Agents | GET | `_apis/distributedtask/pools/{id}/agents` |
| Test plans | GET | `P/_apis/test/plans` (5.0) |
| Test runs | GET | `P/_apis/test/runs` (5.0) |
| Feeds | GET | `_apis/packaging/feeds` (preview.1) |
| Wiki | GET | `P/_apis/wiki/wikis` |

## D. Glossary
- Collection: the top-level container on the server (`$Base` points at it).
- Project: the work container (`$Proj`). Team: a group inside a project with its own backlog and sprints.
- Work item: a task/story/bug/etc. Relation: a link between items or to commits/PRs.
- WIQL: Work Item Query Language (SQL-like).
- Build definition / build: pipeline / one run of it.
- Release definition / release / environment: deployment pipeline / one instance / a stage (e.g. test, production).
- Artifact: the output of a build that a release deploys.
- Service endpoint: a stored connection to an external system (holds credentials).
- Variable group: shared pipeline variables (may include secrets).
- Agent pool: machines that run builds and deployments.
- `api-version`: required on every call; max 6.0 here.
- Preview version: `-preview.N` suffix; required by some endpoints.
- `validateOnly`: work item dry run, no save.
