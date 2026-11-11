package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gotest.tools/assert"
)

func testGatewayConfig(stateDir string) gatewayConfig {
	return gatewayConfig{
		identity:     testIdentity(),
		stateDir:     stateDir,
		pollInterval: time.Hour,
		maxStaleness: 60 * time.Second,
	}
}

func TestAcquireLockWithRetryHolderReleases(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".lock")
	holder, err := acquireLock(path)
	assert.NilError(t, err)
	go func() {
		time.Sleep(60 * time.Millisecond)
		releaseLock(holder)
	}()

	f, err := acquireLockWithRetry(path, 2*time.Second, 10*time.Millisecond, nil)
	assert.NilError(t, err)
	defer releaseLock(f)
	assert.Assert(t, !lockLost(f, path))
}

func TestAcquireLockWithRetryWindowPasses(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".lock")
	holder, err := acquireLock(path)
	assert.NilError(t, err)
	defer releaseLock(holder)

	window := 100 * time.Millisecond
	start := time.Now()
	_, err = acquireLockWithRetry(path, window, 10*time.Millisecond, nil)
	assert.Assert(t, time.Since(start) >= window)
	assert.Assert(t, errors.Is(err, errLockNotAcquired))
	assert.Assert(t, strings.Contains(err.Error(), lockNotAcquiredMarker))
}

func TestStartGatewayTouchesNothingWithoutLock(t *testing.T) {
	dir := t.TempDir()
	holder, err := acquireLock(filepath.Join(dir, ".lock"))
	assert.NilError(t, err)
	defer releaseLock(holder)
	src := &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, allowAll())}}

	_, _, startErr := startGateway(testGatewayConfig(dir), src, 50*time.Millisecond, nil, (*gatewayServer).evaluateDisposition)
	assert.Assert(t, startErr != nil)

	// a sync started without the lock would have read by now
	time.Sleep(20 * time.Millisecond)
	src.mu.Lock()
	gets, watches := src.getCalls, src.watchCalls
	src.mu.Unlock()
	assert.Equal(t, gets, 0)
	assert.Equal(t, watches, 0)

	entries, err := os.ReadDir(dir)
	assert.NilError(t, err)
	assert.Equal(t, len(entries), 1) // the holder's lock file and nothing else
	assert.Equal(t, entries[0].Name(), ".lock")
	assert.Assert(t, errors.Is(startErr, errLockNotAcquired))
}

func TestStartGatewayHoldsLockAndSyncs(t *testing.T) {
	dir := t.TempDir()
	src := &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, allowAll())}}

	g, lockFile, err := startGateway(testGatewayConfig(dir), src, 50*time.Millisecond, nil, (*gatewayServer).evaluateDisposition)
	assert.NilError(t, err)
	defer releaseLock(lockFile)
	defer g.closeStop()

	_, err = acquireLock(filepath.Join(dir, ".lock"))
	assert.Assert(t, err != nil)
	waitFor(t, time.Second, func() bool { _, _, s, _ := g.policy.snapshot(); return s == sourceCached })
}

func TestLockLost(t *testing.T) {
	tests := []struct {
		name    string
		disturb func(t *testing.T, path string)
		want    bool
	}{
		{
			name:    "held and intact",
			disturb: func(t *testing.T, path string) {},
			want:    false,
		},
		{
			name: "lock file removed",
			disturb: func(t *testing.T, path string) {
				assert.NilError(t, os.Remove(path))
			},
			want: true,
		},
		{
			name: "lock file replaced",
			disturb: func(t *testing.T, path string) {
				assert.NilError(t, os.Remove(path))
				assert.NilError(t, os.WriteFile(path, nil, 0o644))
			},
			want: true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), ".lock")
			f, err := acquireLock(path)
			assert.NilError(t, err)
			defer releaseLock(f)

			tc.disturb(t, path)
			assert.Equal(t, lockLost(f, path), tc.want)
		})
	}
}
