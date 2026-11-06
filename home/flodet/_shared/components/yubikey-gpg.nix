{
  config,
  pkgs,
  ...
}:
{
  programs.gpg = {
    enable = true;

    # My public key (on the YubiKey), imported and fully trusted on every
    # install, so signing, SSH and sops work without manual setup.
    publicKeys = [
      {
        source = ../../../../keys/flodet.asc;
        trust = 5;
      }
    ];

    # https://support.yubico.com/hc/en-us/articles/4819584884124-Resolving-GPG-s-CCID-conflicts
    scdaemonSettings = {
      disable-ccid = true;
      # Don't take exclusive access to the card, otherwise other PC/SC users
      # (e.g. Yubico Authenticator) leave scdaemon unable to reach the key.
      pcsc-shared = true;
    };

    # https://github.com/drduh/config/blob/master/gpg.conf
    settings = {
      personal-cipher-preferences = "AES256 AES192 AES";
      personal-digest-preferences = "SHA512 SHA384 SHA256";
      personal-compress-preferences = "ZLIB BZIP2 ZIP Uncompressed";
      default-preference-list = "SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed";
      cert-digest-algo = "SHA512";
      s2k-digest-algo = "SHA512";
      s2k-cipher-algo = "AES256";
      charset = "utf-8";
      fixed-list-mode = true;
      no-comments = true;
      no-emit-version = true;
      keyid-format = "0xlong";
      list-options = "show-uid-validity";
      verify-options = "show-uid-validity";
      with-fingerprint = true;
      require-cross-certification = true;
      no-symkey-cache = true;
      use-agent = true;
      # No `throw-keyids`: anonymous recipients make the YubiKey fail to decrypt
      # sops files ("Invalid ID"), and sops stores the key fingerprint anyway.
    };
  };

  services.gpg-agent = {
    enable = true;

    # https://github.com/drduh/config/blob/master/gpg-agent.conf
    enableSshSupport = true;
    defaultCacheTtl = 60;
    maxCacheTtl = 120;
    # GUI prompt that doesn't depend on whichever terminal last ran
    # `updatestartuptty`; falls back to curses when there is no display.
    pinentry.package = pkgs.pinentry-gnome3;
  };

  # Shells get SSH_AUTH_SOCK from the gpg-agent module; this also covers
  # GUI apps (editors, git clients) started outside a shell.
  systemd.user.sessionVariables.SSH_AUTH_SOCK = "\${XDG_RUNTIME_DIR}/gnupg/S.gpg-agent.ssh";

  # gpg only uses the keys on the YubiKey after it has seen the card once
  # (`gpg --card-status` creates the key stubs). Run that at login and whenever
  # the YubiKey is plugged in (udev rule in hosts/_shared/components/yubikey-gpg.nix).
  systemd.user.services.yubikey-learn = {
    Unit.Description = "Make gpg learn the keys on the YubiKey";
    Service = {
      Type = "oneshot";
      # no card plugged in is fine
      ExecStart = "-${config.programs.gpg.package}/bin/gpg --card-status";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
