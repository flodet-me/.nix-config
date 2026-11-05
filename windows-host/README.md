# winvm.ps1 — Windows test VMs on VirtualBox (Windows host)

The Windows-host counterpart of `../winvm` (QEMU/KVM on Linux): build a clean,
patched Windows VM once, clone it in seconds, reset it after every test.
Separate from the Linux version; it shares only the ISOs (`../iso`), the
Chocolatey package list (`../provision/packages.txt`), the recipes
(`../recipes`) and the guest helper scripts (`../lib/guest`).

## Requirements

- Windows 10/11 host with VirtualBox 7.0 or newer (tested against 7.2's
  `VBoxManage`), with the Guest Additions ISO that comes with it.
- OpenSSH client (built in since Windows 10 1809; Settings > Apps > Optional
  features > "OpenSSH Client"). Remote Desktop Connection (`mstsc`) for `rdp`.
- Windows PowerShell 5.1 (built in) or PowerShell 7.
- If Hyper-V / WSL2 / Windows Sandbox is enabled, VirtualBox runs on top of
  the Windows hypervisor: works, but noticeably slower. Turning off "Virtual
  Machine Platform" and "Hyper-V" gives VirtualBox the CPU's VT-x directly.
- The Windows ISO: put it where `config.ps1` expects it (`..\iso\win10.iso`,
  ...) or set the path in `config.local.ps1`.
- For deploying from Visual Studio (see below):
  - Visual Studio 2026 with the workloads your solution needs anyway
    (".NET desktop development", "WinUI application development",
    ".NET Multi-platform App UI development"). Classic UWP also needs the
    optional component **Universal Windows Platform tools** (Visual Studio
    Installer > Modify > WinUI application development); Visual Studio 2026
    no longer installs it by default.
  - **Developer Mode** on this PC (Settings > System > For developers), for
    packaged apps (WinUI 3, MAUI, UWP). The VMs get it from the recipe.
  - Run `winvm.ps1` from a normal desktop session. VirtualBox's
    `VBoxManage` hangs in an SSH session to this PC.

If scripts are blocked: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`,
or run with `powershell -ExecutionPolicy Bypass -File .\winvm.ps1 ...`.

## Quick start

```powershell
cd windows-host
.\winvm.ps1 images                 # what can be built
.\winvm.ps1 build                  # win10: install + provision + all updates, 1-2 h
.\winvm.ps1 start -Wait            # VM "default", headless
.\winvm.ps1 ssh                    # PowerShell in the VM
.\winvm.ps1 rdp                    # desktop
.\winvm.ps1 reset                  # back to the clean state, in seconds
```

Other Windows versions: `.\winvm.ps1 build -Image win11`, then
`.\winvm.ps1 -Name win11 start`. More VMs of one version:
`.\winvm.ps1 new test2` (a linked clone: seconds, little disk).

## What `build` does

1. Creates the VM `winvm-base-IMAGE` (UEFI, TPM 2.0, Secure Boot with
   Microsoft's keys) and runs VirtualBox's unattended installation with the
   edition from `config.ps1` (the generic key installs without activating).
2. VirtualBox installs the Guest Additions; then a short post-install command
   sets up the OpenSSH server with a key generated in `state\id_ed25519`.
3. Over SSH: Remote Desktop, power settings, crash dumps to `C:\dumps`,
   Explorer developer settings, Chocolatey with `..\provision\packages.txt`.
4. All Windows updates, restarting as needed (`-No-Updates` skips them).
5. Shuts down, removes the ISOs, takes the snapshot "clean …" and creates the
   VM `default` (or `IMAGE`) as a linked clone of it.

`.\winvm.ps1 --dry-run build` stops after step 1 without starting anything:
the generated answer file and post-install script are in the VM's folder
(`vms\winvm-base-IMAGE\unattended-*`) for a look.

If a build fails, the build VM is left for a look (VirtualBox Manager, or
`ssh -p 2321 dev@127.0.0.1` with the key in `state\`); the next `build`
replaces it.

## Commands

```
.\winvm.ps1 [-Name NAME] <command> [options]      (without -Name: the VM "default")

images                 Windows versions and whether they're built
build [-Image IMG] [-Force] [-Gui] [-No-Updates]
new NAME [-Recipe R] [-Image IMG]
start [-Gui] [-Wait] / stop [-Force] / list / status
reset                  back to the clean snapshot
seal                   make the current state the clean state
snapshot save|load|delete|list NAME     (taken while running: with RAM)
apply RECIPE [-Seal]   run a recipe in an existing VM
destroy [NAME...] [-All] [-Yes]
ssh [COMMAND] / scp SRC... DST (vm:PATH = guest) / rdp
info, ps, kill, service, apps, events, ports, reboot    (as in ../winvm)
vs [APP]               Visual Studio: check the VM, print the F5 settings
vs setup SOLUTION [-Remove]           configure a solution's apps for F5 into the VM
deploy FOLDER [-As APP] [-Run | -Service] [-Wait] [-Args "..."] [-Install]
                       build output -> C:\deploy\APP; -Run: start it on the desktop,
                       -Service: as Windows service winvm-APP; -Install: MSIX
vscode setup SOLUTION [-Remove]       VS Code: build, copy and debug in the VM over SSH
rider setup SOLUTION [-Remove]        Rider: run configurations (build, copy, start)
rider                  what Rider's "Attach to Remote Process" needs
ssh-config             Host entry for ~/.ssh/config
```

## Custom VMs and recipes

The recipes in `..\recipes` work here too (see `..\docs\custom-vms.md`):

```powershell
.\winvm.ps1 new de -Recipe german-formats    # created, set up, sealed
.\winvm.ps1 -Name de start
.\winvm.ps1 -Name de reset                   # back to the German setup
```

`VM_RAM` and `VM_CPUS` from `recipe.env` are applied. `VM_INTERNET`,
`USB_DEVICES` and `AUDIO` are not (a note says so): use VirtualBox Manager for
those.

## Visual Studio: deploy and debug

Visual Studio 2026 on this PC deploys into a VM and debugs there with F5, like
a second PC on the desk.

### Setting it up on a new machine

Needs: Windows 10/11 with VirtualBox 7, Visual Studio 2026 with the workloads
your apps need, the OpenSSH client, and a Windows ISO (see Requirements).

```powershell
git clone <this repo> C:\src\windows-vm
cd C:\src\windows-vm\windows-host
.\winvm.ps1 build                                # once: Windows image, 1-2 h
.\winvm.ps1 new dev -Recipe vs-deploy            # once: the deploy VM, ~10 min
.\winvm.ps1 -Name dev vs setup C:\src\MyApp\MyApp.sln   # once per solution
```

Then open the solution in Visual Studio, choose the launch profile
**winvm dev** next to the start button and press F5. That's all.

`vs setup` looks at every project in the solution (`.sln`, `.slnx`, a single
project, or a folder with one solution) and configures each app by type:

| project | what `vs setup` does | F5 then |
|---|---|---|
| Windows GUI exe (`WinExe`): WPF, WinForms, unpackaged WinUI 3; unpackaged MAUI (`WindowsPackageType` None; only the Windows target framework is copied); C#, VB, F# | `PROJECT.csproj.user`: copy the build to `C:\deploy\PROJECT` in the VM after builds **while the profile *winvm dev* is selected** (`vs\Winvm.targets`; builds for other profiles leave the VM alone), and make `C:\deploy\PROJECT` on this PC a junction to the build output (VS checks the path exists locally); launch profile *winvm dev* (`Executable`, remote) | builds, copies, starts it in the VM under the debugger; boots a stopped VM |
| packaged WinUI 3 or MAUI (the default for MAUI), UWP on .NET 9+ (MSIX) | launch profile *winvm dev* (`MsixPackage`, remote); *Deploy* ticked in the solution | VS installs the package in the VM, starts and debugs it |
| classic UWP, packaging project (`.wapproj`) | `PROJECT.csproj.user`: remote machine `127.0.0.1:PORT`, authentication None, for every configuration; *Deploy* ticked in the solution | start button shows *Remote Machine*; VS installs the package in the VM, starts and debugs it |
| console apps, worker and Windows services (`Exe`) | like a GUI exe: it runs in a console window in the VM (services as a console app; as a real service see below) | builds, copies, starts it in the VM under the debugger |
| web apps (ASP.NET Core, Blazor) | nothing, unless named: `vs setup ... -Project Api` treats them like the above | |
| libraries, test projects, MAUI projects without a Windows target, C++/WiX/SQL/shared projects | nothing | |
| old-style .NET Framework projects (non-SDK `.csproj`) | not supported yet: their remote settings live in the `.user` file (Debug page: *Use remote machine*), which `vs setup` doesn't write; the copy step works (`Winvm.targets`), set the remote machine by hand | |

What it changes, so you know what to commit: the `.csproj.user` files are
personal (normally in `.gitignore`); the launch profile goes into
`Properties\launchSettings.json` (`My Project\` for VB; kept next to your
other profiles; commit it or not); *Deploy* goes into the solution file. The
project files themselves aren't touched. Run it again any time (it doesn't
add things twice).

How it edits files: only what it adds is written, as text, into the file as
it is. The profile *winvm dev* is inserted as the last profile; your other
profiles, comments (Visual Studio allows `//` and `/* */`), trailing commas,
escapes, indentation, line endings and BOM stay byte for byte as they were.
In `.user` and `.slnx` files only its own elements are added (`Label="winvm"`
in `.user`), indented like the rest of the file. A `launchSettings.json` it
can't read is left alone, and that project is skipped with a note.

What it doesn't change: profiles other than *winvm dev* keep running on this
PC, and their builds don't copy anything into the VM or start it.

`vs setup ... -Remove` undoes all of it: the profiles, the `.user` entries,
the *Deploy* ticks it added (it records them in the `.user` file; ticks that
were there before stay), files it created, and the `C:\deploy\APP` junctions
on this PC. Files it changed are written back byte for byte (encoding, line
endings), so git shows no difference afterwards. The VM keeps the copies it
received; `reset` returns it to its sealed state.

Another VM: `-Name other vs setup ...` adds a profile *winvm other*.

The rest of this section explains what these pieces do, for setting projects
up by hand or when something doesn't work. `.\winvm.ps1 -Name dev vs MyApp`
checks the VM and prints the manual settings.

The recipe (`..\recipes\vs-deploy`) turns on Developer Mode, installs the VS
2026 remote tools and starts the remote debugger (msvsmon, no authentication,
port 4026) at every sign-in. It also installs the .NET 10 desktop runtime,
the Windows App SDK 1.8 and 2.6 runtimes (for unpackaged WinUI 3 apps; change
`$appRuntimes` in the recipe for other versions) and the VC++ runtime, and
creates `C:\deploy`. The VM's port 4026 is at `127.0.0.1:40260`
(`VsDebugPort` + the VM's number; `status` shows it). `reset` keeps all of it:
the VM was sealed after the recipe.

```
  Visual Studio ──F5──▶ 127.0.0.1:40260 ──NAT──▶ msvsmon in the VM ──▶ app on the VM's desktop
        │                                              ▲
        └─ .NET: after the build, vs\Winvm.targets ────┘ copies bin\... to C:\deploy\APP (deploy)
```

**UWP and packaged WinUI 3 (MSIX)**: Visual Studio deploys the package itself.

- UWP: choose *Remote Machine* in the device list next to the start button
  (or Project > Properties > Debug), address `127.0.0.1:40260`, authentication
  *None*. Not *Universal (Unencrypted Protocol)*, which older docs name:
  Visual Studio 2026 does that over SSH and fails with DEP6957. `vs setup`
  writes these settings into `PROJECT.csproj.user` itself.
- Packaged WinUI 3: the start button lists the launch profiles of
  `Properties\launchSettings.json`. Add one for the VM next to the local one:

  ```json
  "MyApp (VM)": {
    "commandName": "MsixPackage",
    "remoteDebugEnabled": true,
    "remoteDebugMachine": "127.0.0.1:40260",
    "authenticationMode": "None"
  }
  ```

Then F5. The project needs *Deploy* ticked in Build > Configuration Manager (templates
do that; a `.csproj` opened without its `.sln` doesn't), otherwise VS says
the project "needs to be deployed before it can be started".
Without F5 deployment, build an app package for sideloading and install it:
`.\winvm.ps1 -Name dev deploy ...\AppPackages\MyApp_1.0.0.0_x64_Debug_Test -Install`
(trusts the package's `.cer`, installs the dependencies from its folder).

**.NET 8+ desktop (WPF, WinForms, console)**: Visual Studio doesn't copy these
to a remote machine, so `vs\Winvm.targets` does it after every build:

```xml
<!-- in the .csproj, or in Directory.Build.targets for all projects -->
<PropertyGroup>
  <WinvmDeploy>true</WinvmDeploy>
  <WinvmVm>dev</WinvmVm>               <!-- default: the VM "default" -->
</PropertyGroup>
<Import Project="C:\path\to\windows-vm\windows-host\vs\Winvm.targets" />
```

and a launch profile in `Properties\launchSettings.json` that starts the copy
in the VM under the debugger (`vs MyApp` prints it with this VM's port):

```json
"winvm": {
  "commandName": "Executable",
  "executablePath": "C:\\deploy\\MyApp\\MyApp.exe",
  "workingDirectory": "C:\\deploy\\MyApp",
  "remoteDebugEnabled": true,
  "remoteDebugMachine": "127.0.0.1:40260",
  "authenticationMode": "None"
}
```

Choose the profile *winvm* next to the start button and press F5: it builds,
copies to `C:\deploy\MyApp` (stopping a running copy first) and starts the app
on the VM's desktop. A stopped VM is started first (the first F5 then takes
about a minute longer). `deploy FOLDER -As APP` does the copy by hand.

**Two ways into the VM.** .NET and packaged apps use the port forward
`127.0.0.1:PORT`. Classic UWP needs the VM's own address: Visual Studio 2026
hangs ("Deploy started...", Not Responding) deploying UWP to a port forward.
So every VM also gets a network card on VirtualBox's host-only network
(`HostOnlyAdapter = 'auto'` in `config.ps1`, the adapter VirtualBox's
installer creates; `status` shows the address), and `vs setup` uses
`IP:4026` for UWP projects. The debugger has no authentication; only this PC
can reach a host-only network, so don't bridge it to your LAN. A VM created
before this gets the card when it's next started from the powered-off state.

**When F5 doesn't work**

| Visual Studio says | Cause and fix |
|---|---|
| "needs to be deployed before it can be started" | *Deploy* not ticked for the project (Build > Configuration Manager); `vs setup` ticks it. Open the `.sln`, not the bare `.csproj`. |
| "The debug executable 'C:\deploy\...' ... does not exist" | The build didn't run the copy step (no `vs setup`, or `WinvmDeploy` off), so `C:\deploy\APP` on this PC is missing. |
| "Remote Debugger (MSVSMON.EXE) does not appear to be running" | VM not running, or Windows Firewall added *block* rules for msvsmon (it does when its prompt isn't answered). `.\winvm.ps1 -Name dev vs` removes them and starts the debugger. |
| UWP: DEP6957 "Failed to connect ... using Universal Authentication" | Authentication must be *None*; `vs setup` sets it. |
| UWP: hangs at "Deploy started..." | Address is `127.0.0.1:PORT`; use the host-only `IP:4026` (`vs setup` does, once the VM has the address). |
| UWP: "Cannot resolve 'Windows.metadata'" right after installing the UWP tools | Visual Studio's cache: `devenv /updateconfiguration`, or restart Visual Studio. |

### Services and console apps in Visual Studio

Console apps and worker services get the launch profile *winvm dev* like a
GUI app: F5 copies and starts them in the VM (a service then runs as a console
app). To debug a **real Windows service**:

```powershell
.\winvm.ps1 -Name dev deploy MyService\bin\Debug\net10.0 -As MyService -Service
```

installs it as the service `winvm-MyService` (manual start, LocalSystem) and
starts it; deploying again stops it, replaces the files and starts it again.
Then in Visual Studio: Debug > Attach to Process, connection type
**Remote (Windows - No Authentication)**, target `127.0.0.1:40260` (the VM's
port, `status` shows it), *Show processes from all users*, pick
`MyService.exe`. `-Run` instead starts any program on the VM's desktop, to
attach to it the same way; `-Args "..."` gives it a command line.

## VS Code and Rider

Both debug over SSH; the same works from a Linux host with `../winvm`. The VM
needs the recipe `vs-deploy`. **Full guide with all app types, packaged apps
and troubleshooting: [../docs/ide-debugging.md](../docs/ide-debugging.md).**

```powershell
.\winvm.ps1 -Name dev vscode setup C:\src\MyApp\MyApp.sln     # VS Code (-Remove: undo)
.\winvm.ps1 -Name dev rider setup C:\src\MyApp\MyApp.sln      # Rider run configurations (-Remove: undo)
.\winvm.ps1 -Name dev rider                                    # SSH settings for Rider's attach dialog
.\winvm.ps1 -Name dev deploy bin\Debug\net10.0 -As MyApp -Run -Wait   # by hand: start, wait for a debugger
```

**VS Code** (C# extension): *Run and Debug* lists per app **winvm dev: MyApp**
(console apps, started by the debugger), **...on the VM desktop** (GUI apps:
started on the desktop waiting for the debugger, then attached), **...as Windows
service** and **attach MyApp**; packaged (MSIX) projects get only *attach*.
vsdbg in the VM is kept matching the extension (a mismatch breaks
breakpoints). The same text-only editing as `vs setup`: only entries named
*winvm dev: ...* are added or removed.

**Rider**: run *winvm dev: MyApp on the VM desktop, waiting for the debugger*
(from `rider setup`), then *Run > Attach to Remote Process*: connection
`dev@127.0.0.1:PORT` (not `127.0.0.1@PORT`, the generic one that only lists
Linux and macOS processes), the app, *Attach with .NET Debugger*. The first
time: add the SSH connection (host, port, user, key as `rider` prints them)
and *Install tools to remote computer*. Rider needs cmd.exe as the VM's SSH
login shell; the recipe and `rider` set it.

`.\winvm.ps1 -Name dev ssh-config >> $HOME\.ssh\config` gives a host entry
`winvm-dev` for plain `ssh` and other tools.

## Differences from the Linux version

| | Linux (`../winvm`) | Windows host (`winvm.ps1`) |
|---|---|---|
| hypervisor | QEMU/KVM | VirtualBox |
| clean state | read-only base image + overlay per VM | snapshot "clean" + linked clones |
| install | own `autounattend.xml`, VirtIO drivers | VirtualBox unattended install, Guest Additions |
| test tools (`provision/tools.txt`) | installed | not installed: add what you need to `packages.txt` or a recipe |
| Visual Studio remote deploy + debugging | `debug vs`, attach | `vs`, `deploy`, F5 (recipe `vs-deploy`) |
| run / crashes / WinDbg / uitest / netcap / proxy / trace / usb | yes | no |
| offline VMs (`VM_INTERNET=0`) | yes | no |
| evaluation expiry warnings | yes | no (evaluation images: rebuild after 90/180 days) |

## Configuration

`config.ps1` has the defaults (CPUs, RAM, disk, ports, images with ISO path,
edition, key, locale, time zone). Put changes in `config.local.ps1`:

```powershell
$Config.RamMB = 12288
$Config.Images.win10.Iso = 'D:\iso\Win10_22H2_EnglishInternational_x64.iso'
$Config.Images.win10.Locale = 'en_GB'; $Config.Images.win10.Country = 'GB'
$Config.Images.win10.TimeZone = 'Europe/Berlin'
```

Default credentials `dev` / `dev`; SSH and RDP are only forwarded to
127.0.0.1 (`SshPort` / `RdpPort` + the VM's number).

## Status

Tested end to end on 2026-10-31 on Windows 10 22H2 with VirtualBox 7.2.22
(itself running in a winvm VM with nested AMD-V):

- `build`: unattended install, guest additions, SSH, provisioning,
  Chocolatey packages, 4 Windows Update rounds with restarts, clean snapshot,
  linked clone. About 1 h 15 min (nested).
- `list`, `status`, `start -Wait`, `stop`, `reboot`, `ssh`, `scp`, `info`,
  `ps`, `service`, `ports`, `snapshot save/list/load` (live), `reset`,
  `new -Recipe german-formats` (with its restart), sealed `reset`, `destroy`.

Notes:

- Run `winvm.ps1` from a desktop session. Started from an SSH session into
  the Windows host, VirtualBox VMs can hang.
- `ssh` reports exit codes only as 0 or 1 (a limit of Windows' SSH server).
- Not tested yet: `apply`, `seal` by hand, `rdp`, `apps`, `events`, `kill`,
  images other than win10, `-Gui`.
- Visual Studio deployment tested end to end on 2026-11-03 (VirtualBox 7.2.22,
  Visual Studio Community 2026 18.11.3, VM from the win10 image, nested):
  recipe `vs-deploy` (applied 4 times: idempotent), `vs`, `vs setup` on three
  solutions from scratch, then F5 in Visual Studio for a .NET 10 WPF app, a
  packaged WinUI 3 app (Windows App SDK 2.6) and a classic UWP app: each was
  built, deployed into the VM, started on its desktop and debugged (debugger
  attached to the process in the VM). Also: the build boots a stopped VM,
  32-bit MSBuild, the remote debugger watchdog. On 2026-11-04 (VS 18.11.3 with
  the MAUI workload): a .NET 10 MAUI app from `dotnet new maui`, unpackaged
  (the template default) and packaged, in a `.slnx`: F5 deployed and debugged
  both in the VM (only the Windows target framework copied). `vs setup -Remove`
  checked with git: no difference left in the projects and solutions (WPF,
  MAUI, plus a solution with all project kinds), junctions and an empty
  `C:\deploy` removed. Later on 2026-11-04, after `vs setup` changed to editing
  files as text: a test solution with every project kind (C#/VB/F# apps, web
  app, worker, console tool, library, tests, MAUI variants, C++/WiX/SQL/shared
  projects, solution folders) and hostile files (`launchSettings.json` with
  comments, trailing commas, escapes, emoji, a broken one; tab-indented `.user`;
  BOM, CRLF, missing final newline) as `.sln` and `.slnx`, in PowerShell 7 and
  Windows PowerShell 5.1: projects it doesn't set up stay byte-identical, the
  others only gain lines, a second run changes nothing, `-Remove` restores
  every file byte for byte. In Visual Studio (profile picked in the start
  button's dropdown): with *winvm dev* F5 copies and runs in the VM; with the
  local profile builds don't touch the VM and F5 runs on this PC. F5 into the
  VM again for WPF, WinUI 3, classic UWP and packaged MAUI. Then (same day):
  `deploy -Run` (console app on the VM desktop, with arguments) and `-Service`
  (worker service as a real Windows service, LocalSystem; redeploy stops and
  restarts it); Visual Studio F5 for a console app; Visual Studio attached to
  the running service (Remote (Windows - No Authentication), debugger attached,
  detached, service kept running); VS Code 1.119 with C# 2.160 (started through
  its command palette): launch of a console app in the VM under vsdbg over SSH,
  and attach to the running Windows service; `vscode setup` round trip on files
  with comments, foreign entries, BOM, CRLF (byte-identical after -Remove);
  SSH and SFTP with the key as Rider uses them.
- 2026-11-05 (same setup): recipe `vs-deploy` again (SSH login shell cmd.exe,
  `ssh` with quotes, warnings, errors as text, exit code 3), `vscode setup`
  (updated vsdbg in the VM to the C# extension's 18.12), `rider setup`, the VS
  Code task "start on the VM desktop and wait" (built, copied, started
  waiting), `deploy -Service -Wait`, VS Code F5 with a breakpoint hit (console
  app), a packaged WinUI 3 app built as MSIX with symbols: `deploy -Install
  -Run` (replacing Visual Studio's loose-file registration and a same-version
  install), VS Code attached, breakpoint hit; `vs setup` + F5-like build with
  and without the winvm profile, `-Remove` byte-identical. Rider 2026.2 was
  tested from a Linux host (same SSH path as from here). Not tested: Rider on a
  Windows host, UWP on .NET 9+ (`UseUwp`), `.wapproj`.
