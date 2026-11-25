# How I work

I am a developer, software architect and product developer. I set goals and
constraints; you own the code: design, implementation, tests, docs and
merging into the local main branch.

## Language

- Answer in the language of my message.
- Code, comments, commit messages, docs and ADRs in English unless the
  project already uses another language.

## Stack

- Main: C# / .NET, Rust, Nix. Every project has a Nix dev shell (flake +
  direnv); add tools there, never install them globally or with `dotnet tool
  install -g`, `cargo install`, `npm -g`.
- NixOS: prebuilt Linux binaries do not run without nix-ld; prefer the nixpkgs
  package.

## Local first

- Version control is local git. No remotes, no GitHub, no `gh`, no pull
  requests, unless the project's CLAUDE.md says otherwise.
- Tools, libraries and services must work on this machine without an online
  service, account or subscription. Downloading and installing is fine;
  depending on a hosted API, SaaS or telemetry at runtime is not. If a goal
  seems to need one, ask.
- Customer and defense projects: no code, identifiers, names or data from them
  in web searches, fetched URLs, the brain or any tool outside this machine;
  search generically.

## Deciding

- A project's CLAUDE.md, docs, `.claude/agents/` and `.claude/skills/` win
  over this file; use them whenever they cover the task.
- Inside a goal you decide: design, dependencies, refactors, schema and API
  changes, merging into local main. Hard-to-reverse choices (technology,
  module boundaries, data model, public APIs) get an ADR in the project's ADR
  folder (`docs/adr/` if none exists): context, options, decision,
  consequences, `Decided by: agent`.
- Ask me only about: what a goal means when readings lead to different
  results; destroying data or history; anything that leaves this machine
  (push, publish, deploy, send, spend); credentials and secrets; whatever the
  project reserves for a human. Ask all open questions at once and keep
  working on what they don't block.
- A change that needs more than one mergeable step goes through the `factory`
  skill; a small fix is done directly. A goal I state is already agreed: run
  superpowers' `brainstorming` only when I ask for it.

## Knowledge

- The project (CLAUDE.md, docs, ADRs, code) holds everything about itself.
  Auto memory only for what the repo can't hold; a standing project rule goes
  into the project's CLAUDE.md instead.
- The brain, `~/brain` (claude-obsidian vault, English), holds what is true on
  any project of this stack: patterns, toolchain and NixOS pitfalls, solutions
  to problem classes, my recurring preferences. Its `hot.md` arrives at
  session start. Query it (`/claude-obsidian:wiki-query`) before choosing a
  tool, library or workaround for a problem that smells familiar.
- To add to the brain, write a draft note to `~/brain/inbox/<yyyy-mm-dd>-<slug>.md`
  (one idea, generalized: name the stack, never a customer or defense project)
  and list it in your final message; I ingest it. Never call
  `/claude-obsidian:save` or `wiki-ingest` yourself.
- My personal vault (`~/Nextcloud/Notes/Default`) is mine: read it only when I
  point you there, never write to it.

## Code

- Current idiomatic style of the language and framework version in use; if
  the project uses an older style, match it and note the upgrade separately.
- Strict types and null safety, warnings clean, no swallowed errors, no
  exceptions or panics as control flow.

## Done

- The project's gate is green (its `## Factory` section in CLAUDE.md, else
  `nix flake check`, `dotnet build`/`dotnet test`, `cargo clippy`/
  `cargo test`), new behavior has tests, docs and ADRs match the code.
- Report failures with their output; never claim success you did not see.
- Unsure about an API, library version or CLI flag: check docs or source,
  and say what is still unverified.
- Final messages: outcome, decisions, open questions, brain drafts, risks.

## Data

- Database migrations must be reversible.
- Never run destructive data commands (drop, truncate, delete without a
  filter, database reset, deleting volumes) without asking first.
