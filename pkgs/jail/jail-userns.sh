# Runs CMD in a new user namespace that maps your uid and gid and your
# /etc/subuid and /etc/subgid ranges to themselves, CMD holding every
# capability in it (ambient). The host's setuid newuidmap and newgidmap
# write the maps; they allow only those ranges. Fails, saying why,
# without a range. Args: CMD...
user=$(id -un) uid=$(id -u) gid=$(id -g)
# START:START:COUNT of the first range of user (by name or uid) in $1
range() {
  local n s c
  [ ! -r "$1" ] || while IFS=: read -r n s c; do
    if [[ ($n == "$user" || $n == "$uid") && $s =~ ^[0-9]+$ && $c =~ ^[1-9][0-9]*$ ]]; then
      echo "$s:$s:$c"
      return 0
    fi
  done <"$1"
  echo "jail: no range for $user in $1 (NixOS: users.users.$user.autoSubUidGidRange); containers need one" >&2
  return 1
}
u=$(range /etc/subuid) && g=$(range /etc/subgid) || exit 1
exec env PATH="/run/wrappers/bin:$PATH" unshare --user --map-users="$uid:$uid:1" --map-users="$u" \
  --map-groups="$gid:$gid:1" --map-groups="$g" --setgroups allow --keep-caps -- env PATH="$PATH" "$@"
