package commands

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateProjectName(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{"simple name", "myapp", false},
		{"with digits", "app123", false},
		{"with hyphen", "my-app", false},
		{"with underscore", "my_app", false},
		{"empty", "", true},
		{"dot", ".", true},
		{"parent", "..", true},
		{"forward slash", "foo/bar", true},
		{"backslash", `foo\bar`, true},
		{"absolute unix", "/tmp/foo", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateProjectName(tt.input)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateProjectName(%q) error = %v, wantErr = %v", tt.input, err, tt.wantErr)
			}
		})
	}
}

func TestScaffoldProject(t *testing.T) {
	tmp := t.TempDir()
	projectDir := filepath.Join(tmp, "hello")
	modulePath := "example.com/hello"

	if err := scaffoldProject(projectDir, modulePath); err != nil {
		t.Fatalf("scaffoldProject: %v", err)
	}

	// Verify the three expected files exist.
	expectedFiles := []string{"gala.mod", "main.gala", ".gitignore", filepath.Join(".claude", "settings.json")}
	for _, f := range expectedFiles {
		path := filepath.Join(projectDir, f)
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("missing file %s: %v", f, err)
		}
		if info.IsDir() {
			t.Fatalf("%s: expected file, got directory", f)
		}
	}

	// Verify gala.mod has the correct module line.
	modContent, err := os.ReadFile(filepath.Join(projectDir, "gala.mod"))
	if err != nil {
		t.Fatalf("read gala.mod: %v", err)
	}
	if !strings.Contains(string(modContent), "module "+modulePath) {
		t.Fatalf("gala.mod missing module line for %q, got:\n%s", modulePath, string(modContent))
	}

	// Verify main.gala has package main and a main func that prints the greeting.
	mainContent, err := os.ReadFile(filepath.Join(projectDir, "main.gala"))
	if err != nil {
		t.Fatalf("read main.gala: %v", err)
	}
	mainStr := string(mainContent)
	if !strings.Contains(mainStr, "package main") {
		t.Fatalf("main.gala missing 'package main':\n%s", mainStr)
	}
	if !strings.Contains(mainStr, "func main()") {
		t.Fatalf("main.gala missing 'func main()':\n%s", mainStr)
	}
	if !strings.Contains(mainStr, `Println("Hello, GALA!")`) {
		t.Fatalf("main.gala missing expected Println call:\n%s", mainStr)
	}

	// Verify .gitignore excludes the GALA build/cache directory.
	giContent, err := os.ReadFile(filepath.Join(projectDir, ".gitignore"))
	if err != nil {
		t.Fatalf("read .gitignore: %v", err)
	}
	if !strings.Contains(string(giContent), ".gala/") {
		t.Fatalf(".gitignore missing '.gala/' exclude:\n%s", string(giContent))
	}

	// Verify .claude/settings.json registers the GALA marketplace and enables
	// its plugin, so Claude Code offers the plugin for the new project.
	settingsContent, err := os.ReadFile(filepath.Join(projectDir, ".claude", "settings.json"))
	if err != nil {
		t.Fatalf("read .claude/settings.json: %v", err)
	}
	var settings struct {
		ExtraKnownMarketplaces map[string]struct {
			Source struct {
				Source string `json:"source"`
				Repo   string `json:"repo"`
			} `json:"source"`
		} `json:"extraKnownMarketplaces"`
		EnabledPlugins map[string]bool `json:"enabledPlugins"`
	}
	if err := json.Unmarshal(settingsContent, &settings); err != nil {
		t.Fatalf(".claude/settings.json is not valid JSON: %v\n%s", err, string(settingsContent))
	}
	marketplace := settings.ExtraKnownMarketplaces["gala"].Source
	if marketplace.Source != "github" || marketplace.Repo != "martianoff/gala" {
		t.Fatalf(".claude/settings.json: gala marketplace source = %+v, want github martianoff/gala", marketplace)
	}
	if !settings.EnabledPlugins["gala@gala"] {
		t.Fatalf(".claude/settings.json does not enable gala@gala:\n%s", string(settingsContent))
	}
}

func TestScaffoldProjectCustomModule(t *testing.T) {
	tmp := t.TempDir()
	projectDir := filepath.Join(tmp, "proj")
	modulePath := "github.com/someone/proj"

	if err := scaffoldProject(projectDir, modulePath); err != nil {
		t.Fatalf("scaffoldProject: %v", err)
	}

	modContent, err := os.ReadFile(filepath.Join(projectDir, "gala.mod"))
	if err != nil {
		t.Fatalf("read gala.mod: %v", err)
	}
	if !strings.Contains(string(modContent), "module "+modulePath) {
		t.Fatalf("gala.mod missing custom module path %q, got:\n%s", modulePath, string(modContent))
	}
}
