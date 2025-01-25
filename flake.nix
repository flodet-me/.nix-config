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
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";

    stylix.url = "github:danth/stylix/release-24.11";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    hyprland.url = "github:hyprwm/Hyprland";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      nixos-wsl,
      nix-vscode-extensions,
      home-manager,
      hyprland,
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
            inherit inputs;
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
        };
        lunar = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/lunar/configuration.nix
          ];
        };
        wsl = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/wsl/configuration.nix
            nixos-wsl.nixosModules.default
            {
              system.stateVersion = "24.05";
              wsl.enable = true;
              wsl.defaultUser = "flodet";
            }
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;

              home-manager.users.flodet = import ./hosts/wsl/home/flodet.nix;
            }
          ];
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
