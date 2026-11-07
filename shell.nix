{
  pkgs ? import <nixpkgs> { config.allowUnfree = true; }, # claude-code is unfree
  ...
}:
{
  default = pkgs.mkShell {
    NIX_CONFIG = "extra-experimental-features = nix-command flakes";
    nativeBuildInputs =
      with pkgs;
      [
        nix
        git
        sops
        ssh-to-age
        gnupg
        age
        nixfmt
        nix-output-monitor
        claude-code
        act # run the GitHub Actions workflow locally (needs Docker)
        nixos-anywhere # first install of cloud servers (docs/cloud.md)
      ]
      # Workflow scripts from ./scripts (sops-register-host, make-installer-stick, ...)
      ++ builtins.attrValues (import ./scripts { inherit pkgs; });
  };
}
