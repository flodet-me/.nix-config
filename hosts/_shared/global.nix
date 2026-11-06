# This file (and the global directory) holds config that i use on all hosts
{
  inputs,
  outputs,
  lib,
  ...
}:
{
  imports = [
    inputs.sops-nix.nixosModules.sops
    ./components/zsh.nix
    ./components/locale.nix
    ./components/nix.nix
    ./components/nix-ld.nix
    ./users/flodet
  ];

  # Each host decrypts with its own age key, generated on first activation if
  # missing; its public key must then be added to .sops.yaml (docs/secrets.md).
  sops.age = {
    keyFile = lib.mkDefault "/var/lib/sops-nix/key.txt";
    generateKey = true;
    sshKeyPaths = [ ];
  };
  sops.gnupg.sshKeyPaths = [ ];

  nixpkgs = {
    overlays = builtins.attrValues outputs.overlays;
    config = {
      allowUnfree = true;
      allowUnfreePredicate = _: true;
    };
  };

  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];

    # strongly recommended
    fallback = true;
    builders-use-substitutes = true;
  };
}
