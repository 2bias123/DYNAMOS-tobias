package main

import (
	"os"
	"path/filepath"
	"testing"

	"gotest.tools/assert"
)

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
