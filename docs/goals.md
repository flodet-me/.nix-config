# Goals

Open goals only (factory skill: goal, Accept lines, items, status). A goal
leaves this file in the commit that finishes it (`factory: G-<n> done`), so
the finished ones are in git history:

```sh
git log --oneline -- docs/goals.md          # every goal, item and done commit
git show fc929d4:docs/goals.md              # G-1 to G-6, the last full version
git log -p --grep 'G-<n>' -- docs/goals.md  # one goal's history
```

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

## G-9 winvm in nix-config, on every workstation  (status: open)

Goal: "Copy over and integrate windows-vm repo into this repo and make the
winvm command available in the whole system" (moving it in, chosen over a
flake input on 2026-11-27)
Accept:
- `pkgs/winvm/` holds the windows-vm repository with its history (`git log
  -- pkgs/winvm` shows its commits); its own `flake.nix` is gone, the package
  is `pkgs.winvm` / `nix build .#winvm`.
- `winvm` is on PATH on desktop and laptop with its runtime tools (QEMU/KVM,
  swtpm, OVMF with Secure Boot keys, FreeRDP, xorriso, python3, openssh, curl,
  ...) and shell completion; the dev shell needs no `PATH=$PWD`.
- Code is read-only in the store; everything winvm writes (state, cache, iso,
  share, runs, captures, `config.local.env`, `images/*.local.env`) lives in
  `WINVM_HOME`. Its default and the per-host value are documented; desktop
  keeps using the existing data where it is (nothing moved, copied or
  deleted), and a read-only command (`winvm images` or `list`) shows it.
- A build-time check runs shellcheck on winvm and its scripts and a few
  commands that need no VM against a temporary `WINVM_HOME`, with the package
  root not writable; the Check includes it.
- `tests/smoke.sh` runs against the packaged winvm; it is run once on desktop
  after the merge (throwaway VM `smoke-test`, about 5 minutes).
- ADR 0006 records the move (Decided by: user) and the `WINVM_HOME` layout;
  README, docs/agent-isolation.md (winvm in a jail) and AGENTS.md match.
- Gate green.
Not in scope: jail winvm binds, RemoteApp windows, moving the existing data,
archiving or pushing the old windows-vm repository or its GitHub remote,
packaging `windows-host/` (kept as source).
Assumptions:
- History comes in with `git subtree add` (not squashed); the old repository
  stays untouched.
- VM images do not belong in a snapshotted subvolume: `WINVM_HOME` defaults
  outside the hourly `/home` snapshots where the host allows it.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 winvm-package | subtree import, package, WINVM_HOME, system-wide, checks, ADR | open | |
