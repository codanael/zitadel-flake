{
  description = "Zitadel packaged from source, kept current automatically";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    zitadel-src = {
      url = "github:zitadel/zitadel/v4.16.3";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, zitadel-src, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      overlays.default = final: prev: {
        zitadel = final.callPackage ./pkgs/zitadel/default.nix {
          zitadelSrc = zitadel-src;
        };
      };

      packages.${system} = rec {
        zitadel = (pkgs.extend self.overlays.default).zitadel;
        default = zitadel;
      };

      nixosModules.default = { config, lib, pkgs, ... }: {
        imports = [ ./modules/zitadel-hardened.nix ];
        config = lib.mkIf config.services.zitadel.enable {
          # Cache hits need this exact derivation; a consumer overlaying its own nixpkgs would rebuild from source.
          services.zitadel.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.zitadel;
        };
      };

      checks.${system}.zitadel-pg18 = import ./tests/zitadel-pg18.nix {
        inherit pkgs;
        overlay = self.overlays.default;
        hardenedModule = self.nixosModules.default;
      };
    };
}
