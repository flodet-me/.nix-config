{
  description = "Custom config for myself";
  inputs = {
    hardware = {
      url = "github:nixos/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default-linux";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      url = "github:danth/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-topology = {
      url = "github:oddlama/nix-topology";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      systems,
      ...
    }@inputs:
    let
      inherit (self) outputs;
      inherit (nixpkgs) lib;
      # The one user of all machines (home/<username>/<host>, host.user)
      username = "flodet";

      mkHost =
        {
          host,
          user ? false,
        }:
        lib.nixosSystem {
          specialArgs = { inherit inputs outputs; };
          modules = [
            ./hosts/${host}
            (
              { config, ... }:
              {
                host.user = username;
                # What it was built from: `nixos-version --configuration-revision`
                # and /run/current-system/flake-source, compared by switch-review.
                # switch-review builds `path:<store path>`, which carries a clean
                # tree's rev but no dirtyRev: a dirty tree records its narHash.
                system.configurationRevision = self.rev or self.dirtyRev or self.narHash or null;
                # Workstations only: a server closure must not carry the repository
                # (other hosts' encrypted secrets); switch-review is local anyway.
                system.systemBuilderCommands = lib.mkIf (config.host.role == "workstation") ''
                  ln -s ${self} $out/flake-source
                '';
              }
            )
          ]
          ++ lib.optionals user [
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs outputs; };
              home-manager.users.${username} = import ./home/${username}/${host};
            }
          ];
        };

      # Offline installer ISO (installer/, docs/installer.md). Not a host.
      installer = lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs outputs; };
        modules = [ ./installer ];
      };
      pkgsFor = lib.genAttrs (import systems) (
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        }
      );
      forEachSystem = f: lib.genAttrs (import systems) (system: f pkgsFor.${system});
    in
    {
      overlays = import ./overlays { inherit inputs; };
      packages =
        lib.recursiveUpdate
          (forEachSystem (pkgs: import ./pkgs { inherit pkgs; } // import ./scripts { inherit pkgs; }))
          {
            x86_64-linux.installer-iso = installer.config.system.build.isoImage;
            x86_64-linux.install-host = installer.config.system.build.installHost;
            # `nix build .#network-map`: SVGs of topology.nix (docs/network.md)
            x86_64-linux.network-map =
              (import inputs.nix-topology {
                pkgs = pkgsFor.x86_64-linux.extend inputs.nix-topology.overlays.default;
                modules = [
                  ./topology.nix
                  {
                    # Extended only here, so the real hosts stay untouched
                    nixosConfigurations = lib.mapAttrs (
                      _: host: host.extendModules { modules = [ inputs.nix-topology.nixosModules.default ]; }
                    ) (lib.getAttrs [ "moon" "desktop" ] self.nixosConfigurations);
                  }
                ];
              }).config.output;
          };
      # `nix run .#check` / `.#gate` from the repository root (docs/testing.md)
      apps = forEachSystem (
        pkgs:
        lib.genAttrs [ "check" "gate" ] (name: {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.${name};
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}.${name}) meta;
        })
      );
      devShells = forEachSystem (pkgs: import ./shell.nix { inherit pkgs; });
      formatter = forEachSystem (pkgs: pkgs.nixfmt);
      checks = forEachSystem (pkgs: {
        # Fail if any Nix file is not RFC-formatted.
        formatting = pkgs.runCommand "formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          cd ${self}
          find . -name '*.nix' -exec nixfmt --check {} +
          touch $out
        '';
        # Builds all workflow scripts (runs shellcheck via writeShellApplication),
        # the switch-review diff test and winvm's test (pkgs/winvm/test.nix).
        scripts =
          let
            scripts = import ./scripts { inherit pkgs; };
          in
          pkgs.linkFarm "scripts-check" (
            lib.mapAttrsToList (name: drv: {
              inherit name;
              path = drv;
            }) scripts
            ++ [
              {
                name = "switch-review-test";
                path = import ./scripts/switch-review/test.nix {
                  inherit pkgs;
                  inherit (scripts) switch-review;
                };
              }
              {
                name = "winvm-test";
                path = pkgs.callPackage ./pkgs/winvm/test.nix { inherit (import ./pkgs { inherit pkgs; }) winvm; };
              }
            ]
          );
        # Fail if a secrets file was committed (partly) unencrypted.
        sops-encrypted = pkgs.runCommand "sops-encrypted" { } ''
          cd ${self}
          status=0
          for f in $(find hosts home -name '*secrets.yaml'); do
            if ! grep -q '^    mac: ENC\[' "$f"; then
              echo "$f: not a sops file"; status=1
            elif grep -vE '^(sops:|[[:space:]]|#|$)' "$f" | grep -v ': ENC\['; then
              echo "$f: plaintext values above"; status=1
            fi
          done
          [ "$status" = 0 ] && touch $out
          exit $status
        '';
        # VM test: what a repository jail can see and do (docs/jail.md).
        jail = pkgs.testers.runNixOSTest (import ./pkgs/jail/test.nix { inherit home-manager; });
      });
      # Machines. `user` adds home-manager (home/<username>/<host>).
      nixosConfigurations = {
        desktop = mkHost {
          host = "desktop";
          user = true;
        };
        laptop = mkHost {
          host = "laptop";
          user = true;
        };
        moon = mkHost { host = "moon"; };
        vps = mkHost { host = "vps"; }; # cloud server template (docs/cloud.md)
      };
    };
}
