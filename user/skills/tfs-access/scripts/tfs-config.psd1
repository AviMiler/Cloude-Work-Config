# TFS connection settings read by Tfs.psm1 at import. Replace the three placeholders, keep the file UTF-8 with BOM (needed if the project name is Hebrew).
# Only CollectionUrl and Project are required; every other key has a default and may be removed.
@{
    CollectionUrl              = 'https://<TFS_HOST>/tfs/<COLLECTION>'
    Project                    = '<PROJECT>'

    # List sizes: 0 or omitted -Top means DefaultTop; larger values are capped at MaxTop.
    DefaultTop                 = 20
    MaxTop                     = 200

    # Build failure log tail (lines).
    LogTailLines               = 40
    MaxLogTailLines            = 200

    # Work item states treated as closed by Get-TfsMyItems.
    ClosedStates               = @('Closed', 'Done', 'Removed')

    # Get-TfsDailySummary look-back window (hours).
    SummaryHours               = 24

    # Get-TfsDeployed: release definitions inspected per call.
    DeployedDefaultDefinitions = 3
    DeployedMaxDefinitions     = 10

    # Web request timeout (seconds).
    TimeoutSec                 = 100
}
