# Sql.psm1: read-mostly SQL Server access (queries, schema, performance diagnostics, guarded INSERT/UPDATE and stored procedure calls) through System.Data.SqlClient with Windows integrated auth for Windows PowerShell 5.1; the connection comes from the project's appsettings.Development.json.

$script:DefaultTop = 20
$script:MaxTop = 200
$script:MaxCell = 200
$script:CmdTimeoutSec = 30
$script:ConnectTimeoutSec = 15
$script:LockTimeoutMs = 5000
$script:MaxDefinition = 8000
$script:MaxResultSets = 5
$script:MaxWriteRows = 10000
$script:MaxLineChars = 4000
$script:AppName = 'claude-sql-access'
$script:SettingsFileName = 'appsettings.Development.json'
$script:DiscoveryDepth = 3
$script:SkipFolders = @('bin', 'obj', 'node_modules', '.git')
$script:SecretColumnPattern = '(?i)password|passwd|pwd|secret|token|hash|key'
$script:Secrets = @{}

#region Errors and masking

function Register-SqlSecret {
    [CmdletBinding()]
    [OutputType([void])]
    param([AllowNull()][AllowEmptyString()][string]$Value, [Parameter(Mandatory)][string]$Placeholder)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Trim().Length -lt 2) { return }
    $script:Secrets[$Value.Trim()] = $Placeholder
}

function Hide-SqlSecret {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text, [switch]$Cell, [int]$MaxChars = 0)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($MaxChars -le 0) { $MaxChars = $script:MaxLineChars }
    # Bound the regex work first, but keep 256 spare characters so a name that straddles the final cut is still masked.
    $t = $Text
    if ($t.Length -gt ($MaxChars + 256)) { $t = $t.Substring(0, $MaxChars + 256) }
    $keys = @($script:Secrets.Keys | Sort-Object -Property Length -Descending)
    foreach ($key in $keys) {
        $placeholder = [string]$script:Secrets[$key]
        if ($Cell) {
            # In data cells only whole words of 4 or more characters are masked, so short names do not garble ordinary text.
            if ($key.Length -lt 4) { continue }
            $t = [regex]::Replace($t, '(?<!\w)' + [regex]::Escape($key) + '(?!\w)', $placeholder, 'IgnoreCase')
        }
        else {
            $t = [regex]::Replace($t, [regex]::Escape($key), $placeholder, 'IgnoreCase')
        }
    }
    $t = [regex]::Replace($t, '://[^/\s:@]+:[^@\s]+@', '://***@')
    $t = [regex]::Replace($t, 'eyJ[\w-]+\.[\w-]+\.[\w-]+', '***')
    $t = [regex]::Replace($t, '(?i)bearer\s+\S+', 'Bearer ***')
    $t = [regex]::Replace($t, '(?i)\bbasic\s+[A-Za-z0-9+/=]{8,}', 'Basic ***')
    $t = [regex]::Replace($t, '(?i)(password|passwd|pwd|secret|token|api[_-]?key|accesskey|connectionstring|authorization)\s*[:=]\s*("[^"]*"|''[^'']*''|[^\s;,]+)', '$1=***')
    $t = [regex]::Replace($t, '\b[a-z0-9]{52}\b', '***')
    if ($t.Length -gt $MaxChars) { $t = $t.Substring(0, $MaxChars) + '...[truncated]' }
    return $t
}

function Get-SqlException {
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$Number = 0,
        [Parameter(Mandatory)][string]$Kind
    )

    $oneLine = [regex]::Replace($Message, '\s*[\r\n]+\s*', ' ')
    $ex = New-Object System.Exception(('SQL ' + $Number + ' :: ' + (Hide-SqlSecret -Text $oneLine)))
    $ex.Data['Number'] = $Number
    $ex.Data['Kind'] = $Kind
    return $ex
}

function ConvertTo-SqlError {
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)][ValidateSet('Open', 'Exec')][string]$Phase
    )

    # One mapping for every failure: our own exceptions pass through; a server error is found by its Number (also on inner exceptions).
    $number = $null
    $source = $null
    $cur = $ErrorRecord.Exception
    for ($i = 0; $i -lt 6 -and $null -ne $cur; $i++) {
        if ($cur.Data.Contains('Kind')) { return $cur }
        $prop = $cur.PSObject.Properties['Number']
        if ($null -eq $number -and $null -ne $prop -and $null -ne $prop.Value) {
            $number = [int]$prop.Value
            $source = $cur
        }
        $cur = $cur.InnerException
    }
    $n = 0
    $text = $ErrorRecord.Exception.Message
    if ($null -ne $number) {
        $n = $number
        $text = $source.Message
    }
    if ($Phase -eq 'Open') {
        if (@(18456, 18452, 4060) -contains $n) {
            return Get-SqlException -Message 'Login failed: the server rejected Windows authentication for the current user' -Number $n -Kind 'AUTH'
        }
        return Get-SqlException -Message 'Cannot connect to the SQL Server (not reachable, wrong server name, or the connection was refused)' -Number $n -Kind 'CONNECT'
    }
    $kind = 'SQL'
    if ($null -eq $number) { $kind = 'ERROR' }
    elseif (@(-2, 1222) -contains $n) { $kind = 'TIMEOUT' }
    elseif (@(229, 230, 262, 297, 300) -contains $n) { $kind = 'DENIED' }
    elseif (@(266, 3902, 3903) -contains $n) { $kind = 'TXN' }
    return Get-SqlException -Message $text -Number $n -Kind $kind
}

function Get-SqlTop {
    [CmdletBinding()]
    [OutputType([int])]
    param([int]$Top = 0)

    if ($Top -le 0) { return [int]$script:DefaultTop }
    if ($Top -gt $script:MaxTop) {
        Write-Warning "Top capped at $($script:MaxTop)"
        return [int]$script:MaxTop
    }
    return $Top
}

#endregion Errors and masking

#region Connection source

function Clear-SqlJsonComment {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    # Windows PowerShell 5.1 ConvertFrom-Json rejects comments and trailing commas that .NET configuration files allow, so strip them here (string-aware).
    $sb = New-Object System.Text.StringBuilder
    $n = $Text.Length
    $i = 0
    $inString = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq [char]'\' -and ($i + 1) -lt $n) {
                [void]$sb.Append($Text[$i + 1])
                $i += 2
                continue
            }
            if ($c -eq [char]'"') { $inString = $false }
            $i++
            continue
        }
        if ($c -eq [char]'"') {
            $inString = $true
            [void]$sb.Append($c)
            $i++
            continue
        }
        if ($c -eq [char]'/' -and ($i + 1) -lt $n) {
            $d = $Text[$i + 1]
            if ($d -eq [char]'/') {
                while ($i -lt $n -and $Text[$i] -ne [char]"`n") { $i++ }
                continue
            }
            if ($d -eq [char]'*') {
                $end = $Text.IndexOf('*/', $i + 2)
                if ($end -lt 0) { $i = $n } else { $i = $end + 2 }
                [void]$sb.Append(' ')
                continue
            }
        }
        [void]$sb.Append($c)
        $i++
    }
    $noComments = $sb.ToString()

    $out = New-Object System.Text.StringBuilder
    $n = $noComments.Length
    $inString = $false
    for ($i = 0; $i -lt $n; $i++) {
        $c = $noComments[$i]
        if ($inString) {
            [void]$out.Append($c)
            if ($c -eq [char]'\' -and ($i + 1) -lt $n) {
                $i++
                [void]$out.Append($noComments[$i])
            }
            elseif ($c -eq [char]'"') { $inString = $false }
            continue
        }
        if ($c -eq [char]'"') { $inString = $true }
        if ($c -eq [char]',') {
            $j = $i + 1
            while ($j -lt $n -and [char]::IsWhiteSpace($noComments[$j])) { $j++ }
            if ($j -lt $n -and ($noComments[$j] -eq [char]'}' -or $noComments[$j] -eq [char]']')) { continue }
        }
        [void]$out.Append($c)
    }
    return $out.ToString()
}

function Assert-SqlRelativePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Path)

    $problem = $null
    $p = ''
    if ([string]::IsNullOrWhiteSpace($Path)) { $problem = 'path is empty' }
    else {
        $p = $Path.Trim().Replace('\', '/')
        if ($p.StartsWith('/')) { $problem = 'path must be relative (no leading slash, no UNC path)' }
        elseif ($p.Contains(':')) { $problem = 'path must be relative (no drive letter)' }
        elseif (@($p.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0) { $problem = "path must not contain '..'" }
        elseif ($p.Split('/')[-1] -ine $script:SettingsFileName) { $problem = "file name must be exactly $($script:SettingsFileName)" }
    }
    if ($problem) { throw (Get-SqlException -Message "Config: -Path refused: $problem" -Kind 'CONFIG') }
    return $p
}

function Find-SqlAppSettings {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Path)

    $root = (Get-Location).ProviderPath
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $rel = Assert-SqlRelativePath -Path $Path
        $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $rel.Replace('/', $sep)))
        if (-not [System.IO.File]::Exists($full)) { throw (Get-SqlException -Message "Config: file not found: $rel" -Kind 'CONFIG') }
        return $full
    }
    $trimmedRoot = $root.TrimEnd([char[]]'\/')
    $found = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@{ Dir = $root; Depth = 0 })
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $candidate = [System.IO.Path]::Combine($item.Dir, $script:SettingsFileName)
        if ([System.IO.File]::Exists($candidate)) { $found.Add($candidate) }
        if ($item.Depth -ge $script:DiscoveryDepth) { continue }
        $subs = @()
        try { $subs = @([System.IO.Directory]::GetDirectories($item.Dir)) }
        catch { Write-Verbose 'Folder could not be listed' }
        foreach ($d in ($subs | Sort-Object)) {
            if ($script:SkipFolders -contains [System.IO.Path]::GetFileName($d)) { continue }
            $queue.Enqueue(@{ Dir = $d; Depth = $item.Depth + 1 })
        }
    }
    if ($found.Count -eq 0) {
        throw (Get-SqlException -Message "Config: no $($script:SettingsFileName) found in the current folder or up to $($script:DiscoveryDepth) levels below it" -Kind 'CONFIG')
    }
    $relative = @($found | ForEach-Object { $_.Substring($trimmedRoot.Length).TrimStart([char[]]'\/').Replace('\', '/') } | Sort-Object)
    if ($found.Count -gt 1) {
        $shown = ($relative | Select-Object -First 10) -join ', '
        throw (Get-SqlException -Message "Config: $($found.Count) files match: $shown. Pass -Path with one of them" -Kind 'CONFIG')
    }
    return $found[0]
}

function Assert-SqlEntryName {
    [CmdletBinding()]
    [OutputType([void])]
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return }
    if ($Name -notmatch '^[A-Za-z0-9_.\-]+$') {
        throw (Get-SqlException -Message 'Config: -Name may only contain letters, digits, _, - and .' -Kind 'CONFIG')
    }
}

function Read-SqlAppSettings {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$File, [AllowNull()][string]$Name)

    $text = $null
    try { $text = [System.IO.File]::ReadAllText($File, (New-Object System.Text.UTF8Encoding($false))) }
    catch { throw (Get-SqlException -Message 'Config: the settings file cannot be read' -Kind 'CONFIG') }
    $text = $text.TrimStart([char]0xFEFF)
    $doc = $null
    try { $doc = (Clear-SqlJsonComment -Text $text) | ConvertFrom-Json }
    catch { throw (Get-SqlException -Message 'Config: the settings file is not valid JSON (comments and trailing commas are tolerated)' -Kind 'CONFIG') }
    $section = $null
    if ($null -ne $doc -and $doc.PSObject.Properties['ConnectionStrings']) { $section = $doc.PSObject.Properties['ConnectionStrings'].Value }
    $entries = @()
    if ($section -is [pscustomobject]) { $entries = @($section.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' }) }
    if ($entries.Count -eq 0) {
        throw (Get-SqlException -Message 'Config: the settings file has no ConnectionStrings entries' -Kind 'CONFIG')
    }
    $names = ($entries | ForEach-Object { $_.Name }) -join ', '
    $chosen = $null
    if (-not [string]::IsNullOrEmpty($Name)) {
        $chosen = $entries | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
        if ($null -eq $chosen) { throw (Get-SqlException -Message "Config: no ConnectionStrings entry named $Name; available: $names" -Kind 'CONFIG') }
    }
    elseif ($entries.Count -eq 1) { $chosen = $entries[0] }
    else { throw (Get-SqlException -Message "Config: several ConnectionStrings entries, pass -Name with one of: $names" -Kind 'CONFIG') }
    if ($chosen.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($chosen.Value)) {
        throw (Get-SqlException -Message "Config: entry $($chosen.Name) is not a connection string" -Kind 'CONFIG')
    }
    return [string]$chosen.Value
}

function ConvertTo-SqlConnectionString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Raw)

    $script:Secrets.Clear()
    $invalid = 'Config: the connection string is not valid'
    $loose = New-Object System.Data.Common.DbConnectionStringBuilder
    try { $loose.set_ConnectionString($Raw) }
    catch { throw (Get-SqlException -Message $invalid -Kind 'CONFIG') }
    $credentialKeys = @('userid', 'uid', 'user', 'password', 'pwd', 'authentication')
    foreach ($key in @($loose.get_Keys())) {
        $k = ([string]$key).ToLowerInvariant() -replace '[\s_]', ''
        if ($credentialKeys -contains $k) {
            throw (Get-SqlException -Message 'Config: the connection string sets credentials or an authentication mode; only Windows integrated authentication is allowed' -Kind 'CONFIG')
        }
        if ($k -eq 'integratedsecurity' -or $k -eq 'trustedconnection') {
            if (@('true', 'yes', 'sspi') -notcontains ([string]$loose[$key]).Trim().ToLowerInvariant()) {
                throw (Get-SqlException -Message 'Config: the connection string turns integrated security off; only Windows integrated authentication is allowed' -Kind 'CONFIG')
            }
        }
    }
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    try { $b.set_ConnectionString($Raw) }
    catch { throw (Get-SqlException -Message $invalid -Kind 'CONFIG') }
    # The indexer is used on purpose: the PowerShell dictionary adapter turns property assignments into keyword lookups that fail.
    $b['Integrated Security'] = 'SSPI'
    $b['Connect Timeout'] = $script:ConnectTimeoutSec
    $b['Application Name'] = $script:AppName
    $b['Pooling'] = $false
    $b['MultipleActiveResultSets'] = $false
    $source = [string]$b['Data Source']
    Register-SqlSecret -Value $source -Placeholder '<server>'
    $short = $source -replace '^(?i)(tcp|np|lpc|admin):', '' -replace ',\d+$', ''
    Register-SqlSecret -Value $short -Placeholder '<server>'
    foreach ($part in ($short -split '\\')) { Register-SqlSecret -Value $part -Placeholder '<server>' }
    Register-SqlSecret -Value ([string]$b['Initial Catalog']) -Placeholder '<database>'
    return $b.get_ConnectionString()
}

function Resolve-SqlConnection {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Path, [AllowNull()][string]$Name)

    Assert-SqlEntryName -Name $Name
    $file = Find-SqlAppSettings -Path $Path
    return ConvertTo-SqlConnectionString -Raw (Read-SqlAppSettings -File $file -Name $Name)
}

#endregion Connection source

#region SqlClient seam

function Open-SqlConnection {
    [CmdletBinding()]
    [OutputType([System.Data.SqlClient.SqlConnection])]
    param([Parameter(Mandatory)][string]$ConnectionString)

    # Tests replace this function; it must stay free of logic besides the error mapping.
    $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try { $conn.Open() }
    catch {
        $conn.Dispose()
        throw (ConvertTo-SqlError -ErrorRecord $_ -Phase 'Open')
    }
    return $conn
}

function Close-SqlConnection {
    [CmdletBinding()]
    [OutputType([void])]
    param($Connection)

    if ($null -eq $Connection) { return }
    try {
        $Connection.Close()
        $Connection.Dispose()
    }
    catch { Write-Verbose 'Closing the connection failed' }
}

function Invoke-SqlBatch {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][System.Data.SqlClient.SqlCommand]$Command,
        [int]$MaxRows = 20,
        [int]$StopAfter = 0,
        [int]$MaxSets = 1,
        [switch]$CancelOnMore
    )

    # Tests replace this function. It runs one command and reads at most MaxSets result sets; reads cancel the rest when the row cap was hit, writes never cancel.
    $Command.Connection = $Connection
    $sets = New-Object System.Collections.Generic.List[object]
    $moreSets = $false
    $reader = $Command.ExecuteReader()
    try {
        while ($true) {
            $set = Read-SqlResultSet -Reader $reader -MaxRows $MaxRows -StopAfter $StopAfter
            $sets.Add($set)
            if ($set.More) {
                if ($CancelOnMore) { $Command.Cancel() }
                break
            }
            if (-not $reader.NextResult()) { break }
            if ($sets.Count -ge $MaxSets) {
                $moreSets = $true
                break
            }
        }
    }
    finally { $reader.Dispose() }
    $returnValue = $null
    if ($Command.Parameters.Contains('@__sa_ret')) { $returnValue = $Command.Parameters['@__sa_ret'].Value }
    return [pscustomobject]@{ Sets = $sets.ToArray(); RecordsAffected = $reader.RecordsAffected; ReturnValue = $returnValue; MoreSets = $moreSets }
}

function Get-SqlUniqueName {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Name)

    # Empty names become Column<position>; repeated names (compared ignoring case) get _2, _3 so every column can become a property.
    $seen = @{}
    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Name.Count; $i++) {
        $n = $Name[$i]
        if ([string]::IsNullOrWhiteSpace($n)) { $n = 'Column' + ($i + 1) }
        $base = $n
        $k = 2
        while ($seen.ContainsKey($n)) {
            $n = $base + '_' + $k
            $k++
        }
        $seen[$n] = $true
        $result.Add($n)
    }
    return , $result.ToArray()
}

function Read-SqlResultSet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Data.IDataReader]$Reader,
        [int]$MaxRows = 20,
        [int]$StopAfter = 0
    )

    $count = $Reader.FieldCount
    $raw = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $count; $i++) { $raw.Add([string]$Reader.GetName($i)) }
    $names = Get-SqlUniqueName -Name $raw.ToArray()
    $rows = New-Object System.Collections.Generic.List[object]
    $total = 0
    $more = $false
    while ($Reader.Read()) {
        $total++
        if ($StopAfter -gt 0 -and $total -gt $StopAfter) {
            $more = $true
            break
        }
        if ($rows.Count -lt $MaxRows) {
            $values = New-Object object[] $count
            [void]$Reader.GetValues($values)
            $rows.Add($values)
        }
    }
    return [pscustomobject]@{ Columns = $names; Rows = $rows.ToArray(); TotalRows = $total; More = $more; Cut = ($rows.Count -lt $total) }
}

function Get-SqlCommandObject {
    [CmdletBinding()]
    [OutputType([System.Data.SqlClient.SqlCommand])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [System.Data.CommandType]$CommandType = [System.Data.CommandType]::Text,
        [hashtable]$Parameters,
        [int]$TimeoutSec = 30
    )

    $cmd = New-Object System.Data.SqlClient.SqlCommand
    $cmd.CommandText = $Text
    $cmd.CommandType = $CommandType
    $cmd.CommandTimeout = $TimeoutSec
    if ($null -ne $Parameters) {
        foreach ($key in $Parameters.Keys) {
            $raw = [string]$key
            if ($raw -notmatch '^@?[A-Za-z_]\w*$' -or $raw.TrimStart('@') -like '__sa_*') {
                throw (Get-SqlException -Message 'Parameter names must look like name or @name (letters, digits, _) and must not start with __sa_' -Kind 'REFUSED')
            }
            $name = '@' + $raw.TrimStart('@')
            $value = $Parameters[$key]
            if ($value -is [System.Data.SqlClient.SqlParameter]) {
                $value.ParameterName = $name
                [void]$cmd.Parameters.Add($value)
                continue
            }
            if ($null -eq $value) { $value = [System.DBNull]::Value }
            elseif (-not ($value -is [string] -or $value -is [byte[]] -or $value.GetType().IsValueType)) {
                throw (Get-SqlException -Message "Parameter $name must be a single value (text, number, date, guid, bytes) or a SqlParameter" -Kind 'REFUSED')
            }
            [void]$cmd.Parameters.AddWithValue($name, $value)
        }
    }
    if ($CommandType -eq [System.Data.CommandType]::StoredProcedure) {
        $ret = $cmd.Parameters.Add('@__sa_ret', [System.Data.SqlDbType]::Int)
        $ret.Direction = [System.Data.ParameterDirection]::ReturnValue
    }
    return $cmd
}

function Invoke-SqlStep {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$Parameters,
        [System.Data.CommandType]$CommandType = [System.Data.CommandType]::Text,
        [int]$MaxRows = 1,
        [int]$StopAfter = 0,
        [int]$MaxSets = 1,
        [switch]$CancelOnMore
    )

    # One batch through the seam; every failure leaves as a module exception.
    $cmd = Get-SqlCommandObject -Text $Text -CommandType $CommandType -Parameters $Parameters -TimeoutSec $script:CmdTimeoutSec
    try { return (Invoke-SqlBatch -Connection $Connection -Command $cmd -MaxRows $MaxRows -StopAfter $StopAfter -MaxSets $MaxSets -CancelOnMore:$CancelOnMore) }
    catch { throw (ConvertTo-SqlError -ErrorRecord $_ -Phase 'Exec') }
    finally { $cmd.Dispose() }
}

function Invoke-SqlRead {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$Parameters,
        [int]$MaxRows = 20,
        [AllowNull()][string]$Path,
        [AllowNull()][string]$Name
    )

    # One read: resolve the connection, run with a short lock timeout, read only MaxRows rows, always close.
    $conn = Open-SqlConnection -ConnectionString (Resolve-SqlConnection -Path $Path -Name $Name)
    try {
        $run = Invoke-SqlStep -Connection $conn -Text ('SET LOCK_TIMEOUT ' + $script:LockTimeoutMs + ";`n" + $Text) -Parameters $Parameters -MaxRows $MaxRows -StopAfter $MaxRows -MaxSets 1 -CancelOnMore
    }
    finally { Close-SqlConnection -Connection $conn }
    return $run.Sets[0]
}

function ConvertTo-SqlCell {
    [CmdletBinding()]
    [OutputType([object], [string])]
    param([AllowNull()]$Value, [Parameter(Mandatory)][string]$Column)

    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $null }
    if ($Column -match $script:SecretColumnPattern) { return '***' }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [byte[]]) { return '<binary ' + $Value.Length + ' bytes>' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss', $invariant) }
    if ($Value -is [datetimeoffset]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss zzz', $invariant) }
    if ($Value -is [guid] -or $Value -is [timespan]) { return $Value.ToString() }
    if ($Value -is [string]) {
        # Mask first, then truncate: a name that straddles the cut must not stay half visible.
        $text = Hide-SqlSecret -Text $Value -Cell
        if ($text.Length -gt $script:MaxCell) { $text = $text.Substring(0, $script:MaxCell) + '...' }
        return $text
    }
    return $Value
}

function ConvertTo-SqlRowObject {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Set)

    foreach ($row in $Set.Rows) {
        $h = [ordered]@{}
        for ($i = 0; $i -lt $Set.Columns.Count; $i++) {
            $h[$Set.Columns[$i]] = ConvertTo-SqlCell -Value $row[$i] -Column $Set.Columns[$i]
        }
        [pscustomobject]$h
    }
}

function Write-SqlCutWarning {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)]$Set, [Parameter(Mandatory)][int]$Limit)

    if ($Set.More) { Write-Warning "Rows cut: showing the first $Limit, more rows exist (raise -Top, maximum $($script:MaxTop))" }
    elseif ($Set.Cut) { Write-Warning "Rows cut: showing the first $Limit of $($Set.TotalRows)" }
}

#endregion SqlClient seam

#region Statement validation

$script:QueryRefused = @('INTO', 'EXEC', 'EXECUTE', 'OPENROWSET', 'OPENQUERY', 'OPENDATASOURCE', 'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'DROP', 'ALTER', 'CREATE', 'TRUNCATE', 'GRANT', 'REVOKE', 'DENY', 'DECLARE', 'SET', 'USE', 'DBCC', 'BACKUP', 'RESTORE', 'KILL', 'SHUTDOWN', 'WAITFOR', 'BULK', 'GO')
$script:WriteRefused = $script:QueryRefused + @('OUTPUT')

function Get-SqlToken {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Sql)

    # A small T-SQL lexer, not a parser: it only has to tell words from strings, quoted names and comments, and track parenthesis depth.
    $tokens = New-Object System.Collections.Generic.List[object]
    $n = $Sql.Length
    $i = 0
    $depth = 0
    while ($i -lt $n) {
        $c = $Sql[$i]
        $next = [char]0
        if ($i + 1 -lt $n) { $next = $Sql[$i + 1] }
        if ([char]::IsWhiteSpace($c)) {
            $i++
            continue
        }
        $start = $i
        if ($c -eq [char]'-' -and $next -eq [char]'-') {
            while ($i -lt $n -and $Sql[$i] -ne [char]"`n") { $i++ }
            continue
        }
        if ($c -eq [char]'/' -and $next -eq [char]'*') {
            $level = 1
            $i += 2
            while ($i -lt $n -and $level -gt 0) {
                if ($Sql[$i] -eq [char]'/' -and $i + 1 -lt $n -and $Sql[$i + 1] -eq [char]'*') {
                    $level++
                    $i += 2
                }
                elseif ($Sql[$i] -eq [char]'*' -and $i + 1 -lt $n -and $Sql[$i + 1] -eq [char]'/') {
                    $level--
                    $i += 2
                }
                else { $i++ }
            }
            if ($level -gt 0) { throw (Get-SqlException -Message 'Statement refused: unterminated comment' -Kind 'REFUSED') }
            continue
        }
        $type = $null
        $text = $null
        if ($c -eq [char]"'" -or (($c -eq [char]'N' -or $c -eq [char]'n') -and $next -eq [char]"'")) {
            if ($c -ne [char]"'") { $i++ }
            $i++
            $type = 'String'
            $text = Read-SqlQuoted -Sql $Sql -Index ([ref]$i) -Close ([char]"'") -What 'string'
        }
        elseif ($c -eq [char]'[') {
            $i++
            $type = 'Bracket'
            $text = Read-SqlQuoted -Sql $Sql -Index ([ref]$i) -Close ([char]']') -What 'bracketed name'
        }
        elseif ($c -eq [char]'"') {
            $i++
            $type = 'Quoted'
            $text = Read-SqlQuoted -Sql $Sql -Index ([ref]$i) -Close ([char]'"') -What 'quoted name'
        }
        elseif ($c -eq [char]'@') {
            $i++
            if ($i -lt $n -and $Sql[$i] -eq [char]'@') { $i++ }
            while ($i -lt $n -and ([char]::IsLetterOrDigit($Sql[$i]) -or '_#$@'.Contains([string]$Sql[$i]))) { $i++ }
            $type = 'Var'
            $text = $Sql.Substring($start, $i - $start)
        }
        elseif ([char]::IsDigit($c)) {
            while ($i -lt $n -and ([char]::IsLetterOrDigit($Sql[$i]) -or $Sql[$i] -eq [char]'.')) { $i++ }
            $type = 'Number'
            $text = $Sql.Substring($start, $i - $start)
        }
        elseif ([char]::IsLetter($c) -or $c -eq [char]'_' -or $c -eq [char]'#') {
            $i++
            while ($i -lt $n -and ([char]::IsLetterOrDigit($Sql[$i]) -or '_#$@'.Contains([string]$Sql[$i]))) { $i++ }
            $type = 'Word'
            $text = $Sql.Substring($start, $i - $start)
        }
        else {
            $i++
            $type = 'Symbol'
            $text = [string]$c
        }
        $tokenDepth = $depth
        if ($type -eq 'Symbol' -and $text -eq '(') { $depth++ }
        elseif ($type -eq 'Symbol' -and $text -eq ')') {
            if ($depth -gt 0) { $depth-- }
            $tokenDepth = $depth
        }
        $tokens.Add([pscustomobject]@{ Type = $type; Text = $text; Upper = $text.ToUpperInvariant(); Depth = $tokenDepth; Start = $start; End = $i })
    }
    return , $tokens.ToArray()
}

function Read-SqlQuoted {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][ref]$Index,
        [Parameter(Mandatory)][char]$Close,
        [Parameter(Mandatory)][string]$What
    )

    # Reads up to the closing character; a doubled closing character is an escaped one. $Index starts after the opening character and ends after the closing one.
    $sb = New-Object System.Text.StringBuilder
    $i = $Index.Value
    $n = $Sql.Length
    while ($true) {
        if ($i -ge $n) { throw (Get-SqlException -Message "Statement refused: unterminated $What" -Kind 'REFUSED') }
        $ch = $Sql[$i]
        if ($ch -eq $Close) {
            if ($i + 1 -lt $n -and $Sql[$i + 1] -eq $Close) {
                [void]$sb.Append($ch)
                $i += 2
                continue
            }
            $i++
            break
        }
        [void]$sb.Append($ch)
        $i++
    }
    $Index.Value = $i
    return $sb.ToString()
}

function Assert-SqlTokenRules {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][object[]]$Tokens,
        [Parameter(Mandatory)][string[]]$Refused,
        [Parameter(Mandatory)][string[]]$AllowedFirst,
        [switch]$AllowIntoAfterVerb
    )

    # Rules shared by reads and writes: one statement, an allowed first word, no refused keyword (only unquoted words count), no four-part names.
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        if ($Tokens[$i].Type -eq 'Symbol' -and $Tokens[$i].Text -eq ';' -and $i -lt $Tokens.Count - 1) {
            throw (Get-SqlException -Message "Statement refused: only one statement per call (found ';' followed by more text)" -Kind 'REFUSED')
        }
    }
    $first = $Tokens[0]
    if ($first.Type -ne 'Word' -or $AllowedFirst -notcontains $first.Upper) {
        throw (Get-SqlException -Message ('Statement refused: it must start with ' + ($AllowedFirst -join ' or ')) -Kind 'REFUSED')
    }
    for ($i = 1; $i -lt $Tokens.Count; $i++) {
        $t = $Tokens[$i]
        if ($t.Type -ne 'Word') { continue }
        $isRefused = $Refused -contains $t.Upper -or $t.Upper.StartsWith('XP_')
        if ($t.Upper -eq 'INTO' -and $AllowIntoAfterVerb -and $i -eq 1) { $isRefused = $false }
        if ($isRefused) { throw (Get-SqlException -Message "Statement refused: keyword $($t.Text) is not allowed" -Kind 'REFUSED') }
    }
    $dots = 0
    $previous = ''
    foreach ($t in $Tokens) {
        $isName = $t.Type -eq 'Word' -or $t.Type -eq 'Bracket' -or $t.Type -eq 'Quoted'
        if ($t.Type -eq 'Symbol' -and $t.Text -eq '.') {
            $dots++
            $previous = 'dot'
        }
        elseif ($isName) {
            if ($previous -eq 'name') { $dots = 0 }
            $previous = 'name'
        }
        else {
            $dots = 0
            $previous = ''
        }
        if ($dots -ge 3) { throw (Get-SqlException -Message 'Statement refused: four-part names (linked servers) are not allowed' -Kind 'REFUSED') }
    }
}

function Get-SqlStatementText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Sql, [Parameter(Mandatory)][object[]]$Tokens)

    $last = $Tokens[$Tokens.Count - 1]
    if ($last.Type -eq 'Symbol' -and $last.Text -eq ';') { return $Sql.Substring(0, $last.Start).Trim() }
    return $Sql.Trim()
}

function Assert-SqlQueryText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Sql)

    $tokens = Get-SqlToken -Sql $Sql
    if ($tokens.Count -eq 0) { throw (Get-SqlException -Message 'Statement refused: it is empty' -Kind 'REFUSED') }
    Assert-SqlTokenRules -Tokens $tokens -Refused $script:QueryRefused -AllowedFirst @('SELECT', 'WITH')
    return (Get-SqlStatementText -Sql $Sql -Tokens $tokens)
}

function Assert-SqlWriteText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Sql)

    $tokens = Get-SqlToken -Sql $Sql
    if ($tokens.Count -eq 0) { throw (Get-SqlException -Message 'Statement refused: it is empty' -Kind 'REFUSED') }
    if ($tokens[0].Type -eq 'Word' -and $tokens[0].Upper -eq 'WITH') {
        throw (Get-SqlException -Message 'Statement refused: a WITH (CTE) prefix is not supported for writes' -Kind 'REFUSED')
    }
    $verb = $tokens[0].Upper
    $refused = $script:WriteRefused
    if ($verb -eq 'UPDATE') { $refused = @($refused | Where-Object { $_ -ne 'SET' }) }
    Assert-SqlTokenRules -Tokens $tokens -Refused $refused -AllowedFirst @('INSERT', 'UPDATE') -AllowIntoAfterVerb:($verb -eq 'INSERT')
    if ($verb -eq 'UPDATE') {
        $sets = @($tokens | Where-Object { $_.Type -eq 'Word' -and $_.Upper -eq 'SET' })
        if ($sets.Count -ne 1 -or $sets[0].Depth -ne 0) {
            throw (Get-SqlException -Message "Statement refused: UPDATE must contain exactly one SET (found $($sets.Count))" -Kind 'REFUSED')
        }
        $where = @($tokens | Where-Object { $_.Type -eq 'Word' -and $_.Upper -eq 'WHERE' -and $_.Depth -eq 0 -and $_.Start -gt $sets[0].Start })
        if ($where.Count -eq 0) { throw (Get-SqlException -Message 'Statement refused: UPDATE needs a WHERE clause' -Kind 'REFUSED') }
    }
    return [pscustomobject]@{ Verb = $verb; Sql = (Get-SqlStatementText -Sql $Sql -Tokens $tokens) }
}

function Add-SqlOutputClause {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][ValidateSet('INSERT', 'UPDATE')][string]$Verb
    )

    # Returns the statement with an OUTPUT clause (old and new row images) or $null when no safe injection point exists.
    $tokens = Get-SqlToken -Sql $Sql
    $at = $null
    if ($Verb -eq 'UPDATE') {
        $setStart = -1
        foreach ($t in $tokens) {
            if ($t.Type -eq 'Word' -and $t.Upper -eq 'SET' -and $t.Depth -eq 0) {
                $setStart = $t.Start
                break
            }
        }
        if ($setStart -ge 0) {
            $hit = @($tokens | Where-Object { $_.Type -eq 'Word' -and $_.Depth -eq 0 -and $_.Start -gt $setStart -and @('FROM', 'WHERE', 'OPTION') -contains $_.Upper }) | Select-Object -First 1
            if ($null -ne $hit) { $at = $hit.Start }
        }
        $clause = "OUTPUT deleted.*, N'' AS [__sa_sep], inserted.* "
    }
    else {
        $hit = @($tokens | Select-Object -Skip 1 | Where-Object { $_.Type -eq 'Word' -and $_.Depth -eq 0 -and @('VALUES', 'SELECT', 'DEFAULT') -contains $_.Upper }) | Select-Object -First 1
        if ($null -ne $hit) { $at = $hit.Start }
        $clause = 'OUTPUT inserted.* '
    }
    if ($null -eq $at) { return $null }
    return $Sql.Insert($at, $clause)
}

#endregion Statement validation

#region Read functions

function Assert-SqlProcName {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Name, [switch]$AllowSystem)

    # One- or two-part identifier only; returned re-quoted as [schema].[name] so nothing else can travel with it.
    $refuse = { param($why) throw (Get-SqlException -Message "Name refused: $why" -Kind 'REFUSED') }
    if ([string]::IsNullOrEmpty($Name)) { & $refuse 'it is empty' }
    $m = [regex]::Match($Name, '^(?:(?<s>\[[^\]]+\]|[A-Za-z_][\w@#$]*)\.)?(?<p>\[[^\]]+\]|[A-Za-z_][\w@#$]*)\z')
    if (-not $m.Success) { & $refuse 'it must be name or schema.name (one or two identifier parts, no server or database part)' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($m.Groups['s'], $m.Groups['p'])) {
        if (-not $g.Success) { continue }
        $inner = $g.Value
        if ($inner.StartsWith('[')) { $inner = $inner.Substring(1, $inner.Length - 2) }
        $parts.Add($inner)
    }
    $leaf = $parts[$parts.Count - 1]
    if (-not $AllowSystem -and ($leaf -match '^(?i)(sp|xp)_')) { & $refuse 'system procedures (sp_*, xp_*) are not allowed' }
    return (($parts | ForEach-Object { '[' + $_.Replace(']', ']]') + ']' }) -join '.')
}

function Get-SqlCatalogRow {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$Parameters,
        [int]$Top = 0,
        [AllowNull()][string]$Path,
        [AllowNull()][string]$Name
    )

    $n = Get-SqlTop -Top $Top
    $set = Invoke-SqlRead -Text $Text -Parameters $Parameters -MaxRows $n -Path $Path -Name $Name
    Write-SqlCutWarning -Set $set -Limit $n
    ConvertTo-SqlRowObject -Set $set
}

<#
.SYNOPSIS
Runs one read-only SELECT (or WITH ... SELECT) and returns the rows as small objects.
.DESCRIPTION
Exactly one statement is accepted; INSERT, UPDATE, DELETE, EXEC, SELECT INTO, linked-server names and similar are refused before any connection is opened. Values go through -Parameters (SqlClient parameters), never string concatenation. -Top 0 means 20 rows, the hard cap is 200; only that many rows are read. Cells over 200 characters are truncated, binary shows its length, columns named like password, secret, token, hash or key are masked. A warning says when rows were cut.
.PARAMETER Parameters
Hashtable of parameter values, for example @{ id = 5 }; the statement refers to them as @id.
.EXAMPLE
Invoke-SqlQuery -Sql 'SELECT TOP 5 Id, Name FROM dbo.Orders WHERE Id > @id' -Parameters @{ id = 100 } -Path 'src/Api/appsettings.Development.json' -Name Main
#>
function Invoke-SqlQuery {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Sql,
        [hashtable]$Parameters,
        [int]$Top = 0,
        [string]$Path,
        [string]$Name
    )

    $text = Assert-SqlQueryText -Sql $Sql
    Get-SqlCatalogRow -Text $text -Parameters $Parameters -Top $Top -Path $Path -Name $Name
}

<#
.SYNOPSIS
Lists user tables and views: Schema, Name, Type, Rows.
.PARAMETER Like
LIKE pattern for the table name or schema.name (default all).
#>
function Get-SqlTable {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Like = '%', [int]$Top = 0, [string]$Path, [string]$Name)

    $text = @'
SELECT s.name AS [Schema], o.name AS [Name], CASE o.type WHEN 'U' THEN 'TABLE' ELSE 'VIEW' END AS [Type],
  (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)) AS [Rows]
FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0 AND (o.name LIKE @like OR s.name + '.' + o.name LIKE @like)
ORDER BY s.name, o.name
'@
    Get-SqlCatalogRow -Text $text -Parameters @{ like = $Like } -Top $Top -Path $Path -Name $Name
}

<#
.SYNOPSIS
Lists the columns of the tables or views matching -Table: Schema, Table, Pos, Column, Type, MaxLen, Prec, Scale, Nullable, Identity, Computed, InPk.
.PARAMETER Table
LIKE pattern for the table name or schema.name (required).
.PARAMETER Like
LIKE pattern for the column name (default all).
#>
function Get-SqlColumn {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Table, [string]$Like = '%', [int]$Top = 0, [string]$Path, [string]$Name)

    $text = @'
SELECT s.name AS [Schema], o.name AS [Table], c.column_id AS [Pos], c.name AS [Column],
  TYPE_NAME(c.user_type_id) AS [Type], c.max_length AS [MaxLen], c.precision AS [Prec], c.scale AS [Scale],
  c.is_nullable AS [Nullable], c.is_identity AS [Identity], c.is_computed AS [Computed],
  CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 1 ELSE 0 END AS [InPk]
FROM sys.columns c JOIN sys.objects o ON o.object_id = c.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0 AND (o.name LIKE @table OR s.name + '.' + o.name LIKE @table) AND c.name LIKE @like
ORDER BY s.name, o.name, c.column_id
'@
    Get-SqlCatalogRow -Text $text -Parameters @{ table = $Table; like = $Like } -Top $Top -Path $Path -Name $Name
}

<#
.SYNOPSIS
Lists the indexes of the tables matching -Table: Schema, Table, Index, Type, Unique, Primary, Cols, Incl, Filter.
.PARAMETER Table
LIKE pattern for the table name or schema.name (required).
#>
function Get-SqlIndex {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Table, [int]$Top = 0, [string]$Path, [string]$Name)

    $text = @'
SELECT s.name AS [Schema], o.name AS [Table], i.name AS [Index], i.type_desc AS [Type], i.is_unique AS [Unique], i.is_primary_key AS [Primary],
  STUFF((SELECT ', ' + c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0 ORDER BY ic.key_ordinal
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS [Cols],
  STUFF((SELECT ', ' + c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1 ORDER BY ic.index_column_id
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS [Incl],
  i.filter_definition AS [Filter]
FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE i.index_id > 0 AND o.type IN ('U', 'V') AND o.is_ms_shipped = 0 AND (o.name LIKE @table OR s.name + '.' + o.name LIKE @table)
ORDER BY s.name, o.name, i.index_id
'@
    Get-SqlCatalogRow -Text $text -Parameters @{ table = $Table } -Top $Top -Path $Path -Name $Name
}

<#
.SYNOPSIS
Lists the foreign keys where a table matching -Table is the child or the parent: Name, Parent, ParentCols, Ref, RefCols, OnDelete, OnUpdate, Disabled.
.PARAMETER Table
LIKE pattern for the table name or schema.name (required).
#>
function Get-SqlForeignKey {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Table, [int]$Top = 0, [string]$Path, [string]$Name)

    $text = @'
SELECT fk.name AS [Name], ps.name + '.' + po.name AS [Parent],
  STUFF((SELECT ', ' + pc.name FROM sys.foreign_key_columns fkc JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
    WHERE fkc.constraint_object_id = fk.object_id ORDER BY fkc.constraint_column_id
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS [ParentCols],
  rs.name + '.' + ro.name AS [Ref],
  STUFF((SELECT ', ' + rc.name FROM sys.foreign_key_columns fkc JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
    WHERE fkc.constraint_object_id = fk.object_id ORDER BY fkc.constraint_column_id
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS [RefCols],
  fk.delete_referential_action_desc AS [OnDelete], fk.update_referential_action_desc AS [OnUpdate], fk.is_disabled AS [Disabled]
FROM sys.foreign_keys fk
JOIN sys.objects po ON po.object_id = fk.parent_object_id JOIN sys.schemas ps ON ps.schema_id = po.schema_id
JOIN sys.objects ro ON ro.object_id = fk.referenced_object_id JOIN sys.schemas rs ON rs.schema_id = ro.schema_id
WHERE (po.name LIKE @table OR ps.name + '.' + po.name LIKE @table OR ro.name LIKE @table OR rs.name + '.' + ro.name LIKE @table)
ORDER BY ps.name, po.name, fk.name
'@
    Get-SqlCatalogRow -Text $text -Parameters @{ table = $Table } -Top $Top -Path $Path -Name $Name
}

<#
.SYNOPSIS
Lists stored procedures and functions: Schema, Name, Type, Modified.
.PARAMETER Like
LIKE pattern for the name or schema.name (default all).
#>
function Get-SqlProc {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Like = '%', [int]$Top = 0, [string]$Path, [string]$Name)

    $text = @'
SELECT s.name AS [Schema], o.name AS [Name], o.type_desc AS [Type], o.modify_date AS [Modified]
FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type IN ('P', 'FN', 'IF', 'TF') AND o.is_ms_shipped = 0 AND (o.name LIKE @like OR s.name + '.' + o.name LIKE @like)
ORDER BY s.name, o.name
'@
    Get-SqlCatalogRow -Text $text -Parameters @{ like = $Like } -Top $Top -Path $Path -Name $Name
}

<#
.SYNOPSIS
Returns the source text of a view, procedure or function (from sys.sql_modules), masked and cut at 8000 characters.
.PARAMETER Object
schema.name or name (one or two identifier parts).
#>
function Get-SqlDefinition {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Object, [string]$Path, [string]$Name)

    $quoted = Assert-SqlProcName -Name $Object -AllowSystem
    $text = @'
SELECT s.name AS [Schema], o.name AS [Name], o.type_desc AS [Type], m.definition AS [Definition]
FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE m.object_id = OBJECT_ID(@obj)
'@
    $set = Invoke-SqlRead -Text $text -Parameters @{ obj = $quoted } -MaxRows 1 -Path $Path -Name $Name
    if ($set.Rows.Count -eq 0) {
        throw (Get-SqlException -Message 'Object not found (or no permission to see its definition)' -Kind 'SQL')
    }
    $row = $set.Rows[0]
    $note = $null
    $definition = $null
    $length = 0
    $truncated = $false
    if ($null -eq $row[3] -or $row[3] -is [System.DBNull]) { $note = 'Definition not available (encrypted module or no VIEW DEFINITION permission)' }
    else {
        $full = [string]$row[3]
        $length = $full.Length
        $truncated = $length -gt $script:MaxDefinition
        $definition = Hide-SqlSecret -Text $full -MaxChars $script:MaxDefinition
        if ($truncated) { $note = "Definition cut at $($script:MaxDefinition) of $length characters" }
    }
    [pscustomobject][ordered]@{
        Schema     = ConvertTo-SqlCell -Value $row[0] -Column 'Schema'
        Name       = ConvertTo-SqlCell -Value $row[1] -Column 'Name'
        Type       = ConvertTo-SqlCell -Value $row[2] -Column 'Type'
        Length     = $length
        Truncated  = $truncated
        Note       = $note
        Definition = $definition
    }
}

#endregion Read functions

#region Writes and procedures

function Assert-SqlParameter {
    [CmdletBinding()]
    [OutputType([void])]
    param([hashtable]$Parameters)

    # Parameter names and values are checked before any connection is opened.
    $cmd = Get-SqlCommandObject -Text 'SELECT 1' -Parameters $Parameters
    $cmd.Dispose()
}

function Get-SqlTranCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Connection)

    $r = Invoke-SqlStep -Connection $Connection -Text 'SELECT @@TRANCOUNT'
    return [int]$r.Sets[0].Rows[0][0]
}

function Invoke-SqlTransaction {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][ValidateSet('Write', 'Proc')][string]$Kind,
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$Parameters,
        [switch]$Commit,
        [int]$ExpectedRows = 0,
        [int]$MaxRows = 20
    )

    # Shared by Invoke-SqlWrite and Invoke-SqlProc. Every step is its own batch through the seam:
    # BEGIN TRAN, the statement or procedure, a @@TRANCOUNT check, then COMMIT (only with -Commit and a matching count) or ROLLBACK.
    $begin = 'SET LOCK_TIMEOUT ' + $script:LockTimeoutMs + '; BEGIN TRAN'
    if ($Kind -eq 'Write') { $begin = 'SET XACT_ABORT ON; SET NOCOUNT OFF; ' + $begin }
    $rollbackText = 'IF @@TRANCOUNT > 0 ROLLBACK TRAN'
    $finished = $false
    $committed = $false
    try {
        [void](Invoke-SqlStep -Connection $Connection -Text $begin)
        if ($Kind -eq 'Proc' -and (Get-SqlTranCount -Connection $Connection) -ne 1) {
            throw (Get-SqlException -Message 'The transaction could not be started cleanly (@@TRANCOUNT is not 1)' -Kind 'TXN')
        }
        $rows = -1
        $outSets = @()
        $exceeded = $false
        $moreSets = $false
        $returnValue = $null
        if ($Kind -eq 'Write') {
            $run = Invoke-SqlStep -Connection $Connection -Text ($Text + "`n;SELECT @@ROWCOUNT AS [__sa_rc]") -Parameters $Parameters -MaxRows $MaxRows -StopAfter $script:MaxWriteRows -MaxSets 2
            $sets = @($run.Sets)
            $exceeded = @($sets | Where-Object { $_.More }).Count -gt 0
            if (-not $exceeded) {
                $last = $sets[$sets.Count - 1]
                if ($null -eq $last -or $last.Columns.Count -ne 1 -or $last.Columns[0] -ne '__sa_rc' -or $last.Rows.Count -ne 1) {
                    throw (Get-SqlException -Message 'The number of affected rows could not be read' -Kind 'ERROR')
                }
                $rows = [int]$last.Rows[0][0]
                $outSets = @()
                if ($sets.Count -gt 1) { $outSets = @($sets[0..($sets.Count - 2)]) }
                if ($rows -gt $script:MaxWriteRows) { $exceeded = $true }
            }
        }
        else {
            try {
                $run = Invoke-SqlStep -Connection $Connection -Text $Text -CommandType StoredProcedure -Parameters $Parameters -MaxRows $MaxRows -StopAfter 0 -MaxSets $script:MaxResultSets
            }
            catch {
                if ($_.Exception.Data['Kind'] -ne 'TXN') { throw }
                $original = $_.Exception.Message -replace '^SQL -?\d+ :: ', ''
                throw (Get-SqlException -Message "The procedure ended or broke the module's transaction ($original); its effect may already be permanent" -Number ([int]$_.Exception.Data['Number']) -Kind 'TXN')
            }
            $rows = [int]$run.RecordsAffected
            $outSets = @($run.Sets)
            $moreSets = [bool]$run.MoreSets
            $returnValue = $run.ReturnValue
            if ($rows -gt $script:MaxWriteRows) { $exceeded = $true }
        }
        $count = Get-SqlTranCount -Connection $Connection
        if ($count -ne 1) {
            [void](Invoke-SqlStep -Connection $Connection -Text $rollbackText)
            $finished = $true
            if ($Kind -eq 'Proc') {
                throw (Get-SqlException -Message "The procedure changed the transaction (@@TRANCOUNT is $count, expected 1); its effect may already be permanent" -Kind 'TXN')
            }
            throw (Get-SqlException -Message "The transaction state changed during the statement (@@TRANCOUNT is $count, expected 1)" -Kind 'TXN')
        }
        if ($exceeded) {
            [void](Invoke-SqlStep -Connection $Connection -Text $rollbackText)
            $finished = $true
            throw (Get-SqlException -Message "Refused: more than $($script:MaxWriteRows) rows affected; rolled back, nothing written" -Kind 'REFUSED')
        }
        if (-not $Commit) {
            [void](Invoke-SqlStep -Connection $Connection -Text $rollbackText)
            $finished = $true
        }
        elseif ($rows -ne $ExpectedRows) {
            [void](Invoke-SqlStep -Connection $Connection -Text $rollbackText)
            $finished = $true
            throw (Get-SqlException -Message "Refused: rows affected differ (expected $ExpectedRows, got $rows; nothing written)" -Kind 'REFUSED')
        }
        else {
            [void](Invoke-SqlStep -Connection $Connection -Text 'COMMIT TRAN')
            $finished = $true
            $committed = $true
        }
    }
    finally {
        if (-not $finished) {
            try { [void](Invoke-SqlStep -Connection $Connection -Text $rollbackText) }
            catch { Write-Verbose 'Rollback after a failure did not run' }
        }
    }
    return [pscustomobject]@{ Committed = $committed; RowsAffected = $rows; Sets = $outSets; ReturnValue = $returnValue; MoreSets = $moreSets }
}

function Test-SqlValueEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param($A, $B)

    $aNull = $null -eq $A -or $A -is [System.DBNull]
    $bNull = $null -eq $B -or $B -is [System.DBNull]
    if ($aNull -or $bNull) { return ($aNull -and $bNull) }
    if ($A -is [byte[]] -and $B -is [byte[]]) {
        if ($A.Length -ne $B.Length) { return $false }
        for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
        return $true
    }
    return [object]::Equals($A, $B)
}

function Get-SqlNewRowSet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Set, [Parameter(Mandatory)][string]$Verb)

    # For an UPDATE the OUTPUT set holds the old image, a separator column, then the new image; this returns the new image under the old names.
    if ($Verb -ne 'UPDATE') { return $Set }
    $sep = [array]::IndexOf([string[]]$Set.Columns, '__sa_sep')
    if ($sep -lt 1) { return $Set }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Set.Rows) { $rows.Add([object[]]@($row[($sep + 1)..($sep + $sep)])) }
    return [pscustomobject]@{ Columns = @($Set.Columns[0..($sep - 1)]); Rows = $rows.ToArray(); TotalRows = $Set.TotalRows; More = $Set.More; Cut = $Set.Cut }
}

function ConvertTo-SqlChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Set, [Parameter(Mandatory)][string]$Verb)

    $sep = -1
    if ($Verb -eq 'UPDATE') { $sep = [array]::IndexOf([string[]]$Set.Columns, '__sa_sep') }
    if ($sep -lt 1) {
        ConvertTo-SqlRowObject -Set $Set
        return
    }
    foreach ($row in $Set.Rows) {
        $changed = 0
        for ($k = 0; $k -lt $sep; $k++) {
            $old = $row[$k]
            $new = $row[$sep + 1 + $k]
            if (Test-SqlValueEqual -A $old -B $new) { continue }
            $changed++
            [pscustomobject][ordered]@{
                Ref    = ConvertTo-SqlCell -Value $row[0] -Column $Set.Columns[0]
                Column = $Set.Columns[$k]
                Old    = ConvertTo-SqlCell -Value $old -Column $Set.Columns[$k]
                New    = ConvertTo-SqlCell -Value $new -Column $Set.Columns[$k]
            }
        }
        if ($changed -eq 0) {
            [pscustomobject][ordered]@{ Ref = ConvertTo-SqlCell -Value $row[0] -Column $Set.Columns[0]; Column = '(no change)'; Old = $null; New = $null }
        }
    }
}

function Test-SqlOutputUnsupported {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Exception]$Exception)

    # 334 and 4186: the target has triggers or a shape that does not allow OUTPUT without INTO.
    if ($Exception.Data['Kind'] -ne 'SQL') { return $false }
    $number = [int]$Exception.Data['Number']
    return ($number -eq 334 -or $number -eq 4186 -or $Exception.Message -match '\bOUTPUT\b')
}

function Get-SqlTargetName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Sql, [Parameter(Mandatory)][string]$Verb)

    # [schema].[table] of a plain one- or two-part target, or $null (temp tables, variables, anything unusual).
    $tokens = Get-SqlToken -Sql $Sql
    $i = 1
    if ($Verb -eq 'INSERT' -and $tokens.Count -gt 1 -and $tokens[1].Type -eq 'Word' -and $tokens[1].Upper -eq 'INTO') { $i = 2 }
    if ($Verb -eq 'UPDATE' -and $tokens.Count -gt 2 -and $tokens[1].Type -eq 'Word' -and $tokens[1].Upper -eq 'TOP') {
        $i = 2
        while ($i -lt $tokens.Count -and -not ($tokens[$i].Type -eq 'Symbol' -and $tokens[$i].Text -eq ')' -and $tokens[$i].Depth -eq 0)) { $i++ }
        $i++
    }
    $names = New-Object System.Collections.Generic.List[string]
    while ($i -lt $tokens.Count -and $names.Count -lt 3) {
        $t = $tokens[$i]
        if (-not ($t.Type -eq 'Bracket' -or $t.Type -eq 'Quoted' -or ($t.Type -eq 'Word' -and -not $t.Text.StartsWith('#')))) { return $null }
        $names.Add($t.Text)
        if ($i + 1 -lt $tokens.Count -and $tokens[$i + 1].Type -eq 'Symbol' -and $tokens[$i + 1].Text -eq '.') { $i += 2 }
        else { break }
    }
    if ($names.Count -lt 1 -or $names.Count -gt 2) { return $null }
    return (($names | ForEach-Object { '[' + $_.Replace(']', ']]') + ']' }) -join '.')
}

function Get-SqlStoredRow {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][string]$Verb,
        [AllowNull()]$NewSet,
        [int]$Top = 20
    )

    # After a commit: re-read the affected rows by primary key. When that is not possible the OUTPUT values are shown instead, with a note.
    if ($null -eq $NewSet) { return @{ Rows = @(); Note = 'Stored values not shown: this statement was run without OUTPUT capture' } }
    $fallback = @{ Rows = @(ConvertTo-SqlRowObject -Set $NewSet); Note = 'Stored values are the OUTPUT values; changes made later by triggers or defaults are not shown' }
    $target = Get-SqlTargetName -Sql $Sql -Verb $Verb
    if ($null -eq $target) { return $fallback }
    try {
        $pkSql = 'SELECT c.name AS [Col] FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(@obj) ORDER BY ic.key_ordinal'
        $pk = Invoke-SqlStep -Connection $Connection -Text $pkSql -Parameters @{ obj = $target } -MaxRows 16 -MaxSets 1
        $keys = @($pk.Sets[0].Rows | ForEach-Object { [string]$_[0] })
        if ($keys.Count -eq 0) { return $fallback }
        $index = @()
        foreach ($key in $keys) {
            $found = -1
            for ($c = 0; $c -lt $NewSet.Columns.Count; $c++) { if ($NewSet.Columns[$c] -ieq $key) { $found = $c } }
            if ($found -lt 0) { return $fallback }
            $index += $found
        }
        if ($NewSet.Rows.Count -eq 0) { return @{ Rows = @(); Note = $null } }
        if ($NewSet.Rows.Count * $keys.Count -gt 2000) { return $fallback }
        $params = @{}
        $groups = New-Object System.Collections.Generic.List[string]
        for ($r = 0; $r -lt $NewSet.Rows.Count; $r++) {
            $parts = New-Object System.Collections.Generic.List[string]
            for ($j = 0; $j -lt $keys.Count; $j++) {
                $name = 'k' + $r + '_' + $j
                $params[$name] = $NewSet.Rows[$r][$index[$j]]
                $parts.Add('[' + $keys[$j].Replace(']', ']]') + '] = @' + $name)
            }
            $groups.Add('(' + ($parts -join ' AND ') + ')')
        }
        $text = 'SELECT * FROM ' + $target + ' WHERE ' + ($groups -join ' OR ')
        $res = Invoke-SqlStep -Connection $Connection -Text $text -Parameters $params -MaxRows $Top -StopAfter $Top -MaxSets 1
        return @{ Rows = @(ConvertTo-SqlRowObject -Set $res.Sets[0]); Note = $null }
    }
    catch {
        $kind = [string]$_.Exception.Data['Kind']
        return @{ Rows = $fallback.Rows; Note = "Stored values could not be re-read ($kind); showing the OUTPUT values" }
    }
}

<#
.SYNOPSIS
Runs ONE INSERT or UPDATE as a dry run (rolled back) or, with -Commit and -ExpectedRows, for real.
.DESCRIPTION
Only INSERT and UPDATE are accepted (DELETE, MERGE, TRUNCATE, DROP, ALTER, CREATE, EXEC, GRANT and the rest are refused; an UPDATE needs a WHERE). The statement runs inside a transaction with an OUTPUT clause the module adds, so the dry run shows rows affected and old/new values for up to -Top rows; when OUTPUT is not possible only the count is shown and the Note says why. -Commit also needs -ExpectedRows: if the real count differs, everything is rolled back and nothing is written. A statement affecting more than 10000 rows is rolled back and refused. After a commit the rows are re-read by primary key. Triggers, identity values and locks are not undone or shown by a dry run. The module cannot enforce human approval: the safety protocol in SKILL.md applies.
.PARAMETER Sql
One INSERT or UPDATE statement; values belong in -Parameters.
.PARAMETER ExpectedRows
Number of rows the user approved (required with -Commit).
.EXAMPLE
Invoke-SqlWrite -Sql 'UPDATE dbo.Orders SET Status = @s WHERE Id = @id' -Parameters @{ s = 'Closed'; id = 5 } -Path 'src/Api/appsettings.Development.json' -Name Main
.EXAMPLE
Invoke-SqlWrite -Sql 'UPDATE dbo.Orders SET Status = @s WHERE Id = @id' -Parameters @{ s = 'Closed'; id = 5 } -Commit -ExpectedRows 1 -Path 'src/Api/appsettings.Development.json' -Name Main
#>
function Invoke-SqlWrite {
    [CmdletBinding(DefaultParameterSetName = 'DryRun', SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Sql,
        [hashtable]$Parameters,
        [int]$Top = 0,
        [string]$Path,
        [string]$Name,
        [Parameter(ParameterSetName = 'Commit', Mandatory)][switch]$Commit,
        [Parameter(ParameterSetName = 'Commit', Mandatory)][ValidateRange(0, 2147483647)][int]$ExpectedRows
    )

    $check = Assert-SqlWriteText -Sql $Sql
    Assert-SqlParameter -Parameters $Parameters
    $n = Get-SqlTop -Top $Top
    $notes = New-Object System.Collections.Generic.List[string]
    $doCommit = $false
    if ($Commit) {
        if ($PSCmdlet.ShouldProcess($check.Verb + ' statement', 'Commit')) { $doCommit = $true }
        else { $notes.Add('-WhatIf: nothing was committed') }
    }
    $conn = Open-SqlConnection -ConnectionString (Resolve-SqlConnection -Path $Path -Name $Name)
    try {
        $capture = 'OUTPUT'
        $run = $null
        $withOutput = Add-SqlOutputClause -Sql $check.Sql -Verb $check.Verb
        if ($null -eq $withOutput) {
            $capture = 'CountOnly'
            $notes.Add('Old/new values not shown: no safe place for an OUTPUT clause in this statement')
        }
        else {
            try { $run = Invoke-SqlTransaction -Connection $conn -Kind Write -Text $withOutput -Parameters $Parameters -Commit:$doCommit -ExpectedRows $ExpectedRows -MaxRows $n }
            catch {
                if (-not (Test-SqlOutputUnsupported -Exception $_.Exception)) { throw }
                $capture = 'CountOnly'
                $notes.Add('Old/new values not shown: the server rejected the OUTPUT clause (for example a trigger on the target)')
            }
        }
        if ($null -eq $run) {
            $run = Invoke-SqlTransaction -Connection $conn -Kind Write -Text $check.Sql -Parameters $Parameters -Commit:$doCommit -ExpectedRows $ExpectedRows -MaxRows $n
        }
        $set = $null
        if ($capture -eq 'OUTPUT' -and $run.Sets.Count -gt 0) { $set = $run.Sets[0] }
        $changes = @()
        if ($null -ne $set) {
            $changes = @(ConvertTo-SqlChange -Set $set -Verb $check.Verb)
            if ($set.Rows.Count -lt $run.RowsAffected) { Write-Warning "Old/new values shown for the first $($set.Rows.Count) of $($run.RowsAffected) rows" }
        }
        $result = [ordered]@{
            Mode         = 'DryRun'
            Action       = $check.Verb
            RowsAffected = $run.RowsAffected
            Capture      = $capture
            Changes      = $changes
        }
        if ($run.Committed) {
            $result.Mode = 'Committed'
            $newSet = $null
            if ($null -ne $set) { $newSet = Get-SqlNewRowSet -Set $set -Verb $check.Verb }
            $stored = Get-SqlStoredRow -Connection $conn -Sql $check.Sql -Verb $check.Verb -NewSet $newSet -Top $n
            $result.Stored = $stored.Rows
            if ($stored.Note) { $notes.Add($stored.Note) }
        }
        else { $notes.Add('Rolled back. Triggers, identity values and locks are not undone or shown by a dry run') }
        $result.Note = $notes -join '; '
        [pscustomobject]$result
    }
    finally { Close-SqlConnection -Connection $conn }
}

<#
.SYNOPSIS
Calls ONE stored procedure as a dry run (rolled back) or, with -Commit and -ExpectedRows, for real.
.DESCRIPTION
Takes a procedure name (name or schema.name; no server or database part, no sp_ or xp_ system procedures) and parameters, never SQL text. The call runs inside a transaction that the dry run always rolls back. It shows the return value, the summed rows affected and the first -Top rows of up to 5 result sets. -Commit also needs -ExpectedRows; a procedure with SET NOCOUNT ON reports -1 and then -ExpectedRows -1 matches only that. A mismatch, or more than 10000 rows, rolls back and refuses. If the procedure committed or rolled back internally (@@TRANCOUNT changed, or errors 266, 3902, 3903) the result is Kind TXN: its effect may already be permanent. A procedure can do things a rollback cannot undo (own COMMIT, external calls, sequences, CLR, linked servers, mail): read its definition with Get-SqlDefinition first. The module cannot enforce human approval.
.PARAMETER Procedure
schema.name or name.
.PARAMETER ExpectedRows
Rows affected the user approved (required with -Commit); -1 only for a procedure that reports -1.
.EXAMPLE
Invoke-SqlProc -Procedure 'dbo.usp_Recalc' -Parameters @{ year = 2026 } -Path 'src/Api/appsettings.Development.json' -Name Main
#>
function Invoke-SqlProc {
    [CmdletBinding(DefaultParameterSetName = 'DryRun', SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Procedure,
        [hashtable]$Parameters,
        [int]$Top = 0,
        [string]$Path,
        [string]$Name,
        [Parameter(ParameterSetName = 'Commit', Mandatory)][switch]$Commit,
        [Parameter(ParameterSetName = 'Commit', Mandatory)][ValidateRange(-1, 2147483647)][int]$ExpectedRows
    )

    $quoted = Assert-SqlProcName -Name $Procedure
    Assert-SqlParameter -Parameters $Parameters
    $n = Get-SqlTop -Top $Top
    $notes = New-Object System.Collections.Generic.List[string]
    $doCommit = $false
    if ($Commit) {
        if ($PSCmdlet.ShouldProcess($quoted, 'Commit procedure call')) { $doCommit = $true }
        else { $notes.Add('-WhatIf: nothing was committed') }
    }
    $conn = Open-SqlConnection -ConnectionString (Resolve-SqlConnection -Path $Path -Name $Name)
    try {
        $run = Invoke-SqlTransaction -Connection $conn -Kind Proc -Text $quoted -Parameters $Parameters -Commit:$doCommit -ExpectedRows $ExpectedRows -MaxRows $n
    }
    finally { Close-SqlConnection -Connection $conn }
    $resultSets = New-Object System.Collections.Generic.List[object]
    foreach ($set in $run.Sets) {
        if ($set.Columns.Count -eq 0) { continue }
        Write-SqlCutWarning -Set $set -Limit $n
        $resultSets.Add([pscustomobject][ordered]@{ Columns = $set.Columns; Rows = @(ConvertTo-SqlRowObject -Set $set); TotalRows = $set.TotalRows; Cut = $set.Cut })
    }
    if ($run.MoreSets) { Write-Warning "Only the first $($script:MaxResultSets) result sets are shown" }
    if ($run.RowsAffected -eq -1) { $notes.Add('RowsAffected -1: the procedure uses SET NOCOUNT ON; -ExpectedRows -1 matches only such a procedure') }
    if ($run.Committed) { $notes.Add('Committed; no re-read is possible for a procedure') }
    else { $notes.Add('Rolled back. A procedure may do things a rollback cannot undo (own COMMIT, external calls, sequences, identity values, CLR, linked servers, mail)') }
    [pscustomobject][ordered]@{
        Mode         = $(if ($run.Committed) { 'Committed' } else { 'DryRun' })
        Procedure    = $quoted
        ReturnValue  = $run.ReturnValue
        RowsAffected = $run.RowsAffected
        ResultSets   = $resultSets.ToArray()
        Note         = $notes -join '; '
    }
}

#endregion Writes and procedures

#region Performance diagnostics

function Get-SqlXmlNumber {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][System.Xml.XmlNode]$Node, [Parameter(Mandatory)][string]$Attribute)

    $value = $Node.GetAttribute($Attribute)
    $number = 0.0
    if ([double]::TryParse($value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $number }
    return 0.0
}

function Get-SqlPlanObjectName {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][System.Xml.XmlNode]$Object)

    # Schema.Table.Index without brackets; the database part is dropped on purpose.
    if ($null -eq $Object) { return '' }
    $parts = foreach ($a in 'Schema', 'Table', 'Index') {
        $v = $Object.GetAttribute($a).Trim('[', ']')
        if ($v) { $v }
    }
    return ($parts -join '.')
}

function ConvertFrom-SqlPlanXml {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Xml)

    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    try { $doc.LoadXml($Xml) }
    catch { throw (Get-SqlException -Message 'The execution plan could not be parsed' -Kind 'ERROR') }
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('sp', 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
    $stmt = $doc.SelectSingleNode('//sp:StmtSimple', $ns)
    if ($null -eq $stmt) { throw (Get-SqlException -Message 'The execution plan has no statement' -Kind 'ERROR') }
    $total = Get-SqlXmlNumber -Node $stmt -Attribute 'StatementSubTreeCost'
    $operators = New-Object System.Collections.Generic.List[object]
    foreach ($op in $stmt.SelectNodes('.//sp:RelOp', $ns)) {
        $subtree = Get-SqlXmlNumber -Node $op -Attribute 'EstimatedTotalSubtreeCost'
        $children = 0.0
        foreach ($child in $op.SelectNodes('./*/sp:RelOp', $ns)) { $children += Get-SqlXmlNumber -Node $child -Attribute 'EstimatedTotalSubtreeCost' }
        $own = [Math]::Max(0.0, $subtree - $children)
        $pct = 0.0
        if ($total -gt 0) { $pct = [Math]::Round($own / $total * 100, 1) }
        $operators.Add([pscustomobject][ordered]@{
                Pct      = $pct
                NodeId   = [int](Get-SqlXmlNumber -Node $op -Attribute 'NodeId')
                Operator = Hide-SqlSecret -Text $op.GetAttribute('PhysicalOp')
                Object   = Hide-SqlSecret -Text (Get-SqlPlanObjectName -Object $op.SelectSingleNode('./*/sp:Object', $ns))
                EstRows  = Get-SqlXmlNumber -Node $op -Attribute 'EstimateRows'
                Own      = $own
            })
    }
    $ranked = @($operators | Sort-Object -Property @{ Expression = { $_.Own }; Descending = $true }, @{ Expression = { $_.NodeId } } | Select-Object -First 5)
    $top = @($ranked | ForEach-Object { [pscustomobject][ordered]@{ Pct = $_.Pct; NodeId = $_.NodeId; Operator = $_.Operator; Object = $_.Object; EstRows = $_.EstRows } })
    $scans = @($operators | Where-Object { @('Table Scan', 'Index Scan', 'Clustered Index Scan') -contains $_.Operator } | ForEach-Object { ($_.Operator + ' ' + $_.Object + ' (est ' + $_.EstRows + ' rows)').Replace('  ', ' ') })
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($w in $stmt.SelectNodes('.//sp:Warnings/*', $ns)) {
        if (-not $warnings.Contains($w.LocalName)) { $warnings.Add($w.LocalName) }
    }
    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($g in $stmt.SelectNodes('.//sp:MissingIndexGroup', $ns)) {
        $mi = $g.SelectSingleNode('./sp:MissingIndex', $ns)
        if ($null -eq $mi) { continue }
        $usage = @{ EQUALITY = @(); INEQUALITY = @(); INCLUDE = @() }
        foreach ($cg in $mi.SelectNodes('./sp:ColumnGroup', $ns)) {
            $names = @($cg.SelectNodes('./sp:Column', $ns) | ForEach-Object { $_.GetAttribute('Name').Trim('[', ']') })
            $usage[$cg.GetAttribute('Usage').ToUpperInvariant()] = $names
        }
        $missing.Add([pscustomobject][ordered]@{
                Impact     = Get-SqlXmlNumber -Node $g -Attribute 'Impact'
                Table      = Hide-SqlSecret -Text ((@($mi.GetAttribute('Schema').Trim('[', ']'), $mi.GetAttribute('Table').Trim('[', ']')) | Where-Object { $_ }) -join '.')
                Equality   = Hide-SqlSecret -Text ($usage['EQUALITY'] -join ', ')
                Inequality = Hide-SqlSecret -Text ($usage['INEQUALITY'] -join ', ')
                Include    = Hide-SqlSecret -Text ($usage['INCLUDE'] -join ', ')
            })
    }
    $abort = $stmt.GetAttribute('StatementOptmEarlyAbortReason')
    if ([string]::IsNullOrEmpty($abort)) { $abort = $null }
    return [pscustomobject][ordered]@{
        Cost           = [Math]::Round($total, 4)
        EstimatedRows  = Get-SqlXmlNumber -Node $stmt -Attribute 'StatementEstRows'
        EarlyAbort     = $abort
        TopOperators   = $top
        Scans          = $scans
        Warnings       = $warnings.ToArray()
        MissingIndexes = $missing.ToArray()
    }
}

<#
.SYNOPSIS
Estimated execution plan of ONE statement as a short summary; the statement is NOT executed.
.DESCRIPTION
Uses SET SHOWPLAN_XML ON on a dedicated connection. The statement must pass the same rules as Invoke-SqlQuery (SELECT/WITH) or Invoke-SqlWrite (INSERT/UPDATE). Returns cost, estimated rows, early-abort reason, the top 5 operators by their own cost (percent of the statement), scans, warnings and missing-index hints; never the raw XML. A missing SHOWPLAN permission gives DENIED.
.EXAMPLE
Get-SqlPlan -Sql 'SELECT * FROM dbo.Orders WHERE CustomerId = @c' -Parameters @{ c = 5 } -Path 'src/Api/appsettings.Development.json' -Name Main
#>
function Get-SqlPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Sql,
        [hashtable]$Parameters,
        [string]$Path,
        [string]$Name
    )

    $tokens = Get-SqlToken -Sql $Sql
    if ($tokens.Count -gt 0 -and $tokens[0].Type -eq 'Word' -and @('INSERT', 'UPDATE') -contains $tokens[0].Upper) { $text = (Assert-SqlWriteText -Sql $Sql).Sql }
    else { $text = Assert-SqlQueryText -Sql $Sql }
    Assert-SqlParameter -Parameters $Parameters
    $conn = Open-SqlConnection -ConnectionString (Resolve-SqlConnection -Path $Path -Name $Name)
    try {
        try {
            [void](Invoke-SqlStep -Connection $conn -Text 'SET SHOWPLAN_XML ON')
            $run = Invoke-SqlStep -Connection $conn -Text $text -Parameters $Parameters -MaxRows 1 -MaxSets 1
        }
        finally {
            try { [void](Invoke-SqlStep -Connection $conn -Text 'SET SHOWPLAN_XML OFF') }
            catch { Write-Verbose 'SHOWPLAN_XML OFF did not run' }
        }
    }
    finally { Close-SqlConnection -Connection $conn }
    $set = $run.Sets[0]
    if ($set.Rows.Count -eq 0 -or $null -eq $set.Rows[0][0] -or $set.Rows[0][0] -is [System.DBNull]) {
        throw (Get-SqlException -Message 'The server returned no execution plan' -Kind 'ERROR')
    }
    ConvertFrom-SqlPlanXml -Xml ([string]$set.Rows[0][0])
}

<#
.SYNOPSIS
Most expensive cached statements of the current database from sys.dm_exec_query_stats.
.PARAMETER By
cpu, reads or duration (the sort column comes from a fixed list).
.EXAMPLE
Get-SqlTopQueries -By reads -Top 10 -Path 'src/Api/appsettings.Development.json' -Name Main
#>
function Get-SqlTopQueries {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([ValidateSet('cpu', 'reads', 'duration')][string]$By = 'cpu', [int]$Top = 0, [string]$Path, [string]$Name)

    $order = @{ cpu = 'qs.total_worker_time'; reads = 'qs.total_logical_reads'; duration = 'qs.total_elapsed_time' }[$By]
    $text = @'
SELECT TOP (@top)
  qs.execution_count AS [Count],
  qs.total_worker_time / 1000 AS [CpuMs],
  qs.total_elapsed_time / 1000 AS [DurationMs],
  qs.total_logical_reads AS [Reads],
  qs.total_worker_time / qs.execution_count / 1000 AS [AvgCpuMs],
  qs.total_elapsed_time / qs.execution_count / 1000 AS [AvgDurationMs],
  qs.total_logical_reads / qs.execution_count AS [AvgReads],
  qs.last_execution_time AS [LastRun],
  LEFT(LTRIM(RTRIM(SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
    ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1))), 200) AS [Text]
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY (SELECT CONVERT(int, pa.value) AS dbid FROM sys.dm_exec_plan_attributes(qs.plan_handle) pa WHERE pa.attribute = 'dbid') a
WHERE qs.execution_count > 0 AND a.dbid = DB_ID()
'@ + "`nORDER BY $order DESC"
    $n = Get-SqlTop -Top $Top
    $set = Invoke-SqlRead -Text $text -Parameters @{ top = $n } -MaxRows $n -Path $Path -Name $Name
    Write-SqlCutWarning -Set $set -Limit $n
    foreach ($row in @(ConvertTo-SqlRowObject -Set $set)) {
        if ($row.PSObject.Properties['Text'] -and $row.Text) { $row.Text = [regex]::Replace([string]$row.Text, '\s+', ' ').Trim() }
        $row
    }
}

<#
.SYNOPSIS
Blocked requests and head blockers right now: Session, BlockedBy, Wait, WaitMs, Role, short statement text. No login or host names.
.EXAMPLE
Get-SqlBlocking -Path 'src/Api/appsettings.Development.json' -Name Main
#>
function Get-SqlBlocking {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int]$Top = 0, [string]$Path, [string]$Name)

    $text = @'
SELECT x.[Session], x.[BlockedBy], x.[Wait], x.[WaitMs], x.[Role], x.[Text]
FROM (
  SELECT r.session_id AS [Session], r.blocking_session_id AS [BlockedBy], r.wait_type AS [Wait], r.wait_time AS [WaitMs], 'blocked' AS [Role],
    LEFT(LTRIM(RTRIM(t.text)), 200) AS [Text]
  FROM sys.dm_exec_requests r
  OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
  WHERE r.blocking_session_id <> 0 AND r.session_id <> @@SPID
  UNION ALL
  SELECT s.session_id, 0, NULL, 0, 'head blocker', LEFT(LTRIM(RTRIM(t.text)), 200)
  FROM sys.dm_exec_sessions s
  LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
  OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
  WHERE s.session_id <> @@SPID
    AND s.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
    AND s.session_id NOT IN (SELECT session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
) x
ORDER BY x.[WaitMs] DESC
'@
    foreach ($row in @(Get-SqlCatalogRow -Text $text -Top $Top -Path $Path -Name $Name)) {
        if ($row.PSObject.Properties['Text'] -and $row.Text) { $row.Text = [regex]::Replace([string]$row.Text, '\s+', ' ').Trim() }
        $row
    }
}

<#
.SYNOPSIS
Top waits since the last server restart (cumulative, benign waits excluded): Wait, Tasks, WaitMs, SignalMs, Pct.
.EXAMPLE
Get-SqlWaits -Top 10 -Path 'src/Api/appsettings.Development.json' -Name Main
#>
function Get-SqlWaits {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int]$Top = 0, [string]$Path, [string]$Name)

    $text = @'
SELECT TOP (@top) w.wait_type AS [Wait], w.waiting_tasks_count AS [Tasks], w.wait_time_ms AS [WaitMs], w.signal_wait_time_ms AS [SignalMs],
  CONVERT(decimal(5, 2), 100.0 * w.wait_time_ms / NULLIF(SUM(w.wait_time_ms) OVER (), 0)) AS [Pct]
FROM sys.dm_os_wait_stats w
WHERE w.waiting_tasks_count > 0
  AND w.wait_type NOT LIKE N'SLEEP[_]%' AND w.wait_type NOT LIKE N'BROKER[_]%' AND w.wait_type NOT LIKE N'XE[_]%'
  AND w.wait_type NOT LIKE N'HADR[_]%' AND w.wait_type NOT LIKE N'SQLTRACE[_]%' AND w.wait_type NOT LIKE N'PARALLEL[_]REDO[_]%'
  AND w.wait_type NOT IN (N'LAZYWRITER_SLEEP', N'CHECKPOINT_QUEUE', N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE',
    N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX', N'KSOURCE_WAKEUP', N'LOGMGR_QUEUE',
    N'ONDEMAND_TASK_QUEUE', N'REQUEST_FOR_DEADLOCK_SEARCH', N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SNI_HTTP_ACCEPT', N'SOS_WORK_DISPATCHER',
    N'SP_SERVER_DIAGNOSTICS_SLEEP', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_FOR_RESULTS', N'WAIT_XTP_HOST_WAIT', N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
    N'WAIT_XTP_CKPT_CLOSE', N'WAIT_XTP_RECOVERY', N'MEMORY_ALLOCATION_EXT', N'PREEMPTIVE_XE_GETTARGETSTATE', N'PWAIT_ALL_COMPONENTS_INITIALIZED',
    N'PWAIT_DIRECTLOGCONSUMER_GETNEXT', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE', N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    N'QDS_SHUTDOWN_QUEUE', N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE', N'DBMIRRORING_CMD', N'EXECSYNC', N'FSAGENT')
ORDER BY w.wait_time_ms DESC
'@
    $n = Get-SqlTop -Top $Top
    $set = Invoke-SqlRead -Text $text -Parameters @{ top = $n } -MaxRows $n -Path $Path -Name $Name
    Write-SqlCutWarning -Set $set -Limit $n
    ConvertTo-SqlRowObject -Set $set
}

#endregion Performance diagnostics

#region Setup check

function Get-SqlAreaResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Area, [Parameter(Mandatory)][scriptblock]$Probe)

    # A probe returns a Pass flag and a Code, or throws; a failure is reduced to the error Kind so no name or server message is printed.
    $result = 'PASS'
    $code = ''
    try {
        $outcome = & $Probe
        $code = [string]$outcome.Code
        if (-not $outcome.Pass) { $result = 'FAIL' }
    }
    catch {
        $result = 'FAIL'
        $code = 'ERROR'
        if ($_.Exception.Data.Contains('Kind')) { $code = [string]$_.Exception.Data['Kind'] }
    }
    return [pscustomobject][ordered]@{ Area = $Area; Result = $result; Code = $code }
}

<#
.SYNOPSIS
First-run check: config file, connection string, connect, server version, VIEW SERVER STATE, SHOWPLAN. Prints Area, Result (PASS/FAIL/SKIP) and Code only.
.DESCRIPTION
Read-only. Does not read the project CLAUDE.md (the registration line is the agent's job): pass -Path and -Name like every other function. Never prints server, database or user names. After a Config, ConnString or Connect failure the remaining areas are SKIP. Version has the major version as Code (13 = SQL Server 2016, the minimum).
.EXAMPLE
Test-SqlSetup -Path 'src/Api/appsettings.Development.json' -Name Main
#>
function Test-SqlSetup {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path, [string]$Name)

    $entryName = $Name
    $settingsPath = $Path
    $state = @{ Raw = $null; ConnectionString = $null; Connection = $null }
    $chain = @(
        @{ Area = 'Config'; Probe = {
                Assert-SqlEntryName -Name $entryName
                $state.Raw = Read-SqlAppSettings -File (Find-SqlAppSettings -Path $settingsPath) -Name $entryName
                [pscustomobject]@{ Pass = $true; Code = '' }
            }
        }
        @{ Area = 'ConnString'; Probe = {
                $state.ConnectionString = ConvertTo-SqlConnectionString -Raw $state.Raw
                [pscustomobject]@{ Pass = $true; Code = '' }
            }
        }
        @{ Area = 'Connect'; Probe = {
                $state.Connection = Open-SqlConnection -ConnectionString $state.ConnectionString
                [pscustomobject]@{ Pass = $true; Code = '' }
            }
        }
    )
    $probes = @(
        @{ Area = 'Version'; Probe = {
                $r = Invoke-SqlStep -Connection $state.Connection -Text "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))"
                $major = 0
                if (-not [int]::TryParse(([string]$r.Sets[0].Rows[0][0]).Split('.')[0], [ref]$major)) { return [pscustomobject]@{ Pass = $false; Code = 'PARSE' } }
                [pscustomobject]@{ Pass = ($major -ge 13); Code = [string]$major }
            }
        }
        @{ Area = 'ServerState'; Probe = {
                $r = Invoke-SqlStep -Connection $state.Connection -Text "SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')"
                $ok = $r.Sets[0].Rows[0][0] -eq 1
                [pscustomobject]@{ Pass = $ok; Code = $(if ($ok) { '' } else { 'DENIED' }) }
            }
        }
        @{ Area = 'Showplan'; Probe = {
                $r = Invoke-SqlStep -Connection $state.Connection -Text "SELECT HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'SHOWPLAN')"
                $ok = $r.Sets[0].Rows[0][0] -eq 1
                [pscustomobject]@{ Pass = $ok; Code = $(if ($ok) { '' } else { 'DENIED' }) }
            }
        }
    )
    $stopped = $false
    try {
        foreach ($step in $chain) {
            if ($stopped) {
                [pscustomobject][ordered]@{ Area = $step.Area; Result = 'SKIP'; Code = '' }
                continue
            }
            $row = Get-SqlAreaResult -Area $step.Area -Probe $step.Probe
            if ($row.Result -ne 'PASS') { $stopped = $true }
            $row
        }
        foreach ($step in $probes) {
            if ($stopped) {
                [pscustomobject][ordered]@{ Area = $step.Area; Result = 'SKIP'; Code = '' }
                continue
            }
            Get-SqlAreaResult -Area $step.Area -Probe $step.Probe
        }
    }
    finally {
        if ($null -ne $state.Connection) { Close-SqlConnection -Connection $state.Connection }
    }
}

#endregion Setup check

try { Add-Type -AssemblyName System.Data }
catch { Write-Verbose 'System.Data could not be loaded explicitly' }
try {
    # Hebrew output reads correctly only with a UTF-8 console encoding (no BOM); do not use chcp for this.
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch { Write-Verbose 'Console output encoding could not be set' }

Export-ModuleMember -Function Invoke-SqlQuery, Invoke-SqlWrite, Invoke-SqlProc, Get-SqlTable, Get-SqlColumn, Get-SqlIndex, Get-SqlForeignKey, Get-SqlProc, Get-SqlDefinition, Get-SqlPlan, Get-SqlTopQueries, Get-SqlBlocking, Get-SqlWaits, Test-SqlSetup
