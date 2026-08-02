package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"gotest.tools/assert"
)

func auditLogLines(t *testing.T, s *Store) []string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(s.auditDir, "audit.log"))
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

// Every state file on disk must have an ALLOW write audit line for its
// class/key — the invariant the audit-before-rename ordering exists for.
func assertFileImpliesLine(t *testing.T, s *Store) {
	t.Helper()
	lines := strings.Join(auditLogLines(t, s), "\n")
	err := filepath.Walk(s.dataDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".bin") {
			return err
		}
		key := strings.TrimSuffix(filepath.Base(path), ".bin")
		class := filepath.Base(filepath.Dir(path))
		want := `"decision":"ALLOW","identity"`
		if !strings.Contains(lines, `"stateClass":"`+class+`","stateKey":"`+key+`"`) || !strings.Contains(lines, want) {
			t.Fatalf("state file %s/%s has no ALLOW audit line", class, key)
		}
		return nil
	})
	assert.NilError(t, err)
}

func TestWriteProducesLineBeforeFileInvariantHolds(t *testing.T) {
	client, g := newTestServer(t)

	_, err := client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k1", Payload: []byte{1},
	})
	assert.NilError(t, err)
	assertFileImpliesLine(t, g.store)
}

func TestWriteRefusedWhenAuditUnavailable(t *testing.T) {
	client, g := newTestServer(t)
	assert.NilError(t, g.store.auditF.Close()) // audit leg dies

	_, err := client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k1", Payload: []byte{1},
	})
	assert.Equal(t, status.Code(err), codes.Internal)

	_, readErr := g.store.Read("kv", "k1")
	assert.Assert(t, readErr != nil) // no unaudited file
}

func TestReadRefusedWhenAuditUnavailable(t *testing.T) {
	client, g := newTestServer(t)

	_, err := client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k1", Payload: []byte{1},
	})
	assert.NilError(t, err)

	assert.NilError(t, g.store.auditF.Close()) // audit leg dies

	_, err = client.ValidateStateRead(context.Background(), &pb.StateReadRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k1",
	})
	assert.Equal(t, status.Code(err), codes.Internal) // no payload without a record
}

func TestCrashBetweenAuditAndRenameLeavesLineNoFile(t *testing.T) {
	client, g := newTestServer(t)

	// make the data dir unwritable so the rename leg fails after the audit
	// append succeeded — the crash-window shape
	assert.NilError(t, os.Chmod(g.store.dataDir, 0o555))
	t.Cleanup(func() { _ = os.Chmod(g.store.dataDir, 0o755) })

	_, err := client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k-crash", Payload: []byte{1},
	})
	assert.Equal(t, status.Code(err), codes.Internal)

	// recorded intent, no file: the asymmetry is exactly this way around
	lines := strings.Join(auditLogLines(t, g.store), "\n")
	assert.Assert(t, strings.Contains(lines, `"stateKey":"k-crash"`))
	assert.Assert(t, strings.Contains(lines, `"decision":"ALLOW"`))
	_, readErr := g.store.Read("kv", "k-crash")
	assert.Assert(t, readErr != nil)
	assertFileImpliesLine(t, g.store)
}
