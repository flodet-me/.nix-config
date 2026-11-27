# Visual Studio 2026 Community (the IDE) for classic UWP apps (.NET Native) and native C++
# libraries (UWP app CRT and desktop) for x64 and ARM64 (x86 too). Use it through RDP:
# winvm -n NAME rdp. msbuild over SSH works as well:
#   & "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe" App.sln /restore /p:Configuration=Release /p:Platform=x64
# Community asks for a Microsoft account sign-in after a 30-day trial.
#
# 1. Windows updates first: on an unpatched Windows 10 22H2 the .NET 10 SDK that VS brings
#    crashes ("Your Windows doesn't fully support CET"). One update round per run, restart
#    (exit 3010) until nothing is left. If the runner gives up after its 5 runs, continue
#    with: winvm -n NAME apply vs2026-community --seal
# 2. VS 2026 Community with the components below, Developer Mode.
# DNS is 1.1.1.1 during the run: the host's resolver returned SERVFAIL for the VS CDN.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\Program Files\Microsoft Visual Studio\18\Community'
$msbuild = "$root\MSBuild\Current\Bin\MSBuild.exe"

# Developer Mode: register loose-file UWP builds and unsigned test packages.
$unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
New-Item -Force $unlock | Out-Null
Set-ItemProperty $unlock -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord
Set-ItemProperty $unlock -Name AllowAllTrustedApps -Value 1 -Type DWord
Write-Host 'Developer Mode on'

function Invoke-WindowsUpdateRound {  # -> 'installed=N reboot=True|False'
    $result = 'C:\winvm\wu-result.txt'
    Remove-Item $result -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction powershell.exe "-NoProfile -ExecutionPolicy Bypass -File $PSScriptRoot\wu.ps1"
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask winvm-recipe-wu -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask winvm-recipe-wu
    $deadline = (Get-Date).AddHours(3)
    while (-not (Test-Path $result)) {
        if ((Get-Date) -gt $deadline) { throw 'Windows Update round did not finish within 3 hours; C:\winvm\wu.log' }
        Start-Sleep 20
        if ((Get-ScheduledTask winvm-recipe-wu).State -ne 'Running' -and -not (Test-Path $result)) {
            throw "Windows Update task ended without a result (last result $((Get-ScheduledTaskInfo winvm-recipe-wu).LastTaskResult)); C:\winvm\wu.log"
        }
    }
    Unregister-ScheduledTask winvm-recipe-wu -Confirm:$false
    Get-Content $result
}

# Component IDs: the VS 2026 channel manifest (aka.ms/vs/18/stable/channel, 18.12.1), checked 2026-11-18.
$components = @(
    'Microsoft.VisualStudio.Workload.Universal'                # "WinUI application development"; requires .NET Native + .NET SDK (ComponentGroup.UWP.NetCoreAndStandard)
    'Microsoft.VisualStudio.ComponentGroup.UWP.Support'        # "Universal Windows Platform tools": optional in that workload
    'Microsoft.VisualStudio.ComponentGroup.UWP.VC'             # C++ UWP (app CRT), x86/x64 + ARM64
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'        # C++ desktop x86/x64
    'Microsoft.VisualStudio.Component.VC.Tools.ARM64'          # C++ desktop ARM64
    'Microsoft.VisualStudio.Component.VC.CMake.Project'
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
    'Microsoft.VisualStudio.Component.Git'
)

$adapters = @(Get-NetAdapter | Where-Object Status -eq Up)
foreach ($a in $adapters) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses 1.1.1.1 }
$exitCode = 0
try {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        Write-Host 'a restart is pending'; $exitCode = 3010
    }
    while ($exitCode -eq 0) {
        Write-Host 'Windows Update round (takes a while)'
        $wu = Invoke-WindowsUpdateRound
        Write-Host "  $wu"
        if ($wu -notmatch '^installed=(\d+) reboot=(True|False)$') { throw "Windows Update: $wu; C:\winvm\wu.log" }
        if ($Matches[2] -eq 'True') { $exitCode = 3010 }
        elseif ($Matches[1] -eq '0') { break }
    }
    if ($exitCode -eq 0 -and -not (Test-Path $msbuild)) {
        # VS needs ~20 GB: first drop what the updates left behind (superseded components, downloads).
        Write-Host 'cleaning up after the updates'
        Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
        Remove-Item C:\Windows\SoftwareDistribution\Download\* -Recurse -Force -ErrorAction SilentlyContinue
        & Dism.exe /Online /Quiet /NoRestart /Cleanup-Image /StartComponentCleanup
        if ($LASTEXITCODE -notin 0, 3010) { throw "DISM component cleanup: exit code $LASTEXITCODE" }
        Write-Host ('{0:N1} GB free on C:' -f ((Get-Volume C).SizeRemaining / 1GB))
        $exe = "$env:TEMP\vs_community_2026.exe"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        (New-Object Net.WebClient).DownloadFile('https://aka.ms/vs/18/stable/vs_community.exe', $exe)
        $vsArgs = @('--quiet', '--wait', '--norestart', '--nocache', '--installPath', "`"$root`"") + ($components | ForEach-Object { '--add', $_ })
        Write-Host 'installing VS 2026 Community (UWP + .NET Native, C++ UWP + desktop x86/x64/ARM64, CMake, SDK 26100, Git); takes a while'
        $p = Start-Process $exe $vsArgs -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "vs_community exit code $($p.ExitCode); logs: $env:TEMP\dd_*.log" }
    }
} finally {
    foreach ($a in $adapters) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses }
}
if ($exitCode -ne 0) { Write-Host 'restarting to finish the updates'; exit $exitCode }

if (-not (Test-Path $msbuild)) { throw "MSBuild missing: $msbuild" }
if (-not (Test-Path "${env:ProgramFiles(x86)}\Windows Kits\10\Platforms\UAP\10.0.26100.0")) { throw 'Windows SDK 10.0.26100 missing' }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
foreach ($c in $components) {
    if (-not (& $vswhere -products * -requires $c -property installationPath)) { throw "component missing: $c" }
}
$info = & "$env:ProgramFiles\dotnet\dotnet.exe" --info   # not piped into Select -First: that stops dotnet, exit code -1
if ($LASTEXITCODE -ne 0) { throw "dotnet --info failed (exit code $LASTEXITCODE)" }
$info | Select-Object -First 3
Write-Host "VS $(& $vswhere -products * -property installationVersion), MSBuild: $msbuild"
Write-Host 'recipe done'
