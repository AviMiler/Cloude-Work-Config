# Test plans, feeds/packages, wiki

Prerequisite: `Invoke-Tfs`, `$Base`, `$Proj` from SKILL.md.

## Contents
1. Test plans (version `5.0`)
2. Test runs and results
3. Feeds and packages (version `6.0-preview.1`)
4. npm / NuGet usage of feeds
5. Wiki
6. Pitfalls

## 1. Test plans (use `-Ver "5.0"`)
```powershell
(Invoke-Tfs "$Proj/_apis/test/plans" -Ver "5.0").value | Select-Object id, name, state, @{n='area';e={$_.area.name}}
Invoke-Tfs "$Proj/_apis/test/plans/<planId>" -Ver "5.0"
(Invoke-Tfs "$Proj/_apis/test/plans/<planId>/suites" -Ver "5.0").value | Select-Object id, name, testCaseCount
(Invoke-Tfs "$Proj/_apis/test/plans/<planId>/suites/<suiteId>/points" -Ver "5.0").value | Select-Object id, outcome, @{n='case';e={$_.testCase.name}}
```
- `outcome`: `Passed`, `Failed`, `Blocked`, `NotApplicable`, `Unspecified`.
- Test cases are work items of type "Test Case". Read them with boards.md.
- Test variables (`test/variables`) returned 404 on this server. Test configurations need `5.0-preview.2`; run attachments, result summary by build and code coverage need `5.0-preview.1`.
- One plan on this server has about 9,900 suites. Never list all suites of a plan into the output.
- Test plans only worked with `5.0` on this server. If a newer version fails, stay on `5.0`.

## 2. Test runs and results
```powershell
(Invoke-Tfs "$Proj/_apis/test/runs?`$top=10" -Ver "5.0").value | Select-Object id, name, state, totalTests, passedTests
(Invoke-Tfs "$Proj/_apis/test/runs/<runId>/results" -Ver "5.0").value | Select-Object id, outcome, testCaseTitle, errorMessage
```
- Runs produced by builds/releases also appear here. Filter by `buildUri` if needed: `...runs?buildUri=<uri>`.
- Failure details: `errorMessage` and `stackTrace` on a result. Show a short excerpt.
- Aggregate stats for a build: `$Proj/_apis/test/ResultSummaryByBuild?buildId=<id>` (try `-Ver 5.0-preview.1`).

## 3. Feeds and packages (version `6.0-preview.1`)
```powershell
(Invoke-Tfs "_apis/packaging/feeds" -Ver "6.0-preview.1").value | Select-Object id, name
(Invoke-Tfs "_apis/packaging/feeds/<feedId>/packages?`$top=50" -Ver "6.0-preview.1").value | Select-Object id, name, protocolType
(Invoke-Tfs "_apis/packaging/feeds/<feedId>/packages/<packageId>/versions" -Ver "6.0-preview.1").value | Select-Object version, isLatest
```
Filters: `protocolType=Npm|NuGet|Maven|PyPI`, `packageNameQuery=<text>`, `includeAllVersions=true`.
- Project-scoped feeds use `$Proj/_apis/packaging/feeds`. Try both if the first is empty.
- Some feeds in the collection-level list are really project-scoped: detail and packages for them return 400 at collection level. If that happens, use the project-level path with the same feed id.
- Feeds hold internal packages. This server has no external internet, so this is where npm/NuGet packages come from.

## 4. npm / NuGet usage of feeds
- npm registry URL pattern: `https://<TFS_HOST>/tfs/<COLLECTION>/_packaging/<feedName>/npm/registry/`
- NuGet v3 URL pattern: `https://<TFS_HOST>/tfs/<COLLECTION>/_packaging/<feedName>/nuget/v3/index.json`
- These are patterns. Confirm the exact URL in the TFS UI (Artifacts > Connect to feed) or the project's existing `.npmrc` before relying on them.
- Do not print `.npmrc` content: it can contain tokens. Show only the registry lines, never `_authToken`, `_auth` or `_password`.

## 5. Wiki
```powershell
(Invoke-Tfs "$Proj/_apis/wiki/wikis").value | Select-Object id, name, type
Invoke-Tfs "$Proj/_apis/wiki/wikis/<wikiId>/pages?path=/&recursionLevel=OneLevel"
Invoke-Tfs "$Proj/_apis/wiki/wikis/<wikiId>/pages?path=/PageName&includeContent=true"
```
- Page content is markdown in `.content`.
- Creating/updating a page is a PUT with `@{ content = "..." }` and an `If-Match` ETag header for updates. Not supported by the helper (no custom headers). Ask the user before attempting, and use `Invoke-RestMethod` directly.

## 6. Pitfalls
- Test APIs: version `5.0` only; `6.0` returns 404 or 400.
- Feeds: 400 means a missing preview suffix.
- Package names for npm scopes contain `@` and `/`. URL-encode with `[uri]::EscapeDataString()`.
