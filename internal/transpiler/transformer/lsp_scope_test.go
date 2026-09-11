package transformer

import (
	"testing"

	"martianoff/gala/internal/transpiler"
)

// The LSP's var-type channel answers two questions: what type a name has, and
// whether the name is a local at all. Dropping entries whose type did not
// resolve answered the second question "no" for exactly those bindings, so a
// local shadowing a documented package-level val was rendered as that val.
func TestUnresolvedLocalIsStillRecordedAsABinding(t *testing.T) {
	tr := NewGalaASTTransformer().(*galaASTTransformer)
	tr.lspVarTypes = map[string]transpiler.Type{}
	tr.lspCurrentFunc = "Run"

	tr.recordLSPVarType("label", transpiler.NilType{})
	typ, ok := tr.lspVarTypes["Run.label"]
	if !ok {
		t.Fatal("a local whose type did not resolve was not recorded as a binding")
	}
	// It must still read as "no type": every hint consumer skips the empty string.
	if typ.String() != "" {
		t.Errorf("unresolved binding rendered as %q, want the empty string", typ.String())
	}

	// A resolved type replaces it, and is never clobbered by a later unresolved
	// pass over the same name.
	tr.recordLSPVarType("label", transpiler.BasicType{Name: "int"})
	tr.recordLSPVarType("label", transpiler.NilType{})
	if got := tr.lspVarTypes["Run.label"].String(); got != "int" {
		t.Errorf("resolved type was lost: got %q, want int", got)
	}
}
