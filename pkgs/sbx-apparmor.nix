# pkgs/sbx-apparmor.nix
#
# AppArmor helper for the sbx bubblewrap sandbox. Keeps the host-side, one
# time setup off the critical path: `sbx-apparmor install` writes the
# profile for the exact bwrap store path baked below.
#
# sudo and /usr/sbin/apparmor_parser come from the host on purpose:
# setuid sudo cannot come from the Nix store, and the parser must match
# the host kernel's AppArmor ABI.
{
  pkgs,
  bubblewrap,
}:
pkgs.writeShellApplication {
  name = "sbx-apparmor";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
  ];
  text = ''
    export SBX_BWRAP="${bubblewrap}/bin/bwrap"
    ${builtins.readFile ./sbx-apparmor.sh}
  '';
}
