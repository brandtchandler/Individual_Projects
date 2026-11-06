# Get-HealthReport.ps1
# One-page health check, saved as a dated text file on the Desktop.
# Run:  .\Get-HealthReport.ps1
# Or:   .\Get-HealthReport.ps1 -OutputPath "C:\Reports"

[CmdletBinding()]
param(
    [string]$OutputPath = "$HOME\Desktop"
)

$os       = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$bios     = Get-CimInstance Win32_BIOS
$uptime   = (Get-Date) - $os.LastBootUpTime
$memUsed  = [math]::Round((1 - ($os.FreePhysicalMemory * 1KB) / $computer.TotalPhysicalMemory) * 100, 1)

$lines = @()
$lines += "=== PC Health Report ==="
$lines += "Computer : $env:COMPUTERNAME  ($($computer.Manufacturer) $($computer.Model))"
$lines += "Serial   : $($bios.SerialNumber)"
$lines += "Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$lines += "OS       : $($os.Caption)"
$lines += "Uptime   : {0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
$lines += "Memory   : $memUsed% in use"
$lines += ""
$lines += "--- Disks (under 15% free are flagged) ---"
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $pct = [math]::Round($_.FreeSpace / $_.Size * 100, 1)
    $flag = if ($pct -lt 15) { "  *** LOW SPACE ***" } else { "" }
    $lines += "{0} {1:N1}% free of {2:N0} GB{3}" -f $_.DeviceID, $pct, ($_.Size / 1GB), $flag
}
$lines += ""
$lines += "--- Services ---"
$stoppedAuto = Get-Service | Where-Object { $_.Status -eq 'Stopped' -and $_.StartType -eq 'Automatic' }
$lines += "Stopped automatic services: $($stoppedAuto.Count)"
$stoppedAuto | ForEach-Object { $lines += "  - $($_.DisplayName) ($($_.Name))" }
$lines += ""
$lines += "--- Errors in the last 24 hours (System log) ---"
try {
    $errs = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=2; StartTime=(Get-Date).AddHours(-24) } -ErrorAction Stop
    $lines += "Error events: $($errs.Count)"
} catch {
    $lines += "Error events: 0"
}

$file = Join-Path $OutputPath ("HealthReport_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd"))
$lines | Out-File -FilePath $file -Encoding utf8
$lines | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "Saved to: $file" -ForegroundColor Green
