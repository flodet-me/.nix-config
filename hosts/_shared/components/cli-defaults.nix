{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # CLI Tools and more
    neofetch

    # Nix
    nixfmt-rfc-style
    nix-output-monitor

    # git
    git
    git-lfs
    lazygit
    git-extras

    ranger
    direnv
    curl
    wget
    python3Full
    pipx

    # archives
    zip
    xz
    unzip
    p7zip

    # utils
    ripgrep # recursively searches directories for a regex pattern
    jq # A lightweight and flexible command-line JSON processor
    yq-go # yaml processor https://github.com/mikefarah/yq
    eza # A modern replacement for ‘ls’
    fzf # A command-line fuzzy finder
    grc # Frontend colouriserr

    # networking tools
    mtr # A network diagnostic tool
    iperf3 # Network throughput tool
    dnsutils # `dig` + `nslookup`
    ldns # replacement of `dig`, it provide the command `drill`
    nmap # A utility for network discovery and security auditing
    ipcalc # it is a calculator for the IPv4/v6 addresses

    # misc
    file
    which
    tree
    gnused
    gnutar
    gawk
    zstd
    gnupg
    openssl

    # productivity
    iotop # io monitoring
    iftop # network monitoring
    ctop # docker top

    bat # fancy cat
    fd # alternative to find
    z-lua # better cd

    # system call monitoring
    strace # system call monitoring
    ltrace # library call monitoring
    lsof # list open files

    # system tools
    sysstat
    lm_sensors # for `sensors` command
    ethtool
    pciutils # lspci
    usbutils # lsusb

    # media tools
    ffmpeg
  ];
}
