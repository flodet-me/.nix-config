{
  inputs,
  lib,
  ...
}:
let
  # `self` is a store path of this repo: useless as a registry entry
  flakeInputs = lib.filterAttrs (name: input: name != "self" && lib.isType "flake" input) inputs;
in
{
  nix = {
    settings = {
      trusted-users = [
        "root"
        "@wheel"
      ];
      auto-optimise-store = lib.mkDefault true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      warn-dirty = false;
      system-features = [
        "kvm"
        "big-parallel"
        "nixos-test"
      ];
      flake-registry = ""; # Disable global flake registry

      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
      fallback = true; # build locally when a substituter is unreachable
      builders-use-substitutes = true;

      # Garbage-collect during a build when the disk runs low, instead of failing
      # with "No space left on device" half way.
      min-free = 5 * 1024 * 1024 * 1024;
      max-free = 20 * 1024 * 1024 * 1024;
    };
    # Add each flake input as a registry and nix_path
    registry = lib.mapAttrs (_: flake: { inherit flake; }) flakeInputs;
    nixPath = lib.mapAttrsToList (n: _: "${n}=flake:${n}") flakeInputs;
  };

  # nh: `nh os switch` shows what changes before switching; also does the
  # weekly garbage collection (keeps at least 5 generations and 30 days).
  programs.nh = {
    enable = true;
    clean = {
      enable = true;
      dates = "weekly";
      extraArgs = "--keep 5 --keep-since 30d";
    };
  };
}
