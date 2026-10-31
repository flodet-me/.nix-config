# Installs all Windows updates at the end of `winvm build` (BUILD_UPDATES=1), so
# the base image is fully patched. Runs as SYSTEM at every boot (task
# winvm-updates, registered by setup.ps1), rebooting until nothing is left;
# then cleans up and finishes the build. Feature upgrades (e.g. Windows 10 ->
# 11) are left out: the image stays the Windows version it was built from.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dst = 'C:\winvm'
. "$dst\settings.ps1"
. "$dst\common.ps1"

$maxBoots = 20                      # safety net; Windows also restarts on its own while servicing
$bootFile = "$dst\update-boots.txt"
$failFile = "$dst\update-failures.txt"   # "UpdateID<TAB>title" per failed install
$boot = 1 + [int](Get-Content $bootFile -ErrorAction SilentlyContinue)
Set-Content $bootFile $boot

function Test-RebootPending {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

function Get-Failures { @(Get-Content $failFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Split("`t")[0] }) }

Step "Windows Update (boot $boot)" {
    if ($boot -gt $maxBoots) { throw "updates still pending after $maxBoots reboots" }
    if (Test-RebootPending) { Log '  a restart is still pending'; Restart-Guest }
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'winvm'
    while ($true) {
        $found = Retry 20 { $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0") }
        $failures = Get-Failures
        $todo = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $found.Updates) {
            if ($u.Categories | Where-Object Name -eq 'Upgrades') { continue }
            $id = $u.Identity.UpdateID
            if (@($failures | Where-Object { $_ -eq $id }).Count -ge 2) { continue }   # gave up on it
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$todo.Add($u)
        }
        if ($todo.Count -eq 0) { break }
        for ($i = 0; $i -lt $todo.Count; $i++) { Log "  $($todo.Item($i).Title)" }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $todo
        Retry 3 {
            $r = $downloader.Download()
            if ($r.ResultCode -notin 2, 3) { throw ('download failed (result {0}, 0x{1:X8})' -f $r.ResultCode, $r.HResult) }
        }
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $todo
        $r = $installer.Install()
        for ($i = 0; $i -lt $todo.Count; $i++) {
            $res = $r.GetUpdateResult($i)
            if ($res.ResultCode -notin 2, 3) {
                $u = $todo.Item($i)
                Add-Content $failFile "$($u.Identity.UpdateID)`t$($u.Title)"
                Log ('  install failed (0x{0:X8}): {1}' -f $res.HResult, $u.Title)
            }
        }
        if ($r.RebootRequired -or (Test-RebootPending)) { Log '  restarting to finish installing'; Restart-Guest }
    }
}

# Done (or given up): the task must not survive into the base image.
Unregister-ScheduledTask winvm-updates -Confirm:$false -ErrorAction SilentlyContinue

Get-Content $failFile -ErrorAction SilentlyContinue | Group-Object { $_.Split("`t")[0] } |
    Where-Object Count -ge 2 | ForEach-Object { Log "skipped update (failed twice): $($_.Group[0].Split("`t")[1])" }

Step 'Clean up after updates' {
    # Superseded components out of WinSxS: smaller base image (installed updates
    # can't be uninstalled any more, which a clean base doesn't need).
    & Dism.exe /Online /Quiet /NoRestart /Cleanup-Image /StartComponentCleanup /ResetBase
    if ($LASTEXITCODE -notin 0, 3010) { throw "DISM component cleanup: exit code $LASTEXITCODE" }
    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Remove-Item C:\Windows\SoftwareDistribution\Download\* -Recurse -Force -ErrorAction SilentlyContinue
    Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue   # free blocks back to the qcow2
}

Complete-Provisioning
