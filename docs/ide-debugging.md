# Debugging your apps in a winvm VM: Visual Studio, VS Code, Rider

Build on your machine, run in a clean Windows VM, debug with your usual IDE.
This page covers both hosts:

- **Linux host** (QEMU): `../winvm`
- **Windows host** (VirtualBox): `..\windows-host\winvm.ps1` — same commands,
  PowerShell-style options (`-Run` instead of `--run`, `-Name dev` instead of `-n dev`)

Contents: [What works where](#what-works-where) ·
[One-time setup](#one-time-setup) · [deploy](#deploy-copy-and-start-an-app) ·
[Visual Studio](#visual-studio-windows-host) · [VS Code](#vs-code) ·
[Rider](#rider) · [Packaged apps](#packaged-apps-msix-winui-3-maui) ·
[How it works](#how-it-works) · [Troubleshooting](#troubleshooting)

## What works where

| App type | Visual Studio 2026 (Windows host) | VS Code (Windows or Linux host) | Rider (Windows or Linux host) |
|---|---|---|---|
| WPF, WinForms, unpackaged WinUI 3 / MAUI | F5 | F5 (`...on the VM desktop`) | run configuration + attach |
| Console app | F5 | F5 | run configuration + attach |
| Windows service (worker) | attach | F5 (`...as Windows service`) | run configuration + attach |
| Packaged WinUI 3 / MAUI (MSIX) | F5 | attach after `deploy --install --run` | attach after `deploy --install --run` |
| Classic UWP | F5 | – | – |

Building on a **Linux host**: WPF, WinForms, console apps and services build
with `dotnet build -r win-x64 -p:EnableWindowsTargeting=true` (the generated
configurations do that). WinUI 3, MAUI and UWP need Windows to build; their
packages can still be installed from Linux with `deploy --install`.

"F5" means: build, copy into the VM, start there, debugger attached, from the
first line of `Main` (breakpoints in startup code work). "Attach" means the app
runs in the VM and you attach to it; with `--wait` it waits for you first.

Not supported: old-style (non-SDK) .NET Framework projects; Hot Reload and
Edit and Continue into the VM.

## One-time setup

1. A VM with the recipe **vs-deploy**:

   ```sh
   winvm new dev --recipe vs-deploy             # Linux; or on an existing VM: winvm apply vs-deploy --seal
   .\winvm.ps1 new dev -Recipe vs-deploy        # Windows host
   ```

   It installs the VS remote debugger (msvsmon), vsdbg (VS Code's debugger),
   the .NET 10 desktop runtime, the Windows App SDK runtimes, turns on
   Developer Mode and makes cmd.exe the SSH login shell (Rider needs that;
   `winvm ssh` still opens PowerShell).

2. Per solution, once, for the IDE you use (all of them can be used side by side):

   ```sh
   winvm -n dev vscode setup MySolution.sln     # VS Code: .vscode/launch.json + tasks.json
   winvm -n dev rider setup MySolution.sln      # Rider:   .run/winvm-dev-*.run.xml
   .\winvm.ps1 -Name dev vs setup MySolution.sln   # Visual Studio (Windows host only)
   ```

   Each adds only its own entries (named `winvm VM: ...`), leaves everything
   else in the files byte for byte as it was, and `--remove` / `-Remove` takes
   exactly that out again. `--project A,B` limits it to some projects.

Linux host requirements: `pwsh` and `python3` (both in `nix develop`), a .NET SDK
for building. On NixOS, run VS Code as `vscode-fhs` (the C# extension needs the
usual Linux libraries).

## deploy: copy and start an app

Every IDE integration ends in `deploy`; it is also useful by hand:

```sh
winvm deploy FOLDER --as MyApp                  # copy a build output to C:\deploy\MyApp
winvm deploy FOLDER --as MyApp --run            # ... and start it on the VM's desktop
winvm deploy FOLDER --as MyApp --run --wait     # ... started, but waiting for a debugger before Main
winvm deploy FOLDER --as MyApp --service        # ... as Windows service winvm-MyApp (LocalSystem)
winvm deploy FOLDER --as MyApp --service --wait # ... waiting up to 25 s for a debugger
winvm deploy FOLDER --run --args "a b"          # command line for --run / --service
winvm deploy AppPackages\MyApp_..._Test --install --run   # MSIX: install, then start
```

A redeploy stops the running copy (and the service) first. `--wait` uses a
.NET startup hook (`DOTNET_STARTUP_HOOKS`) for that one start: no change to
your app, nothing left behind. Services can't wait longer than 25 s: Windows
gives a service 30 s to start.

## Visual Studio (Windows host)

Covered in detail in [windows-host/README.md](../windows-host/README.md#visual-studio-deploy-and-debug):
`vs setup` adds a launch profile *winvm dev*; pick it next to the start button
and press F5. Services: deploy with `-Service` (or `-Service -Wait`), then
*Debug > Attach to Process*, connection type *Remote (Windows - No
Authentication)*, address `127.0.0.1:40260+slot` (`winvm.ps1 vs` prints it).

## VS Code

Needs the C# extension (`ms-dotnettools.csharp`). After `vscode setup`, *Run
and Debug* lists per app:

| configuration | what F5 does |
|---|---|
| **winvm VM: APP** | build, copy, start it under the debugger in the SSH session: console apps (output in the Debug Console). A GUI app started this way has no visible window. |
| **winvm VM: APP on the VM desktop** | build, copy, start it on the VM's desktop waiting for the debugger, attach: GUI apps, from `Main` on |
| **winvm VM: APP as Windows service** | (console projects) build, copy, register and start service `winvm-APP` waiting for the debugger, attach |
| **winvm VM: attach APP** | attach to `APP.exe` running in the VM (no build) |

Stop (Shift+F5) on an attached session detaches; the app keeps running.

vsdbg in the VM is kept matching your C# extension: `vscode setup` and every
F5 build check it and download the extension's own Windows build if needed
(one-time, about 15 s). A mismatch makes breakpoints fail.

On a **Linux host** the debugger pipe runs through `lib/ide/dap-pathmap.py`,
and builds for VS Code put Windows-style source paths into the PDB
(`C:\winvm-linux\home/...`, `PathMap` in `Winvm.targets`): vsdbg on Windows
rejects breakpoints with Linux paths. Nothing to do for you; it is why the
generated `pipeProgram` is `python3`.

## Rider

Rider attaches over SSH with its own debugger; there is no F5 into a remote
machine, so it is two steps.

1. **Once per VM**: *Run > Attach to Remote Process... > SSH > Add Connection*:
   host `127.0.0.1`, port and user as `winvm -n dev rider` prints them,
   authentication *Key pair*, private key `state/id_ed25519` (Windows host:
   `windows-host\state\id_ed25519`).
2. In the attach dialog the connection shows up **twice**. Pick
   **`dev@127.0.0.1:PORT`** (Rider's .NET debugger). `127.0.0.1@PORT` is the
   generic one: it only knows Linux and macOS and shows "No processes to
   attach to".
3. The first time: *Install tools to remote computer* (Rider copies its
   debugger to `%LOCALAPPDATA%\JetBrains\RiderRemoteDebugger` in the VM).

Then, every time:

1. Run one of the `rider setup` configurations (toolbar, next to the run
   button): **winvm dev: APP on the VM desktop, waiting for the debugger**
   (or *...as Windows service, waiting 25 s...*). It builds, copies and starts
   the app in Rider's terminal.
2. *Run > Attach to Remote Process...* — the dialog remembers the connection —
   pick the app, *Attach with .NET Debugger*. The app continues; breakpoints
   from `Main` on work.

The variants without "waiting" start the app normally (attach later or not at
all).

## Packaged apps (MSIX, WinUI 3, MAUI)

Visual Studio deploys and debugs them itself (F5). For VS Code and Rider,
install a package and attach:

1. Build a sideloading package **with symbols** (vsdbg and Rider's debugger
   run inside the VM, so the PDBs must be in the package):

   ```powershell
   msbuild MyApp.csproj /restore /p:Configuration=Debug /p:Platform=x64 `
     /p:GenerateAppxPackageOnBuild=true /p:AppxBundle=Never /p:UapAppxPackageBuildMode=SideloadOnly `
     /p:AppxPackageSigningEnabled=true /p:PackageCertificateThumbprint=THUMBPRINT `
     /p:AppxPackageIncludePrivateSymbols=true
   ```

   (or in Visual Studio: *Publish > Create App Packages > Sideloading*.) The
   certificate's subject must match the manifest's `Publisher`; a self-signed
   one is fine (`New-SelfSignedCertificate -Type CodeSigningCert -Subject CN=...`).
2. `winvm deploy AppPackages\MyApp_1.0.0.0_x64_Debug_Test --as MyApp --install --run`
   (works from Linux too): trusts the `.cer`, installs with its dependencies,
   starts the app. A previous install of the same version, or one Visual Studio
   registered from loose files, is removed first (so the app's local data is
   reset).
3. VS Code: **winvm VM: attach MyApp** (`vscode setup` adds only that for
   packaged projects). Rider: the attach dialog.

Classic UWP apps can only be debugged with Visual Studio.

## How it works

```
 your machine                                      VM
 ────────────                                      ──
 build ──> Winvm.targets (after Build) ──> deploy ──tar over SSH──> C:\deploy\APP
                                                  └─ lib/guest/deploy.ps1: stop old copy,
                                                     unpack, start (desktop task / service)
 Visual Studio ── msvsmon, TCP 127.0.0.1:40260+ ─────────────────> msvsmon (port 4026)
 VS Code ──────── ssh "C:\vsdbg\vsdbg.exe" (DAP over stdin/out) ──> vsdbg
 Rider ────────── SSH + SFTP ─────────────────────────────────────> RiderRemoteDebugger
```

Files:

| file | role |
|---|---|
| `windows-host/vs/Winvm.targets` | MSBuild: after a build with `WinvmDeploy=true`, run `deploy`; used by all three IDEs |
| `lib/guest/deploy.ps1` | in the VM: unpack, stop/start, service, `--wait` hook, package install |
| `lib/guest/vsdbg.ps1` | in the VM: vsdbg matching the C# extension |
| `lib/ide/vscode.ps1`, `lib/ide/rider.ps1` | write the IDE configurations (shared by both hosts) |
| `lib/ide/ide-setup.ps1` | Linux entry point for them (pwsh) |
| `lib/ide/dap-pathmap.py` | Linux host: source paths between VS Code and vsdbg |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| VS Code: breakpoints stay hollow / "Incorrect breakpoint request format" | vsdbg doesn't match the C# extension (extension updated): run any VS Code F5 build, or `vscode setup` again; it updates `C:\vsdbg`. `winvm ssh "Get-Content C:\vsdbg\winvm-source.txt"` shows where it came from. |
| VS Code from Linux: breakpoints hollow, vsdbg current | The configuration predates the path relay: run `winvm vscode setup` again (its `pipeProgram` must be `python3 ... dap-pathmap.py`); the app must be built by the generated task (PathMap). Protocol log: add `"pipeEnv": {"WINVM_DAP_LOG": "/tmp/dap.log"}` to the configuration's `pipeTransport`. |
| VS Code: a GUI app starts but no window shows | Use **...on the VM desktop**; **winvm VM: APP** runs it in the SSH session (session 0, no desktop). |
| VS Code: "...preLaunchTask ... terminated with exit code 1" | Open the task's terminal: the build or `deploy` failed. `winvm -n VM status` (is the VM up?), `winvm deploy ...` by hand shows the error. |
| App exits immediately after deploy; deploy printed "needs Microsoft.NETCore.App N.x" | The VM lacks that .NET runtime (the recipe installs .NET 10): `winvm ssh "choco install -y dotnet-N.0-desktopruntime"`, add it to a recipe's `packages.txt`, or build self-contained. |
| Rider: "No processes to attach to" | Wrong entry: pick `dev@127.0.0.1:PORT`, not `127.0.0.1@PORT`. |
| Rider: "Install tools to remote computer" every time, or the list stays empty | The VM's SSH login shell is PowerShell: `winvm -n VM rider` sets cmd.exe; then restart Rider (it remembers the failed check per session). |
| Rider run configuration: `dotnet: command not found` | Rider's terminal has no .NET SDK on PATH; start Rider from a shell that has it (e.g. `nix develop`). |
| Service with `--wait`: starts without stopping at breakpoints | Attach within 25 s; after that it starts normally (Windows' 30 s service start limit). |
| `deploy --install`: 0x80073CFB / "same identity ... contents are different" | Fixed automatically (old registration removed); if it still fails, `winvm ssh "Get-AppxPackage NAME \| Remove-AppxPackage"`. |
| Packaged app: attach works, breakpoints hollow | The package has no PDBs: build it with `AppxPackageIncludePrivateSymbols=true`. |
| Visual Studio (Windows host): warning MSB4011 "Winvm.targets cannot be imported again" | Harmless: the project is set up for both Visual Studio (`.csproj.user`) and VS Code (command line). |
| `winvm ssh` opens cmd.exe | Fine for a VM where the recipe set cmd.exe; `winvm ssh` itself starts PowerShell. Plain `ssh winvm` (ssh-config) gives the login shell: type `powershell`. |

Everything here was tested on 2026-11-05: Linux host (NixOS, QEMU VM, VS Code
1.140 + C# 2.160.4, Rider 2026.2) and Windows host (VirtualBox, VS 2026, VS Code
+ C# 2.160.4), each with console apps, a worker service, and a packaged WinUI 3
app (install + attach). Not tested: Rider on a Windows host; classic UWP on .NET
9+ (`UseUwp`) and `.wapproj` packaging projects with Visual Studio.
