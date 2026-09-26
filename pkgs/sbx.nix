# pkgs/sbx.nix
#
# sbx wrapper package: pkgs/sbx.sh with the bwrap path baked in.
#
# Built from the same nixpkgs and bubblewrap as pkgs/sbx-apparmor.nix so the
# AppArmor profile installed by sbx-apparmor matches the exact bwrap store
# path that sbx executes. If they are built from different inputs, the
# profile stops matching and bwrap is blocked until it is reinstalled.
{
  pkgs,
  bubblewrap,
}:
pkgs.writeShellApplication {
  name = "sbx";
  runtimeInputs = [
    bubblewrap
    pkgs.coreutils
    pkgs.gnugrep
  ];
  text = ''
    export SBX_BWRAP="${bubblewrap}/bin/bwrap"
    ${builtins.readFile ./sbx.sh}
  '';
}
