# One round of Windows Update for winvm.ps1 build. Started over SSH, it runs
# the actual work as SYSTEM in a scheduled task (Windows Update refuses to
# download from remote sessions) and shows its log until it's done.
# Result in C:\winvm\updates-state.txt: done | reboot | error: ...
param([switch]$Worker)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$state = 'C:\winvm\updates-state.txt'
$log = 'C:\winvm\updates.log'
$failFile = 'C:\winvm\updates-failed.txt'   # "UpdateID<TAB>title" per failed install

if (-not $Worker) {
    Set-Content $state 'running'
    $start = (Get-Content $log -ErrorAction SilentlyContinue).Count
    $action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Worker"
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask winvm-updates -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask winvm-updates
    $shown = $start
    do {
        Start-Sleep 5
        $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
        if ($lines.Count -gt $shown) { $lines[$shown..($lines.Count - 1)] | ForEach-Object { Write-Host $_ }; $shown = $lines.Count }
    } while ((Get-Content $state) -eq 'running')
    Unregister-ScheduledTask winvm-updates -Confirm:$false
    Write-Host "updates: $(Get-Content $state)"
    return
}

function Log([string]$m) { Add-Content $log "  $(Get-Date -Format HH:mm:ss) $m" }
try {
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    if ($pending) { Log 'a restart is pending'; Set-Content $state 'reboot'; return }
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'winvm'
    $found = $null
    foreach ($i in 1..10) {
        try { $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0"); break }
        catch { Log "search failed, retrying: $_"; Start-Sleep 30; Clear-DnsClientCache -ErrorAction SilentlyContinue }
    }
    if (-not $found) { throw 'Windows Update search kept failing' }
    $failures = @(Get-Content $failFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Split("`t")[0] })
    $todo = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
        if ($u.Categories | Where-Object Name -eq 'Upgrades') { continue }    # no feature upgrades
        if (@($failures | Where-Object { $_ -eq $u.Identity.UpdateID }).Count -ge 2) { continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$todo.Add($u)
    }
    if ($todo.Count -eq 0) {
        Log 'no more updates; cleaning up the component store (takes a while)'
        & Dism.exe /Online /Quiet /NoRestart /Cleanup-Image /StartComponentCleanup /ResetBase
        Get-Content $failFile -ErrorAction SilentlyContinue | Group-Object { $_.Split("`t")[0] } | Where-Object Count -ge 2 |
            ForEach-Object { Log "skipped update (failed twice): $($_.Group[0].Split("`t")[1])" }
        Set-Content $state 'done'
        return
    }
    for ($i = 0; $i -lt $todo.Count; $i++) { Log $todo.Item($i).Title }
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $todo
    $r = $downloader.Download()
    if ($r.ResultCode -notin 2, 3) { throw ('download failed (result {0}, 0x{1:X8})' -f $r.ResultCode, $r.HResult) }
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $todo
    $r = $installer.Install()
    for ($i = 0; $i -lt $todo.Count; $i++) {
        $res = $r.GetUpdateResult($i)
        if ($res.ResultCode -notin 2, 3) {
            $u = $todo.Item($i)
            Add-Content $failFile "$($u.Identity.UpdateID)`t$($u.Title)"
            Log ('install failed (0x{0:X8}): {1}' -f $res.HResult, $u.Title)
        }
    }
    # Another round decides whether more is left; a restart first if needed.
    Set-Content $state $(if ($r.RebootRequired) { 'reboot' } else { 'more' })
} catch {
    Log "ERROR: $_"
    Set-Content $state "error: $_"
}
