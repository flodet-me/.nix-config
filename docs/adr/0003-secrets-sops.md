# 0003: Secrets with sops-nix, YubiKey admin key and per-host age keys

Date: 2026-11-27. Status: accepted, implemented ([secrets.md](../secrets.md)).
Recorded after the fact on 2026-11-27.

## Context

The repository is public (pushed to GitHub), yet hosts need secrets such as
the Mullvad account key and the servers' backup credentials. Hosts are
reinstalled from the repository (installer stick, `provision-server`), and a
host installed from the stick has its secrets from the first boot. Why
sops-nix was picked over other tools is not recorded.

## Options

1. sops-nix: encrypted `*secrets.yaml` in the repository, one data key per
   file encrypted to every recipient.
2. agenix or secrets kept outside the repository (obvious alternatives;
   reason for not choosing them not recorded).
3. A private secrets repository: noted in docs/secrets.md as only worth it
   if the secret *names* must be hidden; not done.

## Decision

Option 1. Recipients come from two sources: `keys/admins` (the YubiKey
OpenPGP key, on every file, used to edit secrets and add hosts) and
`keys/hosts/<host>.age` (one age key per host). `sops-sync` generates
`.sops.yaml` from them and each host's `host.role` (workstations read
`hosts/_shared/**` and `home/**`, servers only `hosts/<host>/secrets.yaml`) and
re-encrypts deterministically; `.sops.yaml` is never edited by hand. Secrets
are system-level only, decrypted to `/run/secrets/<name>`; Nix references
only `config.sops.secrets.<name>.path` (`osConfig...` in home-manager). The
workstation login password is intentionally not a secret: it is public, set
in `hosts/_shared/users/flodet/default.nix`, and only guards the screen lock
and `sudo` at the keyboard; LUKS protects the data.

## Consequences

- Editing secrets, `sops-sync` and adding a host need the YubiKey (touch and
  PIN), so they are human-only steps.
- Losing the YubiKey means nobody can edit secrets or add hosts until an
  offline backup age recipient is added to `keys/admins` (not done yet).
- The host's private age key lives at `/persist/var/lib/sops-nix/key.txt`
  (ADR 0002); a host whose key is not registered boots without its secrets.
- Removing a host means deleting its key file, `sops-sync`, and rotating
  every secret it could read.
- `checks.<system>.sops-encrypted` fails on plaintext in a secrets file.
- The public password must become a sops `hashedPasswordFile` before sshd is
  ever enabled on a workstation.

## Evidence

- `flake.nix` (`sops-nix` input, `sops-encrypted` check),
  `hosts/_shared/global.nix`, `scripts/sops-sync/`,
  `scripts/sops-register-host/`, `keys/admins`, `keys/hosts/`,
  `hosts/_shared/users/flodet/default.nix`;
  [secrets.md](../secrets.md); AGENTS.md, "Secrets (sops-nix)".
- `57b5981` (2025-01-26): sops-nix input. `7a9c559` (2025-02-28): the
  public login password. `c9bfb71` (2026-11-06): `keys/admins`,
  `keys/hosts/`, `sops-sync` with roles. `a66fda6` (2026-11-06):
  `sops-encrypted` check. `f9111a9` (2026-11-06): laptop host key
  registered.

Decided by: user (recorded by agent).
