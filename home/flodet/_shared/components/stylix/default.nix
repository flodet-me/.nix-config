{ pkgs, ... }:

{
  stylix = with pkgs; {
    enable = true;
    image = ./background.png;
    base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
    polarity = "dark";
    fonts = {
      monospace = {
        name = "MonaspiceNe Nerd Font Mono";
        package = nerd-fonts.monaspace;
      };
      sansSerif = {
        name = "MonaspiceNe Nerd Font";
        package = nerd-fonts.monaspace;
      };
      serif = {
        name = "MonaspiceNe Nerd Font";
        package = nerd-fonts.monaspace;
      };
    };
  };
}
