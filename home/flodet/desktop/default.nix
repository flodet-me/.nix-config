{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

{
  imports = [
    ../_shared/global.nix
    ../_shared/components/vscode.nix
    ../_shared/components/stylix
    ../_shared/components/qmk
    ../_shared/components/stream-controller
    ../_shared/components/easyeffects
    ../_shared/components/gnome.nix
    inputs.sops-nix.homeManagerModules.sops
  ];

  home.username = "flodet";
  home.homeDirectory = "/home/flodet";

  sops = {
    age.keyFile = "/home/flodet/.config/sops/age/keys.txt"; # must have no password!
    # It's also possible to use a ssh key, but only when it has no password:
    #age.sshKeyPaths = [ "/home/user/path-to-ssh-key" ];
    defaultSopsFile = ./secrets.yaml;
    defaultSymlinkPath = "/run/user/1000/secrets";
    defaultSecretsMountPoint = "/run/user/1000/secrets.d";

    secrets.git_mail = {
      # sopsFile = ./secrets.yml.enc; # optionally define per-secret files

      # %r gets replaced with a runtime directory, use %% to specify a '%'
      # sign. Runtime dir is $XDG_RUNTIME_DIR on linux and $(getconf
      # DARWIN_USER_TEMP_DIR) on darwin.
      path = "${config.sops.defaultSymlinkPath}/git_mail";
    };
  };

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    cameractrls
    cameractrls-gtk3
    stremio
    drawio

    lunarvim
    neovim
    nerd-fonts.fira-code
  ];

  fonts.fontconfig.enable = true;

 
  # This value determines the home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update home Manager without changing this value. See
  # the home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "24.11";
}
