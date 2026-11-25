param(
    [int]$Count = 10,
    [switch]$UnreadOnly,
    [string[]]$Keywords = @(),        # match ANY of these words in subject OR body
    [string]$SenderContains = "",
    [int]$Days = 0,                    # 0 = no date limit; otherwise only the last N days
    [ValidateSet("Inbox","Sent")][string]$Folder = "Inbox",
    [switch]$FullBody,
    [switch]$ListOnly,                 # headers only (subject, sender, date), no body
    [string]$SaveAttachmentsTo = ""
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Escape-Dasl([string]$s) { return $s.Replace("'", "''") }

try {
    $outlook = New-Object -ComObject Outlook.Application
    $ns = $outlook.GetNamespace("MAPI")
    $folderId = if ($Folder -eq "Sent") { 5 } else { 6 }   # 5 = Sent Items, 6 = Inbox
    $items = $ns.GetDefaultFolder($folderId).Items

    # Fast server-side keyword filter on subject OR body (DASL)
    if ($Keywords.Count -gt 0) {
        $parts = foreach ($k in $Keywords) {
            $e = Escape-Dasl $k
            "(""urn:schemas:httpmail:subject"" LIKE '%$e%' OR ""urn:schemas:httpmail:textdescription"" LIKE '%$e%')"
        }
        $items = $items.Restrict("@SQL=" + ($parts -join " OR "))
    }

    $items.Sort("[ReceivedTime]", $true)   # newest first
    $cutoff = if ($Days -gt 0) { (Get-Date).AddDays(-$Days) } else { $null }

    $shown = 0
    foreach ($m in $items) {
        if ($shown -ge $Count) { break }
        if ($m.Class -ne 43) { continue }                       # 43 = regular mail item
        if ($cutoff -and $m.ReceivedTime -lt $cutoff) { break } # sorted newest first, so stop
        if ($UnreadOnly -and -not $m.UnRead) { continue }
        if ($SenderContains -and ($m.SenderName -notlike "*$SenderContains*") -and ($m.SenderEmailAddress -notlike "*$SenderContains*")) { continue }

        $shown++
        Write-Output "=============================="
        Write-Output "[$shown] Subject : $($m.Subject)"
        Write-Output "From    : $($m.SenderName) <$($m.SenderEmailAddress)>"
        Write-Output "Date    : $($m.ReceivedTime)"
        Write-Output "Unread  : $($m.UnRead)"
        Write-Output "Attachments: $($m.Attachments.Count)"

        if (-not $ListOnly) {
            $body = $m.Body
            if (-not $FullBody -and $body.Length -gt 1000) { $body = $body.Substring(0, 1000) + " ...[truncated]" }
            Write-Output "------------------------------"
            Write-Output $body
        }

        if ($SaveAttachmentsTo -and $m.Attachments.Count -gt 0) {
            if (-not (Test-Path $SaveAttachmentsTo)) { New-Item -ItemType Directory -Path $SaveAttachmentsTo | Out-Null }
            foreach ($att in $m.Attachments) {
                $safeName = ($att.FileName -replace '[\\/:*?"<>|]', '_')
                $att.SaveAsFile((Join-Path $SaveAttachmentsTo $safeName))
                Write-Output "Saved attachment: $safeName"
            }
        }
    }
    if ($shown -eq 0) { Write-Output "No matching mails found" }
}
catch {
    Write-Error "FAILED: $($_.Exception.Message)"
    exit 1
}
