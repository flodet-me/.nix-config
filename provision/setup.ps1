# Runs once at first logon (from autounattend.xml FirstLogonCommands), elevated.
# Progress goes to C:\winvm\provision.log and to COM1, which the host tails
# during `winvm build`. Shuts the VM down when finished.
# $Online (settings.ps1) is false for `winvm build --offline`: then nothing
# here may touch the network, everything comes from the ISO and cache\.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$src = Split-Path -Parent $PSCommandPath
$cache = "$src\cache"        # host-downloaded installers, read straight from the CD
$dst = 'C:\winvm'
New-Item -ItemType Directory -Force $dst | Out-Null
Get-ChildItem $src -Exclude cache | Copy-Item -Destination $dst -Recurse -Force
. "$dst\settings.ps1"

$serial = $null
try { $serial = New-Object System.IO.Ports.SerialPort 'COM1', 115200; $serial.Open() } catch { $serial = $null }

function Log([string]$msg) {
    $line = "[winvm] $(Get-Date -Format HH:mm:ss) $msg"
    Write-Host $line
    Add-Content -Path "$dst\provision.log" -Value $line
    if ($serial) { try { $serial.WriteLine($line) } catch {} }
}

$failed = @()
function Step([string]$name, [scriptblock]$body) {
    Log "==> $name"
    try { & $body; Log "ok: $name" }
    catch { $script:failed += $name; Log "FAILED: ${name}: $_" }
}

function Read-List([string]$file) {
    Get-Content $file | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ }
}

Log "mode: $(if ($Online) { 'online' } else { 'OFFLINE (no network during build)' })"

# Report what the specialize pass (debloat, features) did.
if (Test-Path "$dst\specialize.log") {
    foreach ($line in Get-Content "$dst\specialize.log") {
        Log $line
        if ($line -match 'FAILED: ([^:]+)') { $failed += "specialize: $($Matches[1])" }
    }
} else {
    Log 'specialize.ps1 did not run'
    $failed += 'specialize'
}

function Find-Drive([string]$file) {
    Get-PSDrive -PSProvider FileSystem | ForEach-Object { "$($_.Root)$file" } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

Step 'VirtIO guest tools' {
    $tools = Find-Drive 'virtio-win-guest-tools.exe'
    if (-not $tools) { throw 'virtio-win ISO not found' }
    $root = Split-Path -Parent $tools
    # Trust the driver signer first, otherwise Windows shows an install prompt per driver.
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store 'TrustedPublisher', 'LocalMachine'
    $store.Open('ReadWrite')
    Get-ChildItem "$root\*\$VirtioOs\amd64\*.cat" | ForEach-Object {
        $cert = (Get-AuthenticodeSignature $_.FullName).SignerCertificate
        if ($cert) { $store.Add($cert) }
    }
    $store.Close()
    $p = Start-Process $tools -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "installer exit code $($p.ExitCode)" }
}

Step 'Power settings' {
    powercfg /change standby-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /hibernate off
    # Power button (ACPI powerdown from `winvm stop`) = shut down.
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
    powercfg /setactive SCHEME_CURRENT
}

Step 'Network profile private' {
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
}

Step 'Remote Desktop' {
    Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    # Group by resource id so this works on localized Windows.
    Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'
}

Step 'Explorer / developer settings' {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-ItemProperty $adv -Name HideFileExt -Value 0
    Set-ItemProperty $adv -Name Hidden -Value 1
    $dev = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    New-Item -Force $dev | Out-Null
    Set-ItemProperty $dev -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord
    Set-ItemProperty $dev -Name AllowAllTrustedApps -Value 1 -Type DWord
}

Step 'Test-friendly system settings' {
    # Paths > 260 chars for apps that opt in.
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -Type DWord
    # Full crash dumps of any crashing process in C:\dumps.
    $wer = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
    New-Item -Force $wer | Out-Null
    New-Item -ItemType Directory -Force 'C:\dumps' | Out-Null
    Set-ItemProperty $wer -Name DumpFolder -Value 'C:\dumps' -Type ExpandString
    Set-ItemProperty $wer -Name DumpType -Value 2 -Type DWord
    Set-ItemProperty $wer -Name DumpCount -Value 20 -Type DWord
    # Real shutdowns (no hybrid "fast startup"): clean state for snapshots and boot tests.
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
    # Show what Windows is doing during boot/logon/shutdown.
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name VerboseStatus -Value 1 -Type DWord
    # No "How do you want to open this file?" each time a new app registers for a
    # file type (e.g. after installing an editor): files keep opening with their default.
    New-Item -Force 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name NoNewAppAlert -Value 1 -Type DWord
    # Local scripts run without signing. (Set-ExecutionPolicy errors here
    # because this process runs with -ExecutionPolicy Bypass.)
    $ps = 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell'
    Set-ItemProperty $ps -Name ExecutionPolicy -Value RemoteSigned
    # Keep Defender on (realistic), but never upload binaries under test to Microsoft.
    Set-MpPreference -SubmitSamplesConsent 2
}

if ($Debloat) {
    Step 'Remove leftover apps for this user' {
        $patterns = Read-List "$dst\remove-apps.txt"
        Get-AppxPackage | Where-Object { $name = $_.Name; $patterns | Where-Object { $name -like $_ } } | ForEach-Object {
            $pkg = $_
            try { Remove-AppxPackage $pkg.PackageFullName; Log "removed $($pkg.Name)" }
            catch { Log "could not remove $($pkg.Name): $_" }
        }
    }
}

Step 'OpenSSH server' {
    $installed = $false
    if ($Online) {
        try {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
            if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
            $installed = $true
        } catch { Log "Windows capability failed ($_), using the cached MSI" }
    }
    if (-not $installed) {
        # The capability's payload comes from Windows Update; offline we use Win32-OpenSSH.
        if (-not (Test-Path "$cache\openssh.msi")) { throw "cache\openssh.msi missing (run 'winvm fetch' on the host while online)" }
        $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$cache\openssh.msi`"", '/qn', '/norestart' -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "msiexec exit code $($p.ExitCode)" }
    }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    New-Item -Force 'HKLM:\SOFTWARE\OpenSSH' | Out-Null
    New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -PropertyType String -Force `
        -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
    $ak = "$env:ProgramData\ssh\administrators_authorized_keys"
    Copy-Item "$dst\authorized_keys" $ak -Force
    icacls.exe $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
            -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
    }
}

# --- test and debugging tools from cache\ (provision/tools.txt) -------------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$toolPaths = @()
$menu = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Test Tools"
New-Item -ItemType Directory -Force $menu | Out-Null
$shell = New-Object -ComObject WScript.Shell
# Sysinternals has ~150 executables; only these get Start menu entries.
$sysinternalsMenu = 'Procmon64', 'procexp64', 'Autoruns64', 'Tcpview64', 'Dbgview64', 'vmmap64', 'Winobj64', 'RAMMap64'

function Add-Shortcut([string]$exe) {
    $name = [IO.Path]::GetFileNameWithoutExtension($exe) -replace '64$', ''
    $lnk = $shell.CreateShortcut("$menu\$name.lnk")
    $lnk.TargetPath = $exe
    $lnk.Save()
}

foreach ($line in Read-List "$dst\tools.txt") {
    # Not $name: Step's own parameter of that name would shadow it inside the script block.
    $toolName, $null, $rest = -split $line
    $toolArgs = @($rest | Where-Object { $_ })
    if ($toolName -eq 'openssh') { continue }   # installed above
    $file = Get-ChildItem "$cache\$toolName.*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $file) { Log "skipped tool ${toolName}: not in cache (run 'winvm fetch' on the host while online)"; continue }
    Step "tool $toolName" {
        $dir = "C:\Tools\$toolName"
        switch -Regex ($file.Extension) {
            '^\.zip$' {
                Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
                [IO.Compression.ZipFile]::ExtractToDirectory($file.FullName, $dir)
                $bin = $toolArgs | Where-Object { $_ -like 'bin:*' } | Select-Object -First 1
                if ($bin) { $dir = (Resolve-Path (Join-Path $dir $bin.Substring(4)) | Select-Object -First 1).Path }
                elseif (Test-Path "$dir\amd64") { $dir = "$dir\amd64" }
                $script:toolPaths += $dir
                # 32-bit twins (foo-x86.exe, foo32.exe) don't need their own menu entry.
                $exes = Get-ChildItem "$dir\*.exe" | Where-Object { $_.BaseName -notmatch '(x86|32)$' }
                $only = $toolArgs | Where-Object { $_ -like 'menu:*' } | ForEach-Object { $_.Substring(5) -split ',' }
                if ($toolName -eq 'sysinternals') { $only = $sysinternalsMenu }
                if ($only) { $exes = $exes | Where-Object { $_.BaseName -in $only } }
                $exes | ForEach-Object { Add-Shortcut $_.FullName }
            }
            '^\.(msix|msixbundle|appx|appxbundle)$' {
                Add-AppxProvisionedPackage -Online -PackagePath $file.FullName -SkipLicense | Out-Null
                foreach ($a in $toolArgs) {
                    if ($a -notmatch '^extract:(.+)$') { continue }
                    # Command-line tools from inside the package (e.g. cdb, kd, dbgsrv).
                    $prefix = $Matches[1].TrimEnd('/') + '/'
                    $zip = [IO.Compression.ZipFile]::OpenRead($file.FullName)
                    try {
                        foreach ($e in $zip.Entries) {
                            if (-not $e.FullName.StartsWith($prefix) -or -not $e.Name) { continue }
                            $out = Join-Path $dir ([uri]::UnescapeDataString($e.FullName.Substring($prefix.Length)))
                            New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
                            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
                        }
                    } finally { $zip.Dispose() }
                    $script:toolPaths += $dir
                }
            }
            '^\.msi$' {
                $p = Start-Process msiexec.exe -ArgumentList (@('/i', "`"$($file.FullName)`"", '/qn', '/norestart') + $toolArgs) -Wait -PassThru
                if ($p.ExitCode -notin 0, 3010) { throw "msiexec exit code $($p.ExitCode)" }
            }
            '^\.exe$' {
                $p = if ($toolArgs) { Start-Process $file.FullName -ArgumentList $toolArgs -Wait -PassThru }
                     else { Start-Process $file.FullName -Wait -PassThru }
                if ($p.ExitCode -notin 0, 3010) { throw "installer exit code $($p.ExitCode)" }
            }
            default { throw "don't know how to install $($file.Name)" }
        }
    }
}

Step 'Tools on PATH, WinvmTest module' {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    foreach ($p in $toolPaths) { if ($path -notlike "*$p*") { $path += ";$p" } }
    [Environment]::SetEnvironmentVariable('Path', $path, 'Machine')
    $env:Path += ';' + ($toolPaths -join ';')
    # Accept the Sysinternals EULA up front so the tools don't prompt.
    New-Item -Force 'HKCU:\Software\Sysinternals' | Out-Null
    Set-ItemProperty 'HKCU:\Software\Sysinternals' -Name EulaAccepted -Value 1 -Type DWord
    reg.exe add 'HKU\.DEFAULT\Software\Sysinternals' /v EulaAccepted /t REG_DWORD /d 1 /f | Out-Null
    $mod = "$env:ProgramFiles\WindowsPowerShell\Modules\WinvmTest"
    New-Item -ItemType Directory -Force $mod | Out-Null
    Copy-Item "$dst\WinvmTest.psm1" $mod -Force
    $lnk = $shell.CreateShortcut("$env:PUBLIC\Desktop\Test Tools.lnk")
    $lnk.TargetPath = $menu
    $lnk.Save()
}

Step 'Remote debugging + UI test servers (on demand: winvm debug / uitest)' {
    # Run in the logged-on user's session (autologon), so debuggees can show UI
    # and processes started from the debugger appear on the desktop.
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -MultipleInstances IgnoreNew
    # Search instead of hard-coding the folder: it changes with each VS version.
    $msvsmon = Get-ChildItem "$env:ProgramFiles\Microsoft Visual Studio*\Common7\IDE\Remote Debugger\x64\msvsmon.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    if ($msvsmon) {
        Log "msvsmon: $msvsmon"
        # No authentication: the port is only reachable through the host's 127.0.0.1 forward.
        $action = New-ScheduledTaskAction -Execute $msvsmon -Argument "/noauth /anyuser /nosecuritywarn /nofirewallwarn /port $VsDebugPort"
        Register-ScheduledTask winvm-msvsmon -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        # Per-program rules: a port rule alone still makes Windows show a firewall
        # prompt. Also for the x86 msvsmon it starts to debug 32-bit processes.
        Get-ChildItem (Split-Path (Split-Path $msvsmon)) -Recurse -Filter msvsmon.exe | ForEach-Object {
            New-NetFirewallRule -DisplayName "winvm: VS remote debugger ($($_.Directory.Name))" -Direction Inbound `
                -Program $_.FullName -Action Allow | Out-Null
        }
    } else { Log 'VS remote tools not installed, skipping msvsmon' }
    if (Test-Path 'C:\Tools\windbg\dbgsrv.exe') {
        $action = New-ScheduledTaskAction -Execute 'C:\Tools\windbg\dbgsrv.exe' -Argument "-t tcp:port=$DbgsrvPort"
        Register-ScheduledTask winvm-dbgsrv -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        New-NetFirewallRule -Name winvm-dbgsrv -DisplayName 'winvm: WinDbg process server' -Direction Inbound -Program 'C:\Tools\windbg\dbgsrv.exe' -Action Allow | Out-Null
    } else { Log 'WinDbg not installed, skipping dbgsrv' }
    $wad = "${env:ProgramFiles(x86)}\Windows Application Driver\WinAppDriver.exe"
    if (Test-Path $wad) {
        # Listen on all interfaces (the host reaches the guest through QEMU's NAT);
        # WinAppDriver rejects 0.0.0.0 but takes the HTTP.sys wildcard. Its console
        # (with the request log) starts minimized so it doesn't cover the apps under
        # test; it can't run hidden, because without a console it exits at once
        # ("Press ENTER to exit" reads end-of-input).
        $action = New-ScheduledTaskAction -Execute cmd.exe -Argument "/c start `"WinAppDriver`" /min `"$wad`" * $UiDriverPort"
        Register-ScheduledTask winvm-winappdriver -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        # Port rule, not a program rule: HTTP.sys (the System process) receives the traffic.
        New-NetFirewallRule -Name winvm-winappdriver -DisplayName 'winvm: WinAppDriver' -Direction Inbound -Protocol TCP -LocalPort $UiDriverPort -Action Allow | Out-Null
    } else { Log 'WinAppDriver not installed, skipping' }
}

# --- online-only: Chocolatey packages ----------------------------------------
$packages = @(Read-List "$dst\packages.txt")
if (-not $Online) {
    Log "skipped (offline build): Chocolatey and packages.txt ($($packages -join ', '))"
} else {
    Step 'Chocolatey' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path += ";$env:ProgramData\chocolatey\bin"
    }
    foreach ($pkg in $packages) {
        Step "choco install $pkg" {
            choco install $pkg -y --no-progress
            if ($LASTEXITCODE -notin 0, 3010) { throw "choco exit code $LASTEXITCODE" }
        }
    }
}

if (Test-Path "$dst\custom.ps1") {
    Step 'custom.ps1' { & "$dst\custom.ps1" }
}

if ($DisableWindowsUpdate) {
    Step 'Disable automatic Windows Update + Store app updates' {
        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        New-Item -Force $au | Out-Null
        Set-ItemProperty $au -Name NoAutoUpdate -Value 1 -Type DWord
        $store = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
        New-Item -Force $store | Out-Null
        Set-ItemProperty $store -Name AutoDownload -Value 2 -Type DWord
    }
}

# Windows Setup looks the hardware up in Autopilot when online. If an organization
# registered matching hardware, its device profile (MDM enrollment, rename,
# telemetry) was applied: that image must not become the clean base.
Step 'No Autopilot profile applied' {
    $ap = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\Autopilot' -ErrorAction SilentlyContinue
    if ($ap.CloudAssignedTenantDomain -or $ap.CloudAssignedTenantId) {
        throw "Setup received the Autopilot profile of '$($ap.CloudAssignedTenantDomain)' ($($ap.CloudAssignedTenantId))"
    }
    Log "computer name: $env:COMPUTERNAME"
}

# Programs that crashed while installing (seen: pwsh, svchost) left dumps; a
# clean image starts with an empty C:\dumps so every dump in it is yours.
Remove-Item C:\dumps\* -Force -ErrorAction SilentlyContinue

if ($failed.Count -eq 0) { Log 'PROVISION-OK' }
else { Log "PROVISION-FAILED: $($failed -join ', ')" }
if ($serial) { $serial.Close() }
shutdown.exe /s /t 5 /f
