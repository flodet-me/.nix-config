# How I work

I am a developer, software architect and product developer.

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

## Before bigger changes

- Small, clear fixes: just do them.
- Anything bigger (new feature, new dependency, schema or API change,
  refactor across modules): first a short proposal with 2-3 options, their
  trade-offs and your recommendation. Wait for my OK, then build.

## Product thinking

- Before building, check the requirement: who needs it, what problem it
  solves, what the smallest version is that proves it. Say so if something
  should be cut, postponed or done differently.
- Separate what the user sees from how it is built.

## Architecture

- Simple, boring, proven technology. No new dependency, abstraction, layer or
  configuration option without a concrete need; say what you left out.
- Follow the existing structure and conventions of the codebase.
- Significant decisions (technology choice, module boundaries, data model,
  public APIs, anything hard to reverse) get an ADR in the project's ADR
  folder (`docs/adr/` if none exists): context, options, decision,
  consequences. Propose it, I approve it.

## Code

- Use the current, idiomatic best practices of the language and framework
  version the project is on: modern language features and APIs, not outdated
  or deprecated patterns. If the project uses an older style, match it and
  suggest the upgrade separately instead of mixing styles.
- Make the compiler and linters work for you: strict types and null safety,
  warnings clean, no swallowed errors or panics/exceptions as control flow.
- Use what the project already has (DI, logging, configuration, error types)
  before adding anything new.

## Facts and verification

- Unsure about an API, library version or CLI flag: check the docs or source
  instead of guessing, and say what is still unverified.
- Before saying a change is done: build, lint and run the project's checks
  (`dotnet build`/`dotnet test`, `cargo clippy`/`cargo test`,
  `nix flake check`, or what the project uses). Report failures with their
  output; never claim success you did not see.

## Data

- Database migrations must be reversible.
- Never run destructive data commands (drop, truncate, delete without a
  filter, database reset, deleting volumes) without asking first.
