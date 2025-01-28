{ pkgs, ... }:

{
  stylix = with pkgs; {
    enable = true;
    image = ./background.png;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
    polarity = "dark";
    fonts = {
      monospace = {
        name = "FiraCode Nerd Font Mono";
        package = pkgs.nerdfonts.override { fonts = [ "FiraCode" ]; };
      };
      sansSerif = {
        name = "FiraCode Nerd Font";
        package = pkgs.nerdfonts.override { fonts = [ "FiraCode" ]; };
      };
      serif = {
        name = "FiraCode Nerd Font";
        package = pkgs.nerdfonts.override { fonts = [ "FiraCode" ]; };
      };
    };
  };
}
