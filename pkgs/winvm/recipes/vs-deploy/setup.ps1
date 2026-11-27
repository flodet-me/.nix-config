# Makes the VM a Visual Studio 2026 deploy target (see recipe.env).
# Works on images from ../winvm (Linux) and ../windows-host (VirtualBox).
$ErrorActionPreference = 'Stop'
# No progress bars: the firewall cmdlets fail drawing them when the output is
# redirected ("Access is denied ... reading the console output buffer").
$ProgressPreference = 'SilentlyContinue'
$port = 4026                 # VS 2026's msvsmon port; the host forwards to it
$remoteTools = 'https://aka.ms/vs/18/release/RemoteTools.amd64ret.enu.exe'

# Developer Mode: needed to register UWP / MSIX packages from a folder (F5 deploy).
$unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
New-Item -Force $unlock | Out-Null
Set-ItemProperty $unlock -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord
Set-ItemProperty $unlock -Name AllowAllTrustedApps -Value 1 -Type DWord
Write-Host 'Developer Mode on'

# VS 2026 remote tools (the Linux images have them already).
function Find-Msvsmon {
    Get-ChildItem "$env:ProgramFiles\Microsoft Visual Studio*\Common7\IDE\Remote Debugger\x64\msvsmon.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
$msvsmon = Find-Msvsmon
if (-not $msvsmon) {
    Write-Host 'installing the Visual Studio 2026 remote tools'
    $exe = "$env:TEMP\RemoteTools.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    (New-Object Net.WebClient).DownloadFile($remoteTools, $exe)
    $p = Start-Process $exe '/install /quiet /norestart' -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "remote tools installer exit code $($p.ExitCode)" }
    $msvsmon = Find-Msvsmon
    if (-not $msvsmon) { throw 'msvsmon.exe missing after installing the remote tools' }
}
Write-Host "msvsmon: $msvsmon"

# Windows App SDK runtimes, for unpackaged WinUI 3 apps (WindowsPackageType
# None) copied in by `deploy`; packaged apps bring theirs with F5. One per
# Microsoft.WindowsAppSDK major.minor your apps use (they install side by side).
$appRuntimes = @('1.8', '2.6')
foreach ($v in $appRuntimes) {
    $exe = "$env:TEMP\WindowsAppRuntimeInstall-$v-x64.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    (New-Object Net.WebClient).DownloadFile("https://aka.ms/windowsappsdk/$v/latest/windowsappruntimeinstall-x64.exe", $exe)
    # An unknown version redirects to a web page instead of an installer.
    $f = [IO.File]::OpenRead($exe); $head = (New-Object byte[] 2); [void]$f.Read($head, 0, 2); $f.Close()
    if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) { throw "Windows App SDK $v`: no installer at aka.ms/windowsappsdk/$v (unknown version?)" }
    $p = Start-Process $exe '--quiet --force' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Windows App SDK $v runtime installer exit code $($p.ExitCode)" }
    Remove-Item $exe -Force
    Write-Host "Windows App SDK $v runtime installed"
}

# vsdbg, the .NET debugger VS Code uses (over SSH: `vscode setup`), with
# Microsoft's install script. That script lags behind the C# extension, so
# `vscode setup` and each VS Code debug build replace it with the extension's
# own build (lib/guest/vsdbg.ps1). Rider brings its own debugger over SSH.
$vsdbgScript = "$env:TEMP\GetVsDbg.ps1"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
(New-Object Net.WebClient).DownloadFile('https://aka.ms/getvsdbgps1', $vsdbgScript)
# (RuntimeID win7-x64 is the script's name for 64-bit Windows; its messages on
# stderr must not end this script, so the result is checked instead.)
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $vsdbgScript -Version latest -RuntimeID win7-x64 -InstallPath C:\vsdbg 2>&1 | ForEach-Object { "$_" }
$ErrorActionPreference = $eap
if (-not (Test-Path C:\vsdbg\vsdbg.exe)) { throw "vsdbg missing after its install script (C:\vsdbg): $($log -join ' | ')" }
Remove-Item $vsdbgScript -Force
Write-Host "vsdbg installed: C:\vsdbg ($((Get-Item C:\vsdbg\vsdbg.exe).VersionInfo.ProductVersion))"

# SSH logins get cmd.exe (Windows' default) instead of PowerShell: Rider's
# remote debugging sends cmd syntax (echo %LOCALAPPDATA%, if exist ...) and
# fails silently otherwise. winvm's own commands start PowerShell explicitly.
Set-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value "$env:SystemRoot\System32\cmd.exe"
Write-Host 'SSH login shell: cmd.exe (for Rider)'

# The desktop signs in automatically (VirtualBox's unattended install may not
# set it up for good), so msvsmon is running whenever the VM is.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if ((Get-ItemProperty $winlogon).AutoAdminLogon -ne '1') {
    Set-ItemProperty $winlogon -Name AutoAdminLogon -Value '1'
    Set-ItemProperty $winlogon -Name DefaultUserName -Value $env:USERNAME
    Set-ItemProperty $winlogon -Name DefaultPassword -Value 'dev'
    Set-ItemProperty $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
    Remove-ItemProperty $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue
    Write-Host "automatic sign-in as $env:USERNAME"
}
$desktopUser = (Get-ItemProperty $winlogon).DefaultUserName

# msvsmon at every sign-in, in the desktop session: apps started from Visual
# Studio appear on the VM's desktop. No authentication: the port is only
# forwarded to the host's 127.0.0.1 (or a host-only network). Same task name
# as the Linux images' on-demand task, so `winvm debug vs` keeps working.
# A watchdog loop starts msvsmon again whenever it isn't running: it can end
# (e.g. when a connected Visual Studio goes away), and F5 for packaged/UWP apps
# then fails with "Remote Debugger does not appear to be running".
$watchdog = "while (`$true) { if (-not (Get-Process msvsmon -ErrorAction SilentlyContinue)) { Start-Process '$msvsmon' '/noauth /anyuser /nosecuritywarn /nofirewallwarn /port $port' }; Start-Sleep 5 }"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$watchdog`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $desktopUser
$principal = New-ScheduledTaskPrincipal -UserId $desktopUser -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Stop-ScheduledTask winvm-msvsmon -ErrorAction SilentlyContinue   # an older instance would block the new one
Register-ScheduledTask winvm-msvsmon -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "msvsmon starts at sign-in of $desktopUser (port $port)"

# Block rules Windows adds when msvsmon listens before an allow rule exists and
# nobody answers its firewall prompt: they win over allow rules, and Visual
# Studio then reports "Remote Debugger does not appear to be running".
Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { $_.Program -match '\\Remote Debugger\\[^\\]+\\msvsmon\.exe$' } |
    Get-NetFirewallRule | Where-Object { $_.Action -eq 'Block' -and $_.Direction -eq 'Inbound' } | Remove-NetFirewallRule
# Per-program rules (a port rule alone still prompts), x64 and x86 msvsmon.
# Only the missing ones: safe to run again.
$have = @(Get-NetFirewallRule -DisplayName 'winvm: VS remote debugger*' -ErrorAction SilentlyContinue | Get-NetFirewallApplicationFilter | ForEach-Object Program)
Get-ChildItem (Split-Path (Split-Path $msvsmon)) -Recurse -Filter msvsmon.exe | Where-Object { $have -notcontains $_.FullName } | ForEach-Object {
    New-NetFirewallRule -DisplayName "winvm: VS remote debugger ($($_.Directory.Name))" -Direction Inbound `
        -Program $_.FullName -Action Allow | Out-Null
}

# Where `winvm.ps1 deploy` (and the MSBuild targets) put .NET builds.
New-Item -ItemType Directory -Force C:\deploy | Out-Null

# Running now if the desktop is signed in; otherwise at the next sign-in.
if (Get-Process explorer -ErrorAction SilentlyContinue) { Start-ScheduledTask winvm-msvsmon }
Write-Host 'recipe done: Visual Studio can deploy to this VM'
