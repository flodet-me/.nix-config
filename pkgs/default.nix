# Custom packages. Exposed as flake packages and as pkgs.* through
# overlays/default.nix `additions`; called with `{ pkgs }`.
{ pkgs }:
{
  jail = pkgs.callPackage ./jail { }; # docs/jail.md
}
