# Repository jail

If a port or a path outside the repository is unreachable, check `$JAIL`. If
it is set, you are in a repository jail: for a port or a folder outside the
repository, edit `.jail` at the repository root (format:
`/run/current-system/sw/share/doc/jail/README.md`) and check it with
`jail config`. It applies only after the user approves it on a host
terminal at the next jail start. Tell the user.
