package main

import (
	"bytes"
	"context"
	"net"
	"path/filepath"
	"strings"
	"testing"

	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"gotest.tools/assert"
)

func testIdentity() *pb.Identity {
	return &pb.Identity{
		Steward:      "UVA",
		User:         "u@x",
		RequestType:  "sqlDataRequest",
		JobId:        "jobX",
		LocalJobName: "jobX-1",
	}
}

func newTestServer(t *testing.T) (pb.PolicyCheckpointGatewayClient, *gatewayServer) {
	t.Helper()

	store, err := NewStore(t.TempDir())
	assert.NilError(t, err)
	store.auditW = &bytes.Buffer{} // keep audit lines out of test stdout

	g := newGatewayServer(store, testIdentity())

	lis := bufconn.Listen(1024 * 1024)
	srv := grpc.NewServer()
	pb.RegisterPolicyCheckpointGatewayServer(srv, g)
	go func() { _ = srv.Serve(lis) }()

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return lis.DialContext(ctx)
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	assert.NilError(t, err)

	t.Cleanup(func() {
		conn.Close()
		srv.Stop()
	})
	return pb.NewPolicyCheckpointGatewayClient(conn), g
}

func TestRequestStateWriteAllowsAndPersists(t *testing.T) {
	client, g := newTestServer(t)

	resp, err := client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k1", Payload: []byte{1, 2, 3},
	})
	assert.NilError(t, err)
	assert.Assert(t, resp.GetAllowed())

	got, err := g.store.Read("kv", "k1")
	assert.NilError(t, err)
	assert.Equal(t, string(got), string([]byte{1, 2, 3}))
}

func TestIdentityMismatchDeniedAndAudited(t *testing.T) {
	client, g := newTestServer(t)

	bad := testIdentity()
	bad.User = "attacker@x"
	_, err := client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: bad, StateClass: "kv", StateKey: "k1", Payload: []byte{1},
	})
	assert.Equal(t, status.Code(err), codes.PermissionDenied)

	buf := g.store.auditW.(*bytes.Buffer)
	g.store.auditMu.Lock()
	out := buf.String()
	g.store.auditMu.Unlock()
	assert.Assert(t, strings.Contains(out, "identity_mismatch"))
}

func TestValidateStateReadExistingAndMissing(t *testing.T) {
	client, _ := newTestServer(t)

	resp, err := client.ValidateStateRead(context.Background(), &pb.StateReadRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "absent",
	})
	assert.NilError(t, err)
	assert.Assert(t, !resp.GetAllowed())
	assert.Equal(t, resp.GetReason(), "not found")

	_, err = client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k1", Payload: []byte("hello"),
	})
	assert.NilError(t, err)

	resp, err = client.ValidateStateRead(context.Background(), &pb.StateReadRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k1",
	})
	assert.NilError(t, err)
	assert.Assert(t, resp.GetAllowed())
	assert.Equal(t, string(resp.GetPayload()), "hello")
}

func TestInvalidNamesInvalidArgument(t *testing.T) {
	client, _ := newTestServer(t)

	_, err := client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: testIdentity(), StateClass: "..", StateKey: "k", Payload: []byte{1},
	})
	assert.Equal(t, status.Code(err), codes.InvalidArgument)
}

func TestSubscribeStateEventsInitialEvent(t *testing.T) {
	client, _ := newTestServer(t)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	stream, err := client.SubscribeStateEvents(ctx, &pb.SubscribeRequest{
		Identity: testIdentity(), SubscriberId: "sub1",
	})
	assert.NilError(t, err)

	ev, err := stream.Recv()
	assert.NilError(t, err)
	assert.Equal(t, ev.GetKind(), pb.StateEvent_AGREEMENT_CHANGED)
}

func TestShutdownClosesStop(t *testing.T) {
	client, g := newTestServer(t)

	_, err := client.Shutdown(context.Background(), &pb.ShutdownRequest{
		Identity: testIdentity(), Reason: "test",
	})
	assert.NilError(t, err)

	select {
	case <-g.stop:
	default:
		t.Fatal("stop channel was not closed by Shutdown")
	}
}

func TestAcquireLockConflict(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".lock")

	f1, err := acquireLock(path)
	assert.NilError(t, err)
	defer releaseLock(f1)

	_, err = acquireLock(path)
	assert.Assert(t, err != nil)
}
