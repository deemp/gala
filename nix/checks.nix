{ self, eachSystem }:
eachSystem (
  system: pkgs: {
    package = self.packages.${system}.gala;
    gala-local = self.packages.${system}.gala-local;

    # End-to-end smoke test: scaffold a project, build it with the
    # embedded stdlib, and run it. Works offline (GOPROXY=off).
    smoke =
      let
        gala = self.packages.${system}.gala;
      in
      pkgs.runCommand "gala-smoke-test" { nativeBuildInputs = [ pkgs.go ]; } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" project
        cd project

        ${gala}/bin/gala mod init example.com/smoke > /dev/null

        cat > main.gala <<'GALA'
        package main

        func main() {
          Println(s"hello ''${1 + 1}")
        }
        GALA

        ${gala}/bin/gala version | grep -F ${gala.version}
        GOPROXY=off ${gala}/bin/gala run | grep -F 'hello 2'
        touch "$out"
      '';

    stdlib-source-priority =
      let
        gala = self.packages.${system}.gala;
        releaseGalaBin = gala.passthru.releaseGalaBin;
        stdlib = self.packages.${system}.gala-stdlib;
      in
      pkgs.runCommand "gala-stdlib-source-priority-test" { nativeBuildInputs = [ pkgs.go ]; } ''
        export HOME="$TMPDIR/home"
        export GALA_HOME="$TMPDIR/gala-home"
        export GOCACHE="$TMPDIR/go-cache"
        export GOMODCACHE="$TMPDIR/go-mod-cache"
        mkdir -p "$HOME" "$GALA_HOME" "$GOCACHE" "$GOMODCACHE" project
        cd project

        cp -R ${stdlib}/files/lazy "$PWD/lazy"
        chmod -R u+w "$PWD/lazy"

        cat > gala.mod <<'GALA_MOD'
        module martianoff/gala

        gala ${gala.version}
        GALA_MOD

        cat > lazy/nix_local_sentinel.gala <<'GALA'
        package lazy

        func NixLocalStdlibSentinel() string {
          return "local"
        }
        GALA

        cat > main.gala <<'GALA'
        package main

        import "martianoff/gala/lazy"

        func main() {
          Println(lazy.NixLocalStdlibSentinel())
        }
        GALA

        GOPROXY=off ${releaseGalaBin}/bin/gala transpile-package \
          --inputs "$PWD/main.gala" \
          --outputs "$TMPDIR/main.gen.go" \
          --search "$PWD" \
          --goroot="${pkgs.go}/share/go"

        test -d "$GALA_HOME/stdlib/v${gala.version}/lazy"
        test ! -e "$GALA_HOME/stdlib/v${gala.version}/lazy/nix_local_sentinel.gala"
        grep -F 'NixLocalStdlibSentinel' "$TMPDIR/main.gen.go"
        touch "$out"
      '';
  }
)
