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
  frontend-slides PDF export), `jq`, `perl` (agent-skills hooks), `gh`
  (mattpocock-skills), Python with `python-pptx` (frontend-slides PPTX import),
  and `uv` (graphify).

The dev shell also has `claude-code`, but not the plugins.

## How it works

- **Activation** (every `nixos-rebuild switch`) merges the declared
  `extraKnownMarketplaces`, `enabledPlugins` and `pluginConfigs` into
  `~/.claude/settings.json` with `jq`. The file stays a normal writable file,
  so `/config`, `/model`, permission edits etc. keep working and are kept.
  Declared keys win over local edits to the same keys.
- **`claude-plugins-sync`** downloads and installs everything:
  marketplaces and plugins (`claude plugin …`), the user-scope MCP servers
  (`claude mcp add-json -s user`), and graphify (`uv tool install graphifyy`,
  then `graphify install`). Every step is idempotent.
- It runs **automatically** as the systemd user service
  `claude-plugins-sync`: at login, and on `nixos-rebuild switch` whenever the
  declared lists change. It retries every 60 s until the network is up.
  Check it with `systemctl --user status claude-plugins-sync` or
  `journalctl --user -u claude-plugins-sync`. Running
  `claude-plugins-sync` by hand does the same.

Plugin code lives in `~/.claude/plugins/` and is downloaded from GitHub, so
it is **not** pinned by `flake.lock`: a fresh install gets each plugin's
current version. Playwright MCP is the exception: it comes from nixpkgs.

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

Removing an entry stops it from being declared but does not uninstall it:
run `claude plugin uninstall <plugin>@<marketplace>` (and
`claude plugin marketplace remove <name>`, `claude mcp remove -s user
<name>`, `graphify uninstall`) once.

Trying a plugin interactively with `/plugin install` is fine; it only becomes
reproducible once it is added to the Nix lists.

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

### agent-skills (`agent-skills@addy-agent-skills`)

Source: <https://github.com/addyosmani/agent-skills> · docs:
<https://skills.addy.ie> (incl. tutorials), repo `docs/getting-started.md`.

25 engineering-workflow skills covering the lifecycle
define → plan → build → verify → review → ship, plus 4 subagents
(`code-reviewer`, `security-auditor`, `test-engineer`,
`web-performance-auditor`). Skills also trigger automatically from what you
are doing (e.g. designing an API loads `api-and-interface-design`).

| Command | Use |
| --- | --- |
| `/spec` | Write a spec/PRD before code |
| `/planning` | Break work into small, ordered tasks with acceptance criteria |
| `/build` (`/build auto`) | Implement task by task: test, verify, commit (`auto`: whole plan after one approval) |
| `/test` | TDD; for bugs, prove it with a failing test first |
| `/constraints` | Write the project's quality bar to `CONSTRAINTS.md` and guard it |
| `/agent-skills:review` | Five-axis review (namespaced: built-in `/review` exists) |
| `/code-simplify` | Simplify without behavior change |
| `/webperf` | Web performance audit |
| `/ship` | Pre-launch checklist and go/no-go |

Notable skills to ask for by name: `interview-me` (clarify a vague request),
`idea-refine`, `doubt-driven-development` (adversarial check of risky
decisions), `debugging-and-error-recovery`, `security-and-hardening`,
`documentation-and-adrs`, `git-workflow-and-versioning`,
`source-driven-development`. `using-agent-skills` explains how to pick one.

Best use:

- For a new feature: `/spec` → `/planning` → `/build` → `/test` →
  `/agent-skills:review`. Small fixes don't need the full chain.
- Use `interview-me` when you only have a rough idea, `/constraints` once per
  project.
- It overlaps with ponytail (both review/simplify). They combine well:
  agent-skills gives the process, ponytail keeps each step small. Pick one
  reviewer per change rather than running both.

### mattpocock-skills (`mattpocock-skills@claude-plugins-official`) — grill-me

Source: <https://github.com/mattpocock/skills> · docs: its `README.md`,
`GLOSSARY.md`.

Small, composable engineering skills. The plugin ships all of them, but
`grill-me` is the reason it's here.

| Skill | Use |
| --- | --- |
| `/grill-me` | Relentless one-question-at-a-time interview that stress-tests a plan or design before you build it |
| `/grill-with-docs` | Same, but writes ADRs and a glossary as decisions fall |
| `/ask-matt` | "Which skill fits?" router |
| `/to-spec`, `/to-tickets`, `/implement-spec` | Conversation → spec → tracer-bullet tickets in the issue tracker → code |
| `/tdd`, `/diagnosing-bugs`, `/code-review`, `/pr` | Test-first work, hard bugs, review since a commit/branch, PR body |
| `/improve-codebase-architecture`, `/codebase-design`, `/domain-modeling` | Find deepening opportunities, design module interfaces, keep a glossary |
| `/handoff`, `/teach`, `/wait-what` | Hand work to a fresh agent, learn a concept, "re-explain that" |

Best use:

- Describe your plan in a few sentences, then `/grill-me`. Answer until it
  stops asking; the result is a plan with the holes found before coding.
  Use `/grill-with-docs` when the decisions should end up in the repo.
- Run `/setup-matt-pocock-skills` once per repo before the ticket/triage
  skills (it asks for issue tracker, labels, doc location). They use `gh`.
- Overlaps with agent-skills (`interview-me`, `/spec`, TDD, review). Pick one
  flow per task: grill-me for sharpening an idea, agent-skills'
  `/spec` → `/build` chain for carrying it out.

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
form works". Check it's connected with `/mcp`. agent-skills'
`browser-testing-with-devtools` expects a Chrome DevTools MCP server instead;
use Playwright for the same job.

### rust-analyzer-lsp (`rust-analyzer-lsp@claude-plugins-official`)

From Anthropic's official marketplace. Gives Claude Code rust-analyzer
diagnostics/navigation in Rust projects; `rust-analyzer` must be on `PATH`
(e.g. from the project's dev shell).

## References

- Plugins: <https://code.claude.com/docs/en/plugins>
- Skills: <https://code.claude.com/docs/en/skills>
- Settings (`enabledPlugins`, `extraKnownMarketplaces`):
  <https://code.claude.com/docs/en/settings>
