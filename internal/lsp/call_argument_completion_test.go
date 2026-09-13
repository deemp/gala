package lsp_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/owenrumney/go-lsp/lsp"
	"github.com/owenrumney/go-lsp/servertest"

)

// callArgsMainSrc is a complete document to settle analysis on; each test then
// edits it into the mid-typing shape it is about.
const callArgsMainSrc = `package main

import "github.com/example/kv/internal/srv"

func Connect(host string, port int = 8080, tls bool = true) bool = true

func Run() {
    srv.NewServer().
        WithName("gala-kv")
    Println(Connect("localhost"))
}
`

// openCallArgsProject opens callArgsMainSrc in a project that imports the
// builder package, from a client that does or does not accept snippets.
func openCallArgsProject(t *testing.T, snippets bool) (*servertest.Harness, lsp.DocumentURI) {
	t.Helper()
	root := createTestProject(t, []testProjectFile{
		{Name: "gala.mod", Src: "module github.com/example/kv\n\ngala 0.76.0\n"},
		{Name: "internal/srv/server.gala", Src: chainServerSrc},
		{Name: "app/main.gala", Src: callArgsMainSrc},
	})
	h, handler := newHarnessWithHandler(t)

	var params lsp.InitializeParams
	caps := `{"rootUri": ` + mustJSON(t, string(fileURIForPath(root))) +
		`, "capabilities": {"textDocument": {"completion": {"completionItem": {"snippetSupport": ` +
		mustJSON(t, snippets) + `}}}}}`
	if err := json.Unmarshal([]byte(caps), &params); err != nil {
		t.Fatal(err)
	}
	if _, err := handler.Initialize(context.Background(), &params); err != nil {
		t.Fatal(err)
	}

	uri := openProjectFile(t, h, root, "app/main.gala")
	settle(t, h, uri, callArgsMainSrc, "srv.NewServer()", "NewServer")
	return h, uri
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// editTo replaces the document and returns the caret position marked by `|`.
func editTo(t *testing.T, h *servertest.Harness, uri lsp.DocumentURI, version int, marked string) (line, col int) {
	t.Helper()
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

func itemByLabel(list *lsp.CompletionList, label string) *lsp.CompletionItem {
	if list == nil {
		return nil
	}
	for i := range list.Items {
		if list.Items[i].Label == label {
			return &list.Items[i]
		}
	}
	return nil
}

func methodItem(list *lsp.CompletionList, name string) *lsp.CompletionItem {
	if list == nil {
		return nil
	}
	for i := range list.Items {
		if list.Items[i].FilterText == name || list.Items[i].Label == name {
			return &list.Items[i]
		}
	}
	return nil
}

func isSnippet(item *lsp.CompletionItem) bool {
	return item.InsertTextFormat != nil && *item.InsertTextFormat == lsp.InsertTextFormatSnippet
}

// Right after the opening paren of a call, completion offers the callee's
// parameters as named arguments — for a method at the end of a builder chain,
// resolved through the whole chain, and for a plain function.
func TestCompletionOffersParametersAsNamedArguments(t *testing.T) {
	h, uri := openCallArgsProject(t, true)

	// The editor usually closes the paren as it is typed; the document may hold
	// either shape.
	for i, tt := range []struct{ name, call string }{
		{"method in a builder chain", "WithName(|"},
		{"method in a builder chain, paren auto-closed", "WithName(|)"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			line, col := editTo(t, h, uri, 10+i, `package main

import "github.com/example/kv/internal/srv"

func Connect(host string, port int = 8080, tls bool = true) bool = true

func Run() {
    srv.NewServer().
        `+tt.call+`
}
`)
			list, err := h.Completion(uri, line, col)
			if err != nil {
				t.Fatalf("completion: %v", err)
			}
			name := itemByLabel(list, "name")
			if name == nil {
				t.Errorf("no named-argument item for WithName's parameter, got %v", labelSlice(list))
			} else if name.InsertText != "name = " {
				t.Errorf("named argument inserts %q, want %q", name.InsertText, "name = ")
			}
			// Nothing typed yet: the parameters are the whole answer, not buried
			// in the global list, and typing asks again.
			if hasLabelPrefix(list, "Tuple") {
				t.Errorf("parameters came back mixed into the global list: %v", labelSlice(list))
			}
			if !list.IsIncomplete {
				t.Error("a parameters-only list must be incomplete, so typing asks again")
			}

			// The popup the editor opens on `(` is signature help; it must
			// resolve the same unfinished call.
			sh := requestSignatureHelp(t, h, uri, line, col)
			if sh == nil || len(sh.Signatures) == 0 || !strings.Contains(sh.Signatures[0].Label, "name string") {
				t.Errorf("no signature help for the unfinished call, got %+v", sh)
			}
		})
	}

	t.Run("typed prefix keeps the rest of the list", func(t *testing.T) {
		line, col := editTo(t, h, uri, 20, `package main

import "github.com/example/kv/internal/srv"

func Connect(host string, port int = 8080, tls bool = true) bool = true

func Run() {
    srv.NewServer().
        WithName(Co|
}
`)
		list, err := h.Completion(uri, line, col)
		if err != nil {
			t.Fatalf("completion: %v", err)
		}
		if itemByLabel(list, "name") == nil {
			t.Errorf("missing the named argument, got %v", labelSlice(list))
		}
		// A positional argument is as valid as a named one.
		if methodItem(list, "Connect") == nil {
			t.Errorf("missing the global list for a positional argument, got %v", labelSlice(list))
		}
	})

	t.Run("function with defaults, skipping arguments already given", func(t *testing.T) {
		line, col := editTo(t, h, uri, 30, `package main

import "github.com/example/kv/internal/srv"

func Connect(host string, port int = 8080, tls bool = true) bool = true

func Run() {
    srv.NewServer().WithName("gala-kv")
    Println(Connect("localhost", tls = false, |
}
`)
		list, err := h.Completion(uri, line, col)
		if err != nil {
			t.Fatalf("completion: %v", err)
		}
		if itemByLabel(list, "port") == nil {
			t.Errorf("missing the one parameter not yet given, got %v", labelSlice(list))
		}
		for _, given := range []string{"host", "tls"} {
			if itemByLabel(list, given) != nil {
				t.Errorf("offered %q, which is already given", given)
			}
		}
	})
}

// Completing a method or function that has required parameters inserts them as
// named arguments with tab stops; a client without snippet support keeps the
// plain `Name(` insert.
func TestCompletionInsertsRequiredParametersAsNamedArguments(t *testing.T) {
	marked := `package main

import "github.com/example/kv/internal/srv"

func Connect(host string, port int = 8080, tls bool = true) bool = true

func Run() {
    srv.NewServer().|
}
`
	t.Run("snippet client", func(t *testing.T) {
		h, uri := openCallArgsProject(t, true)
		line, col := editTo(t, h, uri, 1, marked)
		list, err := h.Completion(uri, line, col)
		if err != nil {
			t.Fatalf("completion: %v", err)
		}
		for _, tt := range []struct{ method, want string }{
			{"WithName", "WithName(name = $1)$0"},
			{"ServeTCPOn", "ServeTCPOn(addr = $1, handler = $2)$0"},
		} {
			item := methodItem(list, tt.method)
			if item == nil {
				t.Fatalf("no completion for %s, got %v", tt.method, labelSlice(list))
			}
			if item.InsertText != tt.want || !isSnippet(item) {
				t.Errorf("%s inserts %q (snippet=%v), want snippet %q", tt.method, item.InsertText, isSnippet(item), tt.want)
			}
		}
	})

	t.Run("function with defaults inserts only the required parameters", func(t *testing.T) {
		h, uri := openCallArgsProject(t, true)
		line, col := editTo(t, h, uri, 1, `package main

import "github.com/example/kv/internal/srv"

func Connect(host string, port int = 8080, tls bool = true) bool = true

func Run() {
    srv.NewServer().WithName("gala-kv")
    Println(Conn|)
}
`)
		list, err := h.Completion(uri, line, col)
		if err != nil {
			t.Fatalf("completion: %v", err)
		}
		item := methodItem(list, "Connect")
		if item == nil {
			t.Fatalf("no completion for Connect, got %v", labelSlice(list))
		}
		if want := "Connect(host = $1)$0"; item.InsertText != want || !isSnippet(item) {
			t.Errorf("Connect inserts %q (snippet=%v), want snippet %q", item.InsertText, isSnippet(item), want)
		}
	})

	t.Run("plain-text client", func(t *testing.T) {
		h, uri := openCallArgsProject(t, false)
		line, col := editTo(t, h, uri, 1, marked)
		list, err := h.Completion(uri, line, col)
		if err != nil {
			t.Fatalf("completion: %v", err)
		}
		item := methodItem(list, "WithName")
		if item == nil {
			t.Fatalf("no completion for WithName, got %v", labelSlice(list))
		}
		if item.InsertText != "WithName(" || isSnippet(item) {
			t.Errorf("WithName inserts %q (snippet=%v), want plain %q", item.InsertText, isSnippet(item), "WithName(")
		}
	})
}

