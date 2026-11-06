# Find-LogErrors.ps1
# Shows recent Error events from a Windows Event Log.
# Run:  .\Find-LogErrors.ps1
# Or:   .\Find-LogErrors.ps1 -LogName Application -Hours 48 -MaxEvents 10

[CmdletBinding()]
param(
    [ValidateSet("System","Application","Security")]
    [string]$LogName = "System",
    [int]$Hours = 24,
    [int]$MaxEvents = 10
)

$filter = @{
    LogName   = $LogName
    Level     = 2            # 2 = Error (1 = Critical, 3 = Warning)
    StartTime = (Get-Date).AddHours(-$Hours)
}

try {
    $events = Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop
    Write-Host "Found $($events.Count) error(s) in '$LogName' in the last $Hours hour(s):" -ForegroundColor Cyan
    $events | Select-Object TimeCreated, Id, ProviderName,
        @{ Name = 'Message'; Expression = {
            $m = $_.Message -replace '\s+', ' '
            if ($m.Length -gt 140) { $m.Substring(0, 140) + '...' } else { $m }
        } } | Format-List
}
catch {
    Write-Host "No Error events found in '$LogName' in the last $Hours hour(s) — good news." -ForegroundColor Green
}
