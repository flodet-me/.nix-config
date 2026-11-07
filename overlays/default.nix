{
  inputs,
}:
{
  # For every flake input, aliases 'pkgs.inputs.${flake}' to
  # 'inputs.${flake}.packages.{pkgs.stdenv.hostPlatform.system}' or
  # 'inputs.${flake}.legacyPackages.{pkgs.stdenv.hostPlatform.system}'
  flake-inputs = final: _: {
    inputs = builtins.mapAttrs (
      _: flake:
      let
        legacyPackages = (flake.legacyPackages or { }).${final.stdenv.hostPlatform.system} or { };
        packages = (flake.packages or { }).${final.stdenv.hostPlatform.system} or { };
      in
      if legacyPackages != { } then legacyPackages else packages
    ) inputs;
  };

  # Adds pkgs.stable: the pinned nixpkgs-stable release. Only allowUnfree is
  # carried over (the full config differs between releases).
  stable = final: _: {
    stable = import inputs.nixpkgs-stable {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = final.config.allowUnfree or false;
    };
  };

  # Adds my custom packages
  additions = final: _: import ../pkgs { pkgs = final; };

  # Modifies existing packages
  modifications = _: _: { };
}
