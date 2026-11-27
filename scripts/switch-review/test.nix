# switch-review on fake source trees, and its build/switch flow with stubbed
# nix, nh and /run/current-system (built by checks.scripts).
{ pkgs, switch-review }:
let
  # The running system's flake-source must be a top-level store directory.
  oldTree = pkgs.runCommand "source" { } ''
    mkdir $out
    printf 'x = 1;\n' > $out/old.nix
  '';
  storeFile = pkgs.writeText "source" "x";
in
pkgs.runCommand "switch-review-test"
  {
    nativeBuildInputs = [
      switch-review
      pkgs.jq
    ];
  }
  ''
    fail() { echo "FAIL: $1"; exit 1; }
    has() { grep -qF -- "$1" out || fail "missing: $1"; }
    hasnt() { grep -qF -- "$1" out && fail "shown: $1" || true; }

    ## --dirs: the diff itself
    mkdir -p old/docs new/docs/sub old/home new/home old/d new/assets
    # code anywhere: full diff
    printf 'x = 1;\n' > old/home/b.nix
    printf 'x = 1;\nhome-change-marker = 2;\n' > new/home/b.nix
    # docs/**/*.md: name only; anything else under docs/: full diff
    printf 'old text\n' > old/docs/c.md
    printf 'docs-change-marker\n' > new/docs/c.md
    printf 'nested-docs-marker\n' > new/docs/sub/n.md
    printf 'a\n' > old/docs/tool.sh
    printf 'docs-script-marker\n' > new/docs/tool.sh
    # odd file names
    printf 'space-marker\n' > 'new/home/with space.nix'
    printf 'newline-marker\n' > new/home/$'new\nline.nix'
    printf 'x\n' > new/home/$'cr\rname.nix'
    printf 'x\n' > new/home/$'esc\033name.nix'
    # non-regular files and type changes
    ln -s /etc/passwd new/home/link.nix
    ln -s same old/home/same-link
    ln -s same new/home/same-link
    printf 'inner-marker\n' > old/d/inner
    printf 'replacement-marker\n' > new/d
    # a directory replaced by a link out of the tree: never read through it
    mkdir old/home/p
    printf 'old-version-marker\n' > old/home/p/version
    ln -s /proc new/home/p
    # NUL, CR and ESC in content
    printf 'x\n' > old/home/bytes.nix
    printf 'x\0nul-marker\ncr-marker\r\n\033[31mesc-marker\n' > new/home/bytes.nix
    # Nix reads a .nix file up to its first NUL: that text is diffed, however long the rest
    { printf '{...}: { security.sudo.wheelNeedsPassword = false; }'; head -c 70000 /dev/zero; } > new/home/nul-padded.nix
    # a small change in a big file is a small diff
    seq -f '# padding line %g' 120000 > old/home/big.nix
    cp old/home/big.nix new/home/big.nix
    echo '{ }' >> old/home/big.nix
    echo '{ security.sudo.extraRules = "big-file-marker"; }' >> new/home/big.nix
    # only the exec bit changes
    printf 'same\n' > old/home/run.sh
    printf 'same\n' > new/home/run.sh
    chmod 644 old/home/run.sh
    chmod 755 new/home/run.sh
    # flake.nix unchanged, the lock redirects inputs to local trees
    printf '{ }\n' | tee old/flake.nix > new/flake.nix
    cat > old/flake.lock <<'EOF'
    {"nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs","other":"other"}},
     "nixpkgs":{"locked":{"type":"github","owner":"nixos","repo":"nixpkgs","rev":"aaaa"},"original":{"type":"github","owner":"nixos","repo":"nixpkgs"}},
     "other":{"locked":{"type":"github","owner":"o","repo":"r","rev":"bbbb"},"original":{"type":"github","owner":"o","repo":"r"}}},
     "root":"root","version":7}
    EOF
    cat > new/flake.lock <<'EOF'
    {"nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs","other":"other"}},
     "nixpkgs":{"locked":{"type":"path","path":"/home/x/evil","narHash":"sha256-x"},"original":{"type":"github","owner":"nixos","repo":"nixpkgs"}},
     "other":{"locked":{"type":"git","url":"file:///home/x/repo","rev":"cccc"},"original":{"type":"git","url":"file:///home/x/repo"}},
     "bare":{"locked":{"type":"git","url":"/home/x/bare","rev":"dddd"},"original":{"type":"git","url":"/home/x/bare"}}},
     "root":"root","version":7}
    EOF
    # names that are special as array subscripts
    printf 'at-marker\n' > new/@
    printf 'star-marker\n' > 'new/*'
    printf 'subscript-marker\n' > 'new/x[$(touch pwned)]'
    # The real flow passes a resolved store path; a symlinked root must work too.
    ln -s new newlink

    switch-review --dirs old newlink > out
    cat out
    has '+home-change-marker = 2;'
    has 'A @'
    has '+at-marker'
    has 'A *'
    has '+star-marker'
    has 'A x[$(touch pwned)]'
    has '+subscript-marker'
    [[ -e pwned ]] && fail "a file name was evaluated"
    has 'M docs/c.md'
    hasnt docs-change-marker
    has 'A docs/sub/n.md'
    hasnt nested-docs-marker
    has '+docs-script-marker'
    has 'A home/with space.nix'
    has '+space-marker'
    has 'A home/new\nline.nix'
    has '+newline-marker'
    has 'home/link.nix: none -> symlink to /etc/passwd'
    has 'd: directory -> regular file'
    hasnt same-link
    has '+replacement-marker'
    has '-inner-marker'
    has '!! home/p: directory -> symlink to /proc'
    has 'D home/p/version'
    has '-old-version-marker'
    hasnt 'Linux version'
    has '+x^@nul-marker'
    has '+cr-marker^M'
    has '+^[[31mesc-marker'
    has '!! home/bytes.nix: NUL bytes'
    has '+{...}: { security.sudo.wheelNeedsPassword = false; }'
    has '!! home/nul-padded.nix: NUL bytes'
    has '+{ security.sudo.extraRules = "big-file-marker"; }'
    has '-{ }'
    [[ $(grep -c '^[-+]# padding' out) == 0 ]] || fail "unchanged lines of a big file diffed"
    has '!! home/run.sh: mode 644 -> 755'
    has 'nixpkgs  github  nixos/nixpkgs aaaa'
    hasnt 'root  none'
    has 'nixpkgs  path  /home/x/evil'
    has '!! input nixpkgs (new): locked path /home/x/evil, original github'
    has '!! input other (new): locked git file:///home/x/repo cccc, original git'
    has '!! input bare (new): locked git /home/x/bare dddd, original git'
    hasnt '!! input nixpkgs (old)'
    # the lists again after the (long) diff, right before nh asks
    sed -n '/^== Full diff/,$p' out > after
    grep -qF '== Again: changed files (diff lines) ==' after || fail "changed files not repeated"
    grep -qE '^M home/big\.nix \([0-9]+ diff lines\)$' after || fail "no diff line count after the diff"
    grep -qF '!! home/run.sh: mode 644 -> 755' after || fail "!! list not repeated"
    grep -qF '!! input nixpkgs (new)' after || fail "input flags not repeated"
    has 'cr^Mname.nix'
    has 'esc^[name.nix'
    grep -q $'[\r\033]' out && fail "raw CR or ESC in the output"

    ## The flow: prefetch, build exactly that tree, check the pin, review, switch
    stubs=$PWD/stubs fake=$PWD/current
    mkdir -p "$stubs" "$fake" src out-ok out-bad out-hop
    printf 'x = 2;\n' > src/new.nix
    ln -s "$PWD/src" out-ok/flake-source
    ln -s "$PWD/old" out-bad/flake-source
    # two hops that end at the reviewed tree
    ln -s "$PWD/src" hop
    ln -s "$PWD/hop" out-hop/flake-source
    cat > "$stubs/nix" <<EOF
    #!${pkgs.runtimeShell}
    readlink /proc/self/fd/0 >> "$stubs/stdin"
    case "\$1 \$2" in
      "flake prefetch") cat "$stubs/prefetch.json" ;;
      "build "*) printf '%s\n' "\$*" > "$stubs/build-args"; [[ ! -e $stubs/build-fails ]] && cat "$stubs/out-path" ;;
      *) echo "unexpected nix \$*" >&2; exit 2 ;;
    esac
    EOF
    cat > "$stubs/nh" <<EOF
    #!${pkgs.runtimeShell}
    printf 'NH-RAN %s PATH=%s NIX_CONFIG=%s\n' "\$*" "\$PATH" "\''${NIX_CONFIG-unset}"
    EOF
    chmod +x "$stubs/nix" "$stubs/nh"
    sed -e "s|^nix=.*|nix=$stubs/nix|" -e "s|^nh=.*|nh=$stubs/nh|" -e "s|^current=.*|current=$fake|" \
      ${switch-review}/bin/switch-review > sr
    chmod +x sr
    [[ $(grep -c "^nix=$stubs/nix$\|^nh=$stubs/nh$\|^current=$fake$" sr) == 3 ]] || fail "stubbing failed"
    host=$(</proc/sys/kernel/hostname)
    export NH_FLAKE=$PWD/checkout NIX_CONFIG=evil
    clean() {
      jq -n --arg p "$PWD/src" '{storePath: $p, locked: {rev: "0123456789abcdef0123456789abcdef01234567", revCount: 7, lastModified: 42}}' > "$stubs/prefetch.json"
    }

    # first switch (no flake-source yet), clean tree, matching pin: switches
    clean
    echo "$PWD/out-ok" > "$stubs/out-path"
    ./sr --switch > out 2>&1 || { cat out; fail "clean switch failed"; }
    cat out
    grep -qF -- '--no-update-lock-file' "$stubs/build-args" || fail "lock file may be updated"
    grep -qF -- "path:$PWD/src?rev=0123456789abcdef0123456789abcdef01234567&revCount=7&lastModified=42#nixosConfigurations.\"$host\".config.system.build.toplevel" "$stubs/build-args" || fail "not built from the prefetched tree"
    has 'The running system has no flake-source'
    has "NH-RAN os switch --ask $PWD/out-ok PATH=/run/wrappers/bin:$fake/sw/bin NIX_CONFIG=unset"
    # nix never reads the terminal (no y/N for nixConfig)
    [[ $(sort -u "$stubs/stdin") == /dev/null ]] || fail "nix got stdin: $(sort -u "$stubs/stdin")"

    # dirty tree: no rev on the path: ref; its dirtyRev in the header; review against the old tree
    jq -n --arg p "$PWD/src" '{storePath: $p, locked: {dirtyRev: "0123456789abcdef0123456789abcdef01234567-dirty", lastModified: 42}}' > "$stubs/prefetch.json"
    ln -s ${oldTree} "$fake/flake-source"
    ./sr > out 2>&1 || { cat out; fail "dirty review failed"; }
    cat out
    grep -qF -- "path:$PWD/src#nixosConfigurations" "$stubs/build-args" || fail "dirty: wrong ref"
    has '0123456789abcdef0123456789abcdef01234567-dirty'
    has 'A new.nix'
    has '+x = 2;'
    has 'D old.nix'
    hasnt NH-RAN

    # the build points flake-source elsewhere: fail closed, before any review
    clean
    echo "$PWD/out-bad" > "$stubs/out-path"
    ./sr --switch > out 2>&1 && { cat out; fail "mismatch accepted"; }
    cat out
    has 'nothing was switched'
    has "$PWD/old"
    hasnt '== Changed files'
    hasnt NH-RAN
    # also on a first switch
    rm "$fake/flake-source"
    ./sr --switch > out 2>&1 && { cat out; fail "mismatch accepted on a first switch"; }
    has 'nothing was switched'
    hasnt NH-RAN
    # the failure message is complete when switch-review returns
    for i in $(seq 200); do
      ./sr --switch > out 2>&1 && fail "mismatch accepted"
      grep -qF 'nothing was switched' out || fail "failure output incomplete in run $i"
    done

    # a flake-source that reaches the tree in two hops is not the pin
    echo "$PWD/out-hop" > "$stubs/out-path"
    ./sr --switch > out 2>&1 && { cat out; fail "two hops accepted"; }
    cat out
    has 'nothing was switched'
    hasnt NH-RAN

    # the running system's flake-source: one hop to an existing top-level store
    # source directory, or no link at all (first switch); anything else fails
    echo "$PWD/out-ok" > "$stubs/out-path"
    ln -s ${oldTree} hop2
    for target in /nix/store/00000000000000000000000000000000-source "$PWD/old" "$PWD/hop2" ${storeFile}; do
      rm -f "$fake/flake-source"
      ln -s "$target" "$fake/flake-source"
      ./sr --switch > out 2>&1 && { cat out; fail "old flake-source -> $target accepted"; }
      cat out
      has 'is not an existing top-level /nix/store/<hash>-source directory'
      has 'nothing was switched'
      hasnt NH-RAN
    done
    rm "$fake/flake-source"
    mkdir "$fake/flake-source"
    ./sr --switch > out 2>&1 && { cat out; fail "old flake-source directory accepted"; }
    has 'is not a symlink'
    hasnt NH-RAN
    rmdir "$fake/flake-source"

    # a failed build never switches
    echo "$PWD/out-ok" > "$stubs/out-path"
    touch "$stubs/build-fails"
    ./sr --switch > out 2>&1 && { cat out; fail "failed build accepted"; }
    cat out
    has 'nothing was switched'
    hasnt NH-RAN
    rm "$stubs/build-fails"

    touch $out
  ''
