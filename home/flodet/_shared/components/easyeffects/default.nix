{ pkgs, ... }:

let
  # JackHack96 presets, pinned to the commit the former in-repo copies came from.
  presets = pkgs.fetchFromGitHub {
    owner = "JackHack96";
    repo = "EasyEffects-Presets";
    rev = "069195c4e73d5ce94a87acb45903d18e05bffdcc";
    hash = "sha256-nXVtX0ju+Ckauo0o30Y+sfNZ/wrx3HXNCK05z7dLaFc=";
  };
in
{
  services.easyeffects = {
    enable = true;
    preset = "Perfect_EQ";
  };

  # Only the preset in use. EasyEffects 8 reads presets from ~/.local/share;
  # from ~/.config it tries to copy them over and fails on read-only copies.
  # force: replaces those copies.
  xdg.dataFile."easyeffects/output/Perfect_EQ.json" = {
    source = "${presets}/Perfect EQ.json";
    force = true;
  };
}
