# Goals

Open goals only (factory skill: goal, Accept lines, items, status). A goal
leaves this file in the commit that finishes it (`factory: G-<n> done`), so
the finished ones are in git history:

```sh
git log --oneline -- docs/goals.md          # every goal, item and done commit
git show fc929d4:docs/goals.md              # G-1 to G-6, the last full version
git log -p --grep 'G-<n>' -- docs/goals.md  # one goal's history
```

## G-7 Review items C 27-30  (status: open)

Goal: "do them" (the 2026-11-27 repository review, items C 27-30)
Accept:
- 30: the Check and Gate commands exist once, as flake apps (`nix run .#check`,
  `nix run .#gate`) that report the failing step; CLAUDE.md `## Factory`,
  AGENTS.md and docs/testing.md call them instead of copying command lists; CI
  is unchanged or calls the same checks.
- 27: Easyeffects presets are no longer copied into the repository: fetched
  pinned (hash) from upstream, only the presets in use installed; the installed
  preset files are byte-identical to today's.
- 29: short ADRs (context, options, decision, consequences) for decisions
  already made: impermanence, sops with YubiKey, nixos-unstable as the main
  channel, Nix owning `~/.claude`; each marked as recorded after the fact, with
  the evidence (commits, docs) it rests on.
- 28: `docs/goals.md` keeps only open goals (finished ones stay in git history,
  the file says how to find them), lines wrapped; ADR 0001's status no longer
  says "winvm open" as if planned (winvm binds: user skipped them for now).
- Gate green after each item.
Not in scope: winvm binds, egress allowlist, containers in a jail, microVM
profile.
Assumptions:
- "Decided by" of the after-the-fact ADRs is the user (the decisions predate the
  agent); the agent only records them.
- 28 runs last, so this goal is still in the file while it is open.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 one-check-source | `nix run .#check` / `.#gate`, docs point to them | done | 5c9978c |
| I2 easyeffects-fetch | presets fetched pinned, only those in use | done | e189a98 |
| I3 adrs-after-the-fact | ADRs 0002-0005 | done | 1775158 |
| I4 goals-trim | goals.md open goals only, ADR 0001 status | open | |

## G-8 jail README and .jail help inside a jail  (status: open)

Goal: "Jail needs a readme and in jail i need to be able to edit and add an
.jail file with the necessary knowledge"
Accept:
- `pkgs/jail/README.md` is the user guide (what a jail is, use, `.jail` format
  with examples, approval, restart, reset, limits in short) and ships in the
  package (`share/doc/jail/README.md`); docs/jail.md links to it and keeps
  design, tests and details without repeating the guide.
- Inside a jail, without the nix-config repository: `jail --help` names the
  README path and the `.jail` commands; a `jail config` command (works inside
  and outside) checks the repository's `.jail` with the same parser, prints what
  it would add, what is in effect now, and how it takes effect (approval on a
  terminal at the next start, how to restart); a bad line is named.
- Agents inside a jail know it: the jail sets an instruction (Claude Code and
  Codex) that points to the README and `jail config` when they need a port or
  folder.
- The VM test covers `jail config` inside a jail (good file, bad line, in effect
  vs pending); Gate green.
Not in scope: approving `.jail` from inside a jail (that would let jailed code
approve itself), winvm binds.
Assumptions:
- Editing `.jail` inside a jail already works (it is in the writable
  repository); what is missing is the knowledge and a check, not write access.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 jail-readme-config | README in the package, `jail config`, agent hint, test | open | |
