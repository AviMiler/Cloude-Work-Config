# PSScriptAnalyzer settings for user/skills/sql-access/scripts: default rules plus Windows PowerShell 5.1 compatibility rules (test-only, never shipped).
@{
    IncludeDefaultRules = $true
    # Without IncludeRules the compatibility rules silently do not run.
    IncludeRules        = @('*')
    # Plural nouns (Get-SqlTable, Get-SqlColumn) are the spec'd function names.
    ExcludeRules        = @('PSUseSingularNouns')
    Rules               = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
            )
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @(
                'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
            )
        }
        PSUseCompatibleCmdlets  = @{
            compatibility = @('desktop-5.1.14393.206-windows')
        }
    }
}
