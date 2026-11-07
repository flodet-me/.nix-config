# Config of every host (workstations and servers): secrets, nixpkgs, nix
# settings. Workstation-only things live in components/workstation.nix.
{
  inputs,
  outputs,
  lib,
  ...
}:
{
  imports = [
    inputs.sops-nix.nixosModules.sops
    ./components/host-role.nix
    ./components/privacy.nix
    ./components/zsh.nix
    ./components/nix.nix
  ];

  # Each host decrypts with its own age key. install-host creates it at
  # install time and registers its public key in .sops.yaml (docs/secrets.md);
  # a host that boots without a registered key just gets no secrets, because
  # generateKey creates a fresh unregistered one.
  sops.age = {
    keyFile = lib.mkDefault "/var/lib/sops-nix/key.txt";
    generateKey = true;
    sshKeyPaths = [ ];
  };
  sops.gnupg.sshKeyPaths = [ ];

  nixpkgs = {
    overlays = builtins.attrValues outputs.overlays;
    config.allowUnfree = true;
  };
}
