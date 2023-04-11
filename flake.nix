{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    
    nim-stable-source = { url = "github:nim-lang/Nim/v1.6.12"; flake = false; };
    nim-devel-source = { url = "github:nim-lang/Nim/devel"; flake = false; };
    nim-bootstrap-source = { url = "https://github.com/nim-lang/nightlies/releases/download/2023-04-11-devel-4d683fc689e124cfb0ba3ddd6e68d3e3e9b9b343/nim-1.9.3-linux_x64.tar.xz"; flake = false; };
    nimble-latest-source = { url = "github:nim-lang/nimble"; flake = false; };
    nimble-source = { url = "github:nim-lang/nimble/v0.14.2"; flake = false; };
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
