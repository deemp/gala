package commands

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"martianoff/gala/internal/build"
)

var (
	cleanAll   bool
	cleanStale bool
	cleanCache bool
)

var cleanCmd = &cobra.Command{
	Use:   "clean",
	Short: "Clean build workspaces and caches",
	Long: `Clean removes build workspaces and cached data.

By default, only cleans the workspace for the current project.

Options:
  --all     Remove all build workspaces
  --stale   Remove workspaces older than 7 days
  --cache   Remove the analysis cache (.gala/cache/)

Examples:
  gala clean              # Clean current project's workspace
  gala clean --all        # Clean all workspaces
  gala clean --stale      # Clean stale workspaces
  gala clean --cache      # Clear analysis cache`,
	Run: runClean,
}

func init() {
	cleanCmd.Flags().BoolVar(&cleanAll, "all", false, "Clean all workspaces")
	cleanCmd.Flags().BoolVar(&cleanStale, "stale", false, "Clean workspaces older than 7 days")
	cleanCmd.Flags().BoolVar(&cleanCache, "cache", false, "Clear analysis cache (.gala/cache/)")
}

func runClean(cmd *cobra.Command, args []string) {
	config := build.DefaultConfig()

	if cleanCache {
		cwd, err := os.Getwd()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		cacheDir := filepath.Join(cwd, ".gala", "cache")
		if _, err := os.Stat(cacheDir); os.IsNotExist(err) {
			fmt.Println("No analysis cache found.")
		} else if err := os.RemoveAll(cacheDir); err != nil {
			fmt.Fprintf(os.Stderr, "Error cleaning cache: %v\n", err)
			os.Exit(1)
		} else {
			fmt.Println("Analysis cache cleared.")
		}
		return
	}

	if cleanAll {
		// Clean all workspaces
		fmt.Println("Cleaning all build workspaces...")
		removed, busy, err := build.CleanAllWorkspaces(config)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		reportSweep(removed, busy)
		return
	}

	if cleanStale {
		// Clean stale workspaces (older than 7 days)
		fmt.Println("Cleaning stale workspaces...")
		removed, busy, err := build.CleanStaleWorkspaces(config, 7*24*time.Hour)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Cleaned %d stale workspaces.\n", removed)
		reportBusy(busy)
		return
	}

	// Clean current project's workspace
	projectDir, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// Check if gala.mod exists
	galaModPath := filepath.Join(projectDir, "gala.mod")
	if _, err := os.Stat(galaModPath); err != nil {
		fmt.Fprintf(os.Stderr, "Error: gala.mod not found in current directory\n")
		fmt.Fprintln(os.Stderr, "Use 'gala clean --all' to clean all workspaces.")
		os.Exit(1)
	}

	// A project has one workspace per command family (build, test), so
	// cleaning it means removing each of them.
	workspaces, err := build.FindWorkspacesByProject(config, projectDir)
	if err != nil {
		fmt.Println("No workspace found for current project.")
		return
	}

	for _, workspace := range workspaces {
		if err := workspace.Clean(); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Cleaned workspace: %s\n", workspace.Dir)
	}
}

// reportSweep prints what a whole-directory sweep did.
func reportSweep(removed, busy int) {
	fmt.Printf("Cleaned %d workspaces.\n", removed)
	reportBusy(busy)
}

// reportBusy notes workspaces a sweep left alone because a build holds them.
// Silence would be wrong: the user asked for everything to go, and some of it
// is still there.
func reportBusy(busy int) {
	if busy == 0 {
		return
	}
	fmt.Printf("Left %d workspace(s) in use by a running build.\n", busy)
}
