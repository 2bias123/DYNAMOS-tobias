package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"gotest.tools/assert"
)

func TestNewStoreCreatesDirs(t *testing.T) {
	dir := t.TempDir()
	_, err := NewStore(dir)
	assert.NilError(t, err)

	for _, sub := range []string{"data", "audit"} {
		info, err := os.Stat(filepath.Join(dir, sub))
		assert.NilError(t, err)
		assert.Assert(t, info.IsDir())
	}
}

func TestStoreWriteReadRoundTrip(t *testing.T) {
	s, err := NewStore(t.TempDir())
	assert.NilError(t, err)

	payload := []byte{0x01, 0x02, 0x03}
	assert.NilError(t, s.Write("kv", "k1", payload))

	got, err := s.Read("kv", "k1")
	assert.NilError(t, err)
	assert.Equal(t, string(got), string(payload))
}

func TestStoreReadMissing(t *testing.T) {
	s, err := NewStore(t.TempDir())
	assert.NilError(t, err)

	_, err = s.Read("kv", "absent")
	assert.Assert(t, errors.Is(err, os.ErrNotExist))
}

func TestStoreWriteOverwrites(t *testing.T) {
	s, err := NewStore(t.TempDir())
	assert.NilError(t, err)

	assert.NilError(t, s.Write("kv", "k", []byte("first")))
	assert.NilError(t, s.Write("kv", "k", []byte("second")))

	got, err := s.Read("kv", "k")
	assert.NilError(t, err)
	assert.Equal(t, string(got), "second")
}

func TestStoreInvalidNames(t *testing.T) {
	s, err := NewStore(t.TempDir())
	assert.NilError(t, err)

	cases := []struct {
		name       string
		class, key string
	}{
		{"dotdot class", "..", "k"},
		{"slash in key", "kv", "a/b"},
		{"leading dot key", "kv", ".hidden"},
		{"empty class", "", "k"},
		{"empty key", "kv", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			werr := s.Write(tc.class, tc.key, []byte("x"))
			assert.Assert(t, errors.Is(werr, errInvalidName))

			_, rerr := s.Read(tc.class, tc.key)
			assert.Assert(t, errors.Is(rerr, errInvalidName))
		})
	}
}

func TestStoreWriteLeavesNoTemp(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir)
	assert.NilError(t, err)

	assert.NilError(t, s.Write("kv", "k1", []byte("data")))

	_, err = os.Stat(filepath.Join(dir, "data", "kv", "k1.bin"))
	assert.NilError(t, err)

	tmps, err := filepath.Glob(filepath.Join(dir, "data", "kv", "*.tmp"))
	assert.NilError(t, err)
	assert.Equal(t, len(tmps), 0)
}

func TestStoreAuditEmitsNDJSON(t *testing.T) {
	s, err := NewStore(t.TempDir())
	assert.NilError(t, err)

	var buf bytes.Buffer
	s.auditW = &buf
	at := time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return at }

	rec := auditRecord{
		Op:         "write",
		Reason:     "stub",
		Identity:   auditIdentity{Steward: "UVA", User: "u@x", RequestType: "sqlDataRequest"},
		StateClass: "kv",
		StateKey:   "k1",
	}
	assert.NilError(t, s.Audit(rec))

	out := buf.String()
	assert.Assert(t, strings.HasSuffix(out, "\n"))
	assert.Equal(t, strings.Count(out, "\n"), 1)

	var got auditRecord
	assert.NilError(t, json.Unmarshal([]byte(out), &got))
	assert.Equal(t, got.DecidedUnixMicros, at.UnixMicro())
	got.DecidedUnixMicros = 0
	assert.DeepEqual(t, got, rec)
}

func TestStoreAuditStampsDecisionTime(t *testing.T) {
	s, err := NewStore(t.TempDir())
	assert.NilError(t, err)

	var buf bytes.Buffer
	s.auditW = &buf
	at := time.Date(2026, 11, 11, 12, 0, 0, 123456000, time.UTC)
	s.now = func() time.Time { return at }

	assert.NilError(t, s.Audit(auditRecord{Op: "write", Decision: "ALLOW"}))

	want := fmt.Sprintf(`"decidedUnixMicros":%d`, at.UnixMicro())
	assert.Assert(t, strings.Contains(buf.String(), want))
	lines := auditLogLines(t, s)
	assert.Equal(t, len(lines), 1)
	assert.Assert(t, strings.Contains(lines[0], want))
}

func TestStoreAuditDecisionTimeNeverDecreases(t *testing.T) {
	s, err := NewStore(t.TempDir())
	assert.NilError(t, err)
	s.auditW = &bytes.Buffer{}

	base := time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)
	// the wall clock steps back one second between the first two records
	readings := []time.Duration{2 * time.Second, time.Second, 3 * time.Second}
	want := []time.Duration{2 * time.Second, 2 * time.Second, 3 * time.Second}
	s.now = func() time.Time {
		at := base.Add(readings[0])
		readings = readings[1:]
		return at
	}

	for range want {
		assert.NilError(t, s.Audit(auditRecord{Op: "write"}))
	}

	lines := auditLogLines(t, s)
	assert.Equal(t, len(lines), len(want))
	for i, line := range lines {
		var got auditRecord
		assert.NilError(t, json.Unmarshal([]byte(line), &got))
		assert.Equal(t, got.DecidedUnixMicros, base.Add(want[i]).UnixMicro())
	}
}

func TestStoreConcurrentWritesOneKey(t *testing.T) {
	s, err := NewStore(t.TempDir())
	assert.NilError(t, err)

	const n = 100
	payloads := make([][]byte, n)
	for i := range payloads {
		payloads[i] = []byte(fmt.Sprintf("payload-%03d", i)) // fixed width; a torn write would not match any
	}

	errs := make(chan error, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs <- s.Write("kv", "hot", payloads[i])
		}(i)
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		assert.NilError(t, e)
	}

	got, err := s.Read("kv", "hot")
	assert.NilError(t, err)

	found := false
	for _, p := range payloads {
		if string(got) == string(p) {
			found = true
			break
		}
	}
	assert.Assert(t, found)
}
