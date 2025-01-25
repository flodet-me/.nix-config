# This file (and the global directory) holds config that i use on all hosts
{
  inputs,
  outputs,
  ...
}:
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ./components/zsh.nix
    ./components/locale.nix
    ./components/nix.nix
    ./components/nix-ld.nix
    ./components/silentboot.nix
    ./users/flodet/default.nix
  ];

  home-manager.useGlobalPkgs = true;
  home-manager.extraSpecialArgs = {
    inherit inputs outputs;
  };

  nixpkgs = {
    overlays = builtins.attrValues outputs.overlays;
    config = {
      allowUnfree = true;
    };
  };
}
