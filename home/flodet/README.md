# flodet

This is the [home manager](https://github.com/nix-community/home-manager) configuration for [`flodet`](https://github.com/flodet-me).

Public SSH Key: [Reference](./ssh.pub)
Public GPG Key: [Reference](./pgp.pub)

## Structure

The following structure is used for organizing the home-manager configuration per host.

```
.
├── _shared     | Configuration files shared and / or optional for different hosts
└── <<HOST>>    | Host specific configuration for home-manager
```

## Secrets

Secrets for home-manager can be found [here](./_shared/secrets/secrets.yaml).

Documentation for usage and configuration of secrets can be found [here](./../../docs/secrets.md).
