# Provisions a fresh VirtualBox VM for winvm.ps1 (runs elevated over SSH).
# Mirrors the main points of ../provision/setup.ps1 without the QEMU parts.
# Result for the host: C:\winvm\provision-result.txt ("ok" or the failed steps),
# because Windows' SSH server only reports exit codes 0 and 1.
param([string]$Packages = 'C:\winvm\packages.txt', [switch]$DisableWindowsUpdate)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$result = 'C:\winvm\provision-result.txt'
Set-Content $result 'running'
$failed = @()

function Step([string]$name, [scriptblock]$body) {
    Write-Host "==> $name"
    try { & $body; Write-Host "ok: $name" }
    catch { $script:failed += $name; Write-Host "FAILED: ${name}: $_" }
}
function Retry([int]$tries, [scriptblock]$body) {
    for ($i = 1; ; $i++) {
        try { return & $body }
        catch {
            if ($i -ge $tries) { throw }
            Write-Host "  attempt $i failed, retrying in 15 s: $_"
            Start-Sleep 15
            Clear-DnsClientCache -ErrorAction SilentlyContinue
        }
    }
}

Step 'Power settings' {
    & powercfg.exe /change standby-timeout-ac 0
    & powercfg.exe /change monitor-timeout-ac 0
    & powercfg.exe /hibernate off
}
Step 'Network profile private' {
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
}
Step 'Remote Desktop' {
    Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
    Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752'      # "Remote Desktop", any UI language
}
Step 'Explorer / developer settings' {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-ItemProperty $adv -Name HideFileExt -Value 0
    Set-ItemProperty $adv -Name Hidden -Value 1
}
Step 'Crash dumps to C:\dumps' {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
    New-Item -Force $key | Out-Null
    New-Item -ItemType Directory -Force C:\dumps | Out-Null
    Set-ItemProperty $key -Name DumpFolder -Value C:\dumps -Type ExpandString
    Set-ItemProperty $key -Name DumpType -Value 2 -Type DWord      # full dumps
    Set-ItemProperty $key -Name DumpCount -Value 20 -Type DWord
}

$list = @()
if (Test-Path $Packages) { $list = @(Get-Content $Packages | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ }) }
if ($list) {
    Step 'Chocolatey' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Retry 5 {
            Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            if (-not (Test-Path "$env:ProgramData\chocolatey\bin\choco.exe")) { throw 'choco.exe missing after install' }
        }
        $env:Path += ";$env:ProgramData\chocolatey\bin"
    }
    foreach ($p in $list) {
        Step "choco install $p" {
            Retry 3 {
                & choco install $p -y --no-progress --limit-output
                if ($LASTEXITCODE -notin 0, 1641, 3010) { throw "choco exit code $LASTEXITCODE" }
            }
        }
    }
}

if ($DisableWindowsUpdate) {
    Step 'Disable automatic Windows Update' {
        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        New-Item -Force $au | Out-Null
        Set-ItemProperty $au -Name NoAutoUpdate -Value 1 -Type DWord
    }
}

Set-Content $result $(if ($failed) { "failed: $($failed -join ', ')" } else { 'ok' })
