# Guest side of `winvm run / crashes / netcap / proxy / trace`. The host copies
# this file to C:\winvm\hosttools.ps1 before each use and dot-sources it, so
# it works on every VM without rebuilding the image.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Runs a program elevated on the logged-on user's desktop. Needed for tools
# that don't work from an SSH session, which lives on a hidden desktop and
# whose processes Windows' OpenSSH ends when the session closes.
function Invoke-DesktopTask([string]$Exe, [string]$Arguments, [int]$WaitSec = 0) {
    $user = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwner
    if (-not $user.User) { throw 'nobody is logged on to the desktop' }
    $name = "winvm-task-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $action = if ($Arguments) { New-ScheduledTaskAction -Execute $Exe -Argument $Arguments } else { New-ScheduledTaskAction -Execute $Exe }
    $principal = New-ScheduledTaskPrincipal -UserId "$($user.Domain)\$($user.User)" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries
    Register-ScheduledTask $name -Action $action -Principal $principal -Settings $settings | Out-Null
    Start-ScheduledTask $name
    if ($WaitSec) {
        for ($i = 0; $i -lt 20 -and (Get-ScheduledTask $name).State -ne 'Running'; $i++) { Start-Sleep -Milliseconds 100 }
        for ($i = 0; $i -lt $WaitSec * 2 -and (Get-ScheduledTask $name).State -eq 'Running'; $i++) { Start-Sleep -Milliseconds 500 }
        if ((Get-ScheduledTask $name).State -eq 'Running') { throw "$Exe $Arguments did not finish within $WaitSec s" }
        Unregister-ScheduledTask $name -Confirm:$false
    }
    # Without waiting the task stays registered: deleting it would end the program.
}

# --- winvm run ----------------------------------------------------------------

# Starts the program on the user's desktop through a one-shot scheduled task and
# returns at once; the task's wrapper writes pid.txt, stdout/stderr and finally
# result.json into the run directory.
# $ArgsB64: the complete, already quoted Windows command line (base64, UTF-8).
function Start-WinvmRun([string]$Dir, [string]$Exe, [string]$ArgsB64, [string]$WorkDir) {
    $cmdLine = if ($ArgsB64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgsB64)) } else { '' }
    $wrapper = @"
`$ErrorActionPreference = 'Stop'
`$start = Get-Date
try {
    `$p = @{ FilePath = '$($Exe -replace "'", "''")'; WorkingDirectory = '$($WorkDir -replace "'", "''")'; PassThru = `$true
            RedirectStandardOutput = '$Dir\stdout.txt'; RedirectStandardError = '$Dir\stderr.txt' }
    `$a = '$($cmdLine -replace "'", "''")'
    if (`$a) { `$p.ArgumentList = `$a }   # one string: passed on exactly as quoted by the host
    `$proc = Start-Process @p
    `$null = `$proc.Handle   # without this, ExitCode stays empty for redirected processes
    Set-Content '$Dir\pid.txt' `$proc.Id
    `$proc.WaitForExit()
    `$code = `$proc.ExitCode
    `$err = `$null
} catch { `$code = `$null; `$err = `$_.ToString() }
@{ exitCode = `$code; error = `$err; start = `$start.ToString('o'); end = (Get-Date).ToString('o') } |
    ConvertTo-Json | Set-Content '$Dir\result.json'
"@
    Set-Content "$Dir\wrapper.ps1" $wrapper
    $user = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwner
    if (-not $user.User) { throw 'nobody is logged on to the desktop' }
    $name = 'winvm-run-' + (Split-Path $Dir -Leaf)
    $action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\wrapper.ps1`""
    $principal = New-ScheduledTaskPrincipal -UserId "$($user.Domain)\$($user.User)" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries
    Register-ScheduledTask $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask $name
    for ($i = 0; $i -lt 100 -and -not (Test-Path "$Dir\pid.txt") -and -not (Test-Path "$Dir\result.json"); $i++) { Start-Sleep -Milliseconds 100 }
    Unregister-ScheduledTask $name -Confirm:$false   # the running wrapper is not affected
    if (Test-Path "$Dir\pid.txt") { 'pid ' + (Get-Content "$Dir\pid.txt") } else { 'not started' }
}

function Get-WinvmRunState([string]$Dir) {
    if (Test-Path "$Dir\result.json") { 'done' } else { 'running' }
}

function Stop-WinvmRun([string]$Dir) {
    if (Test-Path "$Dir\pid.txt") { Stop-Process -Id ([int](Get-Content "$Dir\pid.txt")) -Force -ErrorAction SilentlyContinue }
}

# --- crash dumps --------------------------------------------------------------

# Symbols from Microsoft's server when online (cached in C:\symbols), else local only.
function Get-SymbolPath {
    $online = try { (New-Object Net.Sockets.TcpClient).ConnectAsync('msdl.microsoft.com', 443).Wait(3000) } catch { $false }
    if ($online) { 'srv*C:\symbols*https://msdl.microsoft.com/download/symbols' } else { 'C:\symbols' }
}

# $SymDir: where the program's own .pdb files are (e.g. the folder it ran from).
function Invoke-DumpAnalysis([string]$Dump, [string]$Out, [string]$SymDir) {
    $cdb = (Get-Command cdb.exe -ErrorAction SilentlyContinue).Source
    if (-not $cdb) { Set-Content $Out 'cdb.exe not found (WinDbg tools not installed)'; return }
    $sym = (@($SymDir, (Get-SymbolPath)) | Where-Object { $_ }) -join ';'
    & $cdb -z $Dump -y $sym -c '!analyze -v; q' 2>&1 | Set-Content $Out
}

# Dumps newer than $Since (all if empty): copied into $Dir with an analysis each.
function Save-WinvmCrashes([string]$Dir, [string]$Since, [string]$Name, [string]$SymDir) {
    $dumps = Get-ChildItem C:\dumps -Filter *.dmp -ErrorAction SilentlyContinue
    if ($Since) { $t = [datetime]::Parse($Since); $dumps = $dumps | Where-Object LastWriteTime -ge $t.AddSeconds(-2) }
    if ($Name) { $dumps = $dumps | Where-Object Name -like "$Name*" }
    foreach ($d in $dumps) {
        Copy-Item $d.FullName $Dir
        Invoke-DumpAnalysis $d.FullName "$Dir\$($d.BaseName).analysis.txt" $SymDir
        $d.Name
    }
}

function Get-WinvmCrashList {
    Get-ChildItem C:\dumps -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        ForEach-Object { '{0:yyyy-MM-dd HH:mm:ss}  {1,8:N0} KB  {2}' -f $_.LastWriteTime, ($_.Length / 1KB), $_.Name }
}

# --- network capture (pktmon) -------------------------------------------------

function Start-WinvmNetCapture {
    # Through cmd: PowerShell 5.1 turns pktmon's "not running" on stderr into an error.
    cmd.exe /c "pktmon stop >nul 2>&1"
    Remove-Item C:\winvm\netcap.etl -ErrorAction SilentlyContinue
    pktmon start --capture --pkt-size 0 --file-name C:\winvm\netcap.etl | Out-Null
    if ($LASTEXITCODE) { throw "pktmon start failed ($LASTEXITCODE)" }
}

function Stop-WinvmNetCapture {
    pktmon stop | Out-Null
    pktmon etl2pcap C:\winvm\netcap.etl --out C:\winvm\netcap.pcapng | Out-Null
    if ($LASTEXITCODE) { throw "pktmon etl2pcap failed ($LASTEXITCODE)" }
}

# --- HTTP(S) proxy -------------------------------------------------------------

function Set-WinvmProxy([string]$Proxy, [string]$CertFile) {
    if ($CertFile) { Import-Certificate -FilePath $CertFile -CertStoreLocation Cert:\LocalMachine\Root | Out-Null }
    # WinINET (most apps, Edge/Chrome) for the desktop user, WinHTTP for services.
    $sid = (Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwnerSid).Sid
    $key = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty $key -Name ProxyServer -Value $Proxy
    Set-ItemProperty $key -Name ProxyOverride -Value '<local>'
    Set-ItemProperty $key -Name ProxyEnable -Value 1 -Type DWord
    netsh winhttp set proxy $Proxy '<local>' | Out-Null
}

function Clear-WinvmProxy([string]$CertSubject) {
    $sid = (Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwnerSid).Sid
    Set-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 0 -Type DWord
    netsh winhttp reset proxy | Out-Null
    if ($CertSubject) { Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like "*$CertSubject*" | Remove-Item }
}

# --- Process Monitor / ETW trace ---------------------------------------------

# Process Monitor runs on the desktop (minimized): from an SSH session it can't
# record and can't be stopped.
function Start-WinvmTrace([switch]$Etw) {
    $pm = (Get-Command Procmon64.exe -ErrorAction SilentlyContinue).Source
    if (-not $pm) { throw 'Procmon64.exe not found (Sysinternals not installed)' }
    Get-Process Procmon, Procmon64 -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item C:\winvm\trace.pml, C:\winvm\trace.csv, C:\winvm\trace.etl -ErrorAction SilentlyContinue
    Invoke-DesktopTask $pm '/AcceptEula /Quiet /Minimized /BackingFile C:\winvm\trace.pml'
    for ($i = 0; $i -lt 60 -and -not (Test-Path C:\winvm\trace.pml); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path C:\winvm\trace.pml)) { throw 'Process Monitor did not start recording' }
    if ($Etw) { wpr -start GeneralProfile -filemode | Out-Null }
}

function Stop-WinvmTrace([switch]$Etw) {
    $pm = (Get-Command Procmon64.exe).Source
    if ($Etw) { wpr -stop C:\winvm\trace.etl | Out-Null }
    Invoke-DesktopTask $pm '/Terminate' -WaitSec 60
    for ($i = 0; $i -lt 120 -and (Get-Process Procmon64 -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    # CSV is readable anywhere; the .pml opens in Process Monitor.
    Invoke-DesktopTask $pm '/AcceptEula /Quiet /Minimized /OpenLog C:\winvm\trace.pml /SaveAs C:\winvm\trace.csv' -WaitSec 900
}

# --- winvm info / ps / kill / service / apps / events / ports / windows -------

function Out-Table { $input | Format-Table -AutoSize | Out-String -Width 250 | ForEach-Object { $_.Trim("`r`n") } }

function Get-DesktopUser {
    $o = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwner
    if ($o.User) { "$($o.Domain)\$($o.User)" } else { '(nobody signed in)' }
}

function Get-WinvmInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
    $licText = switch ($lic.LicenseStatus) { 1 { 'activated' } 0 { 'unlicensed' } default { "not activated (status $_)" } }
    if ($lic.Name -match 'Eval') { $licText = "evaluation, $([int]($lic.GracePeriodRemaining / 1440)) days left" }
    $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
              (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
    $hotfix = Get-HotFix | Sort-Object InstalledOn -Descending -ErrorAction SilentlyContinue | Select-Object -First 1
    $info = [ordered]@{
        'windows'      = "$($os.Caption) $($os.Version).$ubr ($($os.OSArchitecture))"
        'license'      = $licText
        'computer'     = "$($cs.Name), $($cs.NumberOfLogicalProcessors) CPUs, $([math]::Round($cs.TotalPhysicalMemory / 1GB, 1)) GB RAM"
        'uptime'       = ((Get-Date) - $os.LastBootUpTime).ToString('d\d\ hh\h\ mm\m')
        'memory used'  = "$([math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)) of $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
        'disk C:'      = "$([math]::Round(($c.Size - $c.FreeSpace) / 1GB, 1)) GB used, $([math]::Round($c.FreeSpace / 1GB, 1)) GB free"
        'desktop user' = Get-DesktopUser
        'culture'      = "$((Get-Culture).Name), system locale $((Get-WinSystemLocale).Name), time zone $((Get-TimeZone).Id)"
        'network'      = ((Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceAlias -notlike 'Loopback*').IPAddress -join ', ')
        'last update'  = if ($hotfix) { "$($hotfix.HotFixID) ($($hotfix.InstalledOn.ToString('yyyy-MM-dd')))" } else { '-' }
        'restart'      = if ($reboot) { 'PENDING (winvm reboot)' } else { 'not needed' }
    }
    $info.GetEnumerator() | ForEach-Object { '{0,-13}: {1}' -f $_.Key, $_.Value }
}

function Get-WinvmProcess([string]$Filter) {
    Get-Process -IncludeUserName | Where-Object { -not $Filter -or $_.ProcessName -like "*$Filter*" -or "$($_.Id)" -eq $Filter } |
        Sort-Object WorkingSet64 -Descending | Select-Object -First 50 Id,
            @{ n = 'Name'; e = { $_.ProcessName } },
            @{ n = 'CPU s'; e = { [math]::Round($_.CPU, 1) } },
            @{ n = 'MB'; e = { [math]::Round($_.WorkingSet64 / 1MB) } },
            @{ n = 'Session'; e = { $_.SessionId } },
            @{ n = 'User'; e = { $_.UserName -replace '^.*\\' } },
            @{ n = 'Window'; e = { $_.MainWindowTitle } } | Out-Table
}

function Stop-WinvmProcess([string]$Target, [switch]$Tree) {
    $procs = if ($Target -match '^\d+$') { Get-Process -Id $Target } else { Get-Process -Name ($Target -replace '\.exe$', '') }
    foreach ($p in $procs) {
        if ($Tree) { & taskkill.exe /PID $p.Id /T /F | Out-Null } else { Stop-Process -Id $p.Id -Force }
        "killed $($p.ProcessName) ($($p.Id))"
    }
}

function Get-WinvmService([string]$Filter) {
    Get-CimInstance Win32_Service | Where-Object { -not $Filter -or $_.Name -like "*$Filter*" -or $_.DisplayName -like "*$Filter*" } |
        Sort-Object Name | Select-Object Name, State, StartMode,
            @{ n = 'Account'; e = { $_.StartName -replace '^NT AUTHORITY\\' } }, ProcessId, DisplayName | Out-Table
}

function Show-WinvmService([string]$Name) {
    $s = Get-CimInstance Win32_Service -Filter "Name='$($Name -replace "'", "''")'"
    if (-not $s) { $s = Get-CimInstance Win32_Service | Where-Object DisplayName -eq $Name }
    if (-not $s) { throw "no service '$Name' (winvm service list $Name)" }
    $svc = Get-Service $s.Name
    # "RESTART -- Delay = 60000 milliseconds." lines of sc qfailure, per failure in order
    $actions = & sc.exe qfailure $s.Name 2>$null | Select-String '(\w+(?: \w+)?) -- Delay = (\d+)' |
        ForEach-Object { "$($_.Matches[0].Groups[1].Value.ToLower()) after $([int]$_.Matches[0].Groups[2].Value / 1000) s" }
    $recovery = if ($actions) { $actions -join ', then ' } else { 'nothing (no recovery actions)' }
    $info = [ordered]@{
        'name'         = "$($s.Name) - $($s.DisplayName)"
        'state'        = "$($s.State)$(if ($s.ProcessId) { ", pid $($s.ProcessId)" })$(if ($s.ExitCode) { ", last exit code $($s.ExitCode)" })"
        'start mode'   = "$($s.StartMode)$(if ($s.DelayedAutoStart) { ' (delayed)' })"
        'account'      = $s.StartName
        'binary'       = $s.PathName
        'depends on'   = ($svc.ServicesDependedOn.Name -join ', ')
        'needed by'    = ($svc.DependentServices.Name -join ', ')
        'on failure'   = $recovery
    }
    $info.GetEnumerator() | ForEach-Object { '{0,-11}: {1}' -f $_.Key, $_.Value }
    ''
    'recent Service Control Manager events:'
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager' } -MaxEvents 500 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -like "*$($s.DisplayName)*" -or $_.Message -like "*$($s.Name)*" } | Select-Object -First 10 |
        ForEach-Object { '  {0:yyyy-MM-dd HH:mm:ss}  {1}' -f $_.TimeCreated, ($_.Message -split "`r?`n")[0] }
}

function Set-WinvmService([string]$Action, [string]$Name) {
    switch ($Action) {
        'start'   { Start-Service $Name }
        'stop'    { Stop-Service $Name -Force }
        'restart' { Restart-Service $Name -Force }
        'enable'  { Set-Service $Name -StartupType Automatic }
        'manual'  { Set-Service $Name -StartupType Manual }
        'disable' { Set-Service $Name -StartupType Disabled }
        default   { throw "unknown action '$Action'" }
    }
    $s = Get-CimInstance Win32_Service -Filter "Name='$((Get-Service $Name).Name)'"
    "$($s.Name): $($s.State), start mode $($s.StartMode)"
}

function Get-InstalledApp([string]$Filter) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        Where-Object { -not $Filter -or $_.DisplayName -like "*$Filter*" -or $_.Publisher -like "*$Filter*" } |
        Sort-Object DisplayName
}

function Get-WinvmApp([string]$Filter, [switch]$Store) {
    Get-InstalledApp $Filter | Select-Object @{ n = 'Name'; e = { $_.DisplayName } }, @{ n = 'Version'; e = { $_.DisplayVersion } },
        Publisher, @{ n = 'Installed'; e = { $_.InstallDate } },
        @{ n = 'Type'; e = { if ($_.WindowsInstaller -eq 1) { 'msi' } elseif ($_.PSPath -like '*HKEY_CURRENT_USER*') { 'user' } else { 'exe' } } } | Out-Table
    if ($Store) {
        ''
        'Store / MSIX packages (desktop user):'
        Get-AppxPackage -AllUsers | Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' -and (-not $Filter -or $_.Name -like "*$Filter*") } |
            Sort-Object Name | Select-Object Name, Version, @{ n = 'Publisher'; e = { $_.Publisher -replace ',.*' } } | Out-Table
    }
}

function Uninstall-WinvmApp([string]$Name) {
    $apps = @(Get-InstalledApp $Name)
    $exact = @($apps | Where-Object DisplayName -eq $Name)
    if ($exact.Count -eq 1) { $apps = $exact }
    if ($apps.Count -eq 0) { throw "nothing installed matches '$Name' (winvm apps)" }
    if ($apps.Count -gt 1) { throw "'$Name' matches several apps, be more specific: $(($apps.DisplayName | Select-Object -Unique) -join '; ')" }
    $a = $apps[0]
    if ($a.WindowsInstaller -eq 1 -or $a.UninstallString -match 'msiexec') {
        $code = if ($a.PSChildName -match '^\{.*\}$') { $a.PSChildName } else { [regex]::Match($a.UninstallString, '\{[^}]+\}').Value }
        $p = Start-Process msiexec.exe "/x $code /qn /norestart" -Wait -PassThru
    } elseif ($a.QuietUninstallString) {
        $p = Start-Process cmd.exe "/c `"$($a.QuietUninstallString)`"" -Wait -PassThru
    } else {
        throw "'$($a.DisplayName)' has no silent uninstaller; uninstall it on the desktop (winvm rdp) or run: $($a.UninstallString) with its silent switch"
    }
    switch ($p.ExitCode) {
        0 { "uninstalled $($a.DisplayName)" }
        3010 { "uninstalled $($a.DisplayName); a restart is needed (winvm reboot)" }
        default { throw "uninstalling $($a.DisplayName) failed with exit code $($p.ExitCode)" }
    }
}

function Get-WinvmEvent([int]$Minutes = 60, [string]$Level = 'warning', [string[]]$Log = @('System', 'Application'), [string]$Filter) {
    $levels = switch ($Level) { 'error' { 1, 2 } 'warning' { 1, 2, 3 } default { 1, 2, 3, 4 } }
    $events = foreach ($l in $Log) {
        Get-WinEvent -FilterHashtable @{ LogName = $l; Level = $levels; StartTime = (Get-Date).AddMinutes(-$Minutes) } -ErrorAction SilentlyContinue
    }
    $events = $events | Where-Object { -not $Filter -or $_.ProviderName -like "*$Filter*" -or $_.Message -like "*$Filter*" } | Sort-Object TimeCreated
    if (-not $events) { return "no $Level events in the last $Minutes min ($($Log -join ', '))" }
    $events | Select-Object -Last 100 @{ n = 'Time'; e = { $_.TimeCreated.ToString('MM-dd HH:mm:ss') } },
        @{ n = 'Level'; e = { $_.LevelDisplayName } }, @{ n = 'Log'; e = { $_.LogName } },
        @{ n = 'Source'; e = { $_.ProviderName -replace '^Microsoft-Windows-' } }, Id,
        @{ n = 'Message'; e = { $m = (($_.Message -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1); if ($m.Length -gt 140) { $m.Substring(0, 140) + '...' } else { $m } } } | Out-Table
}

function Get-WinvmPort {
    $names = @{}
    Get-Process | ForEach-Object { $names[[int]$_.Id] = $_.ProcessName }
    $svc = @{}
    Get-CimInstance Win32_Service -Filter "State='Running'" | ForEach-Object { $svc[[int]$_.ProcessId] += @($_.Name) }
    $tcp = Get-NetTCPConnection -State Listen | ForEach-Object { [pscustomobject]@{ Proto = 'tcp'; Address = $_.LocalAddress; Port = $_.LocalPort; Pid = $_.OwningProcess } }
    $udp = Get-NetUDPEndpoint | ForEach-Object { [pscustomobject]@{ Proto = 'udp'; Address = $_.LocalAddress; Port = $_.LocalPort; Pid = $_.OwningProcess } }
    @($tcp) + @($udp) | Where-Object { $_.Address -notin '::1', '127.0.0.1' -or $_.Proto -eq 'tcp' } |
        Sort-Object Proto, Port, Address -Unique | Select-Object Proto, Address, Port, Pid,
            @{ n = 'Process'; e = { $names[[int]$_.Pid] } },
            @{ n = 'Services'; e = { ($svc[[int]$_.Pid] | Select-Object -First 4) -join ',' } } | Out-Table
}
