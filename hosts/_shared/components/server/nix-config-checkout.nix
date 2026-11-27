# Server half of home/flodet/_shared/components/nix-config-checkout.nix:
# install-host leaves a plain copy of the repo (no .git) in ~/.nix-config.
# On the first boot with network scripts/nix-config-checkout replaces it with
# a read-only checkout of GitHub's main (HTTPS, public repo) and carries over
# what the install added (.install-keep), which then shows up in `git status`.
# Servers have no GitHub key: changes are made on a workstation and deployed
# from there (docs/cloud.md).
{ config, pkgs, ... }:
let
  repo = "flodet-me/.nix-config";
  user = config.host.user;
  installed = "${config.users.users.${user}.home}/.nix-config";
  inherit ((import ../../../../scripts { inherit pkgs; })) nix-config-checkout;
in
{
  systemd.services.nix-config-checkout = {
    description = "Turn the installer's copy of ~/.nix-config into a git checkout";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = [
        "${installed}/flake.nix"
        "!${installed}/.git"
      ];
      StartLimitIntervalSec = 0; # keep retrying until GitHub is reachable
    };
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Restart = "on-failure";
      RestartSec = 60;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
    # No hook: servers never commit (changes come from a workstation)
    script = "${nix-config-checkout}/bin/nix-config-checkout ${installed} https://github.com/${repo}.git git@github.com:${repo}.git";
  };
}
