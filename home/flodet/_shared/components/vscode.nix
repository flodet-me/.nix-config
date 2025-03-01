{
  pkgs,
  ...
}:
{
  stylix.targets.vscode.enable = false;

  programs.vscode = {
    enable = true;
    package = pkgs.vscodium;
    profiles = {
      default = {
        extensions = with pkgs.vscode-extensions; [
          vscodevim.vim
          jnoortheen.nix-ide
          mkhl.direnv
          arrterian.nix-env-selector
          ms-azuretools.vscode-docker
          editorconfig.editorconfig
          ms-python.python
          github.copilot
          github.copilot-chat
          esbenp.prettier-vscode
          streetsidesoftware.code-spell-checker
          sonarsource.sonarlint-vscode
          mhutchie.git-graph
          waderyan.gitblame
          bierner.markdown-mermaid
          bierner.markdown-preview-github-styles
          bierner.markdown-emoji
          bierner.markdown-checkbox
          bierner.markdown-footnotes

          dracula-theme.theme-dracula
          timonwong.shellcheck
          mads-hartmann.bash-ide-vscode
        ];
        userSettings = {
          "workbench.sideBar.location" = "right";
          "workbench.tree.indent" = 10;
          "workbench.tree.renderIndentGuides" = "always";
          "workbench.iconTheme" = null;
          "workbench.colorTheme" = "Dracula Theme";
          "editor.renderWhitespace" = "all";
          "editor.inlineSuggest.syntaxHighlightingEnabled" = true;
          "editor.fontFamily" = "MonaspiceAr NFM";
          "files.autoSave" = "onFocusChange";
          "files.autoSaveWhenNoErrors" = true;
          "accessibility.dimUnfocused.enabled" = false;
          "explorer.fileNesting.enabled" = true;
          "explorer.confirmDragAndDrop" = false;
          "vim.enableNeovim" = true;
          "vim.highlightedyank.enable" = true;
          "vim.useSystemClipboard" = true;
          "vim.useCtrlKeys" = false;
          "git.enableSmartCommit" = true;
        };
      };
    };
  };
}
