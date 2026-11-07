{
  pkgs ? import <nixpkgs> { config.allowUnfree = true; }, # claude-code is unfree
  ...
}:
{
  default = pkgs.mkShell {
    NIX_CONFIG = "extra-experimental-features = nix-command flakes";
    # mkShell points TMPDIR (and TMP, TEMP, TEMPDIR) at a per-shell directory,
    # /tmp/nix-shell.XXXXXX, which nix deletes when the shell exits. Whatever
    # outlives the shell (an editor started from it, tmux, a direnv-cached
    # environment) then fails with "creating directory ...: No such file or
    # directory". Use the normal temp directory instead.
    shellHook = ''
      export TMPDIR=/tmp TMP=/tmp TEMP=/tmp TEMPDIR=/tmp
    '';
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
