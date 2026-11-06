{
  inputs,
  lib,
  ...
}:
let
  flakeInputs = lib.filterAttrs (_: lib.isType "flake") inputs;
in
{
  imports = [ inputs.nix-index-database.nixosModules.nix-index ];

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
    };
    # Add each flake input as a registry and nix_path
    registry = lib.mapAttrs (_: flake: { inherit flake; }) flakeInputs;
    nixPath = lib.mapAttrsToList (n: _: "${n}=flake:${n}") flakeInputs;
  };

  # nh: `nh os switch` shows what changes before switching; also does the
  # weekly garbage collection (keeps at least 5 generations and 30 days).
  programs.nh = {
    enable = true;
    flake = "/home/flodet/.nix-config";
    clean = {
      enable = true;
      dates = "weekly";
      extraArgs = "--keep 5 --keep-since 30d";
    };
  };

  # Prebuilt package index: `nix-locate bin/foo`, `, foo` runs foo once
  # without installing it, and a missing command says which package has it.
  programs.nix-index-database.comma.enable = true;
}
