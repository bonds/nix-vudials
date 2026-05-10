{
  description = "Nix packages and service module for VU dials";

  outputs = {
    self,
    nixpkgs,
  }: {
    overlays.default = final: prev: {
      vuserver = prev.callPackage "${self}/pkgs/vuserver" {};
      vuclient = prev.callPackage "${self}/pkgs/vuclient" {};
    };

    nixosModules.default = ./modules/vudials.nix;

    darwinModules.default = ./modules/vudials.nix;
  };
}
