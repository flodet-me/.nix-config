{ pkgs, config, ... }:

{
  stylix = with pkgs; {
    enable = true;
    image = ./planets-3440x1440.png;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
    polarity = "dark";
    fonts = {
      monospace = {
        name = "MonaspiceAr NFM";
        package = nerd-fonts.monaspace;
      };
      sansSerif = {
        name = "MonaspiceAr NF";
        package = nerd-fonts.monaspace;
      };
      serif = {
        name = "MonaspiceAr NF";
        package = nerd-fonts.monaspace;
      };
      emoji = {
        package = pkgs.noto-fonts-color-emoji;
        name = "Noto Color Emoji";
      };
    };
  };
}
