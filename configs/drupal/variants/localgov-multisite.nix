# Compatibility shim — imports dlg-ms.nix so consumers that still reference
# the old path continue to work. Update your devenv.nix to import dlg-ms.nix.
{ ... }:
{
  imports = [ ./dlg-ms.nix ];
}
