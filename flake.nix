{
  description = "Custom config for myself";

  inputs = {
    systems.url = "github:nix-systems/default-linux";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    # home-manager, used for managing user configuration
    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      # The `follows` keyword in inputs is used for inheritance.
      # Here, `inputs.nixpkgs` of home-manager is kept consistent with
      # the `inputs.nixpkgs` of the current flake,
      # to avoid problems caused by different versions of nixpkgs.
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nvf.url = "github:notashelf/nvf";
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";

    stylix.url = "github:danth/stylix/release-24.11";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      nix-vscode-extensions,
      home-manager,
      nvf,
      ...
    }@inputs:
    let
      pkgs = nixpkgs.legacyPackages."x86_64-linux";
      pkgs-unstable = nixpkgs-unstable.legacyPackages."x86_64-linux";
      pkgs-vscode-extensions-daily = nix-vscode-extensions.extensions."x86_64-linux";
    in
    {

      nixosConfigurations = {
        desktop = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit pkgs-unstable;
            inherit pkgs-vscode-extensions-daily;
          };
          modules = [
            ./hosts/desktop/configuration.nix
            inputs.stylix.nixosModules.stylix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;

              home-manager.users.flodet = import ./hosts/desktop/home/flodet.nix;
              home-manager.extraSpecialArgs = {
                inherit pkgs-unstable;
                inherit pkgs-vscode-extensions-daily;
              };
            }
            nvf.nixosModules.default
          ];
        };
        laptop = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/laptop/configuration.nix
            inputs.stylix.nixosModules.stylix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;

              home-manager.users.flodet = import ./hosts/laptop/home/flodet.nix;
            }
          ];
          lunar = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              ./hosts/lunar/configuration.nix
            ];
          };
        };
      };

      devShells."x86_64-linux".default = pkgs.mkShell {
        NIX_CONFIG = "extra-experimental-features = nix-command flakes";

        packages = with pkgs; [
          nix
          git
          nixfmt-rfc-style
        ];
      };
    };
}
