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
