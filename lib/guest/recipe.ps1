# Applies a recipe inside the VM (copied to C:\winvm\recipe by `winvm new/apply`):
# packages.txt via Chocolatey, then setup.ps1. Runs elevated over SSH as the
# VM user. Exit code 3010 from setup.ps1 = restart the VM and run it again.
# The result goes to C:\winvm\recipe-exit.txt: Windows' SSH server only reports
# 0 or 1 as exit status.
param([int]$Run = 1)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = 'C:\winvm\recipe'
$exitFile = 'C:\winvm\recipe-exit.txt'
Set-Content $exitFile 1      # until we know better

if ($Run -eq 1 -and (Test-Path "$dir\packages.txt")) {
    $packages = Get-Content "$dir\packages.txt" | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ }
    if ($packages -and -not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host 'ERROR: packages.txt needs Chocolatey, which offline-built images lack'; exit 1
    }
    foreach ($p in $packages) {
        Write-Host "==> choco install $p"
        $ok = $false
        foreach ($try in 1..3) {   # network hiccups
            choco install $p -y --no-progress --limit-output
            if ($LASTEXITCODE -in 0, 1641, 3010) { $ok = $true; break }
            Write-Host "    exit code $LASTEXITCODE, retrying in 15 s"
            Start-Sleep 15
        }
        if (-not $ok) { Write-Host "ERROR: choco install $p failed"; exit 1 }
    }
}

if (Test-Path "$dir\setup.ps1") {
    Write-Host "==> setup.ps1 (run $Run)"
    $env:WINVM_RECIPE_RUN = $Run
    # Own process: a clean exit code (0, 3010 or 1 for an error) and the PATH
    # that packages just changed.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    Set-Location $dir
    # Its errors (stderr) as plain lines: Windows PowerShell would turn them
    # into a terminating error of this script and hide the message.
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$dir\setup.ps1" 2>&1 | ForEach-Object { "$_" }
    Set-Content $exitFile $LASTEXITCODE
    exit
}
Set-Content $exitFile 0
