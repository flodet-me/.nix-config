# NixOS VM test of the jail package (docs/jail.md): a normal user with
# home-manager (jail reads its generation) runs `jail` and `jail-push`.
# Every "absent inside" assertion has a positive control outside, so it
# cannot pass vacuously.
{ home-manager }:
{
  name = "jail";

  # another host on the test network, for outbound connections from a jail
  nodes.server =
    { pkgs, ... }:
    {
      networking.firewall.allowedTCPPorts = [ 8000 ];
      systemd.services.remote-listener = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:8000,reuseaddr,fork SYSTEM:'echo remote'";
      };
    };

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];
      services.resolved.enable = true; # as on the hosts: resolv.conf names 127.0.0.53
      virtualisation.memorySize = 2048;
      nix.settings = {
        experimental-features = [ "nix-command" ];
        substituters = lib.mkForce [ ]; # offline
      };
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [ "wheel" ];
        password = "pw";
        linger = true; # a user manager and session bus without a login
      };
      programs.gnupg.agent.enable = true; # its socket is the control for "no gpg-agent"
      environment.systemPackages = [
        (pkgs.callPackage ./. { }) # as on the workstations
        pkgs.git
        pkgs.tmux
        pkgs.socat
        pkgs.dig
        (pkgs.callPackage ../../home/flodet/_shared/components/claude-code/codex/wrapper.nix { })
      ];
      # names on the session bus: the one the jail may talk to, and another
      systemd.user.services =
        lib.genAttrs [ "org.freedesktop.Notifications" "org.example.Other" ]
          (name: {
            wantedBy = [ "default.target" ];
            serviceConfig.ExecStart = "${pkgs.dbus}/bin/dbus-test-tool echo --name=${name}";
          });
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        users.alice = {
          home.stateVersion = "26.05";
          home.file.probe.text = "from-home-manager";
          home.file.".codex/AGENTS.md".text = "from-home-manager"; # also bound read-only
          home.file.".codex/jail.config.toml".source =
            ../../home/flodet/_shared/components/claude-code/codex/jail.config.toml;
          home.file.".cache/hm/.keep".text = ""; # linked into the jail home's old .cache
          home.sessionVariables.JAIL_PROBE = "from-session-vars";
          home.sessionPath = [ "$HOME/probe-bin" ];
        };
      };
    };

  testScript = ''
    import shlex

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")
    machine.wait_for_unit("home-manager-alice.service")

    def alice(cmd, ok=True):
        full = "su - alice -c " + shlex.quote("export XDG_RUNTIME_DIR=/run/user/1000; set -e; " + cmd)
        return machine.succeed(full) if ok else machine.fail(full)

    def push_confirmed(repo, ok=True):
        # jail-push on a terminal, answering its question about an unstored URL;
        # a refusal must be a refusal, not a hang
        rc = f"rc=0; printf 'yes\\n' | timeout 60 script -qec 'jail-push {repo}' /dev/null || rc=$?; echo rc=$rc; "
        return alice(rc + ("test $rc = 0" if ok else "test $rc != 0 && test $rc != 124"))

    def jail(cmd, ok=True, repo="~/repo"):
        # host variables that must not reach the jail
        env = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus SSH_AUTH_SOCK=/run/user/1000/gnupg/S.gpg-agent.ssh"
        return alice(f"{env} jail {repo} -- sh -c {shlex.quote(cmd)}", ok)

    def terminal(unit, repo="/home/alice/repo"):
        # the shared jail of repo in a terminal that stays open
        alice(f"systemd-run --user --quiet --unit={unit} -E TERM=xterm sh -c 'sleep 600 | /run/current-system/sw/bin/script -qfc \"/run/current-system/sw/bin/jail {repo}\" /dev/null'")

    def start(cmd, answer=None, repo="~/repoc", ok=True, shared=False):
        # jail with its messages (stderr): without a terminal, or on one typing answer
        j = f"jail {repo}" if shared else f"jail {repo} -- sh -c {shlex.quote(cmd)}"
        if answer is None:
            return alice(f"{j} </dev/null 2>&1", ok)
        rc = f"rc=0; printf '{answer}\\n' | timeout 60 script -qec {shlex.quote(j)} /dev/null || rc=$?; echo rc=$rc; "
        return alice(rc + ("test $rc = 0" if ok else "test $rc != 0 && test $rc != 124"))

    def refuses(cmd):
        # fails with its messages, and does not hang
        return alice(f"rc=0; timeout 60 {cmd} </dev/null 2>&1 || rc=$?; echo rc=$rc; test $rc != 0 && test $rc != 124")

    alice("""
      git config --global user.name a
      git config --global user.email a@example.com
      git config --global init.defaultBranch main
      git config --global protocol.ext.allow always # only jail-push may refuse ext::
      # ssh for ssh://localhost URLs: runs the remote command here, and marks that it ran
      git config --global core.sshCommand /home/alice/fakessh
      cat > ~/fakessh <<'EOF'
    #!/bin/sh
    : > /tmp/ssh-global
    for a; do last=$a; done
    exec sh -c "$last"
    EOF
      chmod +x ~/fakessh
      mkdir -p Nextcloud brain/inbox .cache/nix .cache/docker .local/bin
      mkdir -p .claude/skills .claude/rules .claude/agents .claude/plugins/data/p .claude/projects .codex/rules
      echo secret > Nextcloud/secret
      echo note > brain/note
      touch .cache/nix/hostmark .claude/plugins/data/p/hostmark .claude/projects/hostmark
      echo '{}' > .claude/settings.json
      echo host > .claude/CLAUDE.md
      echo host > .claude/.credentials.json
      echo 'model = "host"' > .codex/config.toml
      echo host > .codex/auth.json
      echo '{"oauthAccount":{"a":1},"mcpServers":{"m":{}},"projects":{"hostproject":{}}}' > .claude.json
      cp .claude.json claude.json.orig
      echo '{"leak":1}' > target
      git init -q repo
      cd repo
      echo one > f
      git add f
      git commit -qm one
    """)

    with subtest("only the repository, brain and the login are shared"):
        alice("cat ~/Nextcloud/secret && test -d ~/.cache/docker")
        jail("test ! -e ~/Nextcloud && test ! -e ~/.cache/docker && test ! -e ~/.gitconfig")
        jail('test "$HOME" = /home/alice && test "$PWD" = /home/alice/repo')
        jail("cat ~/brain/note && grep -q host ~/.claude/CLAUDE.md ~/.codex/config.toml && grep -q from-home-manager ~/.codex/AGENTS.md")
        jail("touch ~/brain/inbox/x ~/repo/w")
        alice("test -e ~/brain/inbox/x && test -e ~/repo/w")
        # config, instructions and code: read-only
        for p in ["brain/x", ".claude/settings.json", ".claude/CLAUDE.md", ".claude/skills/x", ".claude/rules/x",
                  ".claude/agents/x", ".claude/plugins/x", ".codex/config.toml", ".codex/AGENTS.md",
                  ".codex/rules/x", ".local/bin/x"]:
            jail(f"touch ~/{p}", ok=False)
        # the login: shared
        jail("echo jail > ~/.claude/.credentials.json && echo jail > ~/.codex/auth.json")
        alice("grep -q jail ~/.claude/.credentials.json && grep -q jail ~/.codex/auth.json")
        # state and caches: the jail's own, both ways
        jail("test ! -e ~/.cache/nix/hostmark && test ! -e ~/.claude/plugins/data/p && test ! -e ~/.claude/projects/hostmark")
        jail("mkdir -p ~/.claude/projects/p ~/.claude/shell-snapshots ~/.claude/plugins/data/p ~/.codex/sessions ~/.cache/nix"
             " && touch ~/.claude/new ~/.claude/projects/p/m ~/.claude/shell-snapshots/s ~/.claude/plugins/data/p/m"
             " ~/.codex/sessions/s ~/.cache/nix/x")
        for p in [".claude/new", ".claude/projects/p", ".claude/shell-snapshots", ".claude/plugins/data/p/m",
                  ".codex/sessions", ".cache/nix/x"]:
            alice(f"test ! -e ~/{p}")

    with subtest("a bare-repository container: one jail for all worktrees, jail-push per worktree"):
        alice("""
          git init -q --bare ~/cremote.git
          git init -q ~/cseed && cd ~/cseed && echo seed > s && git add s && git commit -qm seed
          git push -q ~/cremote.git main
          # made as the real ones are
          mkdir ~/cont && cd ~/cont
          git clone -q --bare ~/cremote.git .bare
          printf 'gitdir: ./.bare\\n' > .git
          git worktree add -q main
          git worktree add -q -b feature feature
          git -c worktree.useRelativePaths=true worktree add -q -b rel rel
          grep -q '^gitdir: \\.\\./\\.bare/worktrees/rel$' rel/.git
          mkdir .claude var rel/sub
        """)
        gc = "git -c user.name=a -c user.email=a@example.com"
        # git works inside in every worktree; the URL is recorded at the first start
        out = start(f'test "$PWD" = /home/alice/cont/main && test -d ../var && {gc} commit -qm m --allow-empty'
                    f' && git status --short && cd ../feature && {gc} commit -qm f --allow-empty', repo="~/cont/main")
        assert "jail-push /home/alice/cont pushes to /home/alice/cremote.git" in out, out
        jail(f'test "$PWD" = /home/alice/cont && cd rel && {gc} commit -qm r --allow-empty && git -C ../main log --oneline | grep -q " m$"',
             repo="~/cont")
        # gitdir: without ./ is the same
        alice("printf 'gitdir: .bare\\n' > ~/cont/.git")
        jail("git status >/dev/null", repo="~/cont/feature")
        alice("printf 'gitdir: ./.bare\\n' > ~/cont/.git")

        # the container and its worktrees share one jail
        csock = "$(echo /run/user/1000/jails/cont-*/tmux.sock)"
        terminal("termw", repo="/home/alice/cont/feature")
        machine.wait_until_succeeds(f"su - alice -c 'tmux -S {csock} list-clients' | grep -q .", timeout=60)
        terminal("termr", repo="/home/alice/cont")
        machine.wait_until_succeeds(f"test \"$(su - alice -c 'tmux -S {csock} list-clients' | wc -l)\" = 2", timeout=60)
        alice('test "$(systemctl --user list-units --plain --no-legend "jail-cont-*" | wc -l)" = 1')
        alice("test \"$(ls ~/.local/share/jails | grep -c '^cont-')\" = 1 && ! ls ~/.local/share/jails | grep -qE '^(main|feature|rel)-'")
        alice("systemctl --user stop 'jail-cont-*' termw termr")
        machine.wait_until_succeeds("! pgrep -u alice '^(xdg-dbus-proxy|passt|pasta)'", timeout=30)

        # jail-push: the worktree's branch only; the bare HEAD's from the container
        remote = "git --git-dir ~/cremote.git rev-parse"
        bare = "git --git-dir ~/cont/.bare rev-parse"
        alice("jail-push ~/cont/feature </dev/null")
        alice(f'test "$({remote} feature)" = "$({bare} feature)" && test "$({remote} main)" = "$(git -C ~/cseed rev-parse main)"'
              f' && test "$({bare} main)" != "$({remote} main)"')
        alice("jail-push ~/cont </dev/null")
        alice(f'test "$({remote} main)" = "$({bare} main)" && ! {remote} -q --verify rel')
        alice("jail-push ~/cont/rel/sub </dev/null")
        alice(f'test "$({remote} rel)" = "$({bare} rel)"')
        jail(f"{gc} -C main commit -qm m2 --allow-empty", repo="~/cont")
        alice("jail-push ~/cont/var </dev/null")
        alice(f'test "$({remote} main)" = "$({bare} main)"')

        # a worktree whose .git points elsewhere: no branch of its own, a named one is pushed
        alice("cd ~/cont && git worktree add -q -b other other")
        for gd in ["/home/alice/cremote.git", "../../cseed/.git", "../.bare/worktrees/../../../cseed/.git", "/home/alice/cont/.bare"]:
            alice(f"printf 'gitdir: %s\\n' {shlex.quote(gd)} > ~/cont/other/.git")
            assert "name the branch" in refuses("jail-push ~/cont/other"), gd
        alice(f"! {remote} -q --verify other")
        alice(f'jail-push ~/cont/other other </dev/null && test "$({remote} other)" = "$({bare} other)"')

        # a normal repository: a linked worktree and a submodule resolve to it, jail-push pushes its HEAD
        alice("""
          git init -q --bare ~/nremote.git
          git init -q ~/norm && cd ~/norm && echo n > f && git add f && git commit -qm n
          git remote add origin /home/alice/nremote.git
          git worktree add -q -b wtb wt
          git -c protocol.file.allow=always submodule --quiet add /home/alice/cseed sub
          git commit -qm sub
        """)
        for d in ["wt", "sub"]:
            jail(f'test "$PWD" = /home/alice/norm/{d} && test -e /home/alice/norm/f && git status >/dev/null', repo=f"~/norm/{d}")
        alice("! ls ~/.local/share/jails | grep -qE '^(wt|sub)-'")
        alice("jail-push ~/norm/wt </dev/null")
        alice('test "$(git --git-dir ~/nremote.git rev-parse main)" = "$(git -C ~/norm rev-parse main)"'
              " && ! git --git-dir ~/nremote.git rev-parse -q --verify wtb")

        # a container .git that is not gitdir: ./NAME of a bare repository in it: refused
        alice("""
          mkdir ~/bad && cd ~/bad
          git clone -q --bare ~/cremote.git .bare
          printf 'gitdir: ./.bare\\n' > .git
          git worktree add -q main
        """)
        jail("git status >/dev/null", repo="~/bad/main")  # the control
        refs = alice("git --git-dir ~/cremote.git for-each-ref")
        bad = {
            "printf 'gitdir: ../cremote.git\\n' > .git": "not inside a git repository",
            "printf 'gitdir: /home/alice/cremote.git\\n' > .git": "not inside a git repository",
            "printf 'gitdir: /home/alice/bad/.bare\\n' > .git": "not inside a git repository",
            "printf 'gitdir: ..\\n' > .git": "not one directory name",
            "printf 'gitdir: ./\\n' > .git": "not one directory name",
            "mv .bare bare && ln -s /home/alice/cremote.git .bare": "not a bare repository directory",
            "mv .bare bare && mkdir .bare": "not a bare repository directory",
            "mv .bare bare && mkfifo .bare": "not a bare repository directory",
            "rm .git && mkfifo .git": "not inside a git repository",
        }
        for make, why in bad.items():
            alice(f"cd ~/bad && {make}")
            for cmd in ["jail ~/bad/main -- true", "jail ~/bad -- true", "jail-push ~/bad main"]:
                out = refuses(cmd)
                assert why in out, (make, cmd, out)
            alice("cd ~/bad && rm -rf .git && printf 'gitdir: ./.bare\\n' > .git && if [ -d bare ]; then rm -rf .bare && mv bare .bare; fi")
        assert alice("git --git-dir ~/cremote.git for-each-ref") == refs

        # a FIFO instead of a worktree's git directory: no wait on it
        alice("mv ~/cont/.bare/worktrees/rel ~/relgit && mkfifo ~/cont/.bare/worktrees/rel")
        assert "name the branch" in refuses("jail-push ~/cont/rel")
        # a link instead of worktrees: the worktree's HEAD is not read through it
        alice("mv ~/cont/.bare/worktrees ~/wtcopy && ln -s ~/wtcopy ~/cont/.bare/worktrees")
        assert "name the branch" in refuses("jail-push ~/cont/feature")

    with subtest("~/.claude.json: login and MCP servers copied in, nothing back"):
        jail("grep -q oauthAccount ~/.claude.json && grep -q mcpServers ~/.claude.json && ! grep -q hostproject ~/.claude.json")
        jail("""echo '{"projects":{"jailproject":{}}}' > ~/.claude.json""")
        alice("cmp ~/.claude.json ~/claude.json.orig")
        jail("grep -q jailproject ~/.claude.json && grep -q oauthAccount ~/.claude.json")
        # a link planted in the jail home does not make the next start touch host files
        jail("ln -sfn /home/alice/target ~/.claude.json")
        jail("test ! -L ~/.claude.json && grep -q oauthAccount ~/.claude.json && ! grep -q leak ~/.claude.json")
        alice("""test "$(cat ~/target)" = '{"leak":1}' && cmp ~/.claude.json ~/claude.json.orig""")

    with subtest("a link planted at a mount point does not stop the next start"):
        alice("cd ~/.local/share/jails/repo-*/home && mv .codex codex-old && ln -s /nowhere .codex")
        jail("grep -q host ~/.codex/config.toml")

    with subtest("home-manager dotfiles are mirrored into the jail home"):
        jail("grep -q from-home-manager ~/probe")
        alice("test -d ~/.local/share/jails/repo-*/home")

    with subtest("one-off jails get the home-manager session variables"):
        jail('test "$JAIL_PROBE" = from-session-vars && case ":$PATH:" in *:/home/alice/probe-bin:*) ;; *) exit 1 ;; esac')

    with subtest("the jail's ~/.cache is ~/.cache/jails/<name>, outside the jail home"):
        jail("echo c > ~/.cache/probe")
        alice("grep -q c ~/.cache/jails/repo-*/probe && test ! -e ~/.cache/probe && cd ~/.local/share/jails/repo-*/home && test ! -e .cache/probe")
        # a link planted at the mount point does not stop the next start
        alice("cd ~/.local/share/jails/repo-*/home && rm -r .cache && ln -s /nowhere .cache")
        jail("grep -q c ~/.cache/probe")
        # a cache from before the move stays where it was, unused, and says so once
        alice("git init -q ~/repom")
        jail("true", repo="~/repom")
        alice("rm -r ~/.cache/jails/repom-* && cd ~/.local/share/jails/repom-*/home/.cache && touch old")
        out = start("test ! -e ~/.cache/old && touch ~/.cache/new", repo="~/repom")
        assert "is no longer used" in out, out
        assert "no longer used" not in start("true", repo="~/repom")
        alice("test -e ~/.local/share/jails/repom-*/home/.cache/old && test -e ~/.cache/jails/repom-*/new")
        # a removed cache (Reset) is made again without that message
        alice("rm ~/.local/share/jails/repom-*/home/.cache/old && rm -r ~/.cache/jails/repom-*")
        assert "no longer used" not in start("true", repo="~/repom")
        alice("test -d ~/.cache/jails/repom-*")

    with subtest("codex in a jail uses the jail profile, the host default stays"):
        sandbox = "codex debug prompt-input hi 2>/dev/null | grep -o 'sandbox_mode. is .[a-z-]*'"
        out = alice(f"cd ~/repo && {sandbox}")
        assert "read-only" in out, out
        out = jail(sandbox)
        assert "danger-full-access" in out, out
        # subcommands that refuse --profile still work
        jail("codex features list >/dev/null")

    with subtest("commits and tags in a jail are unsigned, the host still signs"):
        alice("""
          git init -q ~/repos && cd ~/repos
          git config user.name a && git config user.email a@example.com
          git config commit.gpgsign true && git config tag.gpgSign true
          # control: signing is on outside (and fails: no key)
          if git commit -q --allow-empty -m host 2>/dev/null; then exit 1; fi
          if git tag -a -m t host-tag 2>/dev/null; then exit 1; fi
        """)
        jail('git commit -q --allow-empty -m jail && git tag -a -m t t1 && test "$(git log -1 --format=%G?)" = N', repo="~/repos")

    with subtest("shebang paths work"):
        jail("/usr/bin/env true && /bin/sh -c true")

    with subtest("no sudo, no capabilities, no user manager or agent sockets, the bus only through the proxy"):
        alice("echo pw | sudo -S true")
        alice("grep -q '^CapBnd:.*[1-9a-f]' /proc/self/status")
        jail("test -z \"$(grep -E '^Cap(Inh|Prm|Eff|Bnd|Amb):' /proc/self/status | grep -v ':[[:space:]]*0*$')\"")
        # no signal ignored: Ctrl-C and SIGPIPE work as outside
        jail("grep -q '^SigIgn:[[:space:]]*0*$' /proc/self/status")
        jail("sudo -n true", ok=False)
        jail("echo pw | sudo -S true", ok=False)
        alice("systemd-run --user --wait --quiet true")
        jail("systemd-run --user --wait --quiet true", ok=False)
        alice("test -S /run/user/1000/bus && find /run/user/1000 -type s | grep -q gnupg")
        # the one socket is the D-Bus proxy's (see "D-Bus: Notifications only"); not
        # -type s: find takes the type of the mount point bwrap made, a file
        jail('test "$XDG_RUNTIME_DIR" = /run/user/1000 && test "$DBUS_SESSION_BUS_ADDRESS" = unix:path=/run/user/1000/bus && test -z "''${SSH_AUTH_SOCK:-}"')
        jail('test "$(find /run/user /run/wrappers ! -type d 2>/dev/null)" = /run/user/1000/bus && test -S /run/user/1000/bus && test ! -e /run/wrappers')

    with subtest("own network: outbound and DNS work, host loopback does not"):
        server.wait_for_unit("remote-listener.service")
        machine.succeed("systemd-run --unit=lo-listener socat TCP-LISTEN:8123,bind=127.0.0.1,reuseaddr,fork SYSTEM:'echo lo'")
        machine.succeed("systemd-run --unit=lo6-listener socat TCP6-LISTEN:8125,bind=[::1],reuseaddr,fork SYSTEM:'echo lo'")
        machine.wait_for_open_port(8123)
        machine.wait_for_open_port(8125, addr="::1")
        alice("socat -u TCP:server:8000 - | grep -q remote && socat -u TCP:127.0.0.1:8123 - | grep -q lo && socat -u TCP6:[::1]:8125 - | grep -q lo")
        jail("socat -u TCP:server:8000 - | grep -q remote")
        jail("socat -u TCP:127.0.0.1:8123 - | grep -q lo", ok=False)
        jail("socat -u TCP6:[::1]:8125 - | grep -q lo", ok=False)
        # nor through the namespace's gateway, which pasta maps to host loopback by default
        jail('gw=$(ip route show default | cut -d" " -f3) && test -n "$gw" && ! socat -u TCP:$gw:8123,connect-timeout=5 - | grep -q lo')
        # DNS from resolv.conf, not /etc/hosts: resolved answers the test nodes' names
        alice("dig +short +time=5 server | grep -q .")
        jail("dig +short +time=5 server | grep -q . && dig +short +tcp +time=5 server | grep -q .")
        # loopback inside works (winvm's port forwards)
        jail("socat TCP-LISTEN:8124,bind=127.0.0.1 SYSTEM:'echo inside' & sleep 1; socat -u TCP:127.0.0.1:8124 - | grep -q inside")

    with subtest("host abstract Unix sockets are unreachable"):
        machine.succeed("systemd-run --unit=abstract-listener socat ABSTRACT-LISTEN:jail-test-abstract,fork SYSTEM:'echo abstract'")
        machine.wait_until_succeeds("su - alice -c \"socat -u ABSTRACT-CONNECT:jail-test-abstract - | grep -q abstract\"")
        jail("socat -u ABSTRACT-CONNECT:jail-test-abstract - | grep -q abstract", ok=False)

    with subtest("D-Bus: Notifications only, through a proxy that ends with the jail"):
        notify = "busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications GetServerInformation"
        other = "busctl --user call org.example.Other / org.example.Other Ping"
        machine.wait_until_succeeds(f"su - alice -c 'export XDG_RUNTIME_DIR=/run/user/1000; {notify} && {other}'")
        jail(notify)
        jail(other, ok=False)
        jail("systemd-run --user --wait --quiet true", ok=False)
        # by process name (pasta runs as passt.avx2 or pasta), not by command line
        machine.wait_until_succeeds("! pgrep -u alice '^(xdg-dbus-proxy|passt|pasta)'", timeout=10)
        # killing a one-off jail, also with Ctrl-C's signal or SIGKILL, ends what runs in it
        # (a background job starts with SIGINT ignored, which nothing can trap:
        # env gives the jail the default a terminal's foreground job has)
        for sig in ["TERM", "INT", "KILL"]:
            alice("(env --default-signal=INT jail ~/repo -- sleep 300 & echo $! > /tmp/oneoff; wait) >/dev/null 2>&1 &")
            machine.wait_until_succeeds("pgrep -u alice -x sleep")
            alice(f"kill -{sig} $(cat /tmp/oneoff)")
            machine.wait_until_succeeds("! pgrep -u alice -x sleep && ! pgrep -u alice '^(xdg-dbus-proxy|passt|pasta)'", timeout=10)
        # the proxy of the SIGKILLed one sees its pipe close and removes its socket
        machine.wait_until_succeeds("! ls /run/user/1000/jails/*.bus-* 2>/dev/null", timeout=10)

    with subtest("nix build through the daemon"):
        alice("""cat > ~/repo/t.nix <<'EOF'
    derivation { name = "jail-test"; system = builtins.currentSystem; builder = "/bin/sh"; args = [ "-c" "echo ok > $out" ]; }
    EOF""")
        jail("nix build --no-link --print-out-paths -f ~/repo/t.nix | xargs cat | grep -q ok")

    with subtest("/dev/kvm inside iff outside"):
        kvm = machine.execute("test -e /dev/kvm")[0] == 0
        print(f"/dev/kvm on the test VM: {kvm}")
        jail("test -e /dev/kvm", ok=kvm)

    with subtest("jail-push pushes without running anything from the repository"):
        alice("""
          cat > ~/mark <<'EOF'
    #!/bin/sh
    : > /tmp/marker-"''${0##*/}"
    EOF
          chmod +x ~/mark
          git init -q --bare ~/remote.git
          git init -q --bare ~/other.git
          cd ~/repo
          for h in pre-push post-checkout reference-transaction pre-receive update post-update push-to-checkout; do
            cp ~/mark .git/hooks/$h
          done
          cp ~/mark ~/fsmonitor
          git config core.fsmonitor ~/fsmonitor
          git config core.sshCommand ~/mark
          git config uploadpack.packObjectsHook ~/mark
          git remote add origin ssh://localhost/home/alice/remote.git
          # control: the planted hooks are live for a plain git outside
          git checkout -q -b probe && git checkout -q main && git status >/dev/null
          ls /tmp/marker-post-checkout /tmp/marker-fsmonitor
          rm -f /tmp/marker-*
        """)
        # ~/repo ran jailed code before it had a remote: the URL must be confirmed on a terminal
        alice("jail-push ~/repo </dev/null", ok=False)
        alice("test -z \"$(git --git-dir ~/remote.git for-each-ref)\"")
        push_confirmed("~/repo")
        alice('test "$(git --git-dir ~/remote.git rev-parse main)" = "$(cat ~/repo/.git/refs/heads/main)"')
        alice("test -e /tmp/ssh-global && ! ls /tmp/marker-* 2>/dev/null")  # the global sshCommand ran, the planted one not

        # the URL is stored on first use: a later change in the repository is ignored
        jail("git -C ~/repo -c user.name=a -c user.email=a@example.com commit -qm two --allow-empty && git -C ~/repo config remote.origin.url /home/alice/other.git")
        alice("cd / && jail-push ~/repo")
        alice('test "$(git --git-dir ~/remote.git rev-parse main)" = "$(cat ~/repo/.git/refs/heads/main)"')
        alice("test -z \"$(git --git-dir ~/other.git for-each-ref)\"")
        alice("! ls /tmp/marker-* 2>/dev/null")

    with subtest("jail records the URL when it first starts, before jailed code runs"):
        alice("""
          git init -q --bare ~/remote5.git
          git init -q ~/repo5 && cd ~/repo5 && git commit -q --allow-empty -m one
          git remote add origin ssh://localhost/home/alice/remote5.git
        """)
        jail("git config remote.origin.url /home/alice/other.git", repo="~/repo5")
        alice("jail-push ~/repo5 </dev/null")
        alice("git --git-dir ~/remote5.git rev-parse main && test -z \"$(git --git-dir ~/other.git for-each-ref)\"")

    with subtest("jail-push refuses unsafe remotes and repositories"):
        alice("git init -q ~/repo2 && cd ~/repo2 && git commit -q --allow-empty -m one && git remote add origin x")
        # control: ext:: runs for a plain git here
        alice("git ls-remote 'ext::sh -c touch% /tmp/ext-control' || true; test -e /tmp/ext-control")
        for url in ["ext::sh -c touch% /tmp/marker-ext", "--upload-pack=touch /tmp/marker-opt", "fd::3", "file:///home/alice/remote.git", "/home/alice/Nextcloud", "-oProxyCommand=touch@x:y"]:
            alice(f"git -C ~/repo2 config -- remote.origin.url {shlex.quote(url)}")
            push_confirmed("~/repo2", ok=False)
        alice("! ls /tmp/marker-* 2>/dev/null")
        # a control character (terminal escape) in an otherwise valid URL
        alice("git -C ~/repo2 config remote.origin.url \"$(printf 'ssh://localhost/home/alice/remote.git\\033[2J')\"")
        assert "refusing" in push_confirmed("~/repo2", ok=False)
        # DIR is mandatory and must exist
        alice("cd ~/repo && jail-push", ok=False)
        alice("cd ~/repo && jail-push ~/nonexistent main", ok=False)
        # .git/config or HEAD as a link (to another repository's) or a FIFO
        alice("""
          git init -q --bare ~/victim-remote.git
          git init -q ~/victim && cd ~/victim && git commit -q --allow-empty -m one
          git remote add origin /home/alice/victim-remote.git
          git init -q ~/repo6 && cd ~/repo6 && git commit -q --allow-empty -m one
          git remote add origin /home/alice/other.git
          cp -r ~/repo6 ~/repo7 && cp -r ~/repo6 ~/repo8 && cp -r ~/repo6 ~/repo11
          ln -sf ~/victim/.git/config ~/repo6/.git/config
          rm ~/repo7/.git/config && mkfifo ~/repo7/.git/config
          ln -sf ~/victim/.git/HEAD ~/repo8/.git/HEAD
          rm ~/repo11/.git/HEAD && mkfifo ~/repo11/.git/HEAD
          git init -q ~/repo9 && cd ~/repo9 && git commit -q --allow-empty -m one
          printf '[include]\\n\\tpath = /home/alice/victim/.git/config\\n' >> ~/repo9/.git/config
        """)
        for r in ["repo6", "repo7", "repo8", "repo11"]:
            push_confirmed(f"~/{r}", ok=False)
        # an include in .git/config is not followed: neither jail nor jail-push take its URL
        jail("true", repo="~/repo9")
        alice("! ls -d ~/.local/share/jails/repo9-*/mirror.git")
        push_confirmed("~/repo9", ok=False)
        alice("test -z \"$(git --git-dir ~/victim-remote.git for-each-ref)\" && test -z \"$(git --git-dir ~/other.git for-each-ref)\"")
        # a .git that points elsewhere (could hand out another repository)
        alice("git init -q ~/repo3 && cd ~/repo3 && git commit -q --allow-empty -m one && git remote add origin /home/alice/other.git")
        alice("mv ~/repo3/.git ~/repo3.git && ln -s ~/repo3.git ~/repo3/.git")
        alice("jail-push ~/repo3", ok=False)
        alice("test -z \"$(git --git-dir ~/other.git for-each-ref)\"")

    with subtest("a local remote's hooks run sandboxed"):
        alice("""
          git init -q ~/repo4 && cd ~/repo4 && git commit -q --allow-empty -m one
          git init -q --bare ~/repo4/evil.git
          cp ~/mark ~/repo4/evil.git/hooks/pre-receive
          git remote add origin /home/alice/repo4/evil.git
        """)
        push_confirmed("~/repo4")
        alice("git --git-dir ~/repo4/evil.git rev-parse main")
        alice("! ls /tmp/marker-* 2>/dev/null")

    with subtest("per-repository .jail: applied only as approved on a terminal"):
        alice("""
          mkdir -p ~/data-ro ~/data-rw && echo ro > ~/data-ro/f && echo secret > ~/secret
          ln -s ~/data-ro ~/data-link
          mkdir -p ~/.cache/jails/x ~/.ssh ~/.gnupg ~/.password-store ~/.local/share/keyrings ~/.local/state ~/.config/x ~/brain/wiki
          git init -q ~/repoc && cd ~/repoc && git commit -q --allow-empty -m one
          printf '#\\ta website and two folders\\nport 8090\\nport 8091\\nport 8090\\n\\nro ~/data-ro\\nrw /home/alice/data-rw/\\n' > .jail
        """)
        alice("test -d ~/data-ro && test -d ~/data-rw && cat ~/secret")
        # not approved yet: nothing applied, without a terminal or when refused
        out = start("test ! -e ~/data-ro && test ! -e ~/data-rw")
        assert "is not applied (it changed, and there is no terminal" in out, out
        out = start("test ! -e ~/data-ro", answer="no")
        assert "port 8090" in out and "is not applied (not approved)" in out, out
        # a tab shown as text, and what the file amounts to
        assert "#^Ia website" in out, out
        assert "jail: in effect: ports 8090 8091 | ro /home/alice/data-ro | rw /home/alice/data-rw" in out, out
        # approved: the folders, then used without asking
        start("cat ~/data-ro/f && ! touch ~/data-ro/x 2>/dev/null && touch ~/data-rw/x", answer="yes")
        alice("test -e ~/data-rw/x && test ! -e ~/data-ro/x")
        assert "not applied" not in start("cat ~/data-ro/f")
        # binds by fd, and bwrap closes those fds: the jail gets no handle on a host directory
        start("test \"$(ls /proc/self/fd | tr '\\n' ' ')\" = '0 1 2 3 '")

        # A bind source swapped for a link after jail checked it (a running jail
        # can do that below its rw folders) is refused when it is opened for bwrap.
        jb = "$(grep -o '/nix/store/[a-z0-9]*-jail-binds/bin/jail-binds' $(grep -o '/nix/store/[a-z0-9]*-jail-run/bin/jail-run' $(readlink -f $(command -v jail)) | head -n 1) | head -n 1)"
        alice(f"{jb} ro /home/alice/data-ro rw /home/alice/data-rw -- true")
        out = alice(f"! {jb} ro /home/alice/data-ro ro /home/alice/data-link -- touch /tmp/marker-binds 2>&1")
        assert "/home/alice/data-link changed after it was checked" in out, out
        alice("test ! -e /tmp/marker-binds")

        # the port: host 127.0.0.1:8090 reaches a listener on the jail's 127.0.0.1:8090
        listeners = "socat TCP-LISTEN:8091,bind=127.0.0.1 SYSTEM:'echo two' & socat TCP-LISTEN:8090,bind=127.0.0.1 SYSTEM:'echo inside'"
        holder = f"(jail ~/repoc -- sh -c {shlex.quote(listeners)} </dev/null & wait) >/dev/null 2>&1 &"
        alice(holder)
        machine.wait_until_succeeds("su - alice -c 'socat -u TCP:127.0.0.1:8091 -' | grep -q two", timeout=30)
        # on the host's 127.0.0.1 only, not on every address
        ss = machine.succeed("ss -Htln 'sport = :8090 or sport = :8091'")
        assert len(ss.splitlines()) == 2 and all(" 127.0.0.1:809" in l for l in ss.splitlines()), ss
        machine.wait_until_succeeds("su - alice -c 'socat -u TCP:127.0.0.1:8090 -' | grep -q inside", timeout=30)
        # and the jail still does not reach the host's loopback (control: "own network")
        start("if socat -u TCP:127.0.0.1:8123,connect-timeout=5 - | grep -q lo; then exit 1; fi; cat ~/data-ro/f")
        # a one-off next to a jail holding the port starts without it
        alice(holder)
        machine.wait_until_succeeds("ss -Htln 'sport = :8090' | grep -q .", timeout=30)
        out = start("cat ~/data-ro/f")
        assert "port 8090: 127.0.0.1:8090 is in use" in out and "not forwarded" in out, out
        machine.wait_until_succeeds("su - alice -c 'socat -u TCP:127.0.0.1:8091 -' | grep -q two", timeout=30)
        machine.wait_until_succeeds("su - alice -c 'socat -u TCP:127.0.0.1:8090 -' | grep -q inside", timeout=30)

        # the shared jail: a taken port stops its start, naming the port; once free it starts
        machine.wait_until_succeeds("! ss -Htln 'sport = :8090 or sport = :8091' | grep -q .", timeout=30)
        machine.succeed("systemd-run --unit=busy-8090 socat TCP-LISTEN:8090,bind=127.0.0.1,reuseaddr,fork SYSTEM:'echo busy'")
        machine.wait_until_succeeds("ss -Htln 'sport = :8090' | grep -q .", timeout=30)
        assert "port 8090" in start("", answer="", shared=True, ok=False)
        alice('test -z "$(systemctl --user list-units --plain --no-legend "jail-repoc-*")"')
        machine.succeed("systemctl stop busy-8090")
        terminal("termc", repo="/home/alice/repoc")
        sockc = "$(echo /run/user/1000/jails/repoc-*/tmux.sock)"
        machine.wait_until_succeeds(f"su - alice -c 'tmux -S {sockc} list-clients' | grep -q .", timeout=60)
        alice(f"tmux -S {sockc} send-keys -t main 'socat TCP-LISTEN:8090,bind=127.0.0.1,fork SYSTEM:pwd &' Enter")
        machine.wait_until_succeeds("su - alice -c 'socat -u TCP:127.0.0.1:8090 -' | grep -q repoc", timeout=30)
        alice("systemctl --user stop 'jail-repoc-*' termc")

        # jailed code edits .jail: not applied without approval, the approved copy stays
        start("printf '# \\033[2J\\nrw /home/alice/secret\\n' >> .jail")
        assert "is not applied" in start("test ! -e ~/secret && cat ~/data-ro/f")
        out = start("test ! -e ~/secret && cat ~/data-ro/f", answer="no")
        # shown as a diff, the escape sequence as text
        assert "+rw /home/alice/secret" in out and "^[[2J" in out and "\x1b" not in out, out
        alice("cat ~/secret")

        # refused with a reason, nothing applied: a linked .jail, a linked or forbidden path
        alice("git init -q ~/repoe && ln -s ~/repoc/.jail ~/repoe/.jail")
        out = start("test ! -e ~/data-ro", answer="yes", repo="~/repoe")
        assert "not a regular file" in out and "is not applied" in out, out
        refused = {
            "ro ~/data-link": "goes through a symlink", "ro /": "is or contains /home/alice", "ro /home": "is or contains /home/alice",
            "rw ~": "is or contains /home/alice", "rw ~/.local": "is or contains /home/alice/.local/share/jails",
            "ro ~/.local/share/jails": "is or contains /home/alice/.local/share/jails", "ro /etc": "is in /etc",
            "rw ~/.cache": "is or contains /home/alice/.cache/jails", "ro ~/.cache/jails": "is or contains /home/alice/.cache/jails",
            "ro ~/.cache/jails/x": "is in the jails' caches",
            "ro /nix/store": "is in /nix", "rw /run/user": "is in /run", "ro /proc": "is in /proc", "rw /tmp": "is /tmp",
            "rw ~/repoe": "is or contains /home/alice/repoe", "rw ~/repoe/.git": "is in the repository",
            "ro relative": "not an absolute path", "ro ~/missing": "does not exist",
            "rw ~/.ssh": "overlaps /home/alice/.ssh", "ro ~/.gnupg": "overlaps /home/alice/.gnupg",
            "ro ~/.claude": "overlaps /home/alice/.claude", "ro ~/.claude/skills": "overlaps /home/alice/.claude",
            "ro ~/.codex": "overlaps /home/alice/.codex", "ro ~/.claude.json": "overlaps /home/alice/.claude.json",
            "ro ~/.local/share/keyrings": "overlaps /home/alice/.local/share/keyrings",
            "ro ~/.password-store": "overlaps /home/alice/.password-store",
            "rw ~/.config/x": "overlaps /home/alice/.config (ro only)", "rw ~/.local/state": "overlaps /home/alice/.local/state (ro only)",
            "rw ~/.local/bin": "overlaps /home/alice/.local/bin (ro only)", "rw ~/brain/wiki": "overlaps /home/alice/brain (ro only)",
            "port 80": "a port is", "port 70000": "a port is", "port 8o": "a port is", "bind /tmp": "unknown keyword",
        }
        for line, why in refused.items():
            alice(f"rm -f ~/repoe/.jail && printf '# x\\n%s\\n' {shlex.quote(line)} > ~/repoe/.jail")
            # checked before asking: on a terminal (yes typed) only for two, as fast without one
            answer = "yes" if line in ["ro ~/data-link", "bind /tmp"] else None
            out = start("test ! -e ~/data-ro", answer=answer, repo="~/repoe")
            assert f".jail line 2: {line}: {why}" in out and "is not applied" in out, out
        alice("! ls ~/.local/share/jails/repoe-*/jail.approved")
        # too large, a FIFO (no wait on it), a directory: not applied, the jail starts
        for make, why in [("head -c 65537 /dev/zero | tr '\\0' '#' > .jail", "larger than 64 KiB"),
                          ("mkfifo .jail", "not a regular file"), ("mkdir .jail", "not a regular file")]:
            alice(f"cd ~/repoe && rm -rf .jail && {make}")
            out = start("test ! -e ~/data-ro", answer="yes", repo="~/repoe")
            assert f"is not applied (it is {why})" in out, out
        # an approved path that is gone: the jail does not start, and says why
        alice("mkdir ~/gone && cd ~/repoe && rm -rf .jail && echo 'ro ~/gone' > .jail")
        start("test -d ~/gone", answer="yes", repo="~/repoe")
        alice("rmdir ~/gone")
        out = start("true", repo="~/repoe", ok=False)
        assert ".jail line 1: ro ~/gone: does not exist" in out and "no longer applies" in out, out
        machine.wait_until_succeeds("! pgrep -u alice '^(xdg-dbus-proxy|passt|pasta)'", timeout=30)

    with subtest("terminals of one repository share one jail"):
        sock = "$(echo /run/user/1000/jails/repo-*/tmux.sock)"
        terminal("term1")
        machine.wait_until_succeeds(f"su - alice -c 'tmux -S {sock} list-clients' | grep -q .", timeout=60)
        terminal("term2")
        machine.wait_until_succeeds(f"test \"$(su - alice -c 'tmux -S {sock} list-clients' | wc -l)\" = 2", timeout=60)
        alice(f'test "$(tmux -S {sock} list-sessions | wc -l)" = 1')
        alice('test "$(systemctl --user list-units --plain --no-legend "jail-*" | wc -l)" = 1')
        # the shell in the session is jailed
        alice(f"tmux -S {sock} send-keys -t main 'ls ~/Nextcloud > ~/repo/probe 2>&1; echo done >> ~/repo/probe' Enter")
        machine.wait_until_succeeds("grep -q done /home/alice/repo/probe", timeout=30)
        alice("grep -q 'No such file' ~/repo/probe")
        # a one-off start next to it leaves its read-only binds in place
        jail("true")
        alice(f"tmux -S {sock} send-keys -t main 'touch ~/.codex/AGENTS.md 2> ~/repo/probe2; grep -c from-home-manager ~/.codex/AGENTS.md >> ~/repo/probe2' Enter")
        machine.wait_until_succeeds("grep -q '^1$' /home/alice/repo/probe2", timeout=30)
        alice("grep -q 'cannot touch' ~/repo/probe2")
        # jailed code can make a client exec a command on detach: it must stay sandboxed
        alice(f"tmux -S {sock} send-keys -t main 'tmux detach-client -s main -E \": > /tmp/marker-detach\"' Enter")
        machine.wait_until_succeeds(f"test -z \"$(su - alice -c 'tmux -S {sock} list-clients')\"", timeout=30)
        machine.sleep(2)  # let a client that would exec the command finish
        alice("! ls /tmp/marker-* 2>/dev/null")
        # the shared jail has its network and D-Bus proxy too, both end with it
        alice(f"tmux -S {sock} send-keys -t main '{notify} && socat -u TCP:server:8000 - > ~/repo/probe3' Enter")
        machine.wait_until_succeeds("grep -q remote /home/alice/repo/probe3", timeout=30)
        alice("pgrep -u alice '^xdg-dbus-proxy$' && pgrep -u alice '^(passt|pasta)'")
        # the shared jail's processes (here its keepalive's sleep) ignore no signal
        machine.wait_until_succeeds("grep -q '^SigIgn:[[:space:]]*0*$' /proc/$(pgrep -n -u alice -f 'bin/sleep 2$')/status", timeout=10)
        alice("systemctl --user stop 'jail-repo-*'")
        alice("! pgrep -u alice '^(xdg-dbus-proxy|passt|pasta)'")
        alice("! ls /run/user/1000/jails/*bus* 2>/dev/null")
        # and it starts again
        terminal("term3")
        machine.wait_until_succeeds(f"su - alice -c 'tmux -S {sock} list-clients' | grep -q .", timeout=60)
  '';
}
