# 0005: Nix owns the Claude Code configuration in `~/.claude`

Date: 2026-11-27. Status: accepted, implemented on `desktop` and `laptop`
([claude-code.md](../claude-code.md)).
Recorded after the fact on 2026-11-27.

## Context

Claude Code on both workstations needs the same plugins, skills, MCP
servers, permissions and the tools their hooks call, and it must work after
a reinstall without manual `npm`, `pip` or `/plugin install` steps
(docs/claude-code.md). Claude Code itself writes to
`~/.claude/settings.json`, so that file cannot be a read-only store link
(module header in `default.nix`).

## Options

1. Manual setup with `/plugin install`, `/permissions`, ...: still possible
   for trying a plugin, but undone at the next switch.
2. Link a Nix-built `settings.json` read-only: breaks Claude Code's own
   writes.
3. Keep `settings.json` writable and merge the Nix-owned keys into it on
   every activation; install plugins from a service.
4. A home-manager `programs.claude-code` module (obvious alternative; reason
   for not choosing it not recorded).

## Decision

Option 3. The module declares marketplaces, plugins, plugin configs, MCP
servers, permissions, hooks, `env` and `skillOverrides`. The
`claudeCodeSettings` activation deletes every Nix-owned object key
(`ownedObjectKeys`, derived from the managed settings) and merges the managed
settings in with `jq`. The `claude-plugins-sync` user service installs
marketplaces, plugins, MCP servers and graphify idempotently, at login and
when the lists change. `personal.md`, the factory and consult-codex skills
and the agents are linked from the store.

## Consequences

- A change made in Claude Code to a Nix-owned key (`/model`,
  `/permissions`, a `/skills` toggle) lasts until the next switch; arrays are
  replaced whole, so a hand-added `permissions.allow` rule is dropped. Keys
  not declared stay Claude's.
- Plugin code is downloaded from GitHub and not pinned by `flake.lock`
  (except Playwright MCP from nixpkgs and graphify's pinned version).
- A switch disables a removed plugin but does not delete its files; MCP
  servers and graphify are not removed by a switch.
- The sync service needs the network and gives up after 10 starts in an
  hour; then it is run by hand.
- An invalid `settings.json` is left unchanged by the merge.

## Evidence

- `home/flodet/_shared/components/claude-code/default.nix` (header,
  `ownedObjectKeys`, `home.activation.claudeCodeSettings`,
  `systemd.user.services.claude-plugins-sync`), `settings.json`,
  `hosts/_shared/components/claude-code.nix`;
  [claude-code.md](../claude-code.md), "How it works", "Adding or removing a
  plugin"; CLAUDE.md, "Claude Code in this repo".
- `a66fda6` (2026-11-06): module with the activation merge and
  `claude-plugins-sync`. `c9bfb71` (2026-11-06): system half. `85372b8`
  (2026-11-06): `settings.json`. `6f7b11e` (2026-11-27): `skillOverrides`.
  `2919038` (2026-11-27): the merge deletes every Nix-owned object key.

Decided by: user (recorded by agent).
