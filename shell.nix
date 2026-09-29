# shell.nix --- tools for checking Kargu's TLA+ specification.
#
#   nix-shell --run 'proof/run_tlc.sh'              # exhaustive scan
#   nix-shell --run 'proof/run_tlc.sh --simulate'   # quick smoke test
{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    tlaplus   # TLC model checker: `tlc'
  ];

  shellHook = ''
    echo "Kargu proof shell: run proof/run_tlc.sh"
  '';
}
