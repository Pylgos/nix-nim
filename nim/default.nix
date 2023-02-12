{ inputs
, nixpkgs
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

  parseNimVersion = src: "idk";
  parseNimbleVersion = src: "idk";

  nimHost = parsePlatform nixpkgs.stdenv.hostPlatform;
  nimTarget = parsePlatform nixpkgs.stdenv.targetPlatform;

  nim-bootstrap = nixpkgs.stdenv.mkDerivation {
    pname = "nim-bootstrap";
    version = "1.6.10";
    src = inputs.nim-bootstrap-source;

    installPhase = ''
      mkdir -p $out/bin
      cp bin/nim $out/bin/nim
    '';
  };

  buildNim = { nim-src, nimble-src }:
    let
      nim-built = nixpkgs.stdenv.mkDerivation {
        pname = "nim-raw";
        version = parseNimVersion nim-src;
        strictDeps = true;

        src = nim-src;

        buildInputs = with nixpkgs; [ boehmgc openssl pcre readline sqlite ];

        dontFixup = true;

        patches = [
          ./NIM_CONFIG_DIR.patch
          # Override compiler configuration via an environmental variable
          ./nixbuild.patch
          # Load libraries at runtime by absolute path
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
        ] ++ nixpkgs.lib.optional (nixpkgs.stdenv.isDarwin || nixpkgs.stdenv.isLinux) "-d:nativeStacktrace";

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
          cp -a . $out
          runHook postInstall
        '';
      };
    in
    rec {
      nim-unwrapped =
        nixpkgs.stdenv.mkDerivation {
          pname = "nim-unwrapped";
          inherit (nim-built) version;
          strictDeps = true;

          src = nim-built;

          buildInputs = with nixpkgs; [ boehmgc openssl pcre readline sqlite ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out/nim
            cp -a {bin,compiler,config,lib,nim.nimble} $out/nim
            rm $out/nim/bin/{empty.txt,nim-gdb.bat}
            ln -s $out/nim/bin $out/bin
            runHook postInstall
          '';

          meta = with nixpkgs.lib; {
            description = "Statically typed, imperative programming language";
            homepage = "https://nim-lang.org/";
            license = licenses.mit;
            mainProgram = "nim";
          };
        };

      nim-wrapped = nixpkgs.stdenv.mkDerivation {
        name = "${nixpkgs.targetPlatform.config}-nim-wrapper-${nim-unwrapped.version}";
        inherit (nim-unwrapped) version;
        preferLocalBuild = true;
        strictDeps = true;

        nativeBuildInputs = with nixpkgs; [ makeWrapper ];

        patches = [
          ./nim.cfg.patch
          # Remove configurations that clash with ours
        ];

        unpackPhase = ''
          runHook preUnpack
          ls ${nim-bootstrap.src}
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
            mv config/nim.cfg config/nim.cfg.old
            cat > config/nim.cfg << WTF
            os = "${nimTarget.os}"
            cpu =  "${nimTarget.cpu}"
            define:"nixbuild"
            WTF
            cat >> config/nim.cfg < config/nim.cfg.old
            rm config/nim.cfg.old
            cat >> config/nim.cfg << WTF
            clang.cpp.exe %= "\$CXX"
            clang.cpp.linkerexe %= "\$CXX"
            clang.exe %= "\$CC"
            clang.linkerexe %= "\$CC"
            gcc.cpp.exe %= "\$CXX"
            gcc.cpp.linkerexe %= "\$CXX"
            gcc.exe %= "\$CC"
            gcc.linkerexe %= "\$CC"
            WTF
            runHook postBuild
          '';

        wrapperArgs = [
          "--prefix PATH : ${nixpkgs.lib.makeBinPath [ nixpkgs.buildPackages.gdb ]}:${
          placeholder "out"
        }/bin"
          # Used by nim-gdb

          "--prefix LD_LIBRARY_PATH : ${with nixpkgs; lib.makeLibraryPath [ openssl pcre ]}"
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
            config = nixpkgs.targetPlatform.config;
          in
          ''
            runHook preInstall

            mkdir -p $out/nim
            cp -r config $out/nim/config
            ln -s ${nim-unwrapped}/nim/compiler $out/nim/compiler
            ln -s ${nim-unwrapped}/nim/lib $out/nim/lib
            ln -s ${nim-unwrapped}/nim/nim.nimble $out/nim/nim.nimble
            ln -s $out/nim/bin $out/bin

            for binpath in ${nim-unwrapped}/nim/bin/nim?*; do
              local binname=`basename $binpath`
              makeWrapper \
                $binpath $out/nim/bin/${config}-$binname \
                $wrapperArgs
              ln -s $out/nim/bin/${config}-$binname $out/nim/bin/$binname
            done

            makeWrapper \
              ${nim-unwrapped}/nim/bin/nim $out/nim/bin/${config}-nim \
              --set-default CC $(command -v $CC) \
              --set-default CXX $(command -v $CXX) \
              $wrapperArgs
            
            ln -s $out/nim/bin/${config}-nim $out/nim/bin/nim

            makeWrapper \
              ${nim-unwrapped}/nim/bin/testament $out/nim/bin/${config}-testament \
              $wrapperArgs
            ln -s $out/nim/bin/${config}-testament $out/nim/bin/testament

            makeWrapper \
              ${nimble}/bin/nimble $out/nim/bin/${config}-nimble \
              --suffix PATH : $out/bin
            ln -s $out/nim/bin/${config}-nimble $out/nim/bin/nimble

            runHook postInstall
          '';

        passthru = {
          inherit nim-unwrapped nimble;
        };

        meta = nim-unwrapped.meta // {
          description = nim-unwrapped.meta.description
            + " (${nixpkgs.targetPlatform.config} wrapper)";
          platforms = with nixpkgs.lib.platforms; unix ++ genode;
          mainProgram = "nim";
        };
      };

      nimble = nixpkgs.stdenv.mkDerivation {
        pname = "nimble";
        version = parseNimbleVersion nimble-src;
        src = nimble-src;
        strictDeps = true;

        depsBuildBuild = [ nim-unwrapped ];
        buildInputs = with nixpkgs; [ openssl ];

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

        meta = with nixpkgs.lib; {
          description = "Package manager for the Nim programming language";
          homepage = "https://github.com/nim-lang/nimble";
          license = licenses.bsd3;
          mainProgram = "nimble";
        };
      };
    };

  stable = buildNim {
    nim-src = inputs.nim-stable-source;
    nimble-src = inputs.nimble-source;
  };

  devel = buildNim {
    nim-src = inputs.nim-devel-source;
    nimble-src = inputs.nimble-latest-source;
  };
in
rec {
  nim-stable = stable.nim-wrapped;
  nim-stable-unwrapped = stable.nim-unwrapped;
  nim-stable-nimble = stable.nimble-unwrapped;

  nim-devel = devel.nim-wrapped;
  nim-devel-unwrapped = devel.nim-unwrapped;
  nim-devel-nimble = devel.nimble-unwrapped;
}
