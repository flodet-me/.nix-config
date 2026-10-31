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

## Differences from the Linux version

| | Linux (`../winvm`) | Windows host (`winvm.ps1`) |
|---|---|---|
| hypervisor | QEMU/KVM | VirtualBox |
| clean state | read-only base image + overlay per VM | snapshot "clean" + linked clones |
| install | own `autounattend.xml`, VirtIO drivers | VirtualBox unattended install, Guest Additions |
| test tools (`provision/tools.txt`) | installed | not installed: add what you need to `packages.txt` or a recipe |
| run / crashes / debug / uitest / netcap / proxy / trace / usb | yes | no |
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
