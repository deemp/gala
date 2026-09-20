package build

import (
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"
)

// The stdlib cache is shared by every project's build and read as a transpiler
// search path. Re-extraction used to empty the version directory and refill it
// in place, so concurrent extractions deleted each other's files and any build
// reading the directory meanwhile saw it half-written.
//
// Several processes asking for the same version at once must all end up with a
// complete, correctly-marked directory.
func TestConcurrentStdlibExtractionConverges(t *testing.T) {
	config := isolatedConfig(t)
	const version = "9.9.9"

	const racers = 6
	var wg sync.WaitGroup
	dirs := make([]string, racers)
	errs := make([]error, racers)

	for i := 0; i < racers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			dirs[i], _, errs[i] = config.ensureStdlibExtracted(version)
		}(i)
	}
	wg.Wait()

	want := snapshotFingerprint(version)
	for i := 0; i < racers; i++ {
		require.NoError(t, errs[i], "extraction %d failed", i)
		require.Equal(t, config.StdlibVersionDir(version), dirs[i])

		marker, err := os.ReadFile(filepath.Join(dirs[i], stdlibMarkerName))
		require.NoError(t, err, "extraction %d left no marker", i)
		require.Equal(t, want, string(marker), "extraction %d left a mismatched marker", i)
	}

	// The staged copies must not survive as siblings of the real directory.
	leftovers, err := filepath.Glob(config.StdlibVersionDir(version) + ".staging-*")
	require.NoError(t, err)
	require.Empty(t, leftovers, "staging directories must be cleaned up")
}

// A second call with the cache already populated must not re-extract: that is
// the fast path every build takes, and it has to stay lock-free and cheap.
func TestStdlibExtractionIsIdempotent(t *testing.T) {
	config := isolatedConfig(t)
	const version = "9.9.9"

	_, extracted, err := config.ensureStdlibExtracted(version)
	require.NoError(t, err)
	require.True(t, extracted, "the first call should extract")

	_, extracted, err = config.ensureStdlibExtracted(version)
	require.NoError(t, err)
	require.False(t, extracted, "a populated cache must not be re-extracted")
}

// A marker written by a different snapshot must invalidate the directory —
// that is the whole point of storing a fingerprint rather than a bare flag —
// and the replacement must again be complete.
func TestStaleMarkerTriggersCleanReExtraction(t *testing.T) {
	config := isolatedConfig(t)
	const version = "9.9.9"

	dir, _, err := config.ensureStdlibExtracted(version)
	require.NoError(t, err)

	// A file no longer in the snapshot, plus a marker from another binary.
	orphan := filepath.Join(dir, "dropped_upstream.gala")
	require.NoError(t, os.WriteFile(orphan, []byte("package gone\n"), 0644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, stdlibMarkerName), []byte("0.0.0 deadbeef"), 0644))

	_, extracted, err := config.ensureStdlibExtracted(version)
	require.NoError(t, err)
	require.True(t, extracted, "a stale marker must force re-extraction")

	require.NoFileExists(t, orphan, "re-extraction must not keep files dropped upstream")

	marker, err := os.ReadFile(filepath.Join(dir, stdlibMarkerName))
	require.NoError(t, err)
	require.Equal(t, snapshotFingerprint(version), string(marker))
}

// The guard against a degenerate version string turning cache invalidation into
// a recursive delete must still hold on the staging path.
func TestExtractionStillRefusesUnsafeVersionDir(t *testing.T) {
	config := isolatedConfig(t)

	err := config.extractStdlibVersion(config.StdlibDir, "irrelevant")
	require.Error(t, err, "the cache root itself is not a version directory")
	require.IsType(t, &UnsafeStdlibDirError{}, err)
}
