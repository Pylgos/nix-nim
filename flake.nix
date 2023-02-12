{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    
    nim-stable-source = { url = "github:nim-lang/Nim/v1.6.10"; flake = false; };
    nim-devel-source = { url = "github:nim-lang/Nim/devel"; flake = false; };
    nim-bootstrap-source = { url = "https://nim-lang.org/download/nim-1.6.10-linux_x64.tar.xz"; flake = false; };
    nimble-latest-source = { url = "github:nim-lang/nimble"; flake = false; };
    nimble-source = { url = "github:nim-lang/nimble/v0.14.1"; flake = false; };
  };

  outputs = { flake-utils, ... } @ inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        nixpkgs = inputs.nixpkgs.legacyPackages.${system};
      in
      {
        packages = import ./nim { inherit inputs nixpkgs; };
      }
    );
}
