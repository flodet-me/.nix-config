# VS Code: debug .NET apps in a winvm VM over SSH (vsdbg, installed in the VM
# by the recipe vs-deploy). Writes the solution folder's .vscode/launch.json and
# .vscode/tasks.json: for each app project a launch configuration (build, copy
# into the VM, start under the debugger), an attach configuration (to a process
# already running there: an app on the desktop, a service) and the tasks behind
# them. Used by both hosts:
#   Windows (VirtualBox): winvm.ps1 vscode setup SOLUTION   (this file is dot-sourced)
#   Linux (QEMU):         winvm vscode setup SOLUTION       (lib/ide/ide-setup.ps1, pwsh)
# Only entries named "winvm VM: ..." are added or taken out (-Remove); the rest of
# both files stays as it is, byte for byte (comments, other entries, formatting).

# --- JSON arrays, edited as text (objects: Json-Members & co in winvm.ps1) ---------

# The elements of the array whose '[' is at $open: @{ Start; End }.
function Json-Elements([string]$t, [int]$open) {
    if ($t[$open] -ne '[') { throw "expected an array at $open" }
    $el = @(); $i = $open + 1
    while ($true) {
        $i = Json-SkipWs $t $i
        if ($i -ge $t.Length) { throw 'unterminated array' }
        if ($t[$i] -eq ']') { return , $el }
        if ($t[$i] -eq ',') { $i++; continue }
        $e = Json-SkipValue $t $i
        $el += @{ Start = $i; End = $e }
        $i = $e
    }
}
# Inserts $value as the last element; Json-RemoveElement is its exact inverse.
function Json-InsertElement([string]$t, [int]$open, [string]$value, [string]$in, [string]$closeIn, [string]$nl) {
    $el = Json-Elements $t $open
    if ($el.Count) { return $t.Insert($el[-1].End, ",$nl$in$value") }
    $close = Json-SkipWs $t ($open + 1)
    if ($close -eq $open + 1) { return $t.Insert($open + 1, "$nl$in$value$nl$closeIn") }   # [] -> one element, nicely
    $t.Insert($open + 1, "$nl$in$value")
}
function Json-RemoveElement([string]$t, [int]$open, [int]$k) {
    $el = Json-Elements $t $open
    if ($el.Count -eq 1) {
        $close = Json-SkipWs $t $el[0].End
        if (-not $t.Substring($open + 1, $el[0].Start - $open - 1).Trim() -and -not $t.Substring($el[0].End, $close - $el[0].End).Trim()) {
            return $t.Remove($open + 1, $close - $open - 1)   # back to []
        }
        return $t.Remove($open + 1, $el[0].End - $open - 1)
    }
    if ($k -lt $el.Count - 1) { return $t.Remove($el[$k].Start, $el[$k + 1].Start - $el[$k].Start) }
    $t.Remove($el[$k - 1].End, $el[$k].End - $el[$k - 1].End)
}
# The string value of member $key in the object at $i, or $null.
function Json-StringMember([string]$t, [int]$i, [string]$key) {
    if ($t[$i] -ne '{') { return $null }
    foreach ($m in (Json-Members $t $i)) {
        if ($m.Key -eq $key -and $t[$m.ValueStart] -eq '"') { return [regex]::Unescape($t.Substring($m.ValueStart + 1, $m.ValueEnd - $m.ValueStart - 2)) }
    }
    $null
}
# Any value as JSON: strings, booleans, numbers, arrays, (ordered) hashtables.
function Json-Value($v, [string]$in, [string]$unit, [string]$nl) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [int] -or $v -is [long]) { return "$v" }
    if ($v -is [string]) { return Json-Quote $v }
    if ($v -is [Collections.IDictionary]) {
        if (-not $v.Count) { return '{}' }
        $lines = foreach ($kv in $v.GetEnumerator()) { "$in$unit$(Json-Quote $kv.Key): $(Json-Value $kv.Value "$in$unit" $unit $nl)" }
        return "{$nl" + ($lines -join ",$nl") + "$nl$in}"
    }
    $items = @($v)
    if (-not $items.Count) { return '[]' }
    if (-not ($items | Where-Object { $_ -is [Collections.IDictionary] -or ($_ -is [Array]) })) {   # short arrays on one line
        return '[ ' + (($items | ForEach-Object { Json-Value $_ '' $unit $nl }) -join ', ') + ' ]'
    }
    $lines = foreach ($x in $items) { "$in$unit$(Json-Value $x "$in$unit" $unit $nl)" }
    "[$nl" + ($lines -join ",$nl") + "$nl$in]"
}

# Puts $entries (ordered hashtables, each with $idKey) into the array $listKey of
# $file, replacing entries whose $idKey starts with $prefix; with $remove only
# takes those out. A file it creates is deleted again when it's back to its
# skeleton. Returns a word for the summary: created / updated / removed / ''.
function Set-JsonListEntries([string]$file, [string]$version, [string]$listKey, [string]$idKey, [object[]]$entries, [string]$prefix, [bool]$remove) {
    $nl = "`r`n"
    $skeleton = "{$nl  `"version`": `"$version`",$nl  `"$listKey`": []$nl}$nl"
    $exists = Test-Path -LiteralPath $file
    if (-not $exists) {
        if ($remove -or -not $entries) { return '' }
        New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
        $t = $skeleton; $orig = $null
    } else {
        $orig = Read-Bytes $file
        $t = [IO.File]::ReadAllText($file)
        $nl = Text-Newline $t
    }
    $before = $t
    $unit = if ($t -match "\n([ \t]+)`"") { $Matches[1] } else { '  ' }
    $top = Json-SkipWs $t 0
    $members = Json-Members $t $top
    $lm = $members | Where-Object { $_.Key -eq $listKey } | Select-Object -First 1
    if (-not $lm) {
        if ($remove -or -not $entries) { return '' }
        $t = Json-InsertMember $t $top $listKey '[]' $unit $nl
        $members = Json-Members $t $top
        $lm = $members | Where-Object { $_.Key -eq $listKey } | Select-Object -First 1
    }
    # Ours out (from the back, so the positions stay right)
    $el = Json-Elements $t $lm.ValueStart
    for ($k = $el.Count - 1; $k -ge 0; $k--) {
        $id = Json-StringMember $t $el[$k].Start $idKey
        if ($id -and $id.StartsWith($prefix)) { $t = Json-RemoveElement $t $lm.ValueStart $k }
    }
    if (-not $remove) {
        foreach ($e in $entries) {
            $lm = (Json-Members $t $top) | Where-Object { $_.Key -eq $listKey } | Select-Object -First 1
            $t = Json-InsertElement $t $lm.ValueStart (Json-Value $e "$unit$unit" $unit $nl) "$unit$unit" $unit $nl
        }
    }
    if ($t -eq $before -and $exists) { return '' }
    if (($t -replace "`r`n", "`n") -eq ($skeleton -replace "`r`n", "`n")) {   # nothing but the skeleton it was created as
        if ($exists) { Remove-Item -LiteralPath $file -Force }
        $d = Split-Path $file
        if ((Test-Path $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force }
        return $(if ($exists) { 'removed' } else { '' })
    }
    Write-Like $file $t $orig $false
    if (-not $exists) { 'created' } elseif ($remove) { 'removed' } else { 'updated' }
}

# The launch and attach configurations and the tasks for one app project.
# $buildArgs: MSBuild arguments that switch the copy into the VM on (see
# Winvm.targets); $extra.Run / $extra.Service: the ones for --run / --service.
function New-VsCodeEntries($pl, [string]$vm, [string]$sshExe, [string[]]$sshArgs, [string[]]$buildArgs, [hashtable]$extra, [string]$folder) {
    $pfx = "winvm ${vm}: "
    $pipe = [ordered]@{ pipeCwd = '${workspaceFolder}'; pipeProgram = $sshExe; pipeArgs = @($sshArgs); debuggerPath = 'C:\vsdbg\vsdbg.exe'; quoteArgs = $false }
    # Relative to the solution folder (no [IO.Path]::GetRelativePath in Windows PowerShell 5.1)
    $f = $folder.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $rel = $(if ($pl.Proj.StartsWith($f, [StringComparison]::OrdinalIgnoreCase)) { $pl.Proj.Substring($f.Length) } else { $pl.Proj }) -replace '\\', '/'
    $build = @('build', "`${workspaceFolder}/$rel") + $buildArgs + @("-p:WinvmVm=$vm", "-p:WinvmApp=$($pl.Pn)")
    $exe = "C:\deploy\$($pl.Pn)\$($pl.Asm).exe"
    # processName, resolved by vsdbg in the VM: ${command:pickRemoteProcess} only
    # supports Linux and macOS targets (the C# extension checks `uname`).
    $attach = { param($label, $task) $c = [ordered]@{ name = $label; type = 'coreclr'; request = 'attach'; processName = "$($pl.Asm).exe" }; if ($task) { $c.preLaunchTask = $task }; $c.pipeTransport = $pipe; $c }
    # Packaged (MSIX) apps install with Visual Studio or deploy -Install -Run: attach only.
    if ($pl.Kind -eq 'msix') { return @{ Launch = @(& $attach "${pfx}attach $($pl.Pn)" $null); Tasks = @() } }
    $launch = @(
        # Started by vsdbg: in the SSH session, so without a desktop (console apps).
        [ordered]@{ name = "${pfx}$($pl.Pn)"; type = 'coreclr'; request = 'launch'; preLaunchTask = "${pfx}deploy $($pl.Pn)"
                    program = $exe; args = @(); cwd = "C:\deploy\$($pl.Pn)"; console = 'internalConsole'; stopAtEntry = $false; pipeTransport = $pipe },
        # Started on the desktop, waiting for the debugger (deploy -Wait), then attached: GUI apps, from Main on.
        (& $attach "${pfx}$($pl.Pn) on the VM desktop" "${pfx}deploy $($pl.Pn), start it on the VM desktop and wait for the debugger"),
        (& $attach "${pfx}attach $($pl.Pn)" $null)
    )
    $task = { param($label, $more, $hide) $t = [ordered]@{ label = $label; type = 'process'; command = 'dotnet'; args = @($build + $more); group = 'build'; problemMatcher = '$msCompile' }; if ($hide) { $t.hide = $true }; $t }
    $tasks = @(
        (& $task "${pfx}deploy $($pl.Pn)" @()),
        (& $task "${pfx}deploy $($pl.Pn) and start it on the VM desktop" @($extra.Run)),
        (& $task "${pfx}deploy $($pl.Pn), start it on the VM desktop and wait for the debugger" @($extra.RunWait) $true)
    )
    if ($pl.Kind -eq 'console') {   # services: console projects
        $launch += (& $attach "${pfx}$($pl.Pn) as Windows service" "${pfx}deploy $($pl.Pn) as Windows service, wait for the debugger")
        $tasks += (& $task "${pfx}deploy $($pl.Pn) as Windows service winvm-$($pl.Pn)" @($extra.Service))
        $tasks += (& $task "${pfx}deploy $($pl.Pn) as Windows service, wait for the debugger" @($extra.ServiceWait) $true)
    }
    @{ Launch = $launch; Tasks = $tasks }
}

# vscode setup: the configurations for every app project of $solution
# (-Remove: takes them out again). $buildArgs/$extra: see New-VsCodeEntries.
function Invoke-VsCodeSetup([string]$solution, [string]$vm, [bool]$remove, [string[]]$only, [string]$sshExe, [string[]]$sshArgs, [string[]]$buildArgs, [hashtable]$extra) {
    $solution = (Resolve-Path -LiteralPath $solution).Path
    if (Test-Path -LiteralPath $solution -PathType Container) {
        $c = @(Get-ChildItem -LiteralPath $solution -File | Where-Object { $_.Extension -in '.sln', '.slnx' })
        if ($c.Count -ne 1) { Die "${solution}: $(if ($c) { 'several solutions in it, name one' } else { 'no .sln/.slnx in it' })" }
        $solution = $c[0].FullName
    }
    $folder = Split-Path -Parent $solution
    $pfx = "winvm ${vm}: "
    $launch = @(); $tasks = @(); $names = @()
    if (-not $remove) {
        foreach ($proj in @(Solution-Projects $solution)) {
            $pn = [IO.Path]::GetFileNameWithoutExtension($proj)
            if (-not (Test-Path -LiteralPath $proj)) { continue }
            if ($only -and $only -notcontains $pn) { continue }
            $kind = Project-Kind $proj
            if ($kind -eq 'web' -and $only -contains $pn) { $kind = 'dotnet' }
            if ($kind -eq 'msix') { Note "$pn is a packaged app: only 'attach' (install and start it with Visual Studio or 'deploy -Install -Run')" }
            if ($kind -notin 'dotnet', 'console', 'msix') {
                if ($kind -eq 'uwp') { Note "skipped $pn (UWP: Visual Studio's debugger only)" }
                elseif ($kind -eq 'web') { Note "skipped $pn (web app: include it with the project option)" }
                continue
            }
            $asm = Project-Prop (Get-Content -Raw -LiteralPath $proj) 'AssemblyName'
            if (-not $asm -or $asm -match '\$') { $asm = $pn }
            $e = New-VsCodeEntries @{ Proj = $proj; Pn = $pn; Asm = $asm; Kind = $kind } $vm $sshExe $sshArgs $buildArgs $extra $folder
            $launch += $e.Launch; $tasks += $e.Tasks; $names += $pn
        }
        if (-not $names) { Die "no app projects for VS Code in $(Split-Path -Leaf $solution)" }
    }
    $dir = Join-Path $folder '.vscode'
    $l = Set-JsonListEntries (Join-Path $dir 'launch.json') '0.2.0' 'configurations' 'name' $launch $pfx $remove
    $t = Set-JsonListEntries (Join-Path $dir 'tasks.json') '2.0.0' 'tasks' 'label' $tasks $pfx $remove
    if ($remove) { Info "removed the '$pfx...' entries from .vscode/launch.json$(if ($l) { " ($l)" }) and tasks.json$(if ($t) { " ($t)" })"; return }
    Info "$($names -join ', '): .vscode/launch.json ($l), .vscode/tasks.json ($t) in $folder"
    Note "VS Code: open that folder, Run and Debug (each builds and copies first):"
    Note "  '${pfx}APP'                 console apps: started by the debugger, output in the Debug Console"
    Note "  '${pfx}APP on the VM desktop' GUI apps: started on the VM's desktop, debugged from Main on"
    Note "  '${pfx}APP as Windows service' (console projects) as service winvm-APP, from Main on"
    Note "  '${pfx}attach APP'          attach to it running in the VM (no build; packaged apps: only this)"
    Note 'Needs the C# extension (ms-dotnettools.csharp) and the recipe vs-deploy in the VM (vsdbg in C:\vsdbg).'
}

