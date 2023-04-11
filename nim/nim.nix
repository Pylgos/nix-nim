{ source
, nimble-source
, bootstrap-source

, nim-bootstrap
, nim-unwrapped
, nimble
, nim-wrapped

, lib
, boehmgc
, openssl
, pcre
, readline
, sqlite
, targetPlatform
, makeWrapper
, stdenv
, buildPackages
, callPackage
}:
let
  parseCpu = platform:
    with platform;
    # Derive a Nim CPU identifier
    if isAarch32 then
      "arm"
    else if isAarch64 then
      "arm64"
    else if isAlpha then
      "alpha"
    else if isAvr then
      "avr"
    else if isMips && is32bit then
      "mips"
    else if isMips && is64bit then
      "mips64"
    else if isMsp430 then
      "msp430"
    else if isPower && is32bit then
      "powerpc"
    else if isPower && is64bit then
      "powerpc64"
    else if isRiscV && is64bit then
      "riscv64"
    else if isSparc then
      "sparc"
    else if isx86_32 then
      "i386"
    else if isx86_64 then
      "amd64"
    else
      abort "no Nim CPU support known for ${config}";

  parseOs = platform:
    with platform;
    # Derive a Nim OS identifier
    if isAndroid then
      "Android"
    else if isDarwin then
      "MacOSX"
    else if isFreeBSD then
      "FreeBSD"
    else if isGenode then
      "Genode"
    else if isLinux then
      "Linux"
    else if isNetBSD then
      "NetBSD"
    else if isNone then
      "Standalone"
    else if isOpenBSD then
      "OpenBSD"
    else if isWindows then
      "Windows"
    else if isiOS then
      "iOS"
    else
      abort "no Nim OS support known for ${config}";

  parsePlatform = p: {
    cpu = parseCpu p;
    os = parseOs p;
  };

  parseNimVersion = src: src.shortRev;
  parseNimbleVersion = src: src.shortRev;

  nimHost = parsePlatform stdenv.hostPlatform;
  nimTarget = parsePlatform stdenv.targetPlatform;
in
{
  nim-bootstrap = stdenv.mkDerivation {
    name = "nim-bootstrap";
    src = bootstrap-source;

    installPhase = ''
      mkdir -p $out/bin
      cp bin/nim $out/bin/nim
    '';
  };

  nim-unwrapped =
    stdenv.mkDerivation {
      pname = "nim-unwrapped";
      version = parseNimVersion source;
      strictDeps = true;

      src = source;
      buildInputs = [ boehmgc openssl pcre readline sqlite ];

      patches = [
        ./nixbuild.patch
      ];

      configurePhase = ''
        runHook preConfigure
        echo 'define:nixbuild' >> config/nim.cfg
        runHook postConfigure
      '';

      kochArgs = [
        "--cpu:${nimHost.cpu}"
        "--os:${nimHost.os}"
        "-d:release"
        "-d:useGnuReadline"
      ] ++ lib.optional (stdenv.isDarwin || stdenv.isLinux) "-d:nativeStacktrace";

      buildPhase = ''
        runHook preBuild
        local HOME=$TMPDIR
        cp ${nim-bootstrap}/bin/nim bin/nim
        ./bin/nim c --parallelBuild:$NIX_BUILD_CORES koch
        ./koch boot $kochArgs --parallelBuild:$NIX_BUILD_CORES
        ./koch toolsNoExternal $kochArgs --parallelBuild:$NIX_BUILD_CORES
        ./koch distrohelper
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out/nim
        cp -a {bin,compiler,config,lib,nim.nimble} $out/nim
        rm $out/nim/bin/{empty.txt,nim-gdb.bat}
        ln -s $out/nim/bin $out/bin
        runHook postInstall
      '';

      meta = with lib; {
        description = "Statically typed, imperative programming language";
        homepage = "https://nim-lang.org/";
        license = licenses.mit;
        mainProgram = "nim";
      };
    };

  nim-wrapped = stdenv.mkDerivation {
    name = "${targetPlatform.config}-nim-wrapper-${nim-unwrapped.version}";
    inherit (nim-unwrapped) version;
    preferLocalBuild = true;
    strictDeps = true;

    nativeBuildInputs = [ makeWrapper ];

    unpackPhase = ''
      runHook preUnpack
      cp -r ${nim-bootstrap.src}/config /build/config
      cd /build
      chmod +rw -R /build/config
      runHook postUnpack
    '';

    dontConfigure = true;

    buildPhase =
      # Configure the Nim compiler to use $CC and $CXX as backends
      # The compiler is configured by two configuration files, each with
      # a different DSL. The order of evaluation matters and that order
      # is not documented, so duplicate the configuration across both files.
      ''
        runHook preBuild
        cat >> config/config.nims << WTF
        switch("os", "${nimTarget.os}")
        switch("cpu", "${nimTarget.cpu}")
        switch("define", "nixbuild")
        # Configure the compiler using the $CC set by Nix at build time
        import strutils
        let cc = getEnv"CC"
        if cc.contains("gcc"):
          switch("cc", "gcc")
        elif cc.contains("clang"):
          switch("cc", "clang")
        WTF
      '';

    wrapperArgs = lib.optionals (!(stdenv.isDarwin && stdenv.isAarch64)) [
      "--prefix PATH : ${lib.makeBinPath [ buildPackages.gdb ]}:${placeholder "out"}/bin"
      # Used by nim-gdb

      "--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ openssl pcre ]}"
      # These libraries may be referred to by the standard library.
      # This is broken for cross-compilation because the package
      # set will be shifted back by nativeBuildInputs.

      # "--set NIM_CONFIG_PATH ${placeholder "out"}/etc/nim"
      # Use the custom configuration

      ''--set NIX_HARDENING_ENABLE "''${NIX_HARDENING_ENABLE/fortify}"''
      # Fortify hardening appends -O2 to gcc flags which is unwanted for unoptimized nim builds.
    ];

    installPhase =
      let
        config = targetPlatform.config;
      in
      ''
        runHook preInstall

        mkdir -p $out/nim
        cp -r config $out/nim/config

        ln -s ${nim-unwrapped}/nim/compiler $out/nim/compiler
        ln -s ${nim-unwrapped}/nim/lib $out/nim/lib
        ln -s ${nim-unwrapped}/nim/nim.nimble $out/nim/nim.nimble
        ln -s $out/nim/bin $out/bin

        cp -a ${nim-unwrapped}/nim/bin $out/nim/bin
        chmod +w $out/nim/bin

        binpath_list=$(echo $out/nim/bin/nim?*)
        for binpath in $binpath_list; do
          local binname=$(basename $binpath)
          wrapProgram $binpath $wrapperArgs
          ln -s $binpath $out/nim/bin/${config}-$binname
        done

        wrapProgram $out/nim/bin/nim \
          --set-default CC $(command -v $CC) \
          --set-default CXX $(command -v $CXX) \
          $wrapperArgs
        ln -s $out/nim/bin/nim $out/nim/bin/${config}-nim 

        wrapProgram $out/nim/bin/testament $wrapperArgs
        ln -s $out/nim/bin/testament $out/nim/bin/${config}-testament 

        makeWrapper \
          ${nimble}/bin/nimble $out/nim/bin/nimble \
          --suffix PATH : $out/bin
        ln -s $out/nim/bin/nimble $out/nim/bin/${config}-nimble

        runHook postInstall
      '';

    passthru = {
      inherit nim-unwrapped nimble;
      buildNimblePackage = callPackage ./build-nimble-package.nix { nim = nim-wrapped; inherit nimble; };
    };

    meta = nim-unwrapped.meta // {
      description = nim-unwrapped.meta.description
        + " (${targetPlatform.config} wrapper)";
      platforms = with lib.platforms; unix ++ genode;
      mainProgram = "nim";
    };
  };

  nimble = stdenv.mkDerivation {
    pname = "nimble";
    version = parseNimbleVersion nimble-source;
    src = nimble-source;
    strictDeps = true;

    depsBuildBuild = [ nim-unwrapped ];
    buildInputs = [ openssl ];

    nimFlags = [ "--cpu:${nimHost.cpu}" "--os:${nimHost.os}" "-d:release" ];

    buildPhase = ''
      runHook preBuild
      HOME=$NIX_BUILD_TOP nim c $nimFlags src/nimble
      runHook postBuild
    '';

    installPhase = ''
      runHook preBuild
      install -Dt $out/bin src/nimble
      runHook postBuild
    '';

    meta = with lib; {
      description = "Package manager for the Nim programming language";
      homepage = "https://github.com/nim-lang/nimble";
      license = licenses.bsd3;
      mainProgram = "nimble";
    };
  };
}
