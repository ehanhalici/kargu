# shell.nix --- tools for checking Kargu's TLA+ specification.
#
#   nix-shell --run 'proof/run_tlc.sh'              # exhaustive scan
#   nix-shell --run 'proof/run_tlc.sh --simulate'   # quick smoke test
{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    tlaplus   # TLC model checker: `tlc'
    rustc
    rust-analyzer
    rustfmt
    clippy
    cargo
    pkg-config
    tree
    rustup
    libx11
    libxcursor
    libxrandr
    libxi
    libxkbcommon
    glib
    libGL
  ];

  shellHook = ''
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [
      libGL
      libx11
      libxcursor
      libxrandr
      libxi
      libxkbcommon
      glib
    ])}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    echo "Kargu proof shell: run proof/run_tlc.sh"
  '';
}
