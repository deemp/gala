package lsp

import (
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestPackageFiles(t *testing.T) {
	const (
		mainProgram = "package main\n\nfunc main() {\n    Println(Area())\n}\n"
		mainHelper  = "package main\n\nfunc Area() float64 = 1.0\n"
		library     = "package shapes\n\nfunc Area() float64 = 1.0\n"
	)
	tests := []struct {
		name    string
		files   map[string]string
		current string
		want    []string
	}{
		{
			name:    "library package includes same-package files",
			files:   map[string]string{"a.gala": library, "b.gala": library, "other.gala": "package other\n"},
			current: "a.gala",
			want:    []string{"b.gala"},
		},
		{
			name:    "main program split across files includes its helpers",
			files:   map[string]string{"main.gala": mainProgram, "shapes.gala": mainHelper},
			current: "main.gala",
			want:    []string{"shapes.gala"},
		},
		{
			name:    "helper of a single main program includes the program",
			files:   map[string]string{"main.gala": mainProgram, "shapes.gala": mainHelper},
			current: "shapes.gala",
			want:    []string{"main.gala"},
		},
		{
			name:    "directory of independent main programs includes nothing",
			files:   map[string]string{"one.gala": mainProgram, "two.gala": mainProgram, "shapes.gala": mainHelper},
			current: "one.gala",
			want:    nil,
		},
		{
			name:    "test files only join test files",
			files:   map[string]string{"a.gala": library, "a_test.gala": library},
			current: "a.gala",
			want:    nil,
		},
		{
			name:    "a test file sees the package sources",
			files:   map[string]string{"a.gala": library, "a_test.gala": library},
			current: "a_test.gala",
			want:    []string{"a.gala"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			for name, src := range tt.files {
				require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte(src), 0644))
			}

			got := NewGalaHandler().packageFiles(filepath.Join(dir, tt.current), tt.files[tt.current])

			names := []string{}
			for _, p := range got {
				names = append(names, filepath.Base(p))
			}
			sort.Strings(names)
			if len(tt.want) == 0 {
				assert.Empty(t, names)
				return
			}
			assert.Equal(t, tt.want, names)
		})
	}
}

// The editor's unsaved copy of a sibling decides its package, not the file on
// disk.
func TestPackageFiles_PrefersOpenDocument(t *testing.T) {
	dir := t.TempDir()
	current := filepath.Join(dir, "a.gala")
	sibling := filepath.Join(dir, "b.gala")
	require.NoError(t, os.WriteFile(current, []byte("package shapes\n"), 0644))
	require.NoError(t, os.WriteFile(sibling, []byte("package other\n"), 0644))

	h := NewGalaHandler()
	h.documents[pathToURI(sibling)] = "package shapes\n"

	got := h.packageFiles(current, "package shapes\n")
	require.Len(t, got, 1)
	assert.True(t, sameFilePath(got[0], sibling))
}
