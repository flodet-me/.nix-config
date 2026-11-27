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

  # Adds my custom packages
  additions = final: _: import ../pkgs { pkgs = final; };

  # Modifies existing packages
  modifications = _: prev: {
    gnomeExtensions = prev.gnomeExtensions // {
      # Mutter 50 dropped raise_and_make_recent(); the extension threw on the
      # Smile window, so Super+. opened it behind other windows. --replace-fail
      # breaks the build once upstream fixes it: then drop this.
      smile-complementary-extension = prev.gnomeExtensions.smile-complementary-extension.overrideAttrs {
        postPatch = ''
          substituteInPlace extension.js --replace-fail \
            'window.raise_and_make_recent();' \
            'window.raise_and_make_recent_on_workspace(global.workspace_manager.get_active_workspace());'
        '';
      };
    };
  };
}
