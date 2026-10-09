{
  description = "A minimal Zig development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
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
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig
              pkgs.pkg-config
              pkgs.libdrm
              pkgs.libgbm
              pkgs.freetype
              pkgs.libinput
              pkgs.systemd
              pkgs.libxkbcommon
              pkgs.libGL # Provides EGL and OpenGL headers
            ];
          };
        });
    };
}
