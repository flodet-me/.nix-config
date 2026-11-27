h=/tmp/home
files=$1
root=$2
shift 2
fail() { echo "jail: preparing the jail home failed at: $1" >&2; exit 1; }
# bwrap cannot mount on or below a symlink: drop links the jail made there
unlink_mounts() {
  local m p c parts
  for m in "$@"; do
    p=$h
    IFS=/ read -ra parts <<<"$m"
    for c in "${parts[@]}"; do
      p=$p/$c
      [ ! -L "$p" ] || rm -f "$p"
    done
  done
}
unlink_mounts "$@" || fail "removing links at mount points"
# home-manager's dotfiles as links into the store; files the jail made
# stay, and so do mount points of a running jail (replacing one would
# detach that mount in the jail)
find "$h" -type l -lname '/nix/store/*-home-manager-files/*' -delete || fail "removing old home-manager links"
cp -rs --update=none --no-preserve=mode "$files/." "$h/" || fail "linking home-manager files"
unlink_mounts "$@" || fail "removing home-manager links at mount points"

# direnv: the repository's .envrc loads without `direnv allow`. Inside, it
# runs as jailed code anyway; the allow list only guards the host, which
# keeps its own. Only this jail's home has the whitelist.
mkdir -p "$h/.config/direnv" || fail "creating ~/.config/direnv"
jq -nr --arg r "$root" '"# written by jail on every start\n[whitelist]\nprefix = [\($r | tojson)]"' >/tmp/direnv.toml ||
  fail "writing direnv's whitelist"
cp --remove-destination /tmp/direnv.toml "$h/.config/direnv/direnv.toml" || fail "writing ~/.config/direnv/direnv.toml"

# ~/.claude.json: login and MCP servers from the host, the jail's own
# project state stays; nothing goes back
[ -f /tmp/host.json ] || exit 0
f=$h/.claude.json
host='{hasCompletedOnboarding, lastOnboardingVersion, lastReleaseNotesSeen, oauthAccount, userID, mcpServers} | with_entries(select(.value != null))'
if [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
  jq --slurpfile h /tmp/host.json ". + (\$h[0] | $host)" "$f" >/tmp/new || fail "merging ~/.claude.json"
else
  jq "$host" /tmp/host.json >/tmp/new || fail "reading your ~/.claude.json"
fi
cp --remove-destination /tmp/new "$f" || fail "writing ~/.claude.json"
