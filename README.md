# winvm — reproducible Windows 10 VM

Fully scripted Windows 10 dev/test VM on plain QEMU/KVM (no libvirt, runs as
your user, everything lives in this directory).

- **Unattended install**: `autounattend.xml` + VirtIO drivers, no clicks.
- **Provisioning**: VirtIO guest tools, OpenSSH (key auth), RDP, Chocolatey
  packages from `provision/packages.txt`, your own `provision/custom.ps1`.
- **Easy reset**: the provisioned install is a read-only `base.qcow2`; the VM
  runs on a copy-on-write overlay. `winvm reset` throws the overlay away in
  about a second.

## Quick start

```sh
nix develop                     # qemu, xorriso, freerdp, ... (or install them yourself)
# put the Windows 10 ISO at iso/win10.iso
#   https://www.microsoft.com/software-download/windows10ISO
winvm build                     # 20-60 min, VM powers off when provisioned
winvm start --headless --wait
winvm ssh                       # PowerShell
winvm rdp                       # desktop, clipboard, \\tsclient\share = ./share
```

## Commands

| command | |
|---|---|
| `build [--force] [--headless]` | install + provision → clean base image |
| `start [--headless\|--gui] [--temp] [--wait]` | boot; `--temp` discards every change on stop |
| `stop [--force]` | ACPI shutdown / hard stop |
| `reset` | back to the clean base image |
| `commit` | make the current state the new clean base |
| `snapshot save\|load\|delete\|list NAME` | live (with RAM) when running, disk-only when stopped |
| `ssh`, `scp SRC vm:DST`, `rdp`, `wait`, `status`, `destroy` | |

Three levels of "undo", from coarse to fine:

1. `winvm reset` — everything since the build (or the last `commit`).
2. `winvm snapshot load NAME` — named checkpoints on top of the base.
3. `winvm start --temp` — a throwaway session; nothing is written.

## Configuration

Defaults are in `config.env`; put overrides in `config.local.env` (gitignored).
Things you will likely want:

```sh
WIN_INPUT_LOCALE="de-DE"              # keyboard layout
WIN_TIMEZONE="W. Europe Standard Time"
VM_RAM="12G"; VM_CPUS=6
WIN_ISO_SHA256="..."                  # pin the exact ISO for reproducibility
```

Changing `config.env`, `packages.txt` or `custom.ps1` needs
`winvm build --force`. For a quick change, install it in the running VM and
`winvm commit` instead.

## Notes

- Default credentials are `dev` / `dev`. SSH and RDP are only forwarded to
  127.0.0.1 (`SSH_PORT`, `RDP_PORT`). The SSH key is generated in
  `state/id_ed25519`.
- Generic product keys install Windows **without activating it**. That's fine
  for testing; some personalization settings stay locked.
- Use Pro or Enterprise: Home has no RDP server.
- The guest has outbound internet through QEMU user networking (NAT). Only the
  SSH and RDP ports are reachable from the host.
- Provisioning progress is written to the serial port and shown during
  `build`. In the guest it is at `C:\winvm\provision.log`.
