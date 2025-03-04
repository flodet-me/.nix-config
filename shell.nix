{
  pkgs ? import <nixpkgs> { },
  ...
}:
{
  default = pkgs.mkShell {
    NIX_CONFIG = "extra-experimental-features = nix-command flakes";
    nativeBuildInputs = with pkgs; [
      nix
      home-manager
      git
      sops
      ssh-to-age
      gnupg
      age
      nixfmt-rfc-style
      nix-output-monitor
    ];
  };
}
