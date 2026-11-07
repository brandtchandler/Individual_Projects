# Find-LogErrors.ps1
# Shows recent Error events from a Windows Event Log with full details for troubleshooting.
# Run:  .\Find-LogErrors.ps1
# Or:  .\Find-LogErrors.ps1 -LogName Application -Hours 48 -MaxEvents 20
[CmdletBinding()]
param(
   [ValidateSet("System","Application","Security")]
   [string]$LogName = "System",
   [int]$Hours = 24,
   [int]$MaxEvents = 15,
   [string]$OutFile = "C:\temp\LogErrorsReport_$(Get-Date -Format 'yyyy-MM-dd_HHmm').txt"
)
$filter = @{
   LogName   = $LogName
   Level     = 2          # 2 = Error (1 = Critical, 3 = Warning)
   StartTime = (Get-Date).AddHours(-$Hours)
}
try {
   $events = Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop
   Write-Host "Found $($events.Count) error(s) in '$LogName' in the last $Hours hour(s):" -ForegroundColor Cyan
   Write-Host ""
   $report = foreach ($e in $events) {
       $props = if ($e.Properties) {
           ($e.Properties | ForEach-Object { $_.Value }) -join " | "
       } else { "None" }
       [PSCustomObject]@{
           TimeCreated   = $e.TimeCreated
           Id            = $e.Id
           Level         = $e.LevelDisplayName
           ProviderName  = $e.ProviderName
           MachineName   = $e.MachineName
           RecordId      = $e.RecordId
           Message       = ($e.Message -replace '\s+', ' ').Trim()
           Properties    = $props
       }
   }
   # Show on screen
   $report | Format-List
   # Save detailed report
   $report | Format-List | Out-File -FilePath $OutFile -Encoding utf8
   # Optional secure channel checks
   if ($IncludeSecureChannel) {
       Write-Host "`nRunning secure channel checks..." -ForegroundColor Yellow
       $nltestOutput = @()
       $nltestOutput += "===== SECURE CHANNEL CHECKS ====="
       $nltestOutput += "Time: $(Get-Date)"
       $nltestOutput += ""
       # 1. Query current secure channel status
       $nltestOutput += "--- nltest /sc_query:PEACEHEALTH ---"
       $nltestOutput += (nltest /sc_query:PEACEHEALTH 2>&1 | Out-String).Trim()
       $nltestOutput += ""
       # 2. Show which Domain Controller the machine is using
       $nltestOutput += "--- nltest /dsgetdc:PEACEHEALTH ---"
       $nltestOutput += (nltest /dsgetdc:PEACEHEALTH 2>&1 | Out-String).Trim()
       $nltestOutput += ""
       # 3. Attempt to reset the secure channel (optional – only if you want it)
       # Uncomment the next two lines if you want the script to try a reset automatically
       # $nltestOutput += "--- nltest /sc_reset:PEACEHEALTH ---"
       # $nltestOutput += (nltest /sc_reset:PEACEHEALTH 2>&1 | Out-String).Trim()
       # Show on screen
       $nltestOutput | ForEach-Object { Write-Host $_ }
       # Append to the report file
       $nltestOutput | Out-File -FilePath $OutFile -Append -Encoding utf8
   }
   Write-Host "`nReport successfully saved to: $OutFile" -ForegroundColor Green
}
catch {
   Write-Host "No Error events found in '$LogName' in the last $Hours hour(s) — good news." -ForegroundColor Green
}
