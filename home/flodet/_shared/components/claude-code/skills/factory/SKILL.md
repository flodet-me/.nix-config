---
name: factory
description: Autonomous software factory. Takes a goal from the user and delivers it as merged, verified code on the local main branch, with the agent owning design, implementation, tests, review and merge. Use when the user states a goal for a project ("/factory [goal]", "make it so that ...", "build ..."), or says "continue the factory" / "factory status".
---

# Factory

The user defines goals. You own everything between the goal and merged code on the local `main`. You are the
orchestrator: you plan, brief and verify; items are built by subagents and only their short reports come back.
Local only: no remotes, pushes, PRs or online services.

This skill replaces these superpowers skills, don't invoke them: `brainstorming` (the goal is the decision),
`writing-plans` (the items table is the plan), `using-git-worktrees` (section 4), `subagent-driven-development`
(sections 4-6), `finishing-a-development-branch` (section 6). The agents use `test-driven-development`,
`systematic-debugging` and `verification-before-completion`.

## 1. Project contract

The project's `CLAUDE.md` needs a `## Factory` section; if it is missing, write it and say so in the report:

```markdown
## Factory

- Check: `<fast command for one item, minutes at most>`
- Gate: `<full release command, exits 0 on a releasable commit>`
- Goals: `docs/goals.md`
- Reserved for a human: <decisions the project keeps for a person, or "none">
- Skills: <project skills and when they run, scoped to one item, e.g. "`/security-audit <site>` when an item touches
  the security core", or "none">
```

- **Check and Gate**: take the project's existing commands. None: the first item of the first goal creates them.
  Run every Check and Gate with `run_in_background`, output to `$logs/<item>-<step>.log`
  (`logs="$(git rev-parse --path-format=absolute --git-common-dir)/factory/logs"; mkdir -p "$logs"`), read its last 30 lines. Never a
  foreground call: those die at 10 minutes.
- **Main**: find the checkout of `main` and use it for every merge, branch deletion and goals-file commit; stop if it
  is dirty (report the files):
  `main=$(git worktree list --porcelain | awk '/^worktree /{w=$2} /^branch refs\/heads\/main$/{print w}')`,
  `git -C "$main" status --porcelain`. Empty (main checked out nowhere):
  `main="$(git rev-parse --path-format=absolute --git-common-dir)/factory/main"; git worktree add "$main" main`.
  Run the Gate on `main` once before the first item: red means item 1 is to
  make it green.
- **Shell variables** (`$main`, `$wt`, `$logs`) don't survive a Bash call: set them again in each call, or write
  the paths out.
- **Project knowledge and agents**: the project's CLAUDE.md, docs and skills are the source for every brief; name
  the files that matter. Spawn `implementer` and `reviewer` by name: a project's own `.claude/agents/` version
  replaces the global one. Other project agents are used where the Skills line or their description fits.
- **Reserved for a human**: copy every rule that requires a person ("ask the product owner", "needs human review").
  Such an item is built to ready-to-merge, then waits for the user.

## 2. Goal

Append to `"$main/docs/goals.md"` (and write the `## Factory` section into `"$main/CLAUDE.md"`), then commit both on
main at once, so item worktrees branch from them:
`git -C "$main" add -- docs/goals.md CLAUDE.md && git -C "$main" commit -m "factory: G-<n> <title>" -- docs/goals.md CLAUDE.md`

```markdown
## G-<n> <short title>  (status: open | done | blocked)

Goal: <the user's words, verbatim>
Accept: <observable criteria, each checkable by a command, test or screenshot>
Not in scope: <what the smallest version leaves out>
Assumptions: <readings you chose where the goal was open>

| Item | What | Status | Commit |
|---|---|---|---|
```

Ask the user only when two readings of the goal lead to different products; otherwise take the smallest reasonable
reading and record it under Assumptions. Ask once, all questions together. Only you edit the goals file.

## 3. Plan

If the goal smells like a known problem class, `/claude-obsidian:wiki-query quick: <question>` (the brain's hot.md is
already in context). Split the goal into items: each one concern, mergeable alone, Check-green alone, ordered by
dependency. Hard-to-reverse choices get an ADR (`Decided by: agent`) inside the item that needs them. Write the items
into the table and commit it.

## 4. Build an item

One item at a time. Two may be built in parallel only when they touch disjoint directories; merges and Gates
still run one at a time.

```sh
wt="$(git rev-parse --path-format=absolute --git-common-dir)/factory/<item>"
git worktree list --porcelain | grep -qxF "worktree $wt" \
  || git worktree add "$wt" factory/<item> 2>/dev/null \
  || git worktree add -b factory/<item> "$wt" main
```

(Not the subagent `isolation` option: the factory needs its own branch name and path to resume.) Spawn `implementer`
with: worktree path, goal id, item, acceptance criteria, the files and docs that matter, the Check command, the
reserved rules, relevant brain lessons. For a resumed branch add `git -C "$wt" log --oneline main..HEAD`.

## 5. Verify (never trust a report)

1. `git -C "$wt" log main..HEAD` has commits, `git -C "$wt" status --porcelain` is empty, the Check passes (yours).
2. Spawn `reviewer` with: worktree path, range `main..factory/<item>`, acceptance criteria, the project's rules and
   the project skills the Skills line names for this item (run scoped, inside the review, never a full run). Not the
   implementer's report.
3. Blocking findings go back to the same implementer (SendMessage). Two failed rounds, or six Check runs for one
   item: mark it blocked with the reason and move on.

## 6. Merge

```sh
git -C "$wt" rebase main || { git -C "$wt" rebase --abort; }   # aborted: the implementer rebases and resolves, then this section again
<Check> in "$wt"                                                # again, on the rebased branch
git -C "$main" merge --no-ff factory/<item> -m "<item>: <what changed>" -m "Goal: G-<n>" \
  && git -C "$main" rev-parse HEAD                              # the item's merge commit: note the printed hash
<Gate> in "$main"                                               # only after a merge that exited 0; the next merge waits for this
```

- Merge exits non-zero: no Gate, no reset (HEAD is not your merge). If `git -C "$main" rev-parse -q --verify MERGE_HEAD`
  prints a hash (a conflict): `git -C "$main" merge --abort`, item back to open, the implementer rebases. No hash
  (main's checkout is in the way): stop and report `git -C "$main" status --porcelain`; the item stays ready to merge.
- Gate green: `git worktree remove "$wt" && git -C "$main" branch -d factory/<item>`; item row `done` with the merge
  commit you noted, committed. `worktree remove` refused: report `git -C "$wt" status --porcelain -uall`, never
  `--force`.
- Gate red: only if `git -C "$main" rev-parse -q --verify HEAD^2` equals `git -C "$main" rev-parse factory/<item>`
  (HEAD is this item's merge), `git -C "$main" reset --keep HEAD^1`; else stop and report. That undoes only the merge
  you just made; branch and worktree stay (a `revert` would make a later re-merge silently drop the item). Item back
  to open with the gate output. If the reset exits non-zero, or `git -C "$main" status --porcelain` prints anything
  afterwards (the Gate left files in main): stop and report that output and `git -C "$main" log --oneline -3`; never
  `--hard`, `stash`, `checkout --` or `clean`, and don't reopen the item.
- Commits use the unsigned agent identity from the environment; never pass `-S` or change it.
- Never push, never rewrite `main` beyond undoing your own just-made merge, never delete a branch with unmerged
  commits.

## 7. Finish

The goal is done when every Accept line is shown true by output you saw. Set the goal's status and commit.

Stop early and report when: a step needs the user (personal rules: destroying data or history, leaving the
machine, secrets, reserved), two items in a row end blocked, or the same Gate failure returns after a fix.

Lessons that outlive the goal (a pattern, a pitfall, a tool lesson): write each as a draft to
`~/brain/inbox/<yyyy-mm-dd>-<slug>.md`, generalized, nothing confidential (personal rules, "Knowledge").

Final message, nothing else:

- Goal: done / blocked, each Accept line with its evidence (command and result).
- Merged: commits, one line each.
- Decided by you: assumptions and ADRs, linked.
- For the user: questions, items waiting for a human, ready-to-merge items, brain drafts to ingest.
- Risks and what was not checked.

`continue the factory`: read the goals file, resume the first open goal at its first open item; existing
`factory/*` branches (`git branch --list 'factory/*'`) are resumed through section 4. `factory status`: summarize the
goals file, change nothing.
