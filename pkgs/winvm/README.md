# winvm — clean, reproducible Windows test VMs

Build a Windows VM once, fully unattended, then start, test and reset it from
the Linux command line in seconds. Plain QEMU/KVM: no libvirt, no root, all
files stay in this directory.

**What you get**

- **Windows 10, 11, 11 LTSC, Server 2025**, installed unattended, all updates
  applied, online or fully **offline** (air-gapped).
- **Reset in a second**: the installed Windows is a read-only base image, every
  VM is a thin copy-on-write layer on top. Snapshots with RAM, throwaway sessions.
- **Run your app from the host**: `winvm run ./app.exe` copies it in and runs it,
  then reports exit code, output and a WinDbg crash analysis.
- **Real-PC firmware**: UEFI, Secure Boot (Microsoft keys) and TPM 2.0, for
  BitLocker, VBS, Windows Hello.
- **Clean Windows**: no ads, suggested apps, Bing/Cortana, OneDrive or News;
  minimal telemetry. Also applies to user accounts created later.
- **Test, debug and capture**: 30+ test tools preinstalled, remote debugging
  (Visual Studio, WinDbg, kernel, gdb), UI automation (WinAppDriver),
  screenshots, `.pcapng`, mitmproxy, Process Monitor traces.
- **Several VMs** of one or more Windows versions, each with its own ports.
  If you only need one VM, there's nothing extra to do.

---

## Contents

[Requirements](#requirements) ·
[Quick start](#quick-start) ·
[How it works](#how-it-works) ·
[Everyday use](#everyday-use) ·
[Commands](#commands) ·
[Windows versions](#windows-versions) ·
[Several VMs](#several-vms) ·
[Custom VMs](#custom-vms) ·
[Running apps](#running-and-testing-apps) ·
[Managing the VM](#managing-what-runs-in-the-vm) ·
[Online / offline](#online-offline-isolated) ·
[Capturing](#capturing) ·
[Debugging](#remote-debugging) ·
[IDE debugging guide](docs/ide-debugging.md) ·
[UI testing](#remote-ui-testing) ·
[Test tools](#test-tools) ·
[Hardware](#hardware) ·
[Configuration](#configuration) ·
[Troubleshooting](#troubleshooting) ·
[Reference](#reference)

---

## Requirements

| | |
|---|---|
| Host | x86-64 Linux with KVM (`/dev/kvm` writable by your user) |
| Software | The `winvm` package of nix-config (`pkgs/winvm`): on PATH on the workstations, with QEMU, swtpm, OVMF, FreeRDP, ... ([Installed use](#installed-use-and-where-the-data-lives)) |
| Disk | ~25 GB free per Windows version (base image ~20 GB) plus a few GB per VM |
| RAM | 8 GB for the VM by default (`VM_RAM`) on top of what the host needs |
| Windows host instead? | see [windows-host/](windows-host/README.md) (VirtualBox) |

## Quick start

```sh
winvm status                    # what exists, what's missing, the next command
winvm build                     # Windows 10: install + provision + updates, 1-2 h
winvm start --headless --wait   # boot, wait until Windows answers
winvm ssh                       # PowerShell in the VM
winvm rdp                       # desktop; clipboard; host folder $WINVM_HOME/share = \\tsclient\share
winvm reset                     # back to the freshly built state
```

`build` downloads the Windows ISO if it can. If Microsoft refuses the download,
`build` stops and prints the download page. Save the ISO under the path shown,
then run `build` again ([details](#windows-versions)).

Help: `winvm help`, `winvm <command> --help`. Login in the VM: `dev` / `dev`.

## Installed use and where the data lives

This directory is `pkgs/winvm` in nix-config (moved there from its own
repository with its history, ADR 0006). The package puts the whole tree,
read-only, into the Nix store (`share/winvm`), wraps `winvm` with its tools
and `WINVM_OVMF_DIR`, and installs tab completion for bash and zsh. The
workstations (desktop, laptop) have it on PATH (home-manager,
`home/flodet/_shared/desktop.nix`).

The code never changes at run time. Everything winvm writes or you configure
lives in `WINVM_HOME` (`winvm home` prints it):

| in `WINVM_HOME` | what |
|---|---|
| `state/images/NAME/`, `state/vms/NAME/`, `state/id_ed25519` | base images, VMs, the SSH key |
| `iso/`, `cache/` | installation media, downloaded tools |
| `share/`, `runs/`, `captures/` | RDP share, `winvm run` results, screenshots, pcaps, traces |
| `config.local.env`, `images/NAME.local.env` | your settings |
| `recipes/NAME/` | your own recipes (`winvm recipes new NAME`); a shipped recipe of the same name wins |

- Default: `${XDG_DATA_HOME:-~/.local/share}/winvm`. The first command that
  writes creates it, on btrfs as a subvolume of its own: the hourly `/home`
  snapshots (btrbk) do not contain nested subvolumes, so VM images stay out of
  them. It also gets `chattr +C` (no copy-on-write, the usual setting for VM
  disk images; it only takes on an empty directory). The laptop uses this
  default. Let winvm create it (`winvm recipes new NAME` or the first
  `build`) before you put `config.local.env` there: a directory made with
  `mkdir` is a plain one inside the snapshots (winvm says so).
- desktop: `WINVM_HOME=~/Projects/windows-vm` (home-manager,
  `home/flodet/desktop/default.nix`), the old checkout with its data: on the
  data disk, not snapshotted, erased by a reinstall. The copies of
  `config.env`, `images/*.env`, `provision/` and `recipes/` still lying there
  are ignored; only the local settings are read from it.
- Command-only reads (`help`, `home`, `images`, `list`, `status`, `recipes`,
  `ssh-config`, `completion`) do not create `WINVM_HOME`.

**Changing winvm**: edit it here in nix-config, then try it without switching:

```sh
nix run .#winvm -- status                       # the working tree's winvm, your WINVM_HOME
nix build .#checks.x86_64-linux.scripts         # shellcheck + the no-VM test (test.nix)
WINVM=$(nix build --no-link --print-out-paths .#winvm)/bin/winvm pkgs/winvm/tests/smoke.sh
```

and switch to get it on PATH. Shipped settings (`config.env`, `images/*.env`,
`provision/`, the recipes) change the same way; your own go in `WINVM_HOME`.

`winvm vscode setup` / `rider setup` write store paths into the IDE files
(`lib/ide/dap-pathmap.py`, `windows-host/vs/Winvm.targets`). After an update,
once garbage collection removes the old package, run the setup again.

---

## How it works

```
  iso/win10.iso ──── winvm build ────▶  base image "win10"      state/images/win10/
                    (unattended,        read-only, one per
                     drivers, tools,    Windows version
                     updates)                 │
                                              │ copy-on-write: a VM stores only
                         ┌────────────────────┼──────────────── what it changed
                         ▼                    ▼                    ▼
                    VM "default"          VM "test2"           VM "de"         state/vms/NAME/
                    overlay disk          overlay disk         sealed state (recipe)
                    NVRAM, TPM, ports     NVRAM, TPM, ports      └ overlay disk
```

- **Image**: a Windows version (`win10`, `win11`, ...) installed by `winvm build`.
  It is never modified while VMs use it.
- **VM**: a disk layer on top of an image, plus its own UEFI NVRAM, TPM,
  hardware identity, snapshots and host ports. Without `-n NAME`, every command
  uses the VM `default`.
- **Reset point**: what `winvm reset` returns to. Normally the image. A
  [custom VM](#custom-vms) has its own (`seal`).

### Undo, from coarse to fine

```
  base image ──▶ [sealed state] ──▶ snapshot A ──▶ snapshot B ──▶ now
       ▲               ▲                 ▲
  reset --image      reset         snapshot load A          start --temp: nothing written
```

| you want to... | command | keeps |
|---|---|---|
| throw away everything since the build | `winvm reset` | image (or sealed state) |
| go back to a named checkpoint | `winvm snapshot save X` ... `snapshot load X` | disk, plus RAM + TPM if it was running |
| test without writing anything | `winvm start --temp` or `winvm run --temp` | nothing of the session |
| keep the current state for this VM | `winvm seal` | becomes this VM's reset point |
| keep the current state for all future VMs | `winvm commit` | becomes the new base image |

NVRAM and TPM go with the disk: `reset` restores them, `commit` and `seal`
save them.

---

## Everyday use

```
  winvm start ──▶ test (ssh / rdp / run) ──▶ winvm reset ──┐
       ▲                                                   │
       └───────────────────────────────────────────────────┘
```

```sh
winvm start --wait                 # window on the host (--headless: none)
winvm run ./myapp.exe --flag       # run your build, get exit code + crash analysis
winvm screenshot                   # captures/....png
winvm stop                         # clean shutdown
winvm reset                        # clean again
```

---

## Commands

All commands take `-n NAME` to act on another VM: `winvm -n test2 start`.
Each has `--help`.

| Set up | |
|---|---|
| `fetch [--refresh]` | download ISOs and tools into `iso/` and `cache/` (`build` does this too) |
| `build [--image IMG] [--force] [--headless] [--offline] [--no-updates]` | install Windows → base image |
| `images` | Windows versions, built or not, days left for evaluation editions |
| `completion` | bash completion script (`source <(winvm completion)`) |

| Run | |
|---|---|
| `start [--headless\|--gui] [--wait] [--temp] [--offline] [--image IMG] [--kd] [--gdb]` | boot; the first start creates the VM |
| `stop [--force]` | shut down (ACPI, forced after 3 min) / pull the plug |
| `status [--json]` | what exists, config, state, guest ready?, ports, next step (`--json` for scripts) |
| `list` | all VMs: state, ports, size, reset point |
| `wait [SEC]` | block until SSH answers |

| Undo | |
|---|---|
| `reset [--image]` | back to the reset point (`--image`: to the plain image) |
| `snapshot save\|load\|delete\|list [NAME]` | named checkpoints (with RAM while running) |
| `seal [--yes]` | current state becomes this VM's reset point |
| `commit [--yes]` | current state becomes the base image |
| `destroy [NAME...] [--all] [--yes]` | delete VMs (`--all`: also base images) |

| Custom VMs | |
|---|---|
| `new NAME [--recipe R] [--image IMG] [--offline]` | create a VM, optionally set up by a recipe and sealed |
| `recipes [list \| new NAME]` | list recipes / start a new one from the template |
| `apply RECIPE [--seal] [--offline]` | run a recipe in an existing VM |

| Access | |
|---|---|
| `ssh [COMMAND...]` | PowerShell, or run one command |
| `scp SRC... DST` | copy; `vm:PATH` is a guest path |
| `rdp [FREERDP_ARGS...]` | desktop, clipboard, `share/` as `\\tsclient\share` |
| `ssh-config` | entry for `~/.ssh/config` (VS Code Remote-SSH, plain ssh) |

| Inside the VM | |
|---|---|
| `info` | version, license, uptime, memory, disk, signed-in user, pending restart |
| `ps [FILTER]` / `kill NAME\|PID [--tree]` | processes / end one |
| `service [list\|show\|start\|stop\|restart\|enable\|manual\|disable] [NAME]` | services |
| `apps [FILTER] [--store]` / `apps uninstall NAME` | installed programs / silent uninstall |
| `events [FILTER] [--since 2h] [--errors\|--all] [--log NAME]` | event log |
| `ports` | listening ports with process and service |
| `windows [TITLE] [--all] [--children]` | visible windows and their controls |
| `key KEYS...` | send keys, e.g. `ctrl-alt-delete`, also on the lock screen |
| `reboot [--no-wait]` | restart Windows and wait |

| Test, debug, capture | |
|---|---|
| `run [--dir DIR] [--timeout S] [--no-wait] [--temp] PROGRAM [ARGS]` | run a host program in the VM |
| `crashes [list \| analyze [DUMP]]` | crash dumps, analyzed with WinDbg |
| `debug [info\|vs\|windbg\|stop\|kernel on\|off]` | remote debugging |
| `uitest [info\|start\|stop]` | WinAppDriver for UI automation |
| `screenshot` | PNG of the screen |
| `netcap start\|stop` | network capture (`.pcapng`) |
| `proxy start\|stop` | HTTP(S) through mitmproxy |
| `trace start [--etw] \| stop` | Process Monitor trace |
| `usb [list \| attach VID:PID \| detach VID:PID]` | USB passthrough |

| Develop ([guide](docs/ide-debugging.md)) | |
|---|---|
| `deploy FOLDER [--as APP] [--run\|--service] [--wait] [--args "..."] [--install]` | copy a build to `C:\deploy\APP`, start it on the desktop or as service, optionally waiting for a debugger; `--install`: MSIX |
| `vscode setup SOLUTION [--project A,B] [--remove]` | VS Code configurations: build, copy, debug in the VM |
| `rider setup SOLUTION [--project A,B] [--remove]` / `rider` | Rider run configurations / its attach settings |

---

## Windows versions

```sh
winvm images                        # what's available, built, days left
winvm build --image win11           # build another version
winvm -n win11 start                # its first VM; a VM named like an image uses that image
winvm -n w11b start --image win11   # any other name: say which image
```

| image | edition | ISO | expires |
|---|---|---|---|
| `win10` (default) | Windows 10 22H2 Pro | consumer ISO: auto-download, or [by hand](https://www.microsoft.com/software-download/windows10ISO) → `iso/win10.iso` | no (not activated) |
| `win11` | Windows 11 Pro | consumer ISO, [by hand](https://www.microsoft.com/software-download/windows11) ("English (United Kingdom)") → `iso/win11-pro.iso` | no (not activated) |
| `win11-ltsc` | Windows 11 Enterprise LTSC 2024 | Evaluation Center, auto-download | 90 days |
| `server2025` | Server 2025 Standard, Desktop Experience | Evaluation Center, auto-download | 180 days |

- **Consumer ISOs** go through Microsoft's download API (like Rufus/Fido). Its
  bot protection often refuses, depending on IP or VPN. When it does, `build`
  prints the page to download from manually. `winvm status` shows whether the
  ISO is present.
- **Updates**: builds install all Windows updates (`--no-updates` or
  `BUILD_UPDATES=0` skips them).
- **Expiry**: evaluation editions shut down every hour once expired.
  `images`/`status` show the days left, `start` warns 14 days ahead. A rebuild
  starts a new evaluation period:
  `winvm build --force --image win11-ltsc`. Note: **this deletes the image's VMs**.
  Recipe VMs can be recreated with the commands the build prints.
- **Not activated**: generic keys install without activation. Fine for testing;
  some personalization settings stay locked. Home editions don't work (no RDP
  server).
- **Add a version**: copy a file in `images/`. Per-image overrides (your own
  key, ISO checksum) go in `images/NAME.local.env`.
- **Default version**: `IMAGE=win11` in `config.local.env`.

---

## Several VMs

```sh
winvm -n test2 start --headless   # created from the base image on first start
winvm list                        # NAME, IMAGE, STATE, SSH, RDP, OVERLAY, RESETS TO
winvm destroy test2               # the base image stays
```

Or set `WINVM_VM=test2` in your shell instead of passing `-n` every time.

Each VM gets a slot number; its ports are the configured port + slot:

```
  host 127.0.0.1                         guest
  ─────────────────────────────          ──────────────────────
  VM default (slot 0)   :2222   ───────▶  :22    SSH
                        :33890  ───────▶  :3389  RDP
  VM test2   (slot 1)   :2223   ───────▶  :22
                        :33891  ───────▶  :3389
  ...                                    guest sees the host as 10.0.2.2
```

`winvm status` and `winvm list` show the actual ports.

- VMs of one image are clones with the same computer name, SID and TPM
  endorsement key. That's fine for isolated tests, but they can't join the same domain.
- VMs reach each other through the host: from VM A, `10.0.2.2:<B's port>`
  (e.g. a debugger VM attaching to a target VM).
- `commit` only works while no other VM uses the same image.

---

## Custom VMs

For tests that need a specially prepared VM (German formats, non-admin user,
150 % scaling, slow offline PC, old app version for upgrade tests). `reset`
returns to the prepared state, not the plain image.

```sh
winvm recipes                          # german-formats, standard-user, hidpi, low-spec-offline, vs-deploy, uwp-build
winvm new de --recipe german-formats   # create + set up + seal
winvm -n de start                      # ... test ...
winvm -n de reset                      # back to the German setup
winvm recipes new my-test              # write your own: recipes/my-test/
```

Tutorial and recipe format: **[docs/custom-vms.md](docs/custom-vms.md)**.

---

## Running and testing apps

Build on Linux, run in Windows, e.g. with `zig cc -target x86_64-windows-gnu`,
`cargo-xwin`, `pkgsCross.mingwW64` or `dotnet publish -r win-x64`.

```sh
winvm run ./app.exe --some-arg      # copy in, run on the desktop, wait
winvm run --dir build/ bin/app.exe  # copy the whole folder (DLLs, .pdb, data)
winvm run --temp ./installer.exe    # in a throwaway session
winvm run --timeout 30 ./app.exe    # kill after 30 s
```

```
  host                                   VM
  ./app.exe ───── copy ────────────────▶ C:\winvm\runs\ID\app.exe  runs on the desktop
  runs/VM-TIME/ ◀── exit code, stdout/stderr, crash dump, WinDbg analysis
```

```
exit code : -1073741819 (0xC0000005) — access violation
crash dump: crash.exe.4160.dmp
      SYMBOL_NAME:  crash!parse_config+d
      FAILURE_BUCKET_ID:  INVALID_POINTER_WRITE_c0000005_crash.exe!parse_config
      stack:
        crash!parse_config+0xd
        crash!main+0x3e
```

- Crash codes are decoded (access violation, missing DLL, stack overflow, ...).
  With a `.pdb` next to the program, the stack has function names.
- `winvm run` exits with the program's exit status, so it works in scripts and CI.
- `winvm crashes` lists and analyzes dumps of anything else that crashed
  (every crash in the VM is dumped to `C:\dumps`).
- Other ways to move files: `winvm scp ./f vm:C:/t/`, or `\\tsclient\share` in RDP.

---

## Managing what runs in the VM

Quick looks and changes without opening the desktop:

```sh
winvm info                        # version + build, license, uptime, memory, disk, user, pending restart
winvm ps myapp                    # processes: memory, CPU, user, window title
winvm kill myapp --tree           # end it and its children
winvm service show MyAppSvc       # binary, account, dependencies, recovery, recent crashes
winvm service restart MyAppSvc    # also start, stop, enable, manual, disable
winvm apps myapp                  # installed programs (--store: MSIX too)
winvm apps uninstall "MyApp"      # silent (MSI or the app's quiet uninstaller)
winvm events --since 2h myapp     # warnings/errors from System + Application
winvm ports                       # listening ports with process and service
winvm windows --children          # windows and controls: title, class, process, position
winvm key ctrl-alt-delete         # lock screen, secure desktop, hung UI
winvm reboot                      # restart Windows, wait until it's back
```

---

## Online, offline, isolated

| when | online (default) | offline |
|---|---|---|
| running | `VM_INTERNET=1`: NAT internet | `VM_INTERNET=0` or `start --offline`: no network at all. SSH/RDP from the host still work |
| building | `BUILD_INTERNET=1` | `build --offline`: like an air-gapped PC, run `winvm fetch` first |

An offline build differs as follows (also printed when the build starts):

- no Chocolatey packages (`provision/packages.txt`)
- OpenSSH from the Win32-OpenSSH MSI in `cache/` instead of Windows Update
- optional features only if their payload is on the ISO (`sources\sxs`, e.g. .NET 3.5)
- no updates: Windows, Defender signatures and root certificates stay at the ISO's level

---

## Capturing

Results go to `captures/`.

| command | result |
|---|---|
| `winvm screenshot` | PNG of the screen |
| `winvm netcap start` ... `stop` | all VM traffic as `.pcapng`. In Wireshark, `!(tcp.port == 22)` hides winvm's own SSH |
| `winvm proxy start` ... `stop` | HTTP(S) through mitmproxy with a live web UI. The VM trusts its CA while active |
| `winvm trace start [--etw]` ... `stop` | Process Monitor `.pml` + `.csv` (+ ETW `.etl`) |

---

## Remote debugging

`winvm debug` prints the exact connection strings for the current VM.

| what | how |
|---|---|
| VS Code, from this host | `winvm vscode setup SOLUTION` (needs the recipe `vs-deploy`): F5 builds for Windows, copies into the VM and debugs it there over SSH ([guide](docs/ide-debugging.md)) |
| VS Code, inside the VM | `winvm ssh-config >> ~/.ssh/config`, then Remote-SSH to `winvm` |
| Rider, from this host | `winvm rider setup SOLUTION` + Attach to Remote Process over SSH ([guide](docs/ide-debugging.md#rider)) |
| Visual Studio 2026 | `winvm debug vs`, attach to `127.0.0.1:40260` (connection type *Remote (Windows - No Authentication)*) |
| WinDbg, user mode | `winvm debug windbg`, process server `tcp:Port=50050,Server=127.0.0.1` |
| WinDbg, kernel | `winvm debug kernel on`, `winvm start --kd`, `windbg -k com:ipport=50150,port=127.0.0.1`. Needs `SECURE_BOOT=0` or `FIRMWARE=bios` |
| whole VM / firmware | `winvm start --gdb`, `gdb -ex 'target remote 127.0.0.1:12340'` |

Visual Studio and WinDbg are Windows programs. Run them in a second VM
(`winvm -n dbg start`, connect to `10.0.2.2:PORT`) or on a Windows PC through
`ssh -L PORT:127.0.0.1:PORT you@this-host`.

### VS Code and Rider from this host

Build on Linux, run and debug in the VM: WPF, WinForms, console apps and
services from VS Code or Rider, packaged WinUI 3 / MAUI apps by installing a
package and attaching. The VM needs the recipe `vs-deploy` once (`winvm apply
vs-deploy --seal`). **Full guide, incl. Visual Studio on a Windows host and
troubleshooting: [docs/ide-debugging.md](docs/ide-debugging.md).**

```sh
winvm vscode setup MySolution.sln     # VS Code: F5 builds, copies, starts in the VM, debugs (--remove: undo)
winvm rider setup MySolution.sln      # Rider: run configurations, then Attach to Remote Process
winvm rider                           # the SSH settings for Rider's attach dialog
winvm deploy bin/Debug/net10.0/win-x64 --as MyApp --run --wait   # by hand: start, wait for a debugger
```

In VS Code, *Run and Debug* then lists per app: **winvm VM: APP** (console
apps), **...on the VM desktop** (GUI apps), **...as Windows service** and
**attach APP**; all of them stop at breakpoints from `Main` on. Rider: run
*winvm VM: APP on the VM desktop, waiting for the debugger*, then *Attach to
Remote Process* > `dev@127.0.0.1:PORT` > the app.

Tested 2026-11-05 on this host (NixOS): VS Code 1.140 with C# 2.160 (launch,
desktop app, service, breakpoints) and Rider 2026.2 (attach, breakpoints in
`Main` with `--wait`, services); `tests/smoke.sh` covers `deploy`, `--wait`
and both `setup` commands.

---

## Remote UI testing

```
  host: Python/C#/Java test  ──WebDriver──▶  127.0.0.1:47230  ──▶  WinAppDriver in the VM ──▶ your app
```

```sh
winvm uitest start                 # starts WinAppDriver on the VM's desktop, prints examples
pip install Appium-Python-Client
python examples/uitest.py          # opens Notepad, types, reads back, takes a screenshot
```

- To find element names and AutomationIds, use Accessibility Insights or
  FlaUInspect in the VM, or `winvm ssh "Get-Window -Children"`.
- WinAppDriver 1.2 speaks the old JSON Wire Protocol. The `WinAppDriver` class
  in `examples/uitest.py` adapts current Appium/Selenium clients to it.

---

## Test tools

Installed in `C:\Tools`, on `PATH`, and in the Start menu and desktop folder
"Test Tools". The list is in `provision/tools.txt`. Tools you add there are
installed by the next `build --force`.

| area | tools |
|---|---|
| file types, URL protocols, default apps | FileTypesMan, URLProtocolView, OpenWithView |
| shell extensions, context menus | ShellExView, ShellMenuView |
| windows, UI Automation tree | GUIPropView, WinLister, Accessibility Insights, FlaUInspect |
| scripted UI actions | AutoHotkey v2 |
| processes, handles, DLLs | Process Explorer, System Informer, Handle, ListDLLs, Dependencies |
| services and drivers | ServiWin, PsService, Autoruns |
| file / registry / network activity | Process Monitor, ProcessActivityView, TCPView, RegScanner |
| what an installer changed | FolderChangesView, RegistryChangesView, InstalledAppView, Autoruns |
| robustness | TestLimit (exhaust memory/handles), clumsy (packet loss, latency) |
| binaries, API calls | PE-bear, Detect It Easy, API Monitor, Sigcheck |
| permissions, kernel objects | AccessChk, WinObj |
| crashes, logs, timeline | BlueScreenView, FullEventLogView, LastActivityView |
| debugging | x64dbg, WinDbg (cdb, kd, dbgsrv), VS 2026 remote debugger, DebugView, VMMap, RAMMap |
| .NET | dnSpyEx |
| UI automation | WinAppDriver |
| finding files | Everything |

The PowerShell module `WinvmTest` is loaded in every session, including SSH:

```powershell
Get-FileHandler .pdf, .html                    # effective handler, incl. the user's choice
Get-UrlHandler mailto; Get-UrlHandler -All
Invoke-Handler https://example.com             # open like a click, report what started
Invoke-Handler C:\t\a.pdf -Expect msedge.exe   # fail if that app didn't start
Get-Window -Process notepad -Children          # HWND, class, style, position
Start-Interactive notepad.exe                  # start on the desktop, also from SSH
Invoke-Interactive { Get-Clipboard }           # run on the desktop, get the output
Get-Crash                                      # recent dumps + crash events
```

From the host: `winvm ssh "Invoke-Handler https://example.com"`.

---

## Hardware

| | |
|---|---|
| Sound | Intel HD Audio → host PipeWire. `AUDIO=pipewire\|pa\|alsa\|none` |
| USB | `winvm usb list`, `winvm usb attach VID:PID`. `USB_DEVICES="VID:PID ..."` attaches at every start. If your user can't access the device, `attach` prints the udev rule |
| Graphics | standard VGA, no 3D acceleration. DirectX/OpenGL apps use Windows' software renderer (slow, but they run) |

RAM snapshots only load with the same sound/USB setup they were saved with.

---

## Configuration

Defaults: `config.env` (in the package). Your overrides: `$WINVM_HOME/config.local.env`.

```sh
# $WINVM_HOME/config.local.env
IMAGE="win11"                         # default Windows version
VM_RAM="12G"; VM_CPUS=6
WIN_INPUT_LOCALE="de-DE"              # keyboard layout
WIN_TIMEZONE="W. Europe Standard Time"
DISPLAY_MODE="none"                   # always headless (gtk | sdl | none)
```

| what changes | takes effect |
|---|---|
| `VM_RAM`, `VM_CPUS`, `VM_INTERNET`, `AUDIO`, `USB_DEVICES`, `DISPLAY_MODE` | next `start` |
| one VM only | `state/vms/NAME/vm.env` (same variables), next `start` |
| locale, user, edition, `FIRMWARE`, anything in `provision/` | `winvm build --force` |
| quick one-off change to the image | install it in the VM, then `winvm commit` |

What the build installs (`provision/`):

| file | |
|---|---|
| `tools.txt` | test/debug tools, downloaded on the host |
| `packages.txt` | Chocolatey packages (online builds only) |
| `remove-apps.txt` | preinstalled apps to remove (`DEBLOAT=1`). Store, winget, Photos, Calculator stay |
| `features.txt` | optional features (Sandbox, Hyper-V, WSL, .NET 3.5, ...). Hypervisor features run nested |
| `custom.ps1` | your own steps; `$Online` tells you whether the build has network |

---

## Troubleshooting

Start with `winvm status`: it lists problems and the next command.

| symptom | cause / fix |
|---|---|
| `build`: ISO download refused | Microsoft's bot protection. Download from the printed page, save under the path shown, run `build` again |
| `/dev/kvm not accessible` | enable virtualization in the BIOS/UEFI; add your user to the `kvm` group |
| `qemu-system-x86_64 not found` | run the packaged winvm (`nix run .#winvm` in nix-config), not the script itself |
| `status`: guest "not answering SSH yet" | still booting or installing updates: `winvm wait`. Hung? `winvm screenshot` |
| build fails | the error is printed; install log: `state/images/IMG/install-serial.log`, provisioning log in the guest: `C:\winvm\provision.log`. Rerun `winvm build --image IMG` (starts over) |
| evaluation expired (shuts down hourly) | `winvm build --force --image IMG` (deletes that image's VMs) |
| low disk space | `winvm destroy NAME` for unused VMs; `winvm destroy --all` removes everything incl. base images |
| RAM snapshot won't load | sound/USB setup differs from when it was saved |
| wrong keyboard layout | `WIN_INPUT_LOCALE` in `config.local.env` + rebuild, or a recipe like `german-formats` |

---

## Reference

**Directory layout**

```
# the package (this directory, read-only in the store)
config.env                     default settings
images/NAME.env                Windows versions
provision/                     what the build installs
recipes/                       custom VM recipes
completions/winvm.bash         tab completion
tests/smoke.sh                 smoke test of winvm itself
default.nix, test.nix          the Nix package and its no-VM test
windows-host/                  VirtualBox version for Windows hosts

# WINVM_HOME (winvm home)
config.local.env               your settings
images/NAME.local.env          your settings for one image
recipes/NAME/                  your recipes
iso/                           installation media
cache/                         downloaded tools
state/images/NAME/             base images
state/vms/NAME/                VMs: disk, NVRAM, TPM, vm.env
runs/                          winvm run results
captures/                      screenshots, pcaps, traces
share/                         \\tsclient\share during RDP
```

**Security and identity**

- Login `dev` / `dev`. SSH key: `state/id_ed25519`.
- All forwarded ports listen on 127.0.0.1 only (the VS debugger runs without
  authentication).
- Every VM gets its own SMBIOS serial and UUID (`state/vms/NAME/smbios`).
  QEMU's default identity is registered with some organization's Windows
  Autopilot and would enroll the VM into their MDM. The build fails if an
  Autopilot profile is ever applied.

**Test-friendly Windows settings**: crash dumps of every process in
`C:\dumps`, developer mode, long paths, no fast startup, verbose boot/logon
messages, automatic Windows/Store updates off (`DISABLE_WINDOWS_UPDATE`), Defender on but not uploading samples.

**Testing winvm itself**: `tests/smoke.sh [--image IMG] [--keep]` runs the
everyday commands on a throwaway VM `smoke-test` (4 GB RAM): status, start,
ssh/scp, `run` with exit code, output and a real crash, management commands,
live snapshots, stop/reset. It needs a built image, takes about 5 minutes and
exits non-zero if any check fails. Run it after changing `winvm`; it tests the
winvm in `$WINVM`, else the one on PATH (command above).

**Tab completion**: installed with the package for bash and zsh (`_winvm_zsh`,
through zsh's `bashcompinit`). For a winvm from elsewhere, add
`source <(winvm completion)` to `~/.bashrc`. For zsh, run
`autoload -U +X bashcompinit && bashcompinit` first.
