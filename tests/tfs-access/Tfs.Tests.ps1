# Pester tests for user/skills/tfs-access/scripts/Tfs.psm1: static checks, config loading, and behaviour against a mocked Invoke-WebRequest (test-only, never shipped).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'user/skills/tfs-access/scripts'
    $script:ModuleSrc = Join-Path $script:ScriptsDir 'Tfs.psm1'
    $script:ConfigSrc = Join-Path $script:ScriptsDir 'tfs-config.psd1'
    $script:SettingsFile = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $script:TBase = 'https://tfs.test.invalid/tfs/Coll'
    $script:ValidConfig = "@{ CollectionUrl = '$($script:TBase)'; Project = 'Proj' }"
    $script:Hebrew = -join ([char[]](0x05E9, 0x05DC, 0x05D5, 0x05DD, 0x20, 0x05E2, 0x05D5, 0x05DC, 0x05DD))

    # Copies the module plus the given config text into a fresh folder under TestDrive and imports it. Returns the import warnings.
    function Import-TfsUnderTest {
        param([string]$ConfigBody = $script:ValidConfig, [switch]$UseShippedConfig)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -LiteralPath $script:ModuleSrc -Destination (Join-Path $dir 'Tfs.psm1')
        if ($UseShippedConfig) {
            Copy-Item -LiteralPath $script:ConfigSrc -Destination (Join-Path $dir 'tfs-config.psd1')
        }
        else {
            Set-Content -LiteralPath (Join-Path $dir 'tfs-config.psd1') -Value $ConfigBody -Encoding UTF8
        }
        Remove-Module Tfs -Force -ErrorAction SilentlyContinue
        $output = Import-Module (Join-Path $dir 'Tfs.psm1') -Force 3>&1
        return , @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
    }

    function New-WebResponse {
        param([string]$Content)
        [pscustomobject]@{
            StatusCode       = 200
            Content          = $Content
            RawContentStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($Content))
        }
    }

    function New-HttpError {
        param([int]$Code, [string]$Message = '')
        $ex = [System.Net.WebException]::new("The remote server returned an error: ($Code).")
        $resp = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]$Code }
        Add-Member -InputObject $ex -MemberType NoteProperty -Name Response -Value $resp -Force
        $rec = [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
        $rec.ErrorDetails = [System.Management.Automation.ErrorDetails]::new((ConvertTo-Json -InputObject @{ message = $Message } -Compress))
        return $rec
    }

    function New-PlainError {
        param([string]$Message = 'boom', [System.Exception]$Exception)
        if ($null -eq $Exception) { $Exception = [System.Exception]::new($Message) }
        return [System.Management.Automation.ErrorRecord]::new($Exception, 'PlainError', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    }

    function New-NetworkError {
        $ex = [System.Net.WebException]::new("The remote name could not be resolved: 'tfs.test.invalid'", [System.Net.WebExceptionStatus]::NameResolutionFailure)
        return [System.Management.Automation.ErrorRecord]::new($ex, 'WebCmdletWebResponseException', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    }

    # Routes are matched in the order added against "METHOD URI" with -like. Unmatched calls throw, so tests are strict.
    function Add-Route {
        param([string]$Like, $Json, [string]$Text, [System.Management.Automation.ErrorRecord]$ErrorRecord, [scriptblock]$Handler, [switch]$Empty)
        $route = @{ Like = $Like; Response = $null; ErrorRecord = $ErrorRecord; Handler = $Handler }
        if ($PSBoundParameters.ContainsKey('Json')) { $route.Response = New-WebResponse (ConvertTo-Json -InputObject $Json -Depth 20 -Compress) }
        elseif ($PSBoundParameters.ContainsKey('Text')) { $route.Response = New-WebResponse $Text }
        elseif ($Empty) { $route.Response = New-WebResponse '' }
        $global:TfsTestRoutes.Add($route)
    }

    function Register-WebMock {
        $global:TfsTestRoutes = [System.Collections.Generic.List[object]]::new()
        $global:TfsTestCalls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-WebRequest -ModuleName Tfs -MockWith {
            # [uri].ToString() unescapes, so use OriginalString to see what the module really asked for.
            $uriText = $Uri.OriginalString
            $bodyText = $null
            if ($Body -is [byte[]]) { $bodyText = [System.Text.Encoding]::UTF8.GetString($Body) }
            elseif ($null -ne $Body) { $bodyText = [string]$Body }
            $firstByte = $null
            if ($Body -is [byte[]] -and $Body.Length -gt 0) { $firstByte = $Body[0] }
            # pwsh 7.4 renamed the canonical parameter behind the TimeoutSec alias.
            $timeout = $null
            foreach ($name in 'TimeoutSec', 'ConnectionTimeoutSeconds', 'OperationTimeoutSeconds') {
                if ($null -eq $timeout -and $PesterBoundParameters.ContainsKey($name)) { $timeout = $PesterBoundParameters[$name] }
            }
            $global:TfsTestCalls.Add([pscustomobject]@{
                    Method = [string]$Method; Uri = $uriText; Body = $bodyText; BodyIsBytes = ($Body -is [byte[]])
                    FirstByte = $firstByte; ContentType = $PesterBoundParameters.ContentType; TimeoutSec = $timeout; MaxRedirect = $PesterBoundParameters['MaximumRedirection']; Bound = @($PesterBoundParameters.Keys)
                })
            foreach ($r in $global:TfsTestRoutes) {
                if ("$Method $uriText" -like $r.Like) {
                    if ($r.Handler) {
                        $out = & $r.Handler $uriText $Method $bodyText
                        if ($out -is [System.Management.Automation.ErrorRecord]) { throw $out }
                        return $out
                    }
                    if ($r.ErrorRecord) { throw $r.ErrorRecord }
                    return $r.Response
                }
            }
            throw "unexpected call: $Method $uriText"
        }
    }

    function Initialize-TfsTest {
        param([string]$ConfigBody = $script:ValidConfig)
        $null = Import-TfsUnderTest -ConfigBody $ConfigBody
        Register-WebMock
    }

    # Mirrors the structure of a real work item response, including URLs that contain the host.
    function New-WorkItem {
        param([int]$Id, [string]$Type = 'Task', [string]$State = 'Active', [string]$Title = 'A title', [hashtable]$ExtraFields = @{}, $Relations = $null)
        $fields = [ordered]@{
            'System.Id' = $Id; 'System.WorkItemType' = $Type; 'System.State' = $State; 'System.Title' = $Title
            'System.AreaPath' = 'Proj\Area'; 'System.IterationPath' = 'Proj\Sprint 1'; 'System.Tags' = 'a; b'
            'System.ChangedDate' = '2026-11-02T13:05:09.123Z'; 'System.Rev' = 3
        }
        foreach ($k in $ExtraFields.Keys) { $fields[$k] = $ExtraFields[$k] }
        $item = [ordered]@{ id = $Id; rev = 3; fields = $fields; url = "$($script:TBase)/_apis/wit/workItems/$Id" }
        if ($null -ne $Relations) { $item.relations = $Relations }
        return $item
    }

    function Assert-NoHost {
        param($Value)
        (ConvertTo-Json -InputObject $Value -Depth 10) | Should -Not -Match 'tfs\.test\.invalid'
    }

    function Reset-TfsRoutes {
        $global:TfsTestRoutes.Clear()
        $global:TfsTestCalls.Clear()
    }
}

AfterAll {
    Remove-Variable -Name TfsTestRoutes, TfsTestCalls, TfsTestGets, TfsTestWrites -Scope Global -ErrorAction SilentlyContinue
    Remove-Module Tfs -Force -ErrorAction SilentlyContinue
}

Describe 'Static checks' {
    It 'PSScriptAnalyzer reports zero findings with the 5.1 compatibility settings' {
        $findings = @(Invoke-ScriptAnalyzer -Path $script:ScriptsDir -Recurse -Settings $script:SettingsFile)
        ($findings | ForEach-Object { "$($_.RuleName) $($_.ScriptName):$($_.Line) $($_.Message)" }) | Should -BeNullOrEmpty
    }

    It 'ships <File> as UTF-8 BOM, CRLF and ASCII-only' -ForEach @(
        @{ File = 'Tfs.psm1' }, @{ File = 'tfs-config.psd1' }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:ScriptsDir $File))
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $body = $bytes[3..($bytes.Length - 1)]
        @($body | Where-Object { $_ -gt 127 }) | Should -BeNullOrEmpty
        $text = [System.Text.Encoding]::ASCII.GetString($body)
        ([regex]::Matches($text, "(?<!`r)`n")).Count | Should -Be 0
        $text | Should -Match "`r`n"
    }

    It 'never writes a variable followed by ? inside a URL string (PowerShell reads it as part of the name)' {
        $text = Get-Content -LiteralPath $script:ModuleSrc -Raw
        [regex]::Matches($text, '(?<!\{)\$[A-Za-z_]\w*\?') | Should -BeNullOrEmpty
    }

    It 'ships only the three documented placeholders and no organisation values' {
        $text = Get-Content -LiteralPath $script:ConfigSrc -Raw
        $found = [regex]::Matches($text, '<[A-Z][A-Z0-9_]*>') | ForEach-Object { $_.Value } | Sort-Object -Unique
        $found | Should -Be @('<COLLECTION>', '<PROJECT>', '<TFS_HOST>')
    }

    It 'contains no file-writing, certificate-bypass or other forbidden commands' {
        $text = Get-Content -LiteralPath $script:ModuleSrc -Raw
        [regex]::Matches($text, '\b(Out-File|Set-Content|Add-Content|New-Item|Export-Csv|Write-Host|SkipCertificateCheck|ServerCertificateValidationCallback)\b') | Should -BeNullOrEmpty
    }

    It 'exports exactly the 13 documented functions and nothing else' {
        $null = Import-TfsUnderTest
        $m = Get-Module Tfs
        @($m.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'Find-TfsRepo', 'Get-TfsBuildFailure', 'Get-TfsCommits', 'Get-TfsDailySummary', 'Get-TfsDeployed',
            'Get-TfsItem', 'Get-TfsMyItems', 'Get-TfsPR', 'Get-TfsTree', 'Invoke-Tfs', 'New-TfsItem', 'Set-TfsItem', 'Test-TfsSetup')
        @($m.ExportedVariables.Keys) | Should -BeNullOrEmpty
        @($m.ExportedAliases.Keys) | Should -BeNullOrEmpty
    }
}

Describe 'Config loading' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    It 'warns once on the shipped placeholder config and names the first placeholder with a relative path only' {
        $warnings = Import-TfsUnderTest -UseShippedConfig
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike '*placeholder <TFS_HOST> not replaced (key CollectionUrl) in scripts\tfs-config.psd1*'
        "$($warnings[0])" | Should -Not -Match ([regex]::Escape($TestDrive))
    }

    It '<Name> throws the stored config message and makes no web call on the placeholder config' -ForEach @(
        @{ Name = 'Invoke-Tfs'; Call = { Invoke-Tfs -Path '_apis/projects' } }
        @{ Name = 'Get-TfsMyItems'; Call = { Get-TfsMyItems } }
        @{ Name = 'Get-TfsItem'; Call = { Get-TfsItem -Id 1 } }
        @{ Name = 'Get-TfsTree'; Call = { Get-TfsTree -Id 1 } }
        @{ Name = 'Find-TfsRepo'; Call = { Find-TfsRepo } }
        @{ Name = 'Get-TfsPR'; Call = { Get-TfsPR } }
        @{ Name = 'Get-TfsCommits'; Call = { Get-TfsCommits -Repo r } }
        @{ Name = 'Get-TfsBuildFailure'; Call = { Get-TfsBuildFailure -Id 1 } }
        @{ Name = 'Get-TfsDeployed'; Call = { Get-TfsDeployed -Definition d } }
        @{ Name = 'Get-TfsDailySummary'; Call = { Get-TfsDailySummary } }
        @{ Name = 'New-TfsItem'; Call = { New-TfsItem -Type Bug -Title t } }
        @{ Name = 'Set-TfsItem'; Call = { Set-TfsItem -Id 1 -Fields @{ 'System.Title' = 'x' } } }
    ) {
        $null = Import-TfsUnderTest -UseShippedConfig
        Register-WebMock
        $Call | Should -Throw '*placeholder <TFS_HOST> not replaced*'
        $global:TfsTestCalls.Count | Should -Be 0
    }

    It 'a valid config sets the globals Base and Proj with the trailing slash trimmed' {
        $null = Import-TfsUnderTest -ConfigBody "@{ CollectionUrl = 'https://tfs.test.invalid/tfs/Coll/'; Project = 'Proj' }"
        $global:Base | Should -Be 'https://tfs.test.invalid/tfs/Coll'
        $global:Proj | Should -Be 'Proj'
    }

    It 'merges unspecified keys from the defaults and lets the file override them' {
        $null = Import-TfsUnderTest -ConfigBody "@{ CollectionUrl = '$($script:TBase)'; Project = 'Proj'; DefaultTop = 5; MaxTop = 50 }"
        InModuleScope Tfs {
            $script:Cfg.DefaultTop | Should -Be 5
            $script:Cfg.MaxTop | Should -Be 50
            $script:Cfg.LogTailLines | Should -Be 40
            $script:Cfg.ClosedStates | Should -Be @('Closed', 'Done', 'Removed')
        }
    }

    It 'warns once that integrated auth is cleartext for an http CollectionUrl but still loads the config' {
        $warnings = Import-TfsUnderTest -ConfigBody "@{ CollectionUrl = 'http://tfs.test.invalid/tfs/Coll'; Project = 'Proj' }"
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike '*cleartext*'
        "$($warnings[0])" | Should -Not -Match 'tfs\.test\.invalid'
        $global:Base | Should -Be 'http://tfs.test.invalid/tfs/Coll'
    }

    It 'gives no warning for a valid https CollectionUrl' {
        (Import-TfsUnderTest).Count | Should -Be 0
    }

    It 'sets the console output encoding to UTF-8 without BOM on import so Hebrew output reads correctly' {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::ASCII }
        catch { Set-ItResult -Skipped -Because 'console encoding cannot be changed in this host'; return }
        $null = Import-TfsUnderTest
        [Console]::OutputEncoding.CodePage | Should -Be 65001
        [Console]::OutputEncoding.GetPreamble().Length | Should -Be 0
    }

    It 'rejects <Name> with a message naming the key, and clears the globals' -ForEach @(
        @{ Name = 'a zero DefaultTop'; Body = "@{ CollectionUrl = 'https://tfs.test.invalid/tfs/Coll'; Project = 'P'; DefaultTop = 0 }"; Expect = '*DefaultTop*' }
        @{ Name = 'a non-numeric TimeoutSec'; Body = "@{ CollectionUrl = 'https://tfs.test.invalid/tfs/Coll'; Project = 'P'; TimeoutSec = 'abc' }"; Expect = '*TimeoutSec*' }
        @{ Name = 'MaxTop below DefaultTop'; Body = "@{ CollectionUrl = 'https://tfs.test.invalid/tfs/Coll'; Project = 'P'; MaxTop = 5 }"; Expect = '*MaxTop*' }
        @{ Name = 'a CollectionUrl that is not a URL'; Body = "@{ CollectionUrl = 'not a url'; Project = 'P' }"; Expect = '*CollectionUrl*' }
        @{ Name = 'a missing Project'; Body = "@{ CollectionUrl = 'https://tfs.test.invalid/tfs/Coll' }"; Expect = '*Project*' }
        @{ Name = 'an empty ClosedStates list'; Body = "@{ CollectionUrl = 'https://tfs.test.invalid/tfs/Coll'; Project = 'P'; ClosedStates = @() }"; Expect = '*ClosedStates*' }
        @{ Name = 'a placeholder inside an array value'; Body = "@{ CollectionUrl = 'https://tfs.test.invalid/tfs/Coll'; Project = 'P'; ClosedStates = @('Closed', '<STATE>') }"; Expect = '*placeholder <STATE>*' }
    ) {
        $warnings = Import-TfsUnderTest -ConfigBody $Body
        $warnings.Count | Should -Be 1
        { Get-TfsMyItems } | Should -Throw $Expect
        Get-Variable -Name Base -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-Tfs' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    It 'appends api-version with ? when the path has no query' {
        Add-Route -Like 'GET *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '_apis/projects'
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/_apis/projects?api-version=6.0'
    }

    It 'appends api-version with & when the path already has a query, and honours -Ver' {
        Add-Route -Like 'GET *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path 'Proj/_apis/x?$top=1' -Ver '6.0-preview.3'
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/x?$top=1&api-version=6.0-preview.3'
    }

    It 'trims a leading slash from the path' {
        Add-Route -Like 'GET *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '/_apis/projects'
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/_apis/projects?api-version=6.0'
    }

    It 'sends integrated auth, basic parsing and no certificate bypass' {
        Add-Route -Like 'GET *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '_apis/projects'
        $c = $global:TfsTestCalls[0]
        $c.Bound | Should -Contain 'UseDefaultCredentials'
        $c.Bound | Should -Contain 'UseBasicParsing'
        $c.Bound | Should -Not -Contain 'SkipCertificateCheck'
    }

    It 'sends a Hebrew body as BOM-less UTF-8 bytes with a charset' {
        Add-Route -Like 'POST *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '_apis/x' -Method POST -Body @{ title = $script:Hebrew }
        $c = $global:TfsTestCalls[0]
        $c.BodyIsBytes | Should -BeTrue
        $c.FirstByte | Should -Be 0x7B
        $c.Body | Should -Be ('{"title":"' + $script:Hebrew + '"}')
        $c.ContentType | Should -Be 'application/json; charset=utf-8'
    }

    It 'keeps a one-element array body a JSON array' {
        Add-Route -Like 'PATCH *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '_apis/x' -Method PATCH -Body @([ordered]@{ op = 'add'; path = '/fields/System.Title'; value = 'a' }) -ContentType 'application/json-patch+json'
        $c = $global:TfsTestCalls[0]
        $c.Body | Should -Be '[{"op":"add","path":"/fields/System.Title","value":"a"}]'
        $c.ContentType | Should -Be 'application/json-patch+json; charset=utf-8'
    }

    It 'passes a string body through unchanged' {
        Add-Route -Like 'POST *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '_apis/x' -Method POST -Body '{"query":"a"}'
        $global:TfsTestCalls[0].Body | Should -Be '{"query":"a"}'
    }

    It 'sends no body or content type on a GET' {
        Add-Route -Like 'GET *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '_apis/x'
        $global:TfsTestCalls[0].Bound | Should -Not -Contain 'Body'
    }

    It 'returns $null for an empty response' {
        Add-Route -Like 'GET *' -Empty
        Invoke-Tfs -Path '_apis/x' | Should -BeNullOrEmpty
    }

    It 'returns a parsed object for JSON' {
        Add-Route -Like 'GET *' -Json @{ count = 2; value = @(@{ id = 1 }, @{ id = 2 }) }
        $r = Invoke-Tfs -Path '_apis/x'
        $r.count | Should -Be 2
        @($r.value).Count | Should -Be 2
        $r.value[1].id | Should -Be 2
    }

    It 'returns JSON-looking text unparsed with -Raw' {
        Add-Route -Like 'GET *' -Text '{"a":1}'
        $r = Invoke-Tfs -Path '_apis/x' -Raw
        $r | Should -BeOfType [string]
        $r | Should -Be '{"a":1}'
    }

    It 'decodes Hebrew response bytes as UTF-8' {
        Add-Route -Like 'GET *' -Json @{ name = $script:Hebrew }
        (Invoke-Tfs -Path '_apis/x').name | Should -Be $script:Hebrew
    }

    It 'turns an HTTP error into a new exception with code, method, path and server message' {
        Add-Route -Like 'GET *' -ErrorRecord (New-HttpError 404 'TF401232: Work item 5 does not exist')
        $err = { Invoke-Tfs -Path '_apis/wit/workitems/5' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Be 'HTTP 404 GET _apis/wit/workitems/5 :: TF401232: Work item 5 does not exist'
        $err.Exception.Data['StatusCode'] | Should -Be 404
        $err.Exception.InnerException | Should -BeNullOrEmpty
    }

    It 'masks the host and base URL when the server message contains them' {
        Add-Route -Like 'GET *' -ErrorRecord (New-HttpError 400 'Bad request to https://tfs.test.invalid/tfs/Coll/Proj/_apis and tfs.test.invalid')
        $err = { Invoke-Tfs -Path '_apis/x' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Be 'HTTP 400 GET _apis/x :: Bad request to <base>/Proj/_apis and <host>'
    }

    It 'reports a network failure as code 0 without leaking the host from the original message' {
        Add-Route -Like 'GET *' -ErrorRecord (New-NetworkError)
        $err = { Invoke-Tfs -Path '_apis/x' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Be 'HTTP 0 GET _apis/x :: NETWORK NameResolutionFailure'
        $err.Exception.Data['StatusCode'] | Should -Be 0
        $err.Exception.Message | Should -Not -Match 'tfs\.test\.invalid'
    }
}

Describe 'Invoke-Tfs configuration wiring' {
    BeforeAll { Initialize-TfsTest -ConfigBody "@{ CollectionUrl = '$($script:TBase)'; Project = 'Proj'; TimeoutSec = 7 }" }

    It 'passes the configured TimeoutSec to the web request' {
        Add-Route -Like 'GET *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '_apis/projects'
        $global:TfsTestCalls[0].TimeoutSec | Should -Be 7
    }
}

Describe 'Private helpers' {
    BeforeAll { $null = Import-TfsUnderTest }

    It 'Hide-TfsSecret turns <In> into <Out>' -ForEach @(
        @{ In = 'password=hunter2 next'; Out = 'password=*** next' }
        @{ In = 'DB connectionString: "Server=a;Pwd=b" end'; Out = 'DB connectionString=*** end' }
        @{ In = 'Authorization: Bearer abc.def.ghi'; Out = 'Authorization=*** ***' }
        @{ In = 'sent Bearer abcdef now'; Out = 'sent Bearer *** now' }
        @{ In = 'https://user:pw@internal/x'; Out = 'https://***@internal/x' }
        @{ In = 'jwt eyJhbGciOi.eyJzdWIiOjF9.sig_-x end'; Out = 'jwt *** end' }
        @{ In = 'pat a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5a1b2c3d4e5xy end'; Out = 'pat *** end' }
        @{ In = 'fetch https://tfs.test.invalid/tfs/Coll/Proj/_apis failed'; Out = 'fetch <base>/Proj/_apis failed' }
        @{ In = 'host tfs.test.invalid down'; Out = 'host <host> down' }
        @{ In = 'error CS1002: ; expected in Password policy docs'; Out = 'error CS1002: ; expected in Password policy docs' }
    ) {
        InModuleScope Tfs -Parameters @{ In = $In; Out = $Out } {
            Hide-TfsSecret -Text $In | Should -Be $Out
        }
    }

    It 'Hide-TfsSecret caps a very long line before any regex work and marks the cut' {
        InModuleScope Tfs {
            $line = 'a' * 100000
            $elapsed = Measure-Command { $script:out = Hide-TfsSecret -Text $line }
            $script:out.Length | Should -Be (4000 + '...[truncated]'.Length)
            $script:out | Should -BeLike '*...[[]truncated]'
            $elapsed.TotalSeconds | Should -BeLessThan 2
        }
    }

    It 'Get-TfsTop returns the default for 0, the value when in range, and caps with a warning' {
        InModuleScope Tfs {
            Get-TfsTop -Top 0 | Should -Be 20
            Get-TfsTop -Top 5 | Should -Be 5
            $capped = Get-TfsTop -Top 500 -WarningVariable w -WarningAction SilentlyContinue
            $capped | Should -Be 200
            "$w" | Should -Be 'Top capped at 200'
        }
    }

    It 'Format-TfsDate normalises strings, offsets and datetimes to UTC yyyy-MM-dd HH:mm' -ForEach @(
        @{ In = '2026-11-02T13:05:09.123Z'; Out = '2026-11-02 13:05' }
        @{ In = '2026-11-02T15:05:09+02:00'; Out = '2026-11-02 13:05' }
        @{ In = '2026-11-02T13:05:09'; Out = '2026-11-02 13:05' }
        @{ In = $null; Out = '' }
        @{ In = ''; Out = '' }
    ) {
        InModuleScope Tfs -Parameters @{ In = $In; Out = $Out } {
            Format-TfsDate -Value $In | Should -Be $Out
        }
    }

    It 'Format-TfsDate accepts a [datetime] as pwsh 7 produces' {
        InModuleScope Tfs {
            Format-TfsDate -Value ([datetime]::SpecifyKind([datetime]'2026-11-02 13:05:09', [System.DateTimeKind]::Utc)) | Should -Be '2026-11-02 13:05'
        }
    }

    It 'date helpers ignore the current culture (Hijri calendar must not change the year)' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            try { [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('ar-SA') } catch { Set-ItResult -Skipped -Because 'ar-SA culture not available' }
            InModuleScope Tfs {
                Format-TfsDate -Value '2026-11-02T13:05:09Z' | Should -Be '2026-11-02 13:05'
                ConvertTo-TfsUtcIso -Value ([datetime]::SpecifyKind([datetime]'2026-11-02 13:05:09', [System.DateTimeKind]::Utc)) | Should -Be '2026-11-02T13:05:09Z'
            }
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }

    It 'Format-TfsRef strips refs/heads/ only' {
        InModuleScope Tfs {
            Format-TfsRef -Ref 'refs/heads/feature/x' | Should -Be 'feature/x'
            Format-TfsRef -Ref 'refs/tags/v1' | Should -Be 'refs/tags/v1'
            Format-TfsRef -Ref $null | Should -Be ''
        }
    }

    It 'ConvertTo-TfsPsObject converts nested dictionaries and lists and keeps one-item and empty lists as arrays' {
        InModuleScope Tfs {
            $inner = [System.Collections.Generic.Dictionary[string, object]]::new()
            $inner['id'] = 7
            $one = [System.Collections.Generic.List[object]]::new(); $one.Add($inner)
            $root = [System.Collections.Generic.Dictionary[string, object]]::new()
            $root['value'] = $one
            $root['empty'] = [System.Collections.Generic.List[object]]::new()
            $root['name'] = 'n'
            $o = ConvertTo-TfsPsObject $root
            $o.name | Should -Be 'n'
            $o.value.GetType().IsArray | Should -BeTrue
            @($o.value).Count | Should -Be 1
            $o.value[0].id | Should -Be 7
            $o.empty.GetType().IsArray | Should -BeTrue
            $o.empty.Count | Should -Be 0
        }
    }

    It 'ConvertTo-TfsPsObject keeps keys that differ only in case by suffixing _2' {
        InModuleScope Tfs {
            $d = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            $d['a'] = 1; $d['A'] = 2
            $o = ConvertTo-TfsPsObject $d
            $o.a | Should -Be 1
            $o.A_2 | Should -Be 2
        }
    }
}

Describe 'Get-TfsMyItems' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function Add-BatchRoute {
            # Answers like the server: unordered (reversed) items for the requested ids.
            Add-Route -Like 'POST */_apis/wit/workitemsbatch?*' -Handler {
                param($Uri, $Method, $Body)
                $ids = @((ConvertFrom-Json $Body).ids)
                [array]::Reverse($ids)
                New-WebResponse (ConvertTo-Json -InputObject @{ count = $ids.Count; value = @($ids | ForEach-Object { New-WorkItem -Id $_ -Type 'Bug' -State 'Active' -Title "Item $_" }) } -Depth 20 -Compress)
            }
        }
    }

    It 'queries non-closed items assigned to @Me with the default top and the project from config' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @(@{ id = 5; url = "$($script:TBase)/_apis/wit/workItems/5" }) }
        Add-BatchRoute
        $null = Get-TfsMyItems
        $wiql = $global:TfsTestCalls[0]
        $wiql.Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/wit/wiql?$top=20&api-version=6.0'
        $q = (ConvertFrom-Json $wiql.Body).query
        $q | Should -Match ([regex]::Escape('[System.TeamProject] = @project'))
        $q | Should -Match ([regex]::Escape('[System.AssignedTo] = @Me'))
        $q | Should -Match ([regex]::Escape("[System.State] NOT IN ('Closed','Done','Removed')"))
        $q | Should -Match ([regex]::Escape('ORDER BY [System.ChangedDate] DESC') + '$')
    }

    It 'returns Id, Type, State and Title only, in WIQL order even when the batch answer is reordered' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @(@{ id = 30 }, @{ id = 10 }, @{ id = 20 }) }
        Add-BatchRoute
        $r = @(Get-TfsMyItems)
        @($r.Id) | Should -Be @(30, 10, 20)
        $r[0].PSObject.Properties.Name | Should -Be @('Id', 'Type', 'State', 'Title')
        $r[0].Title | Should -Be 'Item 30'
        $r[0].Type | Should -Be 'Bug'
        Assert-NoHost $r
    }

    It 'asks the batch endpoint for exactly the four fields' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @(@{ id = 1 }) }
        Add-BatchRoute
        $null = Get-TfsMyItems
        $batch = $global:TfsTestCalls[1]
        $batch.Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/_apis/wit/workitemsbatch?api-version=6.0'
        (ConvertFrom-Json $batch.Body).fields | Should -Be @('System.Id', 'System.WorkItemType', 'System.State', 'System.Title')
    }

    It 'sends a flat ids array to the batch endpoint, also for a single id (never nested)' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @(@{ id = 5 }) }
        Add-BatchRoute
        $null = Get-TfsMyItems
        $body = $global:TfsTestCalls[1].Body
        $body | Should -Match '"ids":\[5\]'
        $body | Should -Not -Match '\[\['
        @((ConvertFrom-Json $body).ids).Count | Should -Be 1
        (ConvertFrom-Json $body).ids | Should -BeOfType [long]
    }

    It 'makes no batch call and returns nothing when the query finds no items' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @() }
        @(Get-TfsMyItems).Count | Should -Be 0
        $global:TfsTestCalls.Count | Should -Be 1
    }

    It 'caps -Top at MaxTop with a warning and sends the capped value' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @() }
        $null = Get-TfsMyItems -Top 999 -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Be 'Top capped at 200'
        $global:TfsTestCalls[0].Uri | Should -BeLike '*wiql?$top=200&*'
    }
}

Describe 'Get-TfsMyItems configuration wiring' {
    BeforeAll { Initialize-TfsTest -ConfigBody "@{ CollectionUrl = '$($script:TBase)'; Project = 'Proj'; MaxTop = 300; ClosedStates = @('Done', `"It's`") }" }
    BeforeEach { Reset-TfsRoutes }

    It 'doubles single quotes in configured closed states' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @() }
        $null = Get-TfsMyItems
        (ConvertFrom-Json $global:TfsTestCalls[0].Body).query | Should -BeLike "*NOT IN ('Done','It''s')*"
    }

    It 'splits 250 ids into batch calls of at most 200 and keeps every item' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @(1..250 | ForEach-Object { @{ id = $_ } }) }
        Add-Route -Like 'POST */_apis/wit/workitemsbatch?*' -Handler {
            param($Uri, $Method, $Body)
            $ids = @((ConvertFrom-Json $Body).ids)
            New-WebResponse (ConvertTo-Json -InputObject @{ count = $ids.Count; value = @($ids | ForEach-Object { New-WorkItem -Id $_ }) } -Depth 20 -Compress)
        }
        $r = @(Get-TfsMyItems -Top 250)
        $batches = @($global:TfsTestCalls | Where-Object { $_.Uri -like '*workitemsbatch*' })
        $batches.Count | Should -Be 2
        @((ConvertFrom-Json $batches[0].Body).ids).Count | Should -Be 200
        @((ConvertFrom-Json $batches[1].Body).ids).Count | Should -Be 50
        $r.Count | Should -Be 250
        $r[249].Id | Should -Be 250
    }
}

Describe 'Get-TfsItem' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    It 'reads the default fields with ?fields= and returns the documented properties' {
        Add-Route -Like 'GET *workitems/42?*' -Json (New-WorkItem -Id 42 -Type 'User Story' -State 'New' -Title $script:Hebrew)
        $r = Get-TfsItem -Id 42
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/_apis/wit/workitems/42?fields=System.WorkItemType,System.State,System.Title,System.AreaPath,System.IterationPath,System.Tags,System.ChangedDate,System.Rev&api-version=6.0'
        $r.PSObject.Properties.Name | Should -Be @('Id', 'Type', 'State', 'Title', 'AreaPath', 'IterationPath', 'Tags', 'Changed', 'Rev')
        $r.Id | Should -Be 42
        $r.Type | Should -Be 'User Story'
        $r.Title | Should -Be $script:Hebrew
        $r.AreaPath | Should -Be 'Proj\Area'
        $r.Tags | Should -Be 'a; b'
        $r.Changed | Should -Be '2026-11-02 13:05'
        $r.Rev | Should -Be 3
        Assert-NoHost $r
    }

    It 'adds requested -Fields to the URL and the output, using displayName for identity values' {
        $extra = @{ 'System.AssignedTo' = @{ displayName = 'Dana Levi'; uniqueName = 'dana@example.invalid'; url = "$($script:TBase)/x" }; 'Custom.Size' = 5 }
        Add-Route -Like 'GET *workitems/7?*' -Json (New-WorkItem -Id 7 -ExtraFields $extra)
        $r = Get-TfsItem -Id 7 -Fields 'System.AssignedTo', 'Custom.Size'
        $global:TfsTestCalls[0].Uri | Should -BeLike '*System.Rev,System.AssignedTo,Custom.Size&api-version=6.0'
        $r.'System.AssignedTo' | Should -Be 'Dana Levi'
        $r.'Custom.Size' | Should -Be 5
        (ConvertTo-Json -InputObject $r) | Should -Not -Match 'example\.invalid'
    }

    It 'with -Links uses ?$expand=relations and never fields=, and parses relations without URLs' {
        $rels = @(
            @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "$($script:TBase)/_apis/wit/workItems/100"; attributes = @{ name = 'Parent' } }
            @{ rel = 'System.LinkTypes.Hierarchy-Forward'; url = "$($script:TBase)/_apis/wit/workItems/101"; attributes = @{ name = 'Child' } }
            @{ rel = 'ArtifactLink'; url = 'vstfs:///Git/Commit/aaaa1111%2fbbbb2222%2f0123456789abcdef0123456789abcdef01234567'; attributes = @{ name = 'Fixed in Commit' } }
            @{ rel = 'ArtifactLink'; url = 'vstfs:///Git/PullRequestId/aaaa1111%2fbbbb2222%2f77'; attributes = @{ name = 'Pull Request' } }
            @{ rel = 'Hyperlink'; url = 'https://tfs.test.invalid/wiki/page'; attributes = @{ name = 'Hyperlink' } }
        )
        Add-Route -Like 'GET *workitems/42?*' -Json (New-WorkItem -Id 42 -Relations $rels)
        $r = Get-TfsItem -Id 42 -Links
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/_apis/wit/workitems/42?$expand=relations&api-version=6.0'
        $global:TfsTestCalls[0].Uri | Should -Not -BeLike '*fields=*'
        $rel = @($r.Relations)
        $rel.Count | Should -Be 5
        $rel[0].PSObject.Properties.Name | Should -Be @('Rel', 'TargetId', 'Target', 'Name')
        $rel[0].Rel | Should -Be 'System.LinkTypes.Hierarchy-Reverse'
        $rel[0].TargetId | Should -Be 100
        $rel[0].TargetId | Should -BeOfType [int]
        $rel[0].Name | Should -Be 'Parent'
        $rel[1].TargetId | Should -Be 101
        $rel[2].Target | Should -Be 'Git/Commit'
        $rel[2].TargetId | Should -Be '0123456789abcdef0123456789abcdef01234567'
        $rel[3].Target | Should -Be 'Git/PullRequestId'
        $rel[3].TargetId | Should -Be '77'
        $rel[4].Target | Should -Be 'Hyperlink'
        $rel[4].TargetId | Should -BeNullOrEmpty
        Assert-NoHost $r
    }

    It 'returns an empty Relations array for an item without relations' {
        Add-Route -Like 'GET *workitems/8?*' -Json (New-WorkItem -Id 8)
        $r = Get-TfsItem -Id 8 -Links
        @($r.Relations).Count | Should -Be 0
        $r.PSObject.Properties.Name | Should -Contain 'Relations'
    }

    It 'lets a 404 propagate with its status code' {
        Add-Route -Like 'GET *' -ErrorRecord (New-HttpError 404 'gone')
        $err = { Get-TfsItem -Id 9 } | Should -Throw -PassThru
        $err.Exception.Data['StatusCode'] | Should -Be 404
    }
}

Describe 'Get-TfsTree' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function New-RelationFixture {
            # root 100; 101 and 102 under it; 103 under 101; 104 under 103
            param([switch]$ChildBeforeParent)
            $rel = { param($parent, $child) @{ rel = 'System.LinkTypes.Hierarchy-Forward'; source = @{ id = $parent; url = "$($script:TBase)/x" }; target = @{ id = $child; url = "$($script:TBase)/y" } } }
            $list = @(
                @{ rel = $null; source = $null; target = @{ id = 100; url = "$($script:TBase)/r" } }
                (& $rel 100 101)
                (& $rel 100 102)
            )
            if ($ChildBeforeParent) { $list += @((& $rel 103 104), (& $rel 101 103)) }
            else { $list += @((& $rel 101 103), (& $rel 103 104)) }
            @{ workItemRelations = $list }
        }
        function Add-TreeBatchRoute {
            $global:TfsTestStates = @{ 100 = 'Active'; 101 = 'Active'; 102 = 'New'; 103 = 'New'; 104 = 'Closed' }
            Add-Route -Like 'POST */_apis/wit/workitemsbatch[?]*' -Handler {
                param($Uri, $Method, $Body)
                $ids = @((ConvertFrom-Json $Body).ids)
                New-WebResponse (ConvertTo-Json -InputObject @{ value = @($ids | ForEach-Object { New-WorkItem -Id $_ -Type 'Task' -State $global:TfsTestStates[[int]$_] -Title "Item $_" }) } -Depth 20 -Compress)
            }
        }
    }
    AfterAll { Remove-Variable -Name TfsTestStates -Scope Global -ErrorAction SilentlyContinue }

    It 'runs a recursive WorkItemLinks query with an integer id and the Hierarchy-Forward link type' {
        Add-Route -Like 'POST *wiql*' -Json (New-RelationFixture)
        Add-TreeBatchRoute
        $null = Get-TfsTree -Id 100
        $wiql = $global:TfsTestCalls[0]
        $wiql.Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/wit/wiql?$top=20&api-version=6.0'
        $q = (ConvertFrom-Json $wiql.Body).query
        $q | Should -Match 'FROM WorkItemLinks WHERE'
        $q | Should -Match ([regex]::Escape('[Source].[System.Id] = 100 AND'))
        $q | Should -Match ([regex]::Escape("[System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward'"))
        $q | Should -Match ([regex]::Escape('MODE (Recursive)') + '$')
    }

    It 'returns Id, ParentId, Level, Type, State, Title rows with the root at level 0' {
        Add-Route -Like 'POST *wiql*' -Json (New-RelationFixture)
        Add-TreeBatchRoute
        $r = @(Get-TfsTree -Id 100)
        @($r.Id) | Should -Be @(100, 101, 102, 103, 104)
        $r[0].PSObject.Properties.Name | Should -Be @('Id', 'ParentId', 'Level', 'Type', 'State', 'Title')
        $r[0].ParentId | Should -BeNullOrEmpty
        @($r.Level) | Should -Be @(0, 1, 1, 2, 3)
        @($r.ParentId[1..4]) | Should -Be @(100, 100, 101, 103)
        $r[4].State | Should -Be 'Closed'
        $r[4].Title | Should -Be 'Item 104'
        Assert-NoHost $r
    }

    It 'computes levels correctly even when the server lists a child before its parent' {
        Add-Route -Like 'POST *wiql*' -Json (New-RelationFixture -ChildBeforeParent)
        Add-TreeBatchRoute
        $r = @(Get-TfsTree -Id 100)
        ($r | Where-Object { $_.Id -eq 104 }).Level | Should -Be 3
        ($r | Where-Object { $_.Id -eq 103 }).Level | Should -Be 2
    }

    It '-Depth 1 keeps only the root and its direct children and fetches only those ids' {
        Add-Route -Like 'POST *wiql*' -Json (New-RelationFixture)
        Add-TreeBatchRoute
        $r = @(Get-TfsTree -Id 100 -Depth 1)
        @($r.Id) | Should -Be @(100, 101, 102)
        @((ConvertFrom-Json $global:TfsTestCalls[1].Body).ids) | Should -Be @(100, 101, 102)
    }

    It '-Top limits the rows and is sent as the WIQL top' {
        Add-Route -Like 'POST *wiql*' -Json (New-RelationFixture)
        Add-TreeBatchRoute
        @(Get-TfsTree -Id 100 -Top 2).Count | Should -Be 2
        $global:TfsTestCalls[0].Uri | Should -BeLike '*wiql?$top=2&*'
    }

    It '-Summary returns the total and the counts by state, largest first' {
        Add-Route -Like 'POST *wiql*' -Json (New-RelationFixture)
        Add-TreeBatchRoute
        $r = Get-TfsTree -Id 100 -Summary
        $r.PSObject.Properties.Name | Should -Be @('Total', 'ByState')
        $r.Total | Should -Be 5
        @($r.ByState | ForEach-Object { "$($_.State)=$($_.Count)" }) | Should -Be @('Active=2', 'New=2', 'Closed=1')
    }

    It 'rejects an id that is not a positive integer before any web call' {
        { Get-TfsTree -Id 'Proj\5' } | Should -Throw
        { Get-TfsTree -Id 0 } | Should -Throw
        $global:TfsTestCalls.Count | Should -Be 0
    }

    It 'returns nothing and makes no batch call when the query returns no relations' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItemRelations = @() }
        @(Get-TfsTree -Id 100).Count | Should -Be 0
        $global:TfsTestCalls.Count | Should -Be 1
    }
}

Describe 'Find-TfsRepo' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    It 'filters by wildcard case-insensitively, sorts by name and returns Name, Id, DefaultBranch only' {
        $repos = @(
            @{ id = 'id-z'; name = 'zeta'; defaultBranch = 'refs/heads/main'; url = "$($script:TBase)/Proj/_apis/git/repositories/id-z" }
            @{ id = 'id-a'; name = 'Alpha'; defaultBranch = 'refs/heads/develop'; url = "$($script:TBase)/x" }
            @{ id = 'id-l'; name = 'alpine'; url = "$($script:TBase)/y" }
            @{ id = 'id-b'; name = 'beta'; defaultBranch = 'refs/heads/main' }
        )
        Add-Route -Like 'GET */Proj/_apis/git/repositories?api-version=6.0' -Json @{ count = 4; value = $repos }
        $r = @(Find-TfsRepo -Name 'al*')
        @($r.Name) | Should -Be @('Alpha', 'alpine')
        $r[0].PSObject.Properties.Name | Should -Be @('Name', 'Id', 'DefaultBranch')
        $r[0].DefaultBranch | Should -Be 'develop'
        $r[1].DefaultBranch | Should -BeNullOrEmpty
        Assert-NoHost $r
    }

    It 'returns only the first N after sorting, defaulting to the configured top' {
        $repos = @(1..30 | ForEach-Object { @{ id = "id$_"; name = ('repo{0:D2}' -f $_) } })
        Add-Route -Like 'GET *' -Json @{ value = $repos }
        @(Find-TfsRepo).Count | Should -Be 20
        $three = @(Find-TfsRepo -Top 3)
        @($three.Name) | Should -Be @('repo01', 'repo02', 'repo03')
    }

    It 'returns nothing when no repository matches' {
        Add-Route -Like 'GET *' -Json @{ value = @(@{ id = 'x'; name = 'beta' }) }
        @(Find-TfsRepo -Name 'zzz*').Count | Should -Be 0
    }
}

Describe 'Get-TfsPR' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function New-PrFixture {
            param([int]$Id)
            @{
                pullRequestId = $Id; title = "PR $Id"; status = 'active'; isDraft = $true; mergeStatus = 'succeeded'
                creationDate = '2026-11-02T13:05:09.5Z'; sourceRefName = 'refs/heads/feature/x'; targetRefName = 'refs/heads/main'
                repository = @{ id = 'rid'; name = 'svc'; url = "$($script:TBase)/Proj/_apis/git/repositories/rid" }
                createdBy = @{ displayName = 'Dana Levi'; uniqueName = 'dana@example.invalid' }
                url = "$($script:TBase)/Proj/_apis/git/repositories/rid/pullRequests/$Id"
            }
        }
    }

    It 'lists active PRs project-wide by default and returns the documented fields without the creator' {
        Add-Route -Like 'GET *' -Json @{ count = 1; value = @(New-PrFixture 12) }
        $r = @(Get-TfsPR)
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/git/pullrequests?searchCriteria.status=active&$top=20&api-version=6.0'
        $r[0].PSObject.Properties.Name | Should -Be @('Id', 'Title', 'Repo', 'Source', 'Target', 'Status', 'IsDraft', 'Created', 'MergeStatus')
        $r[0].Id | Should -Be 12
        $r[0].Repo | Should -Be 'svc'
        $r[0].Source | Should -Be 'feature/x'
        $r[0].Target | Should -Be 'main'
        $r[0].IsDraft | Should -BeTrue
        $r[0].Created | Should -Be '2026-11-02 13:05'
        $r[0].MergeStatus | Should -Be 'succeeded'
        (ConvertTo-Json -InputObject $r) | Should -Not -Match 'example\.invalid|Dana'
        Assert-NoHost $r
    }

    It 'uses the per-repository URL with an escaped repo name, the status, the target branch and top' {
        Add-Route -Like 'GET *' -Json @{ value = @() }
        $null = Get-TfsPR -Repo 'my repo' -Status completed -TargetBranch 'release/1.0' -Top 5
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/git/repositories/my%20repo/pullrequests?searchCriteria.status=completed&searchCriteria.targetRefName=refs/heads/release%2F1.0&$top=5&api-version=6.0'
    }

    It '-Active is a switch that means status active' {
        Add-Route -Like 'GET *' -Json @{ value = @() }
        $null = Get-TfsPR -Active
        $global:TfsTestCalls[0].Uri | Should -BeLike '*searchCriteria.status=active&*'
    }

    It '-Active together with another -Status throws instead of guessing' {
        Add-Route -Like 'GET *' -Json @{ value = @() }
        { Get-TfsPR -Active -Status completed } | Should -Throw '*-Active*-Status*'
        $global:TfsTestCalls.Count | Should -Be 0
    }

    It 'rejects a status outside active, completed, abandoned and all' {
        { Get-TfsPR -Status deleted } | Should -Throw
    }

    It 'defaults IsDraft to false when the server omits it' {
        $pr = New-PrFixture 3
        $pr.Remove('isDraft')
        Add-Route -Like 'GET *' -Json @{ value = @($pr) }
        @(Get-TfsPR)[0].IsDraft | Should -BeFalse
    }
}

Describe 'Get-TfsCommits' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function New-CommitFixture {
            param([string]$Sha, [string]$Comment)
            @{ commitId = $Sha; comment = $Comment; committer = @{ name = 'Dana'; email = 'dana@example.invalid'; date = '2026-11-02T13:05:09Z' }; url = "$($script:TBase)/Proj/_apis/git/repositories/r/commits/$Sha" }
        }
    }

    It 'sends the escaped branch as searchCriteria.itemVersion.version and the top as searchCriteria.$top' {
        Add-Route -Like 'GET *' -Json @{ value = @() }
        $null = Get-TfsCommits -Repo 'my repo' -Branch 'feature/x' -Top 7
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/git/repositories/my%20repo/commits?searchCriteria.itemVersion.version=feature%2Fx&searchCriteria.$top=7&api-version=6.0'
    }

    It 'omits the version criteria without -Branch so the server uses the default branch' {
        Add-Route -Like 'GET *' -Json @{ value = @() }
        $null = Get-TfsCommits -Repo 'svc'
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/git/repositories/svc/commits?searchCriteria.$top=20&api-version=6.0'
    }

    It 'returns an 8-character sha, the first comment line and a UTC date, with no committer data' {
        Add-Route -Like 'GET *' -Json @{ value = @(New-CommitFixture '0123456789abcdef0123456789abcdef01234567' "Fix the bug`n`nLong body text") }
        $r = @(Get-TfsCommits -Repo 'svc')
        $r[0].PSObject.Properties.Name | Should -Be @('Sha', 'Comment', 'Date')
        $r[0].Sha | Should -Be '01234567'
        $r[0].Comment | Should -Be 'Fix the bug'
        $r[0].Date | Should -Be '2026-11-02 13:05'
        (ConvertTo-Json -InputObject $r) | Should -Not -Match 'example\.invalid|Dana'
        Assert-NoHost $r
    }

    It 'cuts a long first line to 200 characters and survives a missing comment' {
        Add-Route -Like 'GET *' -Json @{ value = @((New-CommitFixture 'aaaaaaaabbbbbbbb' ('x' * 300)), (New-CommitFixture 'ccccccccdddddddd' $null)) }
        $r = @(Get-TfsCommits -Repo 'svc')
        $r[0].Comment.Length | Should -Be 200
        $r[1].Comment | Should -Be ''
    }
}

Describe 'Get-TfsBuildFailure' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        $script:Token52 = ('a1b2c3d4e5' * 5) + 'xy'
        function New-BuildFixture {
            @{
                id = 77; buildNumber = '20261102.3'; status = 'completed'; result = 'failed'
                sourceBranch = 'refs/heads/feature/x'; sourceVersion = '0123456789abcdef0123456789abcdef01234567'
                definition = @{ id = 5; name = 'CI svc'; url = "$($script:TBase)/Proj/_apis/build/Definitions/5" }
                requestedFor = @{ displayName = 'Dana Levi'; uniqueName = 'dana@example.invalid' }
                _links = @{ web = @{ href = "$($script:TBase)/Proj/_build/results?buildId=77" } }
            }
        }
        function New-TimelineFixture {
            param([int]$ErrorCount = 1)
            $errors = @(1..$ErrorCount | ForEach-Object { @{ type = 'error'; message = "error E$_ ; expected password=hunter2" } })
            @{ records = @(
                    @{ type = 'Stage'; name = 'Stage1'; result = 'failed'; log = $null; issues = @() }
                    @{ type = 'Job'; name = 'Job1'; result = 'failed'; log = @{ id = 3 }; issues = @() }
                    @{ type = 'Task'; name = 'Init'; result = 'succeeded'; log = @{ id = 8 }; issues = @() }
                    @{ type = 'Task'; name = 'Compile'; result = 'failed'; log = @{ id = 9; url = "$($script:TBase)/log/9" }; issues = @($errors + @{ type = 'warning'; message = 'just a warning' }) }
                    @{ type = 'Task'; name = 'Publish'; result = 'canceled'; log = @{ id = 10 }; issues = @() }
                )
            }
        }
        function Add-RangeLogRoute {
            # Serves lines "line N" for the requested startLine..endLine; the last lines carry secrets and the host.
            Add-Route -Like 'GET */_apis/build/builds/77/logs/9[?]*' -Handler {
                param($Uri, $Method, $Body)
                $start = 1; $end = 120
                if ($Uri -match 'startLine=(\d+)&endLine=(\d+)') { $start = [int]$Matches[1]; $end = [int]$Matches[2] }
                $lines = foreach ($i in $start..$end) {
                    switch ($i) {
                        118 { 'connect password=hunter2' }
                        119 { 'Authorization: Bearer abc.def.ghi' }
                        120 { "fetch https://tfs.test.invalid/tfs/Coll/x token $($script:Token52)" }
                        default { "line $i" }
                    }
                }
                New-WebResponse (($lines -join "`r`n") + "`r`n")
            }
        }
        function Add-BuildRoutes {
            param([int]$ErrorCount = 1, [switch]$NoLineCount)
            Add-Route -Like 'GET */_apis/build/builds/77[?]*' -Json (New-BuildFixture)
            Add-Route -Like 'GET */_apis/build/builds/77/timeline[?]*' -Json (New-TimelineFixture -ErrorCount $ErrorCount)
            if ($NoLineCount) { Add-Route -Like 'GET */_apis/build/builds/77/logs[?]*' -Json @{ value = @(@{ id = 9 }) } }
            else { Add-Route -Like 'GET */_apis/build/builds/77/logs[?]*' -Json @{ value = @(@{ id = 8; lineCount = 4 }, @{ id = 9; lineCount = 120 }) } }
        }
    }

    It 'returns the build facts, failed steps with tasks first, and no requester or URLs' {
        Add-BuildRoutes
        Add-RangeLogRoute
        $r = Get-TfsBuildFailure -Id 77
        $r.PSObject.Properties.Name | Should -Be @('Id', 'BuildNumber', 'Definition', 'Status', 'Result', 'Branch', 'Sha', 'FailedSteps', 'LogStep', 'LogTail')
        $r.Id | Should -Be 77
        $r.BuildNumber | Should -Be '20261102.3'
        $r.Definition | Should -Be 'CI svc'
        $r.Status | Should -Be 'completed'
        $r.Result | Should -Be 'failed'
        $r.Branch | Should -Be 'feature/x'
        $r.Sha | Should -Be '01234567'
        @($r.FailedSteps.Step) | Should -Be @('Compile', 'Publish', 'Stage1', 'Job1')
        @($r.FailedSteps.Result) | Should -Be @('failed', 'canceled', 'failed', 'failed')
        $r.FailedSteps[0].Type | Should -Be 'Task'
        $r.LogStep | Should -Be 'Compile'
        (ConvertTo-Json -InputObject $r -Depth 10) | Should -Not -Match 'example\.invalid|Dana'
        Assert-NoHost $r
    }

    It 'keeps only error issues, masked, at most 10 per step' {
        Add-BuildRoutes -ErrorCount 12
        Add-RangeLogRoute
        $r = Get-TfsBuildFailure -Id 77
        $errors = @($r.FailedSteps[0].Errors)
        $errors.Count | Should -Be 10
        $errors[0] | Should -Be 'error E1 ; expected password=***'
        @($r.FailedSteps[1].Errors).Count | Should -Be 0
    }

    It 'reads exactly the last 40 lines of the first failed task log using the line count' {
        Add-BuildRoutes
        Add-RangeLogRoute
        $r = Get-TfsBuildFailure -Id 77
        $logCall = $global:TfsTestCalls | Where-Object { $_.Uri -like '*/logs/9?*' }
        $logCall.Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/build/builds/77/logs/9?startLine=81&endLine=120&api-version=6.0'
        @($r.LogTail).Count | Should -Be 40
        $r.LogTail[0] | Should -Be 'line 81'
        $r.LogTail[36] | Should -Be 'line 117'
    }

    It 'masks passwords, bearer tokens, 52-character tokens and the host in the log tail' {
        Add-BuildRoutes
        Add-RangeLogRoute
        $tail = @((Get-TfsBuildFailure -Id 77).LogTail)
        $tail[37] | Should -Be 'connect password=***'
        $tail[38] | Should -Be 'Authorization=*** ***'
        $tail[39] | Should -Be 'fetch <base>/x token ***'
        ($tail -join "`n") | Should -Not -Match 'hunter2|abc\.def|tfs\.test\.invalid|a1b2c3d4e5'
    }

    It 'caps -TailLines at MaxLogTailLines with a warning and honours a smaller value' {
        Add-BuildRoutes
        Add-RangeLogRoute
        $null = Get-TfsBuildFailure -Id 77 -TailLines 500 -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Be 'TailLines capped at 200'
        ($global:TfsTestCalls | Where-Object { $_.Uri -like '*/logs/9?*' }).Uri | Should -BeLike '*logs/9?startLine=1&endLine=120&*'
        Reset-TfsRoutes
        Add-BuildRoutes
        Add-RangeLogRoute
        @((Get-TfsBuildFailure -Id 77 -TailLines 5).LogTail).Count | Should -Be 5
    }

    It 'still returns at most N lines when the server ignores the line range' {
        Add-BuildRoutes
        Add-Route -Like 'GET */_apis/build/builds/77/logs/9[?]*' -Text ((1..120 | ForEach-Object { "line $_" }) -join "`n")
        $tail = @((Get-TfsBuildFailure -Id 77).LogTail)
        $tail.Count | Should -Be 40
        $tail[39] | Should -Be 'line 120'
    }

    It 'fetches the whole log and tails it when the logs list has no line count' {
        Add-BuildRoutes -NoLineCount
        Add-Route -Like 'GET */_apis/build/builds/77/logs/9[?]api-version=6.0' -Text ((1..50 | ForEach-Object { "line $_" }) -join "`n")
        $tail = @((Get-TfsBuildFailure -Id 77 -TailLines 3).LogTail)
        $tail | Should -Be @('line 48', 'line 49', 'line 50')
    }

    It 'returns no log step and no log calls when no failed task has a log' {
        Add-Route -Like 'GET */_apis/build/builds/77[?]*' -Json (New-BuildFixture)
        Add-Route -Like 'GET */_apis/build/builds/77/timeline[?]*' -Json @{ records = @(@{ type = 'Stage'; name = 'S'; result = 'failed'; log = $null; issues = @() }) }
        $r = Get-TfsBuildFailure -Id 77
        $r.LogStep | Should -BeNullOrEmpty
        @($r.LogTail).Count | Should -Be 0
        @($global:TfsTestCalls | Where-Object { $_.Uri -like '*/logs*' }).Count | Should -Be 0
    }

    It 'copes with a build that never started (no timeline)' {
        Add-Route -Like 'GET */_apis/build/builds/77[?]*' -Json (New-BuildFixture)
        Add-Route -Like 'GET */_apis/build/builds/77/timeline[?]*' -Empty
        $r = Get-TfsBuildFailure -Id 77
        @($r.FailedSteps).Count | Should -Be 0
    }
}

Describe 'Get-TfsDeployed' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function New-ReleaseDefinitions {
            @{ value = @(
                    @{ id = 2; name = 'Svc-B'; environments = @(@{ id = 30; name = 'QA' }) }
                    @{ id = 1; name = 'Svc-A'; environments = @(@{ id = 10; name = 'Dev' }, @{ id = 20; name = 'Prod' }); url = "$($script:TBase)/x" }
                    @{ id = 3; name = 'Other'; environments = @(@{ id = 40; name = 'Dev' }) }
                )
            }
        }
        function New-DeploymentFixture {
            param([int]$ReleaseId, [string]$ReleaseName, [string]$Version)
            $release = @{ id = $ReleaseId; name = $ReleaseName; url = "$($script:TBase)/rel/$ReleaseId" }
            if ($Version) { $release.artifacts = @(@{ isPrimary = $false; definitionReference = @{ version = @{ name = 'other' } } }, @{ isPrimary = $true; definitionReference = @{ version = @{ name = $Version } } }) }
            @{ value = @(@{ id = 900; release = $release; completedOn = '2026-11-02T13:05:09Z'; deploymentStatus = 'succeeded'; requestedFor = @{ displayName = 'Dana Levi' } }) }
        }
    }

    It 'matches definitions by name text, sorted, and asks for the latest succeeded deployment per environment' {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        Add-Route -Like 'GET */_apis/release/deployments?definitionId=1&definitionEnvironmentId=10&*' -Json (New-DeploymentFixture 11 'Release-11' '1.4.2')
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json @{ value = @() }
        $r = @(Get-TfsDeployed -Definition 'svc')
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/release/definitions?searchText=svc&$expand=environments&api-version=6.0'
        @($r | ForEach-Object { "$($_.Definition)/$($_.Environment)" }) | Should -Be @('Svc-A/Dev', 'Svc-A/Prod', 'Svc-B/QA')
        $r[0].PSObject.Properties.Name | Should -Be @('Definition', 'Environment', 'Release', 'ArtifactVersion', 'Completed')
        $r[0].Release | Should -Be 'Release-11'
        $r[0].ArtifactVersion | Should -Be '1.4.2'
        $r[0].Completed | Should -Be '2026-11-02 13:05'
        $dep = $global:TfsTestCalls | Where-Object { $_.Uri -like '*deployments?definitionId=1&definitionEnvironmentId=10*' }
        $dep.Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/release/deployments?definitionId=1&definitionEnvironmentId=10&deploymentStatus=succeeded&$top=1&api-version=6.0'
        (ConvertTo-Json -InputObject $r) | Should -Not -Match 'Dana'
        Assert-NoHost $r
    }

    It "reports 'none' for an environment without a succeeded deployment" {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json @{ value = @() }
        $r = @(Get-TfsDeployed -Definition 'Svc-B')
        $r.Count | Should -Be 1
        $r[0].Release | Should -Be 'none'
        $r[0].ArtifactVersion | Should -Be ''
        $r[0].Completed | Should -Be ''
    }

    It "isolates a failing environment as 'error: HTTP n' and keeps the others" {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        Add-Route -Like 'GET */_apis/release/deployments?definitionId=1&definitionEnvironmentId=10&*' -ErrorRecord (New-HttpError 403 'denied')
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json (New-DeploymentFixture 11 'Release-11' '1.0')
        $r = @(Get-TfsDeployed -Definition 'Svc-A')
        $r[0].Release | Should -Be 'error: HTTP 403'
        $r[1].Release | Should -Be 'Release-11'
    }

    It 'filters environments by wildcard and only queries those' {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json (New-DeploymentFixture 11 'Release-11' '1.0')
        $r = @(Get-TfsDeployed -Definition 'Svc-A' -Environment 'Pro*')
        @($r.Environment) | Should -Be @('Prod')
        @($global:TfsTestCalls | Where-Object { $_.Uri -like '*deployments*' }).Count | Should -Be 1
    }

    It 'falls back to reading the release once when the deployment carries no artifacts' {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json (New-DeploymentFixture 12 'Release-12' $null)
        Add-Route -Like 'GET */Proj/_apis/release/releases/12?*' -Json @{ id = 12; name = 'Release-12'; artifacts = @(@{ isPrimary = $true; definitionReference = @{ version = @{ name = '2.0.0' } } }) }
        $r = @(Get-TfsDeployed -Definition 'Svc-B')
        $r[0].ArtifactVersion | Should -Be '2.0.0'
        @($global:TfsTestCalls | Where-Object { $_.Uri -like '*/releases/12?*' }).Count | Should -Be 1
    }

    It 'leaves ArtifactVersion empty when neither source has artifacts' {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json (New-DeploymentFixture 12 'Release-12' $null)
        Add-Route -Like 'GET */Proj/_apis/release/releases/12?*' -Json @{ id = 12; name = 'Release-12' }
        @(Get-TfsDeployed -Definition 'Svc-B')[0].ArtifactVersion | Should -Be ''
    }

    It 'honours a wildcard pattern, removing wildcards from the server search text' {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json @{ value = @() }
        $r = @(Get-TfsDeployed -Definition 'Svc-?' -Environment 'QA')
        $global:TfsTestCalls[0].Uri | Should -BeLike '*definitions?searchText=Svc-&*'
        @($r.Definition) | Should -Be @('Svc-B')
    }

    It 'limits the definitions to -MaxDefinitions with a warning that says how many matched' {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json @{ value = @() }
        $r = @(Get-TfsDeployed -Definition 'svc' -MaxDefinitions 1 -WarningVariable w -WarningAction SilentlyContinue)
        "$w" | Should -Be 'Definitions matched: 2; showing 1 (raise -MaxDefinitions)'
        @($r.Definition | Select-Object -Unique) | Should -Be @('Svc-A')
        $r.Count | Should -Be 2
    }

    It 'defaults to 3 definitions and caps -MaxDefinitions at 10 with a warning' {
        $defs = @(1..12 | ForEach-Object { @{ id = $_; name = ('Rel{0:D2}' -f $_); environments = @(@{ id = $_ * 10; name = 'Prod' }) } })
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json @{ value = $defs }
        Add-Route -Like 'GET */_apis/release/deployments?*' -Json @{ value = @() }
        @(Get-TfsDeployed -Definition 'Rel' -WarningAction SilentlyContinue).Count | Should -Be 3
        $r = @(Get-TfsDeployed -Definition 'Rel' -MaxDefinitions 50 -WarningVariable w -WarningAction SilentlyContinue)
        $r.Count | Should -Be 10
        "$w" | Should -BeLike '*MaxDefinitions capped at 10*'
    }

    It 'warns and returns nothing when no definition matches' {
        Add-Route -Like 'GET */Proj/_apis/release/definitions?*' -Json (New-ReleaseDefinitions)
        $r = @(Get-TfsDeployed -Definition 'nomatch' -WarningVariable w -WarningAction SilentlyContinue)
        $r.Count | Should -Be 0
        "$w" | Should -Be 'No release definition matches nomatch'
    }
}

Describe 'Get-TfsDailySummary' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function Add-SummaryRoutes {
            param([switch]$NoItems, [switch]$NoBuilds, [switch]$NoApprovals)
            if ($NoItems) { Add-Route -Like 'POST *wiql*' -Json @{ workItems = @() } }
            else {
                Add-Route -Like 'POST *wiql*' -Json @{ workItems = @(@{ id = 1 }, @{ id = 2 }) }
                Add-Route -Like 'POST */_apis/wit/workitemsbatch[?]*' -Handler {
                    param($Uri, $Method, $Body)
                    $ids = @((ConvertFrom-Json $Body).ids)
                    New-WebResponse (ConvertTo-Json -InputObject @{ value = @($ids | ForEach-Object { New-WorkItem -Id $_ -Type 'Bug' -Title "Item $_" }) } -Depth 20 -Compress)
                }
            }
            if ($NoBuilds) { Add-Route -Like 'GET */_apis/build/builds[?]*' -Json @{ value = @() } }
            else {
                $build = @{
                    id = 77; buildNumber = '20261102.3'; sourceBranch = 'refs/heads/main'; finishTime = '2026-11-02T13:05:09Z'
                    definition = @{ name = 'CI svc'; url = "$($script:TBase)/d" }; requestedFor = @{ displayName = 'Dana Levi' }
                }
                Add-Route -Like 'GET */_apis/build/builds[?]*' -Json @{ value = @($build) }
            }
            if ($NoApprovals) { Add-Route -Like 'GET */_apis/release/approvals[?]*' -Json @{ value = @() } }
            else {
                $approval = @{
                    id = 5; approvalType = 'preDeploy'; approver = @{ displayName = 'Dana Levi'; uniqueName = 'dana@example.invalid' }
                    release = @{ id = 9; name = 'Release-9'; url = "$($script:TBase)/r" }; releaseEnvironment = @{ id = 2; name = 'Prod' }
                }
                Add-Route -Like 'GET */_apis/release/approvals[?]*' -Json @{ value = @($approval) }
            }
        }
    }

    It 'puts Counts first and returns the three sections with documented fields, without people or URLs' {
        Add-SummaryRoutes
        $r = Get-TfsDailySummary
        $r.PSObject.Properties.Name | Should -Be @('Counts', 'MyItems', 'FailedBuilds', 'PendingApprovals')
        $r.Counts.MyItems | Should -Be 2
        $r.Counts.FailedBuilds | Should -Be 1
        $r.Counts.PendingApprovals | Should -Be 1
        @($r.MyItems.Id) | Should -Be @(1, 2)
        $r.FailedBuilds[0].PSObject.Properties.Name | Should -Be @('Id', 'Definition', 'BuildNumber', 'Branch', 'Finished')
        $r.FailedBuilds[0].Definition | Should -Be 'CI svc'
        $r.FailedBuilds[0].Branch | Should -Be 'main'
        $r.FailedBuilds[0].Finished | Should -Be '2026-11-02 13:05'
        $r.PendingApprovals[0].PSObject.Properties.Name | Should -Be @('Id', 'Release', 'Environment', 'Type')
        $r.PendingApprovals[0].Release | Should -Be 'Release-9'
        $r.PendingApprovals[0].Environment | Should -Be 'Prod'
        $r.PendingApprovals[0].Type | Should -Be 'preDeploy'
        (ConvertTo-Json -InputObject $r -Depth 10) | Should -Not -Match 'Dana|example\.invalid'
        Assert-NoHost $r
    }

    It "shows 'none' with a zero count for empty sections" {
        Add-SummaryRoutes -NoItems -NoBuilds -NoApprovals
        $r = Get-TfsDailySummary
        $r.MyItems | Should -Be 'none'
        $r.FailedBuilds | Should -Be 'none'
        $r.PendingApprovals | Should -Be 'none'
        $r.Counts.MyItems | Should -Be 0
        $r.Counts.FailedBuilds | Should -Be 0
        $r.Counts.PendingApprovals | Should -Be 0
    }

    It 'isolates a 403 in one section and still reports the others' {
        Add-Route -Like 'GET */_apis/build/builds[?]*' -ErrorRecord (New-HttpError 403 'denied')
        Add-SummaryRoutes -NoItems -NoApprovals
        $r = Get-TfsDailySummary
        $r.FailedBuilds | Should -Be 'error: HTTP 403'
        $r.Counts.FailedBuilds | Should -Be 'error'
        $r.MyItems | Should -Be 'none'
        $r.PendingApprovals | Should -Be 'none'
        $r.Counts.MyItems | Should -Be 0
    }

    It 'retries pending approvals once with 6.0-preview.3 after a 400' {
        Add-Route -Like 'GET */_apis/release/approvals[?]*api-version=6.0-preview.3' -Json @{ value = @(@{ id = 5; approvalType = 'preDeploy'; release = @{ name = 'R' }; releaseEnvironment = @{ name = 'Prod' } }) }
        Add-Route -Like 'GET */_apis/release/approvals[?]*' -ErrorRecord (New-HttpError 400 'bad version')
        Add-SummaryRoutes -NoItems -NoBuilds
        $r = Get-TfsDailySummary
        $r.Counts.PendingApprovals | Should -Be 1
        $approvalCalls = @($global:TfsTestCalls | Where-Object { $_.Uri -like '*/release/approvals*' })
        $approvalCalls.Count | Should -Be 2
        $approvalCalls[0].Uri | Should -BeLike '*statusFilter=pending&$top=20&api-version=6.0'
        $approvalCalls[1].Uri | Should -BeLike '*statusFilter=pending&$top=20&api-version=6.0-preview.3'
    }

    It 'does not retry approvals after a 403' {
        Add-Route -Like 'GET */_apis/release/approvals[?]*' -ErrorRecord (New-HttpError 403 'denied')
        Add-SummaryRoutes -NoItems -NoBuilds
        (Get-TfsDailySummary).PendingApprovals | Should -Be 'error: HTTP 403'
        @($global:TfsTestCalls | Where-Object { $_.Uri -like '*/release/approvals*' }).Count | Should -Be 1
    }

    It 'asks for failed completed builds since now minus the look-back hours, as invariant UTC ISO' {
        Add-SummaryRoutes -NoItems -NoApprovals
        $null = Get-TfsDailySummary -Hours 48 -Top 5
        $uri = ($global:TfsTestCalls | Where-Object { $_.Uri -like '*/build/builds*' }).Uri
        $uri | Should -Match '^https://tfs\.test\.invalid/tfs/Coll/Proj/_apis/build/builds\?resultFilter=failed&statusFilter=completed&minTime=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ&queryOrder=finishTimeDescending&\$top=5&api-version=6\.0$'
        $min = [datetime]::ParseExact(([regex]::Match($uri, 'minTime=([^&]+)').Groups[1].Value), "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        ([datetime]::UtcNow - $min).TotalHours | Should -BeGreaterThan 47.9
        ([datetime]::UtcNow - $min).TotalHours | Should -BeLessThan 48.1
    }

    It 'defaults the look-back to 24 hours and passes -Top to every section' {
        Add-SummaryRoutes -NoBuilds -NoApprovals
        $null = Get-TfsDailySummary -Top 7
        $uri = ($global:TfsTestCalls | Where-Object { $_.Uri -like '*/build/builds*' }).Uri
        $min = [datetime]::ParseExact(([regex]::Match($uri, 'minTime=([^&]+)').Groups[1].Value), "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        ([datetime]::UtcNow - $min).TotalHours | Should -BeGreaterThan 23.9
        ([datetime]::UtcNow - $min).TotalHours | Should -BeLessThan 24.1
        @($global:TfsTestCalls | Where-Object { $_.Uri -like '*$top=7&*' }).Count | Should -Be 3
    }
}

Describe 'New-TfsItem' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        $script:ParentRel = @(@{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "$($script:TBase)/_apis/wit/workItems/55"; attributes = @{ name = 'Parent' } })
    }

    It 'by default only validates: one validateOnly POST with json-patch ops, and nothing is created' {
        Add-Route -Like 'POST *' -Json @{ id = 0; fields = @{} }
        $r = New-TfsItem -Type 'User Story' -Title $script:Hebrew -Fields @{ 'Microsoft.VSTS.Common.Priority' = 2; 'System.Description' = 'd' }
        $global:TfsTestCalls.Count | Should -Be 1
        $c = $global:TfsTestCalls[0]
        $c.Method | Should -Be 'POST'
        $c.Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/wit/workitems/$User%20Story?validateOnly=true&api-version=6.0'
        $c.ContentType | Should -Be 'application/json-patch+json; charset=utf-8'
        $c.Body | Should -Be ('[{"op":"add","path":"/fields/System.Title","value":"' + $script:Hebrew + '"},{"op":"add","path":"/fields/Microsoft.VSTS.Common.Priority","value":2},{"op":"add","path":"/fields/System.Description","value":"d"}]')
        $r.PSObject.Properties.Name | Should -Be @('Mode', 'Action', 'Target', 'ParentId', 'Changes', 'Validated', 'Note')
        $r.Mode | Should -Be 'DryRun'
        $r.Action | Should -Be 'Create'
        $r.Target | Should -Be 'new User Story'
        $r.Validated | Should -BeTrue
        $r.Note | Should -BeLike 'Nothing saved*-Commit*'
        @($r.Changes.Field) | Should -Be @('System.Title', 'Microsoft.VSTS.Common.Priority', 'System.Description')
        $r.Changes[0].PSObject.Properties.Name | Should -Be @('Field', 'Old', 'New')
        $r.Changes[0].Old | Should -BeNullOrEmpty
        $r.Changes[0].New | Should -Be $script:Hebrew
        Assert-NoHost $r
    }

    It 'adds the parent as a Hierarchy-Reverse relation built from the configured base' {
        Add-Route -Like 'POST *' -Json @{ id = 0 }
        $r = New-TfsItem -Type Task -Title 'T' -ParentId 55
        $ops = (ConvertFrom-Json $global:TfsTestCalls[0].Body)
        $ops[1].op | Should -Be 'add'
        $ops[1].path | Should -Be '/relations/-'
        $ops[1].value.rel | Should -Be 'System.LinkTypes.Hierarchy-Reverse'
        $ops[1].value.url | Should -Be 'https://tfs.test.invalid/tfs/Coll/_apis/wit/workItems/55'
        $r.ParentId | Should -Be 55
        Assert-NoHost $r
    }

    It 'with -Commit validates, creates, then re-reads and returns what is stored' {
        Add-Route -Like 'POST *validateOnly=true*' -Json @{ id = 0 }
        Add-Route -Like 'POST */workitems/$Task[?]api-version=6.0' -Json (New-WorkItem -Id 901)
        Add-Route -Like 'GET */workitems/901[?]*' -Json (New-WorkItem -Id 901 -Type 'Task' -Title 'T' -ExtraFields @{ 'Microsoft.VSTS.Common.Priority' = 2 })
        $r = New-TfsItem -Type Task -Title 'T' -Fields @{ 'Microsoft.VSTS.Common.Priority' = 2 } -Commit
        @($global:TfsTestCalls | ForEach-Object { $_.Method }) | Should -Be @('POST', 'POST', 'GET')
        $global:TfsTestCalls[0].Uri | Should -BeLike '*validateOnly=true*'
        $global:TfsTestCalls[1].Uri | Should -Not -BeLike '*validateOnly*'
        $global:TfsTestCalls[2].Uri | Should -BeLike '*workitems/901?fields=*Microsoft.VSTS.Common.Priority*'
        $r.PSObject.Properties.Name | Should -Be @('Mode', 'Id', 'Type', 'State', 'Title', 'Stored', 'ParentId')
        $r.Mode | Should -Be 'Committed'
        $r.Id | Should -Be 901
        $r.Title | Should -Be 'T'
        $r.Stored.'Microsoft.VSTS.Common.Priority' | Should -Be 2
        $r.Stored.'System.Title' | Should -Be 'T'
        $r.ParentId | Should -BeNullOrEmpty
        Assert-NoHost $r
    }

    It 'with -Commit and a parent re-reads with relations and reports the stored parent' {
        Add-Route -Like 'POST *validateOnly=true*' -Json @{ id = 0 }
        Add-Route -Like 'POST */workitems/$Task[?]api-version=6.0' -Json (New-WorkItem -Id 902)
        Add-Route -Like 'GET */workitems/902[?]*' -Json (New-WorkItem -Id 902 -Relations $script:ParentRel)
        $r = New-TfsItem -Type Task -Title 'A title' -ParentId 55 -Commit
        $global:TfsTestCalls[2].Uri | Should -BeLike '*workitems/902?$expand=relations&*'
        $r.ParentId | Should -Be 55
    }

    It '-Commit -WhatIf validates but never makes the creating POST' {
        Add-Route -Like 'POST *validateOnly=true*' -Json @{ id = 0 }
        $r = New-TfsItem -Type Task -Title 'T' -Commit -WhatIf
        @($global:TfsTestCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -notlike '*validateOnly*' }).Count | Should -Be 0
        $global:TfsTestCalls.Count | Should -Be 1
        $r.Mode | Should -Be 'DryRun'
    }

    It 'throws the server reason when validation fails and never sends the creating POST' {
        Add-Route -Like 'POST *' -ErrorRecord (New-HttpError 400 'TF401320: Rule Error for field Title')
        $err = { New-TfsItem -Type Task -Title 'T' -Commit } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike 'HTTP 400 POST *validateOnly=true* :: TF401320*'
        $global:TfsTestCalls.Count | Should -Be 1
    }

    It 'rejects a field list that repeats the title or has a null value, before any web call' {
        { New-TfsItem -Type Task -Title 'T' -Fields @{ 'System.Title' = 'x' } } | Should -Throw '*System.Title*'
        { New-TfsItem -Type Task -Title 'T' -Fields @{ 'Custom.X' = $null } } | Should -Throw '*Custom.X*'
        $global:TfsTestCalls.Count | Should -Be 0
    }

    It 'requires a non-empty title' {
        { New-TfsItem -Type Task -Title '' } | Should -Throw
    }
}

Describe 'Set-TfsItem' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function Add-CurrentItemRoute {
            Add-Route -Like 'GET */_apis/wit/workitems/5[?]*' -Json (New-WorkItem -Id 5 -Title 'Old title' -ExtraFields @{ 'Microsoft.VSTS.Common.Priority' = 2; 'Custom.Note' = 'n'; 'System.Tags' = 'a; b' })
        }
    }

    It 'by default reads the item and only validates: GET then one validateOnly PATCH' {
        Add-CurrentItemRoute
        Add-Route -Like 'PATCH *' -Json (New-WorkItem -Id 5)
        $r = Set-TfsItem -Id 5 -Fields @{ 'System.Title' = 'New title'; 'Microsoft.VSTS.Common.Priority' = 3 }
        @($global:TfsTestCalls | ForEach-Object { $_.Method }) | Should -Be @('GET', 'PATCH')
        $global:TfsTestCalls[0].Uri | Should -BeLike '*workitems/5?fields=*System.Rev*Microsoft.VSTS.Common.Priority*'
        $patch = $global:TfsTestCalls[1]
        $patch.Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/_apis/wit/workitems/5?validateOnly=true&api-version=6.0'
        $patch.ContentType | Should -Be 'application/json-patch+json; charset=utf-8'
        $patch.Body | Should -Be '[{"op":"add","path":"/fields/Microsoft.VSTS.Common.Priority","value":3},{"op":"add","path":"/fields/System.Title","value":"New title"}]'
        $r.PSObject.Properties.Name | Should -Be @('Mode', 'Action', 'Target', 'Rev', 'Changes', 'Validated', 'Note')
        $r.Mode | Should -Be 'DryRun'
        $r.Action | Should -Be 'Update'
        $r.Target | Should -Be 'workitem 5: Old title'
        $r.Rev | Should -Be 3
        $r.Validated | Should -BeTrue
        $title = $r.Changes | Where-Object { $_.Field -eq 'System.Title' }
        $title.Old | Should -Be 'Old title'
        $title.New | Should -Be 'New title'
        $prio = $r.Changes | Where-Object { $_.Field -eq 'Microsoft.VSTS.Common.Priority' }
        $prio.Old | Should -Be 2
        $prio.New | Should -Be 3
        Assert-NoHost $r
    }

    It 'turns a $null value into a remove operation' {
        Add-CurrentItemRoute
        Add-Route -Like 'PATCH *' -Json (New-WorkItem -Id 5)
        $r = Set-TfsItem -Id 5 -Fields @{ 'Custom.Note' = $null }
        $global:TfsTestCalls[1].Body | Should -Be '[{"op":"remove","path":"/fields/Custom.Note"}]'
        $r.Changes[0].Old | Should -Be 'n'
        $r.Changes[0].New | Should -BeNullOrEmpty
    }

    It 'merges -AddTag into the current tags without duplicates (case-insensitive) and joins with "; "' {
        Add-CurrentItemRoute
        Add-Route -Like 'PATCH *' -Json (New-WorkItem -Id 5)
        $r = Set-TfsItem -Id 5 -AddTag 'B', 'c'
        $global:TfsTestCalls[1].Body | Should -Be '[{"op":"add","path":"/fields/System.Tags","value":"a; b; c"}]'
        $r.Changes[0].Old | Should -Be 'a; b'
        $r.Changes[0].New | Should -Be 'a; b; c'
    }

    It 'says in the note that System.Tags in -Fields replaces the whole string' {
        Add-CurrentItemRoute
        Add-Route -Like 'PATCH *' -Json (New-WorkItem -Id 5)
        $r = Set-TfsItem -Id 5 -Fields @{ 'System.Tags' = 'only' }
        $r.Note | Should -BeLike '*System.Tags*replaces*'
        $global:TfsTestCalls[1].Body | Should -Be '[{"op":"add","path":"/fields/System.Tags","value":"only"}]'
    }

    It 'refuses -AddTag together with System.Tags in -Fields, and a call with nothing to change' {
        { Set-TfsItem -Id 5 -AddTag x -Fields @{ 'System.Tags' = 'y' } } | Should -Throw '*System.Tags*'
        { Set-TfsItem -Id 5 } | Should -Throw '*Nothing to change*'
        $global:TfsTestCalls.Count | Should -Be 0
    }

    It 'puts a test /rev operation first with -ExpectedRev' {
        Add-CurrentItemRoute
        Add-Route -Like 'PATCH *' -Json (New-WorkItem -Id 5)
        $null = Set-TfsItem -Id 5 -Fields @{ 'System.Title' = 'x' } -ExpectedRev 3
        $global:TfsTestCalls[1].Body | Should -Be '[{"op":"test","path":"/rev","value":3},{"op":"add","path":"/fields/System.Title","value":"x"}]'
    }

    It 'with -Commit validates, patches for real, re-reads, and reports stored values with a per-field match' {
        $global:TfsTestGets = 0
        Add-Route -Like 'GET */_apis/wit/workitems/5[?]*' -Handler {
            param($Uri, $Method, $Body)
            $global:TfsTestGets++
            if ($global:TfsTestGets -eq 1) { return New-WebResponse (ConvertTo-Json -Depth 20 -Compress -InputObject (New-WorkItem -Id 5 -Title 'Old title' -ExtraFields @{ 'Microsoft.VSTS.Common.Priority' = 2 })) }
            # After the write the server stored the title as asked but normalised the priority differently.
            return New-WebResponse (ConvertTo-Json -Depth 20 -Compress -InputObject (New-WorkItem -Id 5 -Title 'New title' -ExtraFields @{ 'Microsoft.VSTS.Common.Priority' = 9 }))
        }
        Add-Route -Like 'PATCH *' -Json (New-WorkItem -Id 5)
        $r = Set-TfsItem -Id 5 -Fields @{ 'System.Title' = 'New title'; 'Microsoft.VSTS.Common.Priority' = 3 } -Commit
        @($global:TfsTestCalls | ForEach-Object { $_.Method }) | Should -Be @('GET', 'PATCH', 'PATCH', 'GET')
        $global:TfsTestCalls[1].Uri | Should -BeLike '*validateOnly=true*'
        $global:TfsTestCalls[2].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/_apis/wit/workitems/5?api-version=6.0'
        $r.Mode | Should -Be 'Committed'
        $title = $r.Changes | Where-Object { $_.Field -eq 'System.Title' }
        $title.PSObject.Properties.Name | Should -Be @('Field', 'Old', 'New', 'Stored', 'Match')
        $title.Stored | Should -Be 'New title'
        $title.Match | Should -BeTrue
        $prio = $r.Changes | Where-Object { $_.Field -eq 'Microsoft.VSTS.Common.Priority' }
        $prio.Stored | Should -Be 9
        $prio.Match | Should -BeFalse
    }

    It '-Commit -WhatIf makes no real PATCH' {
        Add-CurrentItemRoute
        Add-Route -Like 'PATCH *validateOnly=true*' -Json (New-WorkItem -Id 5)
        $r = Set-TfsItem -Id 5 -Fields @{ 'System.Title' = 'x' } -Commit -WhatIf
        @($global:TfsTestCalls | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri -notlike '*validateOnly*' }).Count | Should -Be 0
        $r.Mode | Should -Be 'DryRun'
    }

    It 'sends no PATCH and reports NoChange when every tag is already present' {
        Add-CurrentItemRoute
        $r = Set-TfsItem -Id 5 -AddTag 'a', 'B' -Commit
        $r.Mode | Should -Be 'NoChange'
        @($global:TfsTestCalls | Where-Object { $_.Method -eq 'PATCH' }).Count | Should -Be 0
    }

    It 'throws the server reason on a failed validation and stops before the real PATCH' {
        Add-CurrentItemRoute
        Add-Route -Like 'PATCH *' -ErrorRecord (New-HttpError 409 'TF401028: The updated rev does not match')
        $err = { Set-TfsItem -Id 5 -Fields @{ 'System.Title' = 'x' } -ExpectedRev 1 -Commit } | Should -Throw -PassThru
        $err.Exception.Data['StatusCode'] | Should -Be 409
        @($global:TfsTestCalls | Where-Object { $_.Method -eq 'PATCH' }).Count | Should -Be 1
    }
}

Describe 'Test-TfsSetup' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function Add-SetupRoutes {
            Add-Route -Like 'GET */_apis/projects[?]*' -Json @{ count = 1; value = @(@{ id = 'p1'; name = 'Proj'; url = "$($script:TBase)/_apis/projects/p1" }) }
            Add-Route -Like 'GET */_apis/connectionData[?]*' -Json @{ authenticatedUser = @{ id = 'user-guid-1234'; providerDisplayName = 'Dana Levi' } }
            Add-Route -Like 'GET */_apis/projects/Proj[?]*' -Json @{ id = 'p1'; name = 'Proj' }
            Add-Route -Like 'POST */Proj/_apis/wit/wiql[?]*' -Json @{ workItems = @() }
            Add-Route -Like 'GET */Proj/_apis/git/repositories[?]*' -Json @{ count = 0; value = @() }
            Add-Route -Like 'GET */Proj/_apis/build/builds[?]*' -Json @{ count = 0; value = @() }
            Add-Route -Like 'GET */Proj/_apis/release/deployments[?]*' -Json @{ count = 0; value = @() }
        }
    }

    It 'passes every area in order when every call succeeds, with an empty code' {
        Add-SetupRoutes
        $r = @(Test-TfsSetup)
        @($r.Area) | Should -Be @('Config', 'Connectivity', 'Auth', 'Project', 'WIQL', 'Repos', 'Builds', 'Deployments')
        @($r.Result | Select-Object -Unique) | Should -Be @('PASS')
        $r[0].PSObject.Properties.Name | Should -Be @('Area', 'Result', 'Code')
        @($r.Code | Where-Object { $_ -ne '' }).Count | Should -Be 0
    }

    It 'queries the documented endpoints, with at most one POST and no other write' {
        Add-SetupRoutes
        $null = Test-TfsSetup
        $uris = @($global:TfsTestCalls | ForEach-Object { $_.Uri -replace '^https://tfs\.test\.invalid/tfs/Coll/', '' })
        $uris | Should -Be @(
            '_apis/projects?$top=1&api-version=6.0'
            '_apis/connectionData?api-version=6.0-preview.1'
            '_apis/projects/Proj?api-version=6.0'
            'Proj/_apis/wit/wiql?$top=1&api-version=6.0'
            'Proj/_apis/git/repositories?api-version=6.0'
            'Proj/_apis/build/builds?$top=1&api-version=6.0'
            'Proj/_apis/release/deployments?$top=1&api-version=6.0'
        )
        @($global:TfsTestCalls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 1
        $global:TfsTestCalls[3].Method | Should -Be 'POST'
    }

    It 'reports a 401 on the auth call as Auth FAIL 401 and keeps checking the other areas' {
        Add-Route -Like 'GET */_apis/connectionData[?]*' -ErrorRecord (New-HttpError 401 'unauthorized')
        Add-SetupRoutes
        $r = @(Test-TfsSetup)
        $auth = $r | Where-Object { $_.Area -eq 'Auth' }
        $auth.Result | Should -Be 'FAIL'
        $auth.Code | Should -Be 401
        @($r | Where-Object { $_.Result -eq 'PASS' }).Count | Should -Be 7
    }

    It 'fails Auth with PARSE when the answer has no authenticated user id (for example a login page)' {
        Add-Route -Like 'GET */_apis/connectionData[?]*' -Text '<html>sign in</html>'
        Add-SetupRoutes
        $auth = @(Test-TfsSetup) | Where-Object { $_.Area -eq 'Auth' }
        $auth.Result | Should -Be 'FAIL'
        $auth.Code | Should -Be 'PARSE'
    }

    It 'fails Connectivity with NETWORK on a network error and skips every other area after one call' {
        Add-Route -Like 'GET *' -ErrorRecord (New-NetworkError)
        $r = @(Test-TfsSetup)
        $r[0].Result | Should -Be 'PASS'
        $r[1].Area | Should -Be 'Connectivity'
        $r[1].Result | Should -Be 'FAIL'
        $r[1].Code | Should -Be 'NETWORK'
        @($r[2..7].Result | Select-Object -Unique) | Should -Be @('SKIP')
        $global:TfsTestCalls.Count | Should -Be 1
    }

    It 'fails one area with its HTTP code without stopping the others' {
        Add-Route -Like 'GET */Proj/_apis/build/builds[?]*' -ErrorRecord (New-HttpError 403 'denied')
        Add-SetupRoutes
        $r = @(Test-TfsSetup)
        $b = $r | Where-Object { $_.Area -eq 'Builds' }
        $b.Result | Should -Be 'FAIL'
        $b.Code | Should -Be 403
        @($r | Where-Object { $_.Result -eq 'PASS' }).Count | Should -Be 7
    }

    It 'never prints server, project, user or message text' {
        Add-Route -Like 'GET */Proj/_apis/build/builds[?]*' -ErrorRecord (New-HttpError 403 'denied for Dana at https://tfs.test.invalid/tfs/Coll')
        Add-SetupRoutes
        $text = (Test-TfsSetup | Out-String)
        $text | Should -Not -Match 'tfs\.test\.invalid|Proj|Dana|user-guid|denied'
    }

    It 'reports Config FAIL CONFIG, skips everything else and makes no web call on the placeholder config' {
        $null = Import-TfsUnderTest -UseShippedConfig
        Register-WebMock
        $r = @(Test-TfsSetup)
        $r[0].Area | Should -Be 'Config'
        $r[0].Result | Should -Be 'FAIL'
        $r[0].Code | Should -Be 'CONFIG'
        @($r[1..7].Result | Select-Object -Unique) | Should -Be @('SKIP')
        $r.Count | Should -Be 8
        $global:TfsTestCalls.Count | Should -Be 0
    }
}

Describe 'Invoke-Tfs hardening' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    It 'throws PARSE (status 200) for an HTML body instead of returning it as data' {
        Add-Route -Like 'GET *' -Text '<html><body>Sign in to tfs.test.invalid</body></html>'
        $err = { Invoke-Tfs -Path '_apis/x' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Be 'HTTP 200 GET _apis/x :: PARSE'
        $err.Exception.Data['StatusCode'] | Should -Be 200
        $err.Exception.Data['Kind'] | Should -Be 'PARSE'
    }

    It 'throws PARSE for a body that starts like JSON but is not parseable' {
        Add-Route -Like 'GET *' -Text '{"value": [1, 2'
        $err = { Invoke-Tfs -Path '_apis/x' } | Should -Throw -PassThru
        $err.Exception.Data['Kind'] | Should -Be 'PARSE'
    }

    It 'still returns non-JSON text with -Raw' {
        Add-Route -Like 'GET *' -Text 'plain log text'
        Invoke-Tfs -Path '_apis/x' -Raw | Should -Be 'plain log text'
    }

    It 'never follows redirects: MaximumRedirection is 0' {
        Add-Route -Like 'GET *' -Json @{ ok = 1 }
        $null = Invoke-Tfs -Path '_apis/x'
        $global:TfsTestCalls[0].Bound | Should -Contain 'MaximumRedirection'
        $global:TfsTestCalls[0].MaxRedirect | Should -Be 0
    }

    It 'reports a 302 raised as an HTTP error as REDIRECT without the target' {
        Add-Route -Like 'GET *' -ErrorRecord (New-HttpError 302 'Moved to https://tfs.test.invalid/login')
        $err = { Invoke-Tfs -Path '_apis/x' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Be 'HTTP 302 GET _apis/x :: REDIRECT not followed'
        $err.Exception.Data['Kind'] | Should -Be 'REDIRECT'
        $err.Exception.Data['StatusCode'] | Should -Be 302
    }

    It 'reports a 302 returned as a normal response as REDIRECT' {
        Add-Route -Like 'GET *' -Handler { param($Uri, $Method, $Body) [pscustomobject]@{ StatusCode = 302; Content = '' } }
        $err = { Invoke-Tfs -Path '_apis/x' } | Should -Throw -PassThru
        $err.Exception.Data['Kind'] | Should -Be 'REDIRECT'
    }

    It 'reports the Windows PowerShell 5.1 style redirect exception (no response object) as REDIRECT, not NETWORK' {
        $ex = [System.InvalidOperationException]::new('The maximum redirection count has been exceeded. To increase the number of redirections allowed, supply a higher value to the -MaximumRedirection parameter.')
        Add-Route -Like 'GET *' -ErrorRecord (New-PlainError -Exception $ex)
        $err = { Invoke-Tfs -Path '_apis/x' } | Should -Throw -PassThru
        $err.Exception.Data['Kind'] | Should -Be 'REDIRECT'
    }

    It 'refuses a body above the size cap with TOOBIG' {
        Add-Route -Like 'GET *' -Text ('a' * 5000001)
        $err = { Invoke-Tfs -Path '_apis/x' -Raw } | Should -Throw -PassThru
        $err.Exception.Data['Kind'] | Should -Be 'TOOBIG'
        $err.Exception.Message | Should -BeLike 'HTTP 200 GET _apis/x :: TOOBIG*'
    }

    It 'maps every failure kind to one label' -ForEach @(
        @{ Kind = 'HTTP 403'; Make = { New-HttpError 403 'x' } }
        @{ Kind = 'NETWORK'; Make = { New-NetworkError } }
        @{ Kind = 'NETWORK'; Make = { New-PlainError } }
    ) {
        Add-Route -Like 'GET *' -ErrorRecord (& $Make)
        $label = $null
        try { $null = Invoke-Tfs -Path '_apis/x' } catch { $label = InModuleScope Tfs -Parameters @{ Rec = $_ } { (Get-TfsErrorInfo -ErrorRecord $Rec).Label } }
        $label | Should -Be $Kind
    }
}

Describe 'Error info' {
    BeforeAll { $null = Import-TfsUnderTest }

    It 'labels an exception that did not come from Invoke-Tfs as ERROR, never HTTP 0' {
        InModuleScope Tfs {
            try { throw 'logic bug' } catch { $info = Get-TfsErrorInfo -ErrorRecord $_ }
            $info.Kind | Should -Be 'ERROR'
            $info.Label | Should -Be 'ERROR'
        }
    }

    It 'Get-TfsAreaResult gives FAIL with code ERROR for a probe that throws a plain exception' {
        InModuleScope Tfs {
            $r = Get-TfsAreaResult -Area 'X' -Probe { throw 'boom' }
            $r.Result | Should -Be 'FAIL'
            $r.Code | Should -Be 'ERROR'
        }
    }

    It 'Get-TfsAreaResult gives FAIL with code PARSE for a probe that returns false' {
        InModuleScope Tfs {
            $r = Get-TfsAreaResult -Area 'X' -Probe { $false }
            $r.Code | Should -Be 'PARSE'
        }
    }
}

Describe 'Top caps' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    It 'Get-TfsPR -Top 999 asks for $top=200 and warns' {
        Add-Route -Like 'GET *' -Json @{ value = @() }
        $null = Get-TfsPR -Top 999 -WarningVariable w -WarningAction SilentlyContinue
        $global:TfsTestCalls[0].Uri | Should -BeLike '*&$top=200&api-version=6.0'
        "$w" | Should -Be 'Top capped at 200'
    }

    It 'Get-TfsCommits -Top 999 asks for $top=200 and warns' {
        Add-Route -Like 'GET *' -Json @{ value = @() }
        $null = Get-TfsCommits -Repo svc -Top 999 -WarningVariable w -WarningAction SilentlyContinue
        $global:TfsTestCalls[0].Uri | Should -BeLike '*searchCriteria.$top=200&api-version=6.0'
        "$w" | Should -Be 'Top capped at 200'
    }

    It 'Find-TfsRepo -Top 999 returns at most 200 of 250 repositories and warns' {
        Add-Route -Like 'GET *' -Json @{ value = @(1..250 | ForEach-Object { @{ id = "i$_"; name = ('repo{0:D3}' -f $_) } }) }
        $r = @(Find-TfsRepo -Top 999 -WarningVariable w -WarningAction SilentlyContinue)
        $r.Count | Should -Be 200
        "$w" | Should -Be 'Top capped at 200'
    }

    It 'Get-TfsTree -Top 999 asks for $top=200 and warns' {
        Add-Route -Like 'POST *' -Json @{ workItemRelations = @() }
        $null = Get-TfsTree -Id 5 -Top 999 -WarningVariable w -WarningAction SilentlyContinue
        $global:TfsTestCalls[0].Uri | Should -BeLike '*wiql?$top=200&*'
        "$w" | Should -Be 'Top capped at 200'
    }

    It 'Get-TfsDailySummary -Top 999 caps all three sections at 200 and warns once' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @() }
        Add-Route -Like 'GET */_apis/build/builds[?]*' -Json @{ value = @() }
        Add-Route -Like 'GET */_apis/release/approvals[?]*' -Json @{ value = @() }
        $null = Get-TfsDailySummary -Top 999 -WarningVariable w -WarningAction SilentlyContinue
        @($global:TfsTestCalls | Where-Object { $_.Uri -like '*$top=200&*' }).Count | Should -Be 3
        @($w).Count | Should -Be 1
    }
}

Describe 'Get-TfsBuildFailure limits' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function Add-LimitBuildRoutes {
            param($Records)
            Add-Route -Like 'GET */_apis/build/builds/77[?]*' -Json @{ id = 77; buildNumber = '1'; status = 'completed'; result = 'failed'; sourceBranch = 'refs/heads/main'; sourceVersion = 'abcdef0123456789'; definition = @{ name = 'D' } }
            Add-Route -Like 'GET */_apis/build/builds/77/timeline[?]*' -Json @{ records = $Records }
        }
    }

    It 'returns at most 10 failed steps when 12 failed' {
        Add-LimitBuildRoutes -Records @(1..12 | ForEach-Object { @{ type = 'Task'; name = "Step$_"; result = 'failed'; log = $null; issues = @() } })
        $r = Get-TfsBuildFailure -Id 77
        @($r.FailedSteps).Count | Should -Be 10
        $r.FailedSteps[0].Step | Should -Be 'Step1'
    }

    It 'masks an error issue before cutting it to 300 characters (a secret that straddles the cut must not leak)' {
        $long = ('y ' * 140) + 'tok ' + ('a1b2c3d4e5' * 5) + 'xy' + ' password=hunter2 ' + ('z' * 100)
        Add-LimitBuildRoutes -Records @(@{ type = 'Task'; name = 'T'; result = 'failed'; log = $null; issues = @(@{ type = 'error'; message = $long }) })
        $msg = (Get-TfsBuildFailure -Id 77).FailedSteps[0].Errors[0]
        $msg.Length | Should -BeLessOrEqual 300
        $msg | Should -Not -Match 'a1b2c3d4e5|hunter2'
    }
}

Describe 'Write failures' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    It 'New-TfsItem dry run throws when validation fails (no -Commit needed)' {
        Add-Route -Like 'POST *' -ErrorRecord (New-HttpError 400 'TF401320: Rule Error')
        $err = { New-TfsItem -Type Task -Title 'T' } | Should -Throw -PassThru
        $err.Exception.Data['StatusCode'] | Should -Be 400
        $global:TfsTestCalls.Count | Should -Be 1
    }

    It 'New-TfsItem -Commit propagates a failing real write after a passing validation and returns no Committed object' {
        $global:TfsTestWrites = 0
        Add-Route -Like 'POST *' -Handler {
            param($Uri, $Method, $Body)
            $global:TfsTestWrites++
            if ($global:TfsTestWrites -eq 1) { return New-WebResponse '{"id":0}' }
            return (New-HttpError 500 'server broke')
        }
        $r = $null
        $err = { $r = New-TfsItem -Type Task -Title 'T' -Commit } | Should -Throw -PassThru
        $err.Exception.Data['StatusCode'] | Should -Be 500
        $r | Should -BeNullOrEmpty
        @($global:TfsTestCalls | Where-Object { $_.Method -eq 'GET' }).Count | Should -Be 0
    }

    It 'Set-TfsItem -Commit propagates a failing real PATCH after a passing validation and returns no Committed object' {
        $global:TfsTestWrites = 0
        Add-Route -Like 'GET */_apis/wit/workitems/5[?]*' -Json (New-WorkItem -Id 5)
        Add-Route -Like 'PATCH *' -Handler {
            param($Uri, $Method, $Body)
            $global:TfsTestWrites++
            if ($global:TfsTestWrites -eq 1) { return New-WebResponse '{"id":5}' }
            return (New-HttpError 500 'server broke')
        }
        $r = $null
        $err = { $r = Set-TfsItem -Id 5 -Fields @{ 'System.Title' = 'x' } -Commit } | Should -Throw -PassThru
        $err.Exception.Data['StatusCode'] | Should -Be 500
        $r | Should -BeNullOrEmpty
        @($global:TfsTestCalls | Where-Object { $_.Method -eq 'GET' }).Count | Should -Be 1
    }

    It 'New-TfsItem -Commit -WhatIf says WhatIf, not "re-run with -Commit"' {
        Add-Route -Like 'POST *' -Json @{ id = 0 }
        $r = New-TfsItem -Type Task -Title 'T' -Commit -WhatIf
        $r.Note | Should -BeLike '*WhatIf*'
        $r.Note | Should -Not -BeLike '*Re-run with -Commit*'
    }

    It 'Set-TfsItem -Commit -WhatIf says WhatIf, not "re-run with -Commit"' {
        Add-Route -Like 'GET *' -Json (New-WorkItem -Id 5)
        Add-Route -Like 'PATCH *' -Json (New-WorkItem -Id 5)
        $r = Set-TfsItem -Id 5 -Fields @{ 'System.Title' = 'x' } -Commit -WhatIf
        $r.Note | Should -BeLike '*WhatIf*'
        $r.Note | Should -Not -BeLike '*Re-run with -Commit*'
    }
}

Describe 'Path segment safety' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    It '<Name> rejects dot segments before any web call' -ForEach @(
        @{ Name = 'Get-TfsPR -Repo ..'; Call = { Get-TfsPR -Repo '..' } }
        @{ Name = 'Get-TfsPR -Repo a/../b'; Call = { Get-TfsPR -Repo 'a/../b' } }
        @{ Name = 'Get-TfsPR -TargetBranch ..'; Call = { Get-TfsPR -TargetBranch '..' } }
        @{ Name = 'Get-TfsCommits -Repo .'; Call = { Get-TfsCommits -Repo '.' } }
        @{ Name = 'Get-TfsCommits -Branch ..'; Call = { Get-TfsCommits -Repo svc -Branch '..' } }
        @{ Name = 'Get-TfsCommits -Branch x\..\y'; Call = { Get-TfsCommits -Repo svc -Branch 'x\..\y' } }
    ) {
        Add-Route -Like '* *' -Json @{ value = @() }
        $Call | Should -Throw '*path segment*'
        $global:TfsTestCalls.Count | Should -Be 0
    }

    It 'still accepts dots inside a normal name' {
        Add-Route -Like 'GET *' -Json @{ value = @() }
        { Get-TfsCommits -Repo 'my.repo' -Branch 'release/1.2.3' } | Should -Not -Throw
    }

    It 'Get-TfsDeployed refuses server-supplied ids that are not numbers instead of building a path from them' {
        $defs = @{ value = @(@{ id = '../../x'; name = 'Svc'; environments = @(@{ id = 1; name = 'Prod' }) }) }
        Add-Route -Like 'GET */release/definitions[?]*' -Json $defs
        { Get-TfsDeployed -Definition 'Svc' } | Should -Throw
        @($global:TfsTestCalls | Where-Object { $_.Uri -like '*deployments*' }).Count | Should -Be 0
    }
}

Describe 'Error labels in sections and setup' {
    BeforeAll { Initialize-TfsTest }
    BeforeEach { Reset-TfsRoutes }

    BeforeAll {
        function New-ReleaseDefs {
            @{ value = @(@{ id = 1; name = 'Svc'; environments = @(@{ id = 10; name = 'Dev' }, @{ id = 20; name = 'Prod' }) }) }
        }
    }

    It 'Get-TfsDailySummary shows error: PARSE and Counts error for an HTML answer, not none or 0' {
        Add-Route -Like 'POST *wiql*' -Json @{ workItems = @() }
        Add-Route -Like 'GET */_apis/build/builds[?]*' -Json @{ value = @() }
        Add-Route -Like 'GET */_apis/release/approvals[?]*' -Text '<html>login</html>'
        $r = Get-TfsDailySummary
        $r.PendingApprovals | Should -Be 'error: PARSE'
        $r.Counts.PendingApprovals | Should -Be 'error'
    }

    It 'Get-TfsDailySummary labels a network failure NETWORK and a non-HTTP failure ERROR (never HTTP 0)' {
        Add-Route -Like 'POST *wiql*' -ErrorRecord (New-NetworkError)
        Add-Route -Like 'GET */_apis/build/builds[?]*' -Json @{ value = @(@{ id = 'not-a-number'; buildNumber = '1' }) }
        Add-Route -Like 'GET */_apis/release/approvals[?]*' -Json @{ value = @() }
        $r = Get-TfsDailySummary
        $r.MyItems | Should -Be 'error: NETWORK'
        $r.FailedBuilds | Should -Be 'error: ERROR'
        $r.PendingApprovals | Should -Be 'none'
    }

    It 'Get-TfsDeployed shows error: PARSE for an HTML deployments answer' {
        Add-Route -Like 'GET */release/definitions[?]*' -Json (New-ReleaseDefs)
        Add-Route -Like 'GET */release/deployments[?]*' -Text '<html>login</html>'
        @(Get-TfsDeployed -Definition 'Svc' -Environment 'Dev')[0].Release | Should -Be 'error: PARSE'
    }

    It 'Get-TfsDeployed reports a failing release fallback in ArtifactVersion and does not retry it for the same release' {
        $dep = @{ value = @(@{ id = 900; release = @{ id = 12; name = 'Release-12' }; completedOn = '2026-11-02T13:05:09Z' }) }
        Add-Route -Like 'GET */release/definitions[?]*' -Json (New-ReleaseDefs)
        Add-Route -Like 'GET */release/deployments[?]*' -Json $dep
        Add-Route -Like 'GET */release/releases/12[?]*' -ErrorRecord (New-HttpError 403 'denied')
        $r = @(Get-TfsDeployed -Definition 'Svc')
        $r.Count | Should -Be 2
        @($r.ArtifactVersion) | Should -Be @('error: HTTP 403', 'error: HTTP 403')
        @($r.Release) | Should -Be @('Release-12', 'Release-12')
        @($global:TfsTestCalls | Where-Object { $_.Uri -like '*/releases/12?*' }).Count | Should -Be 1
    }

    It 'Get-TfsDeployed sends only the longest literal part of a wildcard as searchText and still matches client-side' {
        $defs = @{ value = @(@{ id = 1; name = 'Bill-X-ing'; environments = @(@{ id = 10; name = 'Dev' }) }, @{ id = 2; name = 'Other'; environments = @(@{ id = 11; name = 'Dev' }) }) }
        Add-Route -Like 'GET */release/definitions[?]*' -Json $defs
        Add-Route -Like 'GET */release/deployments[?]*' -Json @{ value = @() }
        $r = @(Get-TfsDeployed -Definition 'Bi*ll-X-ing')
        $global:TfsTestCalls[0].Uri | Should -BeLike '*definitions?searchText=ll-X-ing&*'
        @($r.Definition) | Should -Be @('Bill-X-ing')
    }

    It 'Get-TfsDeployed omits searchText when the pattern is only wildcards' {
        Add-Route -Like 'GET */release/definitions[?]*' -Json @{ value = @() }
        $null = Get-TfsDeployed -Definition '*' -WarningAction SilentlyContinue
        $global:TfsTestCalls[0].Uri | Should -Be 'https://tfs.test.invalid/tfs/Coll/Proj/_apis/release/definitions?$expand=environments&api-version=6.0'
    }

    It 'Test-TfsSetup reports PARSE for an HTML answer on any area and REDIRECT for a redirect' {
        Add-Route -Like 'GET */_apis/projects[?]*' -Json @{ value = @() }
        Add-Route -Like 'GET */_apis/connectionData[?]*' -ErrorRecord (New-HttpError 302 '')
        Add-Route -Like 'GET */_apis/projects/Proj[?]*' -Json @{ id = 'p' }
        Add-Route -Like 'POST */wiql[?]*' -Json @{ workItems = @() }
        Add-Route -Like 'GET */Proj/_apis/git/repositories[?]*' -Text '<html>login</html>'
        Add-Route -Like 'GET */Proj/_apis/build/builds[?]*' -Json @{ value = @() }
        Add-Route -Like 'GET */Proj/_apis/release/deployments[?]*' -Json @{ value = @() }
        $r = @(Test-TfsSetup)
        ($r | Where-Object { $_.Area -eq 'Repos' }).Code | Should -Be 'PARSE'
        ($r | Where-Object { $_.Area -eq 'Auth' }).Code | Should -Be 'REDIRECT'
    }
}
