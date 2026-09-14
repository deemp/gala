package lsp_test

import (
	"strings"
	"testing"

	"github.com/owenrumney/go-lsp/lsp"
)

// A free function declared in a sibling file of the same package, called from
// inside a lambda. Agents such as Claude Code open only the file they are
// working on, so the sibling is never sent to the server: it has to be found
// on disk.
var siblingFunctionProject = []testProjectFile{
	{Name: "shapes.gala", Src: `package main

sealed type Shape {
    case Circle(Radius float64)
    case Rect(W float64, H float64)
}

func Area(s Shape) float64 = s match {
    case Circle(r) => 3.14159 * r * r
    case Rect(w, h) => w * h
}
`},
	{Name: "main.gala", Src: `package main

import . "martianoff/gala/collection_immutable"

func main() {
    val shapes = ArrayOf[Shape](Circle(1.0), Rect(2.0, 3.0))
    val total = shapes.FoldLeft(0.0, (acc, s) => acc + Area(s))
    Println(s"total area: $total")
}
`},
}

// Line 6 of main.gala is the FoldLeft call; "Area" spans characters 55-58.
const siblingAreaLine, siblingAreaChar = 6, 56

func TestDefinition_SiblingFileFunction(t *testing.T) {
	tests := []struct {
		name      string
		openFiles []string
	}{
		{"only the calling file is open", []string{"main.gala"}},
		{"both files are open", []string{"shapes.gala", "main.gala"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			dir := createTestProject(t, siblingFunctionProject)
			var uri lsp.DocumentURI
			for _, name := range tt.openFiles {
				uri = openProjectFile(t, h, dir, name)
			}

			locs, err := h.Definition(uri, siblingAreaLine, siblingAreaChar)
			if err != nil {
				t.Fatal(err)
			}
			if len(locs) == 0 {
				t.Fatal("no definition found for Area declared in shapes.gala")
			}
			if !strings.HasSuffix(string(locs[0].URI), "shapes.gala") {
				t.Fatalf("definition in %s, want shapes.gala", locs[0].URI)
			}
			if locs[0].Range.Start.Line != 7 {
				t.Errorf("definition at line %d, want 7 (func Area)", locs[0].Range.Start.Line)
			}
		})
	}
}

func TestHover_SiblingFileFunction(t *testing.T) {
	h := newHarness(t)
	dir := createTestProject(t, siblingFunctionProject)
	uri := openProjectFile(t, h, dir, "main.gala")

	hover, err := h.Hover(uri, siblingAreaLine, siblingAreaChar)
	if err != nil {
		t.Fatal(err)
	}
	if hover == nil {
		t.Fatal("no hover for Area declared in shapes.gala")
	}
	if !strings.Contains(hover.Contents.Value(), "Area") || !strings.Contains(hover.Contents.Value(), "float64") {
		t.Errorf("hover for Area = %q, want its signature", hover.Contents.Value())
	}
}

func TestReferences_SiblingFileFunction(t *testing.T) {
	h := newHarness(t)
	dir := createTestProject(t, siblingFunctionProject)
	uri := openProjectFile(t, h, dir, "main.gala")

	locs, err := h.References(uri, siblingAreaLine, siblingAreaChar, true)
	if err != nil {
		t.Fatal(err)
	}
	var inShapes, inMain bool
	for _, l := range locs {
		inShapes = inShapes || strings.HasSuffix(string(l.URI), "shapes.gala")
		inMain = inMain || strings.HasSuffix(string(l.URI), "main.gala")
	}
	if !inShapes || !inMain {
		t.Errorf("references to Area = %v, want the declaration in shapes.gala and the call in main.gala", locs)
	}
}
