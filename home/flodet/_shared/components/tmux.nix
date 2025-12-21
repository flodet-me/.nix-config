{
  pkgs,
  ...
}:
{
  programs.tmux = {
    enable = true;
    plugins = with pkgs.tmuxPlugins; [
      better-mouse-mode
      sensible
      resurrect
      continuum
      yank
    ];

    terminal = "tmux-256color";
    clock24 = true;
    keyMode = "vi";
    mouse = true;
    historyLimit = 100000;

    baseIndex = 1;
    escapeTime = 0;

    extraConfig = ''
      ##
      bind h select-pane -L
      bind j select-pane -D
      bind k select-pane -U
      bind l select-pane -R

      bind -r H resize-pane -L 5
      bind -r J resize-pane -D 5
      bind -r K resize-pane -U 5
      bind -r L resize-pane -R 5

      ##### COPY MODE #####
      setw -g mode-keys vi
      bind -T copy-mode-vi v send -X begin-selection
      bind -T copy-mode-vi y send -X copy-selection-and-cancel
      bind p paste-buffer

      ##### STATUS BAR #####
      set -g status-position bottom
      set -g status-style "bg=colour234 fg=colour137"
      set -g status-left "#[fg=colour39]#S #[fg=colour245]|"
      set -g status-right "#[fg=colour245]%Y-%m-%d #[fg=colour39]%H:%M"

      setw -g window-status-format "#[fg=colour244] #I:#W "
      setw -g window-status-current-format "#[fg=colour39]#[bold] #I:#W "

      ##### QUALITY #####
      set -g detach-on-destroy off
      setw -g automatic-rename on
      set -g set-clipboard on
      set -g terminal-overrides ",*:Tc"

      ##### PLUGINS #####
      set -g @continuum-restore 'on'
      set -g @resurrect-capture-pane-contents 'on'
    '';
  };
}
