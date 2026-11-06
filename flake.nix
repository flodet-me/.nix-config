{
  description = "Custom config for myself";
  inputs = {
    hardware.url = "github:nixos/nixos-hardware";
    systems.url = "github:nix-systems/default-linux";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    stylix.url = "github:danth/stylix";
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
    hyprpanel = {
      url = "github:Jas-SinghFSU/HyprPanel";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
      nix-vscode-extensions,
      home-manager,
      stylix,
      systems,
      ...
    }@inputs:
    let
      inherit (self) outputs;
      lib = nixpkgs.lib // home-manager.lib;

      mkHost =
        {
          host,
          user ? false,
        }:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs outputs; };
          modules = [
            ./hosts/${host}
          ]
          ++ lib.optionals user [
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs outputs; };
              home-manager.users.flodet = import ./home/flodet/${host};
            }
          ];
        };

      # Offline installer ISO (installer/, docs/installer.md). Not a host.
      installer = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs outputs; };
        modules = [ ./installer ];
      };
      forEachSystem = f: lib.genAttrs (import systems) (system: f pkgsFor.${system});
      pkgsFor = lib.genAttrs (import systems) (
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ ];
        }
      );
    in
    {
      inherit lib;
      overlays = import ./overlays { inherit inputs outputs; };
      packages =
        lib.recursiveUpdate
          (forEachSystem (pkgs: import ./pkgs { inherit pkgs; } // import ./scripts { inherit pkgs; }))
          {
            x86_64-linux.installer-iso = installer.config.system.build.isoImage;
          };
      devShells = forEachSystem (pkgs: import ./shell.nix { inherit pkgs; });
      formatter = forEachSystem (pkgs: pkgs.nixfmt);
      checks = forEachSystem (pkgs: {
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
      });
      # Machines. `user` adds home-manager for flodet (home/flodet/<host>).
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
