{
  pkgs ? import <nixpkgs> { },
  ...
}:
let
  # Names shared with the NixOS config (sops key path, ...)
  names = import ../hosts/_shared/components/impermanence/names.nix;

  # A script from ./<name>/<name>.sh; `subst` replaces @placeholders@.
  script =
    name: runtimeInputs: subst:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = builtins.replaceStrings (builtins.attrNames subst) (builtins.attrValues subst) (
        builtins.readFile ./${name}/${name}.sh
      );
    };
in
rec {
  # Workflow scripts (in the dev shell and `nix run .#<name>`), see
  # docs/installer.md, docs/secrets.md, docs/cloud.md
  # nix itself comes from the system (same version as the store)
  sops-sync = script "sops-sync" (with pkgs; [
    sops
    gnupg
    git
    jq
    gawk
    findutils
    gnugrep
    coreutils
  ]) { };

  sops-register-host = script "sops-register-host" [
    pkgs.git
    sops-sync
  ] { };

  make-installer-stick = script "make-installer-stick" (with pkgs; [
    util-linux
    udisks
    gawk
    diffutils
    git
    coreutils
    gnugrep
  ]) { };

  provision-server = script "provision-server" (with pkgs; [
    nixos-anywhere
    age
    openssh
    git
    coreutils
    findutils
    sops-register-host
  ]) { "@sopsKey@" = names.sopsAgeKey; };

  check-cves = script "check-cves" (with pkgs; [
    vulnix
    jq
    git
    coreutils
  ]) { };

  # Turns install-host's plain copy into a git checkout (docs/installer.md);
  # its test runs while building it.
  nix-config-checkout = pkgs.writeShellApplication {
    name = "nix-config-checkout";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
    ];
    text = builtins.readFile ./nix-config-checkout/nix-config-checkout.sh;
    derivationArgs = {
      nativeBuildInputs = [
        pkgs.git
        pkgs.shellcheck
      ];
      postCheck = ''
        shellcheck ${./nix-config-checkout/test.sh}
        bash ${./nix-config-checkout/test.sh} "$target"
      '';
    };
  };

  # The Check and the Gate (CLAUDE.md `## Factory`, docs/testing.md):
  # `nix run .#check` / `.#gate` from the repository root. Tested while built.
  check = pkgs.writeShellApplication {
    name = "check";
    meta.description = "Fast check: formatting, scripts, secrets, install-host, evaluation";
    text = builtins.readFile ./check/check.sh;
    derivationArgs = {
      nativeBuildInputs = [ pkgs.shellcheck ];
      postCheck = ''
        shellcheck ${./check/test.sh}
        bash ${./check/test.sh} "$target"
      '';
    };
  };
  gate = pkgs.writeShellApplication {
    name = "gate";
    meta.description = "Full gate: nix flake check, install-host and every host";
    runtimeInputs = [ check ];
    text = ''exec check --gate "$@"'';
  };

  installer-vm = script "installer-vm" (with pkgs; [
    qemu_kvm
    git
  ]) { "@ovmf@" = "${pkgs.OVMF.fd}"; };

  # Review before switch: what changed since the running system was built
  # (docs/agent-isolation.md). No git on purpose; nix from the system.
  switch-review = script "switch-review" (with pkgs; [
    diffutils
    findutils
    coreutils
    jq
  ]) { "@nh@" = "${pkgs.nh}"; };
}
