# Offline installer ISO for every host with a disko layout (not a host itself).
# Build:  nix build .#installer-iso   — see docs/installer.md
{
  inputs,
  outputs,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  # Every flake input (transitively), so the hosts evaluate without network.
  allInputs =
    flake:
    lib.concatMap (input: [ input.outPath ] ++ lib.optionals (input ? inputs) (allInputs input)) (
      lib.attrValues (flake.inputs or { })
    );

  # Every host with a disko layout for this architecture can be installed
  # from the stick (docs/installer.md: "Making a host installable").
  hosts = lib.filter (
    name:
    let
      cfg = outputs.nixosConfigurations.${name}.config;
    in
    cfg.nixpkgs.hostPlatform.system == pkgs.stdenv.hostPlatform.system
    && (cfg.disko.devices.disk or { }) != { }
  ) (lib.attrNames outputs.nixosConfigurations);
  hostCfg = host: outputs.nixosConfigurations.${host}.config;
  # Shared with the disk layout and the boot rollback
  names = import ../hosts/_shared/components/impermanence/names.nix;

  install-host = pkgs.writeShellApplication {
    name = "install-host";
    runtimeInputs = with pkgs; [
      inputs.disko.packages.${pkgs.stdenv.hostPlatform.system}.disko
      (import ../scripts { inherit pkgs; }).sops-register-host
      age
      gnupg
      util-linux
      cryptsetup
      gnused
      gnugrep
      findutils
    ];
    text =
      builtins.replaceStrings
        [
          "@repo@"
          "@hosts@"
          "@luks@"
          "@sopsKey@"
          "@user@"
          "@dataLuks@"
          "@dataKey@"
          "@dataKeyTmp@"
        ]
        [
          "${inputs.self}"
          (toString hosts)
          names.luks
          names.sopsAgeKey
          (hostCfg (lib.head hosts)).host.user
          names.dataLuks
          names.dataKey
          names.dataKeyTmp
        ]
        (builtins.readFile ./install-host.sh);
  };
in
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  isoImage = {
    edition = "flodet";
    # Faster to build than the default xz; the image is large anyway.
    squashfsCompression = "zstd -Xcompression-level 6";
    storeContents = [
      inputs.self.outPath
    ]
    ++ lib.unique (allInputs {
      inputs = removeAttrs inputs [ "self" ];
    })
    ++ lib.concatMap (
      host:
      let
        cfg = hostCfg host;
      in
      [
        cfg.system.build.toplevel
        cfg.system.build.destroyFormatMount
      ]
      # Build inputs of the few derivations that change when install-host
      # re-encrypts the secrets or edits the config copy, so they can be
      # rebuilt offline (`inputDerivation`'s closure = exactly those inputs).
      ++ map (drv: drv.inputDerivation) [
        cfg.system.build.toplevel
        cfg.system.build.destroyFormatMount # changes with install-host --disk
        cfg.system.build.etc
        cfg.system.build.separateActivationScript
        cfg.system.build.sops-nix-manifest
        cfg.system.build.sops-nix-users-manifest
        cfg.environment.etc."nix/registry.json".source
      ]
      # Outputs read during evaluation (import-from-derivation). Not part of
      # any closure, so they must be listed. Find new ones with:
      #   nix eval --option trace-import-from-derivation true \
      #     .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
      ++ [
        outputs.nixosConfigurations.${host}.pkgs.base16-schemes # stylix
      ]
    ) hosts;
  };

  # Serial console too (VM testing); the last console= (the screen) stays primary.
  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty0"
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # nmtui for Wi-Fi instead of wpa_supplicant
  networking.wireless.enable = lib.mkForce false;
  networking.networkmanager.enable = true;

  # YubiKey for registering the new host's sops key
  services.pcscd.enable = true;
  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  # Also built on its own in CI (shellcheck runs on it): .#install-host
  system.build.installHost = install-host;

  environment.systemPackages = [
    install-host
    pkgs.rsync
    pkgs.yubikey-manager
  ];

  services.getty.helpLine = lib.mkAfter ''

    To install: sudo install-host <${lib.concatStringsSep "|" hosts}>   (docs/installer.md)
  '';
}
