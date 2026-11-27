# One Windows Update round (all software updates except feature upgrades), run as SYSTEM
# by setup.ps1 through a scheduled task: the Windows Update API doesn't work reliably in
# an SSH session. Result for setup.ps1 in C:\winvm\wu-result.txt, details in C:\winvm\wu.log.
$ErrorActionPreference = 'Stop'
$log = 'C:\winvm\wu.log'
$result = 'C:\winvm\wu-result.txt'
try {
    Add-Content $log "round start $(Get-Date)"
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'winvm-recipe'
    $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software' and BrowseOnly=0")
    $todo = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
        if ($u.Categories | Where-Object Name -eq 'Upgrades') { continue }   # stay on this Windows version
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$todo.Add($u)
        Add-Content $log "  $($u.Title)"
    }
    if ($todo.Count -eq 0) { Add-Content $log '  nothing to install'; Set-Content $result 'installed=0 reboot=False'; return }
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $todo
    $r = $downloader.Download()
    if ($r.ResultCode -notin 2, 3) { throw ('download failed (result {0}, 0x{1:X8})' -f $r.ResultCode, $r.HResult) }
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $todo
    $r = $installer.Install()
    $ok = 0
    for ($i = 0; $i -lt $todo.Count; $i++) {
        $res = $r.GetUpdateResult($i)
        if ($res.ResultCode -in 2, 3) { $ok++ } else { Add-Content $log ('  install failed (0x{0:X8}): {1}' -f $res.HResult, $todo.Item($i).Title) }
    }
    Add-Content $log "  installed $ok of $($todo.Count), reboot required: $($r.RebootRequired)"
    Set-Content $result "installed=$ok reboot=$($r.RebootRequired)"
} catch {
    Add-Content $log "  error: $_"
    Set-Content $result "error=$_"
}
