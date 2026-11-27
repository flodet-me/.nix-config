# Puts the vsdbg build a VS Code C# extension expects into C:\vsdbg: run by
# `winvm vscode setup` and before each VS Code deployment, with the download of
# the extension's own Windows debugger (its package.json, runtimeDependencies
# "Debugger", win32 x86_64). vsdbg and the extension must match: an older vsdbg
# rejects the newer extension's breakpoints ("Incorrect breakpoint request
# format"); Microsoft's GetVsDbg script (the recipe's fallback) lags behind.
# Does nothing when C:\vsdbg came from that URL already.
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Sha256
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = 'C:\vsdbg'
$marker = Join-Path $dir 'winvm-source.txt'
if ((Test-Path "$dir\vsdbg.exe") -and (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $Url)) { return }

$zip = Join-Path $env:TEMP 'winvm-vsdbg.zip'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
(New-Object Net.WebClient).DownloadFile($Url, $zip)
$got = (Get-FileHash $zip -Algorithm SHA256).Hash
if ($got -ne $Sha256.ToUpperInvariant()) { Remove-Item $zip -Force; throw "vsdbg download: SHA-256 $got, expected $Sha256" }

# A debug session still running holds the files.
Get-Process vsdbg, vsdbg-ui -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$new = "$dir.new"
if (Test-Path $new) { Remove-Item -Recurse -Force $new }
Expand-Archive $zip $new
Remove-Item $zip -Force
if (-not (Test-Path "$new\vsdbg.exe")) { throw 'vsdbg download: no vsdbg.exe in the archive' }
for ($i = 1; Test-Path $dir; $i++) {
    try { Remove-Item -Recurse -Force $dir } catch { if ($i -ge 10) { throw }; Start-Sleep 1 }
}
Rename-Item $new $dir
Set-Content $marker $Url -Encoding Ascii
Write-Output "vsdbg $((Get-Item "$dir\vsdbg.exe").VersionInfo.ProductVersion) installed in $dir (matching the VS Code C# extension)"
