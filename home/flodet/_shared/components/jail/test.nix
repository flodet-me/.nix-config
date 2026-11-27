# NixOS VM test of the jail module (docs/jail.md): a normal user with
# home-manager runs `jail` and `jail-push`. Every "absent inside" assertion
# has a positive control outside, so it cannot pass vacuously.
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
        pkgs.git
        pkgs.tmux
        pkgs.socat
        pkgs.dig
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
          imports = [ ./. ];
          home.stateVersion = "26.05";
          home.file.probe.text = "from-home-manager";
          home.file.".codex/AGENTS.md".text = "from-home-manager"; # also bound read-only
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
      echo host > .codex/config.toml
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

    with subtest("shebang paths work"):
        jail("/usr/bin/env true && /bin/sh -c true")

    with subtest("no sudo, no user manager, no session bus or agent sockets"):
        alice("echo pw | sudo -S true")
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
        machine.wait_for_open_port(8123)
        alice("socat -u TCP:server:8000 - | grep -q remote && socat -u TCP:127.0.0.1:8123 - | grep -q lo")
        jail("socat -u TCP:server:8000 - | grep -q remote")
        jail("socat -u TCP:127.0.0.1:8123 - | grep -q lo", ok=False)
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

    with subtest("terminals of one repository share one jail"):
        def terminal(unit):
            alice(f"systemd-run --user --quiet --unit={unit} -E TERM=xterm sh -c 'sleep 600 | /run/current-system/sw/bin/script -qfc \"/etc/profiles/per-user/alice/bin/jail /home/alice/repo\" /dev/null'")

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
        alice("systemctl --user stop 'jail-repo-*'")
        alice("! pgrep -u alice '^(xdg-dbus-proxy|passt|pasta)'")
        alice("! ls /run/user/1000/jails/*bus* 2>/dev/null")
        # and it starts again
        terminal("term3")
        machine.wait_until_succeeds(f"su - alice -c 'tmux -S {sock} list-clients' | grep -q .", timeout=60)
  '';
}
