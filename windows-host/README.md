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
deploy FOLDER [-As APP] [-Install]    build output -> C:\deploy\APP in the VM
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
| .NET exe: WPF, WinForms, console, unpackaged WinUI 3 | `PROJECT.csproj.user`: copy the build to `C:\deploy\PROJECT` in the VM after every build (`vs\Winvm.targets`), and make `C:\deploy\PROJECT` on this PC a junction to the build output (VS checks the path exists locally); launch profile *winvm dev* (`Executable`, remote) | builds, copies, starts it in the VM under the debugger; boots a stopped VM |
| packaged WinUI 3, UWP on .NET 9+ (MSIX) | launch profile *winvm dev* (`MsixPackage`, remote); *Deploy* ticked in the solution | VS installs the package in the VM, starts and debugs it |
| classic UWP, packaging project (`.wapproj`) | `PROJECT.csproj.user`: remote machine `127.0.0.1:PORT`, authentication None, for every configuration; *Deploy* ticked in the solution | start button shows *Remote Machine*; VS installs the package in the VM, starts and debugs it |
| libraries, test projects | nothing | |

What it changes, so you know what to commit: the `.csproj.user` files are
personal (normally in `.gitignore`); the launch profile goes into
`Properties\launchSettings.json` (kept next to your other profiles; commit it
or not); *Deploy* goes into the solution file. The project files themselves
aren't touched. Run it again any time (it doesn't add things twice);
`vs setup ... -Remove` takes the profiles and the `.user` entries out again.
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
  32-bit MSBuild, the remote debugger watchdog. Not tested: UWP on .NET 9+
  (`UseUwp`), `.wapproj`, `.slnx` in Visual Studio, `deploy -Install`.
