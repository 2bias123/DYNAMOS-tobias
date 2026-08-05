package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Jorrit05/DYNAMOS/pkg/api"
	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	"gotest.tools/assert"
)

// sweepAgreement matches the gateway identity of testIdentity(), unlike
// testAgreement which carries the vfl request type.
func sweepAgreement(sd *api.StateDirectives) *api.Agreement {
	return &api.Agreement{
		Name: "uva",
		Relations: map[string]api.Relation{
			"u@x": {ID: "rel-1", RequestTypes: []string{"sqlDataRequest"}, StateDirectives: sd},
		},
	}
}

func sweepAgreementBytes(t *testing.T, sd *api.StateDirectives) []byte {
	t.Helper()
	b, err := json.Marshal(sweepAgreement(sd))
	assert.NilError(t, err)
	return b
}

func revokedPurge() *api.StateDirectives {
	return &api.StateDirectives{Allowed: false, RetentionSeconds: 900, ResumeAllowed: true, OnRevocation: "purge"}
}

func newSweepServer(t *testing.T) *gatewayServer {
	t.Helper()
	store, err := NewStore(t.TempDir())
	assert.NilError(t, err)
	store.auditW = &bytes.Buffer{}
	g := newGatewayServer(store, testIdentity())
	g.policy = newPolicyCache(60 * time.Second)
	return g
}

func setPolicy(t *testing.T, g *gatewayServer, sd *api.StateDirectives) {
	t.Helper()
	agr := sweepAgreement(sd)
	hash, err := canonicalHash(agr)
	assert.NilError(t, err)
	g.policy.update(agr, hash)
}

func auditOutput(g *gatewayServer) string {
	buf := g.store.auditW.(*bytes.Buffer)
	g.store.auditMu.Lock()
	defer g.store.auditMu.Unlock()
	return buf.String()
}

func TestSweepPurgesRevokedStateAfterConfirm(t *testing.T) {
	g := newSweepServer(t)
	assert.NilError(t, g.store.Write("kv", "k1", []byte("a")))
	assert.NilError(t, g.store.Write("model", "latest", []byte("b")))
	setPolicy(t, g, revokedPurge())
	g.source = &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, revokedPurge())}}

	g.evaluateDisposition()

	for _, k := range []stateKey{{"kv", "k1"}, {"model", "latest"}} {
		_, err := g.store.Read(k.Class, k.Key)
		assert.Assert(t, errors.Is(err, os.ErrNotExist))
	}
	out := auditOutput(g)
	assert.Equal(t, strings.Count(out, `"decision":"PURGED"`), 2)
	assert.Assert(t, strings.Contains(out, `"op":"purge"`))
	assert.Assert(t, strings.Contains(out, `"policySource":"fresh"`))
	assert.Assert(t, strings.Contains(out, `"stateKey":"k1"`))
	assert.Assert(t, strings.Contains(out, `"stateKey":"latest"`))
}

func TestSweepDefersWhenConfirmFails(t *testing.T) {
	g := newSweepServer(t)
	assert.NilError(t, g.store.Write("kv", "k1", []byte("a")))
	setPolicy(t, g, revokedPurge())
	g.source = &mockSource{getErr: errors.New("etcd down")}

	g.evaluateDisposition()
	g.evaluateDisposition() // each reconsideration appends its own line

	_, err := g.store.Read("kv", "k1")
	assert.NilError(t, err) // nothing destroyed on a non-fresh view
	out := auditOutput(g)
	assert.Equal(t, strings.Count(out, `"decision":"DEFERRED"`), 2)
	assert.Assert(t, !strings.Contains(out, `"decision":"PURGED"`))
}

func TestSweepCancelsOnRegrant(t *testing.T) {
	g := newSweepServer(t)
	assert.NilError(t, g.store.Write("kv", "k1", []byte("a")))
	setPolicy(t, g, revokedPurge())
	regrant := &api.StateDirectives{Allowed: true, RetentionSeconds: 900, ResumeAllowed: true, OnRevocation: "purge"}
	g.source = &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, regrant)}}

	g.evaluateDisposition()

	_, err := g.store.Read("kv", "k1")
	assert.NilError(t, err)
	assert.Assert(t, !strings.Contains(auditOutput(g), `"op":"purge"`))
	// the confirming read folded the regrant into the cache
	a, _, _, _ := g.policy.snapshot()
	assert.Equal(t, a.Relations["u@x"].StateDirectives.Allowed, true)
}

func TestSweepRetainsWithoutPurgeDirective(t *testing.T) {
	g := newSweepServer(t)
	assert.NilError(t, g.store.Write("kv", "k1", []byte("a")))
	sd := revokedPurge()
	sd.OnRevocation = "" // deny-but-retain: nothing prescribes destruction
	setPolicy(t, g, sd)
	src := &mockSource{}
	g.source = src

	g.evaluateDisposition()

	_, err := g.store.Read("kv", "k1")
	assert.NilError(t, err)
	assert.Equal(t, src.getCalls, 0) // no confirming read was even attempted
	assert.Equal(t, auditOutput(g), "")
}

func TestSweepInvalidDirectivesAuditedNoPurge(t *testing.T) {
	g := newSweepServer(t)
	assert.NilError(t, g.store.Write("kv", "k1", []byte("a")))
	sd := revokedPurge()
	sd.OnRevocation = "freeze"
	setPolicy(t, g, sd)

	g.evaluateDisposition()
	g.evaluateDisposition() // one record per agreement version

	_, err := g.store.Read("kv", "k1")
	assert.NilError(t, err)
	out := auditOutput(g)
	assert.Equal(t, strings.Count(out, `"op":"invalid_directives"`), 1)
	assert.Assert(t, strings.Contains(out, "freeze"))
	assert.Assert(t, !strings.Contains(out, `"op":"purge"`))
}

func backdate(t *testing.T, g *gatewayServer, class, key string, age time.Duration) {
	t.Helper()
	past := time.Now().Add(-age)
	assert.NilError(t, os.Chtimes(filepath.Join(g.store.dataDir, class, key+".bin"), past, past))
}

func TestSweepDeletesExpiredAfterConfirm(t *testing.T) {
	g := newSweepServer(t)
	assert.NilError(t, g.store.Write("kv", "old", []byte("a")))
	assert.NilError(t, g.store.Write("kv", "young", []byte("b")))
	backdate(t, g, "kv", "old", 20*time.Minute) // retention is 900s
	setPolicy(t, g, allowAll())
	g.source = &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, allowAll())}}

	g.evaluateDisposition()

	_, err := g.store.Read("kv", "old")
	assert.Assert(t, errors.Is(err, os.ErrNotExist))
	_, err = g.store.Read("kv", "young")
	assert.NilError(t, err) // only files past retention are deleted
	out := auditOutput(g)
	assert.Equal(t, strings.Count(out, `"op":"expired"`), 1)
	assert.Assert(t, strings.Contains(out, `"decision":"DELETED"`))
	assert.Assert(t, strings.Contains(out, `"policySource":"fresh"`))
	assert.Assert(t, strings.Contains(out, `"stateKey":"old"`))
}

func TestSweepRetainsExpiredWhenConfirmFails(t *testing.T) {
	g := newSweepServer(t)
	assert.NilError(t, g.store.Write("kv", "old", []byte("a")))
	backdate(t, g, "kv", "old", 20*time.Minute)
	setPolicy(t, g, allowAll())
	g.source = &mockSource{getErr: errors.New("etcd down")}

	g.evaluateDisposition()

	_, err := g.store.Read("kv", "old")
	assert.NilError(t, err) // nothing destroyed on a non-fresh view
	assert.Assert(t, !strings.Contains(auditOutput(g), `"op":"expired"`))
}

func TestBootIntoRevokedPurgesAtStartup(t *testing.T) {
	g := newSweepServer(t)
	assert.NilError(t, g.store.Write("kv", "k1", []byte("a")))
	src := &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, revokedPurge())}}
	g.source = src
	stop := make(chan struct{})
	defer close(stop)

	go syncAgreement(stop, src, agreementKey("UVA"), g.policy, time.Hour, g.evaluateDisposition)

	waitFor(t, time.Second, func() bool {
		_, err := g.store.Read("kv", "k1")
		return err != nil
	})
	assert.Assert(t, strings.Contains(auditOutput(g), `"decision":"PURGED"`))
}

func TestPurgeEventReachesSubscriber(t *testing.T) {
	client, g := newTestServer(t)

	_, err := client.RequestStateWrite(context.Background(), &pb.StateWriteRequest{
		Identity: testIdentity(), StateClass: "kv", StateKey: "k1", Payload: []byte{1},
	})
	assert.NilError(t, err)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream, err := client.SubscribeStateEvents(ctx, &pb.SubscribeRequest{
		Identity: testIdentity(), SubscriberId: "sub1",
	})
	assert.NilError(t, err)
	ev, err := stream.Recv()
	assert.NilError(t, err)
	assert.Equal(t, ev.GetKind(), pb.StateEvent_AGREEMENT_CHANGED)

	setPolicy(t, g, revokedPurge())
	g.source = &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, revokedPurge())}}
	g.evaluateDisposition()

	ev, err = stream.Recv()
	assert.NilError(t, err)
	assert.Equal(t, ev.GetKind(), pb.StateEvent_PURGE)
}
