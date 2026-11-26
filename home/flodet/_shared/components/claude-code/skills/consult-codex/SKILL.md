---
name: consult-codex
description: Ask Codex for an independent read-only review while Claude remains responsible for the goal, implementation, verification, and final decision. Use for a second opinion on complex or risky changes, or when the user asks for Codex.
---

# Consult Codex

Claude is always the lead. Codex is a read-only consultant; Claude owns the
plan, changes, tests, interpretation of findings, and final answer.

1. Decide whether an independent opinion would materially help. Use Codex for
   complex Nix behavior, security-sensitive changes, or an explicit user
   request; skip it for routine edits.
2. Call `claude-codex-review` with one focused prompt. Include the goal,
   relevant acceptance criteria, and the files or diff Codex should inspect.
   Ask it to follow the repo's `AGENTS.md` and `CLAUDE.md` instructions.
   Keep the prompt concise enough to fit the available Codex context.
3. The prompt and reviewed code go to OpenAI for model processing. The user
   has authorized this for personal coding work, so do not ask again before
   an ordinary consultation. Never include secrets, credentials, or unrelated
   private information in the prompt; ask Codex not to inspect secret files or
   credentials. Honor any explicit project-specific restriction on external
   processing.
4. Codex runs with a read-only sandbox and no approval prompts. It must not
   edit files, run commands that change state, contact other network services,
   or delegate further. The CLI makes its normal provider request. If Codex
   cannot complete the review within these limits, report that constraint
   instead of loosening the sandbox.
5. Handle invocation failures according to their cause:
   - If Codex is not logged in, stop and tell the user to run `codex login`.
     Never inspect, request, or change credentials.
   - If usage is exhausted, rate-limited, the account has no available
     allowance, or the configured model is unavailable to that sign-in, do
     not retry or switch to an API key, account, or model to bypass it.
     Continue without Codex when reasonable; if the second opinion was
     important, tell the user it is unavailable and what remains unchecked.
   - For a clearly transient service or network failure, retry at most once.
     If it still fails, continue without Codex and disclose that.
   - If the prompt exceeds the context limit, reduce it to the relevant
     acceptance criteria and files, then retry once. If that still fails,
     continue without Codex and disclose that.
6. Return Codex's actionable findings with file and line references. Check
   each finding against the code and project rules yourself before changing
   anything. Ignore unsupported or irrelevant suggestions and explain
   unresolved disagreements to the user.

The Codex CLI uses its own local OpenAI login and usage allowance. Do not
claim that Codex reviewed anything unless its invocation completed and returned
a review. Claude remains responsible for the task when Codex is unavailable.
