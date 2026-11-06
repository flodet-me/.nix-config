# What kind of machine a host is. Read by tooling (sops-sync, install-host)
# instead of guessing from host names:
#   workstation: may read the shared secrets (hosts/_shared, home)
#   server:      may read only hosts/<host>/secrets.yaml
{ lib, ... }:
{
  options.host.role = lib.mkOption {
    type = lib.types.enum [
      "workstation"
      "server"
    ];
    default = "workstation";
    description = "Role of this host, used for secrets access (sops-sync).";
  };
}
