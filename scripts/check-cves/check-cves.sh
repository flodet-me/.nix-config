# shellcheck shell=bash
# Known vulnerabilities (CVEs) in what the hosts actually run: builds each
# host and runs vulnix on the runtime closure (not build-time dependencies).
# Exits 1 if anything at or above --min-cvss is found that isn't listed in
# security/vulnix-whitelist.toml. Used locally and by .github/workflows/security.yml.
#
# usage: check-cves [--min-cvss 7] [--markdown] [host...]   (default: all x86_64 hosts)

min_cvss=7
markdown=no
hosts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-cvss)
      min_cvss="$2"
      shift 2
      ;;
    --markdown)
      markdown=yes
      shift
      ;;
    -h | --help)
      echo "usage: check-cves [--min-cvss 7] [--markdown] [host...]" >&2
      exit 1
      ;;
    *)
      hosts+=("$1")
      shift
      ;;
  esac
done

repo=$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/.nix-config")
cd "$repo"
whitelist="$repo/security/vulnix-whitelist.toml"
system=$(nix eval --impure --raw --expr builtins.currentSystem)

if [[ ${#hosts[@]} -eq 0 ]]; then
  mapfile -t hosts < <(nix eval --json .#nixosConfigurations --apply \
    "cs: builtins.filter (n: n != \"installer\" && cs.\${n}.pkgs.stdenv.hostPlatform.system == \"$system\") (builtins.attrNames cs)" |
    jq -r '.[]')
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
found=0

[[ $markdown == yes ]] && printf '| host | package | CVSS | CVEs |\n| --- | --- | --- | --- |\n'
for host in "${hosts[@]}"; do
  echo "==> $host" >&2
  system_path=$(nix build --no-link --print-out-paths ".#nixosConfigurations.$host.config.system.build.toplevel")
  # exit code 2 just means "vulnerabilities found"
  vulnix --closure --json --whitelist "$whitelist" "$system_path" >"$tmp/$host.json" || [[ $? -eq 2 ]]
  jq -r --arg min "$min_cvss" --arg host "$host" --arg md "$markdown" '
    .[]
    | {name: "\(.pname) \(.version)", cves: .affected_by, cvss: ([.cvssv3_basescore[]?] | max // 0)}
    | select(.cvss >= ($min | tonumber))
    | if $md == "yes"
      then "| \($host) | \(.name) | \(.cvss) | \(.cves | join(" ")) |"
      else "\($host)\t\(.name)\tCVSS \(.cvss)\t\(.cves | join(" "))"
      end' "$tmp/$host.json" | sort -t$'\t' -k3 -r >"$tmp/$host.txt"
  if [[ -s $tmp/$host.txt ]]; then
    found=1
    cat "$tmp/$host.txt"
  fi
done

if [[ $found -eq 1 ]]; then
  echo "Found CVEs with CVSS >= $min_cvss. Update (nix flake update), rebuild, or" \
    "whitelist false positives in security/vulnix-whitelist.toml (docs/security-updates.md)." >&2
  exit 1
fi
echo "No CVEs with CVSS >= $min_cvss in: ${hosts[*]}" >&2
