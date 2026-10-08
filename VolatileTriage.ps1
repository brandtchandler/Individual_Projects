#Requires -Version 5.1
# Volatile Data Triage Collection - Windows 11 - Powershell (Run as Admin)
# Non-destructive | Admin assumed | JSON output to Downloads
# Version: 1.0.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$scriptVersion = '1.0.0'
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outputPath = Join-Path $env:USERPROFILE "Downloads\VolatileTriage_$timestamp.json"

# ------------------------------------------------------------------
# Helper: Admin check
# ------------------------------------------------------------------
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Warning "Script is NOT running elevated. Some data (drivers, full process details, etc.) may be incomplete."
}

# ------------------------------------------------------------------
# Chain of Custody
# ------------------------------------------------------------------
$custody = [ordered]@{
    ScriptVersion     = $scriptVersion
    CollectionTimeUTC = (Get-Date).ToUniversalTime().ToString('o')
    CollectionTimeLocal = (Get-Date).ToString('o')
    Hostname          = $env:COMPUTERNAME
    Domain            = $env:USERDOMAIN
    CollectedBy       = "$env:USERDOMAIN\$env:USERNAME"
    UserSID           = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    IsElevated        = Test-IsAdmin
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    OSCaption         = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    OutputFile        = $outputPath
    Notes             = "Non-destructive volatile triage. No system state was modified."
}

# ------------------------------------------------------------------
# 1. Basic System Information
# ------------------------------------------------------------------
Write-Host "[*] Collecting system information..." -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue

$systemInfo = [ordered]@{
    Hostname          = $env:COMPUTERNAME
    Domain            = $cs.Domain
    Manufacturer      = $cs.Manufacturer
    Model             = $cs.Model
    OSCaption         = $os.Caption
    OSVersion         = $os.Version
    OSBuild           = $os.BuildNumber
    InstallDate       = $os.InstallDate
    LastBootUpTime    = $os.LastBootUpTime
    Uptime            = if ($os) { (Get-Date) - $os.LastBootUpTime } else { $null }
    TotalPhysicalMemoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
    LogicalProcessors = $cs.NumberOfLogicalProcessors
    BIOSVersion       = $bios.SMBIOSBIOSVersion
    SerialNumber      = $bios.SerialNumber
    TimeZone          = (Get-TimeZone).DisplayName
}

# ------------------------------------------------------------------
# 2. Running Processes (with command lines)
# ------------------------------------------------------------------
Write-Host "[*] Collecting processes..." -ForegroundColor Cyan
$processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        ProcessId       = $_.ProcessId
        Name            = $_.Name
        ExecutablePath  = $_.ExecutablePath
        CommandLine     = $_.CommandLine
        ParentProcessId = $_.ParentProcessId
        CreationDate    = $_.CreationDate
        SessionId       = $_.SessionId
        Priority        = $_.Priority
        WorkingSetSize  = $_.WorkingSetSize
        HandleCount     = $_.HandleCount
        ThreadCount     = $_.ThreadCount
        Owner           = try { $_.GetOwner().User } catch { $null }
    }
}

# ------------------------------------------------------------------
# 3. Active TCP / UDP Connections + Listening Ports
# ------------------------------------------------------------------
Write-Host "[*] Collecting network connections..." -ForegroundColor Cyan
$tcp = Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object `
    LocalAddress, LocalPort, RemoteAddress, RemotePort, State, AppliedSetting, OwningProcess, CreationTime

$udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Select-Object `
    LocalAddress, LocalPort, OwningProcess, CreationTime

# ------------------------------------------------------------------
# 4. ARP / Neighbor Table
# ------------------------------------------------------------------
Write-Host "[*] Collecting ARP / neighbor table..." -ForegroundColor Cyan
$neighbors = Get-NetNeighbor -ErrorAction SilentlyContinue | Select-Object `
    IPAddress, LinkLayerAddress, State, AddressFamily, InterfaceAlias, InterfaceIndex

# ------------------------------------------------------------------
# 5. Logged-on Users / Sessions
# ------------------------------------------------------------------
Write-Host "[*] Collecting logged-on users..." -ForegroundColor Cyan
$loggedOn = @()
try {
    $quser = quser 2>$null
    if ($quser) {
        $loggedOn = $quser | Select-Object -Skip 1 | ForEach-Object {
            $line = $_ -replace '\s{2,}', ',' -split ','
            [ordered]@{
                Username    = $line[0].Trim().TrimStart('>')
                SessionName = $line[1].Trim()
                Id          = $line[2].Trim()
                State       = $line[3].Trim()
                IdleTime    = $line[4].Trim()
                LogonTime   = ($line[5..($line.Length-1)] -join ' ').Trim()
            }
        }
    }
} catch {}

$cimLoggedOn = Get-CimInstance Win32_LoggedOnUser -ErrorAction SilentlyContinue | ForEach-Object {
    $user = $_.Antecedent
    $session = $_.Dependent
    [ordered]@{
        Domain   = $user.Domain
        User     = $user.Name
        LogonId  = $session.LogonId
    }
}

# ------------------------------------------------------------------
# 6. PowerShell History
# ------------------------------------------------------------------
Write-Host "[*] Collecting PowerShell history..." -ForegroundColor Cyan
$psHistory = @()
$historyPath = (Get-PSReadLineOption -ErrorAction SilentlyContinue).HistorySavePath
if (-not $historyPath) {
    $historyPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
}
if (Test-Path $historyPath) {
    $psHistory = Get-Content $historyPath -ErrorAction SilentlyContinue -Tail 500   # last 500 entries
}

# ------------------------------------------------------------------
# 7. Clipboard Contents
# ------------------------------------------------------------------
Write-Host "[*] Collecting clipboard..." -ForegroundColor Cyan
$clipboard = $null
try {
    $clipboard = Get-Clipboard -Format Text -ErrorAction SilentlyContinue
} catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $clipboard = [System.Windows.Forms.Clipboard]::GetText()
    } catch {}
}

# ------------------------------------------------------------------
# 8. DNS Cache
# ------------------------------------------------------------------
Write-Host "[*] Collecting DNS cache..." -ForegroundColor Cyan
$dnsCache = Get-DnsClientCache -ErrorAction SilentlyContinue | Select-Object `
    Entry, Name, Type, Data, DataLength, Section, TimeToLive, Status

# ------------------------------------------------------------------
# 9. Network Interfaces + Routing Table
# ------------------------------------------------------------------
Write-Host "[*] Collecting network configuration..." -ForegroundColor Cyan
$interfaces = Get-NetIPConfiguration -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        InterfaceAlias  = $_.InterfaceAlias
        InterfaceIndex  = $_.InterfaceIndex
        IPv4Address     = $_.IPv4Address.IPAddress
        IPv6Address     = $_.IPv6Address.IPAddress
        IPv4DefaultGateway = $_.IPv4DefaultGateway.NextHop
        DNSServer       = $_.DNSServer.ServerAddresses
        NetAdapter      = $_.NetAdapter | Select-Object Name, Status, MacAddress, LinkSpeed
    }
}

$routes = Get-NetRoute -ErrorAction SilentlyContinue | Select-Object `
    DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, Protocol, AddressFamily

# ------------------------------------------------------------------
# 10. Loaded Drivers / Modules
# ------------------------------------------------------------------
Write-Host "[*] Collecting drivers..." -ForegroundColor Cyan
$drivers = Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Select-Object `
    Name, DisplayName, PathName, State, StartMode, Status, ServiceType

# ------------------------------------------------------------------
# 11. Scheduled Tasks
# ------------------------------------------------------------------
Write-Host "[*] Collecting scheduled tasks..." -ForegroundColor Cyan
$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
    $info = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    [ordered]@{
        TaskName    = $_.TaskName
        TaskPath    = $_.TaskPath
        State       = $_.State
        Author      = $_.Author
        Description = $_.Description
        LastRunTime = $info.LastRunTime
        NextRunTime = $info.NextRunTime
        LastResult  = $info.LastTaskResult
        NumberOfMissedRuns = $info.NumberOfMissedRuns
        Actions     = $_.Actions | Select-Object Execute, Arguments, WorkingDirectory
        Triggers    = $_.Triggers | Select-Object -Property *
        Principal   = $_.Principal | Select-Object UserId, LogonType, RunLevel
    }
}

# ------------------------------------------------------------------
# 12. Environment Variables
# ------------------------------------------------------------------
Write-Host "[*] Collecting environment variables..." -ForegroundColor Cyan
$envVars = Get-ChildItem Env: | Sort-Object Name | ForEach-Object {
    [ordered]@{ Name = $_.Name; Value = $_.Value }
}

# ------------------------------------------------------------------
# 13. Open Handles / File Locks (limited – pure PowerShell)
# ------------------------------------------------------------------
# Full open-handle enumeration requires Sysinternals handle.exe.
# Here we collect process handle counts and a few high-level indicators only.
Write-Host "[*] Collecting process handle summary..." -ForegroundColor Cyan
$handleSummary = Get-Process -ErrorAction SilentlyContinue | Select-Object `
    Id, ProcessName, HandleCount, WorkingSet64, PagedMemorySize64, NonpagedSystemMemorySize64

# ------------------------------------------------------------------
# Assemble final object
# ------------------------------------------------------------------
$triage = [ordered]@{
    ChainOfCustody      = $custody
    SystemInformation   = $systemInfo
    Processes           = $processes
    TCPConnections      = $tcp
    UDPEndpoints        = $udp
    ARP_Neighbors       = $neighbors
    LoggedOnUsers_quser = $loggedOn
    LoggedOnUsers_CIM   = $cimLoggedOn
    PowerShellHistory   = $psHistory
    Clipboard           = $clipboard
    DNSCache            = $dnsCache
    NetworkInterfaces   = $interfaces
    RoutingTable        = $routes
    Drivers             = $drivers
    ScheduledTasks      = $tasks
    EnvironmentVariables = $envVars
    ProcessHandleSummary = $handleSummary
}

# ------------------------------------------------------------------
# Write JSON + calculate hash for chain of custody
# ------------------------------------------------------------------
Write-Host "[*] Writing JSON to $outputPath ..." -ForegroundColor Cyan
$triage | ConvertTo-Json -Depth 8 -Compress:$false | Out-File -FilePath $outputPath -Encoding utf8

# Update custody with file hash
$fileHash = (Get-FileHash -Path $outputPath -Algorithm SHA256).Hash
$custody.OutputSHA256 = $fileHash
$custody.FileSizeBytes = (Get-Item $outputPath).Length

# Re-write with final custody hash
$triage.ChainOfCustody = $custody
$triage | ConvertTo-Json -Depth 8 -Compress:$false | Out-File -FilePath $outputPath -Encoding utf8

Write-Host ""
Write-Host "Collection complete." -ForegroundColor Green
Write-Host "Output file : $outputPath"
Write-Host "SHA-256     : $fileHash"
Write-Host "Size        : $([math]::Round($custody.FileSizeBytes / 1MB, 2)) MB"
