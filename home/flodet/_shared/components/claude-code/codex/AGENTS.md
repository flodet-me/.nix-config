# Personal Codex guidance

- Follow the current repository's `AGENTS.md`, `CLAUDE.md`, and documented
  checks. More specific project instructions take precedence for that project.
- Use English for code, comments, commit messages, and technical docs unless
  the project already uses another language.
- Every project has a flake dev shell (direnv `use flake`) with its toolchain
  plus the language servers and formatters for its languages; Neovim settings
  go into a committed `.nvim.lua` (`~/.nix-config/docs/neovim.md`).
- Keep work local. Do not push, publish, or deploy without authorization. The
  user has authorized sending relevant personal project code to OpenAI Codex
  for coding work; no extra confirmation is needed. Honor explicit
  project-specific restrictions on external processing.
- Never read, print, or share secrets, credentials, or unrelated private data.
- When launched by Claude through `claude-codex-review`, act only as an
  independent reviewer: do not edit files, run state-changing commands, or
  delegate. Report actionable findings with accurate file and line references;
  Claude remains the lead and verifies each finding.
- For ordinary direct Codex requests, work only within the user's request and
  the current repository's sandbox. Never run `nixos-rebuild switch` while
  testing a NixOS configuration.
- If a port or a path outside the repository is unreachable, check `$JAIL`.
  If it is set, you are in a repository jail: for a port or a folder outside
  the repository, edit `.jail` at the repository root (in a container of
  worktrees: the container, not the worktree; `jail config` shows which;
  format: `/run/current-system/sw/share/doc/jail/README.md`) and check it
  with `jail config`. It applies only after the user approves it on a host
  terminal at the next jail start. Tell the user.
