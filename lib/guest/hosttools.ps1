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
