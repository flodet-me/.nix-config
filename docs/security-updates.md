# Security updates and CVE monitoring

On NixOS, security fixes arrive by updating the flake inputs (mainly
`nixpkgs`) and redeploying. Everything here is about noticing when that is
needed and making it a routine.

## What runs automatically

`.github/workflows/security.yml`, every Monday (and on demand under Actions):

1. **Update PR**: updates `flake.lock` and opens a pull request
   ("flake.lock: weekly update"). Merge it after CI is green, then deploy.
   For CI to build that PR, add a fine-grained GitHub token (this repo,
   *Contents* + *Pull requests*: read/write) as the secret
   `FLAKE_UPDATE_TOKEN`; without it the PR is created but not built. Without
   the token the default one is used, which can only open the PR if the
   repository setting *Settings → Actions → General → Allow GitHub Actions to
   create and approve pull requests* is on; otherwise the job fails with 403.
2. **CVE scan** per host (`check-cves`): known vulnerabilities in what the
   host actually runs (its runtime closure, not build tools), CVSS >= 7, minus
   the whitelist. The table is in the run summary; if anything is found the run
   fails and GitHub sends you a notification (Settings → Notifications →
   Actions: "Send notifications for failed workflows only").

CVEs without a CVSSv3 score count as 0 and are not reported (at any
`--min-cvss` above 0). The workflows' third-party actions are pinned to
commits; Dependabot (`.github/dependabot.yml`) proposes the updates.

## Locally

```sh
check-cves                  # all hosts (dev shell), or: nix run .#check-cves
check-cves vps laptop       # specific hosts
check-cves --min-cvss 9     # only critical
```

## When something is reported

1. **Update first**: `nix flake update`, rebuild, `check-cves` again. Most
   reports disappear, because the fix is already in nixpkgs (the scan runs
   against the *locked* nixpkgs, so a lock that is weeks old shows many).
2. **Still there?** Look at the CVE (nvd.nist.gov or the nixpkgs issue
   tracker: search for the CVE id). Common cases:
   - *False positive*: vulnix matches by package name, e.g. `git` vs. a
     Jenkins git plugin, or a Rust crate called `nix`. Whitelist it.
   - *Not fixed upstream yet*: is the vulnerable feature reachable on that
     host? On servers: is it exposed? If not, whitelist with `until = ...`
     and a reason; if yes, mitigate (disable the feature/service) or remove
     the package.
   - *Fixed in nixpkgs but not in your channel yet*: wait for the next update,
     or use `pkgs.stable.<pkg>` if 26.05 has the fix.
3. **Whitelist** in `security/vulnix-whitelist.toml`, always with a reason.

## Reduce what can be vulnerable

Every package in a closure is attack surface and scan noise. Servers
deliberately don't import `cli-defaults.nix` (media libraries, nmap, strace,
...). `nix why-depends .#nixosConfigurations.<host>.config.system.build.toplevel <store path>`
shows why something is there.

## Also worth following

- Critical issues are usually announced on the NixOS Discourse
  (category *Security*) and the oss-security mailing list before scans catch
  them. For something like a remotely exploitable OpenSSH bug: update and
  deploy right away instead of waiting for Monday.

## Testing the workflows locally

`act` (in the dev shell, needs Docker) runs `.github/workflows/*` without
pushing. Build the runner image once, which is the usual one plus Nix:
`docker build -t ubuntu-act-nix:local .github/act` (`.actrc` selects it), then
e.g. `act -W .github/workflows/nix.yml -j format` or
`act -W .github/workflows/security.yml -j cves --matrix host:vps`. The
`update` job needs a real token and cannot be tried this way.
