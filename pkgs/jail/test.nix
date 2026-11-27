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
        autoSubUidGidRange = true; # 100000:65536, as on the hosts: containers in a jail
      };
      # no /etc/subuid range: containers refused with a reason
      users.users.bob = {
        isNormalUser = true;
        autoSubUidGidRange = false;
        linger = true; # a user manager for its jails
      };
      # the image the container tests load (offline): busybox, root and nobody, a page
      environment.etc."jail-test/image.tar.gz".source = pkgs.dockerTools.buildImage {
        name = "localhost/jailtest";
        tag = "latest";
        copyToRoot = pkgs.buildEnv {
          name = "jailtest-root";
          paths = [
            pkgs.busybox
            pkgs.curl # to the API socket from a container (testcontainers' Ryuk)
            pkgs.dockerTools.fakeNss
            (pkgs.writeTextDir "www/index.html" "hello-from-web\n")
          ];
        };
      };
      programs.gnupg.agent.enable = true; # its socket is the control for "no gpg-agent"
      environment.systemPackages = [
        (pkgs.callPackage ./. { }) # as on the workstations
        pkgs.git
        pkgs.tmux
        pkgs.direnv
        pkgs.socat
        pkgs.zsh # the completion under zsh's bashcompinit
        pkgs.dig
        pkgs.curl
        (pkgs.callPackage ../../home/flodet/_shared/components/claude-code/codex/wrapper.nix { })
        (pkgs.callPackage ../winvm { }) # as on the workstations; Windows VMs in a jail
        pkgs.qemu-utils
        pkgs.swtpm
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
          # winvm's home on the host, as on desktop (home/flodet/desktop)
          xdg.configFile."winvm/home".text = "/home/alice/winvm-host\n";
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
        # jail push on a terminal, answering its question about an unstored URL;
        # a refusal must be a refusal, not a hang
        rc = f"rc=0; printf 'yes\\n' | timeout 60 script -qec 'jail push {repo}' /dev/null || rc=$?; echo rc=$rc; "
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
        # the host's name, resolvable (pasta's own name is not: zsh's hostname --fqdn failed)
        jail('test "$(cat /proc/sys/kernel/hostname)" = machine && getent ahosts machine')
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
        assert "jail push /home/alice/cont pushes to /home/alice/cremote.git" in out, out
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
        alice("jail push ~/cont/feature </dev/null")
        alice(f'test "$({remote} feature)" = "$({bare} feature)" && test "$({remote} main)" = "$(git -C ~/cseed rev-parse main)"'
              f' && test "$({bare} main)" != "$({remote} main)"')
        alice("jail push ~/cont </dev/null")
        alice(f'test "$({remote} main)" = "$({bare} main)" && ! {remote} -q --verify rel')
        alice("jail push ~/cont/rel/sub </dev/null")
        alice(f'test "$({remote} rel)" = "$({bare} rel)"')
        jail(f"{gc} -C main commit -qm m2 --allow-empty", repo="~/cont")
        alice("jail push ~/cont/var </dev/null")
        alice(f'test "$({remote} main)" = "$({bare} main)"')

        # a worktree whose .git points elsewhere: no branch of its own, a named one is pushed
        alice("cd ~/cont && git worktree add -q -b other other")
        for gd in ["/home/alice/cremote.git", "../../cseed/.git", "../.bare/worktrees/../../../cseed/.git", "/home/alice/cont/.bare"]:
            alice(f"printf 'gitdir: %s\\n' {shlex.quote(gd)} > ~/cont/other/.git")
            assert "name the branch" in refuses("jail push ~/cont/other"), gd
        alice(f"! {remote} -q --verify other")
        alice(f'jail push ~/cont/other other </dev/null && test "$({remote} other)" = "$({bare} other)"')

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
        alice("jail push ~/norm/wt </dev/null")
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
            for cmd in ["jail ~/bad/main -- true", "jail ~/bad -- true", "jail push ~/bad main"]:
                out = refuses(cmd)
                assert why in out, (make, cmd, out)
            alice("cd ~/bad && rm -rf .git && printf 'gitdir: ./.bare\\n' > .git && if [ -d bare ]; then rm -rf .bare && mv bare .bare; fi")
        assert alice("git --git-dir ~/cremote.git for-each-ref") == refs

        # a FIFO instead of a worktree's git directory: no wait on it
        alice("mv ~/cont/.bare/worktrees/rel ~/relgit && mkfifo ~/cont/.bare/worktrees/rel")
        assert "name the branch" in refuses("jail push ~/cont/rel")
        # a link instead of worktrees: the worktree's HEAD is not read through it
        alice("mv ~/cont/.bare/worktrees ~/wtcopy && ln -s ~/wtcopy ~/cont/.bare/worktrees")
        assert "name the branch" in refuses("jail push ~/cont/feature")

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

    with subtest("the repository's .envrc loads in the jail without direnv allow, the host still asks"):
        alice("echo 'export DIRENV_PROBE=loaded' > ~/repo/.envrc")
        jail("direnv exec . printenv DIRENV_PROBE | grep -qx loaded")
        jail("grep -qF 'prefix = [\"/home/alice/repo\"]' ~/.config/direnv/direnv.toml")
        alice("cd ~/repo && direnv exec . printenv DIRENV_PROBE", ok=False)
        alice("test ! -e ~/.config/direnv/direnv.toml")
        alice("rm ~/repo/.envrc")

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
        jail("codex features list >/dev/null && codex -c 'model=\"m\"' features list >/dev/null")
        assert "danger-full-access" in jail("codex -c 'model=\"m\"' " + sandbox.removeprefix("codex "), repo="~/repo")

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
        alice("jail push ~/repo </dev/null", ok=False)
        alice("test -z \"$(git --git-dir ~/remote.git for-each-ref)\"")
        push_confirmed("~/repo")
        alice('test "$(git --git-dir ~/remote.git rev-parse main)" = "$(cat ~/repo/.git/refs/heads/main)"')
        alice("test -e /tmp/ssh-global && ! ls /tmp/marker-* 2>/dev/null")  # the global sshCommand ran, the planted one not

        # the URL is stored on first use: a later change in the repository is ignored
        jail("git -C ~/repo -c user.name=a -c user.email=a@example.com commit -qm two --allow-empty && git -C ~/repo config remote.origin.url /home/alice/other.git")
        alice("cd / && jail-push ~/repo")  # the alias jail-push does what jail push does
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
        alice("jail push ~/repo5 </dev/null")
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
        alice("cd ~/repo && jail push ~/nonexistent main", ok=False)
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
        alice("jail push ~/repo3", ok=False)
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
          mkdir -p ~/.cache/jails/x ~/.cache/foo ~/.ssh ~/.gnupg ~/.password-store ~/.local/share/keyrings ~/.local/state ~/.config/x ~/brain/wiki
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
        # its shells know what is in effect (jail config)
        alice(f"tmux -S {sockc} send-keys -t main 'jail config > ~/repoc/probe-cfg 2>&1; echo done >> ~/repoc/probe-cfg' Enter")
        machine.wait_until_succeeds("grep -q done /home/alice/repoc/probe-cfg", timeout=30)
        out = alice("cat ~/repoc/probe-cfg")
        assert "in effect in this jail: ports 8090 8091 | ro /home/alice/data-ro | rw /home/alice/data-rw" in out, out
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
            "rw ~/.cache": "is or contains /home/alice/.cache", "ro ~/.cache/jails": "is in /home/alice/.cache, the jail has its own",
            "ro ~/.cache/jails/x": "is in /home/alice/.cache, the jail has its own", "ro ~/.cache/foo": "is in /home/alice/.cache, the jail has its own",
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

    with subtest("jail config checks .jail inside a jail and on the host, and writes nothing"):
        readme = "/run/current-system/sw/share/doc/jail/README.md"
        out = alice("jail --help")
        assert readme in out and "jail config [DIR]" in out, out
        jail(f"grep -q '^# jail' {readme} && grep -q 'jail config' {readme}")
        alice("""
          mkdir -p ~/cfg-ro && git init -q ~/repof && cd ~/repof && git commit -q --allow-empty -m one
          printf 'port 8095\\nro ~/cfg-ro\\n' > .jail
          git init -q ~/repog && echo 'port 8097' > ~/repog/.jail
        """)
        # a repository without a jail: checked, and no state or cache made for it
        out = alice("jail config ~/repog 2>&1")
        assert "would add: ports 8097 | ro none | rw none" in out and "approved: nothing yet" in out, out
        assert ".jail differs from the approved copy" in out, out
        alice("! ls -d ~/.local/share/jails/repog-* ~/.cache/jails/repog-* 2>/dev/null")
        # on the host: the approved copy, and nothing written
        start("true", answer="yes", repo="~/repof")
        snap = "find ~/.local/share/jails/repof-* ~/.cache/jails/repof-* -printf '%p %s %T@\\n' | sort"
        before = alice(snap)
        out = alice("jail config ~/repof 2>&1")
        assert alice(snap) == before
        assert "would add: ports 8095 | ro /home/alice/cfg-ro | rw none" in out, out
        assert "approved: ports 8095 | ro /home/alice/cfg-ro | rw none" in out, out
        assert ".jail matches the approved copy" in out, out

        def inside(cmd):
            # jail config inside a one-off jail of repof, its output apart from the start's
            start(f"{cmd} rc=0; jail config > ~/repof/cfg.out 2>&1 || rc=$?; echo rc=$rc >> ~/repof/cfg.out", repo="~/repof")
            return alice("cat ~/repof/cfg.out")

        out = inside("")
        assert "jail config: /home/alice/repof/.jail" in out, out
        assert "would add: ports 8095 | ro /home/alice/cfg-ro | rw none" in out, out
        assert "in effect in this jail: ports 8095 | ro /home/alice/cfg-ro | rw none" in out, out
        assert ".jail matches what is in effect in this jail" in out and "not checked inside a jail" in out, out
        assert "rc=0" in out, out
        # edited inside: pending, and how it gets applied
        out = inside("printf 'port 8096\\n' >> .jail &&")
        assert "would add: ports 8095 8096 | ro /home/alice/cfg-ro | rw none" in out, out
        assert "in effect in this jail: ports 8095 | ro /home/alice/cfg-ro | rw none" in out, out
        assert ".jail differs from what is in effect in this jail" in out, out
        assert "jail stop /home/alice/repof" in out and "type yes" in out and "rc=0" in out, out
        assert ".jail differs from the approved copy" in alice("jail config ~/repof 2>&1")
        # a bad line: named, non-zero, also on the host
        out = inside("printf 'port 80\\n' >> .jail &&")
        assert ".jail line 4: port 80: a port is" in out and "rc=1" in out, out
        out = alice("rc=0; jail config ~/repof 2>&1 || rc=$?; echo rc=$rc")
        assert ".jail line 4: port 80: a port is" in out and "rc=1" in out, out
        # inside as well: a linked .jail, and a path with .. (checked without the host's paths)
        out = inside("mv .jail .jail.real && ln -s .jail.real .jail &&")
        assert "is not applied: it is not a regular file" in out and "rc=1" in out, out
        out = inside("rm .jail && printf 'rw ~/x/../.ssh\\n' > .jail &&")
        assert ".jail line 1: rw ~/x/../.ssh: is not canonical" in out and "rc=1" in out, out
        # an empty .jail is not a missing one: against the approved copy it is pending
        out = inside(": > .jail &&")
        assert ".jail differs from what is in effect in this jail" in out and "rc=0" in out, out
        assert ".jail differs from the approved copy" in alice("jail config ~/repof 2>&1")
        # a nested repository has a jail of its own: this jail's config is not its
        out = inside("rm -rf sub && git init -q sub && cd sub &&")
        assert "has a jail of its own" in out and "in effect in this jail" not in out, out
        # nothing approved or stored from inside
        alice("printf 'port 8095\\nro ~/cfg-ro\\n' | cmp - ~/.local/share/jails/repof-*/jail.approved")
        alice("! ls ~/.local/share/jails/repof-*/jail.approved.new ~/.local/share/jails/repof-*/home/.local/share/jails 2>/dev/null")

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

    # Managing jails (jail list, status, stop, reset, push, help, completion).
    # Here repo's shared jail runs (term3); a one-off of repo starts below.
    import re
    jails = "/home/alice/.local/share/jails"

    def jname(repo):
        return alice(f"cd ~ && basename {jails}/{repo}-*").strip()

    def row(out, n):
        # jail list's line for jail n, by column
        rows = [re.split(r"  +", l.strip()) for l in out.splitlines() if l.startswith(n + " ")]
        assert len(rows) == 1, (n, out)
        return rows[0]

    def answer(cmd, a, ok=True):
        # cmd on a terminal, typing a
        rc = f"rc=0; printf '{a}\\n' | timeout 60 script -qec {shlex.quote(cmd)} /dev/null || rc=$?; echo rc=$rc; "
        return alice(rc + ("test $rc = 0" if ok else "test $rc != 0 && test $rc != 124"))

    with subtest("every start records its repository; jail list shows every jail"):
        r, c, e, f5 = jname("repo"), jname("repoc"), jname("repoe"), jname("repo5")
        assert alice(f"cat {jails}/{r}/repo").strip() == "/home/alice/repo"
        # a jail from before the repo file, and one whose repository is gone
        alice(f"rm {jails}/{f5}/repo && git init -q ~/goner")
        jail("true", repo="~/goner")
        g = jname("goner")
        alice("rm -rf ~/goner")
        alice("(jail ~/repo -- sleep 300 </dev/null & echo $! > /tmp/oneoff; wait) >/dev/null 2>&1 &")
        machine.wait_until_succeeds("pgrep -u alice -f '^sleep 300$'", timeout=30)
        # a folder named like a command is no command: here ~/list
        alice("mkdir ~/list")
        out = alice("cd ~ && jail list")
        assert re.split(r"  +", out.splitlines()[0].strip()) == ["NAME", "REPOSITORY", "SHARED", "ONE-OFF", ".JAIL", "PUSH", "HOME", "CACHE"], out
        line = row(out, r)
        assert line[1:6] == ["/home/alice/repo", "yes", "1", "none", "ssh://localhost/home/alice/remote.git"], line
        assert all(re.fullmatch(r"[0-9.,]+[KMGT]?", s) for s in line[6:]), line
        assert row(out, c)[1:6] == ["/home/alice/repoc", "no", "0", "pending", "-"], out
        assert row(out, e)[1:5] == ["/home/alice/repoe", "no", "0", "approved"], out
        assert row(out, f5)[1] == "?", out
        assert row(out, g)[1] == "/home/alice/goner (gone)", out

    with subtest("list, status, stop, reset, push, help and config are commands, a folder of that name is ./NAME"):
        for w in ["list", "status", "stop", "reset", "push", "help", "config"]:
            alice(f"mkdir -p ~/{w} && git init -q ~/{w}")
            jail(f'test "$PWD" = /home/alice/{w}', repo=f"./{w}")
        assert "Overview" in alice("cd ~ && jail help") and "NAME" in alice("cd ~ && jail list")

    with subtest("jail help groups the commands"):
        out = alice("jail help")
        for s in ["Work in a jail", "Overview", "Manage", "jail push [DIR]", "jail list", "jail status [DIR]",
                  "jail stop [DIR|NAME]", "jail reset [DIR|NAME]", "jail config [DIR]"]:
            assert s in out, (s, out)
        assert alice("jail --help") == out

    with subtest("jail status: config, running, unit, tmux clients, state, push URL; writes nothing"):
        out = alice("jail status ~/repo 2>&1")
        for s in ["jail config: /home/alice/repo/.jail", "running: shared, 1 one-off", f"unit: jail-{r} (active)",
                  f"state: {jails}/{r}", f"cache: /home/alice/.cache/jails/{r}", "push: ssh://localhost/home/alice/remote.git"]:
            assert s in out, (s, out)
        assert re.search(r"tmux clients: [1-9]", out), out
        snap = f"find {jails}/{jname('repof')} -printf '%p %s %T@\\n' | sort"
        before = alice(snap)
        out = alice("jail status ~/repof 2>&1")
        assert "running: no" in out and "push: none recorded" in out, out
        assert alice(snap) == before

    with subtest("jail reset refuses while the jail runs, and without saying what"):
        out = refuses("jail reset ~/repo")
        assert "--approved" in out and "--home" in out and "--all" in out, out
        out = refuses("jail reset ~/repo --home")
        assert f"jail-{r} runs" in out, out
        out = alice("jail stop ~/repo")
        assert f"stopped jail-{r}" in out, out
        alice(f"! systemctl --user is-active jail-{r}")
        out = alice("jail status ~/repo 2>&1")
        assert "running: 1 one-off" in out and f"unit: jail-{r} (inactive)" in out and "tmux clients: 0" in out, out
        assert "1 one-off" in refuses("jail reset ~/repo --home")
        assert "not running" in alice("jail stop ~/repo")
        alice("kill $(cat /tmp/oneoff)")
        machine.wait_until_succeeds("! pgrep -u alice -f '^sleep 300$'", timeout=30)
        assert row(alice("jail list"), r)[2:4] == ["no", "0"]

    with subtest("jail reset lists what it deletes and asks on a terminal"):
        out = refuses(f"jail reset {r} --home")
        assert f"{jails}/{r}/home" in out and f"{jails}/{r}/claude-plugin-data" in out and "no terminal" in out, out
        answer(f"jail reset {r} --home", "n", ok=False)
        alice(f"test -d {jails}/{r}/home")
        out = answer(f"jail reset {r} --home", "y")
        alice(f"test ! -e {jails}/{r}/home && test ! -e {jails}/{r}/claude-plugin-data && test -d {jails}/{r}/mirror.git && test -e {jails}/{r}/repo")
        # read-only folders (Go's module cache) go too
        # and a folder jailed code made unreadable
        jail("mkdir -p ~/ro/x && touch ~/ro/x/f && chmod -R a-w ~/ro && mkdir -p ~/z/y && touch ~/z/y/f && chmod 000 ~/z")
        answer(f"jail reset {r} --home", "y")
        alice(f"test ! -e {jails}/{r}/home")
        # the next start makes a new home, the push URL stays
        jail("grep -q from-home-manager ~/probe")
        alice("cd ~/repo && jail push </dev/null")  # DIR: the current directory
        answer("jail reset ~/repoe --approved", "y")
        alice(f"test ! -e {jails}/{e}/jail.approved && test -d {jails}/{e}/home")
        # by NAME: a gone repository, a dotted name
        out = answer(f"jail reset {g} --all", "y")
        assert f"/home/alice/.cache/jails/{g}" in out and "push URL" in out, out
        alice(f"test ! -e {jails}/{g} && test ! -e /home/alice/.cache/jails/{g}")
        alice("git init -q ~/.dotted")
        jail("true", repo="~/.dotted")
        d = jname(".dotted")
        assert d.startswith(".dotted-"), d
        answer(f"jail reset {d} --all", "y")
        alice(f"test ! -e {jails}/{d}")
        # a folder of that name here is a DIR, not the NAME; and no NAME outside the jails' state
        alice(f"mkdir -p ~/t/{c}")
        assert "not inside a git repository" in refuses(f"sh -c 'cd ~/t && jail reset {c} --approved'")
        for bad in ["..", ".", f"../{c}", "nojail-12345678"]:
            out = answer(f"jail reset {bad} --all", "y", ok=False)
            assert "deletes" not in out and ("not inside a git repository" in out or "no such directory" in out), (bad, out)
        alice(f"test -e {jails}/{c}/jail.approved && test -d ~/.local/share")

    def pending(cmd, tag):
        # cmd on a terminal in the background; it reads y once /tmp/go-tag exists
        feed = f"until [ -e /tmp/go-{tag} ]; do sleep 0.2; done; echo y"
        alice(f"(set +e; ({feed}) | script -qfec {shlex.quote(cmd)} /tmp/log-{tag}; echo rc=$? > /tmp/rc-{tag}) >/dev/null 2>&1 &")

    def release(tag):
        alice(f"touch /tmp/go-{tag}")
        machine.wait_until_succeeds(f"test -e /tmp/rc-{tag}", timeout=60)
        return alice(f"cat /tmp/log-{tag} /tmp/rc-{tag}")

    with subtest("jail reset checks again after the answer, and not while a start prepares"):
        # a one-off started while reset asks
        pending(f"jail reset {r} --home", "a")
        machine.wait_until_succeeds("grep -q 'Delete them' /tmp/log-a", timeout=60)
        alice("(jail ~/repo -- sleep 301 </dev/null & wait) >/dev/null 2>&1 &")
        machine.wait_until_succeeds("pgrep -u alice -f '^sleep 301$'", timeout=30)
        out = release("a")
        assert "one-off" in out and "rc=0" not in out, out
        alice(f"test -d {jails}/{r}/home")
        machine.succeed("pkill -u alice -f '^sleep 301$'")
        machine.wait_until_succeeds("! pgrep -u alice -f '^sleep 301$'", timeout=30)
        # a start still asking about .jail
        pending("jail ~/repoc -- true", "s")
        machine.wait_until_succeeds("grep -q 'Type yes' /tmp/log-s", timeout=60)
        out = answer(f"jail reset {c} --approved", "y", ok=False)
        assert "in progress" in out, out
        alice(f"test -e {jails}/{c}/jail.approved")
        assert "rc=0" in release("s")

    with subtest("jail stop by NAME, and --all"):
        s = jname("repos")
        terminal("term5")
        terminal("term6", repo="/home/alice/repos")
        machine.wait_until_succeeds(f"su - alice -c 'export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user is-active jail-{r} && systemctl --user is-active jail-{s}'", timeout=60)
        alice(f"jail stop {s}")
        alice(f"! systemctl --user is-active jail-{s} && systemctl --user is-active jail-{r}")
        terminal("term7", repo="/home/alice/repos")
        machine.wait_until_succeeds(f"su - alice -c 'export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user is-active jail-{s}'", timeout=60)
        out = alice("jail stop --all")
        assert f"jail-{r}" in out and f"jail-{s}" in out, out
        alice(f"! systemctl --user is-active jail-{r} && ! systemctl --user is-active jail-{s}")
        assert "no shared jail runs" in alice("jail stop --all")

    with subtest("the host commands refuse inside a jail"):
        for cmd in ["jail list", "jail status", "jail stop", "jail reset --home", "jail push", "jail-push ~/repo"]:
            jail(f"rc=0; {cmd} > ~/repo/inside.out 2>&1 || rc=$?; test $rc != 0")
            assert "on the host only" in alice("cat ~/repo/inside.out"), cmd
        alice("jail list >/dev/null && jail status ~/repo >/dev/null")  # the control

    with subtest("jail push: a folder that is also a branch is refused, not guessed"):
        alice("mkdir ~/repo/main")
        out = refuses("sh -c 'cd ~/repo && jail push main'")
        assert "jail push ./main" in out and "jail push . main" in out, out
        alice("rmdir ~/repo/main")

    with subtest("jail list and status escape paths"):
        alice("git init -q ~/$'nl\\nrow'")
        jail("true", repo="~/$'nl\\nrow'")
        out = alice("jail list")
        assert "/home/alice/nl^Jrow" in out and not any(l.startswith("row") for l in out.splitlines()), out
        assert "jail config: /home/alice/nl^Jrow/.jail" in alice("jail status ~/$'nl\\nrow' 2>&1")

    with subtest("bash completion for jail and jail push"):
        def complete(words, fn="_jail"):
            w = " ".join(shlex.quote(x) for x in words)
            src = "/run/current-system/sw/share/bash-completion/completions/" + words[0] + ".bash"
            return alice(f"cd ~ && set +e && source {src} && COMP_WORDS=({w}); COMP_CWORD={len(words) - 1}; {fn}; printf '%s\\n' \"''${{COMPREPLY[@]}}\"").split()
        assert {"status", "stop"} <= set(complete(["jail", "st"])), complete(["jail", "st"])
        assert {"reset", "repo", "repoc"} <= set(complete(["jail", "re"]))
        assert {r, "repo"} <= set(complete(["jail", "stop", ""]))
        assert {"--approved", "--home", "--all"} <= set(complete(["jail", "reset", r, "--"]))
        assert "/home/alice/repo" in complete(["jail", "push", ""])
        assert {"main", "probe"} <= set(complete(["jail", "push", "/home/alice/repo", ""]))
        assert "/home/alice/repo" in complete(["jail-push", ""], "_jail_push")
        assert "main" in complete(["jail-push", "/home/alice/repo", "m"], "_jail_push")
        assert complete(["jail", "list", ""]) == []
        # names jailed code chooses never run on the host: a mirror branch and a repository path
        evil = "m$(touch''${IFS}/tmp/pwned)"
        alice(f"git --git-dir={jails}/{r}/mirror.git update-ref refs/heads/{shlex.quote(evil)} refs/heads/main")
        alice("git init -q ~/" + shlex.quote("x" + evil))
        jail("true", repo="~/" + shlex.quote("x" + evil))
        c1 = complete(["jail", "push", ""])
        c2 = complete(["jail", "push", "/home/alice/repo", ""])
        c3 = complete(["jail-push", "/home/alice/repo", "m"], "_jail_push")
        machine.succeed("test ! -e /tmp/pwned")
        assert "/home/alice/repo" in c1 and "/home/alice/x" + evil not in c1, c1
        assert "main" in c2 and "main" in c3 and not any("touch" in w for w in c2 + c3), (c2, c3)

    with subtest("zsh completion: the same functions under bashcompinit, no chpwd in the repository"):
        def zcomplete(words, fn="_jail"):
            w = " ".join(shlex.quote(x) for x in words)
            src = "/run/current-system/sw/share/bash-completion/completions/jail.bash"
            z = ("chpwd() { touch /tmp/chpwd; }; autoload -U +X compinit && compinit -u -d /tmp/zcd; "
                 "autoload -U +X bashcompinit && bashcompinit; source " + src + "; "
                 "COMP_WORDS=(" + w + "); COMP_CWORD=" + str(len(words) - 1) + "; " + fn + "; print -l -- $COMPREPLY")
            return alice("cd ~ && zsh -fc " + shlex.quote(z)).split()
        assert {"status", "stop"} <= set(zcomplete(["jail", "st"]))
        z = zcomplete(["jail", "push", "/home/alice/repo", "m"])
        assert "main" in z and not any("touch" in x for x in z), z
        assert "main" in zcomplete(["jail-push", "/home/alice/repo", ""], "_jail_push")
        machine.succeed("test ! -e /tmp/pwned && test ! -e /tmp/chpwd")

    # Containers (.jail line containers; docs/jail.md, ADR 0007)
    k = "~/repok"
    nopodman = "! pgrep -f '(^|/)(podman|[.]podman-wrapped|conmon|httpd)( |$)' && ! pgrep -u alice '^(xdg-dbus-proxy|passt|pasta)' && ! pgrep -u alice -f '^sleep infinity$'"

    with subtest("containers: only with the .jail line containers"):
        # without it: no tun device, no podman or docker, no API, no wrappers (see "no sudo")
        jail('test ! -e /dev/net/tun && ! command -v podman && ! command -v docker && test -z "''${DOCKER_HOST:-}"'
             " && test ! -e /run/user/1000/podman && ! grep -qsxE '(podman|[.]podman-wrappe)' /proc/[0-9]*/comm"
             ' && test ! -e /sys/fs/cgroup && test "$(wc -l < /proc/self/uid_map)" = 1')
        alice("""
          git init -q ~/repok && cd ~/repok && git commit -q --allow-empty -m one
          printf 'containers\\nport 8092\\n' > .jail
          cat > compose.yaml <<'EOF'
    services:
      web:
        image: localhost/jailtest
        pull_policy: never
        command: httpd -f -p 80 -h /www
        ports: ["8092:80"]
      client:
        image: localhost/jailtest
        pull_policy: never
        depends_on: [web]
        command: sh -c "until wget -qO- http://web/; do sleep 0.5; done"
    EOF
        """)
        out = alice("jail config ~/repok 2>&1")
        assert "would add: ports 8092 | ro none | rw none | containers" in out, out
        out = start("true", answer="yes", repo=k)
        assert "jail: in effect: ports 8092 | ro none | rw none | containers" in out, out
        assert "is not applied" not in out, out
        # without a subuid range: refused, naming what is missing
        jr = "$(grep -o '/nix/store/[a-z0-9]*-jail-run/bin/jail-run' $(readlink -f $(command -v jail)) | head -n 1)"
        ju = alice(f"grep -o '/nix/store/[a-z0-9]*-jail-userns/bin/jail-userns' {jr} | head -n 1").strip()
        out = machine.fail(f"su - bob -c '{ju} true' 2>&1")
        assert "no range for bob in /etc/subuid" in out, out
        # and a jail with containers, one-off or shared: refused on the terminal
        machine.wait_for_unit("user@1001.service")
        def bob(cmd):
            b = "export XDG_RUNTIME_DIR=/run/user/1001; cd ~/repob; rc=0; timeout 60 script -qec " + shlex.quote(cmd) + " /dev/null < ~/yes || rc=$?; echo rc=$rc; test $rc != 0 && test $rc != 124"
            return machine.succeed("su - bob -c " + shlex.quote(b))
        machine.succeed("su - bob -c " + shlex.quote("git init -q ~/repob && cd ~/repob && git -c user.name=b -c user.email=b@x commit -q --allow-empty -m one"
                        " && printf 'containers\\n' > .jail && printf 'yes\\n' > ~/yes"))
        for cmd in ["jail ~/repob -- true", "jail ~/repob"]:
            out = bob(cmd)
            assert "no range for bob in /etc/subuid" in out, (cmd, out)
        machine.fail("su - bob -c 'XDG_RUNTIME_DIR=/run/user/1001 systemctl --user list-units --all --plain --no-legend \"jail-*\"' | grep -q .")

    with subtest("containers: capabilities, fds, many uids"):
        # CAP_SETUID and CAP_SETGID, in the jail's own user namespace only (newuidmap for podman)
        caps = "grep -E '^Cap(Inh|Prm|Eff|Amb):' /proc/self/status | grep -v ':[[:space:]]*00000000000000c0$'"
        jail(f'test -z "$({caps})" && grep -q "^NoNewPrivs:[[:space:]]*1$" /proc/self/status', repo=k)
        # nothing open beyond 0-2 (3 is ls's): no user namespace or pipe fd left to the jail
        jail("test \"$(ls /proc/self/fd | tr '\\n' ' ')\" = '0 1 2 3 '", repo=k)
        jail("podman load -q -i /etc/jail-test/image.tar.gz && podman unshare cat /proc/self/uid_map | grep -Eq '^ *1 +100000 +65536$'", repo=k)
        # a container chowns, switches users and runs as another uid; on the host those are subuids
        jail('mkdir -p out && podman run --rm -v "$PWD/out:/out" localhost/jailtest sh -c'
             " 'touch /out/f && chown 4321:4321 /out/f && su -s /bin/sh nobody -c \"id -u\"' | grep -qx 65534"
             ' && test "$(podman run --rm --user 4321 localhost/jailtest id -u)" = 4321', repo=k)
        alice('test "$(stat -c %u:%g ~/repok/out/f)" = 104320:104320')
        # a folder a container made private as a subuid: not yours to delete, podman unshare's
        jail("podman run --rm -v \"$PWD/out:/out\" localhost/jailtest sh -c 'mkdir /out/p && touch /out/p/f && chown -R 4321 /out/p && chmod 700 /out/p'"
             " && ! rm -rf out 2>/dev/null && test -d out/p && podman unshare rm -rf out && test ! -e out", repo=k)
        # the same network as every jail: out yes, host loopback and the gateway no
        jail("socat -u TCP:server:8000 - | grep -q remote && ! socat -u TCP:127.0.0.1:8123,connect-timeout=5 - | grep -q lo"
             ' && gw=$(ip route show default | cut -d" " -f3) && test -n "$gw" && ! socat -u TCP:$gw:8123,connect-timeout=5 - | grep -q lo', repo=k)
        # cgroup limits fail loudly (no delegated cgroup)
        jail("! podman run --rm --memory 64m localhost/jailtest true 2> err && grep -q cgroup err", repo=k)

    with subtest("containers: docker, a user network by name, build, the API socket inside only"):
        jail('test "$DOCKER_HOST" = unix:///run/user/1000/podman/podman.sock && test -S /run/user/1000/podman/podman.sock'
             " && docker network create n1 && docker run -d --network n1 --name a localhost/jailtest httpd -f -p 80 -h /www"
             " && docker run --rm --network n1 localhost/jailtest wget -qO- http://a/ | grep -q hello-from-web"
             " && docker ps --format '{{.Names}}' | grep -qx a"
             # the API socket mounted into a container, which lists the containers through it (testcontainers' Ryuk)
             " && docker run --rm --name tc -v /run/user/1000/podman/podman.sock:/var/run/docker.sock localhost/jailtest"
             " curl -sSf --unix-socket /var/run/docker.sock http://d/containers/json > tc.json"
             " && grep -q '\"/tc\"' tc.json && grep -q '\"/a\"' tc.json || { cat tc.json; exit 1; }", repo=k)
        jail("printf 'FROM localhost/jailtest\\nRUN echo built > /built\\n' > Dockerfile && docker build -q -t localhost/built ."
             " && docker run --rm localhost/built cat /built | grep -qx built", repo=k)
        machine.wait_until_succeeds(nopodman, timeout=30)

    with subtest("containers: docker compose, a published port in the jail and on the host"):
        up = ("docker compose up -d && until docker compose logs client | grep -q hello-from-web; do sleep 1; done"
              " && curl -sf http://127.0.0.1:8092/ | grep -q hello-from-web && podman compose ps | grep -q web"
              " && touch ~/repok/up && sleep 300")
        alice(f"rm -f /tmp/kjail; (jail ~/repok -- sh -c {shlex.quote(up)} </dev/null >/tmp/compose.log 2>&1 & echo $! > /tmp/kjail; wait) >/dev/null 2>&1 &")
        machine.wait_until_succeeds("test -e /home/alice/repok/up || { test -s /tmp/kjail && ! kill -0 $(cat /tmp/kjail); }", timeout=180)
        print(machine.succeed("cat /tmp/compose.log"))
        # a one-off's cgroup is a scope of its own, not the terminal's
        alice("grep -Eqx '0::/.*/jail-repok-[^/]*-[0-9]+[.]scope' $(printf '/proc/%s/cgroup ' $(pgrep -u alice -x jail-run))")
        alice("test -e ~/repok/up && curl -sf http://127.0.0.1:8092/ | grep -q hello-from-web")
        # the API is the jail's own: no podman socket on the host
        alice("test ! -e /run/user/1000/podman")
        # it ends with the jail, containers and all, also by SIGKILL
        alice("kill $(cat /tmp/kjail)")
        machine.wait_until_succeeds(nopodman + " && ! ss -Htln 'sport = :8092' | grep -q .", timeout=30)
        alice("(env --default-signal=INT jail ~/repok -- sleep 302 </dev/null & echo $! > /tmp/kjail; wait) >/dev/null 2>&1 &")
        machine.wait_until_succeeds("pgrep -u alice -f '^sleep 302$' && pgrep -f '(^|/)podman$'", timeout=60)
        alice("kill -KILL $(cat /tmp/kjail)")
        machine.wait_until_succeeds(nopodman + " && ! pgrep -u alice -f '^sleep 302$'", timeout=30)

    with subtest("containers: the shared jail's shells find them; each instance has its own"):
        terminal("termk", repo="/home/alice/repok")
        sockk = "$(echo /run/user/1000/jails/repok-*/tmux.sock)"
        machine.wait_until_succeeds(f"su - alice -c 'tmux -S {sockk} list-clients' | grep -q .", timeout=60)
        probe = ("command -v podman docker newuidmap > ~/repok/probe-k; docker run -d --name inshared localhost/jailtest sleep 600 >/dev/null;"
                 " docker ps --format '{{.Names}}' >> ~/repok/probe-k; echo done >> ~/repok/probe-k")
        alice(f"tmux -S {sockk} send-keys -t main {shlex.quote(probe)} Enter")
        machine.wait_until_succeeds("grep -q done /home/alice/repok/probe-k", timeout=60)
        out = alice("cat ~/repok/probe-k")
        assert "/run/wrappers/bin/podman\n/run/wrappers/bin/docker\n/run/wrappers/bin/newuidmap\ninshared\n" in out, out
        jail('test -z "$(docker ps -aq)" && test -z "$(podman ps -aq)"', repo=k)
        alice("test ! -e /run/user/1000/podman")
        alice("systemctl --user stop 'jail-repok-*' termk")
        machine.wait_until_succeeds(nopodman, timeout=30)

    with subtest("containers: jail reset deletes what they made as subuids"):
        kn = jname("repok")
        jail("podman volume create v >/dev/null && podman run --rm -v v:/d localhost/jailtest"
             " sh -c 'mkdir /d/x && touch /d/x/f && chown -R 4321:4321 /d/x && chmod 700 /d/x'", repo=k)
        # control: your own rm cannot
        alice(f"! rm -rf ~/.cache/jails/{kn} 2>/dev/null && test -d ~/.cache/jails/{kn}")
        answer(f"jail reset {kn} --all", "y")
        alice(f"test ! -e ~/.cache/jails/{kn} && test ! -e {jails}/{kn}")

    # Windows VMs (.jail line winvm; docs/jail.md, ADR 0007)
    w = "~/repow"
    hostsnap = "find ~/winvm-host -printf '%p %s %T@ %m\\n' | sort"

    with subtest("winvm: every jail has a WINVM_HOME of its own; without the line nothing of the host's"):
        alice("""
          mkdir -p ~/winvm-host/state/images/win10 ~/winvm-host/state/vms/hostvm
          qemu-img create -q -f qcow2 ~/winvm-host/state/images/win10/base.qcow2 16M
          chmod a-w ~/winvm-host/state/images/win10/base.qcow2
          echo bios > ~/winvm-host/state/images/win10/firmware
          echo hostkey > ~/winvm-host/state/id_ed25519 && chmod 600 ~/winvm-host/state/id_ed25519
          echo hostpub > ~/winvm-host/state/id_ed25519.pub
          touch ~/winvm-host/state/vms/hostvm/disk.qcow2
        """)
        # the control: on the host winvm takes ~/.config/winvm/home
        alice('test "$(winvm home)" = /home/alice/winvm-host && winvm list | grep -q "^hostvm "')
        jail('test "$WINVM_HOME" = /home/alice/.cache/winvm && test "$(winvm home)" = /home/alice/.cache/winvm'
             " && test ! -e ~/.cache/winvm && test ! -e ~/winvm-host && winvm list 2>&1 | grep -q 'no VMs'")

    with subtest("winvm: the line binds the host's base images and key read-only, VMs are the jail's"):
        alice("git init -q ~/repow && printf 'winvm\\nport 33891\\n' > ~/repow/.jail")
        assert "would add: ports 33891 | ro none | rw none | winvm" in alice(f"jail config {w} 2>&1")
        out = start("true", answer="yes", repo=w)
        assert "jail: in effect: ports 33891 | ro none | rw none | winvm" in out, out
        before = alice(hostsnap)
        s = "$WINVM_HOME/state"
        jail(f'test "$WINVM_HOME" = /home/alice/.cache/winvm && test -f {s}/images/win10/base.qcow2'
             f" && grep -qx hostkey {s}/id_ed25519 && grep -qx hostpub {s}/id_ed25519.pub"
             f" && test ! -e {s}/vms/hostvm && test ! -e ~/winvm-host", repo=w)
        # read-only: no new file, no change, no removal
        for cmd in [f"touch {s}/images/x", f"touch {s}/images/win10/x", f"echo x >> {s}/id_ed25519",
                    f"echo x > {s}/id_ed25519.pub", f"rm -f {s}/id_ed25519.pub", f"chmod u+w {s}/images/win10/base.qcow2",
                    f"rm -rf {s}/images/win10"]:
            jail(f"! {cmd} 2>/dev/null && grep -qx hostpub {s}/id_ed25519.pub && test -f {s}/images/win10/base.qcow2", repo=w)
        # winvm itself: a VM on the shared base image, in the jail's home
        jail("winvm images | grep -Eq '^win10 +[0-9]' && winvm new t1 --image win10 && winvm list | grep -q '^t1 '"
             f" && qemu-img info {s}/vms/t1/disk.qcow2 | grep -qx 'backing file: /home/alice/.cache/winvm/state/images/win10/base.qcow2'", repo=w)
        alice("test -f ~/.cache/jails/repow-*/winvm/state/vms/t1/disk.qcow2")
        # what would write the base images says why it cannot
        jail("! winvm build --image win10 2> err && grep -q 'read-only here' err", repo=w)
        # swtpm runs (a UEFI VM's TPM)
        jail("swtpm socket --tpm2 --tpmstate dir=$(mktemp -d) --ctrl type=unixio,path=/tmp/tpm.sock --daemon --pid file=/tmp/tpm.pid"
             " && for i in $(seq 50); do test -S /tmp/tpm.sock && break; sleep 0.1; done && test -S /tmp/tpm.sock && kill $(cat /tmp/tpm.pid)", repo=w)
        if kvm:
            # QEMU on KVM, without a PipeWire socket, its port forwards on the jail's 127.0.0.1
            jail("printf 'VM_RAM=256M\\nVM_CPUS=1\\n' > $WINVM_HOME/state/vms/t1/vm.env && winvm -n t1 start --headless 2> err"
                 " && grep -q 'no PipeWire' err && winvm list | grep -q '^t1 .*running'"
                 " && ss -Htln 'sport = :33891' | grep -q 127.0.0.1 && ss -Htln 'sport = :2223' | grep -q 127.0.0.1"
                 " && winvm -n t1 stop --force", repo=w)
        jail("winvm destroy t1 --yes && test ! -e $WINVM_HOME/state/vms/t1", repo=w)
        assert alice(hostsnap) == before

    with subtest("winvm: RDP from the host through the .jail port"):
        # a stand-in for the VM's RDP forward (winvm's 127.0.0.1:33891 inside, slot 1)
        rdp = "socat TCP-LISTEN:33891,bind=127.0.0.1,fork SYSTEM:'echo rdp'"
        alice(f"(jail {w} -- sh -c {shlex.quote(rdp)} </dev/null & wait) >/dev/null 2>&1 &")
        machine.wait_until_succeeds("su - alice -c 'socat -u TCP:127.0.0.1:33891 -' | grep -q rdp", timeout=30)
        machine.succeed("pkill -u alice -f 'TCP-LISTEN:33891'")
        machine.wait_until_succeeds("! pgrep -u alice '^(xdg-dbus-proxy|passt|pasta)'", timeout=30)

    with subtest("winvm: the host's WINVM_HOME as winvm finds it: $WINVM_HOME, the config file, the default"):
        alice("mkdir -p ~/winvm-env/state/images/envmark ~/.local/share/winvm/state/images/defmark")
        imgs = "ls $WINVM_HOME/state/images"
        assert alice(f"WINVM_HOME=/home/alice/winvm-env jail {w} -- sh -c {shlex.quote(imgs)}").split() == ["envmark"]
        assert alice(f"XDG_CONFIG_HOME=/home/alice/nocfg jail {w} -- sh -c {shlex.quote(imgs)}").split() == ["defmark"]
        assert alice(f"jail {w} -- sh -c {shlex.quote(imgs)}").split() == ["win10"]
        # none there: nothing bound, the jail's own folder (here an empty mount point of the start before)
        alice("git init -q ~/repow2 && echo winvm > ~/repow2/.jail")
        start("true", answer="yes", repo="~/repow2")
        alice("WINVM_HOME=/home/alice/winvm-none jail ~/repow2 -- sh -c"
              " 'test -z \"$(ls -A $WINVM_HOME/state/images)\" && mkdir $WINVM_HOME/state/images/x'")
        # building stays on the host
        jail("! winvm build --image win10 2> err && grep -q 'not in a jail' err", repo="~/repow2")
        # one in the repository: refused, it is read-write there
        alice("mkdir -p ~/repow/wh/state/images")
        out = refuses(f"env WINVM_HOME=/home/alice/repow/wh jail {w} -- true")
        assert "is in the repository" in out, out

    with subtest("a repository under /tmp gets a jail"):
        alice("git init -q /tmp/jailtmp")
        jail('test "$PWD" = /tmp/jailtmp', repo="/tmp/jailtmp")
  '';
}
