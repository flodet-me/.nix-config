# Build box for classic UWP apps (.NET Native) and native C++ libraries (UWP app CRT and
# desktop) for x86, x64 and ARM64, with the Visual Studio 2026 Build Tools. msbuild then
# runs over SSH:
#   & "C:\BuildTools2026\MSBuild\Current\Bin\MSBuild.exe" App.sln /restore /p:Configuration=Release /p:Platform=x64
# Developer Mode lets you register the built packages for testing.
# VS 2026 still builds classic UWP / .NET Native; it has no ARM32 C++ tools and no
# Windows 10 SDK any more (Windows 11 SDK 26100 builds for Windows 10 1809+ too).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\BuildTools2026'   # own folder: VMs set up with the older VS 2022 version keep C:\BuildTools

# Developer Mode: register loose-file UWP builds and unsigned test packages.
$unlock = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
New-Item -Force $unlock | Out-Null
Set-ItemProperty $unlock -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord
Set-ItemProperty $unlock -Name AllowAllTrustedApps -Value 1 -Type DWord
Write-Host 'Developer Mode on'

# Component IDs: the VS 2026 channel manifest (aka.ms/vs/18/stable/channel), checked 2026-11-18.
$components = @(
    'Microsoft.VisualStudio.Workload.UniversalBuildTools'      # .NET Native + UWP build tools, .NET SDK
    'Microsoft.VisualStudio.ComponentGroup.UWP.VC.BuildTools'  # C++ UWP (app CRT), x86/x64 + ARM64
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'        # C++ desktop x86/x64
    'Microsoft.VisualStudio.Component.VC.Tools.ARM64'          # C++ desktop ARM64
    'Microsoft.VisualStudio.Component.VC.CMake.Project'
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
)
if (-not (Test-Path "$root\MSBuild\Current\Bin\MSBuild.exe")) {
    $exe = "$env:TEMP\vs_buildtools_2026.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    (New-Object Net.WebClient).DownloadFile('https://aka.ms/vs/18/stable/vs_buildtools.exe', $exe)
    $vsArgs = @('--quiet', '--wait', '--norestart', '--nocache', '--installPath', $root) + ($components | ForEach-Object { '--add', $_ })
    Write-Host 'installing VS 2026 Build Tools (UWP, C++ UWP + desktop x86/x64/ARM64, CMake, SDK 26100); takes a while'
    $p = Start-Process $exe $vsArgs -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "vs_buildtools exit code $($p.ExitCode); logs: $env:TEMP\dd_*.log" }
}
$msbuild = "$root\MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path $msbuild)) { throw "MSBuild missing: $msbuild" }
if (-not (Test-Path "${env:ProgramFiles(x86)}\Windows Kits\10\Platforms\UAP\10.0.26100.0")) { throw 'Windows SDK 10.0.26100 missing' }
Write-Host "MSBuild: $msbuild"
Write-Host 'recipe done'
