# Secrets

Secrets are encrypted with [sops](https://github.com/getsops/sops) and decrypted
on each host by [sops-nix](https://github.com/Mic92/sops-nix).

## How it works

- Each value in a `*secrets.yaml` is encrypted with a random data key. That
  data key is stored in the file once per recipient (`.sops.yaml`), encrypted
  to that recipient's public key. Any **one** recipient can decrypt.
- Recipients:
  - **YubiKey (PGP)**: admin key, on every file. Used to edit secrets and add hosts.
  - **Workstations** (desktop, laptop) read the shared files under
    `hosts/_shared` and `home`.
  - **Servers** each read only their own `hosts/<server>/secrets.yaml`
    (own rule in `.sops.yaml`), never the workstation secrets.
  - **One age key per host**, at `/persist/var/lib/sops-nix/key.txt`
    (`/var/lib/sops-nix/key.txt` on hosts without impermanence), root-only.
    Created during install (`install-host` on the machine itself,
    `provision-server` locally, then copied over and deleted locally), or on
    first activation if missing (`sops.age.generateKey`). Never in the repo.
- On activation sops-nix decrypts into `/run/secrets/<name>` (RAM only) with
  the declared owner/mode. Config only ever references the path, so nothing
  ends up in `/nix/store`.
- `nix flake check` / CI fail if a secrets file contains plaintext.

Files:

| File                                        | Contents                               |
| ------------------------------------------- | -------------------------------------- |
| `hosts/_shared/users/flodet/secrets.yaml`      | `flodet-password` (needed for users)   |
| `hosts/_shared/users/flodet/user-secrets.yaml` | `mullvad-account-key`, `home-location`, `weather-api-key` |
| `hosts/<server>/secrets.yaml`                  | that server's secrets (`docs/cloud.md`)               |

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
passing the file path to programs (or reading it in a script) over putting the
value in environment variables.

## Adding a host (or reinstalling one)

During the install, before `nixos-install` (see `docs/impermanence.md`):

```sh
sudo mkdir -p /mnt/persist/var/lib/sops-nix
sudo nix --extra-experimental-features "nix-command flakes" shell nixpkgs#age \
  -c age-keygen -o /mnt/persist/var/lib/sops-nix/key.txt   # prints the public key
```

Usually this is automated:

- workstations: `install-host` on the installer stick (`docs/installer.md`)
- servers: `provision-server` (`docs/cloud.md`)

Manually, on any machine with the YubiKey (dev shell):

```sh
sops-register-host <host> <age-pubkey>            # workstation
sops-register-host --server <host> <age-pubkey>   # server: own secrets file only
```

It adds the key to `.sops.yaml`, re-encrypts the files the host may read and
makes the PIN prompt appear in your terminal. Then commit, push, install/rebuild.

The secrets are then decrypted from the very first boot (early in boot, from
`/persist`). Tested in a VM on 2026-11-06 with a fresh key registered via the
YubiKey only.

On a host that is already running, the key is generated on the first switch
instead: `sudo age-keygen -y /var/lib/sops-nix/key.txt` prints the public key;
register it as above and switch again.

Removing a host: delete its key from `.sops.yaml`, `sops updatekeys`, and
`sops rotate -i <file>` (new data key), then change any secret it could read.

### Using the YubiKey in the NixOS installer

Needed when no other machine with the YubiKey setup is available (e.g.
reinstalling the desktop first). The public key is in `keys/flodet.asc`.
Not tested on a real installer yet.

```sh
sudo systemctl start pcscd
nix --extra-experimental-features "nix-command flakes" \
  shell nixpkgs#gnupg nixpkgs#pinentry-curses nixpkgs#sops
mkdir -p ~/.gnupg
echo "pinentry-program $(command -v pinentry-curses)" > ~/.gnupg/gpg-agent.conf
echo "disable-ccid" > ~/.gnupg/scdaemon.conf
gpg --import keys/flodet.asc
gpg --card-status          # creates the stubs pointing at the card
export GPG_TTY=$(tty)
sops updatekeys -y hosts/_shared/users/flodet/secrets.yaml   # asks for the PIN
```

### PIN prompt doesn't show up / "Invalid ID"

gpg reports a missing PIN prompt (timed out) as `public key decryption failed:
Invalid ID`. The prompt goes to the terminal/display gpg-agent last saw. Fix:
run `gpg-connect-agent updatestartuptty /bye` in the terminal you are using,
then retry. Files encrypted with gpg's `throw-keyids` (removed from the config
on 2026-11-06) additionally need `--try-secret-key 0x532B59762527E7DF`.

## Migration status

Both secrets files were re-encrypted to the single-group format on
2026-11-06 (YubiKey or desktop age key, each alone, can decrypt).

When reinstalling the desktop either move the old key
(`~/.config/sops/age/keys.txt`) to `/persist/var/lib/sops-nix/key.txt`, or
(better, it has been copied around) generate a new one as above, replace
`&desktop` and `sops updatekeys`. Afterwards delete
`~/.config/sops/age/keys.txt` on both machines.

## Further hardening (not done yet)

- **Login password from sops.** `flodet-password` holds a plaintext password,
  but `hashedPasswordFile` needs a hash. Run `mkpasswd -m yescrypt`, store the
  output with `sops hosts/_shared/users/flodet/secrets.yaml`, then enable
  `hashedPasswordFile` and remove `password` in
  `hosts/_shared/users/flodet/default.nix`. Test in the VM first: with
  `mutableUsers = false` a broken secret means no login.
- **Backup recipient.** Losing the YubiKey means no one can edit secrets or add
  hosts. Create an offline key (`age-keygen`), keep the private part on paper or
  in a password manager, add the public key as `&backup`, `sops updatekeys`.
- **Rotate the old desktop key** (see migration above).
- **Private secrets repo** only if the secret *names* should be hidden; values
  are already safe in a public repo. Costs: git+ssh flake input, rebuilds need
  `--sudo` and the YubiKey for fetching, and `nix flake update secrets` after
  every edit.
