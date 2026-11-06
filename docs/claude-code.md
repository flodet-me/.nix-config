# Claude Code plugins and skills

Claude Code is installed system-wide on `desktop` and `laptop`
(`environment.systemPackages`) and in the dev shell. Its plugins (skills,
slash commands, subagents, hooks) are declared in
`home/flodet/_shared/components/claude-code/default.nix`, imported by both
home configs.

## How it works

- **Activation** (every `nixos-rebuild switch`) merges the declared
  `extraKnownMarketplaces`, `enabledPlugins` and `pluginConfigs` into
  `~/.claude/settings.json` with `jq`. The file stays a normal writable file,
  so `/config`, `/model`, permission edits etc. keep working and are kept.
  Declared keys win over local edits to the same keys.
- **`claude-plugins-sync`** (in the user profile) adds the declared
  marketplaces and installs the declared plugins with `claude plugin …`.
  It is idempotent; it needs network, so it is not run during activation.

Plugin code itself lives in `~/.claude/plugins/` and is downloaded from
GitHub, so it is **not** pinned by `flake.lock`: a fresh install gets each
marketplace's current version.

## After a reinstall

```sh
nixos-rebuild switch --flake .#<HOST>   # writes settings.json
claude-plugins-sync                     # downloads + installs the plugins
```

Then restart Claude Code and check with `/plugin` (or `claude plugin list`).

## Adding or removing a plugin

1. Edit the `marketplaces` / `plugins` / `pluginConfigs` lists in
   `home/flodet/_shared/components/claude-code/default.nix`. The marketplace
   name must match `name` in the repo's `.claude-plugin/marketplace.json`.
2. `nixos-rebuild switch`, then `claude-plugins-sync`.
3. Add a section to [Installed plugins](#installed-plugins) below.

Removing an entry stops it from being declared but does not uninstall it:
run `claude plugin uninstall <plugin>@<marketplace>` (and
`claude plugin marketplace remove <name>`) once.

Trying a plugin interactively with `/plugin install` is fine; it only becomes
reproducible once it is added to the Nix lists.

Sensitive plugin options (e.g. ponytail's `webhookToken`) are kept in the
system keychain by Claude Code; never put them into `pluginConfigs`.

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

### rust-analyzer-lsp (`rust-analyzer-lsp@claude-plugins-official`)

From Anthropic's official marketplace. Gives Claude Code rust-analyzer
diagnostics/navigation in Rust projects; `rust-analyzer` must be on `PATH`
(e.g. from the project's dev shell).

## References

- Plugins: <https://code.claude.com/docs/en/plugins>
- Skills: <https://code.claude.com/docs/en/skills>
- Settings (`enabledPlugins`, `extraKnownMarketplaces`):
  <https://code.claude.com/docs/en/settings>
