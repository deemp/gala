package lsp_test

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// A package-level binding is a documented symbol of its package, but nothing
// read the doc comment sitting above it: hover rendered a bare `name type` from
// the type channel, which knows types and nothing else. The type was wrong too
// — `15 * time.Second` was typed from the `15`, because arithmetic took the
// left operand's type instead of the typed operand's.
const packageValSrc = `package main

import "time"

// shutdownTimeout bounds how long a drain waits for in-flight connections
// before force-closing them.
//
// 15s is long enough for a command in flight to finish and short enough that a
// deploy is not held up by an idle client.
val shutdownTimeout = 15 * time.Second

// retries is how many times a failed dial is attempted.
var retries = 3

// label names this node in logs.
val label = "kv-1"

func Run() {
    // A local of the same name shadows the package binding.
    val label = 42
    Println(label, shutdownTimeout, retries)
}
`

func TestHoverPackageLevelBinding(t *testing.T) {
	h := newHarness(t)
	uri := openFileOnDisk(t, h, packageValSrc)
	settle(t, h, uri, packageValSrc, "func Run()", "Run")

	for _, tt := range []struct {
		name          string
		anchor, word  string
		want, notWant []string
	}{
		{
			name:   "declaration carries its doc, mutability and type",
			anchor: "val shutdownTimeout = ", word: "shutdownTimeout",
			want: []string{"val shutdownTimeout", "Duration", "bounds how long a drain waits", "deploy is not held up"},
			// `15 * time.Second` is a Duration; typing it from the `15` made it int.
			notWant: []string{"shutdownTimeout int"},
		},
		{
			name:   "use site carries the same doc",
			anchor: "Println(label, shutdownTimeout", word: "shutdownTimeout",
			want:   []string{"val shutdownTimeout", "bounds how long a drain waits"},
		},
		{
			name:   "a var reads as var, not val",
			anchor: "var retries = 3", word: "retries",
			want:    []string{"var retries", "how many times a failed dial"},
			notWant: []string{"val retries"},
		},
		{
			name:   "literal initializer still resolves its type",
			anchor: `val label = "kv-1"`, word: "label",
			want: []string{"val label", "string", "names this node in logs"},
		},
		{
			name:   "a local of the same name is not the package binding",
			anchor: "    val label = 42", word: "label",
			want:    []string{"label"},
			notWant: []string{"names this node in logs"},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			assertHover(t, hoverAt(t, h, uri, packageValSrc, tt.anchor, tt.word), tt.want, tt.notWant)
		})
	}
}

// The recorded position makes go-to-definition exact, where the text scan it
// used to fall through to matches the first `val name` line in the file — a
// local in some earlier function body as readily as the binding itself.
func TestDefinitionPackageLevelBinding(t *testing.T) {
	h := newHarness(t)
	uri := openFileOnDisk(t, h, packageValSrc)
	settle(t, h, uri, packageValSrc, "func Run()", "Run")

	line, col := locate(t, packageValSrc, "Println(label, shutdownTimeout", "shutdownTimeout")
	locs, err := h.Definition(uri, line, col)
	if err != nil {
		t.Fatalf("definition: %v", err)
	}
	if len(locs) == 0 {
		t.Fatal("no definition found for a package-level binding")
	}
	wantLine, _ := locate(t, packageValSrc, "val shutdownTimeout = ", "shutdownTimeout")
	if locs[0].Range.Start.Line != wantLine {
		t.Errorf("expected the declaration on line %d, got line %d", wantLine, locs[0].Range.Start.Line)
	}
}

// A binding declared in a sibling file of the same package resolves too — the
// text scan of the open document could never see it.
func TestDefinitionPackageLevelBindingAcrossFiles(t *testing.T) {
	dir := createTestProject(t, []testProjectFile{
		{Name: "config.gala", Src: "package app\n\n// maxConns caps concurrent connections.\nval maxConns = 64\n"},
		{Name: "server.gala", Src: "package app\n\nfunc Run() {\n    Println(maxConns)\n}\n"},
	})
	h := newHarness(t)
	openProjectFile(t, h, dir, "config.gala")
	uri := openProjectFile(t, h, dir, "server.gala")
	src := "package app\n\nfunc Run() {\n    Println(maxConns)\n}\n"
	settle(t, h, uri, src, "func Run()", "Run")

	line, col := locate(t, src, "Println(maxConns)", "maxConns")
	locs, err := h.Definition(uri, line, col)
	if err != nil {
		t.Fatalf("definition: %v", err)
	}
	if len(locs) == 0 {
		t.Fatal("no definition found for a sibling file's package binding")
	}
	if got := strings.ToLower(filepath.ToSlash(string(locs[0].URI))); !strings.HasSuffix(got, "config.gala") {
		t.Errorf("expected the sibling declaring it, got %s", locs[0].URI)
	}
}

// Completion offers the package's own bindings, with their doc as the
// resolvable documentation.
func TestCompletionOffersPackageLevelBindings(t *testing.T) {
	h := newHarness(t)
	uri := openFileOnDisk(t, h, packageValSrc)
	settle(t, h, uri, packageValSrc, "func Run()", "Run")

	line, _ := locate(t, packageValSrc, "    Println(label, shutdownTimeout", "Println")
	list, err := h.Completion(uri, line, 4)
	if err != nil {
		t.Fatalf("completion: %v", err)
	}
	for _, want := range []string{"shutdownTimeout", "retries"} {
		if !slices.Contains(labelSlice(list), want) {
			t.Errorf("completion missing %q, got %v", want, labelSlice(list))
		}
	}
}

// A binding declared BELOW a function still hovers as itself. Scope here is
// established by the recorded declaration position, not by scanning backwards
// for a `func` line — that scan does not track where a body ends, so it reads
// any later top-level declaration as a local of the function above it.
func TestHoverPackageLevelBindingDeclaredAfterAFunction(t *testing.T) {
	const src = `package main

func Run() {
    val label = 42
    Println(label)
}

// label names this node in logs.
val label = "kv-1"
`
	h := newHarness(t)
	uri := openFileOnDisk(t, h, src)
	settle(t, h, uri, src, "func Run()", "Run")

	assertHover(t, hoverAt(t, h, uri, src, `val label = "kv-1"`, "label"),
		[]string{"val label", "names this node in logs"}, nil)
}
