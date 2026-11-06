# flodet

[home-manager](https://github.com/nix-community/home-manager) configuration
for [`flodet`](https://github.com/flodet-me), applied together with the system
by `nixos-rebuild` (home-manager runs as a NixOS module).

Public GPG key: [keys/flodet.asc](../../keys/flodet.asc)

```
.
├── _shared     | Modules shared by or optional for the machines
└── <host>      | Per-machine entry point (imported by flake.nix)
```

Secrets are system-level (`hosts/_shared/users/flodet`), read here via
`osConfig.sops.secrets.<name>.path`. See [docs/secrets.md](../../docs/secrets.md).
