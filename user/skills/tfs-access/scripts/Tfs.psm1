# Tfs.psm1: read-mostly REST access to the internal Azure DevOps Server (TFS 2020, API 6.0) for Windows PowerShell 5.1; settings come from tfs-config.psd1.

$script:ConfigFileShown = 'scripts\tfs-config.psd1'
$script:Defaults = @{
    DefaultTop                 = 20
    MaxTop                     = 200
    LogTailLines               = 40
    MaxLogTailLines            = 200
    ClosedStates               = @('Closed', 'Done', 'Removed')
    SummaryHours               = 24
    DeployedDefaultDefinitions = 3
    DeployedMaxDefinitions     = 10
    TimeoutSec                 = 100
}
$script:NumericKeys = @('DefaultTop', 'MaxTop', 'LogTailLines', 'MaxLogTailLines', 'SummaryHours', 'DeployedDefaultDefinitions', 'DeployedMaxDefinitions', 'TimeoutSec')
$script:MaxAtLeastDefault = @(
    @('MaxTop', 'DefaultTop'),
    @('MaxLogTailLines', 'LogTailLines'),
    @('DeployedMaxDefinitions', 'DeployedDefaultDefinitions')
)
$script:MaxLineChars = 4000
$script:MaxBodyChars = 5000000
$script:Cfg = $null
$script:ConfigError = $null
$script:Base = $null
$script:Proj = $null
$script:HostName = $null

#region Config

function Get-TfsConfigProblem {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$User, [Parameter(Mandatory)][hashtable]$Merged)

    $shown = $script:ConfigFileShown
    foreach ($key in @('CollectionUrl', 'Project')) {
        if (-not $User.ContainsKey($key) -or $User[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($User[$key])) {
            return "Config: missing or empty key $key in $shown"
        }
    }
    $ordered = @('CollectionUrl', 'Project') + @($User.Keys | Where-Object { $_ -ne 'CollectionUrl' -and $_ -ne 'Project' } | Sort-Object)
    foreach ($key in $ordered) {
        foreach ($item in @($User[$key])) {
            if ($item -is [string]) {
                $m = [regex]::Match($item, '<[A-Z][A-Z0-9_]*>')
                if ($m.Success) { return "Config: placeholder $($m.Value) not replaced (key $key) in $shown" }
            }
        }
    }
    if ($User.CollectionUrl.TrimEnd('/') -notmatch '^https?://[^/<>\s]+/') {
        return "Config: key CollectionUrl must look like https://host/path in $shown"
    }
    foreach ($key in $script:NumericKeys) {
        $v = $Merged[$key]
        if (($v -isnot [int] -and $v -isnot [long]) -or $v -lt 1) {
            return "Config: key $key must be a positive integer in $shown"
        }
    }
    foreach ($pair in $script:MaxAtLeastDefault) {
        if ($Merged[$pair[0]] -lt $Merged[$pair[1]]) {
            return "Config: $($pair[0]) must be at least $($pair[1]) in $shown"
        }
    }
    if (@($Merged.ClosedStates).Count -lt 1) {
        return "Config: key ClosedStates needs at least one state in $shown"
    }
    foreach ($state in @($Merged.ClosedStates)) {
        if ($state -isnot [string] -or [string]::IsNullOrWhiteSpace($state)) {
            return "Config: key ClosedStates must be a list of non-empty strings in $shown"
        }
    }
    return $null
}

function Import-TfsConfig {
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Base and Proj are published on purpose so the raw REST snippets in the skill references keep working; module functions only use the script-scope copies.')]
    param()

    $script:Cfg = $null
    $script:Base = $null
    $script:Proj = $null
    $script:HostName = $null
    $script:ConfigError = $null
    $path = Join-Path $PSScriptRoot 'tfs-config.psd1'
    $problem = $null
    $user = $null
    if (-not (Test-Path -LiteralPath $path)) {
        $problem = "Config: file not found: $($script:ConfigFileShown)"
    }
    else {
        try { $user = Import-PowerShellDataFile -LiteralPath $path }
        catch { $problem = "Config: cannot read $($script:ConfigFileShown) (syntax error)" }
    }
    $merged = @{}
    if (-not $problem) {
        foreach ($key in $script:Defaults.Keys) { $merged[$key] = $script:Defaults[$key] }
        foreach ($key in $user.Keys) { $merged[$key] = $user[$key] }
        if ($user.ContainsKey('ClosedStates')) { $merged.ClosedStates = @($user.ClosedStates) }
        $problem = Get-TfsConfigProblem -User $user -Merged $merged
    }
    if ($problem) {
        $script:ConfigError = $problem
        Remove-Variable -Name Base, Proj -Scope Global -ErrorAction SilentlyContinue
        Write-Warning $problem
        return
    }
    $script:Cfg = $merged
    $script:Base = $user.CollectionUrl.TrimEnd('/')
    $script:Proj = $user.Project
    $script:HostName = ([uri]$script:Base).Host
    $global:Base = $script:Base
    $global:Proj = $script:Proj
    if ($script:Base -like 'http://*') {
        Write-Warning 'Config: CollectionUrl uses http, so integrated authentication travels in cleartext'
    }
}

function Assert-TfsConfig {
    [CmdletBinding()]
    [OutputType([void])]
    param()
    if ($script:ConfigError) { throw $script:ConfigError }
}

#endregion Config

#region Helpers

function ConvertTo-TfsPsObject {
    [CmdletBinding()]
    [OutputType([object], [object[]], [pscustomobject])]
    param($InputValue)

    if ($null -eq $InputValue) { return $null }
    if ($InputValue -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in @($InputValue.Keys)) {
            $n = [string]$k
            $i = 2
            while ($h.Contains($n)) { $n = "${k}_$i"; $i++ }
            $h[$n] = ConvertTo-TfsPsObject -InputValue $InputValue[$k]
        }
        return [pscustomobject]$h
    }
    if ($InputValue -is [System.Collections.IEnumerable] -and $InputValue -isnot [string]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($x in $InputValue) { $list.Add((ConvertTo-TfsPsObject -InputValue $x)) }
        return , ($list.ToArray())
    }
    return $InputValue
}

function ConvertFrom-TfsJson {
    [CmdletBinding()]
    [OutputType([object], [string])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '', Justification = 'The -AsHashtable branch only runs on PowerShell 6 and later (guarded by PSVersion.Major).')]
    param([Parameter(Mandatory)][string]$Text)

    # Windows PowerShell 5.1 ConvertFrom-Json fails on very large documents and on keys that differ only in case, so fall back step by step.
    try { return ($Text | ConvertFrom-Json) }
    catch { Write-Verbose 'ConvertFrom-Json failed, trying fallback parsers' }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try { return ConvertTo-TfsPsObject -InputValue ($Text | ConvertFrom-Json -AsHashtable) }
        catch { Write-Verbose 'ConvertFrom-Json -AsHashtable failed' }
    }
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $js.MaxJsonLength = [int]::MaxValue
        return ConvertTo-TfsPsObject -InputValue ($js.DeserializeObject($Text))
    }
    catch { Write-Verbose 'JavaScriptSerializer failed' }
    throw 'JSON could not be parsed'
}

function Hide-TfsSecret {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # Cap first: bounds the regex work on hostile or huge lines (ReDoS) and the size of anything printed.
    $t = $Text
    if ($t.Length -gt $script:MaxLineChars) { $t = $t.Substring(0, $script:MaxLineChars) + '...[truncated]' }
    if ($script:Base) { $t = [regex]::Replace($t, [regex]::Escape($script:Base), '<base>', 'IgnoreCase') }
    if ($script:HostName) { $t = [regex]::Replace($t, [regex]::Escape($script:HostName), '<host>', 'IgnoreCase') }
    $t = [regex]::Replace($t, '://[^/\s:@]+:[^@\s]+@', '://***@')
    $t = [regex]::Replace($t, 'eyJ[\w-]+\.[\w-]+\.[\w-]+', '***')
    $t = [regex]::Replace($t, '(?i)bearer\s+\S+', 'Bearer ***')
    $t = [regex]::Replace($t, '(?i)\bbasic\s+[A-Za-z0-9+/=]{8,}', 'Basic ***')
    $t = [regex]::Replace($t, '(?i)(password|passwd|pwd|secret|token|api[_-]?key|accesskey|connectionstring|authorization)\s*[:=]\s*("[^"]*"|\S+)', '$1=***')
    $t = [regex]::Replace($t, '\b[a-z0-9]{52}\b', '***')
    return $t
}

function Get-TfsTop {
    [CmdletBinding()]
    [OutputType([int])]
    param([int]$Top = 0)

    if ($Top -le 0) { return [int]$script:Cfg.DefaultTop }
    if ($Top -gt $script:Cfg.MaxTop) {
        Write-Warning "Top capped at $($script:Cfg.MaxTop)"
        return [int]$script:Cfg.MaxTop
    }
    return $Top
}

function Get-TfsErrorInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    # One mapping for every place that reports a failure: HTTP n, NETWORK, PARSE, REDIRECT, TOOBIG, or ERROR (not raised by Invoke-Tfs).
    $data = $ErrorRecord.Exception.Data
    $kind = 'ERROR'
    $code = 0
    if ($data.Contains('Kind')) {
        $kind = [string]$data['Kind']
        if ($data.Contains('StatusCode')) { $code = [int]$data['StatusCode'] }
    }
    $label = $kind
    if ($kind -eq 'HTTP') { $label = "HTTP $code" }
    return [pscustomobject][ordered]@{ Kind = $kind; Code = $code; Label = $label }
}

function Format-TfsRef {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Ref)

    if ([string]::IsNullOrEmpty($Ref)) { return '' }
    return ($Ref -replace '^refs/heads/', '')
}

function Format-TfsDate {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)

    # Windows PowerShell 5.1 leaves ISO dates as strings, PowerShell 7 converts them to [datetime]; both end up as UTC text.
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $format = 'yyyy-MM-dd HH:mm'
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) {
        $utc = $Value
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { $utc = [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) }
        return $utc.ToUniversalTime().ToString($format, $invariant)
    }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($s, $invariant, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString($format, $invariant)
    }
    return $s
}

function ConvertTo-TfsUtcIso {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Value)

    return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-TfsException {
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][int]$Code,
        [Parameter(Mandatory)][string]$Kind
    )

    $ex = New-Object System.Exception((Hide-TfsSecret -Text $Message))
    $ex.Data['StatusCode'] = $Code
    $ex.Data['Kind'] = $Kind
    return $ex
}

function Get-TfsHttpException {
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path
    )

    # A new exception is built on purpose: the original message and ResponseUri contain the server name.
    $code = 0
    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response -and $response.PSObject.Properties['StatusCode']) {
        try { $code = [int]$response.StatusCode } catch { $code = 0 }
    }
    $kind = 'HTTP'
    $detail = ''
    if ($code -ge 300 -and $code -lt 400) {
        $kind = 'REDIRECT'
        $detail = 'REDIRECT not followed'
    }
    elseif ($code -eq 0 -and $ErrorRecord.Exception.Message -match '(?i)redirect') {
        # Windows PowerShell 5.1 can raise the exceeded-redirection error without a response object.
        $kind = 'REDIRECT'
        $detail = 'REDIRECT not followed'
    }
    elseif ($code -eq 0) {
        $kind = 'NETWORK'
        $inner = $ErrorRecord.Exception
        if ($inner -is [System.Net.WebException]) { $detail = 'NETWORK ' + $inner.Status.ToString() }
        else { $detail = 'NETWORK ' + $inner.GetType().Name }
    }
    elseif ($null -ne $ErrorRecord.ErrorDetails) {
        try { $detail = [string](($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json).message) } catch { $detail = '' }
    }
    return Get-TfsException -Message "HTTP $code $Method $Path :: $detail" -Code $code -Kind $kind
}

function Assert-TfsSafeSegment {
    [CmdletBinding()]
    [OutputType([void])]
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Name)

    # '.' and '..' are not escaped by EscapeDataString and would walk out of the intended URL path.
    foreach ($segment in ($Value -split '[/\\]')) {
        if ($segment -eq '.' -or $segment -eq '..') { throw "$Name must not contain '.' or '..' path segments" }
    }
}

function Get-TfsResponseText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Response)

    # Windows PowerShell 5.1 decodes a response without charset as ISO-8859-1 (breaks Hebrew), so decode the raw bytes as UTF-8.
    $text = $null
    $stream = $null
    if ($Response.PSObject.Properties['RawContentStream']) { $stream = $Response.RawContentStream }
    if ($stream -is [System.IO.MemoryStream]) {
        $text = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    }
    else {
        $text = $Response.Content
        if ($text -is [byte[]]) { $text = [System.Text.Encoding]::UTF8.GetString($text) }
    }
    if ($null -eq $text) { return '' }
    return ([string]$text).TrimStart([char]0xFEFF)
}

#endregion Helpers

#region Invoke-Tfs

<#
.SYNOPSIS
Calls any TFS _apis path with Windows integrated auth and returns the parsed JSON (or text, or $null).
.DESCRIPTION
Always appends api-version (default 6.0). Paths are relative to the collection URL, so project-level paths start with $Proj. HTTP errors throw a new exception whose message is 'HTTP <code> <method> <path> :: <server message>' (code 0 = network) and whose Data['StatusCode'] holds the code and Data['Kind'] one of HTTP, NETWORK, PARSE, REDIRECT, TOOBIG; the server name is never included, but the path (with the project name) is. A 3xx is never followed (REDIRECT). A body that is not JSON (an HTML login page) throws PARSE unless -Raw is used; bodies over 5,000,000 characters throw TOOBIG.
.PARAMETER Path
Relative path including any query string. Write a literal $top as a backtick-escaped `$top and use ${id}? before a query.
.PARAMETER Body
Object (sent as compact JSON, UTF-8) or a string (sent unchanged).
.PARAMETER Raw
Return the response text without JSON parsing (logs, $format=text). Required for any non-JSON answer.
.EXAMPLE
Invoke-Tfs '_apis/projects?`$top=2'
#>
function Invoke-Tfs {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        [object]$Body = $null,
        [string]$Ver = '6.0',
        [string]$ContentType = 'application/json',
        [switch]$Raw
    )

    Assert-TfsConfig
    $rel = $Path.TrimStart('/')
    $sep = '?'
    if ($rel.Contains('?')) { $sep = '&' }
    $req = @{
        Uri                   = $script:Base + '/' + $rel + $sep + 'api-version=' + $Ver
        Method                = $Method
        UseDefaultCredentials = $true
        UseBasicParsing       = $true
        TimeoutSec            = $script:Cfg.TimeoutSec
        MaximumRedirection    = 0
        ErrorAction           = 'Stop'
    }
    if ($null -ne $Body) {
        $json = $Body
        if ($Body -isnot [string]) { $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress }
        $req.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $req.ContentType = "$ContentType; charset=utf-8"
    }
    Write-Verbose "$Method $rel"
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { $resp = Invoke-WebRequest @req }
    catch { throw (Get-TfsHttpException -ErrorRecord $_ -Method $Method -Path $rel) }
    finally { $ProgressPreference = $savedProgress }

    $status = 200
    if ($resp.PSObject.Properties['StatusCode']) { $status = [int]$resp.StatusCode }
    if ($status -ge 300 -and $status -lt 400) {
        throw (Get-TfsException -Message "HTTP $status $Method $rel :: REDIRECT not followed" -Code $status -Kind 'REDIRECT')
    }
    $text = Get-TfsResponseText -Response $resp
    if ($text.Length -gt $script:MaxBodyChars) {
        throw (Get-TfsException -Message "HTTP $status $Method $rel :: TOOBIG (body over $($script:MaxBodyChars) characters)" -Code $status -Kind 'TOOBIG')
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if ($Raw) { return $text }
    $trimmed = $text.TrimStart()
    $parseError = Get-TfsException -Message "HTTP $status $Method $rel :: PARSE" -Code $status -Kind 'PARSE'
    if (-not ($trimmed.StartsWith('{') -or $trimmed.StartsWith('['))) { throw $parseError }
    try { return (ConvertFrom-TfsJson -Text $text) }
    catch { throw $parseError }
}

#endregion Invoke-Tfs

#region Work items

function Get-TfsBatch {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][int[]]$Ids,
        [Parameter(Mandatory)][string[]]$Fields
    )

    # workitemsbatch accepts at most 200 ids per call; the answer is unordered, so restore the input order.
    $byId = @{}
    for ($i = 0; $i -lt $Ids.Count; $i += 200) {
        $last = [Math]::Min($i + 199, $Ids.Count - 1)
        $resp = Invoke-Tfs -Path '_apis/wit/workitemsbatch' -Method POST -Body @{ ids = @($Ids[$i..$last]); fields = $Fields }
        foreach ($wi in $resp.value) { $byId[[int]$wi.id] = $wi }
    }
    foreach ($id in $Ids) {
        if ($byId.ContainsKey($id)) { $byId[$id] }
    }
}

function ConvertTo-TfsFieldValue {
    [CmdletBinding()]
    [OutputType([object], [string])]
    param($Value)

    if ($Value -is [pscustomobject] -and $Value.PSObject.Properties['displayName']) { return [string]$Value.displayName }
    return $Value
}

function ConvertTo-TfsRelation {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Relation)

    # Only the kind and the target id are kept; the URL itself contains the server name.
    $url = [string]$Relation.url
    $kind = 'Other'
    $targetId = $null
    if ($Relation.rel -eq 'Hyperlink') { $kind = 'Hyperlink' }
    elseif ($url -match '(?i)/_apis/wit/workitems/(\d+)$') {
        $kind = 'WorkItem'
        $targetId = [int]$Matches[1]
    }
    elseif ($url -match '^vstfs:///([^/]+/[^/]+)/(.+)$') {
        $kind = $Matches[1]
        $targetId = ($Matches[2] -split '(?i)%2f|/')[-1]
    }
    $name = ''
    if ($Relation.PSObject.Properties['attributes'] -and $Relation.attributes.PSObject.Properties['name']) { $name = [string]$Relation.attributes.name }
    return [pscustomobject][ordered]@{ Rel = [string]$Relation.rel; TargetId = $targetId; Target = $kind; Name = $name }
}

<#
.SYNOPSIS
Lists my open work items (assigned to me, not in a closed state): Id, Type, State, Title.
.PARAMETER Top
Maximum items; 0 means the configured DefaultTop, larger than MaxTop is capped with a warning.
.EXAMPLE
Get-TfsMyItems -Top 10
#>
function Get-TfsMyItems {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int]$Top = 0)

    Assert-TfsConfig
    $n = Get-TfsTop -Top $Top
    $states = ($script:Cfg.ClosedStates | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $query = 'SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.AssignedTo] = @Me AND [System.State] NOT IN (' + $states + ') ORDER BY [System.ChangedDate] DESC'
    $resp = Invoke-Tfs -Path ($script:Proj + '/_apis/wit/wiql?$top=' + $n) -Method POST -Body @{ query = $query }
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($w in $resp.workItems) { $ids.Add([int]$w.id) }
    if ($ids.Count -eq 0) { return }
    $fields = @('System.Id', 'System.WorkItemType', 'System.State', 'System.Title')
    foreach ($wi in (Get-TfsBatch -Ids $ids.ToArray() -Fields $fields)) {
        [pscustomobject][ordered]@{
            Id    = [int]$wi.id
            Type  = $wi.fields.'System.WorkItemType'
            State = $wi.fields.'System.State'
            Title = $wi.fields.'System.Title'
        }
    }
}

<#
.SYNOPSIS
Reads one work item: Id, Type, State, Title, AreaPath, IterationPath, Tags, Changed, Rev (plus -Fields; with -Links also Relations).
.PARAMETER Fields
Extra field reference names to include; identity values are returned as display names.
.PARAMETER Links
Adds Relations (Rel, TargetId, Target, Name). Uses $expand=relations, which cannot be combined with fields=, so all fields are fetched.
.EXAMPLE
Get-TfsItem -Id 1234 -Links
#>
function Get-TfsItem {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Id,
        [switch]$Links,
        [string[]]$Fields
    )

    Assert-TfsConfig
    if ($Links) {
        $path = '_apis/wit/workitems/' + $Id + '?$expand=relations'
    }
    else {
        $names = @('System.WorkItemType', 'System.State', 'System.Title', 'System.AreaPath', 'System.IterationPath', 'System.Tags', 'System.ChangedDate', 'System.Rev') + @($Fields | Where-Object { $_ })
        $path = '_apis/wit/workitems/' + $Id + '?fields=' + (($names | Select-Object -Unique | ForEach-Object { [uri]::EscapeDataString($_) }) -join ',')
    }
    $wi = Invoke-Tfs -Path $path
    $f = $wi.fields
    $out = [ordered]@{
        Id            = [int]$wi.id
        Type          = $f.'System.WorkItemType'
        State         = $f.'System.State'
        Title         = $f.'System.Title'
        AreaPath      = $f.'System.AreaPath'
        IterationPath = $f.'System.IterationPath'
        Tags          = $f.'System.Tags'
        Changed       = Format-TfsDate -Value $f.'System.ChangedDate'
        Rev           = $wi.rev
    }
    foreach ($name in $Fields) {
        if ($name) { $out[$name] = ConvertTo-TfsFieldValue -Value $f.$name }
    }
    if ($Links) {
        $rels = New-Object System.Collections.Generic.List[object]
        foreach ($r in $wi.relations) { $rels.Add((ConvertTo-TfsRelation -Relation $r)) }
        $out.Relations = $rels.ToArray()
    }
    [pscustomobject]$out
}

#endregion Work items

#region Git

<#
.SYNOPSIS
Finds Git repositories by wildcard name (client-side filter, sorted, first N): Name, Id, DefaultBranch.
.EXAMPLE
Find-TfsRepo -Name '*billing*' -Top 10
#>
function Find-TfsRepo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string]$Name = '*',
        [int]$Top = 0
    )

    Assert-TfsConfig
    $n = Get-TfsTop -Top $Top
    $resp = Invoke-Tfs -Path ($script:Proj + '/_apis/git/repositories')
    $found = foreach ($r in $resp.value) { if ($r.name -like $Name) { $r } }
    foreach ($r in ($found | Sort-Object -Property name | Select-Object -First $n)) {
        [pscustomobject][ordered]@{
            Name          = $r.name
            Id            = $r.id
            DefaultBranch = Format-TfsRef -Ref $r.defaultBranch
        }
    }
}

<#
.SYNOPSIS
Lists pull requests (project-wide, or one repository): Id, Title, Repo, Source, Target, Status, IsDraft, Created, MergeStatus.
.PARAMETER Active
Switch kept for the form 'Get-TfsPR -Active'; same as -Status active, and an error together with another -Status.
.EXAMPLE
Get-TfsPR -Repo svc -Status completed -Top 5
#>
function Get-TfsPR {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Repo,
        [ValidateSet('active', 'completed', 'abandoned', 'all')][string]$Status = 'active',
        [switch]$Active,
        [string]$TargetBranch,
        [int]$Top = 0
    )

    if ($Active -and $PSBoundParameters.ContainsKey('Status') -and $Status -ne 'active') {
        throw "-Active cannot be combined with -Status $Status; use -Status alone"
    }
    Assert-TfsConfig
    Assert-TfsSafeSegment -Value $Repo -Name '-Repo'
    Assert-TfsSafeSegment -Value $TargetBranch -Name '-TargetBranch'
    $n = Get-TfsTop -Top $Top
    $query = 'searchCriteria.status=' + $Status
    if ($TargetBranch) { $query += '&searchCriteria.targetRefName=refs/heads/' + [uri]::EscapeDataString($TargetBranch) }
    $query += '&$top=' + $n
    if ($Repo) { $path = $script:Proj + '/_apis/git/repositories/' + [uri]::EscapeDataString($Repo) + '/pullrequests?' + $query }
    else { $path = $script:Proj + '/_apis/git/pullrequests?' + $query }
    $resp = Invoke-Tfs -Path $path
    foreach ($pr in $resp.value) {
        $draft = $false
        if ($pr.PSObject.Properties['isDraft']) { $draft = [bool]$pr.isDraft }
        [pscustomobject][ordered]@{
            Id          = [int]$pr.pullRequestId
            Title       = $pr.title
            Repo        = $pr.repository.name
            Source      = Format-TfsRef -Ref $pr.sourceRefName
            Target      = Format-TfsRef -Ref $pr.targetRefName
            Status      = $pr.status
            IsDraft     = $draft
            Created     = Format-TfsDate -Value $pr.creationDate
            MergeStatus = $pr.mergeStatus
        }
    }
}

<#
.SYNOPSIS
Lists recent commits of a repository (default branch unless -Branch): Sha (8 chars), Comment (first line), Date.
.EXAMPLE
Get-TfsCommits -Repo svc -Branch feature/x -Top 5
#>
function Get-TfsCommits {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Branch,
        [int]$Top = 0
    )

    Assert-TfsConfig
    Assert-TfsSafeSegment -Value $Repo -Name '-Repo'
    Assert-TfsSafeSegment -Value $Branch -Name '-Branch'
    $n = Get-TfsTop -Top $Top
    $query = ''
    if ($Branch) { $query = 'searchCriteria.itemVersion.version=' + [uri]::EscapeDataString($Branch) + '&' }
    $query += 'searchCriteria.$top=' + $n
    $resp = Invoke-Tfs -Path ($script:Proj + '/_apis/git/repositories/' + [uri]::EscapeDataString($Repo) + '/commits?' + $query)
    foreach ($c in $resp.value) {
        $sha = [string]$c.commitId
        if ($sha.Length -gt 8) { $sha = $sha.Substring(0, 8) }
        $line = ([string]$c.comment -split '\r?\n')[0].Trim()
        if ($line.Length -gt 200) { $line = $line.Substring(0, 200) }
        [pscustomobject][ordered]@{
            Sha     = $sha
            Comment = $line
            Date    = Format-TfsDate -Value $c.committer.date
        }
    }
}

#endregion Git

#region Builds and releases

<#
.SYNOPSIS
Explains a failed build: facts, failed/canceled steps with their error issues, and the masked tail of the first failed task log.
.DESCRIPTION
FailedSteps lists tasks first, then stages and jobs, at most 10 steps and 10 error issues per step. LogTail is the last -TailLines lines of the first failed task that has a log, with secrets and the server name masked.
.PARAMETER TailLines
Log lines to return; 0 means the configured LogTailLines, larger than MaxLogTailLines is capped with a warning.
.EXAMPLE
Get-TfsBuildFailure -Id 4711
#>
function Get-TfsBuildFailure {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Id,
        [int]$TailLines = 0
    )

    Assert-TfsConfig
    $tail = $TailLines
    if ($tail -le 0) { $tail = [int]$script:Cfg.LogTailLines }
    if ($tail -gt $script:Cfg.MaxLogTailLines) {
        Write-Warning "TailLines capped at $($script:Cfg.MaxLogTailLines)"
        $tail = [int]$script:Cfg.MaxLogTailLines
    }
    $buildPath = $script:Proj + '/_apis/build/builds/' + $Id
    $build = Invoke-Tfs -Path $buildPath
    $timeline = Invoke-Tfs -Path ($buildPath + '/timeline')

    $tasks = New-Object System.Collections.Generic.List[object]
    $others = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $timeline.records) {
        if ($rec.result -eq 'failed' -or $rec.result -eq 'canceled') {
            if ($rec.type -eq 'Task') { $tasks.Add($rec) } else { $others.Add($rec) }
        }
    }
    $steps = New-Object System.Collections.Generic.List[object]
    $tasks.AddRange($others)   # tasks first, then stages and jobs
    foreach ($rec in ($tasks | Select-Object -First 10)) {
        $errors = New-Object System.Collections.Generic.List[string]
        foreach ($issue in $rec.issues) {
            if ($issue.type -eq 'error' -and $errors.Count -lt 10) {
                $message = (Hide-TfsSecret -Text ([string]$issue.message)).Trim()
                if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
                $errors.Add($message)
            }
        }
        $steps.Add([pscustomobject][ordered]@{ Step = $rec.name; Type = $rec.type; Result = $rec.result; Errors = $errors.ToArray() })
    }

    $logStep = $null
    $logLines = New-Object System.Collections.Generic.List[string]
    $logRec = $tasks | Where-Object { $_.type -eq 'Task' -and $_.log -and $_.log.id } | Select-Object -First 1
    if ($null -ne $logRec) {
        $logStep = $logRec.name
        $logId = [int]$logRec.log.id
        $lineCount = 0
        foreach ($entry in (Invoke-Tfs -Path ($buildPath + '/logs')).value) {
            if ([int]$entry.id -eq $logId -and $entry.PSObject.Properties['lineCount']) { $lineCount = [int]$entry.lineCount }
        }
        if ($lineCount -gt 0) {
            $start = [Math]::Max(1, $lineCount - $tail + 1)
            $text = Invoke-Tfs -Path ($buildPath + '/logs/' + $logId + '?startLine=' + $start + '&endLine=' + $lineCount) -Raw
        }
        else {
            $text = Invoke-Tfs -Path ($buildPath + '/logs/' + $logId) -Raw
        }
        $clean = ([string]$text).TrimEnd("`r", "`n")
        if ($clean.Length -gt 0) {
            foreach ($line in ($clean -split '\r?\n' | Select-Object -Last $tail)) { $logLines.Add((Hide-TfsSecret -Text $line)) }
        }
    }

    $sha = [string]$build.sourceVersion
    if ($sha.Length -gt 8) { $sha = $sha.Substring(0, 8) }
    [pscustomobject][ordered]@{
        Id          = [int]$build.id
        BuildNumber = $build.buildNumber
        Definition  = $build.definition.name
        Status      = $build.status
        Result      = $build.result
        Branch      = Format-TfsRef -Ref $build.sourceBranch
        Sha         = $sha
        FailedSteps = $steps.ToArray()
        LogStep     = $logStep
        LogTail     = $logLines.ToArray()
    }
}

function Get-TfsArtifactVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param($Release)

    # Returns $null when the release object carries no artifacts (so the caller can fall back to reading the release).
    if ($null -eq $Release -or -not $Release.PSObject.Properties['artifacts']) { return $null }
    $first = $null
    $primary = $null
    foreach ($a in $Release.artifacts) {
        if ($null -eq $first) { $first = $a }
        if ($a.isPrimary -and $null -eq $primary) { $primary = $a }
    }
    $pick = $primary
    if ($null -eq $pick) { $pick = $first }
    if ($null -eq $pick) { return $null }
    return [string]$pick.definitionReference.version.name
}

<#
.SYNOPSIS
Shows what is deployed: for each environment of the matching release definitions, the latest succeeded deployment (Release, ArtifactVersion, Completed).
.DESCRIPTION
-Definition without wildcards matches names containing the text. Per environment an error is reported as 'error: HTTP n' and no deployment as 'none'. ArtifactVersion comes from the primary artifact (read from the deployment, else from the release; shape not verified on the real server).
.PARAMETER MaxDefinitions
Definitions inspected; 0 means the configured DeployedDefaultDefinitions, larger than DeployedMaxDefinitions is capped with a warning.
.EXAMPLE
Get-TfsDeployed -Definition billing -Environment 'Prod*'
#>
function Get-TfsDeployed {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Definition,
        [string]$Environment = '*',
        [int]$MaxDefinitions = 0
    )

    Assert-TfsConfig
    $max = $MaxDefinitions
    if ($max -le 0) { $max = [int]$script:Cfg.DeployedDefaultDefinitions }
    if ($max -gt $script:Cfg.DeployedMaxDefinitions) {
        Write-Warning "MaxDefinitions capped at $($script:Cfg.DeployedMaxDefinitions)"
        $max = [int]$script:Cfg.DeployedMaxDefinitions
    }
    $query = ''
    # The server search is a plain contains-match: send only the longest literal part; -like below stays the exact filter.
    $searchText = ($Definition -split '[*?]' | Sort-Object -Property Length -Descending | Select-Object -First 1)
    if ($searchText) { $query = 'searchText=' + [uri]::EscapeDataString($searchText) + '&' }
    $resp = Invoke-Tfs -Path ($script:Proj + '/_apis/release/definitions?' + $query + '$expand=environments')
    $pattern = $Definition
    if ($Definition -notmatch '[*?]') { $pattern = '*' + $Definition + '*' }
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($d in $resp.value) { if ($d.name -like $pattern) { $found.Add($d) } }
    if ($found.Count -eq 0) {
        Write-Warning "No release definition matches $Definition"
        return
    }
    if ($found.Count -gt $max) { Write-Warning "Definitions matched: $($found.Count); showing $max (raise -MaxDefinitions)" }
    $releaseCache = @{}
    foreach ($def in ($found | Sort-Object -Property name | Select-Object -First $max)) {
        foreach ($stage in $def.environments) {
            if ($stage.name -notlike $Environment) { continue }
            $defId = [long]$def.id
            $stageId = [long]$stage.id
            $row = [ordered]@{ Definition = $def.name; Environment = $stage.name; Release = 'none'; ArtifactVersion = ''; Completed = '' }
            try {
                $path = $script:Proj + '/_apis/release/deployments?definitionId=' + $defId + '&definitionEnvironmentId=' + $stageId + '&deploymentStatus=succeeded&$top=1'
                $latest = $null
                foreach ($x in (Invoke-Tfs -Path $path).value) { if ($null -eq $latest) { $latest = $x } }
                if ($null -ne $latest) {
                    $row.Release = $latest.release.name
                    $row.Completed = Format-TfsDate -Value $latest.completedOn
                    $version = Get-TfsArtifactVersion -Release $latest.release
                    if ($null -eq $version -and $latest.release.id) {
                        $releaseId = [long]$latest.release.id
                        if (-not $releaseCache.ContainsKey($releaseId)) {
                            # A failed fallback is cached as its error label, so it is shown and not retried for the same release.
                            try { $releaseCache[$releaseId] = Invoke-Tfs -Path ($script:Proj + '/_apis/release/releases/' + $releaseId) }
                            catch { $releaseCache[$releaseId] = 'error: ' + (Get-TfsErrorInfo -ErrorRecord $_).Label }
                        }
                        $cached = $releaseCache[$releaseId]
                        if ($cached -is [string]) { $version = $cached }
                        else { $version = Get-TfsArtifactVersion -Release $cached }
                    }
                    if ($null -ne $version) { $row.ArtifactVersion = $version }
                }
            }
            catch {
                $row.Release = 'error: ' + (Get-TfsErrorInfo -ErrorRecord $_).Label
                $row.ArtifactVersion = ''
                $row.Completed = ''
            }
            [pscustomobject]$row
        }
    }
}

#endregion Builds and releases

#region Summary and setup check

function Get-TfsSummarySection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][scriptblock]$Fetch)

    # One section never fails the whole summary: errors are reduced to a short label (HTTP n, NETWORK, PARSE, ...).
    try { $rows = @(& $Fetch) }
    catch { return @{ Count = 'error'; Value = ('error: ' + (Get-TfsErrorInfo -ErrorRecord $_).Label) } }
    if ($rows.Count -eq 0) { return @{ Count = 0; Value = 'none' } }
    return @{ Count = $rows.Count; Value = $rows }
}

<#
.SYNOPSIS
One-call morning overview: my open work items, builds that failed in the look-back window, and pending release approvals.
.DESCRIPTION
Counts come first (an int, or 'error'). Each section is a list of rows, 'none', or 'error: HTTP n' (or NETWORK, PARSE, REDIRECT, ERROR); a failing section does not affect the others. Approvals are not filtered to the current user (not verified on the real server).
.PARAMETER Hours
Look-back window for failed builds; 0 means the configured SummaryHours.
.EXAMPLE
Get-TfsDailySummary -Top 10
#>
function Get-TfsDailySummary {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int]$Top = 0,
        [int]$Hours = 0
    )

    Assert-TfsConfig
    $n = Get-TfsTop -Top $Top
    $window = $Hours
    if ($window -le 0) { $window = [int]$script:Cfg.SummaryHours }
    $since = ConvertTo-TfsUtcIso -Value ([datetime]::UtcNow.AddHours(-$window))

    $items = Get-TfsSummarySection -Fetch { Get-TfsMyItems -Top $n -WarningAction SilentlyContinue }
    $builds = Get-TfsSummarySection -Fetch {
        $path = $script:Proj + '/_apis/build/builds?resultFilter=failed&statusFilter=completed&minTime=' + $since + '&queryOrder=finishTimeDescending&$top=' + $n
        foreach ($b in (Invoke-Tfs -Path $path).value) {
            [pscustomobject][ordered]@{
                Id          = [int]$b.id
                Definition  = $b.definition.name
                BuildNumber = $b.buildNumber
                Branch      = Format-TfsRef -Ref $b.sourceBranch
                Finished    = Format-TfsDate -Value $b.finishTime
            }
        }
    }
    $approvals = Get-TfsSummarySection -Fetch {
        $path = $script:Proj + '/_apis/release/approvals?statusFilter=pending&$top=' + $n
        try { $resp = Invoke-Tfs -Path $path }
        catch {
            $info = Get-TfsErrorInfo -ErrorRecord $_
            if ($info.Kind -ne 'HTTP' -or $info.Code -ne 400) { throw }
            $resp = Invoke-Tfs -Path $path -Ver '6.0-preview.3'
        }
        foreach ($a in $resp.value) {
            [pscustomobject][ordered]@{
                Id          = [int]$a.id
                Release     = $a.release.name
                Environment = $a.releaseEnvironment.name
                Type        = $a.approvalType
            }
        }
    }
    [pscustomobject][ordered]@{
        Counts           = [pscustomobject][ordered]@{ MyItems = $items.Count; FailedBuilds = $builds.Count; PendingApprovals = $approvals.Count }
        MyItems          = $items.Value
        FailedBuilds     = $builds.Value
        PendingApprovals = $approvals.Value
    }
}

function Get-TfsAreaResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][scriptblock]$Probe
    )

    $result = 'PASS'
    $code = ''
    try {
        if (-not (& $Probe)) {
            $result = 'FAIL'
            $code = 'PARSE'
        }
    }
    catch {
        $result = 'FAIL'
        $info = Get-TfsErrorInfo -ErrorRecord $_
        if ($info.Kind -eq 'HTTP') { $code = $info.Code } else { $code = $info.Kind }
    }
    return [pscustomobject][ordered]@{ Area = $Area; Result = $result; Code = $code }
}

<#
.SYNOPSIS
First-run check of config, connectivity, authentication and read access. Prints Area, Result (PASS/FAIL/SKIP) and Code only.
.DESCRIPTION
Read-only apart from one small WIQL query. Never prints server, project, user or server messages, so the three-column table is safe to read aloud or retype. Code is empty, an HTTP status, CONFIG, NETWORK, PARSE, REDIRECT, TOOBIG or ERROR. After a Config failure or a network failure the remaining areas are SKIP.
.EXAMPLE
Test-TfsSetup
#>
function Test-TfsSetup {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $areas = @('Connectivity', 'Auth', 'Project', 'WIQL', 'Repos', 'Builds', 'Deployments')
    if ($script:ConfigError) {
        [pscustomobject][ordered]@{ Area = 'Config'; Result = 'FAIL'; Code = 'CONFIG' }
        foreach ($a in $areas) { [pscustomobject][ordered]@{ Area = $a; Result = 'SKIP'; Code = '' } }
        return
    }
    [pscustomobject][ordered]@{ Area = 'Config'; Result = 'PASS'; Code = '' }
    $proj = $script:Proj
    $probes = [ordered]@{
        Connectivity = { $r = Invoke-Tfs -Path '_apis/projects?$top=1'; $null -ne $r -and $r -isnot [string] }
        Auth         = { $r = Invoke-Tfs -Path '_apis/connectionData' -Ver '6.0-preview.1'; $null -ne $r -and $r -isnot [string] -and $null -ne $r.authenticatedUser.id }
        Project      = { $r = Invoke-Tfs -Path ('_apis/projects/' + [uri]::EscapeDataString($proj)); $null -ne $r -and $r -isnot [string] }
        WIQL         = {
            $q = 'SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.AssignedTo] = @Me'
            $r = Invoke-Tfs -Path ($proj + '/_apis/wit/wiql?$top=1') -Method POST -Body @{ query = $q }
            $null -ne $r -and $r -isnot [string]
        }
        Repos        = { $r = Invoke-Tfs -Path ($proj + '/_apis/git/repositories'); $null -ne $r -and $r -isnot [string] }
        Builds       = { $r = Invoke-Tfs -Path ($proj + '/_apis/build/builds?$top=1'); $null -ne $r -and $r -isnot [string] }
        Deployments  = { $r = Invoke-Tfs -Path ($proj + '/_apis/release/deployments?$top=1'); $null -ne $r -and $r -isnot [string] }
    }
    $skipRest = $false
    foreach ($name in $areas) {
        if ($skipRest) {
            [pscustomobject][ordered]@{ Area = $name; Result = 'SKIP'; Code = '' }
            continue
        }
        $row = Get-TfsAreaResult -Area $name -Probe $probes[$name]
        if ($name -eq 'Connectivity' -and $row.Code -eq 'NETWORK') { $skipRest = $true }
        $row
    }
}

#endregion Summary and setup check

#region Work item writes

function Invoke-TfsPatch {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Ops
    )

    # The ops go out as a real array (ToArray) so a single operation is still a JSON array.
    return Invoke-Tfs -Path $Path -Method $Method -Body $Ops.ToArray() -ContentType 'application/json-patch+json'
}

<#
.SYNOPSIS
Creates a work item. Dry run by default (validateOnly, nothing saved); -Commit really creates it and returns what was stored.
.DESCRIPTION
Fields are given by reference name (for example Microsoft.VSTS.Common.Priority). -ParentId links the new item to its parent. With -Commit the item is created only if ShouldProcess agrees (so -WhatIf still only validates). The safety protocol in SKILL.md (show the plan, wait for approval) still applies; this function cannot enforce it.
.EXAMPLE
New-TfsItem -Type Task -Title 'Write tests' -ParentId 1234
.EXAMPLE
New-TfsItem -Type Task -Title 'Write tests' -ParentId 1234 -Commit
#>
function New-TfsItem {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Type,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
        [hashtable]$Fields,
        [int]$ParentId,
        [switch]$Commit
    )

    Assert-TfsConfig
    $hasParent = $PSBoundParameters.ContainsKey('ParentId')
    $ops = New-Object System.Collections.Generic.List[object]
    $changes = New-Object System.Collections.Generic.List[object]
    $names = New-Object System.Collections.Generic.List[string]
    $ops.Add([ordered]@{ op = 'add'; path = '/fields/System.Title'; value = $Title })
    $changes.Add([pscustomobject][ordered]@{ Field = 'System.Title'; Old = $null; New = $Title })
    $names.Add('System.Title')
    if ($Fields) {
        foreach ($key in ($Fields.Keys | Sort-Object)) {
            if ($key -eq 'System.Title') { throw '-Fields must not contain System.Title; use -Title' }
            if ($null -eq $Fields[$key]) { throw "Field $key has no value; a null value is only meaningful in Set-TfsItem" }
            $ops.Add([ordered]@{ op = 'add'; path = '/fields/' + $key; value = $Fields[$key] })
            $changes.Add([pscustomobject][ordered]@{ Field = $key; Old = $null; New = $Fields[$key] })
            $names.Add([string]$key)
        }
    }
    if ($hasParent) {
        $parentUrl = $script:Base + '/_apis/wit/workItems/' + $ParentId
        $ops.Add([ordered]@{ op = 'add'; path = '/relations/-'; value = [ordered]@{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = $parentUrl } })
    }
    $createPath = $script:Proj + '/_apis/wit/workitems/$' + [uri]::EscapeDataString($Type)
    $null = Invoke-TfsPatch -Path ($createPath + '?validateOnly=true') -Method POST -Ops $ops

    $parentOut = $null
    if ($hasParent) { $parentOut = $ParentId }
    if (-not ($Commit -and $PSCmdlet.ShouldProcess("new $Type", 'Create work item'))) {
        $note = 'Nothing saved. Re-run with -Commit to create the item.'
        if ($Commit) { $note = 'WhatIf: nothing saved (the write was not confirmed).' }
        return [pscustomobject][ordered]@{
            Mode      = 'DryRun'
            Action    = 'Create'
            Target    = "new $Type"
            ParentId  = $parentOut
            Changes   = $changes.ToArray()
            Validated = $true
            Note      = $note
        }
    }
    $created = Invoke-TfsPatch -Path $createPath -Method POST -Ops $ops
    $id = [int]$created.id
    if ($hasParent) { $stored = Get-TfsItem -Id $id -Fields $names.ToArray() -Links }
    else { $stored = Get-TfsItem -Id $id -Fields $names.ToArray() }
    $storedFields = [ordered]@{}
    foreach ($name in $names) { $storedFields[$name] = $stored.PSObject.Properties[$name].Value }
    $storedParent = $null
    foreach ($rel in $stored.Relations) {
        if ($rel.Rel -eq 'System.LinkTypes.Hierarchy-Reverse') { $storedParent = $rel.TargetId }
    }
    [pscustomobject][ordered]@{
        Mode     = 'Committed'
        Id       = $id
        Type     = $stored.Type
        State    = $stored.State
        Title    = $stored.Title
        Stored   = [pscustomobject]$storedFields
        ParentId = $storedParent
    }
}

<#
.SYNOPSIS
Changes one work item. Dry run by default (shows old and new values, validateOnly); -Commit applies it and returns the stored values with a per-field Match.
.DESCRIPTION
-Fields maps reference names to new values; a $null value removes the field. -AddTag merges tags into the current ones. System.Tags in -Fields replaces the whole tag string. -ExpectedRev adds a test of the revision so a concurrent edit is rejected. One item per call. The safety protocol in SKILL.md (show the plan, wait for approval) still applies.
.EXAMPLE
Set-TfsItem -Id 1234 -Fields @{ 'System.State' = 'Active' }
.EXAMPLE
Set-TfsItem -Id 1234 -AddTag 'reviewed' -Commit
#>
function Set-TfsItem {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Id,
        [hashtable]$Fields,
        [string[]]$AddTag,
        [int]$ExpectedRev,
        [switch]$Commit
    )

    Assert-TfsConfig
    $keys = New-Object System.Collections.Generic.List[string]
    if ($Fields) { foreach ($key in ($Fields.Keys | Sort-Object)) { $keys.Add([string]$key) } }
    if ($keys.Count -eq 0 -and -not $AddTag) { throw 'Nothing to change: give -Fields or -AddTag' }
    if ($AddTag -and $keys -contains 'System.Tags') { throw 'Use either -AddTag or System.Tags in -Fields, not both' }
    $readNames = New-Object System.Collections.Generic.List[string]
    $readNames.AddRange($keys)
    if ($AddTag) { $readNames.Add('System.Tags') }
    $current = Get-TfsItem -Id $Id -Fields $readNames.ToArray()

    $ops = New-Object System.Collections.Generic.List[object]
    $changes = New-Object System.Collections.Generic.List[object]
    if ($PSBoundParameters.ContainsKey('ExpectedRev')) { $ops.Add([ordered]@{ op = 'test'; path = '/rev'; value = $ExpectedRev }) }
    foreach ($key in $keys) {
        $new = $Fields[$key]
        if ($null -eq $new) { $ops.Add([ordered]@{ op = 'remove'; path = '/fields/' + $key }) }
        else { $ops.Add([ordered]@{ op = 'add'; path = '/fields/' + $key; value = $new }) }
        $changes.Add([pscustomobject][ordered]@{ Field = $key; Old = $current.PSObject.Properties[$key].Value; New = $new })
    }
    if ($AddTag) {
        $tags = New-Object System.Collections.Generic.List[string]
        foreach ($t in ([string]$current.Tags -split ';')) { if ($t.Trim()) { $tags.Add($t.Trim()) } }
        $added = $false
        foreach ($t in $AddTag) {
            if ($t.Trim() -and $tags -notcontains $t.Trim()) {
                $tags.Add($t.Trim())
                $added = $true
            }
        }
        if ($added) {
            $merged = $tags -join '; '
            $ops.Add([ordered]@{ op = 'add'; path = '/fields/System.Tags'; value = $merged })
            $changes.Add([pscustomobject][ordered]@{ Field = 'System.Tags'; Old = $current.Tags; New = $merged })
        }
    }

    $target = "workitem ${Id}: $($current.Title)"
    $tagNote = ''
    if ($keys -contains 'System.Tags') { $tagNote = ' System.Tags in -Fields replaces the whole tag string; use -AddTag to add tags.' }
    if ($changes.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Mode = 'NoChange'; Action = 'Update'; Target = $target; Rev = $current.Rev; Changes = @(); Validated = $false
            Note = 'Nothing to change: all tags are already present.'
        }
    }
    $patchPath = '_apis/wit/workitems/' + $Id
    $null = Invoke-TfsPatch -Path ($patchPath + '?validateOnly=true') -Method PATCH -Ops $ops
    if (-not ($Commit -and $PSCmdlet.ShouldProcess("workitem $Id", 'Update work item'))) {
        $note = 'Nothing saved. Re-run with -Commit to apply.'
        if ($Commit) { $note = 'WhatIf: nothing saved (the write was not confirmed).' }
        return [pscustomobject][ordered]@{
            Mode = 'DryRun'; Action = 'Update'; Target = $target; Rev = $current.Rev; Changes = $changes.ToArray(); Validated = $true
            Note = $note + $tagNote
        }
    }
    $null = Invoke-TfsPatch -Path $patchPath -Method PATCH -Ops $ops
    $after = Get-TfsItem -Id $Id -Fields $readNames.ToArray()
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($c in $changes) {
        $stored = $after.PSObject.Properties[$c.Field].Value
        $result.Add([pscustomobject][ordered]@{
                Field = $c.Field; Old = $c.Old; New = $c.New; Stored = $stored
                Match = ([string]$stored -ceq [string]$c.New)
            })
    }
    [pscustomobject][ordered]@{
        Mode = 'Committed'; Action = 'Update'; Target = $target; Rev = $after.Rev; Changes = $result.ToArray(); Validated = $true
        Note = 'Saved. Stored is what was read back after the write.' + $tagNote
    }
}

#endregion Work item writes

#region Work item tree

<#
.SYNOPSIS
Shows the work item hierarchy below one item (children, grandchildren, ...): Id, ParentId, Level, Type, State, Title; or counts by state with -Summary.
.DESCRIPTION
Runs a recursive WorkItemLinks query (Hierarchy-Forward) and then fetches the fields in batches. The root is level 0. -Id must be an integer work item id (never a 'project\id' string). Rows follow the server order; levels are computed from the parent links. -Top limits the number of rows (0 means the configured DefaultTop, capped at MaxTop with a warning).
.PARAMETER Depth
Deepest level to keep; 0 (default) keeps every level.
.PARAMETER Summary
Return one object (Total, ByState) instead of the rows.
.EXAMPLE
Get-TfsTree -Id 1234 -Depth 2
.EXAMPLE
Get-TfsTree -Id 1234 -Summary
#>
function Get-TfsTree {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$Id,
        [ValidateRange(0, 100)][int]$Depth = 0,
        [int]$Top = 0,
        [switch]$Summary
    )

    Assert-TfsConfig
    $n = Get-TfsTop -Top $Top
    $idText = $Id.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $query = 'SELECT [System.Id] FROM WorkItemLinks WHERE [Source].[System.Id] = ' + $idText + " AND [System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward' MODE (Recursive)"
    $resp = Invoke-Tfs -Path ($script:Proj + '/_apis/wit/wiql?$top=' + $n) -Method POST -Body @{ query = $query }

    $parentOf = @{}
    $order = New-Object System.Collections.Generic.List[int]
    foreach ($rel in $resp.workItemRelations) {
        $target = [int]$rel.target.id
        if ($order.Contains($target)) { continue }
        $order.Add($target)
        if ($null -ne $rel.source) { $parentOf[$target] = [int]$rel.source.id }
    }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($itemId in $order) {
        $level = 0
        $cursor = $itemId
        while ($parentOf.ContainsKey($cursor) -and $level -lt 100) {
            $cursor = $parentOf[$cursor]
            $level++
        }
        if ($Depth -gt 0 -and $level -gt $Depth) { continue }
        $parentValue = $null
        if ($parentOf.ContainsKey($itemId)) { $parentValue = $parentOf[$itemId] }
        $entries.Add(@{ Id = $itemId; ParentId = $parentValue; Level = $level })
    }
    $kept = @($entries | Select-Object -First $n)
    if ($kept.Count -eq 0) { return }

    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($e in $kept) { $ids.Add([int]$e.Id) }
    $byId = @{}
    foreach ($wi in (Get-TfsBatch -Ids $ids.ToArray() -Fields @('System.Id', 'System.WorkItemType', 'System.State', 'System.Title'))) { $byId[[int]$wi.id] = $wi }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $kept) {
        $fields = $null
        if ($byId.ContainsKey([int]$e.Id)) { $fields = $byId[[int]$e.Id].fields }
        $rows.Add([pscustomobject][ordered]@{
                Id       = [int]$e.Id
                ParentId = $e.ParentId
                Level    = [int]$e.Level
                Type     = $fields.'System.WorkItemType'
                State    = $fields.'System.State'
                Title    = $fields.'System.Title'
            })
    }
    if (-not $Summary) { return $rows.ToArray() }
    $byState = New-Object System.Collections.Generic.List[object]
    $groups = $rows | Group-Object -Property State | Sort-Object -Property @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false }
    foreach ($g in $groups) { $byState.Add([pscustomobject][ordered]@{ State = [string]$g.Name; Count = $g.Count }) }
    [pscustomobject][ordered]@{ Total = $rows.Count; ByState = $byState.ToArray() }
}

#endregion Work item tree

if ($PSVersionTable.PSVersion.Major -le 5) {
    # Windows PowerShell 5.1 may default to old TLS versions; only ever add TLS 1.2.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}
try {
    # Hebrew output reads correctly only with a UTF-8 console encoding (no BOM); do not use chcp for this.
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch { Write-Verbose 'Console output encoding could not be set' }
Import-TfsConfig

Export-ModuleMember -Function Invoke-Tfs, Get-TfsMyItems, Get-TfsItem, Find-TfsRepo, Get-TfsPR, Get-TfsCommits, Get-TfsBuildFailure, Get-TfsDeployed, Get-TfsDailySummary, Test-TfsSetup, New-TfsItem, Set-TfsItem, Get-TfsTree
