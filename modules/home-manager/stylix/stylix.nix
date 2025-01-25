{ pkgs, ... }:

{
  stylix = with pkgs; {
    enable = true;
    image = ./background.png;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
    polarity = "dark";
  };
}
