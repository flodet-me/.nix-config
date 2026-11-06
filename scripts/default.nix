{
  pkgs ? import <nixpkgs> { },
  ...
}:
let
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
  ]) { };

  provision-server = script "provision-server" (with pkgs; [
    nixos-anywhere
    age
    openssh
    git
    coreutils
    findutils
    sops-register-host
  ]) { };

  check-cves = script "check-cves" (with pkgs; [
    vulnix
    jq
    git
    coreutils
  ]) { };

  installer-vm = script "installer-vm" (with pkgs; [
    qemu_kvm
    git
  ]) { "@ovmf@" = "${pkgs.OVMF.fd}"; };
}
