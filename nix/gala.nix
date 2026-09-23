# GALA, built from source with a pinned stage-0 compiler.
#
# Compiling the stdlib needs a working GALA transpiler, but building that
# transpiler from the working tree would recreate the dependency cycle. So the
# build splits into two stages:
#
#   Stage A (inputs from the pinned revision in MODULE.bazel; rebuilds only
#   when the pin is bumped)
#     pinnedAntlr      gala.g4 -> internal/parser/grammar/*.go
#     pinnedBootstrap  cmd/gala_bootstrap + cmd/stdlib_gen
#     pinnedStdlib     pinned bootstrap transpiles the pinned stdlib
#     pinnedGala       cmd/gala with the pinned stdlib embedded; exports GOCACHE
#
#   Stage B (local tree)
#     localAntlr      gala.g4 -> internal/parser/grammar/*.go
#     localTranspiled the pinned bootstrap transpiles the local stdlib
#     gala            cmd/gala with the local stdlib embedded; packs it with
#                     cmd/stdlib_gen built from local Go; GOCACHE seeded from
#                     pinnedGala so unchanged Go packages compile once
#
# Incrementality:
#   edit Go under internal/ or cmd/   -> gala rebuilds
#   edit a stdlib .gala file          -> localTranspiled + gala
#   edit gala.g4                      -> localAntlr + gala
#   bump the pin                      -> Stage A once, then localTranspiled + gala
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  fetchurl,
  go,
  jdk21,
  stdenv,
  # Escape hatch for grammar work the pinned compiler cannot parse: build the
  # bootstrap from the working tree instead of the pin.
  useLocalBootstrap ? false,
  # Vendor hashes. Defaults are the current master go.mod's hash; if the
  # pinned revision's go.mod differs, run `nix build` once and copy the
  # suggested hash. Keep them separate so a stale pin fails loudly.
  galaVendorHash ? "sha256-elG9Jqrh0Bug4xWgVVpsPZRR21TWtjeQD7jkffkix34=",
  bootstrapVendorHash ? "sha256-elG9Jqrh0Bug4xWgVVpsPZRR21TWtjeQD7jkffkix34=",
  version ? (
    let
      line = lib.findFirst (l: lib.hasPrefix "gala " l) "gala 0.0.0" (
        lib.splitString "\n" (builtins.readFile ../gala.mod)
      );
    in
    lib.removePrefix "gala " line
  ),
  repoFileset ? lib.fileset.unions (
    [
      # Module metadata. gala.mod is also the file `version` above is read
      # from, and the transpiler's module resolver looks it up relative to
      # the search path.
      ../gala.mod
      ../go.mod
      ../go.sum

      # Everything `go build ./cmd/...` compiles, plus the Bazel metadata and
      # ANTLR grammar the stdlib script reads.
      ../cmd
      ../internal
      ../galaerr
      ../docs/errors # errdocs.go embeds GALA-E*.md
    ]
    # Stdlib packages referenced by internal/stdlib/BUILD.bazel's
    # generate_embedded genrule: transpiled .gala sources, .gala files
    # embedded verbatim, and hand-written .go helpers.
    ++ map (pkg: ../. + "/${pkg}") [
      "collection_immutable"
      "collection_mutable"
      "concurrent"
      "crypto"
      "fs"
      "go_builtins"
      "go_interop"
      "io"
      "json"
      "lazy"
      "path"
      "regex"
      "resource"
      "std"
      "stream"
      "strings"
      "subprocess"
      "test"
      "time_utils"
      "validation"
      "yaml"
    ]
    # `go mod vendor` scans every main-module package, including these Go test
    # fixtures; dropping them would change the vendor tree and so break
    # vendorHash.
    ++ map (dir: lib.fileset.fileFilter (file: file.hasExt "go") (../. + "/${dir}")) [
      "bazel_test_fixtures"
      "examples"
    ]
  ),
}:

let
  repoRoot = ../.;

  stdlibPkgs = [
    "collection_immutable"
    "collection_mutable"
    "concurrent"
    "crypto"
    "fs"
    "go_builtins"
    "go_interop"
    "io"
    "json"
    "lazy"
    "path"
    "regex"
    "resource"
    "std"
    "stream"
    "strings"
    "subprocess"
    "test"
    "time_utils"
    "validation"
    "yaml"
  ];

  galaFileset = lib.fileset.intersection repoFileset (
    lib.fileset.fileFilter (file: file.hasExt "gala") repoRoot
  );

  # Go-only source for Go builds: .gala edits must not invalidate them.
  goSource = lib.fileset.toSource {
    root = repoRoot;
    fileset = lib.fileset.difference repoFileset galaFileset;
  };

  # Stdlib source tree for the transpile + stdlib_gen steps. Whole package
  # dirs so hand-written .go helpers and verbatim .gala sources are present;
  # the BUILD files are read by the stdlib script, and gala.mod/go.mod/go.sum
  # by the resolver.
  stdlibSource = lib.fileset.toSource {
    root = repoRoot;
    fileset = lib.fileset.unions (
      [
        (repoRoot + "/gala.mod")
        (repoRoot + "/go.mod")
        (repoRoot + "/go.sum")
        (repoRoot + "/internal/stdlib/BUILD.bazel")
      ]
      ++ map (p: repoRoot + "/${p}") stdlibPkgs
    );
  };

  # --- pin parsed from MODULE.bazel's marked block (single source of truth,
  # written only by tools/bootstrap/bump.sh) ---
  readFlat = path: lib.replaceStrings [ "\n" ] [ " " ] (builtins.readFile path);
  moduleText = readFlat (repoRoot + "/MODULE.bazel");
  mustMatch =
    re: text:
    let
      m = builtins.match re text;
    in
    if m == null then throw "MODULE.bazel: no match for ${re}" else builtins.head m;
  pinRepo = mustMatch ".*# repo: ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+).*" moduleText;
  pinRev = mustMatch ".*# rev: ([0-9a-f]{40}).*" moduleText;
  pinHash = mustMatch ".*# nix-hash: (sha256-[A-Za-z0-9+/=]+).*" moduleText;
  pinRepoSplit = lib.splitString "/" pinRepo;
  pinnedSource = fetchFromGitHub {
    owner = builtins.head pinRepoSplit;
    repo = lib.elemAt pinRepoSplit 1;
    rev = pinRev;
    hash = pinHash;
  };
  pinnedVersion = lib.removePrefix "gala " (
    lib.findFirst (l: lib.hasPrefix "gala " l) "gala 0.0.0" (
      lib.splitString "\n" (builtins.readFile "${pinnedSource}/gala.mod")
    )
  );

  # Keep in sync with MODULE.bazel's @antlr4_tool http_jar.
  antlrJar = fetchurl {
    url = "https://www.antlr.org/download/antlr-4.13.1-complete.jar";
    hash = "sha256-vBOpxXqN19UZaIghHl7eZXy2SjzpaGCGl+T2aCUahIc=";
  };

  mkAntlr =
    label: grammarFile:
    stdenv.mkDerivation {
      pname = "gala-antlr-${label}";
      inherit version;
      dontUnpack = true;
      dontConfigure = true;
      dontInstall = true;
      nativeBuildInputs = [ jdk21 ];
      buildPhase = ''
        runHook preBuild
        mkdir -p "$out/internal/parser/grammar" internal/parser/grammar
        # ANTLR requires the basename to equal the grammar name and mirrors
        # the input's relative path under -o, so stage a relative copy
        # (passing the store path directly would write flat into antlr/).
        cp ${grammarFile} internal/parser/grammar/gala.g4
        java -jar ${antlrJar} -Dlanguage=Go -package grammar \
          -o antlr internal/parser/grammar/gala.g4
        cp antlr/internal/parser/grammar/*.go "$out/internal/parser/grammar/"
        sed -i 's|github.com/antlr/antlr4/runtime/Go/antlr|github.com/antlr4-go/antlr/v4|g' \
          "$out"/internal/parser/grammar/*.go
        runHook postBuild
      '';
    };
  localAntlr = mkAntlr "local" (repoRoot + "/internal/parser/grammar/gala.g4");
  pinnedAntlr = mkAntlr "pinned" "${pinnedSource}/internal/parser/grammar/gala.g4";

  # GOFLAGS can't be passed to buildGoModule directly (it collides with the
  # env it computes), so pin it after the fact. -trimpath must be identical
  # in every build that shares GOCACHE entries or the cache misses.
  pinGoFlags =
    drv:
    drv.overrideAttrs (old: {
      env = old.env // {
        GOFLAGS = "-trimpath -mod=vendor";
      };
    });

  # The exported build cache references the Go SDK; the final build imports
  # it with the same flags, so both need allowGoReference.
  exportGoCache = ''
    mkdir -p "$out/go-cache"
    cp -r --reflink=auto "$GOCACHE"/. "$out/go-cache/"
  '';

  # --- Stage A: everything from the pinned revision ---
  pinnedBootstrap = pinGoFlags (buildGoModule {
    pname = "gala-bootstrap-pinned";
    inherit version;
    src = pinnedSource;
    vendorHash = bootstrapVendorHash;
    subPackages = [
      "cmd/gala_bootstrap"
      "cmd/stdlib_gen"
    ];
    allowGoReference = true;
    doCheck = false;

    # The dependency-fetching fixed-output derivation inherits preBuild and
    # postPatch, but must stay a plain `go mod vendor`.
    overrideModAttrs = _final: _prev: {
      preBuild = "";
      postPatch = "";
    };

    postPatch = ''
      cp ${pinnedAntlr}/internal/parser/grammar/*.go internal/parser/grammar/
    '';

    postInstall = exportGoCache;
  });

  # Same transpile step as localTranspiled, but over the pinned tree, so
  # pinnedGala embeds the stdlib exactly as the pinned compiler does.
  pinnedStdlib = mkTranspiled {
    name = "gala-stdlib-pinned";
    src = pinnedSource;
    transpiler = "${pinnedBootstrap}/bin/gala_bootstrap";
    transpilerEnv = "GOGC=300 GOMEMLIMIT=6GiB";
  };

  pinnedGala = pinGoFlags (buildGoModule {
    pname = "gala-pinned";
    version = pinnedVersion;
    src = pinnedSource;
    vendorHash = bootstrapVendorHash;
    subPackages = [ "cmd/gala" ];
    allowGoReference = true;
    doCheck = false;
    overrideModAttrs = _final: _prev: {
      preBuild = "";
      postPatch = "";
    };
    postPatch = ''
      cp ${pinnedAntlr}/internal/parser/grammar/*.go internal/parser/grammar/
    '';
    preBuild = ''
      ${pinnedBootstrap}/bin/stdlib_gen -output internal/stdlib/embedded_gen.go \
        ${pinnedStdlib}/files/*/*
    '';
    postInstall = exportGoCache;
    ldflags = [
      "-X martianoff/gala/cmd/gala/commands.Version=${pinnedVersion}"
    ];
  });

  # --- Stage B: the local tree ---

  # Escape hatch for grammar work the pin cannot parse.
  localBootstrap = pinGoFlags (buildGoModule {
    pname = "gala-bootstrap-local";
    inherit version;
    src = goSource;
    vendorHash = galaVendorHash;
    subPackages = [ "cmd/gala_bootstrap" ];
    doCheck = false;
    overrideModAttrs = _final: _prev: {
      preBuild = "";
      postPatch = "";
    };
    postPatch = ''
      cp ${localAntlr}/internal/parser/grammar/*.go internal/parser/grammar/
    '';
  });

  # The pinned bootstrap is within noise of the pinned full gala for the
  # stdlib transpile (see tools/bootstrap/README.md), and has no embedded
  # stdlib to unpack, so it is the default transpiler. pinnedGala stays in
  # the graph as the GOCACHE seed.
  localTranspiled = mkTranspiled {
    name = "gala-stdlib";
    src = stdlibSource;
    transpiler =
      if useLocalBootstrap then
        "${localBootstrap}/bin/gala_bootstrap"
      else
        "${pinnedBootstrap}/bin/gala_bootstrap";
    transpilerEnv = "GOGC=300 GOMEMLIMIT=6GiB";
  };

  # Reads internal/stdlib/BUILD.bazel's generate_embedded inputs exactly as
  # Bazel does and stages them under $out/files:
  #   - transpiled .gala targets as <name>.gen.go
  #   - verbatim .gala/.go inputs under their original names
  # The final `gala` build packs them with cmd/stdlib_gen; keeping the pack
  # step out of this derivation means a Go edit does not retranspile the
  # stdlib, and a stdlib edit does not rebuild any Go derivation.
  # `transpiler` must be a gala_bootstrap with batch mode (--inputs/--outputs).
  mkTranspiled =
    {
      name,
      src,
      transpiler,
      transpilerArgs ? "",
      transpilerEnv ? "",
    }:
    stdenv.mkDerivation {
      pname = name;
      inherit version src;
      nativeBuildInputs = [ go ];
      dontConfigure = true;
      dontInstall = true;
      buildPhase = ''
        runHook preBuild
        mkdir -p "$out/files" "$TMPDIR/transpiled"
        embeddedSrcs="$TMPDIR/embedded_srcs.txt"
        awk '/name = "generate_embedded"/,/outs = \["embedded_gen.go"\]/' \
          internal/stdlib/BUILD.bazel \
          | grep -o '"//[^"]*:[^"]*"' | tr -d '"' | sort -u > "$embeddedSrcs"

        batchInputs=()
        batchOutputs=()
        while IFS= read -r label; do
          pkg="''${label#//}"
          pkg="''${pkg%%:*}"
          file="''${label##*:}"
          case "$file" in
            *_go)
              stem="''${file%_go}"
              # Resolve the target to its src attribute so a renamed .gala
              # file is still transpiled from the right source.
              srcfile=$(awk -v name="\"$file\"" '
                $0 ~ ("name = " name) { found = 1; next }
                found && /src = "/ {
                  match($0, /src = "[^"]+"/)
                  print substr($0, RSTART + 7, RLENGTH - 8)
                  exit
                }' "$pkg/BUILD.bazel")
              [ -n "$srcfile" ] || srcfile="$stem.gala"
              mkdir -p "$TMPDIR/transpiled/$pkg"
              batchInputs+=("$pkg/$srcfile")
              batchOutputs+=("$TMPDIR/transpiled/$pkg/$stem.gen.go")
              ;;
            *)
              mkdir -p "$out/files/$pkg"
              cp "$pkg/$file" "$out/files/$pkg/$file"
              ;;
          esac
        done < "$embeddedSrcs"

        inList="$(IFS=,; echo "''${batchInputs[*]}")"
        outList="$(IFS=,; echo "''${batchOutputs[*]}")"
        echo "gala: transpiling ''${#batchInputs[@]} files"
        ${transpilerEnv} ${transpiler} ${transpilerArgs} \
          --inputs "$inList" --outputs "$outList" \
          --search "$PWD" --goroot="${go}/share/go"

        cp -r "$TMPDIR/transpiled/." "$out/files/"
        echo "gala: staged $(find "$out/files" -type f | wc -l) stdlib files"
        runHook postBuild
      '';
    };
in
let
  gala = pinGoFlags (buildGoModule {
    pname = "gala";
    src = goSource;
    inherit version;

    subPackages = [ "cmd/gala" ];

    vendorHash = galaVendorHash;

    # Must match pinnedGala's flags Go-cache-wise.
    allowGoReference = true;

    # The dependency-fetching fixed-output derivation inherits preBuild and
    # postPatch, but must not run the overlay below.
    overrideModAttrs = _final: _prev: {
      preBuild = "";
      postPatch = "";
    };

    ldflags = [
      "-X martianoff/gala/cmd/gala/commands.Version=${version}"
    ];

    # The upstream test suite is Bazel-driven (golden files, registered
    # toolchains, no-sandbox genrules); it is not runnable from a plain
    # `go test` sandbox. The flake's `checks` run a real build/run smoke
    # test against the installed binary instead.
    doCheck = false;

    # Overlay the staged outputs and warm the Go build cache from the pinned
    # build, so unchanged internal/... packages compile only once. The stdlib
    # is packed here rather than in localTranspiled so this derivation is the
    # only one that sees the Go source.
    preBuild = ''
      mkdir -p "$GOCACHE"
      cp -r --reflink=auto ${pinnedGala}/go-cache/. "$GOCACHE"/
      chmod -R u+w "$GOCACHE"
      cp ${localAntlr}/internal/parser/grammar/*.go internal/parser/grammar/
      go build -mod=vendor -o "$TMPDIR/stdlib_gen" ./cmd/stdlib_gen
      "$TMPDIR/stdlib_gen" -output internal/stdlib/embedded_gen.go \
        ${localTranspiled}/files/*/*
    '';

    meta = {
      description = "Functional programming language that transpiles to Go";
      homepage = "https://github.com/martianoff/gala";
      license = lib.licenses.asl20;
      mainProgram = "gala";
      platforms = lib.platforms.unix;
    };
  });
in
gala.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit
      pinnedGala
      pinnedBootstrap
      pinnedStdlib
      localBootstrap
      localTranspiled
      ;
  };
})
