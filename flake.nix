{
  description = "Reproducible Windows 10 dev/test VM on QEMU/KVM";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [ qemu_kvm xorriso python3 openssh curl freerdp ];
        shellHook = ''export PATH="$PWD:$PATH"'';
      };
    };
}
