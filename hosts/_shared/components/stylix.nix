{
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [ inputs.stylix.nixosModules.stylix ];

  stylix = {
    enable = true;
    # overrides the value stylix sets itself for this option
    targets.qt.platform = lib.mkForce "qtct";
    image = ../../../assets/planets-3440x1440.png;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
    polarity = "dark";
    fonts = {
      monospace = {
        name = "MonaspiceAr NFM";
        package = pkgs.nerd-fonts.monaspace;
      };
      sansSerif = {
        name = "MonaspiceAr NF";
        package = pkgs.nerd-fonts.monaspace;
      };
      serif = {
        name = "MonaspiceAr NF";
        package = pkgs.nerd-fonts.monaspace;
      };
      emoji = {
        package = pkgs.noto-fonts-color-emoji;
        name = "Noto Color Emoji";
      };
    };
  };
}
