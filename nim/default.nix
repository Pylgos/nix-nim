{ inputs
, nixpkgs
}:
let
  devel = nixpkgs.callPackages ./nim.nix { 
    source = inputs.nim-devel-source;
    bootstrap-source = inputs.nim-bootstrap-source;
    nimble-source = inputs.nimble-latest-source;
    inherit (devel) nim-bootstrap nimble nim-unwrapped nim-wrapped;
  };
in
rec {
  nim-devel = devel.nim-wrapped;
  nim-devel-clang = devel.nim-wrapped.override (old: { stdenv = nixpkgs.clangStdenv; });
}