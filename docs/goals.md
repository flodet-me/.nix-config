# Goals

Open goals only (factory skill: goal, Accept lines, items, status). A goal
leaves this file in the commit that finishes it (`factory: G-<n> done`), so
the finished ones are in git history:

```sh
git log --oneline -- docs/goals.md          # every goal, item and done commit
git show fc929d4:docs/goals.md              # G-1 to G-6, the last full version
git log -p --grep 'G-<n>' -- docs/goals.md  # one goal's history
```

