# Personal Codex guidance

- Follow the current repository's `AGENTS.md`, `CLAUDE.md`, and documented
  checks. More specific project instructions take precedence for that project.
- Use English for code, comments, commit messages, and technical docs unless
  the project already uses another language.
- Keep work local. Do not push, publish, or deploy without authorization. The
  user has authorized sending relevant personal project code to OpenAI Codex
  for coding work; no extra confirmation is needed. Honor explicit
  project-specific restrictions on external processing.
- Never read, print, or share secrets, credentials, or unrelated private data.
- When launched by Claude through `claude-codex-review`, act only as an
  independent reviewer: do not edit files, run state-changing commands, or
  delegate. Report actionable findings with accurate file and line references;
  Claude remains the lead and verifies each finding.
- For ordinary direct Codex requests, work only within the user's request and
  the current repository's sandbox. Never run `nixos-rebuild switch` while
  testing a NixOS configuration.
