<#
winvm.ps1 - clean, reproducible Windows test VMs on VirtualBox, for Windows hosts.
The VirtualBox counterpart of ../winvm (QEMU/KVM on Linux). See README.md.

    .\winvm.ps1 help                    commands
    .\winvm.ps1 help COMMAND            details

Options can be written -Name, --name or -name; values follow as the next argument.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo = Split-Path -Parent $Root
. (Join-Path $Root 'config.ps1')
$local = Join-Path $Root 'config.local.ps1'
if (Test-Path $local) { . $local }

$State = Join-Path $Root 'state'
$SshKey = Join-Path $State 'id_ed25519'
$Prefix = 'winvm-'                  # VirtualBox names: winvm-NAME (VMs), winvm-base-IMAGE (images)
$BuildSlot = 99                     # port offset while an image is being built

# Errors are thrown (so cleanup in catch/finally runs) and printed once in main.
function Die([string]$msg) { throw "WINVM: $msg" }
function Info([string]$msg) { Write-Host "==> $msg" }
function Note([string]$msg) { Write-Host "    $msg" }

# --- arguments ----------------------------------------------------------------

# Splits $args into positionals and options: -Image win11, --force, ...
function Parse-Args([object[]]$argv, [string[]]$flags, [string[]]$valued) {
    $o = @{ Pos = @() }
    for ($i = 0; $i -lt $argv.Count; $i++) {
        $a = [string]$argv[$i]
        if ($a -match '^--?([A-Za-z][\w-]*)$') {
            $n = $Matches[1].ToLower()
            if ($flags -contains $n) { $o[$n] = $true }
            elseif ($valued -contains $n) {
                if ($i + 1 -ge $argv.Count) { Die "option -$n needs a value" }
                $i++; $o[$n] = [string]$argv[$i]
            } else { Die "unknown option $a (winvm.ps1 help $script:Command)" }
        } else { $o.Pos += $a }
    }
    $o
}

# --- tools --------------------------------------------------------------------

function Find-Tool([string]$name, [string[]]$candidates) {
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $null
}

$VBoxManage = Find-Tool 'VBoxManage' @(
    $(if ($env:VBOX_MSI_INSTALL_PATH) { Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe' }),
    $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe' }))
$SshExe = Find-Tool 'ssh' @($(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe' }))
$ScpExe = Find-Tool 'scp' @($(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe' }))
$SshKeygen = Find-Tool 'ssh-keygen' @($(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe' }))

function Need-VBox { if (-not $VBoxManage) { Die 'VBoxManage not found: install VirtualBox 7 (https://www.virtualbox.org) or put VBoxManage on PATH' } }
function Need-Ssh {
    if (-not $SshExe -or -not $ScpExe) { Die 'ssh/scp not found: Settings > Apps > Optional features > "OpenSSH Client"' }
}

# Runs VBoxManage; returns its output lines, dies with the output on failure.
function VBox {
    Need-VBox
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $VBoxManage @args 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $eap
    if ($code -ne 0) {
        $shown = ($args | ForEach-Object { $a = "$_"; if ($a.Length -gt 80) { $a.Substring(0, 77) + '...' } else { $a } }) -join ' '
        Die "VBoxManage $shown failed:`n$($out -join "`n")"
    }
    $out
}
function VBoxTry { $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $out = & $VBoxManage @args 2>&1 | ForEach-Object { "$_" }; $ErrorActionPreference = $eap; if ($LASTEXITCODE -eq 0) { $out } }

# showvminfo --machinereadable as a hashtable (key -> value without quotes)
function VmInfo([string]$vm) {
    $h = @{}
    foreach ($l in (VBoxTry showvminfo $vm --machinereadable)) {
        if ($l -match '^"?([^"=]+)"?="?(.*?)"?$') { $h[$Matches[1]] = $Matches[2] }
    }
    $h
}
function Vm-Exists([string]$vm) { [bool](VBoxTry showvminfo $vm --machinereadable) }
function Vm-State([string]$vm) { (VmInfo $vm)['VMState'] }
function Is-Running([string]$vm) { (Vm-State $vm) -in 'running', 'paused', 'starting', 'restoring', 'stopping' }
function Get-Extra([string]$vm, [string]$key) {
    $l = VBoxTry getextradata $vm "winvm/$key"
    if ($l -and $l -match '^Value: (.*)$') { $Matches[1] } else { '' }
}
function Set-Extra([string]$vm, [string]$key, [string]$value) { VBox setextradata $vm "winvm/$key" $value | Out-Null }

function All-Vms {
    foreach ($l in (VBox list vms)) {
        if ($l -match '^"winvm-(?!base-)([^"]+)"') { $Matches[1] }
    }
}

# --- images and VMs -------------------------------------------------------------

function Get-Image([string]$name) {
    if (-not $Config.Images.ContainsKey($name)) { Die "unknown image '$name' (winvm.ps1 images)" }
    $Config.Images[$name]
}
function Base-Vm([string]$image) { "${Prefix}base-$image" }
# Built = the build finished and took the clean snapshot (not just started).
function Is-Built([string]$image) { $b = Base-Vm $image; (Vm-Exists $b) -and (Get-Extra $b 'clean') }
# A VM folder VirtualBox doesn't know any more (interrupted delete or build).
function Remove-Leftover([string]$vm) {
    $dir = Join-Path $Config.VmFolder $vm
    if ((Test-Path $dir) -and -not (Vm-Exists $vm)) { Remove-Item -Recurse -Force $dir }
}
function Vm-Name([string]$name) { "$Prefix$name" }

function Valid-Name([string]$name) { $name -cmatch '^[a-z0-9][a-z0-9-]{0,30}$' }

function Vm-Ports([string]$vm) {
    $slot = [int](Get-Extra $vm 'slot')
    @{ Slot = $slot; Ssh = $Config.SshPort + $slot; Rdp = $Config.RdpPort + $slot }
}
function Free-Slot {
    $used = @(0) + @(All-Vms | ForEach-Object { [int](Get-Extra (Vm-Name $_) 'slot') })
    for ($s = 1; $s -lt 99; $s++) { if ($used -notcontains $s) { return $s } }
    Die 'too many VMs'
}

function Need-Vm([string]$name) {
    if (-not (Valid-Name $name)) { Die "VM names: lowercase letters, digits and -, e.g. 'test2'" }
    $vm = Vm-Name $name
    if (-not (Vm-Exists $vm)) { Die "no VM '$name' ($(if ($name -eq 'default') { 'winvm.ps1 build' } else { "winvm.ps1 new $name" }) creates it; winvm.ps1 list)" }
    $vm
}

# --- SSH ------------------------------------------------------------------------

function Ssh-Opts([string]$vm) {
    New-Item -ItemType Directory -Force $State | Out-Null
    $known = Join-Path $State "known_hosts-$vm"
    @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new',
      '-o', "UserKnownHostsFile=$known", '-o', 'ConnectTimeout=5', '-o', 'LogLevel=ERROR')
}

# The guest command line that runs PowerShell code. Base64 survives every
# quoting layer (Windows PowerShell 5.1 drops inner double quotes when it calls
# ssh.exe; Windows' sshd and the guest's login shell parse it again).
# Write-Host and warnings go to stdout as text: otherwise powershell.exe sends
# them as CLIXML on stderr, and the guest's PowerShell login shell prints them
# a second time.
function Guest-PsCommand([string]$code) {
    $full = "& { $code } 3>&1 6>&1 | ForEach-Object { if (`$_ -is [System.Management.Automation.WarningRecord]) { `"WARNING: `$(`$_.Message)`" } elseif (`$_ -is [System.Management.Automation.InformationRecord]) { `"`$_`" } else { `$_ } }"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc"
}

# Runs PowerShell in the guest. Shows its output and returns the exit code;
# -Capture returns the output lines instead (stderr dropped); -Quiet shows nothing.
function Guest-Ps([string]$vm, [int]$port, [string]$script, [switch]$Quiet, [switch]$Capture) {
    Need-Ssh
    $cmd = Guest-PsCommand "`$ProgressPreference='SilentlyContinue'; `$ErrorActionPreference='Stop'; try { $script } catch { [Console]::Error.WriteLine(`$_.ToString()); exit 1 }"
    $sshArgs = @(Ssh-Opts $vm) + @('-o', 'BatchMode=yes', '-p', $port, "$($Config.User)@127.0.0.1", $cmd)
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($Capture) { return @(& $SshExe @sshArgs 2>$null | ForEach-Object { "$_" }) }
        if ($Quiet) { & $SshExe @sshArgs 2>&1 | Out-Null }
        else { & $SshExe @sshArgs 2>&1 | ForEach-Object { Write-Host "$_" } }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap }
}
function Guest-Read([string]$vm, [int]$port, [string]$file) {
    # @(): a single line would come back as a string, and [-1] would be its last character.
    $l = @(Guest-Ps $vm $port "Get-Content $file -ErrorAction SilentlyContinue" -Capture)
    if ($l) { ([string]$l[-1]).Trim() } else { '' }
}
function Ssh-Up([string]$vm, [int]$port) {
    $opts = Ssh-Opts $vm
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $SshExe @opts -o BatchMode=yes -p $port "$($Config.User)@127.0.0.1" exit 2>$null | Out-Null
    $ok = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $eap
    $ok
}
function Wait-Ssh([string]$vm, [int]$port, [int]$timeoutSec = 300) {
    Need-Ssh
    Info "waiting for SSH ($vm)"
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Ssh-Up $vm $port) { Info 'VM is up'; return }
        if (-not (Is-Running $vm)) { Die "$vm stopped while waiting for it" }
        Start-Sleep 5
    }
    Die "SSH not reachable after $timeoutSec s"
}
function Copy-ToGuest([string]$vm, [int]$port, [string[]]$files, [string]$dest, [switch]$Recurse) {
    $opts = Ssh-Opts $vm
    $r = @(); if ($Recurse) { $r = @('-r') }
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $ScpExe @opts @r -q -o BatchMode=yes -P $port @files "$($Config.User)@127.0.0.1:$dest" 2>&1 | ForEach-Object { "$_" } | Write-Host
    $code = $LASTEXITCODE
    $ErrorActionPreference = $eap
    if ($code -ne 0) { Die "could not copy $($files -join ', ') into the VM" }
}
function Guest-Restart([string]$vm, [int]$port) {
    Guest-Ps $vm $port 'shutdown.exe /r /t 2 /f' -Quiet | Out-Null
    for ($i = 0; $i -lt 60 -and (Ssh-Up $vm $port); $i++) { Start-Sleep 2 }   # until it went down
    Wait-Ssh $vm $port 900
}

# --- lifecycle ------------------------------------------------------------------

function Start-Vm([string]$vm, [switch]$Gui) {
    if (Is-Running $vm) { return }
    VBox startvm $vm --type $(if ($Gui) { 'gui' } else { 'headless' }) | Out-Null
}
function Stop-Vm([string]$vm, [switch]$Force, [int]$timeoutSec = 180) {
    if (-not (Is-Running $vm)) { return }
    if (-not $Force) {
        VBoxTry controlvm $vm acpipowerbutton | Out-Null
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        while ((Get-Date) -lt $deadline -and (Is-Running $vm)) { Start-Sleep 2 }
        if (-not (Is-Running $vm)) { return }
        Write-Host "winvm: $vm did not shut down within $timeoutSec s, forcing"
    }
    VBoxTry controlvm $vm poweroff | Out-Null
    for ($i = 0; $i -lt 60 -and (Is-Running $vm); $i++) { Start-Sleep 1 }
}
# The snapshot 'reset' returns to (extradata winvm/clean = its UUID).
function Take-Clean([string]$vm) {
    $old = Get-Extra $vm 'clean'
    $name = "clean $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    VBox snapshot $vm take $name --description 'winvm: the state reset returns to' | Out-Null
    $uuid = ((VmInfo $vm)['CurrentSnapshotUUID'])
    Set-Extra $vm 'clean' $uuid
    if ($old -and $old -ne $uuid) { VBoxTry snapshot $vm delete $old | Out-Null }   # fails harmlessly if a clone uses it
}

# --- commands -------------------------------------------------------------------

function Cmd-Images {
    '{0,-12} {1,-6} {2,-4} {3}' -f 'IMAGE', 'BUILT', 'VMS', 'DESCRIPTION'
    foreach ($i in ($Config.Images.Keys | Sort-Object)) {
        $built = if (Is-Built $i) { 'yes' } elseif (Vm-Exists (Base-Vm $i)) { 'failed' } else { '-' }
        $n = @(All-Vms | Where-Object { (Get-Extra (Vm-Name $_) 'image') -eq $i }).Count
        $d = $Config.Images[$i].Description + $(if ($i -eq $Config.DefaultImage) { '  (default)' } else { '' })
        '{0,-12} {1,-6} {2,-4} {3}' -f $i, $built, $n, $d
    }
    Note 'build one: winvm.ps1 build -Image NAME'
}

function Cmd-Build([object[]]$argv) {
    $o = Parse-Args $argv @('force', 'gui', 'no-updates') @('image')
    $img = if ($o['image']) { $o['image'] } else { $Config.DefaultImage }
    $c = Get-Image $img
    Need-VBox; Need-Ssh
    $base = Base-Vm $img
    if (-not (Test-Path $c.Iso)) { Die "Windows ISO for '$img' not found: $($c.Iso) (set `$Config.Images.'$img'.Iso in config.local.ps1)" }
    $iso = (Resolve-Path $c.Iso).Path
    $clones = @(All-Vms | Where-Object { (Get-Extra (Vm-Name $_) 'image') -eq $img })
    if ((Is-Built $img) -and -not $o['force']) {
        Die "the $img image exists; 'build -Image $img -Force' rebuilds it and deletes its VMs ($(if ($clones) { $clones -join ', ' } else { 'none' }))"
    }
    foreach ($v in $clones) { Remove-Vm (Vm-Name $v); Info "deleted VM $v" }
    if (Vm-Exists $base) { Remove-Vm $base }   # the old image, or an interrupted build
    Remove-Leftover $base

    # Which image on the ISO is the edition we want.
    $detect = VBox unattended detect "--iso=$iso" --machine-readable
    $d = @{}; foreach ($l in $detect) { if ($l -match '^(\w+)="(.*)"$') { $d[$Matches[1]] = $Matches[2] } }
    $index = $null
    foreach ($k in $d.Keys) {
        if ($k -match '^ImageIndex(\d+)$' -and $d[$k] -like "$($c.Edition) (*") { $index = $Matches[1] }
    }
    if (-not $index) {
        $names = ($d.Keys | Where-Object { $_ -like 'ImageIndex*' } | Sort-Object { [int]($_ -replace '\D') } | ForEach-Object { '  ' + ($d[$_] -replace ' \(.*') }) -join "`n"
        Die "edition '$($c.Edition)' is not on $iso; it has:`n$names"
    }
    $language = if ($c.Language) { $c.Language } else { ($d['OSLanguages'] -split ',')[0] }

    New-Item -ItemType Directory -Force $State, $Config.VmFolder | Out-Null
    if (-not (Test-Path $SshKey)) {
        if (-not $SshKeygen) { Die 'ssh-keygen not found (Windows feature "OpenSSH Client")' }
        # Start-Process passes the empty passphrase ("") the same way on every PowerShell version.
        $kg = Start-Process $SshKeygen -ArgumentList "-q -t ed25519 -N `"`" -C winvm -f `"$SshKey`"" -Wait -NoNewWindow -PassThru
        if ($kg.ExitCode -ne 0 -or -not (Test-Path $SshKey)) { Die 'ssh-keygen failed' }
    }
    $pub = (Get-Content "$SshKey.pub" -Raw).Trim()

    Info "creating the build VM for $($c.Description)"
    VBox createvm --name $base --ostype $d['OSTypeId'] --basefolder $Config.VmFolder --register | Out-Null
    $vmdir = Split-Path -Parent ((VmInfo $base)['CfgFile'])
    $mod = @('modifyvm', $base, '--memory', $Config.RamMB, '--cpus', $Config.Cpus, '--vram', 128,
             '--graphicscontroller', 'vboxsvga', '--nic1', 'nat', '--nictype1', '82540EM',
             '--mouse', 'usbtablet', '--usbohci', 'on', '--rtc-use-utc', 'on', '--audio-enabled', 'off',
             '--clipboard-mode', 'bidirectional', '--ioapic', 'on')
    if ($c.Efi) { $mod += @('--firmware', 'efi', '--tpm-type', '2.0') }
    VBox @mod | Out-Null
    if ($c.Efi) {   # Secure Boot with Microsoft's keys, like a real PC
        VBox modifynvram $base inituefivarstore | Out-Null
        VBox modifynvram $base enrollmssignatures | Out-Null
        VBox modifynvram $base enrollorclpk | Out-Null
        VBox modifynvram $base secureboot --enable | Out-Null
    }
    $disk = Join-Path $vmdir "$base.vdi"
    VBox createmedium disk --filename $disk --size ($Config.DiskGB * 1024) --format VDI | Out-Null
    VBox storagectl $base --name SATA --add sata --controller IntelAhci --portcount 4 | Out-Null
    VBox storageattach $base --storagectl SATA --port 0 --device 0 --type hdd --medium $disk | Out-Null
    $port = $Config.SshPort + $BuildSlot
    VBox modifyvm $base --natpf1 "ssh,tcp,127.0.0.1,$port,,22" | Out-Null

    # After Windows Setup: OpenSSH server with our key; the rest goes over SSH.
    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
try {
  if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    foreach (`$i in 1..10) { try { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null; break } catch { Start-Sleep 30 } }
  }
  New-Item -Force HKLM:\SOFTWARE\OpenSSH | Out-Null
  Set-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value "`$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  `$k = "`$env:ProgramData\ssh\administrators_authorized_keys"
  New-Item -ItemType Directory -Force (Split-Path `$k) | Out-Null
  Set-Content `$k '$pub' -Encoding Ascii
  icacls.exe `$k /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
  Set-Service sshd -StartupType Automatic
  Start-Service sshd
  if (-not (Get-NetFirewallRule -Name winvm-ssh -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name winvm-ssh -DisplayName 'winvm: SSH' -Protocol TCP -LocalPort 22 -Direction Inbound -Action Allow | Out-Null
  }
  'ok' | Set-Content C:\winvm-bootstrap.txt
} catch { "`$_" | Set-Content C:\winvm-bootstrap.txt }
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $computer = ($img -replace '[^A-Za-z0-9-]', '').ToUpper() + '-DEV'
    if ($computer.Length -gt 15) { $computer = $computer.Substring(0, 15) }
    $u = @('unattended', 'install', $base, "--iso=$iso", "--user=$($Config.User)", "--user-password=$($Config.Password)",
           "--admin-password=$($Config.Password)", "--full-user-name=$($Config.User)", '--install-additions',
           "--locale=$($c.Locale)", "--country=$($c.Country)", "--time-zone=$($c.TimeZone)", "--language=$language",
           "--hostname=$($computer.ToLower()).winvm.local", "--image-index=$index",
           "--post-install-command=powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc",
           "--start-vm=$(if ($o['gui']) { 'gui' } else { 'headless' })")
    if ($c.Key) { $u += "--key=$($c.Key)" }
    if ($Config.AdditionsIso) { $u += "--additions-iso=$($Config.AdditionsIso)" }
    if ($script:DryRun) {   # prepares everything (answer file, scripts in the VM folder), starts nothing
        $u = @($u | Where-Object { $_ -notlike '--start-vm=*' }) + @("--auxiliary-base-path=$(Join-Path $vmdir 'unattended-')")
    }
    Info "installing $($c.Edition) (unattended; Windows, then the guest additions, then SSH)"
    VBox @u | Out-Null
    if ($script:DryRun) { Info "dry run: VM $base configured, unattended files in $vmdir"; return }

    Wait-Ssh $base $port 5400
    $guest = 'C:/winvm/'
    Guest-Ps $base $port 'New-Item -ItemType Directory -Force C:\winvm | Out-Null' | Out-Null
    $files = @((Join-Path $Root 'guest\provision.ps1'), (Join-Path $Root 'guest\updates.ps1'), (Join-Path $Repo 'provision\packages.txt'))
    Copy-ToGuest $base $port $files $guest
    Info 'provisioning'
    $dwu = if ($Config.DisableWindowsUpdate) { ' -DisableWindowsUpdate' } else { '' }
    Guest-Ps $base $port "& C:\winvm\provision.ps1 -Packages C:\winvm\packages.txt$dwu" | Out-Null
    $result = Guest-Read $base $port 'C:\winvm\provision-result.txt'
    if ($result -ne 'ok') { Die "provisioning: $result (the VM $base is still running for a look: VirtualBox Manager or ssh -p $port)" }

    if ($Config.Updates -and -not $o['no-updates']) {
        Info 'installing all Windows updates (restarts as needed; 30-90 min)'
        for ($round = 1; ; $round++) {
            if ($round -gt 15) { Die 'still updates pending after 15 rounds' }
            Guest-Ps $base $port '& C:\winvm\updates.ps1' | Out-Null
            $st = Guest-Read $base $port 'C:\winvm\updates-state.txt'
            switch -Wildcard ($st) {
                'done'   { break }
                'more'   { continue }
                'reboot' { Info "restarting (round $round)"; Guest-Restart $base $port; continue }
                default  { Die "Windows Update: $st" }
            }
            if ($st -eq 'done') { break }
        }
    }

    Info 'shutting down and taking the clean snapshot'
    Guest-Ps $base $port 'Remove-Item C:\dumps\* -Force -ErrorAction SilentlyContinue' -Quiet | Out-Null
    Stop-Vm $base
    # Installation media out, so clones don't carry the ISOs.
    $info = VmInfo $base
    foreach ($k in @($info.Keys)) {
        if ($k -match '^(.+)-(\d+)-(\d+)$' -and $info[$k] -like '*.iso') {
            VBoxTry storageattach $base --storagectl $Matches[1] --port $Matches[2] --device $Matches[3] --medium emptydrive | Out-Null
        }
    }
    VBox modifyvm $base --natpf1 delete ssh | Out-Null
    Set-Extra $base 'image' $img
    Set-Extra $base 'built' (Get-Date -Format 'yyyy-MM-dd')
    Take-Clean $base
    $vmName = if ($img -eq $Config.DefaultImage) { 'default' } else { $img }
    if (-not (Vm-Exists (Vm-Name $vmName))) { New-Clone $img $vmName }
    Info "done. '.\winvm.ps1 $(if ($vmName -ne 'default') { "-Name $vmName " })start' boots it, 'reset' returns to this state"
}

function Remove-Vm([string]$vm) {
    if (Is-Running $vm) { Stop-Vm $vm -Force }
    # --delete: the VM's own disks, snapshots, logs and folder. Not --delete-all,
    # which also deletes attached ISOs (the Windows ISO!).
    VBox unregistervm $vm --delete | Out-Null
    Get-ChildItem $State -Filter "known_hosts-$vm" -ErrorAction SilentlyContinue | Remove-Item -Force
}

function New-Clone([string]$img, [string]$name) {
    $base = Base-Vm $img
    if (-not (Is-Built $img)) { Die "the $img image isn't built yet: winvm.ps1 build -Image $img" }
    $vm = Vm-Name $name
    Remove-Leftover $vm
    $clean = Get-Extra $base 'clean'
    $slot = if ($name -eq 'default') { 0 } else { Free-Slot }
    VBox clonevm $base --snapshot $clean --options link --name $vm --basefolder $Config.VmFolder --register | Out-Null
    try {
        Set-Extra $vm 'image' $img
        Set-Extra $vm 'slot' $slot
        $p = Vm-Ports $vm
        foreach ($rule in 'ssh', 'rdp') { VBoxTry modifyvm $vm --natpf1 delete $rule | Out-Null }
        VBox modifyvm $vm --natpf1 "ssh,tcp,127.0.0.1,$($p.Ssh),,22" --natpf1 "rdp,tcp,127.0.0.1,$($p.Rdp),,3389" | Out-Null
        Take-Clean $vm
    } catch { VBoxTry unregistervm $vm --delete | Out-Null; throw }
    Info "created VM '$name' from the $img image (linked clone; ssh $($p.Ssh), rdp $($p.Rdp))"
}

# recipe.env is shell syntax; only simple KEY=value lines are read here.
function Read-RecipeEnv([string]$dir) {
    $h = @{}
    foreach ($l in Get-Content (Join-Path $dir 'recipe.env')) {
        if ($l -match '^\s*([A-Z_]+)=(.*)$') { $h[$Matches[1]] = ($Matches[2] -replace '\s+#.*$' -replace '^["'']|["'']$') }
    }
    $h
}
function Recipe-Dir([string]$r) {
    $d = if (Test-Path (Join-Path $Repo "recipes\$r")) { Join-Path $Repo "recipes\$r" } else { $r }
    if (-not (Test-Path (Join-Path $d 'recipe.env'))) { Die "no recipe '$r' (..\recipes\NAME\recipe.env)" }
    (Resolve-Path $d).Path
}

function Apply-Recipe([string]$vm, [string]$dir) {
    $p = Vm-Ports $vm
    if (-not (Is-Running $vm)) { Start-Vm $vm }
    Wait-Ssh $vm $p.Ssh
    Info "applying recipe $(Split-Path -Leaf $dir)"
    Guest-Ps $vm $p.Ssh 'Remove-Item -Recurse -Force C:\winvm\recipe -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force C:\winvm\recipe | Out-Null' | Out-Null
    Copy-ToGuest $vm $p.Ssh @(Get-ChildItem $dir | ForEach-Object FullName) 'C:/winvm/recipe/' -Recurse
    Copy-ToGuest $vm $p.Ssh @(Join-Path $Repo 'lib\guest\recipe.ps1') 'C:/winvm/recipe-runner.ps1'
    for ($run = 1; $run -le 5; $run++) {
        Guest-Ps $vm $p.Ssh "& C:\winvm\recipe-runner.ps1 -Run $run" | Out-Null
        $rc = Guest-Read $vm $p.Ssh 'C:\winvm\recipe-exit.txt'
        if ($rc -eq '0') { Info 'recipe applied'; return }
        if ($rc -eq '3010') { Info "the recipe asked for a restart (run $run done)"; Guest-Restart $vm $p.Ssh; continue }
        Die "the recipe failed (exit code $rc); the VM is still running for a look"
    }
    Die 'the recipe still asked for a restart after 5 runs'
}

function Cmd-New([object[]]$argv) {
    $o = Parse-Args $argv @() @('image', 'recipe')
    if ($o.Pos.Count -ne 1) { Die 'usage: winvm.ps1 new NAME [-Recipe RECIPE] [-Image IMG]' }
    $name = $o.Pos[0]
    if (-not (Valid-Name $name)) { Die "VM names: lowercase letters, digits and -, e.g. 'test2'" }
    if (Vm-Exists (Vm-Name $name)) { Die "VM '$name' exists already" }
    $dir = $null; $envs = @{}
    if ($o['recipe']) { $dir = Recipe-Dir $o['recipe']; $envs = Read-RecipeEnv $dir }
    $img = if ($o['image']) { $o['image'] } elseif ($envs['IMAGE']) { $envs['IMAGE'] } else { $Config.DefaultImage }
    [void](Get-Image $img)
    New-Clone $img $name
    $vm = Vm-Name $name
    if ($dir) {
        $mod = @()
        if ($envs['VM_RAM']) {
            $mb = if ($envs['VM_RAM'] -match '^(\d+)G$') { [int]$Matches[1] * 1024 } elseif ($envs['VM_RAM'] -match '^(\d+)M?$') { [int]$Matches[1] } else { Die "VM_RAM '$($envs['VM_RAM'])': e.g. 4G" }
            $mod += @('--memory', $mb)
        }
        if ($envs['VM_CPUS']) { $mod += @('--cpus', $envs['VM_CPUS']) }
        if ($mod) { VBox modifyvm $vm @mod | Out-Null; Note "VM settings from the recipe: $($mod -join ' ')" }
        foreach ($k in 'VM_INTERNET', 'USB_DEVICES', 'AUDIO') {
            if ($envs[$k]) { Write-Host "winvm: note: $k from the recipe is not supported with VirtualBox, ignored" }
        }
        Apply-Recipe $vm $dir
        Stop-Vm $vm
        Take-Clean $vm
        Set-Extra $vm 'recipe' (Split-Path -Leaf $dir)
        Info "sealed '$name': reset returns to the set-up state"
    }
    Note "start: winvm.ps1 -Name $name start    reset: winvm.ps1 -Name $name reset    delete: winvm.ps1 destroy $name"
}

function Cmd-List {
    '{0,-14} {1,-12} {2,-9} {3,-6} {4,-6} {5}' -f 'NAME', 'IMAGE', 'STATE', 'SSH', 'RDP', 'RESETS TO'
    foreach ($n in (All-Vms | Sort-Object)) {
        $vm = Vm-Name $n; $p = Vm-Ports $vm
        $r = Get-Extra $vm 'recipe'
        '{0,-14} {1,-12} {2,-9} {3,-6} {4,-6} {5}' -f $n, (Get-Extra $vm 'image'), (Vm-State $vm), $p.Ssh, $p.Rdp, $(if ($r) { "recipe $r" } else { 'clean snapshot' })
    }
}

function Cmd-Status([string]$name) {
    $vm = Need-Vm $name; $p = Vm-Ports $vm; $i = VmInfo $vm
    $img = Get-Extra $vm 'image'
    "vm         : $name ($vm)"
    "image      : $img - $($Config.Images[$img].Description), built $(Get-Extra (Base-Vm $img) 'built')"
    "state      : $($i['VMState'])"
    "hardware   : $($i['cpus']) CPUs, $($i['memory']) MB RAM, firmware $($i['firmware'])"
    "resets to  : $(if (Get-Extra $vm 'recipe') { "recipe $(Get-Extra $vm 'recipe')" } else { 'clean snapshot' })"
    "ports      : ssh $($p.Ssh)  rdp $($p.Rdp)  (127.0.0.1)"
}

function Cmd-Start([string]$name, [object[]]$argv) {
    $o = Parse-Args $argv @('gui', 'wait') @()
    $vm = Need-Vm $name
    if (Is-Running $vm) { Die "'$name' is already running" }
    Start-Vm $vm -Gui:([bool]$o['gui'])
    $p = Vm-Ports $vm
    Info "started '$name'"
    Note "ssh: winvm.ps1 -Name $name ssh    rdp: winvm.ps1 -Name $name rdp    (127.0.0.1:$($p.Ssh) / :$($p.Rdp))"
    if ($o['wait']) { Wait-Ssh $vm $p.Ssh }
}

function Cmd-Stop([string]$name, [object[]]$argv) {
    $o = Parse-Args $argv @('force') @()
    $vm = Need-Vm $name
    if (-not (Is-Running $vm)) { Info "'$name' is not running"; return }
    Stop-Vm $vm -Force:([bool]$o['force'])
    Info 'stopped'
}

function Cmd-Reset([string]$name) {
    $vm = Need-Vm $name
    if (Is-Running $vm) { Stop-Vm $vm -Force }
    VBox snapshot $vm restore (Get-Extra $vm 'clean') | Out-Null
    Info "'$name' reset to its clean state"
}

function Cmd-Seal([string]$name) {
    $vm = Need-Vm $name
    if (Is-Running $vm) { Stop-Vm $vm }
    Take-Clean $vm
    Info "sealed '$name': reset returns to this state from now on"
}

function Cmd-Snapshot([string]$name, [object[]]$argv) {
    $vm = Need-Vm $name
    $action = if ($argv.Count) { [string]$argv[0] } else { 'list' }
    $snap = if ($argv.Count -gt 1) { [string]$argv[1] } else { '' }
    switch ($action) {
        'list' { VBoxTry snapshot $vm list; return }
        'save' { if (-not $snap) { Die 'usage: snapshot save NAME' }; VBox snapshot $vm take $snap | Out-Null; Info "saved '$snap'$(if (Is-Running $vm) { ' (with RAM)' })" }
        'load' {
            if (-not $snap) { Die 'usage: snapshot load NAME' }
            if (Is-Running $vm) { Stop-Vm $vm -Force }
            VBox snapshot $vm restore $snap | Out-Null
            if ((Vm-State $vm) -eq 'saved') { Start-Vm $vm }   # had RAM: continue there
            Info "restored '$snap'"
        }
        'delete' { if (-not $snap) { Die 'usage: snapshot delete NAME' }; VBox snapshot $vm delete $snap | Out-Null }
        default { Die 'usage: winvm.ps1 snapshot save|load|delete|list [NAME]' }
    }
}

function Cmd-Apply([string]$name, [object[]]$argv) {
    $o = Parse-Args $argv @('seal') @()
    if ($o.Pos.Count -ne 1) { Die 'usage: winvm.ps1 [-Name NAME] apply RECIPE [-Seal]' }
    $vm = Need-Vm $name
    $dir = Recipe-Dir $o.Pos[0]
    Apply-Recipe $vm $dir
    if ($o['seal']) {
        Stop-Vm $vm; Take-Clean $vm
        $prev = Get-Extra $vm 'recipe'
        Set-Extra $vm 'recipe' $(if ($prev) { "$prev + $(Split-Path -Leaf $dir)" } else { Split-Path -Leaf $dir })
        Info "sealed '$name'"
    } else { Note "keep it as the clean state: winvm.ps1 -Name $name seal" }
}

function Cmd-Destroy([string]$name, [object[]]$argv) {
    $o = Parse-Args $argv @('yes', 'all') @()
    if ($o['all']) {
        if (-not $o['yes']) { $a = Read-Host "Delete ALL winvm VMs and built images? [y/N]"; if ($a -notmatch '^[yY]') { exit 1 } }
        foreach ($n in All-Vms) { Remove-Vm (Vm-Name $n); Info "deleted VM $n" }
        foreach ($i in $Config.Images.Keys) {
            if (Vm-Exists (Base-Vm $i)) { Remove-Vm (Base-Vm $i); Info "deleted image $i" }
            Remove-Leftover (Base-Vm $i)
        }
        return
    }
    $names = if ($o.Pos.Count) { $o.Pos } else { @($name) }
    $vms = foreach ($n in $names) { Need-Vm $n }
    if (-not $o['yes']) { $a = Read-Host "Delete VM $($names -join ', ') (its changes and snapshots; images stay)? [y/N]"; if ($a -notmatch '^[yY]') { exit 1 } }
    foreach ($vm in $vms) { Remove-Vm $vm; Info "deleted $vm" }
}

function Cmd-Ssh([string]$name, [object[]]$argv) {
    Need-Ssh
    $vm = Need-Vm $name; $p = Vm-Ports $vm
    $opts = Ssh-Opts $vm
    # A command is sent encoded, so its quotes arrive as typed.
    $cmd = @(); if ($argv.Count) { $cmd = @(Guest-PsCommand (($argv | ForEach-Object { "$_" }) -join ' ')) }
    & $SshExe @opts -p $p.Ssh "$($Config.User)@127.0.0.1" @cmd
    exit $LASTEXITCODE
}

function Cmd-Scp([string]$name, [object[]]$argv) {
    Need-Ssh
    $vm = Need-Vm $name; $p = Vm-Ports $vm
    $opts = Ssh-Opts $vm
    $a = foreach ($x in $argv) { if ($x -like 'vm:*') { "$($Config.User)@127.0.0.1:$($x.Substring(3))" } else { $x } }
    & $ScpExe @opts -P $p.Ssh @a
    exit $LASTEXITCODE
}

function Cmd-Rdp([string]$name) {
    $vm = Need-Vm $name; $p = Vm-Ports $vm
    if (-not (Get-Command mstsc.exe -ErrorAction SilentlyContinue)) { Die 'mstsc.exe (Remote Desktop Connection) not found' }
    # Saved credentials, so it signs in without asking (test VM, local ports only).
    & cmdkey.exe "/generic:TERMSRV/127.0.0.1" "/user:$($Config.User)" "/pass:$($Config.Password)" | Out-Null
    Start-Process mstsc.exe "/v:127.0.0.1:$($p.Rdp)"
}

# info / ps / kill / service / apps / events / ports: the same guest helpers as ../winvm
function Cmd-Manage([string]$name, [string]$cmd, [object[]]$argv) {
    $vm = Need-Vm $name; $p = Vm-Ports $vm
    if (-not (Is-Running $vm)) { Die "'$name' is not running (winvm.ps1 -Name $name start -Wait)" }
    function Q([string]$s) { "'" + ($s -replace "'", "''") + "'" }
    $a0 = if ($argv.Count) { [string]$argv[0] } else { '' }
    $a1 = if ($argv.Count -gt 1) { [string]$argv[1] } else { '' }
    $call = switch ($cmd) {
        'info'    { 'Get-WinvmInfo' }
        'ps'      { "Get-WinvmProcess $(Q $a0)" }
        'kill'    { if (-not $a0) { Die 'usage: kill NAME|PID' }; "Stop-WinvmProcess $(Q $a0)" }
        'service' {
            switch ($a0) {
                { $_ -in '', 'list' } { "Get-WinvmService $(Q $a1)" }
                'show' { "Show-WinvmService $(Q $a1)" }
                { $_ -in 'start', 'stop', 'restart', 'enable', 'manual', 'disable' } { "Set-WinvmService $a0 $(Q $a1)" }
                default { Die 'usage: service [list [FILTER] | show|start|stop|restart|enable|manual|disable NAME]' }
            }
        }
        'apps'    { if ($a0 -eq 'uninstall') { "Uninstall-WinvmApp $(Q $a1)" } else { "Get-WinvmApp $(Q $(if ($a0 -ne 'list') { $a0 } else { $a1 }))" } }
        'events'  { "Get-WinvmEvent -Minutes $(if ($a0 -match '^\d+$') { $a0 } else { 60 })" }
        'ports'   { 'Get-WinvmPort' }
    }
    Copy-ToGuest $vm $p.Ssh @(Join-Path $Repo 'lib\guest\hosttools.ps1') 'C:/winvm/hosttools.ps1'
    $code = Guest-Ps $vm $p.Ssh ". C:\winvm\hosttools.ps1; $call"
    exit $code
}

function Cmd-Reboot([string]$name) {
    $vm = Need-Vm $name; $p = Vm-Ports $vm
    if (-not (Is-Running $vm)) { Die "'$name' is not running" }
    Info "restarting Windows in '$name'"
    Guest-Restart $vm $p.Ssh
}

function Show-Help([string]$topic) {
    switch ($topic) {
        'build' { @'
winvm.ps1 build [-Image IMG] [-Force] [-Gui] [-No-Updates]

Installs Windows from the ISO in $Config.Images.IMG.Iso unattended (VirtualBox's
unattended install + guest additions), sets up SSH with a key, provisions it
(RDP, crash dumps, Chocolatey packages from ..\provision\packages.txt), installs
all Windows updates and takes the snapshot every VM of this image starts from.
Then creates the VM "default" (default image) or IMG. Takes 1-2 hours.
  -Force        rebuild: deletes the image and its VMs
  -Gui          show the VM window while installing
  -No-Updates   skip Windows Update
'@ }
        'new' { @'
winvm.ps1 new NAME [-Recipe RECIPE] [-Image IMG]

Creates the VM NAME as a linked clone of a built image (seconds, little disk).
With a recipe from ..\recipes\ (or a path) it boots it, applies the recipe
(packages.txt, setup.ps1, restarts as asked), takes VM_RAM / VM_CPUS from
recipe.env and makes the result the state 'reset' returns to.
Writing recipes: ..\docs\custom-vms.md
'@ }
        'snapshot' { @'
winvm.ps1 [-Name NAME] snapshot save|load|delete|list [SNAPSHOT]

VirtualBox snapshots of the VM: taken while running they include RAM, and
'load' continues exactly there.
'@ }
        default { @'
winvm.ps1 - Windows test VMs on VirtualBox (Windows host)

Usage: .\winvm.ps1 [-Name NAME] <command> [options]     .\winvm.ps1 help COMMAND

Setup
  images                 Windows versions and whether they're built
  build [-Image IMG]     install + provision + update -> clean image (and its VM)
Run a VM
  new NAME [-Recipe R]   new VM (linked clone), optionally set up by a recipe
  start [-Gui] [-Wait]   boot (headless by default)
  stop [-Force]          shut down (ACPI; -Force: power off)
  list / status          all VMs / one VM
Undo
  reset                  back to the clean state (snapshot), in seconds
  seal                   make the current state the clean state
  snapshot save|load|delete|list NAME
  apply RECIPE [-Seal]   run a recipe in an existing VM
  destroy [NAME...] [-All] [-Yes]
Use it
  ssh [COMMAND]          PowerShell in the VM
  scp SRC... DST         vm:PATH = guest path
  rdp                    Remote Desktop (signs in automatically)
Manage what runs in the VM
  info, ps [FILTER], kill NAME|PID, service [list|show|start|stop|restart|...] NAME,
  apps [FILTER] / apps uninstall NAME, events [MINUTES], ports, reboot

Without -Name everything acts on the VM "default". Configuration: config.ps1,
your changes in config.local.ps1. More: README.md
'@ }
    }
}

# --- main -----------------------------------------------------------------------

$argv = @($args)
$vmName = if ($env:WINVM_VM) { $env:WINVM_VM } else { 'default' }
$script:DryRun = $false
while ($argv.Count -gt 0 -and ([string]$argv[0]) -match '^--?(name|n|dry-run)$') {
    if ($Matches[1] -eq 'dry-run') { $script:DryRun = $true; $argv = @($argv | Select-Object -Skip 1); continue }
    if ($argv.Count -lt 2) { Die '-Name needs a VM name' }
    $vmName = [string]$argv[1]
    $argv = @($argv | Select-Object -Skip 2)
}
$script:Command = if ($argv.Count) { ([string]$argv[0]).ToLower() } else { 'help' }
$rest = @($argv | Select-Object -Skip 1)

try {
switch ($script:Command) {
    'help'     { Show-Help $(if ($rest.Count) { [string]$rest[0] } else { '' }) }
    'images'   { Cmd-Images }
    'build'    { Cmd-Build $rest }
    'new'      { Cmd-New $rest }
    'list'     { Cmd-List }
    'status'   { Cmd-Status $vmName }
    'start'    { Cmd-Start $vmName $rest }
    'stop'     { Cmd-Stop $vmName $rest }
    'reset'    { Cmd-Reset $vmName }
    'seal'     { Cmd-Seal $vmName }
    'snapshot' { Cmd-Snapshot $vmName $rest }
    'apply'    { Cmd-Apply $vmName $rest }
    'destroy'  { Cmd-Destroy $vmName $rest }
    'ssh'      { Cmd-Ssh $vmName $rest }
    'scp'      { Cmd-Scp $vmName $rest }
    'rdp'      { Cmd-Rdp $vmName }
    'reboot'   { Cmd-Reboot $vmName }
    { $_ -in 'info', 'ps', 'kill', 'service', 'apps', 'events', 'ports' } { Cmd-Manage $vmName $script:Command $rest }
    default    { Show-Help ''; Die "unknown command '$script:Command'" }
}
} catch {
    $m = $_.Exception.Message
    if ($m -like 'WINVM: *') { [Console]::Error.WriteLine("winvm: $($m.Substring(7))") }
    else { [Console]::Error.WriteLine("winvm: unexpected error: $m`n$($_.ScriptStackTrace)") }
    exit 1
}
