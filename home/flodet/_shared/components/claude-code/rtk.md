# Command output (rtk)

A hook runs many Bash commands through `rtk`, which condenses their output.
Treat that output as the complete result: run commands normally and batch
related ones into one call. Truncated output names its own recovery path.
Re-run a command as `rtk bypass <cmd>` only when its result is unusable: empty
where output was clearly expected, contradicting its exit code, or garbled.
