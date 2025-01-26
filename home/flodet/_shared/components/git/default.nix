{
  programs.git = {
    enable = true;
    lfs = {
      enable = true;
    };
    includes = [
      {
        path = ./gitconfig;
      }
    ];
  };
}
