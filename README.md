# winvm — clean, reproducible Windows test VMs

Fully scripted Windows test VMs on plain QEMU/KVM (no libvirt, runs as your
user, everything lives in this directory) — to build, run, debug and test
Windows apps from Linux/NixOS.

- **Windows 10, Windows 11, Windows 11 LTSC, Windows Server 2025**: unattended
  install (`autounattend.xml` + VirtIO drivers, no clicks), online or
  **offline** like an isolated/air-gapped machine. Windows 11 and Server come
  from Microsoft's Evaluation Center and download automatically.
- **Run apps from the host**: `winvm run ./app.exe` copies, runs and reports
  exit code, output and a WinDbg crash analysis.
- **Real-PC firmware**: UEFI with Secure Boot (Microsoft keys) and a TPM 2.0
  (swtpm, with EK certificate), so BitLocker, VBS/Credential Guard, Windows
  Hello, measured boot etc. can be tested. `FIRMWARE=bios` for the old layout.
- **Clean Windows**: consumer apps removed, no ads/suggestions/auto-installed
  "suggested" apps, no Bing/Cortana in Start, no News & Interests, no OneDrive,
  minimal telemetry, empty Start menu. Applied to the default profile during
  Setup, so test accounts you create later are clean too.
- **Test tools**: handlers (file types, URL protocols, "Open with", shell
  extensions, context menus), processes/handles/DLLs, registry and file
  activity, autostarts — see [Test tools](#test-tools).
- **Remote debugging**: Visual Studio 2026 remote debugger, WinDbg process
  server, kernel debugging over serial, QEMU gdb stub, VS Code via SSH.
- **Remote UI testing**: WinAppDriver (WebDriver for desktop apps) — drive the
  VM's apps from the host with Selenium/Appium clients.
- **Capture to the host**: screenshots, network traffic as `.pcapng`, HTTPS
  through mitmproxy, Process Monitor/ETW traces.
- **Hardware**: sound through PipeWire, USB device passthrough.
- **Test-friendly settings**: crash dumps of every crashing process in
  `C:\dumps`, developer mode, long paths, no fast startup, verbose boot/logon
  status, Defender on but never uploading samples.
- **Undo**: the provisioned install is a read-only base image; VMs are
  copy-on-write overlays. `reset` in a second, snapshots with RAM, throwaway
  sessions.
- **Several VMs** of one or several Windows versions when you need them, zero
  extra steps when you don't.

## Quick start

```sh
nix develop                     # qemu, swtpm, OVMF, xorriso, freerdp, ...
winvm build                     # downloads ISOs + tools if missing, then 20-60 min
winvm start --headless --wait
winvm ssh                       # PowerShell
winvm rdp                       # desktop, clipboard, \\tsclient\share = ./share
```

Every command explains itself: `winvm help`, `winvm <command> --help`.

## Commands

| command | |
|---|---|
| `fetch [--refresh]` | download ISOs and tools into `iso/` and `cache/` |
| `build [--image IMG] [--force] [--headless] [--offline]` | install + provision → clean base image |
| `start [--headless\|--gui] [--wait] [--temp] [--offline] [--image IMG] [--kd] [--gdb]` | boot (creates the VM on first start) |
| `stop [--force]` | ACPI shutdown / hard stop |
| `status`, `list`, `images` | this VM / all VMs / Windows versions |
| `reset` | back to the clean base image |
| `snapshot save\|load\|delete\|list NAME` | live (with RAM + TPM) when running, disk-only when stopped |
| `commit` | make the current state the new clean base |
| `destroy [NAME...] [--all]` | delete VMs, also incomplete ones (or everything) |
| `ssh`, `scp SRC vm:DST`, `rdp`, `wait` | use the VM |
| `ssh-config` | `~/.ssh/config` entry (VS Code Remote-SSH etc.) |
| `run [--dir DIR] [--timeout S] [--temp] PROGRAM [ARGS]` | run an app, collect exit code/output/crash analysis |
| `crashes [list\|analyze [DUMP]]` | crash dumps in the VM, analyzed |
| `debug [vs\|windbg\|stop\|kernel on\|off]` | remote debugging, see below |
| `uitest [start\|stop]` | remote UI test automation, see below |
| `screenshot`, `netcap start\|stop`, `proxy start\|stop`, `trace start\|stop` | capture, see below |
| `usb [list\|attach\|detach VID:PID]` | USB passthrough |

Three levels of "undo", from coarse to fine:

1. `winvm reset` — everything since the build (or the last `commit`).
2. `winvm snapshot load NAME` — named checkpoints on top of the base.
3. `winvm start --temp` — a throwaway session; nothing is written.

## Windows versions

```sh
winvm images                      # what's available and built
winvm build --image win11         # downloads the ISO, ~30 min
winvm -n win11 start              # the image's VM is named like it
winvm -n w11b start --image win11 # more VMs of the same version
```

| image | what | notes |
|---|---|---|
| `win10` (default) | Windows 10 22H2 Pro | consumer ISO (see below), generic key, not activated |
| `win11` | Windows 11 Enterprise | 90-day evaluation |
| `win11-ltsc` | Windows 11 Enterprise LTSC 2024 | evaluation; no Store, few inbox apps |
| `server2025` | Windows Server 2025 Standard, Desktop Experience | 180-day evaluation, English only |

Each version is a file in `images/`; add your own the same way. When an
evaluation expires, `winvm build --force --image NAME` gives you a fresh one.
`IMAGE` in `config.local.env` changes the default version.

## Several VMs

Without `-n` everything acts on the VM `default`. Add `-n NAME` (or set
`WINVM_VM=NAME`) for more:

```sh
winvm -n test2 start --headless   # created from the base image on first start
winvm list                        # NAME, state, SSH/RDP ports
winvm destroy test2               # base image stays
```

Each VM has its own disk overlay, NVRAM, TPM, hardware identity, snapshots
and ports (configured port + slot number, e.g. SSH 2222, 2223, ...). VMs of
one version are clones: same computer name, SID and TPM endorsement key — fine
for isolated testing, not for joining them to one domain. VMs can reach each
other's forwarded ports through the host at `10.0.2.2` (e.g. a debugger VM
against a target VM). `commit` is only allowed while no other VM uses the same
image.

## Online, offline, isolated

- **Runtime**: `VM_INTERNET=1` (default) gives the guest normal NAT internet,
  `VM_INTERNET=0` or `start --offline` none at all — SSH/RDP from the host keep
  working. `start --offline` prints what stops working.
- **Build**: `build --offline` (or `BUILD_INTERNET=0`) installs with no network,
  like an air-gapped machine. Everything comes from the ISO and `cache/`, which
  `winvm fetch` fills on the host beforehand. Restrictions, also printed when
  the build starts:
  - Chocolatey / `provision/packages.txt` are skipped.
  - OpenSSH is the Win32-OpenSSH MSI from `cache/` instead of the Windows
    capability (which comes from Windows Update).
  - Optional features only get payloads from the ISO (`sources\sxs`, e.g. .NET 3.5).
  - No updates: Windows, Defender signatures and root certificates stay at the
    ISO's level.
- **ISO download**: missing ISOs are downloaded by `fetch`/`build`. Windows 11
  and Server come straight from the Evaluation Center. Windows 10 goes through
  Microsoft's consumer download API (like Rufus/Fido) in `WIN_ISO_LANGUAGE`;
  Microsoft's bot protection sometimes rejects that (IP/VPN dependent, often
  temporary), and winvm then tells you to download it by hand.

## Running and testing apps

Build on Linux, run in Windows — e.g. with `zig cc -target x86_64-windows-gnu`,
`cargo-xwin`, `pkgsCross.mingwW64` or `dotnet publish -r win-x64`:

```sh
winvm run ./app.exe --some-arg      # copy in, run on the desktop, wait
winvm run --dir build/ bin/app.exe  # the whole folder (DLLs, .pdb, data)
winvm run --temp ./installer.exe    # in a throwaway session: discarded afterwards
winvm run --timeout 30 ./app.exe    # kill after 30 s
```

It reports the exit code (crash codes decoded: access violation, missing DLL,
stack overflow, …), the last lines of stdout/stderr, and for a crash WinDbg's
analysis — exception, faulting function and stack, with your `.pdb` symbols:

```
exit code : -1073741819 (0xC0000005) — access violation
crash dump: crash.exe.4160.dmp
      SYMBOL_NAME:  crash!parse_config+d
      FAILURE_BUCKET_ID:  INVALID_POINTER_WRITE_c0000005_crash.exe!parse_config
      stack:
        crash!parse_config+0xd
        crash!main+0x3e
```

Everything (output, dumps, analysis) lands in `runs/`. The exit status is the
program's, so `winvm run` works in scripts and CI. `winvm crashes` lists and
analyzes dumps of anything else that crashed in the VM. Files to and from the
VM otherwise: `winvm scp`, or `\\tsclient\share` during an RDP session.

## Capturing

| command | result in `captures/` |
|---|---|
| `winvm screenshot` | PNG of the VM's screen |
| `winvm netcap start` … `stop` | all network traffic as `.pcapng` (Wireshark/tshark; filter `!(tcp.port == 22)` hides winvm's SSH) |
| `winvm proxy start` … `stop` | HTTP(S) through mitmproxy with live web UI; its CA is trusted in the VM while active |
| `winvm trace start [--etw]` … `stop` | Process Monitor trace as `.pml` + `.csv` (+ ETW `.etl`) |

## Hardware

- **Sound**: an Intel HD Audio card played through PipeWire (`AUDIO` in
  `config.env`: `pipewire`, `pa`, `alsa` or `none`).
- **USB**: `winvm usb list`, `winvm usb attach VID:PID` passes a host device to
  the running VM; `USB_DEVICES` attaches some at every start. On NixOS your user
  needs access to the device — `attach` prints the udev rule if not.
- **Graphics**: standard VGA, no 3D acceleration; DirectX/OpenGL apps use
  Windows' software renderer (slow, but they run).
- RAM snapshots only load with the same sound/USB setup they were saved with.

## Test tools

Downloaded on the host into `cache/` (`provision/tools.txt`), installed in
`C:\Tools`, on PATH, and in the Start menu folder / desktop link "Test Tools":

| area | tools |
|---|---|
| file types, URL protocols, default apps | FileTypesMan, URLProtocolView, OpenWithView |
| shell extensions, context menus | ShellExView, ShellMenuView |
| windows (HWND, class, styles, owner), UI Automation tree | GUIPropView, WinLister, Accessibility Insights |
| processes, handles, DLLs, services | Process Explorer, System Informer, Handle, ListDLLs, Dependencies |
| file/registry/network activity | Process Monitor, ProcessActivityView, TCPView, RegScanner |
| what an installer changed | FolderChangesView, InstalledAppView, Autoruns |
| binaries, API calls | PE-bear, Detect It Easy, API Monitor, Sigcheck |
| permissions, kernel objects | AccessChk, WinObj |
| crashes, logs, timeline | BlueScreenView, FullEventLogView, LastActivityView, `C:\dumps` |
| debugging | x64dbg, WinDbg (+ cdb, kd, dbgsrv), VS 2026 remote debugger, DebugView, VMMap, RAMMap |
| UI automation | WinAppDriver (see below) |
| finding files | Everything |

Plus the PowerShell module `WinvmTest` (loaded automatically, also over SSH):

```powershell
Get-FileHandler .pdf, .html          # effective handler incl. the user's choice
Get-Window -Process notepad -Children # windows/controls: HWND, class, style, position
Invoke-Interactive { Get-Clipboard }  # run on the desktop, get the output back
Get-UrlHandler mailto; Get-UrlHandler -All
Invoke-Handler https://example.com   # open like a click, report what got started
Invoke-Handler C:\t\a.pdf -Expect msedge.exe   # fails if that app didn't start
Start-Interactive notepad.exe        # run on the desktop, also from SSH
Get-Crash                            # recent dumps in C:\dumps + crash events
```

e.g. `winvm ssh "Invoke-Handler https://example.com"`.

## Remote debugging

`winvm debug` prints the exact connection strings for the current VM.

| what | how |
|---|---|
| VS Code from this host | `winvm ssh-config >> ~/.ssh/config`, Remote-SSH to `winvm`, debug inside |
| Visual Studio 2026 | `winvm debug vs`, attach to `127.0.0.1:40260` (Remote, no authentication) |
| WinDbg user mode | `winvm debug windbg`, connect to process server `tcp:Port=50050,Server=127.0.0.1` |
| WinDbg kernel | `winvm debug kernel on`, `winvm start --kd`, then `windbg -k com:ipport=50150,port=127.0.0.1` — needs `SECURE_BOOT=0` or `FIRMWARE=bios` |
| whole VM / firmware | `winvm start --gdb`, `gdb -ex 'target remote 127.0.0.1:12340'` |

All ports listen on 127.0.0.1 only (msvsmon runs without authentication).
Visual Studio and WinDbg need Windows: run them in a second VM
(`winvm -n dbg start`, then connect to `10.0.2.2:PORT`) or tunnel from a
Windows PC with `ssh -L PORT:127.0.0.1:PORT you@this-host`.

## Remote UI testing

`winvm uitest start` runs WinAppDriver on the VM's desktop and forwards it to
`http://127.0.0.1:47230`. Any WebDriver/Appium client can then launch apps in
the VM and click, type, read and screenshot them; `winvm uitest` prints
ready-to-run examples. Find element names and AutomationIds with Accessibility
Insights in the VM or `winvm ssh "Get-Window -Children"`.

```sh
pip install Appium-Python-Client
python examples/uitest.py      # opens Notepad in the VM, types, reads back, screenshots
```

WinAppDriver 1.2 speaks the older JSON Wire Protocol; the small `WinAppDriver`
class in `examples/uitest.py` adapts current Appium/Selenium clients to it.

## Configuration

Defaults are in `config.env`; put overrides in `config.local.env` (gitignored).
Things you will likely want:

```sh
WIN_INPUT_LOCALE="de-DE"              # keyboard layout
WIN_TIMEZONE="W. Europe Standard Time"
VM_RAM="12G"; VM_CPUS=6
WIN_ISO_SHA256="..."                  # pin the exact ISO for reproducibility
```

What gets installed, removed and enabled during Setup:

- `provision/tools.txt` — test/debug tools (downloaded by the host).
- `provision/packages.txt` — Chocolatey packages (online builds only).
- `provision/remove-apps.txt` — preinstalled apps to remove (`DEBLOAT=1`).
  Store, winget, Photos, Calculator etc. are kept.
- `provision/features.txt` — optional Windows features (Windows Sandbox,
  Hyper-V, WSL, .NET 3.5, ...). Hypervisor-based ones run nested.
- `provision/custom.ps1` — your own steps (`$Online` tells you the build mode).

Changing `config.env` or anything in `provision/` needs
`winvm build --force`. For a quick change, install it in the running VM and
`winvm commit` instead.

## Notes

- Default credentials are `dev` / `dev`. All forwarded ports listen on
  127.0.0.1 only. The SSH key is generated in `state/id_ed25519`.
- Every VM gets its own hardware identity (SMBIOS serial number + UUID, in
  `state/vms/NAME/smbios`). QEMU's default identity is the same for every VM,
  and some organization has registered it with Windows Autopilot: an online
  install then receives *their* device profile (forced MDM enrollment, device
  rename to `CSQ-…`, full telemetry). The build also fails if an Autopilot
  profile ever gets applied.
- Generic product keys install Windows **without activating it**. That's fine
  for testing; some personalization settings stay locked.
- Use Pro or Enterprise: Home has no RDP server.
- UEFI NVRAM and TPM state are part of each VM like its disk: `reset` restores
  them, `commit` saves them, live snapshots include the TPM, `--temp` works on
  a throwaway copy.
- Provisioning progress is shown during `build`; in the guest it is in
  `C:\winvm\provision.log`.
- Directory layout: `iso/` installation media, `cache/` downloaded tools,
  `images/` Windows versions, `state/images/NAME/` their base images,
  `state/vms/NAME/` per VM, `runs/` and `captures/` results, `share/` RDP
  shared folder.
