# `winvm`: reproducible Windows test VMs on QEMU/KVM (./README.md, ADR 0006).
# The repository tree goes unchanged to $out/share/winvm, read-only in the
# store; winvm writes only to WINVM_HOME. `winvm` is wrapped in place, so the
# paths relative to it keep working (lib/ide's ../../windows-host, Winvm.targets'
# ../../winvm). Test: ./test.nix (part of checks.<system>.scripts).
{
  lib,
  stdenvNoCC,
  makeWrapper,
  installShellFiles,
  bash,
  btrfs-progs,
  coreutils,
  curl,
  e2fsprogs,
  findutils,
  freerdp,
  gawk,
  gnugrep,
  gnused,
  gnutar,
  mitmproxy,
  OVMFFull,
  openssh,
  powershell,
  procps,
  python3,
  qemu_kvm,
  swtpm,
  util-linux,
  xorriso,
}:
let
  # The old dev shell's tools (minus wireshark-cli: winvm never runs it, the
  # captures are for you to open), plus what it took from the host.
  # powershell (~290 MB) runs `winvm vscode setup` / `rider setup`.
  runtimeInputs = [
    btrfs-progs # WINVM_HOME as a subvolume of its own (ADR 0006)
    coreutils
    curl
    e2fsprogs # chattr +C
    findutils
    freerdp
    gawk
    gnugrep
    gnused
    gnutar # deploy
    mitmproxy
    openssh
    powershell
    procps # ps in status
    python3
    qemu_kvm
    swtpm
    util-linux # setsid
    xorriso
  ];
in
stdenvNoCC.mkDerivation {
  pname = "winvm";
  version = "0-unstable";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.difference ./. (
      lib.fileset.unions [
        ./default.nix
        ./test.nix
      ]
    );
  };
  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ];
  buildInputs = [ bash ]; # patchShebangs
  installPhase = ''
    runHook preInstall
    mkdir -p $out/share $out/bin
    cp -r . $out/share/winvm
    # UEFI firmware with Secure Boot and Microsoft keys (OVMF_CODE.ms.fd, OVMF_VARS.ms.fd)
    wrapProgram $out/share/winvm/winvm \
      --prefix PATH : ${lib.makeBinPath runtimeInputs} \
      --set-default WINVM_OVMF_DIR ${OVMFFull.fd}/FV
    ln -s ../share/winvm/winvm $out/bin/winvm
    installShellCompletion --cmd winvm --bash completions/winvm.bash
    # zsh: the same completion through zsh's bash emulation
    mkdir -p $out/share/zsh/site-functions
    cat >$out/share/zsh/site-functions/_winvm_zsh <<EOF
    #compdef winvm
    autoload -U +X bashcompinit && bashcompinit
    source $out/share/winvm/completions/winvm.bash
    _bash_complete -F _winvm
    EOF
    runHook postInstall
  '';
  meta = {
    description = "Reproducible Windows test VMs on QEMU/KVM";
    mainProgram = "winvm";
    platforms = lib.platforms.linux; # x86_64 Windows guests; KVM on x86_64 hosts
  };
}
