{ config, pkgs, ... }:

{

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
  ];

  hardware.nvidia-container-toolkit.enable = true;
}
