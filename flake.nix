{
  description = "Nix packages and service module for VU dials";

  outputs = {self, nixpkgs}: let
    overlay = final: _prev: import ./pkgs final;
  in {
    overlays.default = overlay;

    nixosModules.default = ./modules/vudials.nix;

    darwinModules.default = ./modules/vudials.nix;
  };
}
