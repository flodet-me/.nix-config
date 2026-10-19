# Runs once at first logon (from autounattend.xml FirstLogonCommands), elevated.
# Progress goes to C:\winvm\provision.log and to COM1, which the host tails
# during `winvm build`. Shuts the VM down when finished.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$src = Split-Path -Parent $PSCommandPath
$dst = 'C:\winvm'
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item "$src\*" $dst -Recurse -Force
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
    Get-ChildItem "$root\*\w10\amd64\*.cat" | ForEach-Object {
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
}

Step 'Chocolatey' {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ProgramData\chocolatey\bin"
}

Step 'OpenSSH server' {
    try {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
        if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
    } catch {
        Log "Windows capability failed ($_), falling back to choco openssh"
        choco install openssh -y --no-progress --params '"/SSHServerFeature"'
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

$packages = Get-Content "$dst\packages.txt" | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ }
foreach ($pkg in $packages) {
    Step "choco install $pkg" {
        choco install $pkg -y --no-progress
        if ($LASTEXITCODE -notin 0, 3010) { throw "choco exit code $LASTEXITCODE" }
    }
}

if (Test-Path "$dst\custom.ps1") {
    Step 'custom.ps1' { & "$dst\custom.ps1" }
}

if ($DisableWindowsUpdate) {
    Step 'Disable automatic Windows Update' {
        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        New-Item -Force $au | Out-Null
        Set-ItemProperty $au -Name NoAutoUpdate -Value 1 -Type DWord
    }
}

if ($failed.Count -eq 0) { Log 'PROVISION-OK' }
else { Log "PROVISION-FAILED: $($failed -join ', ')" }
if ($serial) { $serial.Close() }
shutdown.exe /s /t 5 /f
