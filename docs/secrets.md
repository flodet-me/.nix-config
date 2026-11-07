# Secrets

Secrets are encrypted with [sops](https://github.com/getsops/sops) and decrypted
on each host by [sops-nix](https://github.com/Mic92/sops-nix).

## How it works

- Each value in a `*secrets.yaml` is encrypted with a random data key. That
  data key is stored in the file once per recipient, encrypted to that
  recipient's public key. Any **one** recipient can decrypt.
- Recipients, one source of truth per kind:
  - `keys/admins`: on **every** file (YubiKey PGP key; optionally an offline
    backup age key). Used to edit secrets and to add hosts.
  - `keys/hosts/<host>.age`: one public age key per host, **by host name**.
    Reinstalling a host overwrites its file; deleting it removes the host.
  - Which files a host may read follows its `host.role` (set in its config):
    `workstation` reads `hosts/_shared/**` and `home/**`, `server` reads only
    `hosts/<host>/secrets.yaml`.
- **`sops-sync`** generates `.sops.yaml` from those (never edit it by hand) and
  re-encrypts every secrets file to exactly those recipients (YubiKey). Running
  it again changes nothing, so recipients never accumulate.
- The private host key lives on the host at `/persist/var/lib/sops-nix/key.txt`
  (`/var/lib/sops-nix/key.txt` without impermanence), root-only, never in the
  repo. sops-nix decrypts into `/run/secrets/<name>` (RAM only); config only
  references the path, so nothing ends up in `/nix/store`.
- `nix flake check` / CI fail if a secrets file contains plaintext.

Files:

| File                                           | Contents                                                  |
| ---------------------------------------------- | --------------------------------------------------------- |
| `hosts/_shared/users/flodet/user-secrets.yaml` | `mullvad-account-key`, `home-location`, `weather-api-key` |
| `hosts/<server>/secrets.yaml`                  | that server's secrets (`docs/cloud.md`)                   |

## Everyday use

```sh
sops hosts/_shared/users/flodet/user-secrets.yaml   # edit (YubiKey touch/PIN)
```

Declare a secret in a NixOS module and use its path:

```nix
sops.secrets.my-token = {
  sopsFile = ../users/flodet/user-secrets.yaml;
  owner = "flodet"; # omit for root-only
};

# then: config.sops.secrets.my-token.path  (= /run/secrets/my-token)
```

From home-manager modules use `osConfig.sops.secrets.<name>.path`. Prefer
passing the file path to programs over putting the value in environment
variables.

## Hosts: add, reinstall, remove

Normally automatic:

- **Installed from the stick** (`docs/installer.md`): `install-host` creates
  the key and re-encrypts on the stick, so the system has its secrets from the
  first boot. The repo only receives `keys/hosts/<host>.age`: on the first
  login `~/.nix-config` becomes a checkout of GitHub's main with that file,
  `sops-sync` runs (YubiKey) and the result is committed; you `git push`.
- **Servers**: `provision-server` (`docs/cloud.md`).

By hand (dev shell, YubiKey plugged in):

```sh
sops-register-host <host> <age-pubkey>   # writes keys/hosts/<host>.age, runs sops-sync
sops-sync                                # after editing keys/admins or deleting a key file
```

then commit `keys/`, `.sops.yaml` and the secrets files, push, rebuild the host.
On a running host the key is `sudo age-keygen -y /persist/var/lib/sops-nix/key.txt`.

Removing a host: delete `keys/hosts/<host>.age`, `sops-sync`, and change any
secret it could read (it may have kept a copy). `sops rotate -i <file>` also
gives the file a new data key.

## PIN prompt doesn't show up / "Invalid ID"

gpg reports a missing PIN prompt (timed out) as `public key decryption failed:
Invalid ID`. The prompt goes to the terminal/display gpg-agent last saw.
`sops-sync` points it at its own terminal; elsewhere run
`gpg-connect-agent updatestartuptty /bye` in the terminal you are using.

## Further hardening (not done yet)

- **Backup recipient.** Losing the YubiKey means no one can edit secrets or add
  hosts. Create an offline key (`age-keygen`), keep the private part on paper or
  in a password manager, add `age <public key>` to `keys/admins`, `sops-sync`.
- **Private secrets repo** only if the secret *names* should be hidden; values
  are already safe in a public repo.
