package lsp_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/owenrumney/go-lsp/lsp"
	"github.com/owenrumney/go-lsp/servertest"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	lspserver "martianoff/gala/internal/lsp"
)

type symbolAt struct {
	name       string
	kind       lsp.SymbolKind
	line, char int
}

func documentSymbolsAt(symbols []lsp.DocumentSymbol) []symbolAt {
	var out []symbolAt
	for _, s := range symbols {
		out = append(out, symbolAt{s.Name, s.Kind, s.SelectionRange.Start.Line, s.SelectionRange.Start.Character})
	}
	return out
}

// The outline lists the declarations of the requested file only, at their own
// positions. The analysis behind it merges sibling files of the package, and
// looking names up by substring put `main` on the `package main` line.
func TestDocumentSymbol_CurrentFileOnly(t *testing.T) {
	h := newHarness(t)
	dir := createTestProject(t, siblingFunctionProject)
	mainURI := openProjectFile(t, h, dir, "main.gala")
	shapesURI := openProjectFile(t, h, dir, "shapes.gala")

	mainSymbols, err := h.DocumentSymbol(mainURI)
	require.NoError(t, err)
	assert.Equal(t, []symbolAt{{"main", lsp.SymbolKindFunction, 4, 5}}, documentSymbolsAt(mainSymbols))

	shapeSymbols, err := h.DocumentSymbol(shapesURI)
	require.NoError(t, err)
	assert.Equal(t, []symbolAt{
		{"Shape", lsp.SymbolKindEnum, 2, 12},
		{"Area", lsp.SymbolKindFunction, 7, 5},
	}, documentSymbolsAt(shapeSymbols))
	require.Len(t, shapeSymbols, 2)
	assert.Equal(t, []symbolAt{
		{"Circle", lsp.SymbolKindEnumMember, 3, 9},
		{"Rect", lsp.SymbolKindEnumMember, 4, 9},
	}, documentSymbolsAt(shapeSymbols[0].Children))
}

// Every symbol's range must contain its selection range and its children's
// ranges, or clients such as VS Code reject the outline.
func TestDocumentSymbol_RangesNest(t *testing.T) {
	h := newHarness(t)
	uri := openFileOnDisk(t, h, `package main

type Person struct {
    val name string
}

func (p Person) Greet() string {
    return "hi"
}

func main() {
    Println(Person(name = "a").Greet())
}
`)
	symbols, err := h.DocumentSymbol(uri)
	require.NoError(t, err)
	var check func(parent *lsp.DocumentSymbol, s lsp.DocumentSymbol)
	check = func(parent *lsp.DocumentSymbol, s lsp.DocumentSymbol) {
		assert.True(t, contains(s.Range, s.SelectionRange), "%s: range %v does not contain selection %v", s.Name, s.Range, s.SelectionRange)
		if parent != nil {
			assert.True(t, contains(parent.Range, s.Range), "%s: range %v outside parent %s %v", s.Name, s.Range, parent.Name, parent.Range)
		}
		for _, c := range s.Children {
			check(&s, c)
		}
	}
	for _, s := range symbols {
		check(nil, s)
	}
	require.NotEmpty(t, symbols)
	assert.Equal(t, "Person", symbols[0].Name)
	assert.Equal(t, []symbolAt{{"Greet", lsp.SymbolKindMethod, 6, 16}}, documentSymbolsAt(symbols[0].Children))
}

func contains(outer, inner lsp.Range) bool {
	before := func(a, b lsp.Position) bool {
		return a.Line < b.Line || (a.Line == b.Line && a.Character <= b.Character)
	}
	return before(outer.Start, inner.Start) && before(inner.End, outer.End)
}

func TestWorkspaceSymbol(t *testing.T) {
	dir := createTestProject(t, []testProjectFile{
		siblingFunctionProject[0],
		siblingFunctionProject[1],
		{Name: "geometry/point.gala", Src: `package geometry

struct Point(X float64, Y float64)

type Area interface {
    Size() float64
}

func (p Point) Distance(o Point) float64 = 0.0

val Origin = Point(0.0, 0.0)
`},
		// Build output and caches under hidden directories are not the workspace.
		{Name: ".gala/cache/copy.gala", Src: "package main\n\nfunc Area() int = 1\n"},
	})
	root := lsp.DocumentURI(fileURIForPath(dir))
	h := servertest.New(t, lspserver.NewGalaHandler(), servertest.WithInitializeParams(&lsp.InitializeParams{RootURI: &root}))

	type found struct {
		name, kind, container, file string
		line                        int
	}
	query := func(q string) []found {
		t.Helper()
		symbols, err := h.WorkspaceSymbol(q)
		require.NoError(t, err)
		var out []found
		for _, s := range symbols {
			rel, err := filepath.Rel(dir, uriPathForTest(string(s.Location.URI)))
			require.NoError(t, err)
			out = append(out, found{s.Name, kindName(s.Kind), s.ContainerName, filepath.ToSlash(rel), s.Location.Range.Start.Line})
		}
		return out
	}

	tests := []struct {
		query string
		want  []found
	}{
		{"area", []found{
			{"Area", "Function", "main", "shapes.gala", 7},
			{"Area", "Interface", "geometry", "geometry/point.gala", 4},
		}},
		{"Circ", []found{{"Circle", "EnumMember", "Shape", "shapes.gala", 3}}},
		{"distance", []found{{"Distance", "Method", "Point", "geometry/point.gala", 8}}},
		{"origin", []found{{"Origin", "Variable", "geometry", "geometry/point.gala", 10}}},
		{"Point", []found{{"Point", "Struct", "geometry", "geometry/point.gala", 2}}},
		{"nothing-matches", nil},
	}
	for _, tt := range tests {
		t.Run(tt.query, func(t *testing.T) {
			assert.ElementsMatch(t, tt.want, query(tt.query))
		})
	}
}

func TestWorkspaceSymbol_Advertised(t *testing.T) {
	h := newHarness(t)
	assert.True(t, h.InitResult.Capabilities.WorkspaceSymbolProvider.Enabled())
}

func kindName(k lsp.SymbolKind) string {
	switch k {
	case lsp.SymbolKindFunction:
		return "Function"
	case lsp.SymbolKindMethod:
		return "Method"
	case lsp.SymbolKindStruct:
		return "Struct"
	case lsp.SymbolKindInterface:
		return "Interface"
	case lsp.SymbolKindEnum:
		return "Enum"
	case lsp.SymbolKindEnumMember:
		return "EnumMember"
	case lsp.SymbolKindVariable:
		return "Variable"
	}
	return "other"
}

// uriPathForTest turns a file URI back into an OS path for comparison.
func uriPathForTest(uri string) string {
	p := strings.TrimPrefix(uri, "file://")
	if len(p) > 2 && p[0] == '/' && p[2] == ':' {
		p = p[1:] // /C:/... -> C:/...
	}
	return filepath.FromSlash(p)
}
