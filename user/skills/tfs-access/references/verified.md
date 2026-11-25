# Verified on this server (full read test, 2026-11-15)

Source: 528 read probes against Azure DevOps Server 2020, PowerShell 5.1, Windows authentication.
Result: 415 OK, 0 permission denials. Write permissions were NOT tested.
Rows with an empty version mean the check is a derived value (a count), not an endpoint.

## Contents
1. Endpoints that worked (area, test, api-version)
2. Endpoints that failed or are unavailable
3. Notes on the failures

## 1. Endpoints that worked

### Core

| Test | api-version |
|---|---|
| projects list | `6.0` |
| teams list | `6.0` |
| team detail | `6.0` |
| team members | `6.0` |
| connectionData (project) | `6.0-preview.1` |
| connectionData (server) | `6.0-preview.1` |
| project collections (server) | `6.0` |
| highest accepted api-version | `6.0` |

### Boards

| Test | api-version |
|---|---|
| work item types | `6.0` |
| work item type categories | `6.0` |
| work item relation types | `6.0` |
| fields list | `6.0` |
| field detail (System.Title) | `6.0` |
| tags | `6.0-preview.1` |
| area tree | `6.0` |
| iteration tree | `6.0` |
| recycle bin | `6.0` |
| process configuration | `6.0-preview.1` |
| delivery plans | `6.0-preview.1` |
| saved queries tree | `6.0` |
| saved query run | `6.0` |
| WIQL: latest items | `6.0` |
| WIQL: assigned to @Me | `6.0` |
| WIQL: changed last 30 days | `6.0` |
| WIQL: tree of links | `6.0` |
| batch POST (fields) | `6.0` |
| batch POST (relations) | `6.0` |
| batch GET (ids+fields) | `6.0` |
| item get | `6.0` |
| item revisions | `6.0` |
| item updates | `6.0` |
| item comments | `6.0-preview.3` |
| reporting: work item revisions | `6.0` |
| reporting: work item links | `6.0` |
| teams list | `6.0` |
| team settings | `6.0` |
| team field values | `6.0` |
| team iterations | `6.0` |
| team current iteration | `6.0` |
| team WIQL @CurrentIteration | `6.0` |
| iteration capacities | `6.0-preview.2` |
| iteration days off | `6.0` |
| boards | `6.0` |
| board detail | `6.0` |
| board columns | `6.0` |
| board rows | `6.0` |
| board card settings | `6.0` |
| board card rules | `6.0` |
| team templates | `6.0-preview.1` |
| team dashboards | `6.0-preview.2` |

### Git

| Test | api-version |
|---|---|
| project id lookup | `6.0` |
| repositories | `6.0` |
| repo detail | `6.0` |
| branches | `6.0` |
| tags | `6.0` |
| branch stats | `6.0` |
| commits | `6.0` |
| commits batch POST | `6.0` |
| commit detail | `6.0` |
| commit changes | `6.0` |
| commit statuses | `6.0` |
| root tree | `6.0` |
| folder listing (root) | `6.0` |
| file content (README) | `6.0` |
| pushes | `6.0` |
| push detail | `6.0` |
| diff between branches | `6.0` |
| PRs active | `6.0` |
| PRs completed | `6.0` |
| PR detail (completed) | `6.0` |
| PR threads (completed) | `6.0` |
| PR commits (completed) | `6.0` |
| PR work items (completed) | `6.0` |
| PR reviewers (completed) | `6.0` |
| PR labels (completed) | `6.0-preview.1` |
| PR iterations (completed) | `6.0` |
| PR iteration changes (completed) | `6.0` |
| PR policy evaluations (completed) | `6.0-preview.1` |
| PRs abandoned | `6.0` |
| import requests | `6.0-preview.1` |
| PRs project-wide (active) | `6.0` |
| PRs project-wide (completed) | `6.0` |
| policy configurations | `6.0` |
| policy types | `6.0` |

### Builds

| Test | api-version |
|---|---|
| definitions | `6.0` |
| definition detail | `6.0` |
| definition revisions | `6.0` |
| builds of definition | `6.0` |
| definition templates | `6.0` |
| build settings | `6.0` |
| tags | `6.0` |
| controllers (legacy) | `6.0` |
| builds (completed) | `6.0` |
| builds (failed) | `6.0` |
| builds (result succeeded) | `6.0` |
| builds (result partiallySucceeded) | `6.0` |
| builds (result canceled) | `6.0` |
| builds (status inProgress) | `6.0` |
| builds (status notStarted) | `6.0` |
| builds (reason manual) | `6.0` |
| builds (reason individualCI) | `6.0` |
| builds (reason schedule) | `6.0` |
| builds (reason pullRequest) | `6.0` |
| builds (last 14 days) | `6.0` |
| builds (order queueTimeDescending) | `6.0` |
| builds (order startTimeDescending) | `6.0` |
| build detail | `6.0` |
| build changes | `6.0` |
| build work items | `6.0` |
| build artifacts | `6.0` |
| build artifact detail | `6.0` |
| build timeline | `6.0` |
| build tags | `6.0` |
| build properties | `6.0-preview.1` |
| build logs list | `6.0` |
| build log (3 lines) | `6.0` |

### Releases

| Test | api-version |
|---|---|
| definitions (environments) | `6.0` |
| definitions (artifacts) | `6.0` |
| definitions (triggers) | `6.0` |
| folders | `6.0-preview.2` |
| environment templates | `6.0-preview.3` |
| definition detail | `6.0` |
| definition revisions | `6.0-preview.1` |
| releases of definition | `6.0` |
| deployments | `6.0` |
| deployments succeeded | `6.0` |
| deployments failed | `6.0` |
| releases status draft | `6.0` |
| releases status active | `6.0` |
| releases status abandoned | `6.0` |
| releases expand artifacts | `6.0` |
| releases expand approvals | `6.0` |
| releases expand manualInterventions | `6.0` |
| release detail | `6.0` |
| release manual interventions | `6.0-preview.1` |
| release environment detail | `6.0-preview.6` |
| approvals (pending) | `6.0` |
| approvals (approved) | `6.0` |
| approvals (rejected) | `6.0` |
| approvals (canceled) | `6.0` |
| approvals type preDeploy | `6.0` |
| approvals type postDeploy | `6.0` |

### Library

| Test | api-version |
|---|---|
| variable groups | `6.0-preview.1` |
| variable group detail | `6.0-preview.1` |
| task groups | `6.0-preview.1` |
| task group detail | `6.0-preview.1` |
| task definitions (tasks) | `6.0` |
| service endpoints | `6.0-preview.1` |
| secure files | `6.0-preview.1` |
| deployment groups | `6.0-preview.1` |
| deployment group detail | `6.0-preview.1` |
| deployment group targets | `6.0-preview.1` |
| environments | `6.0-preview.1` |
| environment detail | `6.0-preview.1` |

### Agents

| Test | api-version |
|---|---|
| agent pools | `6.0` |
| pool detail | `6.0` |
| agents of pool | `6.0` |
| agent detail with capabilities | `6.0` |
| job requests | `6.0` |
| maintenance definitions | `6.0-preview.1` |

### Tests

| Test | api-version |
|---|---|
| test plans | `5.0` |
| plan detail | `5.0` |
| suites | `5.0` |
| suite detail | `5.0` |
| suite test cases | `5.0` |
| suite test points | `5.0` |
| test configurations | `5.0-preview.2` |
| test runs | `5.0` |
| run detail | `5.0` |
| run results | `5.0` |
| result detail | `5.0` |
| run statistics | `5.0` |
| run attachments | `5.0-preview.1` |
| result summary by build | `5.0-preview.1` |
| code coverage by build | `5.0-preview.1` |

### Feeds

| Test | api-version |
|---|---|
| feeds (collection) | `6.0-preview.1` |
| feed detail (collection) | `6.0-preview.1` |
| feed views (collection) | `6.0-preview.1` |
| feed retention (collection) | `6.0-preview.1` |
| feed permissions count (collection) | `6.0-preview.1` |
| packages (collection) | `6.0-preview.1` |
| packages npm (collection) | `6.0-preview.1` |
| packages nuget (collection) | `6.0-preview.1` |
| package detail (collection) | `6.0-preview.1` |
| package versions (collection) | `6.0-preview.1` |
| recycle bin (collection) | `6.0-preview.1` |
| feeds (project) | `6.0-preview.1` |
| feed detail (project) | `6.0-preview.1` |
| feed views (project) | `6.0-preview.1` |
| feed retention (project) | `6.0-preview.1` |
| feed permissions count (project) | `6.0-preview.1` |
| packages (project) | `6.0-preview.1` |
| packages npm (project) | `6.0-preview.1` |
| packages nuget (project) | `6.0-preview.1` |
| recycle bin (project) | `6.0-preview.1` |
| package detail (project) | `6.0-preview.1` |
| package versions (project) | `6.0-preview.1` |

### Wiki

| Test | api-version |
|---|---|
| wikis | `6.0` |
| wiki detail | `6.0` |
| pages root | `6.0` |
| page content | `6.0` |

### Tfvc

| Test | api-version |
|---|---|
| branches | `6.0` |
| changesets | `6.0` |
| changeset detail | `6.0` |
| labels | `6.0` |
| items (root) | `6.0` |

### Misc

| Test | api-version |
|---|---|
| resource areas | `6.0-preview.1` |
| security namespaces | `6.0` |
| service hooks: publishers | `6.0` |
| service hooks: consumers | `6.0` |
| service hooks: subscriptions | `6.0` |
| installed extensions | `6.0-preview.1` |
| notification subscriptions | `6.0` |
| process templates (inherited) | `6.0-preview.2` |
| process templates (legacy) | `6.0` |
| dashboards (project) | `6.0-preview.2` |
| favorites | `6.0-preview.1` |

## 2. Endpoints that failed or are unavailable

| Area | Test | Status | HTTP | Versions tried |
|---|---|---|---|---|
| Core | project details (capabilities) | FAIL | 404 | 6.0 |
| Core | project properties | N/A | 400 | 6.0-preview.1/5.0-preview.1 |
| Boards | saved query detail | FAIL | 404 | 6.0 |
| Boards | item relations | FAIL | 404 | 6.0 |
| Boards | item expand all | FAIL | 404 | 6.0 |
| Boards | iteration items | FAIL | 400 | 6.0 |
| Boards | backlogs | FAIL | 400 | 6.0 |
| Git | commit work items | N/A | 404 | 6.0/6.0-preview.1/5.0 |
| Git | PR statuses (completed) | N/A | 400 | 6.0/5.0 |
| Builds | definition yaml | N/A | 404 | 6.0-preview.1/6.0 |
| Builds | folders | N/A | 400 | 6.0 |
| Builds | build options | N/A | 400 | 6.0 |
| Builds | build report | N/A | 400 | 6.0-preview.2/6.0-preview.1/5.0-preview.2 |
| Releases | settings | N/A | 404 | 6.0-preview.1/6.0/5.0-preview.1 |
| Library | service endpoint types | FAIL | 404 | 6.0-preview.1/5.0-preview.1/5.1-preview.1/6.0-preview.2 |
| Agents | project queues | FAIL | 400 | 6.0 |
| Tests | test variables | N/A | 404 | 5.0/4.1/5.0-preview.2/5.0-preview.3/6.0 |
| Tfvc | changeset changes | N/A | 404 | 6.0/5.0/4.1 |
| Tfvc | changeset work items | N/A | 404 | 6.0/5.0/4.1 |

## 3. Notes on the failures
- `$expand` on a work item, saved query detail, project details with `includeCapabilities`: the URL was broken by PowerShell (`$var?` read as one variable). They work when written with `${var}?`. They are NOT unavailable.
- Iteration work items, backlogs, project queues: work with `6.0-preview.1` (6.0 gives 400). Not re-tested after the fix.
- Service endpoint types: the project-level path returned 404. The collection-level path was not tested.
- Feeds [1] at collection level: that feed is project-scoped. Use the project-level path.
- Team 3: has no iterations configured (404 and 500 are expected for iteration and board calls).
- Genuinely unavailable or unusable on this version: commit work items, PR statuses, build folders, build options, build report, definition yaml, release settings, test variables, TFVC changeset changes and work items, project properties.
- `workitemtypes` and `distributedtask/tasks` came back as a raw string in PowerShell 5.1: the helper in SKILL.md converts them.
