# Facts about a host that tooling and modules read instead of guessing:
#   host.role  what kind of machine it is (sops-sync, install-host)
#   host.user  the login user, set once by mkHost in flake.nix
{ lib, ... }:
{
  options.host = {
    role = lib.mkOption {
      type = lib.types.enum [
        "workstation"
        "server"
      ];
      default = "workstation";
      description = ''
        workstation: may read the shared secrets (hosts/_shared, home).
        server: may read only hosts/<host>/secrets.yaml.
      '';
    };
    user = lib.mkOption {
      type = lib.types.str;
      description = "The login user of this host (set by mkHost).";
    };
  };
}
