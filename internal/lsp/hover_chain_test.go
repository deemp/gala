package lsp_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/owenrumney/go-lsp/lsp"
	"github.com/owenrumney/go-lsp/servertest"
)

// A fluent builder whose chain starts at an imported package's function —
// `pkg.New().WithX(...).WithY(...)` — is the shape every GALA server, client and
// config API is written in. The chain head is a package qualifier, not a value,
// so the receiver resolver hands the chain walker a package marker rather than a
// type name; answering that with "" dropped hover, completion and signature help
// for every method after the first call.
//
// The axis these fixtures own is CROSS-PACKAGE resolution; server_test.go's
// TestCompletion_LongBuilderChain covers same-package chains.
const chainServerSrc = `package srv

// Conn is one accepted connection.
type Conn struct {
    val id int
}

// Server accepts connections until it is asked to stop.
type Server struct {
    val name string
    val timeout int
}

// WithName names the server for logs and metrics.
func (s Server) WithName(name string) Server = Server(name = name, timeout = s.timeout)

// WithTimeout bounds how long a graceful shutdown may take.
func (s Server) WithTimeout(timeout int) Server = Server(name = s.name, timeout = timeout)

// WithPort binds the listener to a port.
func (s Server) WithPort(port int) Server = s

// WithBasePath prefixes every route the server serves.
func (s Server) WithBasePath(prefix string) Server = s

// WithDebug turns on verbose request logging.
func (s Server) WithDebug(enabled bool) Server = s

// WithBanner controls whether the startup banner is printed.
func (s Server) WithBanner(enabled bool) Server = s

// WithMaxConns caps how many connections are served at once.
func (s Server) WithMaxConns(limit int) Server = s

// ServeTCPOn binds addr and serves it until the process is asked to stop.
func (s Server) ServeTCPOn(addr string, handler func(Conn)) Try[bool] = Success(true)

// NewServer builds an unconfigured server.
func NewServer() Server = Server(name = "", timeout = 0)
`

// The chain as it is actually written in gala-kv: eight links deep, a lambda in
// the final call's argument list, and the whole expression consumed by a
// `match`. Every link is resolved by walking the entire prefix back to the
// package qualifier, so the depth is not cosmetic — a resolver that gives up
// part-way answers the later links with silence or with the wrong symbol.
//
// Decoy makes the assertions mean something: a bare-name search over the type
// table finds its WithName first as often as not, so a chain that is not really
// resolved shows up as the decoy's doc rather than as silence.
const chainMainSrc = `package main

import "github.com/example/kv/internal/srv"

type Decoy struct {
    val id int
}

// WithName on Decoy must never answer for the builder's chain.
func (d Decoy) WithName(label string) Decoy = d

func handle(c srv.Conn) {
    Println(c.id)
}

func Run() {
    srv.NewServer().
        WithPort(8080).
        WithName("gala-kv").
        WithBasePath("/api").
        WithDebug(true).
        WithBanner(false).
        WithTimeout(5).
        WithMaxConns(64).
        ServeTCPOn(":8080", (c) => handle(c)) match {
            case Success(_) => {}
            case Failure(e) => Println(e.Error())
        }
}
`

// openChainProject builds a two-package project whose main file is mainSrc, and
// waits for the import to be analyzed.
func openChainProject(t *testing.T, mainSrc string) (*servertest.Harness, lsp.DocumentURI) {
	t.Helper()
	root := createTestProject(t, []testProjectFile{
		{Name: "gala.mod", Src: "module github.com/example/kv\n\ngala 0.76.0\n"},
		{Name: "internal/srv/server.gala", Src: chainServerSrc},
		{Name: "app/main.gala", Src: mainSrc},
	})
	h, handler := newHarnessWithHandler(t)
	initializeAtRoot(t, handler, root)
	uri := openProjectFile(t, h, root, "app/main.gala")
	settle(t, h, uri, mainSrc, "srv.NewServer()", "NewServer")
	return h, uri
}

// Every editor feature that answers for a chain rooted in an imported function
// resolves it the same way, so all four are asserted against one project: hover
// on every link, go-to-definition, completion and signature help.
//
// The dot that selects each method sits at the end of the PREVIOUS line, which
// is how these builders are formatted in practice.
func TestChainFromImportedConstructor(t *testing.T) {
	h, uri := openChainProject(t, chainMainSrc)

	t.Run("hover on the constructor at the chain head", func(t *testing.T) {
		got := hoverAt(t, h, uri, chainMainSrc, "srv.NewServer()", "NewServer")
		assertHover(t, got, []string{"NewServer", "builds an unconfigured server"}, nil)
	})

	// Every link, including the one whose arguments contain a lambda and whose
	// result is matched on.
	t.Run("hover on every link", func(t *testing.T) {
		for _, tt := range []struct {
			anchor, word  string
			want, notWant []string
		}{
			{anchor: "WithPort(8080)", word: "WithPort",
				want: []string{"port int", "binds the listener to a port"}},
			{anchor: `WithName("gala-kv")`, word: "WithName",
				want: []string{"name string", "names the server for logs"},
				// The decoy's own WithName, which a bare-name search finds.
				notWant: []string{"Decoy", "label"}},
			{anchor: `WithBasePath("/api")`, word: "WithBasePath",
				want: []string{"prefix string", "prefixes every route"}},
			{anchor: "WithDebug(true)", word: "WithDebug",
				want: []string{"enabled bool", "verbose request logging"}},
			{anchor: "WithBanner(false)", word: "WithBanner",
				want: []string{"enabled bool", "startup banner is printed"}},
			{anchor: "WithTimeout(5)", word: "WithTimeout",
				want: []string{"timeout int", "graceful shutdown"}},
			{anchor: "WithMaxConns(64)", word: "WithMaxConns",
				want: []string{"limit int", "served at once"}},
			{anchor: `ServeTCPOn(":8080"`, word: "ServeTCPOn",
				want: []string{"addr string", "handler func(srv.Conn)", "binds addr and serves"}},
		} {
			t.Run(tt.word, func(t *testing.T) {
				got := hoverAt(t, h, uri, chainMainSrc, tt.anchor, tt.word)
				// Every link returns the builder, so the receiver must be the
				// builder too — a resolver that fell back to a bare-name search
				// would happily answer with another type's same-named method.
				assertHover(t, got, append([]string{"func (Server) " + tt.word}, tt.want...), tt.notWant)
			})
		}
	})

	// Go-to-definition must land on the builder's own method, not on the
	// same-named method of the local decoy.
	t.Run("definition", func(t *testing.T) {
		line, col := locate(t, chainMainSrc, `WithName("gala-kv")`, "WithName")
		locs, err := h.Definition(uri, line, col)
		if err != nil {
			t.Fatalf("definition: %v", err)
		}
		if len(locs) == 0 {
			t.Fatal("no definition found for the chained method")
		}
		got := strings.ToLower(filepath.ToSlash(string(locs[0].URI)))
		if !strings.HasSuffix(got, "internal/srv/server.gala") {
			t.Fatalf("expected the builder's own source, got %s", locs[0].URI)
		}
	})

	// Completion at the head of the chain, and at its tail — where the receiver
	// is seven links of builder to replay.
	t.Run("completion at the head", func(t *testing.T) {
		assertChainCompletions(t, h, uri, chainMainSrc, "srv.NewServer().", "WithName(", "WithTimeout(")
	})
	t.Run("completion at the tail", func(t *testing.T) {
		assertChainCompletions(t, h, uri, chainMainSrc, "WithMaxConns(64).", "ServeTCPOn(", "WithPort(")
	})

	// Signature help — the parameter popup — on the second link and the eighth.
	t.Run("signature help on the second link", func(t *testing.T) {
		assertFirstParam(t, h, uri, chainMainSrc, `WithName("gala-kv")`, "WithName", "name string")
	})
	t.Run("signature help on the eighth link", func(t *testing.T) {
		assertFirstParam(t, h, uri, chainMainSrc, `ServeTCPOn(":8080"`, "ServeTCPOn", "addr string")
	})
}

// A comment is not part of the expression below it. An ordinary sentence ends
// in a period, and the flattener joins a previous line that ends in one — so
// every statement following a doc comment used to read as the tail of a member
// access: go-to-definition either bailed out entirely (the fall-through guard
// saw a "member access" whose member did not resolve) or jumped to a same-named
// method of whatever the comment's last word happened to name.
const commentedCallSrc = `package main

type Greeter struct {
    val label string
}

// Greet on Greeter must not answer for the free function below.
func (g Greeter) Greet() string = g.label

// Greet is the free function the cursor is on.
func Greet() string = "hi"

func Run() {
    val greeter = Greeter(label = "x")
    Println(greeter)
    // Delegate to greeter.
    Greet()
}
`

func TestCommentLineIsNotPartOfTheExpressionBelowIt(t *testing.T) {
	h := newHarness(t)
	uri := openFileOnDisk(t, h, commentedCallSrc)
	settle(t, h, uri, commentedCallSrc, "type Greeter", "Greeter")

	line, col := locate(t, commentedCallSrc, "    Greet()", "Greet")
	locs, err := h.Definition(uri, line, col)
	if err != nil {
		t.Fatalf("definition: %v", err)
	}
	if len(locs) == 0 {
		t.Fatal("go-to-definition found nothing for a call below a comment")
	}
	wantLine, _ := locate(t, commentedCallSrc, "func Greet()", "Greet")
	if locs[0].Range.Start.Line != wantLine {
		t.Errorf("expected the free function on line %d, got line %d", wantLine, locs[0].Range.Start.Line)
	}

	assertHover(t, hoverAt(t, h, uri, commentedCallSrc, "    Greet()", "Greet"), []string{"func Greet()"}, nil)
}

// A chain may be annotated between its links: a comment-only line is skipped by
// the flattener, not treated as the end of the expression.
func TestChainWithCommentsBetweenLinks(t *testing.T) {
	const src = `package main

import "github.com/example/kv/internal/srv"

func Run() {
    srv.NewServer().
        // name it for the logs
        WithName("gala-kv").
        // and bound the shutdown
        WithTimeout(5)
}
`
	h, uri := openChainProject(t, src)
	got := hoverAt(t, h, uri, src, "WithTimeout(5)", "WithTimeout")
	assertHover(t, got, []string{"func (Server) WithTimeout"}, nil)
}

// assertChainCompletions checks that completing right after the trailing dot of
// the line holding `anchor` offers labels starting with each of `wants`.
func assertChainCompletions(t *testing.T, h *servertest.Harness, uri lsp.DocumentURI, src, anchor string, wants ...string) {
	t.Helper()
	line, _ := locate(t, src, anchor, anchor)
	col := len(strings.Split(src, "\n")[line]) // just past the trailing dot

	list, err := h.Completion(uri, line, col)
	if err != nil {
		t.Fatalf("completion: %v", err)
	}
	// Labels carry the full signature ("WithName(name string) srv.Server").
	for _, want := range wants {
		if !hasLabelPrefix(list, want) {
			t.Errorf("completion missing %q, got %v", want, labelSlice(list))
		}
	}
}

// assertFirstParam checks the parameter popup shown from inside the argument
// list of the call to `word`.
func assertFirstParam(t *testing.T, h *servertest.Harness, uri lsp.DocumentURI, src, anchor, word, want string) {
	t.Helper()
	line, col := locate(t, src, anchor, word)
	col += len(word) // just past the opening paren

	sh := requestSignatureHelp(t, h, uri, line, col)
	if sh == nil || len(sh.Signatures) == 0 {
		t.Fatal("no signature help for the chained method")
	}
	if !strings.Contains(sh.Signatures[0].Label, want) {
		t.Errorf("expected the builder's own parameter list, got %q", sh.Signatures[0].Label)
	}
}
