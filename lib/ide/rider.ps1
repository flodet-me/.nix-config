# rider setup: Rider run configurations that build an app, copy it into a VM
# and start it there (Winvm.targets, like the VS Code tasks), shared in the
# solution's .run folder: Run > NAME, then Run > Attach to Remote Process.
# Functions only (no param block): windows-host/winvm.ps1 dot-sources this; on
# a Linux host lib/ide/ide-setup.ps1 does. Needs Solution-Projects, Project-Kind,
# Info, Note, Die from the caller.
#
# Each configuration is a file of its own, .run/winvm-VM-APP-*.run.xml: setup
# rewrites exactly those, -Remove deletes them (and .run if that leaves it empty).

# One Shell Script configuration whose text runs in Rider's terminal (bash, zsh,
# PowerShell or cmd: one command, every argument in double quotes).
function New-RiderRunXml([string]$name, [string[]]$command) {
    $text = ($command | ForEach-Object { if ($_ -match '[\s;&|<>()]' -or $_ -eq '') { "`"$_`"" } else { $_ } }) -join ' '
    $e = { param($s) [Security.SecurityElement]::Escape($s) }
    @"
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="$(& $e $name)" type="ShConfigurationType">
    <option name="SCRIPT_TEXT" value="$(& $e $text)" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="SCRIPT_PATH" value="" />
    <option name="SCRIPT_OPTIONS" value="" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="`$PROJECT_DIR`$" />
    <option name="INDEPENDENT_INTERPRETER_PATH" value="true" />
    <option name="INTERPRETER_PATH" value="" />
    <option name="INTERPRETER_OPTIONS" value="" />
    <option name="EXECUTE_IN_TERMINAL" value="true" />
    <option name="EXECUTE_SCRIPT_FILE" value="false" />
    <envs />
    <method v="2" />
  </configuration>
</component>
"@
}

# $buildArgs: dotnet build arguments that switch the copy into the VM on (see
# Winvm.targets); $extra.Run/.RunWait/.Service/.ServiceWait: the deploy options.
function Invoke-RiderSetup([string]$solution, [string]$vm, [bool]$remove, [string[]]$only, [string[]]$buildArgs, [hashtable]$extra) {
    $solution = (Resolve-Path -LiteralPath $solution).Path
    if (Test-Path -LiteralPath $solution -PathType Container) {
        $c = @(Get-ChildItem -LiteralPath $solution -File | Where-Object { $_.Extension -in '.sln', '.slnx' })
        if ($c.Count -ne 1) { Die "${solution}: $(if ($c) { 'several solutions in it, name one' } else { 'no .sln/.slnx in it' })" }
        $solution = $c[0].FullName
    }
    $folder = Split-Path -Parent $solution
    $dir = Join-Path $folder '.run'
    $prefix = "winvm-$vm-"
    $old = @(Get-ChildItem -LiteralPath $dir -File -Filter "$prefix*.run.xml" -ErrorAction SilentlyContinue)
    if ($remove) {
        $old | Remove-Item -Force
        if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force)) { Remove-Item -LiteralPath $dir -Force }
        Info "removed $($old.Count) run configuration(s) for '$vm' from $dir"
        return
    }
    $files = [ordered]@{}; $names = @()
    foreach ($proj in @(Solution-Projects $solution)) {
        $pn = [IO.Path]::GetFileNameWithoutExtension($proj)
        if (-not (Test-Path -LiteralPath $proj)) { continue }
        if ($only -and $only -notcontains $pn) { continue }
        $kind = Project-Kind $proj
        if ($kind -eq 'web' -and $only -contains $pn) { $kind = 'dotnet' }
        if ($kind -notin 'dotnet', 'console') {
            if ($kind -in 'msix', 'uwp') { Note "skipped $pn (packaged app: deploy it with Visual Studio or 'deploy -Install', then attach)" }
            elseif ($kind -eq 'web') { Note "skipped $pn (web app: include it with the project option)" }
            continue
        }
        $build = @('dotnet', 'build', $proj) + $buildArgs + @("-p:WinvmVm=$vm", "-p:WinvmApp=$pn")
        $add = { param($id, $label, $more) $files["$prefix$pn-$id.run.xml"] = New-RiderRunXml "winvm ${vm}: $label" @($build + $more) }
        & $add 'desktop-wait' "$pn on the VM desktop, waiting for the debugger" @($extra.RunWait)
        & $add 'desktop' "$pn on the VM desktop" @($extra.Run)
        if ($kind -eq 'console') {   # services: console projects
            & $add 'service-wait' "$pn as Windows service, waiting 25 s for the debugger" @($extra.ServiceWait)
            & $add 'service' "$pn as Windows service winvm-$pn" @($extra.Service)
        }
        $names += $pn
    }
    if (-not $names) { Die "no app projects for Rider in $(Split-Path -Leaf $solution)" }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $old | Where-Object { -not $files.Contains($_.Name) } | Remove-Item -Force
    $utf8 = New-Object Text.UTF8Encoding $false
    foreach ($k in $files.Keys) { [IO.File]::WriteAllText((Join-Path $dir $k), $files[$k], $utf8) }
    Info "$($names -join ', '): $($files.Count) run configurations in $dir"
    Note "Rider: Run > 'winvm ${vm}: APP on the VM desktop, waiting for the debugger' (builds, copies,"
    Note "starts it), then Run > Attach to Remote Process > the VM's SSH connection > APP: debugging"
    Note "starts at Main. 'winvm $vm rider' shows that connection; '...as Windows service' for services."
}
