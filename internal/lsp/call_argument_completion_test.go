package lsp_test

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/owenrumney/go-lsp/lsp"
	"github.com/owenrumney/go-lsp/servertest"
)

// callArgsSrc is a document calling into the builder package, with body as the
// contents of Run.
func callArgsSrc(body string) string {
	return `package main

import "github.com/example/kv/internal/srv"

sealed type Shape {
    case Circle(radius float64)
    case Rect(width float64, height float64)
}

func Connect(host string, port int = 8080, tls bool = true) bool = true

func Run() {
` + body + `
}
`
}

// openCallArgsProject opens a complete document to settle analysis on, from a
// client that does or does not accept snippets; each test then edits it into
// the mid-typing shape it is about.
func openCallArgsProject(t *testing.T, snippets bool) (*servertest.Harness, lsp.DocumentURI) {
	t.Helper()
	var caps lsp.ClientCapabilities
	raw := fmt.Sprintf(`{"textDocument": {"completion": {"completionItem": {"snippetSupport": %t}}}}`, snippets)
	if err := json.Unmarshal([]byte(raw), &caps); err != nil {
		t.Fatal(err)
	}
	return openChainProjectAs(t, callArgsSrc(`    srv.NewServer().WithName("gala-kv")`), caps)
}

// editTo replaces the document with callArgsSrc(body) and returns the caret
// position marked by `|` in body.
func editTo(t *testing.T, h *servertest.Harness, uri lsp.DocumentURI, version int, body string) (line, col int) {
	t.Helper()
	marked := callArgsSrc(body)
	idx := strings.Index(marked, "|")
	if idx < 0 {
		t.Fatal("no caret marker in the edited source")
	}
	before := marked[:idx]
	line = strings.Count(before, "\n")
	col = idx - (strings.LastIndex(before, "\n") + 1)
	if err := h.DidChange(uri, version, before+marked[idx+1:]); err != nil {
		t.Fatal(err)
	}
	return line, col
}

func isSnippet(item lsp.CompletionItem) bool {
	return item.InsertTextFormat != nil && *item.InsertTextFormat == lsp.InsertTextFormatSnippet
}

// Where the caret begins an argument, completion offers the callee's parameters
// as named arguments — for a method at the end of a builder chain, resolved
// through the whole chain, for a function, and for a sealed case constructor.
func TestCompletionOffersParametersAsNamedArguments(t *testing.T) {
	h, uri := openCallArgsProject(t, true)
	version := 0
	complete := func(t *testing.T, body string) (*lsp.CompletionList, int, int) {
		t.Helper()
		version++
		line, col := editTo(t, h, uri, version, body)
		list, err := h.Completion(uri, line, col)
		if err != nil {
			t.Fatalf("completion: %v", err)
		}
		return list, line, col
	}

	// With nothing typed yet the parameters are the whole answer, and typing
	// asks again; the popup the editor opens on `(` is signature help, which
	// must resolve the same call. The editor usually closes the paren as it is
	// typed, so the document may hold either shape.
	for _, tt := range []struct {
		name, body string
		params     []string
		signature  string
	}{
		{"method in a builder chain", "    srv.NewServer().\n        WithName(|", []string{"name"}, "name string"},
		{"method in a builder chain, paren auto-closed", "    srv.NewServer().\n        WithName(|)", []string{"name"}, "name string"},
		{"sealed case constructor", "    val s = Rect(|)", []string{"width", "height"}, "width float64"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			list, line, col := complete(t, tt.body)
			for _, param := range tt.params {
				item, ok := findItem(list, param)
				if !ok {
					t.Errorf("no named-argument item for %q, got %v", param, labelSlice(list))
				} else if item.InsertText != param+" = " {
					t.Errorf("named argument inserts %q, want %q", item.InsertText, param+" = ")
				}
			}
			if hasLabelPrefix(list, "Tuple") {
				t.Errorf("parameters came back mixed into the global list: %v", labelSlice(list))
			}
			if !list.IsIncomplete {
				t.Error("a parameters-only list must be incomplete, so typing asks again")
			}

			sh := requestSignatureHelp(t, h, uri, line, col)
			if sh == nil || len(sh.Signatures) == 0 || !strings.Contains(sh.Signatures[0].Label, tt.signature) {
				t.Errorf("no signature help for the call, got %+v", sh)
			}
		})
	}

	t.Run("typed prefix keeps the rest of the list", func(t *testing.T) {
		list, _, _ := complete(t, "    srv.NewServer().\n        WithName(Co|")
		if _, ok := findItem(list, "name"); !ok {
			t.Errorf("missing the named argument, got %v", labelSlice(list))
		}
		// A positional argument is as valid as a named one.
		if _, ok := findItem(list, "Connect"); !ok {
			t.Errorf("missing the global list for a positional argument, got %v", labelSlice(list))
		}
	})

	t.Run("arguments already given are skipped", func(t *testing.T) {
		list, _, _ := complete(t, `    Println(Connect("localhost", tls = false, |`)
		if _, ok := findItem(list, "port"); !ok {
			t.Errorf("missing the one parameter not yet given, got %v", labelSlice(list))
		}
		for _, given := range []string{"host", "tls"} {
			if _, ok := findItem(list, given); ok {
				t.Errorf("offered %q, which is already given", given)
			}
		}
	})
}

// Completing a method or function that has required parameters inserts them as
// named arguments with tab stops; a client without snippet support keeps the
// plain `Name(` insert.
func TestCompletionInsertsRequiredParametersAsNamedArguments(t *testing.T) {
	const afterDot = "    srv.NewServer().|"
	for _, tt := range []struct {
		name     string
		snippets bool
		body     string
		callee   string
		want     string
	}{
		{"one required parameter", true, afterDot, "WithName", "WithName(name = $1)$0"},
		{"two required parameters", true, afterDot, "ServeTCPOn", "ServeTCPOn(addr = $1, handler = $2)$0"},
		{"function with defaults inserts only the required ones", true, "    Println(Conn|)", "Connect", "Connect(host = $1)$0"},
		{"plain-text client", false, afterDot, "WithName", "WithName("},
	} {
		t.Run(tt.name, func(t *testing.T) {
			h, uri := openCallArgsProject(t, tt.snippets)
			line, col := editTo(t, h, uri, 1, tt.body)
			list, err := h.Completion(uri, line, col)
			if err != nil {
				t.Fatalf("completion: %v", err)
			}
			item, ok := findItem(list, tt.callee)
			if !ok {
				t.Fatalf("no completion for %s, got %v", tt.callee, labelSlice(list))
			}
			if item.InsertText != tt.want || isSnippet(item) != tt.snippets {
				t.Errorf("%s inserts %q (snippet=%v), want %q (snippet=%v)", tt.callee, item.InsertText, isSnippet(item), tt.want, tt.snippets)
			}
		})
	}
}
