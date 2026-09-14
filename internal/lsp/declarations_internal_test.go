package lsp

import (
	"testing"

	"github.com/owenrumney/go-lsp/lsp"
	"github.com/stretchr/testify/assert"
)

func TestScanDeclarations(t *testing.T) {
	type decl struct {
		name, container string
		kind            lsp.SymbolKind
		line, col, end  int
	}
	flatten := func(ds []declaration) []decl {
		var out []decl
		for _, d := range ds {
			out = append(out, decl{d.name, d.container, d.kind, d.line, d.col, d.endLine})
			for _, v := range d.variants {
				out = append(out, decl{v.name, v.container, v.kind, v.line, v.col, v.endLine})
			}
		}
		return out
	}
	tests := []struct {
		name string
		src  string
		want []decl
	}{
		{
			name: "every top-level form",
			src: `package demo

type Id = string
type Box[T any] struct {
    val value T
}
type Sized interface { Size() int }
struct Point(X int, Y int)
sealed type Expr {
    case Num(v int)
    case Neg
}
func (b Box[T]) Get() T = b.value
func (val p *Point) Move() Point {
    return p
}
func Make[T any](v T) Box[T] = Box[T](value = v)
val Zero = 0
var counter int
embed val assets string = "x.txt"
`,
			want: []decl{
				{"Id", "", lsp.SymbolKindClass, 2, 5, 2},
				{"Box", "", lsp.SymbolKindStruct, 3, 5, 5},
				{"Sized", "", lsp.SymbolKindInterface, 6, 5, 6},
				{"Point", "", lsp.SymbolKindStruct, 7, 7, 7},
				{"Expr", "", lsp.SymbolKindEnum, 8, 12, 11},
				{"Num", "Expr", lsp.SymbolKindEnumMember, 9, 9, 9},
				{"Neg", "Expr", lsp.SymbolKindEnumMember, 10, 9, 10},
				{"Get", "Box", lsp.SymbolKindMethod, 12, 16, 12},
				{"Move", "Point", lsp.SymbolKindMethod, 13, 20, 15},
				{"Make", "", lsp.SymbolKindFunction, 16, 5, 16},
				{"Zero", "", lsp.SymbolKindVariable, 17, 4, 17},
				{"counter", "", lsp.SymbolKindVariable, 18, 4, 18},
				{"assets", "", lsp.SymbolKindVariable, 19, 10, 19},
			},
		},
		{
			name: "local declarations, comments and raw strings are not declarations",
			src: "package demo\n" +
				"func outer() {\n" +
				"    val local = 1\n" +
				"}\n" +
				"/*\n" +
				"func commented() {}\n" +
				"*/\n" +
				"val doc = `\n" +
				"func inRawString() {}\n" +
				"`\n" +
				"// func lineComment() {}\n",
			want: []decl{
				{"outer", "", lsp.SymbolKindFunction, 1, 5, 3},
				{"doc", "", lsp.SymbolKindVariable, 7, 4, 7},
			},
		},
		{
			name: "CRLF line endings",
			src:  "package demo\r\nfunc run() {\r\n}\r\n",
			want: []decl{{"run", "", lsp.SymbolKindFunction, 1, 5, 2}},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.want, flatten(scanDeclarations(tt.src)))
		})
	}
}
