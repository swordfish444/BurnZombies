{
  description = "BurnZombies — native macOS menu-bar app that cleans up after AI coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      version = "0.21.0";
      releaseSha256 = "0000000000000000000000000000000000000000000000000000000000000000";
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        burnzombies = pkgs.stdenvNoCC.mkDerivation {
          pname = "burnzombies";
          inherit version;
          src = pkgs.fetchurl {
            url = "https://github.com/swordfish444/BurnZombies/releases/download/v${version}/BurnZombies-macOS-universal.tar.gz";
            sha256 = releaseSha256;
          };
          sourceRoot = ".";
          dontBuild = true;
          installPhase = ''
            mkdir -p $out/Applications $out/bin
            cp -R BurnZombies.app $out/Applications/BurnZombies.app
            ln -s $out/Applications/BurnZombies.app/Contents/MacOS/burnzombies $out/bin/burnzombies
          '';
          meta = with pkgs.lib; {
            description = "Cleans up orphaned processes, stale Git worktrees, and rebuildable junk left by AI coding agents";
            homepage = "https://github.com/swordfish444/BurnZombies";
            license = licenses.mit;
            platforms = platforms.darwin;
            mainProgram = "burnzombies";
          };
        };
        default = burnzombies;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.burnzombies}/bin/burnzombies";
        };
      });
    };
}
