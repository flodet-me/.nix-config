# NixOS VM test of the jail module (docs/jail.md): a normal user with
# home-manager runs `jail` and `jail-push`. Every "absent inside" assertion
# has a positive control outside, so it cannot pass vacuously.
{ home-manager }:
{
  name = "jail";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];
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
      ];
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        users.alice = {
          imports = [ ./. ];
          home.stateVersion = "26.05";
          home.file.probe.text = "from-home-manager";
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

    def jail(cmd, ok=True, repo="~/repo"):
        # host variables that must not reach the jail
        env = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus SSH_AUTH_SOCK=/run/user/1000/gnupg/S.gpg-agent.ssh"
        return alice(f"{env} jail {repo} -- sh -c {shlex.quote(cmd)}", ok)

    alice("""
      git config --global user.name a
      git config --global user.email a@example.com
      git config --global init.defaultBranch main
      mkdir -p Nextcloud brain/inbox .cache/nix .cache/docker .claude/skills .claude/rules .claude/agents .codex .local/bin
      echo secret > Nextcloud/secret
      echo note > brain/note
      echo '{}' > .claude/settings.json
      echo '{}' > .claude.json
      git init -q repo
      cd repo
      echo one > f
      git add f
      git commit -qm one
    """)

    with subtest("only the repository, brain and shared state are visible"):
        alice("cat ~/Nextcloud/secret && test -d ~/.cache/docker")
        jail("test ! -e ~/Nextcloud && test ! -e ~/.cache/docker && test ! -e ~/.gitconfig")
        jail('test "$HOME" = /home/alice && test "$PWD" = /home/alice/repo')
        jail("cat ~/brain/note")
        jail("touch ~/brain/x", ok=False)
        jail("touch ~/brain/inbox/x ~/repo/w ~/.cache/nix/x ~/.claude/x ~/.codex/x && echo x >> ~/.claude.json")
        alice("test -e ~/brain/inbox/x && test -e ~/repo/w && test -e ~/.claude/x")
        for p in [".claude/settings.json", ".claude/skills/x", ".claude/rules/x", ".claude/agents/x", ".local/bin/x"]:
            jail(f"touch ~/{p}", ok=False)

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
        jail('test "$XDG_RUNTIME_DIR" = /run/user/1000 && test -z "''${DBUS_SESSION_BUS_ADDRESS:-}" && test -z "''${SSH_AUTH_SOCK:-}"')
        jail('test -z "$(find /run/user /run/wrappers -type s 2>/dev/null)" && test ! -e /run/wrappers')

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
          git remote add origin /home/alice/remote.git
          # control: the planted hooks are live for a plain git outside
          git checkout -q -b probe && git checkout -q main && git status >/dev/null
          ls /tmp/marker-post-checkout /tmp/marker-fsmonitor
          rm -f /tmp/marker-*
        """)
        alice("jail-push ~/repo")
        alice('test "$(git --git-dir ~/remote.git rev-parse main)" = "$(cat ~/repo/.git/refs/heads/main)"')
        alice("! ls /tmp/marker-* 2>/dev/null")

        # the URL is stored on first use: a later change in the repository is ignored
        jail("git -C ~/repo -c user.name=a -c user.email=a@example.com commit -qm two --allow-empty && git -C ~/repo config remote.origin.url /home/alice/other.git")
        alice("cd / && jail-push ~/repo")
        alice('test "$(git --git-dir ~/remote.git rev-parse main)" = "$(cat ~/repo/.git/refs/heads/main)"')
        alice("test -z \"$(git --git-dir ~/other.git for-each-ref)\"")
        alice("! ls /tmp/marker-* 2>/dev/null")

    with subtest("jail-push refuses unsafe remotes and repositories"):
        alice("git init -q ~/repo2 && cd ~/repo2 && git commit -q --allow-empty -m one && git remote add origin x")
        for url in ["ext::sh -c touch% /tmp/marker-ext", "--upload-pack=touch /tmp/marker-opt", "fd::3", "file:///home/alice/remote.git", "/home/alice/Nextcloud", "-oProxyCommand=touch@x:y"]:
            alice(f"git -C ~/repo2 config -- remote.origin.url {shlex.quote(url)}")
            alice("jail-push ~/repo2", ok=False)
        alice("! ls /tmp/marker-* 2>/dev/null")
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
        alice("jail-push ~/repo4")
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
        # jailed code can make a client exec a command on detach: it must stay sandboxed
        alice(f"tmux -S {sock} send-keys -t main 'tmux detach-client -s main -E \": > /tmp/marker-detach\"' Enter")
        machine.wait_until_succeeds(f"test -z \"$(su - alice -c 'tmux -S {sock} list-clients')\"", timeout=30)
        machine.sleep(2)  # let a client that would exec the command finish
        alice("! ls /tmp/marker-* 2>/dev/null")
  '';
}
