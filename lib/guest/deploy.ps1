# Installs a build in the VM: run by `winvm deploy` (Linux) and `winvm.ps1 deploy`
# (Windows host) over SSH, elevated, as the VM user. C:\deploy\APP gets the
# content of TAR, replacing what was there; programs running from there and the
# service winvm-APP are stopped first. Then, optionally:
#   -Run      start EXE on the desktop of the signed-in user (like a double-click)
#   -Service  register EXE as the Windows service winvm-APP (manual start) and start it
#   -Install  the folder has an .msix/.appx package: install it with its certificate
#             (with -Run: then start its app on the desktop)
#   -Wait     with -Run/-Service: the app waits for a debugger before its own code
#             runs (a .NET startup hook), so attaching catches Main and startup
param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Tar,
    [string]$Exe = '',
    [string]$ArgsB64 = '',      # command line arguments, base64 (UTF-8): no quoting trouble on the way
    [switch]$Run, [switch]$Service, [switch]$Install, [switch]$Wait
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dest = "C:\deploy\$App"
$svc = "winvm-$App"
$arguments = if ($ArgsB64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgsB64)) } else { '' }

$s = Get-Service $svc -ErrorAction SilentlyContinue
if ($s -and $s.Status -ne 'Stopped') {
    Stop-Service $svc -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30 -and (Get-Service $svc).Status -ne 'Stopped'; $i++) { Start-Sleep 1 }
    Write-Output "stopped service $svc"
}
$running = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith("$dest\", [StringComparison]::OrdinalIgnoreCase) })
foreach ($r in $running) { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue; Write-Output "stopped $($r.Name) ($($r.ProcessId))" }
for ($i = 1; Test-Path $dest; $i++) {   # files of a just stopped program can stay locked briefly
    try { Remove-Item -Recurse -Force $dest } catch { if ($i -ge 10) { throw }; Start-Sleep 1 }
}
New-Item -ItemType Directory -Force $dest | Out-Null
tar.exe -xf $Tar -C $dest
if ($LASTEXITCODE -ne 0) { throw "tar -x exit code $LASTEXITCODE" }
Remove-Item $Tar -Force

# A framework-dependent .NET app (APP.runtimeconfig.json, no coreclr.dll of its
# own) needs its runtime in the VM; without it the app exits right away.
foreach ($rc in @(Get-ChildItem $dest -Filter *.runtimeconfig.json -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $dest 'coreclr.dll')) { break }
    $o = (Get-Content -Raw $rc.FullName | ConvertFrom-Json).runtimeOptions
    foreach ($fw in @($o.framework) + @($o.frameworks) | Where-Object { $_ }) {
        $major = [int]([string]$fw.version).Split('.')[0]
        $any = $o.rollForward -in 'Major', 'LatestMajor'   # default: only the same major version
        $have = @(Get-ChildItem "$env:ProgramFiles\dotnet\shared\$($fw.name)" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $m = [int]$_.Name.Split('.')[0]; $m -eq $major -or ($any -and $m -gt $major) })
        if (-not $have) {
            Write-Output "warning: $($rc.Name -replace '\.runtimeconfig\.json$') needs $($fw.name) $major.x, which this VM doesn't have: install it (winvm ssh `"choco install -y dotnet-$major.0-desktopruntime`", or in a recipe's packages.txt like recipes/vs-deploy) or deploy a self-contained build"
        }
    }
}

if ($Install) {
    $pkg = Get-ChildItem $dest -Recurse -Include *.msixbundle, *.msix, *.appxbundle, *.appx |
        Where-Object { $_.DirectoryName -notmatch '\\Dependencies(\\|$)' } | Select-Object -First 1
    if (-not $pkg) { throw 'no .msix/.appx package in the folder' }
    Get-ChildItem $pkg.DirectoryName -Filter *.cer | ForEach-Object {
        Import-Certificate -FilePath $_.FullName -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
        Write-Output "trusted certificate $($_.Name)"
    }
    $deps = @(Get-ChildItem (Join-Path $pkg.DirectoryName 'Dependencies') -Recurse -Include *.msix, *.appx -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -in 'x64', 'neutral' } | ForEach-Object FullName)
    # Its identity, from the manifest inside: an app Visual Studio registered from
    # loose files (F5, development mode) blocks a package of the same name
    # (0x80073CFB "already installed an unpackaged version"); that registration goes.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # A rebuilt package with the same version is refused too ("same identity ...
    # contents are different"): that version is uninstalled first (its app data with it).
    $idName = $null; $idVersion = $null
    if ($pkg.Extension -in '.msix', '.appx') {
        $zip = [IO.Compression.ZipFile]::OpenRead($pkg.FullName)
        try {
            $entry = $zip.GetEntry('AppxManifest.xml')
            $reader = New-Object IO.StreamReader($entry.Open())
            $id = ([xml]$reader.ReadToEnd()).Package.Identity
            $idName = $id.Name; $idVersion = $id.Version
            $reader.Close()
        } finally { $zip.Dispose() }
    }
    if ($idName) {
        Get-AppxPackage -Name $idName | Where-Object { $_.IsDevelopmentMode -or $_.Version -eq $idVersion } | ForEach-Object {
            Remove-AppxPackage $_.PackageFullName
            $why = if ($_.IsDevelopmentMode) { 'registered from loose files, e.g. by Visual Studio' } else { 'same version: replaced' }
            Write-Output "removed $($_.PackageFullName) ($why)"
        }
    }
    $a = @{ Path = $pkg.FullName; ForceApplicationShutdown = $true; ForceUpdateFromAnyVersion = $true }
    if ($deps) { $a.DependencyPath = $deps }
    Add-AppxPackage @a
    # Which package that was: its manifest names it (for -Run).
    $installed = @(if ($idName) { Get-AppxPackage -Name $idName }) | Sort-Object { [version]$_.Version } | Select-Object -Last 1
    Write-Output "installed $($pkg.Name)$(if ($installed) { " ($($installed.PackageFullName))" })"
}

if ($Install) {
    if ($Service -or $Wait) { throw 'an installed package can be started (run option), not as a service or waiting for a debugger' }
} else {
    if (-not $Exe) { $Exe = "$App.exe" }
    $exePath = Join-Path $dest $Exe
    if (($Run -or $Service) -and -not (Test-Path $exePath)) { throw "$exePath not found (name the program with the exe option)" }
}
if ($Wait -and -not ($Run -or $Service)) { throw 'the wait option needs run or service' }

# The startup hook for -Wait: .NET (Core) runs StartupHook.Initialize() before
# Main when DOTNET_STARTUP_HOOKS names the assembly. Compiled here once, with
# the C# compiler of .NET Framework (the runtime's mscorlib facade resolves it).
$hook = 'C:\winvm\WinvmWaitForDebugger-2.dll'   # -N: new name when the code below changes
if ($Wait -and -not (Test-Path $hook)) {
    Add-Type -OutputAssembly $hook -OutputType Library -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;
internal class StartupHook {
    public static void Initialize() {
        Environment.SetEnvironmentVariable("DOTNET_STARTUP_HOOKS", null);   // not for child processes
        int seconds;   // WINVM_WAIT_SECONDS: at most that long (services), else until a debugger is there
        if (!int.TryParse(Environment.GetEnvironmentVariable("WINVM_WAIT_SECONDS"), out seconds)) seconds = 0;
        Environment.SetEnvironmentVariable("WINVM_WAIT_SECONDS", null);
        if (Debugger.IsAttached) return;
        try { Console.Error.WriteLine("winvm: waiting for a debugger to attach..."); } catch { }
        DateTime end = DateTime.UtcNow.AddSeconds(seconds);
        while (!Debugger.IsAttached && (seconds == 0 || DateTime.UtcNow < end)) Thread.Sleep(100);
    }
}
'@
}

if ($Service) {
    $bin = "`"$exePath`"$(if ($arguments) { " $arguments" })"
    if ($s) { & sc.exe config $svc binPath= $bin start= demand | Out-Null; if ($LASTEXITCODE) { throw "sc.exe config: $LASTEXITCODE" } }
    else { New-Service -Name $svc -BinaryPathName $bin -DisplayName "winvm: $App" -StartupType Manual | Out-Null }
    # Service environment: the startup hook only for this start with -Wait.
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
    if ($Wait) {
        # A service has to reach Main within 30 s (Windows' start timeout, error 1053),
        # so it waits for a debugger 25 s at most, then starts anyway.
        New-ItemProperty $key -Name Environment -PropertyType MultiString -Value @("DOTNET_STARTUP_HOOKS=$hook", 'WINVM_WAIT_SECONDS=25') -Force | Out-Null
        # Started in the background: starting a service blocks until it reaches Main.
        Start-Process sc.exe -ArgumentList 'start', $svc -WindowStyle Hidden
        $id = 0
        # (Win32_Service has no process id yet while the start is pending.)
        for ($i = 0; $i -lt 20 -and -not $id; $i++) {
            Start-Sleep -Milliseconds 500
            $id = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $exePath } | ForEach-Object ProcessId)[0]
        }
        Remove-ItemProperty $key -Name Environment -ErrorAction SilentlyContinue   # read at start; later starts don't wait
        if (-not $id) { throw "service $svc did not start" }
        Write-Output "service $svc starting (pid $id, account LocalSystem), waiting up to 25 s for a debugger"
    } else {
        Remove-ItemProperty $key -Name Environment -ErrorAction SilentlyContinue
        Start-Service $svc
        $id = (Get-CimInstance Win32_Service -Filter "Name='$svc'").ProcessId
        Write-Output "service $svc started (pid $id, account LocalSystem)"
    }
}

if ($Run) {
    # In the desktop session: a one-shot task for the signed-in user (SSH runs in session 0)
    $winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $user = $winlogon.DefaultUserName
    for ($i = 0; $i -lt 60 -and -not (Get-Process explorer -ErrorAction SilentlyContinue); $i++) { Start-Sleep 2 }
    $act = @{ Execute = $exePath; WorkingDirectory = $dest }
    if ($arguments) { $act.Argument = $arguments }
    if ($Wait) {
        # The task can't set environment variables: a hidden PowerShell starts the app with one.
        $q = { param($v) "'" + ($v -replace "'", "''") + "'" }
        $launch = "`$env:DOTNET_STARTUP_HOOKS = $(& $q $hook); Start-Process -FilePath $(& $q $exePath) -WorkingDirectory $(& $q $dest)$(if ($arguments) { " -ArgumentList $(& $q $arguments)" })"
        $act = @{ Execute = 'powershell.exe'; WorkingDirectory = $dest
                  Argument = "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch)))" }
    }
    $isOurs = { param($proc) $proc.Path -eq $exePath }
    if ($Install) {
        # A package's app starts by its AppUserModelID, like from the Start menu.
        if (-not $installed) { throw 'the installed package was not found (run option)' }
        $appId = @((Get-AppxPackageManifest $installed).Package.Applications.Application)[0].Id
        $act = @{ Execute = 'explorer.exe'; Argument = "shell:AppsFolder\$($installed.PackageFamilyName)!$appId" }
        $root = $installed.InstallLocation.TrimEnd('\') + '\'
        $isOurs = { param($proc) $proc.Path -and $proc.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) }
        $Exe = $installed.Name
    }
    $task = "winvm-run-$App"
    Register-ScheduledTask $task -Action (New-ScheduledTaskAction @act) -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive) `
        -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries) -Force | Out-Null
    $before = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { & $isOurs $_ } | ForEach-Object Id)
    Start-ScheduledTask $task
    $p = $null
    for ($i = 0; $i -lt 20 -and -not $p; $i++) { Start-Sleep -Milliseconds 500; $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { (& $isOurs $_) -and $before -notcontains $_.Id } | Select-Object -First 1 }
    Unregister-ScheduledTask $task -Confirm:$false   # the program keeps running
    $w = if ($Wait) { ', waiting for a debugger' } else { '' }
    if ($p) { Write-Output "started $Exe on the desktop of $user (pid $($p.Id))$w" } else { Write-Output "started $Exe on the desktop of $user (it exited already, or is still starting)$w" }
}
