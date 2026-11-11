{
  description = "A minimal Zig development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig-overlay }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ zig-overlay.overlays.default ];
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zigpkgs."0.17.1"
              pkgs.pkg-config
              pkgs.libdrm
              pkgs.freetype
              pkgs.harfbuzz
              pkgs.libpng
              pkgs.libinput
              pkgs.seatd
              pkgs.systemd
              pkgs.libxkbcommon
            ];
          };
        });
    };
}
