{pkgs, lib, ...}:

{
  programs.vscode = {
    enable = true;
    package = pkgs.vscode-insiders;

    profiles.default = {
      extensions = with pkgs.vscode-marketplace; [
        vscodevim.vim
        github.copilot
        github.copilot-chat
        redhat.java
        vscjava.vscode-java-pack
        vscjava.vscode-java-debug
        vscjava.vscode-java-test
        vscjava.vscode-java-dependency
        vscjava.vscode-maven
        vscjava.vscode-gradle
      ];

      userSettings = {
        # Vim settings mirroring neovim config
        "vim.leader" = ",";
        "vim.hlsearch" = true;
        "vim.incsearch" = true;
        "vim.ignorecase" = true;
        "vim.smartcase" = true;
        "vim.useSystemClipboard" = true;
        "vim.sneak" = true;
        "vim.sneakUseIgnorecaseAndSmartcase" = true;

        # jk to escape in insert/visual modes
        "vim.insertModeKeyBindings" = [
          { before = ["j" "k"]; after = ["<Esc>"]; }
        ];
        "vim.visualModeKeyBindings" = [
          { before = ["j" "k"]; after = ["<Esc>"]; }
        ];

        # Normal mode keybindings matching neovim
        "vim.normalModeKeyBindingsNonRecursive" = [
          # Clear search highlight
          { before = ["<leader>" "n"]; commands = [":nohl"]; }
          # Close buffer
          { before = ["<leader>" "b" "d"]; commands = ["workbench.action.closeActiveEditor"]; }
          # File explorer
          { before = ["<leader>" "e"]; commands = ["workbench.view.explorer"]; }
          # Splits
          { before = ["<leader>" "h" "s"]; commands = ["workbench.action.splitEditorDown"]; }
          { before = ["<leader>" "v" "s"]; commands = ["workbench.action.splitEditor"]; }
          { before = ["<leader>" "c" "s"]; commands = ["workbench.action.closeEditorsInGroup"]; }
          # Find files (telescope equivalent)
          { before = ["<leader>" "f" "f"]; commands = ["workbench.action.quickOpen"]; }
          # Live grep
          { before = ["<leader>" "f" "g"]; commands = ["workbench.action.findInFiles"]; }
          # Buffers
          { before = ["<leader>" "f" "b"]; commands = ["workbench.action.showAllEditors"]; }
          # Diagnostics
          { before = ["<leader>" "c" "d"]; commands = ["workbench.actions.view.problems"]; }
          # LSP: go to definition
          { before = ["<leader>" "g" "d"]; commands = ["editor.action.revealDefinition"]; }
          # LSP: references
          { before = ["<leader>" "g" "r"]; commands = ["editor.action.goToReferences"]; }
          # Hover (K)
          { before = ["K"]; commands = ["editor.action.showHover"]; }
          # Code actions
          { before = ["<leader>" "c" "a"]; commands = ["editor.action.quickFix"]; }
          # Rename
          { before = ["<leader>" "s" "r"]; commands = ["editor.action.rename"]; }
          # Diagnostics float
          { before = ["<space>" "e"]; commands = ["editor.action.showHover"]; }
          # Git commands
          { before = ["<leader>" "g" "s"]; commands = ["workbench.view.scm"]; }
          { before = ["<leader>" "g" "c"]; commands = ["git.commit"]; }
          { before = ["<leader>" "g" "l"]; commands = ["git.viewHistory"]; }
          { before = ["<leader>" "g" "p"]; commands = ["git.push"]; }
        ];

        # Editor settings matching neovim
        "editor.lineNumbers" = "relative";
        "editor.scrolloff" = 4;
        "editor.tabSize" = 4;
        "editor.insertSpaces" = true;
        "editor.wordWrap" = "off";
        "editor.rulers" = [80];
      };
    };
  };
}
