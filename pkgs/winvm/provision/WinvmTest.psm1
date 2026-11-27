# WinvmTest: helpers to check and exercise Windows handlers from a test VM.
# Installed for all users (Import-Module WinvmTest happens automatically).
#
#   Get-FileHandler .pdf, .txt      which app opens a file type (effective, incl. user choice)
#   Get-UrlHandler https, mailto    which app handles a URL scheme; -All lists every scheme
#   Invoke-Handler <file|url>       open it like a double-click / link click and
#                                   report which processes it started
#   Start-Interactive <exe> [args]  run something on the user's desktop (also from SSH)
#   Invoke-Interactive { ... }      run a script block on the desktop, get its output back
#   Get-Window -Process notepad     windows with HWND, class, process, style, position;
#                                   -Children for controls, -All for hidden windows
#   Get-Crash                       recent crash dumps (C:\dumps) and crash events
#
# From the host: winvm ssh "Invoke-Handler https://example.com"

Add-Type -Namespace WinvmTest -Name Shlwapi -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern uint AssocQueryString(uint flags, uint str, string assoc, string extra,
                                           System.Text.StringBuilder outBuf, ref uint outLen);
'@

$ASSOCF_NOTRUNCATE = 0x20
$ASSOCF_IS_PROTOCOL = 0x1000

function Get-Assoc([string]$assoc, [uint32]$str, [uint32]$flags) {
    $len = [uint32]2048
    $sb = New-Object System.Text.StringBuilder ([int]$len)
    # [NullString]::Value: a plain $null would be passed as "" (= verb "") and every lookup fails.
    $hr = [WinvmTest.Shlwapi]::AssocQueryString($flags -bor $ASSOCF_NOTRUNCATE, $str, $assoc, [NullString]::Value, $sb, [ref]$len)
    if ($hr -eq 0) { $sb.ToString() } else { $null }
}

function Get-UserSid {
    # The interactive (desktop) user, also when called from an SSH session.
    $owner = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 |
        Invoke-CimMethod -MethodName GetOwnerSid
    if ($owner) { $owner.Sid } else { ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value }
}

function Get-FileHandler {
    <# .SYNOPSIS Effective handler for file extensions (what a double-click would run). #>
    param([Parameter(ValueFromPipeline)][string[]]$Extension =
          @('.txt', '.log', '.html', '.htm', '.pdf', '.xml', '.json', '.jpg', '.png', '.gif', '.svg',
            '.mp3', '.mp4', '.zip', '.7z', '.msi', '.ps1', '.bat', '.cmd', '.vbs', '.js', '.reg', '.url', '.lnk'))
    process {
        $sid = Get-UserSid
        foreach ($ext in $Extension) {
            if (-not $ext.StartsWith('.')) { $ext = ".$ext" }
            $uc = Get-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$ext\UserChoice" -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Extension  = $ext
                ProgId     = Get-Assoc $ext 20 0      # ASSOCSTR_PROGID
                UserChoice = $uc.ProgId
                App        = Get-Assoc $ext 4 0       # ASSOCSTR_FRIENDLYAPPNAME
                Executable = Get-Assoc $ext 2 0       # ASSOCSTR_EXECUTABLE
                Command    = Get-Assoc $ext 1 0       # ASSOCSTR_COMMAND
            }
        }
    }
}

function Get-UrlHandler {
    <# .SYNOPSIS Handler for URL schemes (http, mailto, ms-settings, your-app:...). -All lists every registered scheme. #>
    param([Parameter(ValueFromPipeline)][string[]]$Scheme =
          @('http', 'https', 'ftp', 'mailto', 'tel', 'ms-settings', 'microsoft-edge', 'ms-windows-store', 'search-ms'),
          [switch]$All)
    begin {
        if ($All) {
            New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null
            $Scheme = Get-ChildItem HKCR:\ -ErrorAction SilentlyContinue |
                Where-Object { $_.GetValueNames() -contains 'URL Protocol' } | ForEach-Object { $_.PSChildName }
        }
        $sid = Get-UserSid
    }
    process {
        foreach ($s in $Scheme) {
            $s = $s.TrimEnd(':')
            $uc = Get-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$s\UserChoice" -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Scheme     = $s
                UserChoice = $uc.ProgId
                App        = Get-Assoc $s 4 $ASSOCF_IS_PROTOCOL
                Executable = Get-Assoc $s 2 $ASSOCF_IS_PROTOCOL
                Command    = Get-Assoc $s 1 $ASSOCF_IS_PROTOCOL
            }
        }
    }
}

# Runs a PowerShell command line as the desktop user via a one-shot scheduled
# task (SSH sessions live in session 0 and can't reach the desktop).
function Invoke-AsDesktopUser([string]$command, [int]$timeoutSec = 30) {
    $user = (Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 |
             Invoke-CimMethod -MethodName GetOwner)
    if (-not $user.User) { throw 'nobody is logged on to the desktop' }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $name = "winvm-interactive-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $enc"
    $principal = New-ScheduledTaskPrincipal -UserId "$($user.Domain)\$($user.User)" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask $name -Action $action -Principal $principal | Out-Null
    try {
        Start-ScheduledTask $name
        for ($i = 0; $i -lt 50 -and (Get-ScheduledTask $name).State -ne 'Running'; $i++) { Start-Sleep -Milliseconds 100 }
        for ($i = 0; $i -lt $timeoutSec * 10 -and (Get-ScheduledTask $name).State -eq 'Running'; $i++) { Start-Sleep -Milliseconds 100 }
        $info = Get-ScheduledTaskInfo $name
        if ($info.LastTaskResult -ne 0) { throw ("desktop task failed (result 0x{0:X})" -f $info.LastTaskResult) }
    } finally {
        Unregister-ScheduledTask $name -Confirm:$false
    }
}

function Start-Interactive {
    <# .SYNOPSIS Start a program, file or URL on the logged-on user's desktop (also from SSH). #>
    param([Parameter(Mandatory)][string]$FilePath, [string]$ArgumentList)
    if ((Get-Process -Id $PID).SessionId -ne 0) {
        if ($ArgumentList) { Start-Process $FilePath -ArgumentList $ArgumentList } else { Start-Process $FilePath }
        return
    }
    # Start-Process inside the task gives the same semantics as a shell open (verbs, handlers, URLs).
    Invoke-AsDesktopUser ("Start-Process '$($FilePath -replace "'", "''")'" +
        $(if ($ArgumentList) { " -ArgumentList '$($ArgumentList -replace "'", "''")'" }))
}

function Invoke-Interactive {
    <#
    .SYNOPSIS Run a script block in the desktop user's session and return its output (also from SSH).
    .EXAMPLE Invoke-Interactive { Get-Clipboard }
    #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [int]$TimeoutSec = 60)
    if ((Get-Process -Id $PID).SessionId -ne 0) { return & $ScriptBlock }
    $out = Join-Path $env:ProgramData "winvm-interactive-$([guid]::NewGuid().ToString('N')).xml"
    try {
        Invoke-AsDesktopUser "Import-Module WinvmTest; & { $ScriptBlock } | Export-Clixml -Depth 3 -LiteralPath '$out'" $TimeoutSec
        if (Test-Path $out) { Import-Clixml $out }
    } finally { Remove-Item $out -ErrorAction SilentlyContinue }
}

Add-Type -Namespace WinvmTest -Name User32 -UsingNamespace System.Text, System.Collections.Generic -MemberDefinition @'
public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder sb, int max);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder sb, int max);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
[DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hwnd);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
public static List<IntPtr> TopLevel() { var l = new List<IntPtr>(); EnumWindows((h, p) => { l.Add(h); return true; }, IntPtr.Zero); return l; }
public static List<IntPtr> Children(IntPtr parent) { var l = new List<IntPtr>(); EnumChildWindows(parent, (h, p) => { l.Add(h); return true; }, IntPtr.Zero); return l; }
'@

function Get-Window {
    <#
    .SYNOPSIS Windows on the desktop with their handle (HWND), class, owning process and position.
    .DESCRIPTION Visible top-level windows by default; -All adds hidden ones, -Children adds child
    windows (controls). Works from SSH too (queries the desktop session).
    .EXAMPLE Get-Window -Process notepad
    .EXAMPLE Get-Window -Title '*Settings*' -Children | Format-Table
    #>
    param([string]$Title = '*', [string]$Process, [int]$ProcessId, [switch]$All, [switch]$Children)
    if ((Get-Process -Id $PID).SessionId -eq 0) {
        $p = @{ Title = $Title; All = $All; Children = $Children }
        if ($Process) { $p.Process = $Process }
        if ($ProcessId) { $p.ProcessId = $ProcessId }
        $argList = ($p.GetEnumerator() | ForEach-Object {
            if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } }
            else { "-$($_.Key) '$($_.Value -replace "'", "''")'" } }) -join ' '
        return Invoke-Interactive ([scriptblock]::Create("Get-Window $argList"))
    }
    $procs = @{}
    Get-Process | ForEach-Object { $procs[[uint32]$_.Id] = $_.ProcessName }
    $describe = {
        param($h, $parent)
        $sb = New-Object Text.StringBuilder 512
        [void][WinvmTest.User32]::GetWindowText($h, $sb, 512); $text = $sb.ToString()
        [void]$sb.Clear(); [void][WinvmTest.User32]::GetClassName($h, $sb, 512); $class = $sb.ToString()
        $wpid = [uint32]0; $tid = [WinvmTest.User32]::GetWindowThreadProcessId($h, [ref]$wpid)
        $r = New-Object WinvmTest.User32+RECT; [void][WinvmTest.User32]::GetWindowRect($h, [ref]$r)
        [pscustomobject]@{
            Handle      = '0x{0:X}' -f $h.ToInt64()
            Title       = $text
            Class       = $class
            Process     = $procs[$wpid]
            ProcessId   = $wpid
            ThreadId    = $tid
            Visible     = [WinvmTest.User32]::IsWindowVisible($h)
            Parent      = if ($parent) { '0x{0:X}' -f $parent.ToInt64() } else { $null }
            Style       = '0x{0:X8}' -f [WinvmTest.User32]::GetWindowLong($h, -16)
            Rect        = "$($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
        }
    }
    foreach ($h in [WinvmTest.User32]::TopLevel()) {
        $w = & $describe $h $null
        if (-not $All -and -not $w.Visible) { continue }
        if ($w.Title -notlike $Title) { continue }
        if ($Process -and $w.Process -ne ($Process -replace '\.exe$', '')) { continue }
        if ($ProcessId -and $w.ProcessId -ne $ProcessId) { continue }
        $w
        if ($Children) {
            foreach ($c in [WinvmTest.User32]::Children($h)) {
                $cw = & $describe $c ([WinvmTest.User32]::GetParent($c))
                if ($All -or $cw.Visible) { $cw }
            }
        }
    }
}

function Invoke-Handler {
    <#
    .SYNOPSIS Open a file or URL the way the shell does and report the processes it started.
    .EXAMPLE Invoke-Handler https://example.com
    .EXAMPLE Invoke-Handler C:\test\doc.pdf -Expect AcroRd32.exe
    #>
    param([Parameter(Mandatory)][string]$Target, [int]$Seconds = 5, [string]$Expect)
    $before = @{}
    Get-CimInstance Win32_Process | ForEach-Object { $before[$_.ProcessId] = $true }
    Start-Interactive $Target
    Start-Sleep -Seconds $Seconds
    $new = Get-CimInstance Win32_Process | Where-Object { -not $before.ContainsKey($_.ProcessId) -and
        $_.Name -notin 'conhost.exe', 'WmiPrvSE.exe', 'taskhostw.exe', 'svchost.exe', 'backgroundTaskHost.exe' -and
        -not ($_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*-EncodedCommand*') }
    $new | Select-Object Name, ProcessId, ParentProcessId, CommandLine
    if ($Expect -and -not ($new | Where-Object Name -eq $Expect)) {
        Write-Error "expected '$Expect' to start for '$Target', got: $(($new.Name | Sort-Object -Unique) -join ', ')"
    }
}

function Get-Crash {
    <# .SYNOPSIS Crash dumps in C:\dumps and Application Error / WER / .NET crash events. #>
    param([int]$Hours = 24)
    $since = (Get-Date).AddHours(-$Hours)
    Get-ChildItem C:\dumps -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since |
        Select-Object @{n = 'Time'; e = { $_.LastWriteTime } }, @{n = 'Source'; e = { 'dump' } },
                      @{n = 'Detail'; e = { $_.FullName } }
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001, 1026; StartTime = $since } -ErrorAction SilentlyContinue |
        Select-Object @{n = 'Time'; e = { $_.TimeCreated } }, @{n = 'Source'; e = { $_.ProviderName } },
                      @{n = 'Detail'; e = { ($_.Message -split "`n")[0..2] -join ' ' } }
}

Export-ModuleMember -Function Get-FileHandler, Get-UrlHandler, Invoke-Handler, Start-Interactive, Invoke-Interactive, Get-Window, Get-Crash
