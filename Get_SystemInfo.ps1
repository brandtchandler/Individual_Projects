# Get-SystemInfo.ps1
# PowerShell version of Script 1 from @veriqta's "Bash Scripting for Beginners:
# Your First 10 Scripts" (Instagram, 2026-10-17) — the System Information Reporter.
# Read-only: it only reports information, it changes nothing on your machine.
# Now also reports the computer serial number (Win32_BIOS).
# Also reports domain/workgroup (Win32_ComputerSystem) and applied Group Policy Objects (gpresult).
# Run it with:  .\Get-SystemInfo.ps1
# Or with a computer name:  .\Get-SystemInfo.ps1 -ComputerName MyPC

[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME
)

function Format-SizeGB {
    param([uint64]$Bytes)
    return "{0:N2} GB" -f ($Bytes / 1GB)
}

function Get-AppliedGPOs {
    param([string]$ComputerName)
    # gpresult is local-only for a reliable read. For a remote name, report that.
    if ($ComputerName -ne $env:COMPUTERNAME) {
        return @("Remote GPO check not run — run locally for full list")
    }
    try {
        $output = gpresult /r /scope:computer 2>$null
        $inSection = $false
        $gpos = @()
        foreach ($line in $output) {
            if ($line -match 'Applied Group Policy Objects') { $inSection = $true; continue }
            if ($inSection) {
                if ($line -match '^\s*$') { continue }
                if ($line -match 'The following GPOs were not applied|Filtering:') { break }
                $trim = $line.Trim()
                if ($trim) { $gpos += $trim }
            }
        }
        if ($gpos.Count -eq 0) { return @("None found / no computer GPOs applied") }
        return $gpos
    } catch {
        return @("Not available: $($_.Exception.Message)")
    }
}

function Get-SystemReport {
    param([string]$ComputerName)

    $os       = Get-CimInstance Win32_OperatingSystem -ComputerName $ComputerName
    $computer = Get-CimInstance Win32_ComputerSystem -ComputerName $ComputerName
    $cpu      = Get-CimInstance Win32_Processor -ComputerName $ComputerName |
                Select-Object -First 1
    $bios     = Get-CimInstance Win32_BIOS -ComputerName $ComputerName

    $uptime   = (Get-Date) - $os.LastBootUpTime
    $totalRam = $computer.TotalPhysicalMemory
    $freeRam  = $os.FreePhysicalMemory * 1KB
    $domainJoined = $computer.PartOfDomain
    $domainOrWorkgroup = if ($domainJoined) { $computer.Domain } else { $computer.Workgroup }
    $gpos = Get-AppliedGPOs -ComputerName $ComputerName

    [PSCustomObject]@{
        ComputerName = $ComputerName
        OS           = $os.Caption
        OSVersion    = $os.Version
        Manufacturer = $computer.Manufacturer
        Model        = $computer.Model
        SerialNumber = $bios.SerialNumber
        Domain       = $domainOrWorkgroup
        DomainJoined = $domainJoined
        AppliedGPOs  = ($gpos -join '; ')
        CPU          = $cpu.Name.Trim()
        Cores        = $cpu.NumberOfCores
        TotalRAM     = Format-SizeGB $totalRam
        FreeRAM      = Format-SizeGB $freeRam
        Uptime       = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
    }
}

Write-Host "=== System Information Report ===" -ForegroundColor Cyan
Write-Host "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host ""

Get-SystemReport -ComputerName $ComputerName | Format-List

Write-Host "--- Disks ---" -ForegroundColor Cyan
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ComputerName $ComputerName |
    Select-Object DeviceID,
        @{ Name = 'Size';     Expression = { Format-SizeGB $_.Size } },
        @{ Name = 'Free';     Expression = { Format-SizeGB $_.FreeSpace } },
        @{ Name = 'FreePct';  Expression = { "{0:N1}%" -f ($_.FreeSpace / $_.Size * 100) } } |
    Format-Table -AutoSize
