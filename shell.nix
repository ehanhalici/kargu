# shell.nix
{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    tlaps
    tlaplus
  ];

  shellHook = ''
    echo "Insider Notification System dev environment loaded!"
  '';
}
