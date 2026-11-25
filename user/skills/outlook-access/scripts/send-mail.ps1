param(
    [string]$To = "<WORK_EMAIL>",
    [Parameter(Mandatory = $true)][string]$Subject,
    [Parameter(Mandatory = $true)][string]$Body,
    [string[]]$Attachments = @()
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $Subject -or -not $Body) {
    Write-Error "Subject and Body are required"
    exit 1
}

try {
    $outlook = New-Object -ComObject Outlook.Application
    $mail = $outlook.CreateItem(0)
    $mail.To = $To
    $mail.Subject = $Subject
    $mail.Body = $Body
    foreach ($file in $Attachments) {
        if (Test-Path $file) { [void]$mail.Attachments.Add((Resolve-Path $file).Path) }
        else { Write-Error "Attachment not found: $file"; exit 1 }
    }
    $mail.Send()
    Write-Output "OK: mail sent to $To"
}
catch {
    Write-Error "FAILED: $($_.Exception.Message)"
    exit 1
}
