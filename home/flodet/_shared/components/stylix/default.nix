{ pkgs, ... }:

{
  stylix = with pkgs; {
    enable = true;
    image = ./background.png;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
    polarity = "dark";
    fonts = {
      monospace = {
        name = "MonaspiceNe NFM";
        package = nerd-fonts.monaspace;
      };
      sansSerif = {
        name = "MonaspiceNe NF";
        package = nerd-fonts.monaspace;
      };
      serif = {
        name = "MonaspiceNe NF";
        package = nerd-fonts.monaspace;
      };
      emoji = {
        package = pkgs.noto-fonts-emoji;
        name = "Noto Color Emoji";
      };
    };
  };
}
