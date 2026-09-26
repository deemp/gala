package transformer

import (
	"go/ast"
	"go/token"
	"testing"

	"martianoff/gala/internal/transpiler"
)

// Go types a mixed arithmetic expression by its TYPED operand: `15 *
// time.Second` is a Duration, not an int. Inference took the left operand
// unconditionally, so every consumer of it — inlay hints, hover, downstream
// unification — saw the untyped constant's default instead.
func TestIsUntypedConstExpr(t *testing.T) {
	lit := func(kind token.Token, v string) ast.Expr { return &ast.BasicLit{Kind: kind, Value: v} }
	sel := &ast.SelectorExpr{X: ast.NewIdent("time"), Sel: ast.NewIdent("Second")}

	for _, tt := range []struct {
		name string
		expr ast.Expr
		want bool
	}{
		{"int literal", lit(token.INT, "15"), true},
		{"float literal", lit(token.FLOAT, "1.5"), true},
		{"string literal", lit(token.STRING, `"x"`), true},
		{"negated literal", &ast.UnaryExpr{Op: token.SUB, X: lit(token.INT, "3")}, true},
		{"parenthesized literal", &ast.ParenExpr{X: lit(token.INT, "3")}, true},
		{"literal arithmetic", &ast.BinaryExpr{X: lit(token.INT, "2"), Op: token.MUL, Y: lit(token.INT, "3")}, true},
		{"qualified constant", sel, false},
		{"identifier", ast.NewIdent("x"), false},
		{"call", &ast.CallExpr{Fun: ast.NewIdent("f")}, false},
		{"mixed arithmetic", &ast.BinaryExpr{X: lit(token.INT, "2"), Op: token.MUL, Y: sel}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := isUntypedConstExpr(tt.expr); got != tt.want {
				t.Errorf("isUntypedConstExpr = %v, want %v", got, tt.want)
			}
		})
	}
}

// A shift takes its LEFT operand's type whatever the count is: `1 << n` is an
// int, not whatever integer type n happens to be. The count here is a variable,
// which is the only shape where the wrong rule could show — a constant count
// would make the whole expression constant and settle it that way regardless.
func TestShiftKeepsLeftOperandType(t *testing.T) {
	tr := NewGalaASTTransformer().(*galaASTTransformer)
	lit := &ast.BasicLit{Kind: token.INT, Value: "1"}
	count := ast.NewIdent("n")

	for _, op := range []token.Token{token.SHL, token.SHR} {
		got := tr.arithmeticResultType(&ast.BinaryExpr{X: lit, Op: op, Y: count})
		if got.String() != "int" {
			t.Errorf("%s: got %s, want the left operand's int", op, got.String())
		}
	}
}

// An expression built purely from untyped constants has a default type of its
// own, and the kinds combine by width: `1 * 1.5` is a float64, not the left
// operand's int.
func TestUntypedConstantArithmeticCombinesKinds(t *testing.T) {
	tr := &galaASTTransformer{exprTypeCache: map[ast.Expr]transpiler.Type{}}
	got := tr.arithmeticResultType(&ast.BinaryExpr{
		X:  &ast.BasicLit{Kind: token.INT, Value: "1"},
		Op: token.MUL,
		Y:  &ast.BasicLit{Kind: token.FLOAT, Value: "1.5"},
	})
	if got.String() != "float64" {
		t.Errorf("got %s, want float64", got.String())
	}
}

// The typed operand only wins when it actually resolves. An unresolvable one
// must not cost the untyped constant its concrete default: both inference
// paths would otherwise degrade `2 * mystery()` from int to nothing at all —
// and getExprType's "nothing at all" is the `any` this transpiler must never
// emit into generated Go.
func TestUnresolvableOperandKeepsTheConstantsDefault(t *testing.T) {
	tr := NewGalaASTTransformer().(*galaASTTransformer)
	unresolvable := &ast.CallExpr{Fun: ast.NewIdent("mystery")}
	e := &ast.BinaryExpr{X: &ast.BasicLit{Kind: token.INT, Value: "2"}, Op: token.MUL, Y: unresolvable}

	if got := tr.arithmeticResultType(e); got.String() != "int" {
		t.Errorf("arithmeticResultType = %s, want the constant's int default", got.String())
	}
	got := tr.getExprType(e)
	if id, ok := got.(*ast.Ident); !ok || id.Name != "int" {
		t.Errorf("getExprType = %#v, want the constant's int default", got)
	}
}

func TestExprTypeCacheReset(t *testing.T) {
	tr := NewGalaASTTransformer().(*galaASTTransformer)
	oldExpr := ast.NewIdent("old")
	tr.exprTypeCache[oldExpr] = transpiler.BasicType{Name: "int"}
	tr.resetExprTypeCache()
	if len(tr.exprTypeCache) != 0 {
		t.Fatalf("cache has %d entries after reset", len(tr.exprTypeCache))
	}
	tr.exprTypeCache[ast.NewIdent("new")] = transpiler.BasicType{Name: "string"}
	tr.resetExprTypeCache()
	if len(tr.exprTypeCache) != 0 {
		t.Fatalf("cache has %d entries after second reset", len(tr.exprTypeCache))
	}
}

func TestCachedTypeResolverLifecycle(t *testing.T) {
	tr := NewGalaASTTransformer().(*galaASTTransformer)
	tr.packageName = "main"
	tr.importManager = NewImportManager()
	tr.typeMetas = make(map[string]*transpiler.TypeMetadata)
	exists := func(name string) bool {
		_, ok := tr.typeMetas[name]
		return ok
	}

	if _, ok := tr.tryResolveSimpleName("Thing", exists); ok {
		t.Fatal("unexpected resolution before import was added")
	}
	tr.importManager.Add("example.com/a", "", true, "a")
	tr.typeMetas["a.Thing"] = &transpiler.TypeMetadata{Name: "Thing"}
	if got, ok := tr.tryResolveSimpleName("Thing", exists); !ok || got != "a.Thing" {
		t.Fatalf("live resolver = %q, %v; want a.Thing, true", got, ok)
	}

	tr.cachedTypeResolver = tr.buildTypeResolver()
	epoch := tr.typeEnvEpoch
	tr.importManager.Add("example.com/b", "", true, "b")
	tr.typeMetas["b.Other"] = &transpiler.TypeMetadata{Name: "Other"}
	// An import added after the snapshot is the case that used to go
	// unnoticed: bare-name resolution kept answering from the pre-import set.
	// The transformer invalidates both caches wherever entries change, and
	// this is that call, so the new import has to be visible afterwards.
	tr.invalidateImportCaches()
	if got, ok := tr.tryResolveSimpleName("Other", exists); !ok || got != "b.Other" {
		t.Fatalf("resolver after invalidation = %q, %v; want b.Other, true", got, ok)
	}
	if tr.cachedTypeResolver != nil {
		t.Fatal("invalidateImportCaches left the resolver snapshot in place")
	}
	if tr.typeEnvEpoch == epoch {
		t.Fatal("invalidateImportCaches did not invalidate the function environment")
	}
}

func TestTypeNameMemoIsBuildLocal(t *testing.T) {
	tr := NewGalaASTTransformer().(*galaASTTransformer)
	tr.packageName = "main"
	tr.importManager = NewImportManager()
	tr.importManager.Add("example.com/a", "", true, "a")
	tr.typeMetas = make(map[string]*transpiler.TypeMetadata)

	memo := &typeNameMemo{}
	if got := tr.normalizeTypeNameMemoized("Thing", memo); got != "Thing" {
		t.Fatalf("initial normalization = %q, want Thing", got)
	}
	tr.typeMetas["a.Thing"] = &transpiler.TypeMetadata{Name: "Thing"}
	if got := tr.normalizeTypeNameMemoized("Thing", memo); got != "Thing" {
		t.Fatalf("memoized normalization = %q, want Thing", got)
	}
	if got := tr.normalizeTypeNameMemoized("Thing", &typeNameMemo{}); got != "a.Thing" {
		t.Fatalf("fresh normalization = %q, want a.Thing", got)
	}
}
