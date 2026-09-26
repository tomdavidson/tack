# flake.nix
#
# tack's flake exports the sbx sandbox tooling for devenv consumers:
#
#   packages.<system>.sbx           bubblewrap sandbox wrapper
#   packages.<system>.sbx-apparmor  AppArmor profile helper for bwrap
#   packages.<system>.bubblewrap    the bwrap both of the above are built for
#
# Consumer wiring (rendered by configs/devenv):
#
#   devenv.yaml:
#     inputs:
#       tack:
#         url: github:tomdavidson/tack
#   devenv.nix:
#     packages = [ inputs.tack.packages.${pkgs.system}.sbx ... ];
#
# sbx and sbx-apparmor must stay built from the SAME bubblewrap: the
# AppArmor profile matches the exact bwrap store path. Both packages take
# the bubblewrap from this flake's nixpkgs input for that reason.
{
  description = "tack: shared engineering toolkit (sbx sandbox wrappers)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          bubblewrap = pkgs.bubblewrap;
        in
        {
          inherit bubblewrap;
          sbx = pkgs.callPackage ./pkgs/sbx.nix { inherit bubblewrap; };
          sbx-apparmor = pkgs.callPackage ./pkgs/sbx-apparmor.nix { inherit bubblewrap; };
          default = self.packages.${system}.sbx;
        }
      );
    };
}
