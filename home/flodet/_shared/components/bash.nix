{ pkgs, ... }:
{
  programs.bash = {
    enable = true;
    enableCompletion = true;
  };

  # For every shell (bash and zsh); python3 comes from the store, not the PATH
  home.shellAliases = {
    urldecode = "${pkgs.python3}/bin/python3 -c 'import sys, urllib.parse as ul; print(ul.unquote_plus(sys.stdin.read()))'";
    urlencode = "${pkgs.python3}/bin/python3 -c 'import sys, urllib.parse as ul; print(ul.quote_plus(sys.stdin.read()))'";
  };
}
