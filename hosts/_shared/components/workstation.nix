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

  networking.networkmanager.enable = true;
  services.printing.enable = true;
  # Rootless: the docker group would be root. Data in ~/.local/share/docker.
  virtualisation.docker.rootless = {
    enable = true;
    setSocketVariable = true; # DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
  };

  # Closed root paths for agents (docs/agent-isolation.md, design step 1)
  assertions = [
    {
      assertion = config.nix.settings.trusted-users == [ "root" ];
      message = "workstations: only root may be a trusted Nix user";
    }
    {
      assertion = !builtins.elem "docker" config.users.users.${config.host.user}.extraGroups;
      message = "workstations: the docker group is root, use rootless Docker";
    }
  ];

  # QMK/Vial keyboards and the headset
  hardware.keyboard.qmk.enable = true;
  services.udev.packages = [
    pkgs.headsetcontrol
    pkgs.vial
  ];
}
