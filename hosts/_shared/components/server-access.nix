# Workstation side of server access: `ssh <server>` just works, and the
# server's host key is pinned from the repo (no trust-on-first-use).
# Add an entry per server; provision-server writes the host key file.
{ lib, ... }:
let
  servers = {
    # TODO: the server's public IPv4 (or DNS name) once it exists
    vps.address = "203.0.113.10";
  };
  hostKey = name: ../../${name}/ssh_host_ed25519_key.pub;
  pinned = lib.filterAttrs (name: _: builtins.pathExists (hostKey name)) servers;
in
{
  programs.ssh.knownHosts =
    lib.mapAttrs (name: server: {
      hostNames = [
        name
        server.address
      ];
      publicKeyFile = hostKey name;
    }) pinned
    // {
      # From https://api.github.com/meta, so git over SSH works on a fresh install
      github = {
        hostNames = [ "github.com" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      };
    };

  programs.ssh.extraConfig = lib.concatStrings (
    lib.mapAttrsToList (name: server: ''
      Host ${name}
        HostName ${server.address}
        User flodet
        StrictHostKeyChecking ${if pinned ? ${name} then "yes" else "ask"}
    '') servers
  );
}
