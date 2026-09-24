# GALA flake.
#
#   * packages.<system>.gala / .default - the gala CLI, built from source;
#     the stdlib is transpiled by a downloaded release binary (see
#     nix/gala.nix)
#   * packages.<system>.gala-local        - escape hatch for grammar or
#     codegen work the release cannot handle yet: transpiles with
#     cmd/gala_bootstrap built from this tree
#   * overlays.default                   - adds pkgs.gala to nixpkgs
#   * devShells.default                  - Bazelisk, Go, JDK for this repo
#   * checks.<system>.smoke              - offline build-and-run smoke test
#
# Downstream flakes:
#
#   inputs.gala.url = "github:martianoff/gala";
#   ...
#   environment.systemPackages = [ gala.packages.${pkgs.system}.default ];
{
  description = "GALA - a functional programming language that transpiles to Go";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      packages = eachSystem (
        system: pkgs: {
          gala = pkgs.callPackage ./nix/gala.nix { };
          gala-local = pkgs.callPackage ./nix/gala.nix { useLocalBootstrap = true; };
          gala-stdlib = self.packages.${system}.gala.passthru.localTranspiled;
          default = self.packages.${system}.gala;
        }
      );

      # `pkgs.gala` for nixpkgs consumers.
      overlays.default = final: _prev: {
        gala = final.callPackage ./nix/gala.nix { };
      };

      devShells = eachSystem (
        _: pkgs: {
          default = pkgs.mkShell {
            packages = [
              # Does not ship a `bazel` command; add one so the documented
              # `bazel build //...` invocations work. Bazelisk honours the
              # .bazelversion pin (9.2.0). Bazelisk downloads a dynamically
              # linked Bazel: on NixOS it needs `nix-ld` (or an FHS wrapper),
              # while macOS and non-NixOS Linux run it as-is.
              (pkgs.writeShellScriptBin "bazel" ''
                exec ${pkgs.bazelisk}/bin/bazelisk "$@"
              '')
              pkgs.bazelisk
              pkgs.go
              pkgs.jdk21
              pkgs.git
            ];
            # The Bazel build reads GOROOT through --action_env so the
            # transpiler can use go/importer for type inference.
            shellHook = ''
              export GOROOT="$(go env GOROOT)"
            '';
          };
        }
      );

      checks = eachSystem (
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
      );

      formatter = eachSystem (_: pkgs: pkgs.nixfmt);
    };
}
