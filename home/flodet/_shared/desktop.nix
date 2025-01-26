{
  pkgs,
  ...
}:
{
  imports = [
    ./components/firefox.nix
    ./components/vscode.nix
    ./components/stylix
    ./components/font.nix
  ];
}
