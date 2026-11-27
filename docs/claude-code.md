# Claude Code plugins and skills

Everything Claude Code needs on `desktop` and `laptop` is declared in Nix and
works out of the box after `nixos-rebuild switch`: the plugins, skills and MCP
servers, plus the tools their hooks and scripts call. No manual `npm`, `pip`
or `/plugin install` steps.

- `hosts/_shared/components/claude-code.nix` (system): installs
  `claude-code`, and adds the libraries that npm-installed Playwright's
  downloaded Chromium needs to `programs.nix-ld`.
- `home/flodet/_shared/components/claude-code/default.nix` (user): what is
  installed, plus the runtime tools: `node`/`npx` (ponytail hooks,
  frontend-slides PDF export), `jq`, Python with `python-pptx`
  (frontend-slides PPTX import), and `uv` (graphify). `gh` stays installed for
  you; `personal.md` keeps Claude on local git.

The shared workstation module also installs the native `codex` CLI and the
`claude-codex-review` wrapper on both `desktop` and `laptop`. The
`/consult-codex` skill lets Claude request a focused second opinion while
remaining responsible for the goal and all changes. The wrapper runs
`codex exec` with a read-only sandbox and no approval prompts; it cannot edit
the checkout. Prompts and reviewed code are sent to OpenAI for model
processing; this is authorized for personal coding work, with secrets and
credentials excluded. Codex has its own OpenAI login and usage allowance:
authenticate once on each machine with
`codex login`. Claude asks for this review when it would materially help (or
when requested), rather than launching Codex for every task. If Codex has no
available usage, is unauthenticated, or fails, Claude stops or retries only as
the skill directs, continues independently when reasonable, and reports when
the second opinion could not be obtained. The dev shell provides `codex` too.

Codex also gets a shared, Nix-managed user setup on both workstations:
`~/.codex/config.toml` defaults to GPT-5.6 Terra at high reasoning effort,
workspace writes with approvals on request, no shell-command network access,
cached web search, non-login shells, and automatic filtering of environment
variables named like secrets. The activation merges only these owned settings,
preserving Codex's local project-trust entries and authentication. A global
`~/.codex/AGENTS.md` carries personal guidance; project `AGENTS.md` files
remain the source of project-specific rules. Its terminal footer shows the
model, reasoning effort, remaining context, branch, and current directory.
Change the Nix files under
`home/flodet/_shared/components/claude-code/codex/` to keep these defaults
(`config.toml` the owned settings, `merge-config.py` the merge).

The dev shell also has `claude-code`, but not the plugins.

## How it works

- **Activation** (first boot after an install and every `nixos-rebuild switch`)
  merges the Nix-owned settings into `~/.claude/settings.json` with `jq`:
  `home/flodet/_shared/components/claude-code/settings.json` (model
  `claude-opus-5-5` (Opus 5.5), advisor `fable` (newest Fable this Claude Code knows), effort, theme, Remote Control on every session, fullscreen TUI with compact (focus) view, permissions, ...) plus the declared
  `extraKnownMarketplaces`, `enabledPlugins` and `pluginConfigs`. Nix owns
  those keys: changing them in Claude Code (`/model`, `/permissions`, ...)
  works until the next switch, then the repo wins. To keep a change, edit
  `settings.json` in the repo. Keys not declared there stay Claude's;
  `autoMode.environment` and `autoMode.allow` are Nix-owned (both start with
  `"$defaults"`, so the built-in entries stay); `allow` adds one exception:
  the factory may `reset --keep` its own just-made merge on local `main` after
  a red Gate, so an unattended run isn't blocked there. Check the result with
  `claude auto-mode config` and `claude auto-mode critique`. The merge replaces arrays as a whole, so a `permissions.allow`
  rule added by hand is dropped at the next switch. It deletes every Nix-owned
  object key (`permissions`, `env`, `hooks`, `worktree`, `skillOverrides`, ...)
  before merging, so an entry removed in Nix goes away too: `ownedObjectKeys`
  in `default.nix` derives that list from the managed settings (every
  top-level key whose value is an object), and an assert fails the evaluation
  if it lacks `permissions` or `worktree`. If `~/.claude/settings.json`
  is not valid JSON the merge leaves it unchanged and says so.
- **Session behavior** set there: `remoteControlAtStartup` (every session is
  remote controllable through Anthropic's servers) with `agentPushNotifEnabled`
  (Claude may push a mobile notification while Remote Control is connected);
  `autoContinueAtUsageLimit: true` (when a claude.ai subscription limit pauses
  an open interactive session, wait for its reset and continue the interrupted
  task automatically); `autoCompactWindow:
  250000` (compact at 250k tokens instead of near the 1M window, so a long
  session doesn't resend ~1M tokens per turn); `attribution: false` (Claude's commits already carry the
  `Merge Goblin` author, no trailers or claude.ai session links in local history).
  Claude cannot inspect the remaining account quota itself; Claude Code owns
  that state and displays the reset time. It will not auto-continue if the
  machine slept through the reset for about 30 minutes, when it has already
  retried three continuations, or after the session exits. The desktop
  notification hook reports automatic continuation, a stale wait, and a
  disabled wait so the user can intervene.
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY` and
  `DO_NOT_TRACK` skip Claude Code's feature-flag fetch (no `/skill-doctor`,
  `/import`, and Remote Control only with conditions), so neither `env` nor
  `privacy.nix` sets them (only `DISABLE_ERROR_REPORTING`; the nixpkgs wrapper
  disables the autoupdater). `env` is Nix-owned as a whole, so a variable
  removed here is removed from `~/.claude/settings.json` too.
  Opus effort is pinned to `high` in `modelSettings` too, because `/effort`
  stores a per-model value that would otherwise outlive a switch.
  `tui: fullscreen` and `viewMode: focus`
  (the compact view, which needs the fullscreen renderer).
- **Personal instructions** (`personal.md` in the module, linked to
  `~/.claude/rules/personal.md`, read in every session): who I am, answer
  language, stack (every project: flake dev shell with its language servers,
  `.nvim.lua` for editor settings, [neovim.md](neovim.md)), local first, what Claude decides and what it asks,
  knowledge (project, brain, personal vault), done. Edit the file in the repo and switch; keep it short,
  it costs tokens in every session. `/memory` shows which files are loaded.
- **Skills reserved for you** (`skillOverrides`, values `on`, `name-only`,
  `user-invocable-only`, `off`): `user-invocable-only` hides a skill from
  Claude but keeps `/name`, for the skills reserved for you: `graphify`
  (its line in `~/.claude/CLAUDE.md` says `/graphify`), and what `personal.md`
  reserves: `claude-obsidian:save`, `claude-obsidian:wiki-ingest`,
  `superpowers:brainstorming`. Claude Code 2.1.329 applies it to
  `~/.claude/skills` skills (`graphify`, keyed by bare name) only: its
  binary says "Plugin skills can't be turned off individually" and reads
  overrides of plugin skills only for claude.ai-synced ones. The three plugin
  entries are inert there (kept for a version that honours them);
  `personal.md` still keeps Claude off them.
- **Status line** (`claude-statusline` in the module): model, folder and git
  branch, context used, session cost, ponytail badge. Watch the context
  number: around 60-70 % is a good moment for `/compact` or `/clear`.
- **Desktop notification** (`Notification` hook, `notify-send`, matcher
  `permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled`)
  when Claude waits for a permission or your input, or when a usage-limit wait
  continues, becomes stale after sleep, or is disabled, so you can work
  elsewhere meanwhile.
- **Permissions:** interactive sessions start in auto mode, where Claude Code
  drops the blanket `Bash` allow and its classifier decides on each shell
  command (tuned by `autoMode`); `Bash` applies again in manual mode
  (Shift+Tab) and in `claude -p`. `Edit` and `Write` are allowed in general,
  and so are the Playwright MCP tools that only drive or read the browser
  (`mcp__playwright__browser_navigate`, `..._click`, `..._snapshot`, ...);
  `browser_run_code_unsafe`, `browser_evaluate` (run arbitrary code) and
  `browser_file_upload` (sends a local file to a page) still ask.
  In every mode there is a long deny list (secrets and sops files, gpg/ykman,
  privilege escalation, disk tools, pushes and `gh`, `nixos-rebuild`/`nh`)
  and `disableBypassPermissionsMode`. The Bash denies match the command text,
  so `cat <secret>` is denied but another spelling of the same read is not.
  The `Read(...)` and `Edit(...)` denies cover the file tools and the file
  commands Claude Code recognizes inside a Bash command (`cat`, `head`,
  `tail`, `sed` and `<` against `Read`; `tee`, `>` and `>>` against `Edit`),
  not a command that reads without naming the file or a script that opens it
  itself. A path from the filesystem root needs two slashes
  (`Read(//run/secrets/**)`): with one, a rule in the user settings is relative
  to `~/.claude`, and one without a slash (`Read(**/.env)`) only covers the
  session's working directory, not a worktree outside it, hence
  `Read(//**/.env)`. `Bash(rm -rf /*)` and its siblings also match every
  `rm -rf <absolute path>`; clean up with `find <dir> -mindepth 1 -delete`.
- **`claude-plugins-sync`** downloads and installs everything:
  marketplaces and plugins (`claude plugin …`), the user-scope MCP servers
  (`claude mcp add-json -s user`), and graphify (`uv tool install
  graphifyy==<graphifyVersion>`, then `graphify install`). Every step is
  idempotent.
- It runs **automatically** as the systemd user service
  `claude-plugins-sync`: at login, and on `nixos-rebuild switch` whenever the
  declared lists change. It retries every 60 s and gives up after 10 starts
  within an hour (about 10 minutes offline; a broken plugin name must not
  retry forever). Then it stays failed (`systemctl --user --failed`) until the
  next login: run `claude-plugins-sync` by hand.
  Check it with `systemctl --user status claude-plugins-sync` or
  `journalctl --user -u claude-plugins-sync`. Running
  `claude-plugins-sync` by hand does the same.

Plugin code lives in `~/.claude/plugins/` and is downloaded from GitHub, so
it is **not** pinned by `flake.lock`: a fresh install gets each plugin's
current version. Two exceptions: Playwright MCP comes from nixpkgs, and
graphify is pinned (`graphifyVersion` in `default.nix`).

## After a reinstall

`nixos-rebuild switch --flake .#<HOST>`, log in, wait for the sync service
(first run downloads a few hundred MB), then start Claude Code. Check with
`/plugin`, `/mcp` or `claude plugin list`.

## Adding or removing a plugin

1. Edit the `marketplaces` / `plugins` / `pluginConfigs` / `mcpServers`
   lists in `home/flodet/_shared/components/claude-code/default.nix`. The
   marketplace name must match `name` in the repo's
   `.claude-plugin/marketplace.json`. Prefer a plugin from
   `claude-plugins-official` when one exists (no extra marketplace).
   If its hooks or scripts call a tool, add that tool to `home.packages`.
2. `nixos-rebuild switch`. The sync service installs it.
3. Add a section to [Installed plugins](#installed-plugins) below.

`enabledPlugins` and `extraKnownMarketplaces` come only from Nix: activation
replaces them, so removing a plugin or marketplace from the lists disables it
at the next switch. Its downloaded files stay in `~/.claude/plugins/`; to
delete them, run `claude plugin uninstall <plugin>@<marketplace>` (and
`claude plugin marketplace remove <name>`) once. MCP servers and graphify
are not removed by a switch: `claude mcp remove -s user <name>`,
`graphify uninstall`.

Trying a plugin interactively with `/plugin install` is fine, but it is
disabled again at the next switch; add it to the Nix lists to keep it.

Sensitive plugin options (e.g. ponytail's `webhookToken`) are kept in the
system keychain by Claude Code; never put them into `pluginConfigs`.

### NixOS pitfalls

- Anything that downloads prebuilt Linux binaries (`npx playwright install`,
  uv-managed Pythons, prebuilt wheels) only runs through nix-ld. Add missing
  libraries to `programs.nix-ld.libraries` in the system component;
  `ldd <binary> | grep "not found"` shows what is missing.
- Prefer a nixpkgs package over an `npx …@latest` MCP server when one
  exists, as done for Playwright.

## Maintenance

```sh
claude plugin marketplace update        # refresh all marketplace catalogs
claude plugin update <plugin>@<mkt>     # update one plugin (restart needed)
claude plugin details <plugin>@<mkt>    # what it ships + context-token cost
```

Plugins run hooks and scripts on this machine as `flodet`; only add
marketplaces from sources you trust.

## Which tool for which job

Several plugins can do the same thing. Use this one, ignore the others:

| Job | Use | Not |
| --- | --- | --- |
| Deliver a goal end to end, unattended | `/factory <goal>` (see [Factory](#factory)) | — |
| Sharpen a rough idea with me | superpowers `brainstorming` (only when you ask) | — |
| Record a decision | ADR by hand, format in `personal.md` | — |
| Understand an unfamiliar or large repo | `/graphify .`, then ask | — |
| Plan and implement by hand | superpowers `writing-plans` → `subagent-driven-development` (or `executing-plans`, cheaper) | built-in plan mode for small things |
| Tests first, bug hunts | superpowers `test-driven-development`, `systematic-debugging` | — |
| Library/API docs | built-in web search/fetch ("check the current docs of X") | — |
| UI | `/impeccable:impeccable` (craft, polish, audit, critique; enable per project), check it with Playwright MCP | — |
| Review before commit | `/ponytail-review` | superpowers `requesting-code-review` |
| Deep review of a branch | built-in `/code-review`, `/security-review` | — |
| Whole repo health | `/ponytail-audit` | — |
| Talk/demo deck | `/frontend-slides:frontend-slides` | — |

A goal: `/factory <goal>`. A small fix: just ask, then `/ponytail-review`.

Local first: Claude itself and things installed on this machine, nothing that
needs another online service, account or subscription at runtime (downloads
at install time are fine). No plugin or MCP server that sends data to a
third-party service (Context7 was dropped for that reason); the claude.ai
connectors are off in Claude Code (`ENABLE_CLAUDEAI_MCP_SERVERS=false`), and
so is syncing skills and plugins from the claude.ai account
(`syncClaudeAiSkills`, `syncClaudeAiPlugins`: false; it brought ~45 skills,
among them finance, productivity and the docx/pptx/xlsx/pdf skills). Exception
you accept knowingly: impeccable's new-design flow fetches visual directions
from impeccable.style (see [impeccable](#impeccable-impeccableimpeccable)).

Not added on purpose: GitHub MCP and `gh` (local git only), more review
toolkits (`code-review`, `pr-review-toolkit`, `feature-dev` plugins duplicate
the above), Linear/Notion/Figma/Sentry (add one when you use that service:
each is a `…@claude-plugins-official` line), and language servers for languages
not in `~/Projects` yet (see [Language servers](#language-servers-rust-analyzer-lsp-typescript-lsp-csharp-lsp)).

## Factory

`/factory <goal>` in a project: you state the goal, Claude owns the rest and
merges verified code into the local `main` (never pushes). Files:
`components/claude-code/skills/factory/SKILL.md` (the orchestrator) and
`agents/implementer.md`, `agents/reviewer.md`, linked into `~/.claude/` by
home-manager; the ownership rules are in `personal.md` ("Deciding").

- Per project it keeps a `## Factory` section in `CLAUDE.md` (a fast Check
  per item, the full Gate, goals file, decisions reserved for a human,
  project skills and when they run) and `docs/goals.md` (goals, acceptance
  criteria, items), committed on `main` as soon as they are written.
- One item at a time (two built in parallel only when they touch disjoint
  directories; merges and Gates always one at a time): a
  worktree from the current `main` under the repo's git dir
  (`factory/<item>`), an `implementer` subagent, the Check run again by the
  orchestrator, a `reviewer` subagent that sees the diff and the criteria (not
  the implementer's story), rebase, `merge --no-ff` in the checkout of
  `main` (a merge that fails is never reset: a conflict is aborted and goes
  back to the implementer, a checkout that is in the way stops the run), the
  Gate on `main`; red: `reset --keep` to that merge's first parent (a reset
  that fails or leaves `main` dirty stops the run; a revert would make the
  re-merge drop the item). Checks and Gates run in the
  background with logs under `<git dir>/factory/logs/` (a foreground call dies
  at 10 minutes). It stops when `main`'s checkout is dirty.
- It replaces superpowers' `brainstorming`, `writing-plans`,
  `using-git-worktrees`, `subagent-driven-development` and
  `finishing-a-development-branch` (they ask the user, offer PRs, or merge at
  the end by menu); the agents use its TDD, debugging and verification skills.
- A project's `.claude/agents/implementer.md` or `reviewer.md` replaces the
  global one (project agents beat user agents by name). Project skills can't
  replace `factory` (personal skills win), so the `Skills:` line says which
  project skills run on which items.
- Lessons go as drafts to `~/brain/inbox/`; you ingest them (see
  [Brain](#brain-shared-knowledge)).
- `worktree.baseRef` is `head` in `settings.json`: Claude Code's own worktrees
  (`--worktree`, `EnterWorktree`, subagent `isolation: worktree`) branch from
  the local HEAD. The default, `fresh`, branches from `origin/<default
  branch>`, which is old in a repo that is never pushed (seen 2026-11-25 in
  command-and-control: 493 commits behind). The factory still makes its own
  worktrees: it needs the branch name and path to resume.
- Identity: every Claude session (not only the factory) commits as
  `Merge Goblin <develop@flodet.me>`, unsigned. `env` in `settings.json` sets
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` and, through `GIT_CONFIG_COUNT`,
  `commit.gpgsign=false` and `tag.gpgsign=false`, which beat every git config
  file. Your own shell keeps your signed identity; Claude's commits are told
  apart by author (`git log --author='Merge Goblin'`).
- A project's own CLAUDE.md rules that reserve a decision for a person win:
  those items stop at ready-to-merge.
- `continue the factory` resumes, `factory status` summarizes.

## Brain (shared knowledge)

One Obsidian vault, `~/brain`, holds what is true beyond a single project;
the claude-obsidian plugin (`claude-obsidian@agricidaniel-claude-obsidian`,
<https://github.com/AgriciDaniel/claude-obsidian>, MIT, plain Markdown, no
telemetry) reads and writes it from every project. `personal.md`
("Knowledge") says what goes where: project knowledge in the project, lessons
that outlive it in the brain.

- `env` (set in `default.nix`, path from the home directory):
  `CLAUDE_OBSIDIAN_VAULT` picks the brain for every skill from any directory
  (it beats the working directory, which also keeps the personal vault safe);
  `CLAUDE_OBSIDIAN_SESSION_CONTEXT_VAULT` repeats that exact path as the
  explicit allow-list for startup context, since `~/brain` is outside each
  project;
  `CLAUDE_OBSIDIAN_SESSION_CONTEXT=1` injects the vault's bounded
  `wiki/hot.md` at startup, resume, `/clear`, compaction and fork. The plugin
  sanitizes and bounds the context; the hook never writes. Python 3 is on
  `PATH` for the plugin hook.
- Writing: Claude never calls `save` or `wiki-ingest` itself (the skills
  require your explicit request). It drops drafts into `~/brain/inbox/` and lists
  them; you read them and run `/claude-obsidian:wiki-ingest`. Reading:
  `/claude-obsidian:wiki-query`, any time; `/claude-obsidian:wiki-lint` finds
  dead links and orphans.
- 15 skills, of which wiki, wiki-query, wiki-ingest, save and wiki-lint
  matter here; check their listing cost with `/skill-doctor`.
- Keep `wiki/hot.md` short (under ~4 KiB): it is injected into every session.
  For scale, the other always-loaded texts: personal.md ~1000
  tokens, superpowers ~850, ponytail ~700 plus a codebase map of up to 2,000
  characters in code projects.
- `wiki-retrieve`'s optional reranking talks only to a local Ollama
  (`127.0.0.1:11434`); nothing else leaves the machine unless asked.
- Open it in Obsidian with "Open folder as vault" next to the personal vault.
  It stays local; it is not in Nextcloud.
- First use, once after the switch: run `claude-plugins-sync`, restart Claude
  Code, then run `/claude-obsidian:wiki` and ask it to initialize or adopt the
  configured vault at `~/brain`. Review and approve its preview. It creates
  `wiki/`, `inbox/`, `.raw/`, `.obsidian/`, `.claude-obsidian.json` and
  `.gitignore`. The startup hook stays silent until `wiki/hot.md` exists;
  queries explain when the vault is not ready. If startup context is still
  absent, check that `~/.claude/settings.json` contains the two
  `CLAUDE_OBSIDIAN_SESSION_CONTEXT*` values above, then restart Claude Code.
  The plugin's own doctor is `/claude-obsidian:wiki-lint`; `git -C ~/brain init`
  is optional local history.

## Token usage

Already set up: prompt caching and auto-compact (Claude Code defaults), MCP
tool schemas load only when a tool is needed (tool search), and only a few
plugins, because every installed skill and agent adds its description to each
session (ECC alone was several thousand tokens). Before adding a plugin, check
`claude plugin details <plugin>@<mkt>` for its context cost.

Measure first: `/skill-doctor` shows each skill's context cost and how often
it is used; the Skills row of `/context` shows the listing's size. The listing
gets 1% of the context window; when it overflows, Claude Code drops the
descriptions of the least-used skills, and Claude then picks skills at random.
The fix is fewer skills, not a bigger budget (`skillListingBudgetFraction`):
2026-11-25 went from about 105 listed skills to about 40.

Habits that save the most without hurting results:

- `/clear` when you start an unrelated task; `/compact <what to keep>` in a
  long one instead of waiting for auto-compact.
- `/context` shows what fills the window, `/cost` what a session used.
- Name files (`@path/file`) instead of "find where we do X".
- Wide searches over many files: let Claude use a subagent (Explore); only
  its conclusion comes back into the main context.
- Plan mode (Shift+Tab) for bigger changes: a wrong plan is cheaper to fix
  than wrong code.
- Keep project `CLAUDE.md` files short and factual: they are read every session.

## Token tools

Two CLIs in `home.packages` of the Claude Code component, both from nixpkgs:

- **ccusage**: reports Claude Code (and Codex) token use and cost from the
  local session logs in `~/.claude/projects`. `ccusage daily`, `ccusage
  session`, `ccusage blocks` (5-hour billing windows). The binary embeds a
  price snapshot and the LiteLLM price list URL (verified with `strings`); a
  `ccusage daily` made no network call under `strace`, but when it fetches is
  not checked. Use `-O` (`--offline`) to stay on the cached prices.
- **ast-grep**: structural search and rewrite on the syntax tree
  (`ast-grep run -p 'foo($A)' -l rust`). Plain `grep`/`rg` stay fine for text.

The rtk trial (a PreToolUse hook rewriting Bash commands through `rtk`) ended
on 2026-11-27: a replay of 400 real commands rewrote 1% of them and saved 380
tokens in total. Git history has the hook, its guard and its test.

## Installed plugins

### ponytail (`ponytail@ponytail`)

Source: <https://github.com/DietrichGebert/ponytail> · docs: its `README.md`.

"Lazy senior dev" mode: always-on skill that pushes for the smallest change
that fully solves the task (reuse existing code → stdlib → platform feature →
installed dependency → only then new code), while never cutting validation,
error handling, security or accessibility. Leaves a small test for risky
logic and ends replies with what was skipped.

| Command | Use |
| --- | --- |
| `/ponytail [lite\|full\|ultra\|off]` | Set the intensity (default `full`) or turn it off |
| `/ponytail band [on\|off]` | Show/hide the cost/tokens/tests band above the prompt |
| `/ponytail band import` | Import past sessions into the local board |
| `/ponytail-review [target]` | Review a change (`uncommitted`, `staged`, `branch`, PR link) incl. code it touches |
| `/ponytail-audit` | Ranked whole-repo audit: bugs, security, load, untested risky code, bloat |
| `/ponytail-debt` | Collect `shortcut:` comments into a debt ledger |
| `/ponytail-gain`, `/ponytail-help` | Benchmark numbers, quick reference |

Best use:

- Leave it on `full` for everyday work; use `lite` when you want more
  scaffolding/explanation, `off` for exploratory or teaching sessions.
- Run `/ponytail-review` before committing, `/ponytail-audit` when picking up
  an unfamiliar repo.
- Run `/ponytail-debt` now and then so `shortcut:` comments don't rot.
- The board data stays local in `~/.config/ponytail/band/` (`ledger = true`);
  no webhook is configured.

- Its ruleset is injected into subagents only for `implementer`
  (`PONYTAIL_SUBAGENT_MATCHER=^implementer$` in `env`): Explore, Plan and the
  reviewer don't pay ~700 tokens for rules about writing code.
- Its status line badge comes from `~/.claude/ponytail-statusline.sh`, which
  ponytail refreshes at session start but only creates when no status line is
  set; `claude-plugins-sync` seeds an empty one.

### superpowers (`superpowers@claude-plugins-official`)

Source: <https://github.com/obra/superpowers> · docs: its `README.md`.

15 process skills: `writing-plans`, `subagent-driven-development` /
`executing-plans`, `test-driven-development`, `systematic-debugging`,
`verification-before-completion`, `requesting-code-review`,
`using-git-worktrees`, `finishing-a-development-branch`, `brainstorming`,
`writing-skills` and a few more. A SessionStart hook injects
`using-superpowers` (~3.4 KB) on startup, `/clear` and compaction; it tells
Claude to check for a fitting skill before every task.

Best use:

- The factory's implementer preloads `test-driven-development` and
  `verification-before-completion`, a red Check goes through
  `systematic-debugging`; the factory itself replaces the planning, worktree,
  SDD and finishing skills (see [Factory](#factory)).
- The official marketplace auto-updates by default and pins superpowers to a
  commit, so it moves on its own; the third-party ones (ponytail, impeccable,
  claude-obsidian) don't.
- `brainstorming` asks you questions before building; `personal.md` says a
  goal you state is already agreed, so it runs only when you ask.
- `finishing-a-development-branch` offers a PR; with local git the answer is
  always the local merge.

### frontend-slides (`frontend-slides@frontend-slides`)

Source: <https://github.com/zarazhangrui/frontend-slides> · docs: its
`README.md`, `STYLE_PRESETS.md`.

Builds single-file, animated HTML slide decks (no build step), or converts a
`.pptx` into one.

- `/frontend-slides:frontend-slides` then e.g. "a 10-minute talk about
  impermanence on NixOS". It asks about content, shows 3 style previews,
  builds the deck and opens it in the browser.
- "Convert talk.pptx to a web slideshow" extracts text, images and notes
  (needs `python-pptx`, provided).
- PDF export: ask for it; the bundled `export-pdf.sh` `npm install`s
  Playwright into a temp dir and screenshots each slide (needs `node` and the
  nix-ld libraries, provided). Animations are not kept in the PDF.

Best use: name a style preset (see `STYLE_PRESETS.md`) or give a reference
look up front to skip a round of previews; keep one message per slide in the
brief.

### graphify (uv tool + `~/.claude/skills/graphify`)

Source: <https://github.com/safishamsi/graphify> · docs:
<https://docs.graphify.com>.

Not a plugin: a Python CLI (`graphifyy` on PyPI, binary `graphify` in
`~/.local/bin`) that installs its own skill. Turns a folder (code, docs,
papers, images) into a knowledge graph: `graphify-out/graph.json`,
`graph.html` (interactive) and `GRAPH_REPORT.md`. Code is parsed
deterministically (tree-sitter, no LLM); docs and images are read by Claude
subagents.

- `/graphify .` builds the graph for the current repo; `/graphify --update`
  after changes. `graphify update .` refreshes only the code part, without
  Claude.
- `graphify query "…"`, `graphify path "A" "B"`, `graphify explain "X"`
  answer questions from the graph.
- `graphify claude install` (per repo, optional) adds a CLAUDE.md section and
  a PreToolUse hook so Claude reads `GRAPH_REPORT.md` before architecture
  questions; `graphify claude uninstall` reverts it.
- `graphify install` also adds a short pointer to `~/.claude/CLAUDE.md`.
- Pinned to `graphifyVersion` in `default.nix`: unpinned it moved from
  0.9.103 to 0.9.120 on its own when a new Python rebuilt the uv venv, and its
  skill is a prompt that runs in every project. Since 0.9.107 the skill has a
  "Graphify Cloud (hosted)" section that makes Claude suggest the hosted
  service; the sync script cuts it out after `graphify install` (so each sync
  logs a `SKILL.md.bak`). To update: raise the pin, switch, read the new
  `~/.claude/skills/graphify/SKILL.md`.

Best use: on a large or unfamiliar repo, build the graph once, then ask
architecture questions against it instead of letting Claude grep everything.
Add `graphify-out/` to `.gitignore` unless you want it committed.

### Playwright MCP (user-scope MCP server `playwright`)

Source: nixpkgs `playwright-mcp` (Microsoft's `@playwright/mcp`, with
nixpkgs' browsers). Registered via `claude mcp add-json -s user`, not the
official `playwright` plugin, whose `npx @playwright/mcp@latest` downloads
browsers NixOS can't run.

Gives Claude a real browser: navigate, click, fill forms, screenshots,
console and network logs. Ask e.g. "open localhost:3000 and check the login
form works". Check it's connected with `/mcp`. Its browsing tools run without
a prompt; running code in the page and uploading files ask (see
Permissions above).

### Language servers (`rust-analyzer-lsp`, `typescript-lsp`, `csharp-lsp`)

From Anthropic's official marketplace, chosen by what `~/Projects` is written
in (C#, TypeScript/JavaScript, Rust). Claude gets compiler diagnostics after
each edit and exact go-to-definition/references instead of grepping: fewer
wrong edits and fewer tokens. The servers (`rust-analyzer`,
`typescript-language-server`, `csharp-ls`) are in `home.packages`; the
project's own toolchain (`dotnet` SDK, `node_modules/typescript`, `cargo`)
comes from its dev shell, so start Claude inside it (direnv). For another
language add its `…-lsp@claude-plugins-official` plugin and server binary
(`pyright-lsp` + `pyright`, `gopls-lsp` + `gopls`, ...).

### impeccable (`impeccable@impeccable`)

Source: <https://github.com/pbakaus/impeccable> · docs: <https://impeccable.style>.

The successor of Anthropic's `frontend-design`: one skill, `/impeccable
<command>` (`craft`, `polish`, `audit`, `critique`, `harden`, `adapt`, ...),
a deterministic anti-pattern detector and 5 design agents. Its hooks run on
SessionStart, after every Edit/Write and at every turn end (a 30 s "design
deep pass"), so it is installed but **off by default** (`optInPlugins` in
`default.nix`). Turn it on in a UI project's `.claude/settings.json`:
`{"enabledPlugins": {"impeccable@impeccable": true}}` (project settings win).

- The engine is a binary the launcher downloads into `~/.impeccable/` (checked
  against shipped checksums) and runs through nix-ld. After the switch check
  it once: `/impeccable audit` on a web file; an exec error means nix-ld lacks
  a library (`hosts/_shared/components/claude-code.nix`).
- Online parts: anonymous telemetry, off with `npx impeccable telemetry off`
  once, or `"telemetry": false` in a project's `.impeccable/config.json` (not
  `DO_NOT_TRACK`: that also skips Claude Code's feature flags). The new-design flow
  (`concept-seed`) fetches visual directions from impeccable.style; polish,
  audit, critique and the detector work offline.
- Live mode's Apply would start `claude` with bypassed permissions;
  `IMPECCABLE_LIVE_COPY_AGENT=off` in `env` disables it.

### Removed: agent-skills (`agent-skills@addy-agent-skills`) and frontend-design

Removed 2026-11-25. agent-skills: 25 skills built around slash commands you
drive by hand (`/spec`, `/planning`, `/build`); superpowers covers the same
process for an autonomous loop with fewer skills. frontend-design: replaced by
its successor impeccable. To restore, add the line back to `plugins` (and the
`addy-agent-skills` marketplace) in `default.nix`.

### Removed: mattpocock-skills (`mattpocock-skills@claude-plugins-official`)

Removed 2026-11-25: 14 skills, most of them duplicates (TDD, review,
diagnosis, spec) whose descriptions cost tokens in every session and made the
choice between near-identical skills random. `grilling` was the reason it was
here; goals now go to `/factory`. To restore, add the line back to `plugins` in `default.nix`.

### Removed: ECC (`ecc@ecc`)

Was installed until 2026-11; removed because it duplicated everything above
(~300 skills, ~70 agents, its own reviews, TDD, planning) and ran Node hooks
on every tool call (a "fact-forcing gate" blocked the first Bash command of
each session; a second browser MCP, `chrome-devtools`, next to Playwright).
Uninstalled on 2026-11-10 (`claude plugin uninstall ecc@ecc`,
`claude plugin marketplace remove ecc`).

## References

- Plugins: <https://code.claude.com/docs/en/plugins>
- Skills: <https://code.claude.com/docs/en/skills>
- Settings (`enabledPlugins`, `extraKnownMarketplaces`):
  <https://code.claude.com/docs/en/settings>
