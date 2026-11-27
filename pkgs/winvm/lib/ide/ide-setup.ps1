# Entry point for the Linux host: `winvm vscode setup` and `winvm rider setup`
# run this with pwsh. The JSON and project helpers live in windows-host/winvm.ps1
# (the Windows host loads lib/ide/vscode.ps1 and rider.ps1 itself): only their
# function definitions are loaded here.
param(
    [ValidateSet('vscode', 'rider')][string]$Ide = 'vscode',
    [Parameter(Mandatory)][string]$Solution, [string]$Vm = 'default', [switch]$Remove, [string]$Project = '',
    [string]$SshExe = 'ssh', [string]$SshArgsJson = '[]', [Parameter(Mandatory)][string]$Targets   # JSON: pwsh -File can't take a list
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'vscode.ps1')
. (Join-Path $PSScriptRoot 'rider.ps1')
$src = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'windows-host', 'winvm.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $src), [ref]$null, [ref]$null)
$want = 'Solution-Projects', 'Project-Prop', 'Project-Kind', 'Write-Like', 'Read-Bytes', 'Text-Newline', 'Json-SkipWs',
        'Json-SkipString', 'Json-SkipValue', 'Json-Members', 'Json-Quote', 'Json-InsertMember', 'Json-RemoveMember'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($want -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
}
function Info([string]$m) { Write-Host "==> $m" }
function Note([string]$m) { Write-Host "    $m" }
function Die([string]$m) { throw $m }
$only = @(if ($Project) { $Project -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
# Linux: Windows desktop apps build with EnableWindowsTargeting; -r win-x64 gives APP.exe
$buildArgs = @('-r', 'win-x64', '--self-contained', 'false', '-p:EnableWindowsTargeting=true',
               "-p:CustomAfterMicrosoftCommonTargets=$Targets", '-p:WinvmDeploy=true', '-p:WinvmProfile=')
$extra = @{ Run = '-p:WinvmDeployArgs=--run'; Service = '-p:WinvmDeployArgs=--service'; RunWait = '-p:WinvmDeployArgs=--run --wait'; ServiceWait = '-p:WinvmDeployArgs=--service --wait' }
$sshArgs = @($SshArgsJson | ConvertFrom-Json)
try {
    # VS Code: vsdbg matching the C# extension, source paths for it (Winvm.targets)
    if ($Ide -eq 'vscode') { Invoke-VsCodeSetup $Solution $Vm ([bool]$Remove) $only $SshExe $sshArgs ($buildArgs + '-p:WinvmVsdbg=true') $extra }
    else { Invoke-RiderSetup $Solution $Vm ([bool]$Remove) $only $buildArgs $extra }
}
catch { [Console]::Error.WriteLine("winvm: $($_.Exception.Message)"); exit 1 }
