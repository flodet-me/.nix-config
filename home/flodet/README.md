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

Secrets are provided by using [sops-nix](https://github.com/Mic92/sops-nix).
The file can be found [here](./_shared/secrets/secrets.yaml).

To add a secret just execute the following command and add secrets:

```sh
sops secrets.yaml
```

To provide a secret to the configuration add the following definition:

```nix
sops.secrets.<<SECRET_IDENTIFIER>>.path = "${config.sops.defaultSymlinkPath}/<<SECRET_IDENTIFIER>>";
```

To use the file reference to the secret use the configuration expression:

```nix
config.sops.secrets.<<SECRET_IDENTIFIER>>.path
```

To add the secret to a environment variable.

```nix
home.sessionVariables.<<SECRET_IDENTIFIER>> = "$(cat ${config.sops.secrets.w<<SECRET_IDENTIFIER>>.path})";
```
