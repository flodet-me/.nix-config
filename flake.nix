{
  description = "Reproducible Windows 10 dev/test VM on QEMU/KVM";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [ qemu_kvm xorriso python3 openssh curl freerdp swtpm mitmproxy wireshark-cli ];
        shellHook = ''
          export PATH="$PWD:$PATH"
          # Tab completion for winvm (interactive bash only).
          [[ $- == *i* ]] && source "$PWD/completions/winvm.bash"
          # UEFI firmware with Secure Boot and Microsoft keys enrolled (OVMF_CODE.ms.fd / OVMF_VARS.ms.fd).
          export WINVM_OVMF_DIR="${pkgs.OVMFFull.fd}/FV"
        '';
      };
    };
}
