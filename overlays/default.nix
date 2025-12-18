{
  outputs,
  inputs,
}:
let
  addPatches =
    pkg: patches:
    pkg.overrideAttrs (oldAttrs: {
      patches = (oldAttrs.patches or [ ]) ++ patches;
    });
in
{
  # For every flake input, aliases 'pkgs.inputs.${flake}' to
  # 'inputs.${flake}.packages.{pkgs.stdenv.hostPlatform.system}' or
  # 'inputs.${flake}.legacyPackages.{pkgs.stdenv.hostPlatform.system}'
  flake-inputs = final: _: {
    inputs = builtins.mapAttrs (
      _: flake:
      let
        legacyPackages = (flake.legacyPackages or { }).${final.system} or { };
        packages = (flake.packages or { }).${final.system} or { };
      in
      if legacyPackages != { } then legacyPackages else packages
    ) inputs;
  };

  # Adds pkgs.stable == inputs.nixpkgs-stable.legacyPackages.{pkgs.stdenv.hostPlatform.system}
  stable = final: _: {
    stable = inputs.nixpkgs.legacyPackages.${final.system};
  };

  # Adds my custom packages
  additions =
    final: prev:
    import ../pkgs { pkgs = final; }
    // {
    };

  # Modifies existing packages
  modifications = final: prev: {
  };
}
