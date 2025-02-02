# My Nix configurations

This repository contains relevant configuration and definitions for my nix-including systems.
It is based on the experimental [flake feature](https://nixos.wiki/wiki/Flakes).

**Current state**: Under development


## Development

To have the necessary tooling to adjust and build the configuration.

To start on a blank NixOS installation just run:

```sh
nix-shell
```

On an already configured system with nix, git and enabled flakes feature you can just run:

```sh
nix develop
```

After that you have all necessary tools to your disposal.
For example `sops`, `git`, `nix`, `home-manager`, or `nixfmt`.

## Secrets

TODO: Separate config from secrets in depth.
TODO: Change to hardware token.
TODO: Add docs for system secrets

This repository supports storing and providing secrets based on [SOPS](https://getsops.io/).
Integrated into nix by using [sops-nix](https://github.com/Mic92/sops-nix).

Currently the age key generated of my SSH-Key is used.

Further information about how to access and add secrets can be found in subdirectories.


## Preview

Following a picture of the current hyprland setup with `flodet@desktop` (as of (01/2025))

![Hyprland preview](./.assets/2025-02-02_hyprland.png)


## Acknowledgment & References

The following resources were immensely helpful in setting up this repository:

- https://github.com/Misterio77/nix-config
- https://www.youtube.com/@vimjoyer

Also thank you to all the package maintainers, tool developer, and other resources I did not mention.
