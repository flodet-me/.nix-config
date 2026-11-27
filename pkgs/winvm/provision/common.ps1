# Shared by setup.ps1 and update.ps1 (dot-sourced): logging to C:\winvm\provision.log
# and COM1 (the host tails it during `winvm build`), steps, retries, final report.

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

# Network hiccups (DNS not up yet after first logon, a host blip) shouldn't
# fail the whole build.
function Retry([int]$tries, [scriptblock]$body) {
    for ($i = 1; ; $i++) {
        try { return & $body }
        catch {
            if ($i -ge $tries) { throw }
            Log "  attempt $i failed, retrying in 15 s: $_"
            Start-Sleep 15
            # Windows caches failed lookups for minutes; a retry must ask again.
            Clear-DnsClientCache -ErrorAction SilentlyContinue
        }
    }
}

function Restart-Guest {
    if ($serial) { $serial.Close() }
    shutdown.exe /r /t 5 /f
    exit
}

# Last thing every build does: report the license and the result, power off.
function Complete-Provisioning {
    # Evaluation editions stop working after 90-180 days; the host records the date.
    $lic = Get-CimInstance SoftwareLicensingProduct -ErrorAction SilentlyContinue `
        -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
        Select-Object -First 1
    if ($lic.Name -match 'Eval') { Log "EVALUATION-MINUTES-LEFT: $($lic.GracePeriodRemaining)" }

    # Programs that crashed while installing (seen: pwsh, svchost) left dumps; a
    # clean image starts with an empty C:\dumps so every dump in it is yours.
    Remove-Item C:\dumps\* -Force -ErrorAction SilentlyContinue

    if ($script:failed.Count -eq 0) { Log 'PROVISION-OK' }
    else { Log "PROVISION-FAILED: $($script:failed -join ', ')" }
    if ($serial) { $serial.Close() }
    shutdown.exe /s /t 5 /f
    exit
}
