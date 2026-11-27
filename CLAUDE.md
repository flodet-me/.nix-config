# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

@AGENTS.md

## Factory

- Check: `nix run .#check` (`nix run .#check -- --jail` for jail work; what it runs: `scripts/check/check.sh`)
- Gate: `nix run .#gate`
- Goals: `docs/goals.md`
- Reserved for a human: `nixos-rebuild switch` / `nh os switch` on the running host, `sops` / YubiKey operations (`sops-sync`, `sops-register-host`), `git push`, `make-installer-stick`, `provision-server`, `nix flake update`
- Skills: none

## Claude Code in this repo

- **Declarative config:** Plugins, skills, MCP servers, permissions, and runtime tools are declared in `home/flodet/_shared/components/claude-code/default.nix` and `settings.json` (system half: `hosts/_shared/components/claude-code.nix`). Activation merges Nix-owned keys into `~/.claude/settings.json`, and the `claude-plugins-sync` user service installs plugins/MCP servers/graphify. Add runtime dependencies to `home.packages` and document plugins in `docs/claude-code.md`.
- **Reviews:** Subagents are fine for read-only reviews, but verify every claim before acting on it (e.g., check `nix eval` or closure diffs; two past reviews misread `programs.xwayland` and `nvidia-drm.modeset`).
- **Background long jobs:** Run builds, `act`, and VM tests with `run_in_background` (foreground Bash calls time out at 10 minutes); see [docs/testing.md](docs/testing.md) for timings and mandatory cleanup.
