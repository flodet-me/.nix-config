# Everything desktop and laptop share: the login user and its secrets, the
# GNOME desktop, YubiKey, VPNs, theming, health upkeep. A host adds its
# hardware, disk layout (impermanence/disko.nix), hostname and specifics.
{ config, pkgs, ... }:
{
  imports = [
    ../users/flodet
    ./impermanence
    ./uefi-boot.nix
    ./locale.nix
    ./nix-ld.nix
    ./silentboot.nix
    ./pipewire.nix
    ./wireshark.nix
    ./gnome.nix
    ./cli-defaults.nix
    ./yubikey-gpg.nix
    ./firmware-updates.nix
    ./workstation-health.nix
    ./libvirt.nix
    ./claude-code.nix
    ./vpn-fernuni-hagen.nix
    ./mullvad-vpn.nix
    ./server-access.nix
    ./stylix.nix
  ];

  # `nh os switch` without a path
  programs.nh.flake = "/home/${config.host.user}/.nix-config";
  # Builds yield the CPU to the desktop (SCHED_BATCH); max-jobs/cores unchanged.
  nix.daemonCPUSchedPolicy = "batch";

  networking.networkmanager.enable = true;
  services.printing.enable = true;
  # Rootless: the docker group would be root.
  virtualisation.docker.rootless = {
    enable = true;
    setSocketVariable = true; # DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
    # ~/.cache is its own subvolume (cacheSubvolume): images stay out of the /home snapshots
    daemon.settings.data-root = "/home/${config.host.user}/.cache/docker";
  };

  # Closed root paths for agents (docs/agent-isolation.md, design step 1)
  assertions = [
    {
      assertion = builtins.all (u: u == "root") config.nix.settings.trusted-users;
      message = "workstations: only root may be a trusted Nix user";
    }
    {
      assertion = !config.virtualisation.docker.enable && !(config.users.groups ? docker);
      message = "workstations: the docker group is root, use rootless Docker";
    }
    {
      assertion =
        let
          user = config.host.user;
          inGroup =
            g:
            builtins.elem g config.users.users.${user}.extraGroups
            || (config.users.groups ? ${g} && builtins.elem user config.users.groups.${g}.members);
        in
        !builtins.any inGroup [
          "docker"
          "lxd"
          "libvirtd"
          "podman"
        ];
      message = "workstations: ${config.host.user} must not be in docker, lxd, libvirtd or podman, they are root (docs/agent-isolation.md)";
    }
  ];

  # repository jail (pkgs/jail, docs/jail.md); per-user at runtime
  environment.systemPackages = [ pkgs.jail ];

  # QMK/Vial keyboards and the headset
  hardware.keyboard.qmk.enable = true;
  services.udev.packages = [
    pkgs.headsetcontrol
    pkgs.vial
  ];
}
