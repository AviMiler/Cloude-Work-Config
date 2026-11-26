# Pester tests for user/skills/sql-access/scripts/Sql.psm1: static checks, config and connection string handling, statement validation, and behaviour against a mocked SqlClient seam (test-only, never shipped).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'user/skills/sql-access/scripts'
    $script:ModuleSrc = Join-Path $script:ScriptsDir 'Sql.psm1'
    $script:SkillFile = Join-Path $script:RepoRoot 'user/skills/sql-access/SKILL.md'
    $script:SettingsFile = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $script:ServerName = 'sqlhost.test.invalid'
    $script:DbName = 'TestDb1'
    $script:ValidConnString = "Server=tcp:$($script:ServerName),1433;Database=$($script:DbName);Integrated Security=SSPI"

    function Import-SqlUnderTest {
        Remove-Module Sql -Force -ErrorAction SilentlyContinue
        Import-Module $script:ModuleSrc -Force
    }

    # Creates <TestDrive>/<guid>/proj with an appsettings.Development.json (default: one entry Main) and makes it the current directory.
    function New-SqlProject {
        param([string]$Json, [string]$SubPath = '')
        if (-not $PSBoundParameters.ContainsKey('Json')) {
            $Json = '{ "ConnectionStrings": { "Main": "' + $script:ValidConnString + '" } }'
        }
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $dir = Join-Path $root 'proj'
        if ($SubPath) { $dir = Join-Path $dir $SubPath }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'appsettings.Development.json'), $Json, (New-Object System.Text.UTF8Encoding($false)))
        Set-Location -LiteralPath (Join-Path $root 'proj')
        return (Join-Path $root 'proj')
    }

    function New-FakeSqlError {
        param([int]$Number, [string]$Message = 'fake server message')
        $ex = [System.Exception]::new($Message)
        Add-Member -InputObject $ex -MemberType NoteProperty -Name Number -Value $Number -Force
        return $ex
    }

    # A result set as Read-SqlResultSet returns it. Rows are arrays of raw values.
    function New-FakeSet {
        param([string[]]$Columns, [object[]]$Rows = @(), [switch]$More, [int]$Total = -1)
        if ($Total -lt 0) { $Total = $Rows.Count }
        $stored = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $Rows) { $stored.Add([object[]]$r) }
        [pscustomobject]@{ Columns = $Columns; Rows = $stored.ToArray(); TotalRows = $Total; More = [bool]$More; Cut = ($Total -gt $stored.Count) }
    }

    function New-FakeBatch {
        param([object[]]$Sets = @(), [int]$RecordsAffected = -1, $ReturnValue = 0)
        [pscustomobject]@{ Sets = $Sets; RecordsAffected = $RecordsAffected; ReturnValue = $ReturnValue; MoreSets = $false }
    }

    # Routes match the command text with -like in the order added. An unmatched batch throws so tests stay strict.
    function Add-SqlRoute {
        param([string]$Like, $Result, [System.Exception]$Throw, [scriptblock]$Handler)
        $global:SqlTestRoutes.Add(@{ Like = $Like; Result = $Result; Throw = $Throw; Handler = $Handler })
    }

    function Register-SqlMocks {
        $global:SqlTestRoutes = [System.Collections.Generic.List[object]]::new()
        $global:SqlTestCalls = [System.Collections.Generic.List[object]]::new()
        $global:SqlTestEvents = [System.Collections.Generic.List[string]]::new()
        $global:SqlTestOpenError = $null
        Mock Open-SqlConnection -ModuleName Sql -MockWith {
            $global:SqlTestEvents.Add('open')
            $global:SqlTestOpenStrings = $ConnectionString
            if ($global:SqlTestOpenError) { throw $global:SqlTestOpenError }
            [pscustomobject]@{ Fake = $true }
        }
        Mock Close-SqlConnection -ModuleName Sql -MockWith { $global:SqlTestEvents.Add('close') }
        Mock Invoke-SqlBatch -ModuleName Sql -MockWith {
            $params = @{}
            foreach ($p in $Command.Parameters) { $params[$p.ParameterName] = $p.Value }
            $call = [pscustomobject]@{
                Text = $Command.CommandText; Type = $Command.CommandType; Params = $params; Timeout = $Command.CommandTimeout
                ParamObjects = @($Command.Parameters | ForEach-Object { $_ })
                MaxRows = $MaxRows; StopAfter = $StopAfter; MaxSets = $MaxSets; Cancel = [bool]$CancelOnMore
            }
            $global:SqlTestCalls.Add($call)
            foreach ($r in $global:SqlTestRoutes) {
                if ($call.Text -like $r.Like) {
                    if ($r.Handler) { return (& $r.Handler $call) }
                    if ($r.Throw) { throw $r.Throw }
                    return $r.Result
                }
            }
            throw "unexpected batch: $($call.Text)"
        }
    }

    # Runs a script block inside the module scope so private functions can be called.
    function Invoke-InSqlModule {
        param([scriptblock]$Block, [object[]]$ArgList = @())
        & (Get-Module Sql) $Block @ArgList
    }

    # Returns the exception a script block throws, or $null.
    function Get-Thrown {
        param([scriptblock]$Script)
        try { & $Script } catch { return $_.Exception }
        return $null
    }

    function Initialize-SqlTest {
        Import-SqlUnderTest
        Register-SqlMocks
        $null = New-SqlProject
    }

    function Reset-SqlRoutes {
        $global:SqlTestRoutes.Clear()
        $global:SqlTestCalls.Clear()
        $global:SqlTestEvents.Clear()
        $global:SqlTestOpenError = $null
    }

    # Text of every recorded batch, in order.
    function Get-SqlCallText { return @($global:SqlTestCalls | ForEach-Object { $_.Text }) }

    function Assert-NoSecret {
        param($Value)
        $json = ConvertTo-Json -InputObject $Value -Depth 10
        $json | Should -Not -Match 'sqlhost\.test\.invalid'
        $json | Should -Not -Match 'TestDb1'
    }
}

AfterAll {
    Remove-Variable -Name SqlTestRoutes, SqlTestCalls, SqlTestEvents, SqlTestOpenError, SqlTestOpenStrings -Scope Global -ErrorAction SilentlyContinue
    Remove-Module Sql -Force -ErrorAction SilentlyContinue
}

Describe 'Static checks' {
    It 'PSScriptAnalyzer reports zero findings with the 5.1 compatibility settings' {
        $findings = @(Invoke-ScriptAnalyzer -Path $script:ScriptsDir -Recurse -Settings $script:SettingsFile)
        ($findings | ForEach-Object { "$($_.RuleName) $($_.ScriptName):$($_.Line) $($_.Message)" }) | Should -BeNullOrEmpty
    }

    It 'ships Sql.psm1 as UTF-8 BOM, CRLF and ASCII-only' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ModuleSrc)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $body = $bytes[3..($bytes.Length - 1)]
        @($body | Where-Object { $_ -gt 127 }) | Should -BeNullOrEmpty
        $text = [System.Text.Encoding]::ASCII.GetString($body)
        ([regex]::Matches($text, "(?<!`r)`n")).Count | Should -Be 0
        $text | Should -Match "`r`n"
    }

    It 'ships SKILL.md as ASCII-only (SR10)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:SkillFile)
        @($bytes | Where-Object { $_ -gt 127 }) | Should -BeNullOrEmpty
    }

    It 'never writes a variable followed by ? (PowerShell reads it as part of the name)' {
        $text = Get-Content -LiteralPath $script:ModuleSrc -Raw
        [regex]::Matches($text, '(?<!\{)\$[A-Za-z_]\w*\?') | Should -BeNullOrEmpty
    }

    It 'contains no file-writing, other-client, certificate-bypass or 2017+ T-SQL tokens' {
        $text = Get-Content -LiteralPath $script:ModuleSrc -Raw
        [regex]::Matches($text, '\b(Out-File|Set-Content|Add-Content|New-Item|Export-Csv|Write-Host|Invoke-Sqlcmd|sqlcmd|Odbc|OleDb|SkipCertificateCheck)\b') | Should -BeNullOrEmpty
        [regex]::Matches($text, '(STRING_AGG|(?<![A-Za-z_])TRIM\(|CONCAT_WS|TRANSLATE\(|STRING_SPLIT|dm_exec_query_statistics_xml)') | Should -BeNullOrEmpty
    }

    It 'exports exactly the 14 documented functions and nothing else' {
        Import-SqlUnderTest
        $m = Get-Module Sql
        @($m.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'Get-SqlBlocking', 'Get-SqlColumn', 'Get-SqlDefinition', 'Get-SqlForeignKey', 'Get-SqlIndex', 'Get-SqlPlan',
            'Get-SqlProc', 'Get-SqlTable', 'Get-SqlTopQueries', 'Get-SqlWaits', 'Invoke-SqlProc', 'Invoke-SqlQuery',
            'Invoke-SqlWrite', 'Test-SqlSetup')
        @($m.ExportedVariables.Keys) | Should -BeNullOrEmpty
        @($m.ExportedAliases.Keys) | Should -BeNullOrEmpty
    }

    It 'imports without printing anything and without touching a config file' {
        $out = Import-Module $script:ModuleSrc -Force 3>&1 4>&1
        $out | Should -BeNullOrEmpty
        Get-ChildItem -LiteralPath $script:ScriptsDir | ForEach-Object Name | Should -Not -Contain 'sql-config.psd1'
    }
}

Describe 'Errors and secret masking' {
    BeforeAll {
        Initialize-SqlTest
    }

    It 'Get-SqlException builds "SQL <number> :: <message>" with Kind and Number in Data' {
        $ex = Invoke-InSqlModule { Get-SqlException -Message 'boom' -Number 547 -Kind 'SQL' }
        $ex.Message | Should -Be 'SQL 547 :: boom'
        $ex.Data['Kind'] | Should -Be 'SQL'
        $ex.Data['Number'] | Should -Be 547
    }

    It 'Get-SqlException keeps the message on one line' {
        $ex = Invoke-InSqlModule { Get-SqlException -Message "line one`r`nline two" -Number 1 -Kind 'SQL' }
        $ex.Message | Should -Be 'SQL 1 :: line one line two'
    }

    It 'maps server error <Number> in the <Phase> phase to Kind <Kind>' -ForEach @(
        @{ Number = 18456; Phase = 'Open'; Kind = 'AUTH' }
        @{ Number = 18452; Phase = 'Open'; Kind = 'AUTH' }
        @{ Number = 4060; Phase = 'Open'; Kind = 'AUTH' }
        @{ Number = 53; Phase = 'Open'; Kind = 'CONNECT' }
        @{ Number = 0; Phase = 'Open'; Kind = 'CONNECT' }
        @{ Number = -2; Phase = 'Exec'; Kind = 'TIMEOUT' }
        @{ Number = 1222; Phase = 'Exec'; Kind = 'TIMEOUT' }
        @{ Number = 229; Phase = 'Exec'; Kind = 'DENIED' }
        @{ Number = 230; Phase = 'Exec'; Kind = 'DENIED' }
        @{ Number = 262; Phase = 'Exec'; Kind = 'DENIED' }
        @{ Number = 297; Phase = 'Exec'; Kind = 'DENIED' }
        @{ Number = 300; Phase = 'Exec'; Kind = 'DENIED' }
        @{ Number = 266; Phase = 'Exec'; Kind = 'TXN' }
        @{ Number = 3902; Phase = 'Exec'; Kind = 'TXN' }
        @{ Number = 3903; Phase = 'Exec'; Kind = 'TXN' }
        @{ Number = 547; Phase = 'Exec'; Kind = 'SQL' }
        @{ Number = 208; Phase = 'Exec'; Kind = 'SQL' }
    ) {
        $rec = [System.Management.Automation.ErrorRecord]::new((New-FakeSqlError -Number $Number), 'x', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $ex = Invoke-InSqlModule { param($r, $ph) ConvertTo-SqlError -ErrorRecord $r -Phase $ph } @($rec, $Phase)
        $ex.Data['Kind'] | Should -Be $Kind
        $ex.Data['Number'] | Should -Be $Number
        $ex.Message | Should -BeLike "SQL $Number :: *"
    }

    It 'finds the server error number on a wrapped inner exception' {
        $inner = New-FakeSqlError -Number 229
        $outer = [System.Management.Automation.MethodInvocationException]::new('wrapper', $inner)
        $rec = [System.Management.Automation.ErrorRecord]::new($outer, 'x', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $ex = Invoke-InSqlModule { param($r) ConvertTo-SqlError -ErrorRecord $r -Phase 'Exec' } @($rec)
        $ex.Data['Kind'] | Should -Be 'DENIED'
    }

    It 'gives an exception without a server number Kind ERROR' {
        $rec = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('plain'), 'x', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $ex = Invoke-InSqlModule { param($r) ConvertTo-SqlError -ErrorRecord $r -Phase 'Exec' } @($rec)
        $ex.Data['Kind'] | Should -Be 'ERROR'
        $ex.Message | Should -Be 'SQL 0 :: plain'
    }

    It 'passes a module exception through unchanged' {
        $own = Invoke-InSqlModule { Get-SqlException -Message 'mine' -Number 0 -Kind 'REFUSED' }
        $rec = [System.Management.Automation.ErrorRecord]::new($own, 'x', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $ex = Invoke-InSqlModule { param($r) ConvertTo-SqlError -ErrorRecord $r -Phase 'Exec' } @($rec)
        $ex.Data['Kind'] | Should -Be 'REFUSED'
        $ex.Message | Should -Be 'SQL 0 :: mine'
    }

    It 'uses fixed AUTH and CONNECT texts that never contain the server message' {
        $rec = [System.Management.Automation.ErrorRecord]::new((New-FakeSqlError -Number 18456 -Message "Login failed for user 'CORP\alice' on sqlhost.test.invalid"), 'x', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $ex = Invoke-InSqlModule { param($r) ConvertTo-SqlError -ErrorRecord $r -Phase 'Open' } @($rec)
        $ex.Message | Should -Not -Match 'alice|sqlhost'
    }

    It 'masks the registered server and database (case-insensitive, longest first) and generic secrets in error text' {
        $null = Invoke-InSqlModule { param($c) ConvertTo-SqlConnectionString -Raw $c } @("Server=tcp:sqlhost.test.invalid\INST1,1433;Database=TestDb1;Integrated Security=SSPI")
        $rec = [System.Management.Automation.ErrorRecord]::new((New-FakeSqlError -Number 208 -Message "Invalid object in SQLHOST.test.invalid\inst1 database testdb1; password=hunter2 inst1"), 'x', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        $ex = Invoke-InSqlModule { param($r) ConvertTo-SqlError -ErrorRecord $r -Phase 'Exec' } @($rec)
        $ex.Message | Should -Not -Match 'sqlhost|testdb1|inst1|hunter2'
        $ex.Message | Should -Match '<server>'
        $ex.Message | Should -Match '<database>'
    }

    It 'masks a database name in cell text only as a whole word of at least 4 characters' {
        $null = Invoke-InSqlModule { param($c) ConvertTo-SqlConnectionString -Raw $c } @('Server=h1.test.invalid;Database=Orders;Integrated Security=SSPI')
        $a = Invoke-InSqlModule { Hide-SqlSecret -Text 'see Orders table and MyOrdersView' -Cell }
        $a | Should -Be 'see <database> table and MyOrdersView'
        $b = Invoke-InSqlModule { Hide-SqlSecret -Text 'see Orders table and MyOrdersView' }
        $b | Should -Be 'see <database> table and My<database>View'
    }

    It 'does not mask short database names inside cell text' {
        $null = Invoke-InSqlModule { param($c) ConvertTo-SqlConnectionString -Raw $c } @('Server=h2.test.invalid;Database=db;Integrated Security=SSPI')
        Invoke-InSqlModule { Hide-SqlSecret -Text 'the db column' -Cell } | Should -Be 'the db column'
    }

    It 'caps masked text at the given length and marks the cut' {
        $text = 'a' * 100
        Invoke-InSqlModule { param($t) Hide-SqlSecret -Text $t -MaxChars 10 } @($text) | Should -Be ('a' * 10 + '...[truncated]')
    }
}

Describe 'Top handling' {
    BeforeAll { Initialize-SqlTest }

    It 'maps <In> to <Out>' -ForEach @(
        @{ In = 0; Out = 20 }, @{ In = -5; Out = 20 }, @{ In = 7; Out = 7 }, @{ In = 200; Out = 200 }
    ) {
        Invoke-InSqlModule { param($t) Get-SqlTop -Top $t } @($In) | Should -Be $Out
    }

    It 'caps 500 at 200 with a warning' {
        $w = Invoke-InSqlModule { Get-SqlTop -Top 500 } 3>&1
        @($w | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 1
        @($w | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }) | Should -Be 200
    }
}

Describe 'Connection string' {
    BeforeAll { Initialize-SqlTest }

    It 'refuses <Why> with a CONFIG error that does not echo the input' -ForEach @(
        @{ Why = 'User ID'; Raw = 'Server=s1;User Id=alice;Password=secretpw' }
        @{ Why = 'UID'; Raw = 'Server=s1;UID=alice' }
        @{ Why = 'Password alone'; Raw = 'Server=s1;Password=secretpw' }
        @{ Why = 'Pwd'; Raw = 'Server=s1;Pwd=secretpw' }
        @{ Why = 'User'; Raw = 'Server=s1;User=alice' }
        @{ Why = 'Authentication'; Raw = 'Server=s1;Authentication=Active Directory Password' }
        @{ Why = 'Integrated Security=false'; Raw = 'Server=s1;Integrated Security=false;Database=d1' }
        @{ Why = 'Trusted_Connection=no'; Raw = 'Server=s1;Trusted_Connection=no' }
        @{ Why = 'Integrated Security=sql'; Raw = 'Server=s1;Integrated Security=sql' }
        @{ Why = 'not a connection string'; Raw = 'this is not a connection string' }
        @{ Why = 'an unknown keyword'; Raw = 'Server=s1;Bogus Keyword=1' }
    ) {
        $ex = Get-Thrown { Invoke-InSqlModule { param($r) ConvertTo-SqlConnectionString -Raw $r } @($Raw) }
        $ex | Should -Not -BeNullOrEmpty
        $ex.Data['Kind'] | Should -Be 'CONFIG'
        $ex.Message | Should -Not -Match 'secretpw|alice|Bogus|this is not'
    }

    It 'forces integrated security, timeout, application name, no pooling and no MARS over what the file says' {
        $raw = 'Server=tcp:s1,1433;Database=d1;Trusted_Connection=yes;Connect Timeout=300;Application Name=other;Pooling=True;MultipleActiveResultSets=True'
        $out = Invoke-InSqlModule { param($r) ConvertTo-SqlConnectionString -Raw $r } @($raw)
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $b.set_ConnectionString($out)
        $b['Integrated Security'] | Should -Be $true
        $b['Connect Timeout'] | Should -Be 15
        $b['Application Name'] | Should -Be 'claude-sql-access'
        $b['Pooling'] | Should -Be $false
        $b['MultipleActiveResultSets'] | Should -Be $false
        $b['Data Source'] | Should -Be 'tcp:s1,1433'
        $b['Initial Catalog'] | Should -Be 'd1'
    }

    It 'accepts a string without any integrated-security keyword and adds it' {
        $out = Invoke-InSqlModule { param($r) ConvertTo-SqlConnectionString -Raw $r } @('Server=s1;Database=d1')
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $b.set_ConnectionString($out)
        $b['Integrated Security'] | Should -Be $true
    }
}

Describe 'Clear-SqlJsonComment' {
    BeforeAll { Initialize-SqlTest }

    It 'turns <Name> into strictly valid JSON with the expected content' -ForEach @(
        @{ Name = 'a line comment'; In = "{ // note`n `"a`": 1 }"; Key = 'a'; Want = '1' }
        @{ Name = 'a block comment'; In = '{ /* note */ "a": 2 }'; Key = 'a'; Want = '2' }
        @{ Name = 'comment markers inside a string'; In = '{ "a": "http://x/*y*/" }'; Key = 'a'; Want = 'http://x/*y*/' }
        @{ Name = 'an escaped quote before comment markers in a string'; In = '{ "a": "q\" // still string" }'; Key = 'a'; Want = 'q" // still string' }
        @{ Name = 'a trailing comma in an object'; In = '{ "a": 3, }'; Key = 'a'; Want = '3' }
        @{ Name = 'a trailing comma before a comment'; In = "{ `"a`": 4, // x`n }"; Key = 'a'; Want = '4' }
        @{ Name = 'a trailing comma in a nested array'; In = '{ "a": [5, 6,] }'; Key = 'a'; Want = '[5,6]' }
        @{ Name = 'a comma inside a string before a brace'; In = '{ "a": "x,}" }'; Key = 'a'; Want = 'x,}' }
    ) {
        $clean = Invoke-InSqlModule { param($t) Clear-SqlJsonComment -Text $t } @($In)
        $doc = [System.Text.Json.JsonDocument]::Parse($clean)
        $el = $doc.RootElement.GetProperty($Key)
        $got = if ($el.ValueKind -eq 'String') { $el.GetString() } else { $el.GetRawText() -replace '\s', '' }
        $got | Should -Be $Want
    }
}

Describe 'appsettings lookup' {
    BeforeAll {
        Initialize-SqlTest
        function Get-ResolvedString {
            param($Path = $null, $Name = $null)
            Invoke-InSqlModule { param($p, $n) Resolve-SqlConnection -Path $p -Name $n } @($Path, $Name)
        }
    }

    It 'reads a file with BOM, comments and trailing commas and returns a forced integrated string' {
        $json = [string][char]0xFEFF + "{`n // dev only`n `"ConnectionStrings`": { /* main */ `"Main`": `"$($script:ValidConnString)`", },`n}"
        $null = New-SqlProject -Json $json
        $cs = Get-ResolvedString
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $b.set_ConnectionString($cs)
        $b['Data Source'] | Should -Be "tcp:$($script:ServerName),1433"
        $b['Application Name'] | Should -Be 'claude-sql-access'
    }

    It 'matches ConnectionStrings and the entry name case-insensitively' {
        $null = New-SqlProject -Json ('{ "connectionstrings": { "MAIN": "' + $script:ValidConnString + '" } }')
        { Get-ResolvedString -Name 'main' } | Should -Not -Throw
    }

    It 'uses the only entry when -Name is missing' {
        $null = New-SqlProject
        { Get-ResolvedString } | Should -Not -Throw
    }

    It 'lists entry names but never values when several exist and -Name is missing' {
        $null = New-SqlProject -Json ('{ "ConnectionStrings": { "One": "Server=s1;Database=d1", "Two": "Server=s2;Database=d2" } }')
        $ex = Get-Thrown { Get-ResolvedString }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
        $ex.Message | Should -Match 'One'
        $ex.Message | Should -Match 'Two'
        $ex.Message | Should -Not -Match 's1|d2'
    }

    It 'reports an unknown -Name with the available names only' {
        $null = New-SqlProject -Json ('{ "ConnectionStrings": { "One": "Server=s1;Database=d1" } }')
        $ex = Get-Thrown { Get-ResolvedString -Name 'Nope' }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
        $ex.Message | Should -Match 'One'
        $ex.Message | Should -Not -Match 's1'
    }

    It 'rejects the -Name value <Name>' -ForEach @(
        @{ Name = 'a b' }, @{ Name = 'x;y' }, @{ Name = '../x' }
    ) {
        $null = New-SqlProject
        $ex = Get-Thrown { Get-ResolvedString -Name $Name }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
    }

    It 'treats an empty -Name as not given' {
        $null = New-SqlProject
        { Get-ResolvedString -Name '' } | Should -Not -Throw
    }

    It 'reports <Why> as CONFIG without printing connection string values' -ForEach @(
        @{ Why = 'invalid JSON'; Json = '{ "ConnectionStrings": { "Main": "Server=leak1" ' }
        @{ Why = 'a missing ConnectionStrings section'; Json = '{ "Logging": { "A": "Server=leak1" } }' }
        @{ Why = 'an empty ConnectionStrings section'; Json = '{ "ConnectionStrings": { } }' }
        @{ Why = 'a non-string entry'; Json = '{ "ConnectionStrings": { "Main": { "x": "Server=leak1" } } }' }
    ) {
        $null = New-SqlProject -Json $Json
        $ex = Get-Thrown { Get-ResolvedString }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
        $ex.Message | Should -Not -Match 'leak1'
    }

    It 'refuses the unsafe -Path <Path>' -ForEach @(
        @{ Path = 'C:\x\appsettings.Development.json' }
        @{ Path = '/abs/appsettings.Development.json' }
        @{ Path = '\abs\appsettings.Development.json' }
        @{ Path = '\\srv\share\appsettings.Development.json' }
        @{ Path = '..\appsettings.Development.json' }
        @{ Path = 'a/../../appsettings.Development.json' }
        @{ Path = 'src/appsettings.json' }
        @{ Path = 'src/appsettings.Production.json' }
        @{ Path = 'src' }
    ) {
        $null = New-SqlProject
        $ex = Get-Thrown { Get-ResolvedString -Path $Path }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
    }

    It 'reads the file named by a relative -Path and reports a missing one with the relative path only' {
        $null = New-SqlProject -SubPath 'src/Api'
        { Get-ResolvedString -Path 'src/Api/appsettings.Development.json' } | Should -Not -Throw
        $ex = Get-Thrown { Get-ResolvedString -Path 'src/Other/appsettings.Development.json' }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
        $ex.Message | Should -Match 'src/Other/appsettings\.Development\.json'
        $ex.Message | Should -Not -Match ([regex]::Escape($TestDrive))
    }

    It 'accepts backslashes and a quoted-with-spaces path' {
        $null = New-SqlProject -SubPath 'src/My Api'
        { Get-ResolvedString -Path 'src\My Api\appsettings.Development.json' } | Should -Not -Throw
    }

    It 'discovers one file at depth 3 below the current directory' {
        $null = New-SqlProject -SubPath 'a/b/c'
        { Get-ResolvedString } | Should -Not -Throw
    }

    It 'does not look deeper than depth 3' {
        $null = New-SqlProject -SubPath 'a/b/c/d'
        $ex = Get-Thrown { Get-ResolvedString }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
    }

    It 'skips <Dir> folders during discovery' -ForEach @(
        @{ Dir = 'bin' }, @{ Dir = 'obj' }, @{ Dir = 'node_modules' }, @{ Dir = '.git' }
    ) {
        $null = New-SqlProject -SubPath $Dir
        $ex = Get-Thrown { Get-ResolvedString }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
    }

    It 'lists relative paths and stops when several files match' {
        $proj = New-SqlProject
        foreach ($sub in 'src/A', 'src/B') {
            New-Item -ItemType Directory -Path (Join-Path $proj $sub) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $proj "$sub/appsettings.Development.json") -Value '{ "ConnectionStrings": { "Main": "Server=s9" } }'
        }
        $ex = Get-Thrown { Get-ResolvedString }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
        $ex.Message | Should -Match 'src/A/appsettings\.Development\.json'
        $ex.Message | Should -Match 'src/B/appsettings\.Development\.json'
        $ex.Message | Should -Match '-Path'
        $ex.Message | Should -Not -Match ([regex]::Escape($TestDrive))
        $ex.Message | Should -Not -Match 's9'
    }

    It 'says nothing was found when there is no file' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Location -LiteralPath $root
        $ex = Get-Thrown { Get-ResolvedString }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
        $ex.Message | Should -Match 'appsettings\.Development\.json'
    }
}

Describe 'Read-SqlResultSet' {
    BeforeAll {
        Initialize-SqlTest
        function New-TableReader {
            param([string[]]$Columns, [object[]]$Rows)
            $t = New-Object System.Data.DataTable
            foreach ($c in $Columns) { $null = $t.Columns.Add($c, [object]) }
            foreach ($r in $Rows) { $null = $t.Rows.Add([object[]]$r) }
            return , (New-Object System.Data.DataTableReader $t)
        }
        function Read-Set {
            param($Reader, [int]$MaxRows = 100, [int]$StopAfter = 0)
            Invoke-InSqlModule { param($r, $m, $s) Read-SqlResultSet -Reader $r -MaxRows $m -StopAfter $s } @($Reader, $MaxRows, $StopAfter)
        }
    }

    It 'returns column names and raw row values' {
        $set = Read-Set (New-TableReader @('Id', 'Name') @(@(1, 'a'), @(2, 'b')))
        $set.Columns | Should -Be @('Id', 'Name')
        $set.Rows.Count | Should -Be 2
        $set.Rows[1][1] | Should -Be 'b'
        $set.TotalRows | Should -Be 2
        $set.Cut | Should -BeFalse
        $set.More | Should -BeFalse
    }

    It 'keeps only MaxRows rows but counts the rest' {
        $rows = 1..5 | ForEach-Object { , @($_) }
        $set = Read-Set (New-TableReader @('n') $rows) -MaxRows 2
        $set.Rows.Count | Should -Be 2
        $set.Rows[1][0] | Should -Be 2
        $set.TotalRows | Should -Be 5
        $set.Cut | Should -BeTrue
        $set.More | Should -BeFalse
    }

    It 'stops reading one row past StopAfter and says more rows exist' {
        $rows = 1..10 | ForEach-Object { , @($_) }
        $set = Read-Set (New-TableReader @('n') $rows) -MaxRows 3 -StopAfter 3
        $set.Rows.Count | Should -Be 3
        $set.TotalRows | Should -Be 4
        $set.More | Should -BeTrue
        $set.Cut | Should -BeTrue
    }

    It 'gives empty and duplicate column names unique names' {
        $names = Invoke-InSqlModule { Get-SqlUniqueName -Name @('a', 'A', 'Col3', 'a', '', ' ', 'Column5') }
        $names | Should -Be @('a', 'A_2', 'Col3', 'a_3', 'Column5', 'Column6', 'Column5_2')
    }

    It 'returns the columns of an empty result' {
        $set = Read-Set (New-TableReader @('Id') @())
        $set.Columns | Should -Be @('Id')
        $set.Rows.Count | Should -Be 0
        $set.TotalRows | Should -Be 0
    }
}

Describe 'Get-SqlCommandObject' {
    BeforeAll {
        Initialize-SqlTest
        function New-Cmd {
            param([hashtable]$Parameters, [string]$Type = 'Text', [int]$Timeout = 30)
            Invoke-InSqlModule { param($p, $t, $o) Get-SqlCommandObject -Text 'SELECT 1' -CommandType $t -Parameters $p -TimeoutSec $o } @($Parameters, $Type, $Timeout)
        }
    }

    It 'builds a text command with the timeout and no parameters' {
        $c = New-Cmd -Parameters @{} -Timeout 17
        $c.CommandText | Should -Be 'SELECT 1'
        $c.CommandType | Should -Be ([System.Data.CommandType]::Text)
        $c.CommandTimeout | Should -Be 17
        $c.Parameters.Count | Should -Be 0
    }

    It 'adds the @ prefix, keeps value types and turns $null into DBNull' {
        $c = New-Cmd -Parameters @{ id = 5; '@name' = 'x'; none = $null }
        $c.Parameters['@id'].SqlDbType | Should -Be ([System.Data.SqlDbType]::Int)
        $c.Parameters['@id'].Value | Should -Be 5
        $c.Parameters['@name'].SqlDbType | Should -Be ([System.Data.SqlDbType]::NVarChar)
        $c.Parameters['@none'].Value | Should -BeOfType ([System.DBNull])
    }

    It 'passes an explicit SqlParameter through with its exact type' {
        $sp = New-Object System.Data.SqlClient.SqlParameter('ignored', [System.Data.SqlDbType]::VarChar, 5)
        $sp.Value = 'abc'
        $c = New-Cmd -Parameters @{ code = $sp }
        $c.Parameters['@code'].SqlDbType | Should -Be ([System.Data.SqlDbType]::VarChar)
        $c.Parameters['@code'].Size | Should -Be 5
    }

    It 'accepts byte[] values' {
        $c = New-Cmd -Parameters @{ blob = [byte[]](1, 2, 3) }
        $c.Parameters['@blob'].SqlDbType | Should -Be ([System.Data.SqlDbType]::VarBinary)
    }

    It 'refuses the parameter name <Name>' -ForEach @(
        @{ Name = 'a b' }, @{ Name = '1x' }, @{ Name = 'x;y' }, @{ Name = '__sa_rc' }, @{ Name = '@@x' }, @{ Name = '' }
    ) {
        $ex = Get-Thrown { New-Cmd -Parameters @{ $Name = 1 } }
        $ex.Data['Kind'] | Should -Be 'REFUSED'
    }

    It 'refuses a list or object as a parameter value' {
        $ex = Get-Thrown { New-Cmd -Parameters @{ ids = @(1, 2) } }
        $ex.Data['Kind'] | Should -Be 'REFUSED'
    }

    It 'adds a return-value parameter for stored procedures' {
        $c = New-Cmd -Parameters @{ a = 1 } -Type 'StoredProcedure'
        $c.CommandType | Should -Be ([System.Data.CommandType]::StoredProcedure)
        $c.Parameters['@__sa_ret'].Direction | Should -Be ([System.Data.ParameterDirection]::ReturnValue)
        $c.Parameters['@a'].Direction | Should -Be ([System.Data.ParameterDirection]::Input)
    }
}

Describe 'Result cell conversion' {
    BeforeAll { Initialize-SqlTest }

    It 'converts <Name>' -ForEach @(
        @{ Name = 'null'; Value = $null; Column = 'c'; Want = $null }
        @{ Name = 'DBNull'; Value = [System.DBNull]::Value; Column = 'c'; Want = $null }
        @{ Name = 'a short string'; Value = 'abc'; Column = 'c'; Want = 'abc' }
        @{ Name = 'binary to its length'; Value = [byte[]](1, 2, 3); Column = 'c'; Want = '<binary 3 bytes>' }
        @{ Name = 'a datetime to text'; Value = [datetime]'2026-11-02T13:05:09'; Column = 'c'; Want = '2026-11-02 13:05:09' }
        @{ Name = 'a guid to text'; Value = [guid]'11111111-2222-3333-4444-555555555555'; Column = 'c'; Want = '11111111-2222-3333-4444-555555555555' }
        @{ Name = 'a number unchanged'; Value = [decimal]1.5; Column = 'c'; Want = [decimal]1.5 }
        @{ Name = 'a boolean unchanged'; Value = $true; Column = 'c'; Want = $true }
        @{ Name = 'a password column'; Value = 'x'; Column = 'UserPassword'; Want = '***' }
        @{ Name = 'a pwd column'; Value = 'x'; Column = 'pwd'; Want = '***' }
        @{ Name = 'a token column'; Value = 'x'; Column = 'ApiToken'; Want = '***' }
        @{ Name = 'a secret column'; Value = 'x'; Column = 'Secret'; Want = '***' }
        @{ Name = 'a hash column'; Value = 'x'; Column = 'RowHash'; Want = '***' }
        @{ Name = 'a key column'; Value = 5; Column = 'KeyId'; Want = '***' }
        @{ Name = 'a null in a secret column'; Value = $null; Column = 'Password'; Want = $null }
        @{ Name = 'a normal column that merely contains letters'; Value = 'x'; Column = 'Monday'; Want = 'x' }
        @{ Name = 'a connection-string-like text'; Value = 'host=x;password=abc;a=1'; Column = 'c'; Want = 'host=x;password=***;a=1' }
    ) {
        $got = Invoke-InSqlModule { param($v, $c) ConvertTo-SqlCell -Value $v -Column $c } @($Value, $Column)
        $got | Should -Be $Want
    }

    It 'masks first and truncates after, so a name straddling the cut is not left half visible' {
        $null = Invoke-InSqlModule { ConvertTo-SqlConnectionString -Raw 'Server=h3.test.invalid;Database=OrdersDb;Integrated Security=SSPI' }
        $text = ('x' * 195) + ' OrdersDb tail'
        $got = Invoke-InSqlModule { param($t) ConvertTo-SqlCell -Value $t -Column 'c' } @($text)
        $got | Should -Not -Match 'Orders|rdersDb'
        $got | Should -Be (('x' * 195) + ' <dat...')
    }

    It 'truncates text over 200 characters and marks it' {
        $got = Invoke-InSqlModule { param($t) ConvertTo-SqlCell -Value $t -Column 'c' } @(('y' * 300))
        $got | Should -Be (('y' * 200) + '...')
    }

    It 'turns a set into one object per row with the column names as properties' {
        $set = New-FakeSet -Columns @('Id', 'Password') -Rows @(@(1, 'pw1'), @(2, $null))
        $rows = @(Invoke-InSqlModule { param($s) ConvertTo-SqlRowObject -Set $s } @($set))
        $rows.Count | Should -Be 2
        $rows[0].Id | Should -Be 1
        $rows[0].Password | Should -Be '***'
        $rows[1].Password | Should -BeNullOrEmpty
    }

    It 'turns an empty set into no objects' {
        $set = New-FakeSet -Columns @('Id')
        @(Invoke-InSqlModule { param($s) ConvertTo-SqlRowObject -Set $s } @($set)).Count | Should -Be 0
    }
}

Describe 'Get-SqlToken' {
    BeforeAll {
        Initialize-SqlTest
        function Format-Tokens {
            param([string]$Sql)
            $t = Invoke-InSqlModule { param($q) Get-SqlToken -Sql $q } @($Sql)
            return (($t | ForEach-Object { "$($_.Type):$($_.Text):$($_.Depth)" }) -join ' ')
        }
    }

    It 'tokenizes <Name>' -ForEach @(
        @{ Name = 'plain words'; Sql = 'SELECT a FROM t'; Want = 'Word:SELECT:0 Word:a:0 Word:FROM:0 Word:t:0' }
        @{ Name = 'bracket and quoted identifiers with escapes'; Sql = 'SELECT [a b], "c" FROM [x]]y]'; Want = 'Word:SELECT:0 Bracket:a b:0 Symbol:,:0 Quoted:c:0 Word:FROM:0 Bracket:x]y:0' }
        @{ Name = 'strings, numbers and variables'; Sql = "SELECT N'it''s', 1.5, @p, @@rowcount"; Want = 'Word:SELECT:0 String:it''s:0 Symbol:,:0 Number:1.5:0 Symbol:,:0 Var:@p:0 Symbol:,:0 Var:@@rowcount:0' }
        @{ Name = 'a keyword inside a string as a string'; Sql = "SELECT 'DROP TABLE x'"; Want = 'Word:SELECT:0 String:DROP TABLE x:0' }
        @{ Name = 'line and nested block comments away'; Sql = "SELECT 1 -- x`n, /* a /* nested */ b */ 2"; Want = 'Word:SELECT:0 Number:1:0 Symbol:,:0 Number:2:0' }
        @{ Name = 'parenthesis depth'; Sql = 'f(a, (b)) c'; Want = 'Word:f:0 Symbol:(:0 Word:a:1 Symbol:,:1 Symbol:(:1 Word:b:2 Symbol:):1 Symbol:):0 Word:c:0' }
        @{ Name = 'dotted names'; Sql = 'a.b.[c]'; Want = 'Word:a:0 Symbol:.:0 Word:b:0 Symbol:.:0 Bracket:c:0' }
        @{ Name = 'temp tables and a Hebrew identifier'; Sql = ('#t ' + [char]0x05E9 + [char]0x05DD); Want = ('Word:#t:0 Word:' + [char]0x05E9 + [char]0x05DD + ':0') }
    ) {
        Format-Tokens $Sql | Should -Be $Want
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'an unterminated string'; Sql = "SELECT 'abc" }
        @{ Name = 'an unterminated bracket name'; Sql = 'SELECT [abc' }
        @{ Name = 'an unterminated quoted name'; Sql = 'SELECT "abc' }
        @{ Name = 'an unterminated block comment'; Sql = 'SELECT 1 /* abc' }
        @{ Name = 'an unterminated nested block comment'; Sql = 'SELECT 1 /* a /* b */' }
    ) {
        $ex = Get-Thrown { Invoke-InSqlModule { param($q) Get-SqlToken -Sql $q } @($Sql) }
        $ex.Data['Kind'] | Should -Be 'REFUSED'
    }
}

Describe 'Assert-SqlQueryText' {
    BeforeAll { Initialize-SqlTest }

    It 'accepts <Sql>' -ForEach @(
        @{ Sql = 'SELECT 1' }
        @{ Sql = 'select * from dbo.Orders where Id = @id;' }
        @{ Sql = 'WITH x AS (SELECT 1 AS a) SELECT a FROM x' }
        @{ Sql = "SELECT 'DROP TABLE x; DELETE' AS t" }
        @{ Sql = 'SELECT [Update], [Into] FROM t' }
        @{ Sql = 'SELECT "Delete" FROM t' }
        @{ Sql = "-- note`nSELECT 1" }
        @{ Sql = 'SELECT a FROM t WITH (NOLOCK)' }
        @{ Sql = 'SELECT * FROM a.b.c' }
        @{ Sql = 'SELECT * FROM t /* DROP */' }
        @{ Sql = 'SELECT t1.a FROM t1 JOIN t2 ON t1.a = t2.a' }
        @{ Sql = 'SELECT * FROM t UNION ALL SELECT * FROM u' }
        @{ Sql = 'SELECT 1 OPTION (RECOMPILE)' }
    ) {
        { Invoke-InSqlModule { param($q) Assert-SqlQueryText -Sql $q } @($Sql) } | Should -Not -Throw
    }

    It 'refuses <Sql> with a message naming <Why>' -ForEach @(
        @{ Sql = 'DELETE FROM t'; Why = 'SELECT or WITH' }
        @{ Sql = 'UPDATE t SET a = 1'; Why = 'SELECT or WITH' }
        @{ Sql = 'EXEC sp_who'; Why = 'SELECT or WITH' }
        @{ Sql = 'DECLARE @a int SELECT @a'; Why = 'SELECT or WITH' }
        @{ Sql = 'SET ROWCOUNT 5'; Why = 'SELECT or WITH' }
        @{ Sql = ''; Why = 'empty' }
        @{ Sql = '   '; Why = 'empty' }
        @{ Sql = '-- only a comment'; Why = 'empty' }
        @{ Sql = 'SELECT * INTO #t FROM x'; Why = 'INTO' }
        @{ Sql = 'SELECT 1; SELECT 2'; Why = 'one statement' }
        @{ Sql = 'SELECT 1; DROP TABLE t'; Why = 'one statement' }
        @{ Sql = 'SELECT 1;;'; Why = 'one statement' }
        @{ Sql = 'SELECT * FROM OPENROWSET(a, b, c)'; Why = 'OPENROWSET' }
        @{ Sql = "SELECT * FROM OPENQUERY(s, 'x')"; Why = 'OPENQUERY' }
        @{ Sql = 'SELECT * FROM OPENDATASOURCE(a, b)'; Why = 'OPENDATASOURCE' }
        @{ Sql = 'SELECT xp_cmdshell'; Why = 'xp_cmdshell' }
        @{ Sql = 'WITH x AS (SELECT 1) DELETE FROM t'; Why = 'DELETE' }
        @{ Sql = 'SELECT 1 WAITFOR'; Why = 'WAITFOR' }
        @{ Sql = 'SELECT 1 GO'; Why = 'GO' }
        @{ Sql = 'SELECT * FROM srv.db.dbo.t'; Why = 'linked' }
        @{ Sql = 'SELECT * FROM [srv].[db].[dbo].[t]'; Why = 'linked' }
        @{ Sql = 'SELECT * FROM srv..dbo.t'; Why = 'linked' }
        @{ Sql = 'SELECT 1 /* open'; Why = 'unterminated' }
    ) {
        $ex = Get-Thrown { Invoke-InSqlModule { param($q) Assert-SqlQueryText -Sql $q } @($Sql) }
        $ex | Should -Not -BeNullOrEmpty
        $ex.Data['Kind'] | Should -Be 'REFUSED'
        $ex.Message | Should -BeLike "*$Why*"
    }

    It 'returns the statement without its trailing semicolon' {
        Invoke-InSqlModule { Assert-SqlQueryText -Sql '  SELECT 1 ;  ' } | Should -Be 'SELECT 1'
    }
}

Describe 'Assert-SqlWriteText' {
    BeforeAll { Initialize-SqlTest }

    It 'accepts <Sql> as <Verb>' -ForEach @(
        @{ Verb = 'INSERT'; Sql = 'INSERT INTO dbo.t (a, b) VALUES (1, 2)' }
        @{ Verb = 'INSERT'; Sql = 'INSERT t (a) SELECT x FROM u' }
        @{ Verb = 'INSERT'; Sql = 'INSERT INTO t DEFAULT VALUES' }
        @{ Verb = 'UPDATE'; Sql = 'UPDATE t SET a = 1 WHERE id = @id' }
        @{ Verb = 'UPDATE'; Sql = 'UPDATE TOP (5) t SET a = a + 1 WHERE b = 2;' }
        @{ Verb = 'UPDATE'; Sql = 'UPDATE t SET a = (SELECT MAX(x) FROM u) WHERE id = 1' }
        @{ Verb = 'UPDATE'; Sql = "update t set a = 'x; DROP' where id = 1" }
        @{ Verb = 'UPDATE'; Sql = 'UPDATE t SET a = CASE WHEN b > 1 THEN 1 ELSE 0 END WHERE id = 1' }
    ) {
        $r = Invoke-InSqlModule { param($q) Assert-SqlWriteText -Sql $q } @($Sql)
        $r.Verb | Should -Be $Verb
        $r.Sql | Should -Not -Match ';\s*$'
    }

    It 'refuses <Sql> with a message naming <Why>' -ForEach @(
        @{ Sql = 'DELETE FROM t'; Why = 'INSERT or UPDATE' }
        @{ Sql = 'MERGE t USING u ON 1=1 WHEN MATCHED THEN DELETE'; Why = 'INSERT or UPDATE' }
        @{ Sql = 'TRUNCATE TABLE t'; Why = 'INSERT or UPDATE' }
        @{ Sql = 'DROP TABLE t'; Why = 'INSERT or UPDATE' }
        @{ Sql = 'EXEC p'; Why = 'INSERT or UPDATE' }
        @{ Sql = 'SELECT 1'; Why = 'INSERT or UPDATE' }
        @{ Sql = ''; Why = 'empty' }
        @{ Sql = 'WITH x AS (SELECT 1 AS a) UPDATE t SET a = 1 WHERE 1 = 1'; Why = 'WITH' }
        @{ Sql = 'UPDATE t SET a = 1'; Why = 'WHERE' }
        @{ Sql = 'UPDATE t SET a = (SELECT 1 WHERE 1 = 1)'; Why = 'WHERE' }
        @{ Sql = 'INSERT INTO t (a) VALUES (1); DELETE FROM t'; Why = 'one statement' }
        @{ Sql = 'INSERT INTO t OUTPUT inserted.* VALUES (1)'; Why = 'OUTPUT' }
        @{ Sql = 'UPDATE t SET a = 1 OUTPUT deleted.a WHERE id = 1'; Why = 'OUTPUT' }
        @{ Sql = 'INSERT t SELECT * INTO u FROM v'; Why = 'INTO' }
        @{ Sql = 'UPDATE t SET a = 1 WHERE id = 1 UPDATE u SET c = 1 WHERE d = 1'; Why = 'UPDATE' }
        @{ Sql = 'UPDATE t SET a = 1 SET b = 2 WHERE x = 1'; Why = 'SET' }
        @{ Sql = 'UPDATE t SET a = 1 WHERE id IN (SELECT id FROM srv.db.dbo.x)'; Why = 'linked' }
        @{ Sql = 'INSERT INTO t VALUES (1) SET x = 1'; Why = 'SET' }
        @{ Sql = 'INSERT INTO t EXEC p'; Why = 'EXEC' }
        @{ Sql = 'INSERT INTO t (a) VALUES (1) DELETE FROM t'; Why = 'DELETE' }
    ) {
        $ex = Get-Thrown { Invoke-InSqlModule { param($q) Assert-SqlWriteText -Sql $q } @($Sql) }
        $ex | Should -Not -BeNullOrEmpty
        $ex.Data['Kind'] | Should -Be 'REFUSED'
        $ex.Message | Should -BeLike "*$Why*"
    }
}

Describe 'Add-SqlOutputClause' {
    BeforeAll { Initialize-SqlTest }

    It 'injects the OUTPUT clause for <Name>' -ForEach @(
        @{ Name = 'UPDATE with WHERE'; Verb = 'UPDATE'; Sql = 'UPDATE t SET a = 1 WHERE id = 2'; Want = "UPDATE t SET a = 1 OUTPUT deleted.*, N'' AS [__sa_sep], inserted.* WHERE id = 2" }
        @{ Name = 'UPDATE with FROM first'; Verb = 'UPDATE'; Sql = 'UPDATE t SET a = u.a FROM t JOIN u ON t.id = u.id WHERE u.x = 1'; Want = "UPDATE t SET a = u.a OUTPUT deleted.*, N'' AS [__sa_sep], inserted.* FROM t JOIN u ON t.id = u.id WHERE u.x = 1" }
        @{ Name = 'UPDATE with a subquery in SET'; Verb = 'UPDATE'; Sql = 'UPDATE t SET a = (SELECT MAX(x) FROM u WHERE y = 1) WHERE id = 2'; Want = "UPDATE t SET a = (SELECT MAX(x) FROM u WHERE y = 1) OUTPUT deleted.*, N'' AS [__sa_sep], inserted.* WHERE id = 2" }
        @{ Name = 'UPDATE TOP'; Verb = 'UPDATE'; Sql = 'UPDATE TOP (3) t SET a = 1 WHERE b = 2'; Want = "UPDATE TOP (3) t SET a = 1 OUTPUT deleted.*, N'' AS [__sa_sep], inserted.* WHERE b = 2" }
        @{ Name = 'UPDATE with OPTION'; Verb = 'UPDATE'; Sql = 'UPDATE t SET a = 1 WHERE b = 2 OPTION (RECOMPILE)'; Want = "UPDATE t SET a = 1 OUTPUT deleted.*, N'' AS [__sa_sep], inserted.* WHERE b = 2 OPTION (RECOMPILE)" }
        @{ Name = 'INSERT VALUES'; Verb = 'INSERT'; Sql = 'INSERT INTO t (a, b) VALUES (1, 2)'; Want = 'INSERT INTO t (a, b) OUTPUT inserted.* VALUES (1, 2)' }
        @{ Name = 'INSERT SELECT'; Verb = 'INSERT'; Sql = 'INSERT INTO t (a) SELECT a FROM u'; Want = 'INSERT INTO t (a) OUTPUT inserted.* SELECT a FROM u' }
        @{ Name = 'INSERT DEFAULT VALUES'; Verb = 'INSERT'; Sql = 'INSERT t DEFAULT VALUES'; Want = 'INSERT t OUTPUT inserted.* DEFAULT VALUES' }
        @{ Name = 'lower case INSERT'; Verb = 'INSERT'; Sql = 'insert into t (a) values (1)'; Want = 'insert into t (a) OUTPUT inserted.* values (1)' }
        @{ Name = 'an INSERT whose column list names Values'; Verb = 'INSERT'; Sql = 'INSERT INTO t ([Values], a) VALUES (1, 2)'; Want = 'INSERT INTO t ([Values], a) OUTPUT inserted.* VALUES (1, 2)' }
        @{ Name = 'an INSERT with a keyword inside a string'; Verb = 'INSERT'; Sql = "INSERT INTO t (a) VALUES ('SELECT')"; Want = "INSERT INTO t (a) OUTPUT inserted.* VALUES ('SELECT')" }
    ) {
        Invoke-InSqlModule { param($q, $v) Add-SqlOutputClause -Sql $q -Verb $v } @($Sql, $Verb) | Should -Be $Want
    }

    It 'returns $null when an INSERT has no place for OUTPUT' {
        Invoke-InSqlModule { Add-SqlOutputClause -Sql 'INSERT t (a) (SELECT 1)' -Verb 'INSERT' } | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-SqlQuery' {
    BeforeAll { Initialize-SqlTest }
    BeforeEach {
        Reset-SqlRoutes
        $null = New-SqlProject
    }

    It 'returns one object per row and sends the statement with a lock timeout, parameters and the row cap' {
        Add-SqlRoute -Like '*FROM dbo.Orders*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Id', 'Name') -Rows @(@(1, 'a'), @(2, 'b'))))
        $rows = @(Invoke-SqlQuery -Sql 'SELECT Id, Name FROM dbo.Orders WHERE Id > @id' -Parameters @{ id = 0 })
        $rows.Count | Should -Be 2
        $rows[1].Name | Should -Be 'b'
        $call = $global:SqlTestCalls[0]
        $call.Text | Should -BeLike 'SET LOCK_TIMEOUT 5000;*SELECT Id, Name FROM dbo.Orders WHERE Id > @id'
        $call.Params['@id'] | Should -Be 0
        $call.MaxRows | Should -Be 20
        $call.StopAfter | Should -Be 20
        $call.Cancel | Should -BeTrue
        $call.Timeout | Should -Be 30
        $global:SqlTestEvents | Should -Be @('open', 'close')
    }

    It 'refuses a statement before any connection is opened' {
        $ex = Get-Thrown { Invoke-SqlQuery -Sql 'DELETE FROM t' }
        $ex.Data['Kind'] | Should -Be 'REFUSED'
        $global:SqlTestEvents.Count | Should -Be 0
    }

    It 'honours -Top and caps it at 200 with a warning' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('a')))
        $null = Invoke-SqlQuery -Sql 'SELECT 1 AS a' -Top 5
        $global:SqlTestCalls[0].MaxRows | Should -Be 5
        $w = Invoke-SqlQuery -Sql 'SELECT 1 AS a' -Top 999 3>&1
        $global:SqlTestCalls[1].MaxRows | Should -Be 200
        @($w | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 1
    }

    It 'warns when rows were cut' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('a') -Rows @(, @(1)) -More -Total 2))
        $out = Invoke-SqlQuery -Sql 'SELECT a FROM t' -Top 1 3>&1
        $warn = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $warn.Count | Should -Be 1
        "$($warn[0].Message)" | Should -BeLike '*Rows cut*'
        @($out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }).Count | Should -Be 1
    }

    It 'masks secret-named columns and the server and database names inside cells' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Login', 'PasswordHash', 'Note') -Rows @(, @('bob', 'abc123', 'moved from sqlhost.test.invalid to TestDb1'))))
        $rows = @(Invoke-SqlQuery -Sql 'SELECT Login, PasswordHash, Note FROM Users')
        $rows[0].PasswordHash | Should -Be '***'
        Assert-NoSecret $rows
    }

    It 'maps a server error to a module error without server or database names' {
        Add-SqlRoute -Like '*' -Throw (New-FakeSqlError -Number 229 -Message "The SELECT permission was denied on the object 'T', database 'TestDb1' on sqlhost.test.invalid")
        $ex = Get-Thrown { Invoke-SqlQuery -Sql 'SELECT 1' }
        $ex.Data['Kind'] | Should -Be 'DENIED'
        $ex.Message | Should -BeLike 'SQL 229 :: *'
        Assert-NoSecret $ex.Message
        $global:SqlTestEvents | Should -Be @('open', 'close')
    }

    It 'reports a failed connection and runs nothing' {
        $global:SqlTestOpenError = (Invoke-InSqlModule { Get-SqlException -Message 'Cannot connect' -Number 53 -Kind 'CONNECT' })
        $ex = Get-Thrown { Invoke-SqlQuery -Sql 'SELECT 1' }
        $ex.Data['Kind'] | Should -Be 'CONNECT'
        $global:SqlTestCalls.Count | Should -Be 0
    }

    It 'reports a configuration problem before it opens anything' {
        Set-Location -LiteralPath $TestDrive
        $ex = Get-Thrown { Invoke-SqlQuery -Sql 'SELECT 1' -Path 'nope/appsettings.Development.json' }
        $ex.Data['Kind'] | Should -Be 'CONFIG'
        $global:SqlTestEvents.Count | Should -Be 0
    }

    It 'uses the connection entry picked with -Name and connects with integrated security' {
        $null = New-SqlProject -Json '{ "ConnectionStrings": { "One": "Server=s1.test.invalid;Database=d1", "Two": "Server=s2.test.invalid;Database=d2" } }'
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('a')))
        $null = Invoke-SqlQuery -Sql 'SELECT 1 AS a' -Name 'Two'
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $b.set_ConnectionString($global:SqlTestOpenStrings)
        $b['Data Source'] | Should -Be 's2.test.invalid'
        $b['Integrated Security'] | Should -Be $true
    }
}

Describe 'Assert-SqlProcName' {
    BeforeAll { Initialize-SqlTest }

    It 'normalizes <Name> to <Want>' -ForEach @(
        @{ Name = 'dbo.Proc'; Want = '[dbo].[Proc]' }
        @{ Name = 'Proc'; Want = '[Proc]' }
        @{ Name = '[my schema].[my proc]'; Want = '[my schema].[my proc]' }
        @{ Name = 'dbo.[a b]'; Want = '[dbo].[a b]' }
        @{ Name = 'Sales.usp_Get_Orders'; Want = '[Sales].[usp_Get_Orders]' }
    ) {
        Invoke-InSqlModule { param($n) Assert-SqlProcName -Name $n } @($Name) | Should -Be $Want
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'srv.db.dbo.p' }, @{ Name = 'db.dbo.p' }, @{ Name = 'xp_cmdshell' }, @{ Name = 'dbo.xp_x' }
        @{ Name = '[dbo].[xp_x]' }, @{ Name = 'sp_executesql' }, @{ Name = 'dbo.sp_OACreate' }, @{ Name = 'SP_HELP' }
        @{ Name = 'a b' }, @{ Name = 'a;b' }, @{ Name = '' }, @{ Name = "a'b" }, @{ Name = 'dbo.' }, @{ Name = '.p' }
        @{ Name = 'a..b' }, @{ Name = 'p; DROP TABLE t' }, @{ Name = 'p --x' }
    ) {
        $ex = Get-Thrown { Invoke-InSqlModule { param($n) Assert-SqlProcName -Name $n } @($Name) }
        $ex.Data['Kind'] | Should -Be 'REFUSED'
    }

    It 'allows system-looking names only with -AllowSystem and still refuses three parts' {
        Invoke-InSqlModule { Assert-SqlProcName -Name 'dbo.sp_x' -AllowSystem } | Should -Be '[dbo].[sp_x]'
        $ex = Get-Thrown { Invoke-InSqlModule { Assert-SqlProcName -Name 'db.dbo.p' -AllowSystem } }
        $ex.Data['Kind'] | Should -Be 'REFUSED'
    }
}

Describe 'Schema functions' {
    BeforeAll { Initialize-SqlTest }
    BeforeEach {
        Reset-SqlRoutes
        $null = New-SqlProject
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Schema', 'Name') -Rows @(, @('dbo', 'Orders'))))
    }

    It 'Get-SqlTable lists user tables and views filtered by -Like (default all) with -Top' {
        $rows = @(Get-SqlTable)
        $rows[0].Name | Should -Be 'Orders'
        $global:SqlTestCalls[0].Params['@like'] | Should -Be '%'
        $global:SqlTestCalls[0].Text | Should -BeLike '*sys.objects*'
        $null = Get-SqlTable -Like 'Ord%' -Top 7
        $global:SqlTestCalls[1].Params['@like'] | Should -Be 'Ord%'
        $global:SqlTestCalls[1].MaxRows | Should -Be 7
    }

    It 'Get-SqlColumn needs -Table and passes both patterns as parameters' {
        $null = Get-SqlColumn -Table 'Orders' -Like 'Cust%'
        $call = $global:SqlTestCalls[0]
        $call.Text | Should -BeLike '*sys.columns*'
        $call.Params['@table'] | Should -Be 'Orders'
        $call.Params['@like'] | Should -Be 'Cust%'
        { Get-SqlColumn } | Should -Throw
    }

    It 'Get-SqlIndex reads the index catalog for the table pattern' {
        $null = Get-SqlIndex -Table 'Orders'
        $global:SqlTestCalls[0].Text | Should -BeLike '*sys.indexes*'
        $global:SqlTestCalls[0].Params['@table'] | Should -Be 'Orders'
    }

    It 'Get-SqlForeignKey reads the foreign key catalog for the table pattern' {
        $null = Get-SqlForeignKey -Table 'Orders'
        $global:SqlTestCalls[0].Text | Should -BeLike '*sys.foreign_keys*'
        $global:SqlTestCalls[0].Params['@table'] | Should -Be 'Orders'
    }

    It 'Get-SqlProc lists procedures and functions by -Like' {
        $null = Get-SqlProc -Like 'usp%' -Top 3
        $global:SqlTestCalls[0].Text | Should -BeLike '*sys.objects*'
        $global:SqlTestCalls[0].Params['@like'] | Should -Be 'usp%'
        $global:SqlTestCalls[0].MaxRows | Should -Be 3
    }

    It 'passes a hostile pattern only as a parameter value' {
        $null = Get-SqlTable -Like "x'; DROP TABLE t; --"
        $global:SqlTestCalls[0].Text | Should -Not -Match 'DROP TABLE'
        $global:SqlTestCalls[0].Params['@like'] | Should -Be "x'; DROP TABLE t; --"
    }

    It 'never names an output column like a secret, so the masking does not hide catalog facts' {
        $null = Get-SqlTable
        $null = Get-SqlColumn -Table 'x'
        $null = Get-SqlIndex -Table 'x'
        $null = Get-SqlForeignKey -Table 'x'
        $null = Get-SqlProc
        foreach ($call in $global:SqlTestCalls) {
            $aliases = [regex]::Matches($call.Text, '(?i)\bAS\s+\[(\w+)\]') | ForEach-Object { $_.Groups[1].Value }
            $aliases.Count | Should -BeGreaterThan 0
            @($aliases | Where-Object { $_ -match '(?i)password|passwd|pwd|secret|token|hash|key' }) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-SqlDefinition' {
    BeforeAll { Initialize-SqlTest }
    BeforeEach {
        Reset-SqlRoutes
        $null = New-SqlProject
    }

    It 'asks for the quoted object name as a parameter and returns the definition' {
        Add-SqlRoute -Like '*sys.sql_modules*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Schema', 'Name', 'Type', 'Definition') -Rows @(, @('dbo', 'GetOrders', 'SQL_STORED_PROCEDURE', 'CREATE PROC dbo.GetOrders AS SELECT 1'))))
        $d = Get-SqlDefinition -Object 'dbo.GetOrders'
        $global:SqlTestCalls[0].Params['@obj'] | Should -Be '[dbo].[GetOrders]'
        $d.Name | Should -Be 'GetOrders'
        $d.Definition | Should -Be 'CREATE PROC dbo.GetOrders AS SELECT 1'
        $d.Truncated | Should -BeFalse
    }

    It 'allows a system-looking name because it only reads the catalog' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Schema', 'Name', 'Type', 'Definition') -Rows @(, @('sys', 'sp_x', 'SQL_STORED_PROCEDURE', 'x'))))
        { Get-SqlDefinition -Object 'sys.sp_x' } | Should -Not -Throw
    }

    It 'cuts a long definition at 8000 characters and says so' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Schema', 'Name', 'Type', 'Definition') -Rows @(, @('dbo', 'P', 'SQL_STORED_PROCEDURE', ('z' * 9000)))))
        $d = Get-SqlDefinition -Object 'dbo.P'
        $d.Definition.Length | Should -BeLessThan 8100
        $d.Definition | Should -BeLike ('z' * 8000 + '*')
        $d.Truncated | Should -BeTrue
        $d.Length | Should -Be 9000
    }

    It 'masks the server name and password-like text in the definition' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Schema', 'Name', 'Type', 'Definition') -Rows @(, @('dbo', 'P', 'SQL_STORED_PROCEDURE', "EXEC sqlhost.test.invalid.x.y; SET @pwd = 'a'; password=hunter2 in TestDb1"))))
        $null = New-SqlProject
        $d = Get-SqlDefinition -Object 'dbo.P'
        $d.Definition | Should -Not -Match 'hunter2'
        Assert-NoSecret $d
    }

    It 'throws when the object is not found' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Schema', 'Name', 'Type', 'Definition')))
        $ex = Get-Thrown { Get-SqlDefinition -Object 'dbo.Missing' }
        $ex.Data['Kind'] | Should -Be 'SQL'
        $ex.Message | Should -Match 'not found'
    }

    It 'returns a null definition for an encrypted module and says so' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Schema', 'Name', 'Type', 'Definition') -Rows @(, @('dbo', 'P', 'SQL_STORED_PROCEDURE', $null))))
        $d = Get-SqlDefinition -Object 'dbo.P'
        $d.Definition | Should -BeNullOrEmpty
        $d.Note | Should -Match 'encrypted'
    }

    It 'refuses a bad object name before connecting' {
        $ex = Get-Thrown { Get-SqlDefinition -Object 'a;b' }
        $ex.Data['Kind'] | Should -Be 'REFUSED'
        $global:SqlTestEvents.Count | Should -Be 0
    }
}

Describe 'Transactions, writes and procedures' {
    BeforeAll {
        Initialize-SqlTest
        $script:UpdSet = New-FakeSet -Columns @('Id', 'Name', '__sa_sep', 'Id_2', 'Name_2') -Rows @(, @(1, 'a', '', 1, 'b'))
        $script:InsSet = New-FakeSet -Columns @('Id', 'Name') -Rows @(, @(7, 'new'))

        function New-RcSet { param([int]$Count) New-FakeSet -Columns @('__sa_rc') -Rows @(, @($Count)) }

        # Maps every recorded batch to a short step label so tests can assert the order of the transaction.
        function Get-TxnSteps {
            @($global:SqlTestCalls | ForEach-Object {
                    if ($_.Type -eq [System.Data.CommandType]::StoredProcedure) { 'proc' }
                    elseif ($_.Text -like '*BEGIN TRAN*') { 'begin' }
                    elseif ($_.Text -like '*__sa_rc*') { 'stmt' }
                    elseif ($_.Text -eq 'SELECT @@TRANCOUNT') { 'trancount' }
                    elseif ($_.Text -like '*ROLLBACK TRAN*') { 'rollback' }
                    elseif ($_.Text -eq 'COMMIT TRAN') { 'commit' }
                    elseif ($_.Text -like '*is_primary_key*') { 'pk' }
                    elseif ($_.Text -like 'SELECT `* FROM*') { 'reread' }
                    else { 'other' }
                })
        }

        # The ordinary happy path: BEGIN works, the statement returns the given sets, @@TRANCOUNT is 1 each time asked.
        function Add-TxnRoutes {
            param($StatementSets = @(), $TranCounts = @(1, 1, 1))
            $global:TxnTranCounts = [System.Collections.Generic.Queue[int]]::new([int[]]$TranCounts)
            Add-SqlRoute -Like '*BEGIN TRAN*' -Result (New-FakeBatch)
            Add-SqlRoute -Like 'SELECT @@TRANCOUNT' -Handler { New-FakeBatch -Sets @((New-FakeSet -Columns @('c') -Rows @(, @($global:TxnTranCounts.Dequeue())))) }
            Add-SqlRoute -Like '*ROLLBACK TRAN*' -Result (New-FakeBatch)
            Add-SqlRoute -Like 'COMMIT TRAN' -Result (New-FakeBatch)
            if ($StatementSets.Count -gt 0) { Add-SqlRoute -Like '*__sa_rc*' -Result (New-FakeBatch -Sets $StatementSets) }
        }
    }
    BeforeEach {
        Reset-SqlRoutes
        $null = New-SqlProject
    }
    AfterAll { Remove-Variable -Name TxnTranCounts -Scope Global -ErrorAction SilentlyContinue }

    Context 'Invoke-SqlWrite dry run' {
        It 'rolls an UPDATE back, never commits, and shows old and new values of changed columns only' {
            Add-TxnRoutes -StatementSets @($script:UpdSet, (New-RcSet 1))
            $r = Invoke-SqlWrite -Sql 'UPDATE dbo.t SET Name = @n WHERE Id = @id' -Parameters @{ n = 'b'; id = 1 }
            Get-TxnSteps | Should -Be @('begin', 'stmt', 'trancount', 'rollback')
            $global:SqlTestEvents | Should -Be @('open', 'close')
            $r.Mode | Should -Be 'DryRun'
            $r.Action | Should -Be 'UPDATE'
            $r.RowsAffected | Should -Be 1
            $r.Capture | Should -Be 'OUTPUT'
            @($r.Changes).Count | Should -Be 1
            $r.Changes[0].Ref | Should -Be 1
            $r.Changes[0].Column | Should -Be 'Name'
            $r.Changes[0].Old | Should -Be 'a'
            $r.Changes[0].New | Should -Be 'b'
            $stmt = $global:SqlTestCalls[1]
            $stmt.Text | Should -BeLike '*OUTPUT deleted.*'
            $stmt.Params['@n'] | Should -Be 'b'
            $stmt.Params['@id'] | Should -Be 1
        }

        It 'starts the transaction with XACT_ABORT, a short lock timeout and BEGIN TRAN' {
            Add-TxnRoutes -StatementSets @($script:UpdSet, (New-RcSet 1))
            $null = Invoke-SqlWrite -Sql 'UPDATE t SET Name = 1 WHERE Id = 1'
            $global:SqlTestCalls[0].Text | Should -BeLike '*XACT_ABORT ON*LOCK_TIMEOUT 5000*BEGIN TRAN'
        }

        It 'shows the inserted rows for an INSERT' {
            Add-TxnRoutes -StatementSets @($script:InsSet, (New-RcSet 1))
            $r = Invoke-SqlWrite -Sql 'INSERT INTO dbo.t (Name) VALUES (@n)' -Parameters @{ n = 'new' }
            $r.Action | Should -Be 'INSERT'
            $r.Changes[0].Id | Should -Be 7
            $r.Changes[0].Name | Should -Be 'new'
            $global:SqlTestCalls[1].Text | Should -BeLike '*OUTPUT inserted.* VALUES*'
        }

        It 'reports an UPDATE that changes nothing' {
            $same = New-FakeSet -Columns @('Id', '__sa_sep', 'Id_2') -Rows @(, @(1, '', 1))
            Add-TxnRoutes -StatementSets @($same, (New-RcSet 1))
            $r = Invoke-SqlWrite -Sql 'UPDATE t SET Id = 1 WHERE Id = 1'
            $r.Changes[0].Column | Should -Be '(no change)'
        }

        It 'falls back to a count in a fresh transaction when the server rejects OUTPUT (error <Number>)' -ForEach @(
            @{ Number = 334 }, @{ Number = 4186 }
        ) {
            $state = @{ First = $true }
            Add-SqlRoute -Like '*BEGIN TRAN*' -Result (New-FakeBatch)
            Add-SqlRoute -Like 'SELECT @@TRANCOUNT' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('c') -Rows @(, @(1))))
            Add-SqlRoute -Like '*ROLLBACK TRAN*' -Result (New-FakeBatch)
            Add-SqlRoute -Like '*OUTPUT*__sa_rc*' -Throw (New-FakeSqlError -Number $Number -Message 'The target table of the DML statement cannot have any enabled triggers if the statement contains an OUTPUT clause without INTO clause.')
            Add-SqlRoute -Like '*__sa_rc*' -Result (New-FakeBatch -Sets @((New-RcSet 3)))
            $r = Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2'
            Get-TxnSteps | Should -Be @('begin', 'stmt', 'rollback', 'begin', 'stmt', 'trancount', 'rollback')
            $r.Capture | Should -Be 'CountOnly'
            $r.RowsAffected | Should -Be 3
            @($r.Changes).Count | Should -Be 0
            $r.Note | Should -Match 'OUTPUT'
            $global:SqlTestCalls[4].Text | Should -Not -Match 'OUTPUT'
        }

        It 'gives only the count when an INSERT has no place for OUTPUT' {
            Add-TxnRoutes -StatementSets @((New-RcSet 4))
            $r = Invoke-SqlWrite -Sql 'INSERT t (a) (SELECT 1)'
            $r.Capture | Should -Be 'CountOnly'
            $r.RowsAffected | Should -Be 4
            $r.Note | Should -Match 'OUTPUT'
            $global:SqlTestCalls[1].Text | Should -Not -Match 'OUTPUT'
        }

        It 'does not hide other errors as a count-only fallback, rolls back and closes' {
            Add-TxnRoutes
            Add-SqlRoute -Like '*__sa_rc*' -Throw (New-FakeSqlError -Number 547 -Message 'The statement conflicted with a constraint on sqlhost.test.invalid')
            $ex = Get-Thrown { Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' }
            $ex.Data['Kind'] | Should -Be 'SQL'
            $ex.Data['Number'] | Should -Be 547
            Assert-NoSecret $ex.Message
            Get-TxnSteps | Should -Be @('begin', 'stmt', 'rollback')
            $global:SqlTestEvents | Should -Be @('open', 'close')
        }

        It 'refuses and rolls back when the statement affects more than 10000 rows (OUTPUT cut off)' {
            $big = New-FakeSet -Columns @('Id', '__sa_sep', 'Id_2') -Rows @(, @(1, '', 2)) -More -Total 10001
            Add-TxnRoutes -StatementSets @($big, (New-RcSet 10001))
            $ex = Get-Thrown { Invoke-SqlWrite -Sql 'UPDATE t SET Id = Id + 1 WHERE Id > 0' }
            $ex.Data['Kind'] | Should -Be 'REFUSED'
            $ex.Message | Should -Match '10000'
            Get-TxnSteps | Should -Contain 'rollback'
            Get-TxnSteps | Should -Not -Contain 'commit'
        }

        It 'refuses and rolls back when a count-only statement affects more than 10000 rows' {
            Add-TxnRoutes -StatementSets @((New-RcSet 10001))
            $ex = Get-Thrown { Invoke-SqlWrite -Sql 'INSERT t (a) (SELECT 1)' -Commit -ExpectedRows 10001 }
            $ex.Data['Kind'] | Should -Be 'REFUSED'
            Get-TxnSteps | Should -Not -Contain 'commit'
        }

        It 'warns when old and new values are shown for fewer rows than were affected' {
            Add-TxnRoutes -StatementSets @($script:UpdSet, (New-RcSet 5))
            $out = Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' -Top 1 3>&1
            $warn = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warn.Count | Should -Be 1
            "$($warn[0].Message)" | Should -BeLike '*first 1 of 5*'
        }

        It 'reports TXN and rolls back when the transaction count is not 1 after the statement' {
            Add-TxnRoutes -StatementSets @($script:UpdSet, (New-RcSet 1)) -TranCounts @(0)
            $ex = Get-Thrown { Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' }
            $ex.Data['Kind'] | Should -Be 'TXN'
            Get-TxnSteps | Should -Be @('begin', 'stmt', 'trancount', 'rollback')
        }

        It 'refuses a bad statement or bad parameters before opening a connection' {
            (Get-Thrown { Invoke-SqlWrite -Sql 'DELETE FROM t' }).Data['Kind'] | Should -Be 'REFUSED'
            (Get-Thrown { Invoke-SqlWrite -Sql 'UPDATE t SET a = 1' }).Data['Kind'] | Should -Be 'REFUSED'
            (Get-Thrown { Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' -Parameters @{ 'x y' = 1 } }).Data['Kind'] | Should -Be 'REFUSED'
            $global:SqlTestEvents.Count | Should -Be 0
        }

        It 'does not accept -ExpectedRows without -Commit, and -Commit without -ExpectedRows' {
            { Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' -ExpectedRows 1 } | Should -Throw
            { Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' -Commit } | Should -Throw
            $global:SqlTestEvents.Count | Should -Be 0
        }

        It 'stays a dry run with -WhatIf even when -Commit is given' {
            Add-TxnRoutes -StatementSets @($script:UpdSet, (New-RcSet 1))
            $r = Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' -Commit -ExpectedRows 1 -WhatIf
            $r.Mode | Should -Be 'DryRun'
            Get-TxnSteps | Should -Not -Contain 'commit'
            $r.Note | Should -Match 'WhatIf'
        }
    }

    Context 'Invoke-SqlWrite commit' {
        It 'commits when the count matches and returns the re-read stored row by primary key' {
            Add-TxnRoutes -StatementSets @($script:UpdSet, (New-RcSet 1))
            Add-SqlRoute -Like '*is_primary_key*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Col') -Rows @(, @('Id'))))
            Add-SqlRoute -Like 'SELECT `* FROM `[dbo`].`[t`]*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Id', 'Name', 'Stamp') -Rows @(, @(1, 'b', 'trigger-set'))))
            $r = Invoke-SqlWrite -Sql 'UPDATE dbo.t SET Name = @n WHERE Id = @id' -Parameters @{ n = 'b'; id = 1 } -Commit -ExpectedRows 1
            Get-TxnSteps | Should -Be @('begin', 'stmt', 'trancount', 'commit', 'pk', 'reread')
            $r.Mode | Should -Be 'Committed'
            $r.Stored[0].Name | Should -Be 'b'
            $r.Stored[0].Stamp | Should -Be 'trigger-set'
            $pk = $global:SqlTestCalls | Where-Object { $_.Text -like '*is_primary_key*' }
            $pk.Params['@obj'] | Should -Be '[dbo].[t]'
            $reread = $global:SqlTestCalls | Where-Object { $_.Text -like 'SELECT `* FROM*' }
            $reread.Params['@k0_0'] | Should -Be 1
            $reread.Text | Should -BeLike '*[[]Id] = @k0_0*'
        }

        It 're-reads several rows with an OR of key groups, including composite keys' {
            $two = New-FakeSet -Columns @('A', 'B', 'V') -Rows @(@(1, 2, 'x'), @(3, 4, 'y'))
            Add-TxnRoutes -StatementSets @($two, (New-RcSet 2))
            Add-SqlRoute -Like '*is_primary_key*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Col') -Rows @(@('A'), @('B'))))
            Add-SqlRoute -Like 'SELECT `* FROM*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('A', 'B', 'V') -Rows @(@(1, 2, 'x'), @(3, 4, 'y'))))
            $r = Invoke-SqlWrite -Sql "INSERT INTO s.[my t] (A, B, V) SELECT 1, 2, 'x' UNION ALL SELECT 3, 4, 'y'" -Commit -ExpectedRows 2
            $reread = $global:SqlTestCalls | Where-Object { $_.Text -like 'SELECT `* FROM*' }
            $reread.Text | Should -BeLike '*[[]s].[[]my t]*'
            $reread.Params['@k0_0'] | Should -Be 1
            $reread.Params['@k0_1'] | Should -Be 2
            $reread.Params['@k1_0'] | Should -Be 3
            $reread.Params['@k1_1'] | Should -Be 4
            @($r.Stored).Count | Should -Be 2
        }

        It 'falls back to the OUTPUT values with a note when the table has no primary key' {
            Add-TxnRoutes -StatementSets @($script:InsSet, (New-RcSet 1))
            Add-SqlRoute -Like '*is_primary_key*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Col')))
            $r = Invoke-SqlWrite -Sql 'INSERT INTO dbo.t (Name) VALUES (1)' -Commit -ExpectedRows 1
            $r.Stored[0].Name | Should -Be 'new'
            $r.Note | Should -Match 'trigger'
            Get-TxnSteps | Should -Not -Contain 'reread'
        }

        It 'does not re-read for a target that is not a plain one or two part name' {
            Add-TxnRoutes -StatementSets @($script:InsSet, (New-RcSet 1))
            $r = Invoke-SqlWrite -Sql 'INSERT INTO #tmp (Name) VALUES (1)' -Commit -ExpectedRows 1
            $r.Stored[0].Name | Should -Be 'new'
            Get-TxnSteps | Should -Not -Contain 'pk'
        }

        It 'keeps the commit result when the re-read fails' {
            Add-TxnRoutes -StatementSets @($script:InsSet, (New-RcSet 1))
            Add-SqlRoute -Like '*is_primary_key*' -Throw (New-FakeSqlError -Number 229 -Message 'denied')
            $r = Invoke-SqlWrite -Sql 'INSERT INTO dbo.t (Name) VALUES (1)' -Commit -ExpectedRows 1
            $r.Mode | Should -Be 'Committed'
            $r.Note | Should -Match 're-read'
        }

        It 'rolls back and refuses when the count differs from -ExpectedRows, naming both numbers' {
            Add-TxnRoutes -StatementSets @($script:UpdSet, (New-RcSet 2))
            $ex = Get-Thrown { Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' -Commit -ExpectedRows 5 }
            $ex.Data['Kind'] | Should -Be 'REFUSED'
            $ex.Message | Should -BeLike '*expected 5, got 2; nothing written*'
            Get-TxnSteps | Should -Be @('begin', 'stmt', 'trancount', 'rollback')
        }

        It 'attempts a rollback when the COMMIT itself fails' {
            Add-TxnRoutes -StatementSets @($script:UpdSet, (New-RcSet 1))
            $global:SqlTestRoutes.RemoveAt(3)
            Add-SqlRoute -Like 'COMMIT TRAN' -Throw (New-FakeSqlError -Number 3903 -Message 'no transaction')
            $ex = Get-Thrown { Invoke-SqlWrite -Sql 'UPDATE t SET a = 1 WHERE b = 2' -Commit -ExpectedRows 1 }
            $ex.Data['Kind'] | Should -Be 'TXN'
            (Get-TxnSteps)[-1] | Should -Be 'rollback'
        }
    }

    Context 'Invoke-SqlProc' {
        BeforeEach { $script:ProcSet = New-FakeSet -Columns @('Id', 'Total') -Rows @(@(1, 10), @(2, 20)) }

        It 'runs the procedure in a transaction that is rolled back and shows return value, rows affected and result sets' {
            Add-TxnRoutes
            Add-SqlRoute -Like '[[]dbo].[[]usp_Recalc]' -Result (New-FakeBatch -Sets @($script:ProcSet) -RecordsAffected 2 -ReturnValue 0)
            $r = Invoke-SqlProc -Procedure 'dbo.usp_Recalc' -Parameters @{ year = 2026 }
            Get-TxnSteps | Should -Be @('begin', 'trancount', 'proc', 'trancount', 'rollback')
            $call = $global:SqlTestCalls[2]
            $call.Type | Should -Be ([System.Data.CommandType]::StoredProcedure)
            $call.Text | Should -Be '[dbo].[usp_Recalc]'
            $call.Params['@year'] | Should -Be 2026
            $call.MaxSets | Should -Be 5
            $r.Mode | Should -Be 'DryRun'
            $r.RowsAffected | Should -Be 2
            $r.ReturnValue | Should -Be 0
            $r.ResultSets[0].Columns | Should -Be @('Id', 'Total')
            @($r.ResultSets[0].Rows).Count | Should -Be 2
            $r.ResultSets[0].Rows[1].Total | Should -Be 20
        }

        It 'leaves XACT_ABORT at the session default for procedures' {
            Add-TxnRoutes
            Add-SqlRoute -Like '*' -Result (New-FakeBatch -RecordsAffected 0)
            $null = Invoke-SqlProc -Procedure 'dbo.p'
            $global:SqlTestCalls[0].Text | Should -Not -Match 'XACT_ABORT'
            $global:SqlTestCalls[0].Text | Should -BeLike '*BEGIN TRAN'
        }

        It 'reports TXN, rolls back and says the effect may be permanent when the procedure changed @@TRANCOUNT' {
            Add-TxnRoutes -TranCounts @(1, 0)
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -RecordsAffected 1)
            $ex = Get-Thrown { Invoke-SqlProc -Procedure 'dbo.p' }
            $ex.Data['Kind'] | Should -Be 'TXN'
            $ex.Message | Should -Match 'permanent'
            (Get-TxnSteps)[-1] | Should -Be 'rollback'
        }

        It 'reports TXN for server error <Number> raised by the procedure' -ForEach @(
            @{ Number = 266 }, @{ Number = 3902 }, @{ Number = 3903 }
        ) {
            Add-TxnRoutes
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Throw (New-FakeSqlError -Number $Number -Message 'Transaction count after EXECUTE indicates a mismatching number of BEGIN and COMMIT statements.')
            $ex = Get-Thrown { Invoke-SqlProc -Procedure 'dbo.p' }
            $ex.Data['Kind'] | Should -Be 'TXN'
            (Get-TxnSteps)[-1] | Should -Be 'rollback'
        }

        It 'maps an ordinary procedure error to its kind and still rolls back' {
            Add-TxnRoutes
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Throw (New-FakeSqlError -Number 229 -Message 'denied')
            $ex = Get-Thrown { Invoke-SqlProc -Procedure 'dbo.p' }
            $ex.Data['Kind'] | Should -Be 'DENIED'
            (Get-TxnSteps)[-1] | Should -Be 'rollback'
            $global:SqlTestEvents | Should -Be @('open', 'close')
        }

        It 'commits with a matching -ExpectedRows and shows rows affected and result sets again' {
            Add-TxnRoutes
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -Sets @($script:ProcSet) -RecordsAffected 3)
            $r = Invoke-SqlProc -Procedure 'dbo.p' -Commit -ExpectedRows 3
            Get-TxnSteps | Should -Be @('begin', 'trancount', 'proc', 'trancount', 'commit')
            $r.Mode | Should -Be 'Committed'
            $r.RowsAffected | Should -Be 3
            @($r.ResultSets[0].Rows).Count | Should -Be 2
        }

        It 'rolls back and refuses when rows affected differ from -ExpectedRows' {
            Add-TxnRoutes
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -RecordsAffected 3)
            $ex = Get-Thrown { Invoke-SqlProc -Procedure 'dbo.p' -Commit -ExpectedRows 2 }
            $ex.Data['Kind'] | Should -Be 'REFUSED'
            $ex.Message | Should -BeLike '*expected 2, got 3; nothing written*'
            Get-TxnSteps | Should -Not -Contain 'commit'
        }

        It 'accepts -ExpectedRows -1 only when the procedure reports -1 rows (SET NOCOUNT ON)' {
            Add-TxnRoutes -TranCounts @(1, 1, 1, 1)
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -RecordsAffected -1)
            $r = Invoke-SqlProc -Procedure 'dbo.p'
            $r.RowsAffected | Should -Be -1
            $r.Note | Should -Match 'NOCOUNT'
            $c = Invoke-SqlProc -Procedure 'dbo.p' -Commit -ExpectedRows -1
            $c.Mode | Should -Be 'Committed'
        }

        It 'refuses -ExpectedRows -1 when the procedure reports a real count, and a real count when it reports -1' {
            Add-TxnRoutes -TranCounts @(1, 1, 1, 1)
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -RecordsAffected 4)
            (Get-Thrown { Invoke-SqlProc -Procedure 'dbo.p' -Commit -ExpectedRows -1 }).Data['Kind'] | Should -Be 'REFUSED'
            Reset-SqlRoutes
            Add-TxnRoutes -TranCounts @(1, 1)
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -RecordsAffected -1)
            (Get-Thrown { Invoke-SqlProc -Procedure 'dbo.p' -Commit -ExpectedRows 4 }).Data['Kind'] | Should -Be 'REFUSED'
        }

        It 'refuses and rolls back when rows affected exceed 10000' {
            Add-TxnRoutes
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -RecordsAffected 10001)
            $ex = Get-Thrown { Invoke-SqlProc -Procedure 'dbo.p' -Commit -ExpectedRows 10001 }
            $ex.Data['Kind'] | Should -Be 'REFUSED'
            Get-TxnSteps | Should -Not -Contain 'commit'
        }

        It 'caps each result set at -Top rows and warns' {
            Add-TxnRoutes
            $cut = New-FakeSet -Columns @('Id') -Rows @(, @(1)) -Total 50
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -Sets @($cut) -RecordsAffected 0)
            $out = Invoke-SqlProc -Procedure 'dbo.p' -Top 1 3>&1
            @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 1
            $r = $out | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
            $r.ResultSets[0].TotalRows | Should -Be 50
            $global:SqlTestCalls[2].MaxRows | Should -Be 1
        }

        It 'refuses <Name> before opening a connection' -ForEach @(
            @{ Name = 'a system procedure'; Proc = 'sp_executesql'; Params = @{} }
            @{ Name = 'a linked server name'; Proc = 'srv.db.dbo.p'; Params = @{} }
            @{ Name = 'a bad parameter name'; Proc = 'dbo.p'; Params = @{ 'x;y' = 1 } }
            @{ Name = 'a list parameter value'; Proc = 'dbo.p'; Params = @{ ids = @(1, 2) } }
        ) {
            $ex = Get-Thrown { Invoke-SqlProc -Procedure $Proc -Parameters $Params }
            $ex.Data['Kind'] | Should -Be 'REFUSED'
            $global:SqlTestEvents.Count | Should -Be 0
        }

        It 'does not accept -Commit without -ExpectedRows' {
            { Invoke-SqlProc -Procedure 'dbo.p' -Commit } | Should -Throw
        }

        It 'stays a dry run with -WhatIf' {
            Add-TxnRoutes
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -RecordsAffected 1)
            $r = Invoke-SqlProc -Procedure 'dbo.p' -Commit -ExpectedRows 1 -WhatIf
            $r.Mode | Should -Be 'DryRun'
            Get-TxnSteps | Should -Not -Contain 'commit'
        }

        It 'never leaks server or database names in the output' {
            Add-TxnRoutes
            $leak = New-FakeSet -Columns @('Msg') -Rows @(, @('on sqlhost.test.invalid in TestDb1'))
            Add-SqlRoute -Like '[[]dbo].[[]p]' -Result (New-FakeBatch -Sets @($leak) -RecordsAffected 0)
            Assert-NoSecret (Invoke-SqlProc -Procedure 'dbo.p')
        }
    }
}

Describe 'Plan summary' {
    BeforeAll {
        Initialize-SqlTest
        $script:PlanXml = @'
<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.5" Build="13.0.4001.0">
 <BatchSequence><Batch><Statements>
  <StmtSimple StatementText="SELECT * FROM [TestDb1].[dbo].[Orders]" StatementSubTreeCost="10" StatementEstRows="500" StatementType="SELECT" StatementOptmEarlyAbortReason="TimeOut">
   <QueryPlan>
    <Warnings><PlanAffectingConvert ConvertIssue="Seek Plan" Expression="CONVERT_IMPLICIT(x)"/><NoJoinPredicate/></Warnings>
    <MissingIndexes>
     <MissingIndexGroup Impact="85.5">
      <MissingIndex Database="[TestDb1]" Schema="[dbo]" Table="[Orders]">
       <ColumnGroup Usage="EQUALITY"><Column Name="[CustomerId]" ColumnId="2"/><Column Name="[Region]" ColumnId="5"/></ColumnGroup>
       <ColumnGroup Usage="INEQUALITY"><Column Name="[Created]" ColumnId="3"/></ColumnGroup>
       <ColumnGroup Usage="INCLUDE"><Column Name="[Total]" ColumnId="4"/></ColumnGroup>
      </MissingIndex>
     </MissingIndexGroup>
    </MissingIndexes>
    <RelOp NodeId="0" PhysicalOp="Nested Loops" LogicalOp="Inner Join" EstimateRows="500" EstimatedTotalSubtreeCost="10">
     <NestedLoops>
      <RelOp NodeId="1" PhysicalOp="Clustered Index Scan" LogicalOp="Clustered Index Scan" EstimateRows="10000" EstimatedTotalSubtreeCost="6">
       <IndexScan><Object Database="[TestDb1]" Schema="[dbo]" Table="[Orders]" Index="[PK_Orders]" IndexKind="Clustered"/></IndexScan>
      </RelOp>
      <RelOp NodeId="2" PhysicalOp="Index Seek" LogicalOp="Index Seek" EstimateRows="1" EstimatedTotalSubtreeCost="3.5">
       <IndexScan><Object Database="[TestDb1]" Schema="[dbo]" Table="[Cust]" Index="[IX_Cust]"/></IndexScan>
      </RelOp>
     </NestedLoops>
    </RelOp>
   </QueryPlan>
  </StmtSimple>
 </Statements></Batch></BatchSequence>
</ShowPlanXML>
'@
        function Get-PlanSummary { Invoke-InSqlModule { param($x) ConvertFrom-SqlPlanXml -Xml $x } @($script:PlanXml) }
    }

    It 'summarizes statement cost, estimated rows and the early-abort reason' {
        $p = Get-PlanSummary
        $p.Cost | Should -Be 10
        $p.EstimatedRows | Should -Be 500
        $p.EarlyAbort | Should -Be 'TimeOut'
    }

    It 'ranks operators by their own cost as a share of the statement cost, without the database part' {
        $ops = @((Get-PlanSummary).TopOperators)
        $ops.Count | Should -Be 3
        $ops[0].NodeId | Should -Be 1
        $ops[0].Pct | Should -Be 60
        $ops[0].Operator | Should -Be 'Clustered Index Scan'
        $ops[0].Object | Should -Be 'dbo.Orders.PK_Orders'
        $ops[0].EstRows | Should -Be 10000
        $ops[1].NodeId | Should -Be 2
        $ops[1].Pct | Should -Be 35
        $ops[2].NodeId | Should -Be 0
        $ops[2].Pct | Should -Be 5
    }

    It 'lists scans, warnings and missing-index hints' {
        $p = Get-PlanSummary
        @($p.Scans).Count | Should -Be 1
        $p.Scans[0] | Should -BeLike '*dbo.Orders.PK_Orders*'
        @($p.Warnings) | Should -Be @('PlanAffectingConvert', 'NoJoinPredicate')
        $mi = @($p.MissingIndexes)
        $mi.Count | Should -Be 1
        $mi[0].Impact | Should -Be 85.5
        $mi[0].Table | Should -Be 'dbo.Orders'
        $mi[0].Equality | Should -Be 'CustomerId, Region'
        $mi[0].Inequality | Should -Be 'Created'
        $mi[0].Include | Should -Be 'Total'
    }

    It 'never returns raw XML or the statement text' {
        $json = ConvertTo-Json -InputObject (Get-PlanSummary) -Depth 6
        $json | Should -Not -Match 'ShowPlanXML|StatementText|SELECT \* FROM'
    }

    It 'limits the operator list to five' {
        $ops = (1..8 | ForEach-Object { "<RelOp NodeId=`"$_`" PhysicalOp=`"Compute Scalar`" LogicalOp=`"Compute Scalar`" EstimateRows=`"1`" EstimatedTotalSubtreeCost=`"$_`"><ComputeScalar/></RelOp>" }) -join ''
        $xml = "<ShowPlanXML xmlns=`"http://schemas.microsoft.com/sqlserver/2004/07/showplan`"><BatchSequence><Batch><Statements><StmtSimple StatementSubTreeCost=`"36`" StatementEstRows=`"1`"><QueryPlan>$ops</QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>"
        @((Invoke-InSqlModule { param($x) ConvertFrom-SqlPlanXml -Xml $x } @($xml)).TopOperators).Count | Should -Be 5
    }

    It 'reports XML that is not a plan as an error' {
        $ex = Get-Thrown { Invoke-InSqlModule { ConvertFrom-SqlPlanXml -Xml '<nope/>' } }
        $ex.Data['Kind'] | Should -Be 'ERROR'
        $ex = Get-Thrown { Invoke-InSqlModule { ConvertFrom-SqlPlanXml -Xml 'not xml at all' } }
        $ex.Data['Kind'] | Should -Be 'ERROR'
    }
}

Describe 'Get-SqlPlan' {
    BeforeAll {
        Initialize-SqlTest
        $script:PlanSet = New-FakeSet -Columns @('XML Showplan') -Rows @(, @('<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><BatchSequence><Batch><Statements><StmtSimple StatementSubTreeCost="1" StatementEstRows="2"><QueryPlan><RelOp NodeId="0" PhysicalOp="Table Scan" LogicalOp="Table Scan" EstimateRows="2" EstimatedTotalSubtreeCost="1"><TableScan><Object Database="[TestDb1]" Schema="[dbo]" Table="[t]"/></TableScan></RelOp></QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>'))
    }
    BeforeEach {
        Reset-SqlRoutes
        $null = New-SqlProject
        Add-SqlRoute -Like 'SET SHOWPLAN_XML ON' -Result (New-FakeBatch)
        Add-SqlRoute -Like 'SET SHOWPLAN_XML OFF' -Result (New-FakeBatch)
    }

    It 'turns SHOWPLAN on, asks for the plan of the statement with its parameters, turns it off and returns a summary' {
        Add-SqlRoute -Like 'SELECT * FROM dbo.t*' -Result (New-FakeBatch -Sets @($script:PlanSet))
        $p = Get-SqlPlan -Sql 'SELECT * FROM dbo.t WHERE a = @a' -Parameters @{ a = 1 }
        @($global:SqlTestCalls | ForEach-Object { $_.Text }) | Should -Be @('SET SHOWPLAN_XML ON', 'SELECT * FROM dbo.t WHERE a = @a', 'SET SHOWPLAN_XML OFF')
        $global:SqlTestCalls[1].Params['@a'] | Should -Be 1
        $global:SqlTestEvents | Should -Be @('open', 'close')
        $p.Cost | Should -Be 1
        $p.Scans[0] | Should -BeLike '*dbo.t*'
        Assert-NoSecret $p
    }

    It 'accepts an UPDATE for planning and still refuses anything else' {
        Add-SqlRoute -Like 'UPDATE*' -Result (New-FakeBatch -Sets @($script:PlanSet))
        { Get-SqlPlan -Sql 'UPDATE t SET a = 1 WHERE b = 2' } | Should -Not -Throw
        $global:SqlTestEvents.Clear()
        $ex = Get-Thrown { Get-SqlPlan -Sql 'DELETE FROM t' }
        $ex.Data['Kind'] | Should -Be 'REFUSED'
        $global:SqlTestEvents.Count | Should -Be 0
    }

    It 'turns SHOWPLAN off again and reports DENIED when the permission is missing (error 262)' {
        Add-SqlRoute -Like 'SELECT*' -Throw (New-FakeSqlError -Number 262 -Message 'SHOWPLAN permission denied in database TestDb1')
        $ex = Get-Thrown { Get-SqlPlan -Sql 'SELECT 1' }
        $ex.Data['Kind'] | Should -Be 'DENIED'
        Assert-NoSecret $ex.Message
        @($global:SqlTestCalls | ForEach-Object { $_.Text })[-1] | Should -Be 'SET SHOWPLAN_XML OFF'
        $global:SqlTestEvents | Should -Be @('open', 'close')
    }

    It 'still closes when turning SHOWPLAN off fails' {
        $global:SqlTestRoutes.Clear()
        Add-SqlRoute -Like 'SET SHOWPLAN_XML ON' -Result (New-FakeBatch)
        Add-SqlRoute -Like 'SELECT*' -Result (New-FakeBatch -Sets @($script:PlanSet))
        Add-SqlRoute -Like 'SET SHOWPLAN_XML OFF' -Throw (New-FakeSqlError -Number 208 -Message 'x')
        { Get-SqlPlan -Sql 'SELECT 1' } | Should -Not -Throw
        $global:SqlTestEvents | Should -Be @('open', 'close')
    }
}

Describe 'Diagnostics' {
    BeforeAll { Initialize-SqlTest }
    BeforeEach {
        Reset-SqlRoutes
        $null = New-SqlProject
    }

    Context 'Get-SqlTopQueries' {
        It 'orders by the whitelisted column for <By>' -ForEach @(
            @{ By = 'cpu'; Order = 'total_worker_time' }
            @{ By = 'reads'; Order = 'total_logical_reads' }
            @{ By = 'duration'; Order = 'total_elapsed_time' }
        ) {
            Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Count', 'Text') -Rows @(, @(3, 'SELECT 1'))))
            $null = Get-SqlTopQueries -By $By -Top 4
            $call = $global:SqlTestCalls[0]
            $call.Text | Should -BeLike "*ORDER BY qs.$Order DESC*"
            $call.Text | Should -BeLike '*sys.dm_exec_query_stats*'
            $call.Text | Should -BeLike '*DB_ID()*'
            $call.Params['@top'] | Should -Be 4
            $call.MaxRows | Should -Be 4
        }

        It 'defaults to cpu and rejects an unknown -By value' {
            Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Count')))
            $null = Get-SqlTopQueries
            $global:SqlTestCalls[0].Text | Should -BeLike '*ORDER BY qs.total_worker_time DESC*'
            { Get-SqlTopQueries -By 'cpu; DROP TABLE t' } | Should -Throw
        }

        It 'collapses whitespace in the statement text and masks names' {
            Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Count', 'Text') -Rows @(, @(3, "SELECT   a`r`n  FROM  sqlhost.test.invalid"))))
            $rows = @(Get-SqlTopQueries)
            $rows[0].Text | Should -Be 'SELECT a FROM <server>'
            Assert-NoSecret $rows
        }
    }

    Context 'Get-SqlBlocking' {
        It 'reads blocked requests and head blockers without logins or host names, excluding its own session' {
            Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Session', 'BlockedBy', 'Wait', 'WaitMs', 'Role', 'Text') -Rows @(, @(55, 60, 'LCK_M_X', 1200, 'blocked', 'UPDATE t SET a = 1'))))
            $rows = @(Get-SqlBlocking)
            $rows[0].Role | Should -Be 'blocked'
            $call = $global:SqlTestCalls[0]
            $call.Text | Should -BeLike '*sys.dm_exec_requests*'
            $call.Text | Should -BeLike '*@@SPID*'
            $call.Text | Should -Not -Match '(?i)login_name|host_name|program_name|nt_user'
        }
    }

    Context 'Get-SqlWaits' {
        It 'excludes benign waits and passes the row cap' {
            Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('Wait', 'Pct') -Rows @(, @('PAGEIOLATCH_SH', 12.5))))
            $rows = @(Get-SqlWaits -Top 3)
            $rows[0].Wait | Should -Be 'PAGEIOLATCH_SH'
            $call = $global:SqlTestCalls[0]
            $call.Text | Should -BeLike '*sys.dm_os_wait_stats*'
            $call.Text | Should -BeLike '*LAZYWRITER_SLEEP*'
            $call.Params['@top'] | Should -Be 3
        }
    }

    It '<Name> reports a missing VIEW SERVER STATE permission as one DENIED line' -ForEach @(
        @{ Name = 'Get-SqlTopQueries'; Call = { Get-SqlTopQueries } }
        @{ Name = 'Get-SqlBlocking'; Call = { Get-SqlBlocking } }
        @{ Name = 'Get-SqlWaits'; Call = { Get-SqlWaits } }
    ) {
        Add-SqlRoute -Like '*' -Throw (New-FakeSqlError -Number 300 -Message "VIEW SERVER STATE permission was denied on object 'server', database 'master'.`r`nThe user does not have permission on sqlhost.test.invalid")
        $ex = Get-Thrown $Call
        $ex.Data['Kind'] | Should -Be 'DENIED'
        $ex.Message | Should -Not -Match "[\r\n]"
        Assert-NoSecret $ex.Message
    }

    It 'uses only SQL Server 2016 features in every statement the read functions send' {
        Add-SqlRoute -Like '*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('a')))
        $null = Get-SqlTable
        $null = Get-SqlColumn -Table 'x'
        $null = Get-SqlIndex -Table 'x'
        $null = Get-SqlForeignKey -Table 'x'
        $null = Get-SqlProc
        $null = Get-SqlTopQueries
        $null = Get-SqlBlocking
        $null = Get-SqlWaits
        $global:SqlTestCalls.Count | Should -Be 8
        foreach ($call in $global:SqlTestCalls) {
            $call.Text | Should -Not -Match '(STRING_AGG|(?<![A-Za-z_])TRIM\(|CONCAT_WS|TRANSLATE\(|STRING_SPLIT|dm_exec_query_statistics_xml)'
        }
    }
}

Describe 'Test-SqlSetup' {
    BeforeAll {
        Initialize-SqlTest
        function Add-SetupRoutes {
            param([string]$Version = '13.0.4001.0', $ServerState = 1, $Showplan = 1)
            Add-SqlRoute -Like '*SERVERPROPERTY*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('v') -Rows @(, @($Version))))
            Add-SqlRoute -Like '*VIEW SERVER STATE*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('p') -Rows @(, @($ServerState))))
            Add-SqlRoute -Like '*SHOWPLAN*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('p') -Rows @(, @($Showplan))))
        }
        function Get-SetupMap {
            $map = [ordered]@{}
            foreach ($row in @(Test-SqlSetup @args)) { $map[$row.Area] = "$($row.Result) $($row.Code)".Trim() }
            return $map
        }
    }
    BeforeEach {
        Reset-SqlRoutes
        $null = New-SqlProject
    }

    It 'passes every area on a healthy 2016 server and reports the major version as the code' {
        Add-SetupRoutes
        $rows = @(Test-SqlSetup)
        ($rows | ForEach-Object { $_.Area }) | Should -Be @('Config', 'ConnString', 'Connect', 'Version', 'ServerState', 'Showplan')
        ($rows[0].PSObject.Properties.Name) | Should -Be @('Area', 'Result', 'Code')
        $map = [ordered]@{}
        foreach ($row in $rows) { $map[$row.Area] = "$($row.Result) $($row.Code)".Trim() }
        $map['Config'] | Should -Be 'PASS'
        $map['ConnString'] | Should -Be 'PASS'
        $map['Connect'] | Should -Be 'PASS'
        $map['Version'] | Should -Be 'PASS 13'
        $map['ServerState'] | Should -Be 'PASS'
        $map['Showplan'] | Should -Be 'PASS'
        $global:SqlTestEvents | Should -Be @('open', 'close')
        Assert-NoSecret $rows
    }

    It 'fails the version area below 13 and keeps the major number' {
        Add-SetupRoutes -Version '12.0.2000.8'
        (Get-SetupMap)['Version'] | Should -Be 'FAIL 12'
    }

    It 'fails ServerState and Showplan with DENIED when the permission is 0' {
        Add-SetupRoutes -ServerState 0 -Showplan 0
        $map = Get-SetupMap
        $map['ServerState'] | Should -Be 'FAIL DENIED'
        $map['Showplan'] | Should -Be 'FAIL DENIED'
    }

    It 'isolates a failing area: a server error in one probe does not hide the others' {
        Add-SqlRoute -Like '*SERVERPROPERTY*' -Throw (New-FakeSqlError -Number 229 -Message 'denied')
        Add-SqlRoute -Like '*VIEW SERVER STATE*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('p') -Rows @(, @(1))))
        Add-SqlRoute -Like '*SHOWPLAN*' -Result (New-FakeBatch -Sets @(New-FakeSet -Columns @('p') -Rows @(, @(1))))
        $map = Get-SetupMap
        $map['Version'] | Should -Be 'FAIL DENIED'
        $map['ServerState'] | Should -Be 'PASS'
    }

    It 'skips everything after a Config failure' {
        Set-Location -LiteralPath $TestDrive
        $map = Get-SetupMap -Path 'none/appsettings.Development.json'
        $map['Config'] | Should -Be 'FAIL CONFIG'
        foreach ($a in 'ConnString', 'Connect', 'Version', 'ServerState', 'Showplan') { $map[$a] | Should -Be 'SKIP' }
        $global:SqlTestEvents.Count | Should -Be 0
    }

    It 'fails ConnString for a SQL-login string and skips the rest without connecting' {
        $null = New-SqlProject -Json '{ "ConnectionStrings": { "Main": "Server=s1;Database=d1;User Id=u;Password=secretpw" } }'
        $rows = @(Test-SqlSetup)
        $map = [ordered]@{}
        foreach ($row in $rows) { $map[$row.Area] = "$($row.Result) $($row.Code)".Trim() }
        $map['Config'] | Should -Be 'PASS'
        $map['ConnString'] | Should -Be 'FAIL CONFIG'
        foreach ($a in 'Connect', 'Version', 'ServerState', 'Showplan') { $map[$a] | Should -Be 'SKIP' }
        $global:SqlTestEvents.Count | Should -Be 0
        (ConvertTo-Json -InputObject $rows) | Should -Not -Match 'secretpw'
    }

    It 'fails Connect with the error kind and skips the rest' {
        $global:SqlTestOpenError = (Invoke-InSqlModule { Get-SqlException -Message 'Login failed' -Number 18456 -Kind 'AUTH' })
        $map = Get-SetupMap
        $map['Connect'] | Should -Be 'FAIL AUTH'
        foreach ($a in 'Version', 'ServerState', 'Showplan') { $map[$a] | Should -Be 'SKIP' }
    }

    It 'does not read CLAUDE.md: a registration line there changes nothing' {
        Add-SetupRoutes
        Set-Content -LiteralPath (Join-Path (Get-Location).ProviderPath 'CLAUDE.md') -Value 'sql-access: appsettings=bad/appsettings.Development.json name=Nope'
        (Get-SetupMap)['Config'] | Should -Be 'PASS'
    }

    It 'passes -Path and -Name through to the lookup' {
        $null = New-SqlProject -Json '{ "ConnectionStrings": { "One": "Server=s1;Database=d1", "Two": "Server=s2;Database=d2" } }'
        Add-SetupRoutes
        (Get-SetupMap)['Config'] | Should -Be 'FAIL CONFIG'
        Reset-SqlRoutes
        Add-SetupRoutes
        (Get-SetupMap -Name 'Two')['Config'] | Should -Be 'PASS'
    }
}

# @@NEXT-TESTS@@
