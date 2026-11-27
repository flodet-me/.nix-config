# Goals

Open goals only (factory skill: goal, Accept lines, items, status). A goal
leaves this file in the commit that finishes it (`factory: G-<n> done`), so
the finished ones are in git history:

```sh
git log --oneline -- docs/goals.md          # every goal, item and done commit
git show fc929d4:docs/goals.md              # G-1 to G-6, the last full version
git log -p --grep 'G-<n>' -- docs/goals.md  # one goal's history
```


## G-11 jail: overview and management commands, completion  (status: open)

Goal: "Add to jail similar features a in winvm, like autocompletion, a more
holistic approach an overview of the vms etc." / "do as you suggest"
Accept:
- Every jail start writes the repository path to
  `~/.local/share/jails/<name>/repo` (host-only; jails started before show `?`).
- `jail list`: one line per jail (name, repository, running: shared unit and
  count of one-off jails, `.jail` approved/pending/none, push URL, size of
  home and cache); a repository that no longer exists shows `gone`.
- `jail status [DIR]`: what `jail config` prints plus running, unit, tmux
  clients, state paths, push URL.
- `jail stop [DIR|NAME] [--all]` stops shared jails.
- `jail reset [DIR|NAME] [--approved|--home|--all]` replaces the README's
  `rm -rf` recipe: refuses while the jail runs, lists what it deletes, always
  asks y/N (no `--yes`); NAME works for `gone` jails.
- `jail help` groups the commands by task.
- `list`, `status`, `stop`, `reset`, `help` are always commands, like
  `config` (a folder of that name: `./list`).
- bash and zsh completion for `jail` (commands, folders, jail names) and
  `jail-push` (repositories with a jail, then branches of its mirror),
  packaged like winvm's.
- README "Manage jails" section, Reset section via `jail reset`; docs/jail.md
  matches.
- The jail VM test covers every command, including reset refusing while
  running and `gone` in `list`; `nix run .#check -- --jail` and the Gate are green.
Not in scope: `jail push` as a subcommand, `list --json`, automatic pruning.
Assumptions: reserved command words approved by the user ("do as you
suggest"); reset always asks.

| Item | What | Status | Commit |
|---|---|---|---|
| I1 jail-manage | repo file, list/status/stop/reset/help, completion, tests, docs | open | |
