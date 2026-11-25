# PowerShell notes for TFS REST calls

## Contents
1. PowerShell version differences
2. Escaping and quoting
3. JSON: arrays, depth, encoding
4. Reading error bodies
5. Paging and continuation tokens
6. Headers, raw text, binary downloads
7. Dates and URL encoding
8. Output and performance

## 1. PowerShell version differences
- Windows PowerShell 5.1 (`powershell.exe`) and PowerShell 7 (`pwsh`) both work. Check with `$PSVersionTable.PSVersion`.
- 5.1: `Invoke-WebRequest` may need `-UseBasicParsing`. TLS 1.2: if there are TLS errors run `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`.
- 5.1 `Invoke-RestMethod` sometimes returns the raw JSON as one long STRING instead of an object. Seen on this server with `workitemtypes` (about 700 KB) and `distributedtask/tasks` (about 1.4 MB). The `Invoke-Tfs` helper in SKILL.md handles it (retry with `JavaScriptSerializer`). If you must use `Invoke-RestMethod` directly and the result is a string, parse it the same way.
- 5.1 `Invoke-RestMethod` sometimes cannot parse JSON larger than 2 MB. Use `Invoke-WebRequest` and `ConvertFrom-Json` with `[System.Web.Script.Serialization.JavaScriptSerializer]` and `MaxJsonLength` if that happens.
- The `?.` and `??` operators exist only in PowerShell 7.

## 2. Escaping and quoting
- In double-quoted strings, `$name` is expanded. Escape a literal dollar with a backtick: `` `$top ``, `` `$Task ``, `` `$expand ``.
- In single-quoted strings nothing is expanded: `'<PROJECT>/_apis/build/builds?$top=1'`.
- Embedded variables with a method call need `$( )`: `"$($obj.name)"`.
- `${sep}api-version` stops PowerShell from reading `$sepapi...` as one name.
- `?` is a legal character in variable names. `"$id?x=1"` is read as the variable `$id?` (empty), so the URL loses the id and the call returns 404. ALWAYS write `"${id}?x=1"` (same for `$Proj`, `$repo`, `$p`, `$bb`). This was the cause of 404 on `$expand` calls on this server.
- Backtick is the escape character; a backtick at the end of a line continues the command. Do not put spaces after it.
- WIQL strings are inside PowerShell strings: use double quotes outside, single quotes inside WIQL. A single quote inside a WIQL value is doubled (`''`).
- Never name a variable `$args`, `$input`, `$_`, `$error`, `$host`, `$profile`, `$pid`, `$home`.
- `-like` treats `?` and `*` as wildcards. For a literal `?` use `.Contains("?")`.

## 3. JSON
- Always `ConvertTo-Json -InputObject $x -Depth 20` (default depth 2 truncates nested objects).
- `$x | ConvertTo-Json` unrolls arrays: a one-element array becomes an object. Use `-InputObject`.
- Send JSON as UTF-8 bytes (`[Text.Encoding]::UTF8.GetBytes($json)`) so Hebrew is preserved. The helper does this.
- Work item create/update needs `Content-Type: application/json-patch+json`. All other writes use `application/json`.
- Building the body as a hashtable is safer than hand-written JSON strings.
- Booleans: `$true` / `$false` in hashtables, not the strings "true"/"false".
- Reading JSON with dotted property names: `$wi.fields.'System.Title'`.

## 4. Reading error bodies
```powershell
try { Invoke-Tfs "..." } catch {
  $code = $_.Exception.Response.StatusCode.value__
  $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).message
  "HTTP $code : $detail"
}
```
- `$detail` explains what is wrong (missing field, bad version, rule violation). Read it before retrying.
- The helper already prints `HTTP <code> <method> <path> :: <message>`.

## 5. Paging and continuation tokens
- Many list APIs return one page. Signs: a `continuationToken` in the response, or the response header `x-ms-continuationtoken`.
- Header-based paging needs `Invoke-WebRequest`:
```powershell
$all = @(); $tok = $null
do {
  $u = "$Base/$Proj/_apis/build/builds?`$top=100&api-version=6.0" + $(if ($tok) { "&continuationToken=$tok" })
  $r = Invoke-WebRequest -Uri $u -UseDefaultCredentials -UseBasicParsing
  $all += ($r.Content | ConvertFrom-Json).value
  $tok = $r.Headers["x-ms-continuationtoken"]
} while ($tok)
```
- `$top` / `$skip` paging (git commits, PRs): increase `$skip` by `$top` until fewer than `$top` items return.
- Set a sane ceiling (for example 500 items) and tell the user if you stopped at it.

## 6. Headers, raw text, binary downloads
- Custom headers (ETag `If-Match`, `Accept`) are not supported by the `Invoke-Tfs` helper. Use `Invoke-RestMethod -Headers @{ "If-Match" = $etag } -UseDefaultCredentials ...` directly.
- Text endpoints (build logs, file content) return a string. Show only the tail with: `($text -split "`n") | Select-Object -Last 40`.
- Download a file: `Invoke-WebRequest -Uri $u -UseDefaultCredentials -UseBasicParsing -OutFile "C:\temp\x.zip"`.
- Never write downloads into the repository folder or any shared location. Use a temp folder the user approved.

## 7. Dates and URL encoding
- API dates are ISO 8601 UTC: `2026-11-12T14:30:00Z`. Create with `(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")`.
- Yesterday: `(Get-Date).AddDays(-1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")`.
- Convert: `[datetime]$x` (local time conversion applies).
- Encode query values: `[uri]::EscapeDataString("name with spaces/ו")`.
- Branch names inside JSON bodies keep `refs/heads/`. Inside artifact link URLs slashes become `%2F`.

## 8. Output and performance
- Prefer `Select-Object` (objects) over `Format-Table` in scripts. Use `Format-Table -AutoSize` only for the final display.
- Limit: `Select-Object -First N`.
- Loops over many IDs: batch endpoints exist for work items (`workitemsbatch`). Do not call one request per id for large sets.
- Pause between repeated write calls (`Start-Sleep -Milliseconds 300`).
- Do not run more than about 100 requests in a burst without asking the user.
- Wrap each independent check in try/catch so one failure does not stop the others.
