{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./networking.nix # generated at runtime by nixos-infect

  ];

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "lunar";
  networking.domain = "";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN9l0ZWdNgRv7wS68DquWySb+Zc5x9tJf3viat54Az0b''
  ];


  users.users.flodet = {
    isNormalUser = true;
    description = "flodet";
    extraGroups = [
      "docker"
    ];
  };

  system.stateVersion = "24.11";
}
