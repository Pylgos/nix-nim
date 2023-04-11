{ nim
, stdenv
, runCommand
, nimble
, lib
, git
, jq
, cacert
, breakpointHook
}:

{ src
, vendorHash ? lib.fakeHash
, pname
, nimbleFileName ? "${pname}.nimble"
, ...
} @ args:

let
  vendor = runCommand "vendor" {
    outputHashAlgo = null;
    outputHash = vendorHash;
    outputHashMode = "recursive";
    lockFile = src + "/nimble.lock";
    nimbleFile = src + "/${nimbleFileName}";
    nativeBuildInputs = [ git nimble nim ];
    GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [
      "GIT_PROXY_COMMAND" "NIX_GIT_SSL_CAINFO" "SOCKS_SERVER"
    ];
  } ''
    cp $nimbleFile ${pname}.nimble
    cp $lockFile nimble.lock
    nimble --nimbleDir:nimbledeps install --depsOnly
    mkdir -p $out
    cp -a nimbledeps/pkgs2 $out/pkgs2
  '';
in
stdenv.mkDerivation (args // {
  depsBuildBuild = [ nim ];
  nativeBuildInputs = [ nimble jq ];

  buildPhase = ''
    nimbledeps=/tmp/nimbledeps
    mkdir -p $nimbledeps/pkgs2
    for pkg in ${vendor}/pkgs2/*; do
      ln -s $pkg $nimbledeps/pkgs2
    done
    ls -l
    # ls -l $nimbledeps/pkgs2
    # nimble build --nimbleDir:$nimbledeps --nimcache:/tmp/nimcache
    nimble install --nimbleDir:$nimbledeps --verbose --nimcache:/tmp/nimcache

    for pkg in $nimbledeps/pkgs2/*; do
      if [[ ! -L $pkg ]]; then
        cp -a $pkg $out
      fi
    done

    for binName in $(cat $out/nimblemeta.json | jq -r '.metaData.binaries[]'); do
      mkdir -p $out/bin
      ln -s "$out/$binName" "$out/bin" 
    done
  '';
})