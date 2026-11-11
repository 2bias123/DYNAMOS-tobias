package main

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Jorrit05/DYNAMOS/pkg/api"
	"go.etcd.io/etcd/api/v3/mvccpb"
	clientv3 "go.etcd.io/etcd/client/v3"
	"gotest.tools/assert"
)

// mockSource scripts Get responses and lets tests push watch responses.
type mockSource struct {
	mu         sync.Mutex
	getKvs     [][]byte // nil entry = key absent
	getErr     error
	getCalls   int
	watchCalls int
	watchCh    chan clientv3.WatchResponse
}

func (m *mockSource) Get(ctx context.Context, key string, opts ...clientv3.OpOption) (*clientv3.GetResponse, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.getCalls++
	if m.getErr != nil {
		return nil, m.getErr
	}
	resp := &clientv3.GetResponse{}
	if len(m.getKvs) > 0 {
		b := m.getKvs[0]
		if len(m.getKvs) > 1 {
			m.getKvs = m.getKvs[1:]
		}
		if b != nil {
			resp.Kvs = []*mvccpb.KeyValue{{Value: b}}
		}
	}
	return resp, nil
}

func (m *mockSource) Watch(ctx context.Context, key string, opts ...clientv3.OpOption) clientv3.WatchChan {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.watchCalls++
	m.watchCh = make(chan clientv3.WatchResponse)
	return m.watchCh
}

func (m *mockSource) setErr(err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.getErr = err
}

func agreementBytes(t *testing.T, sd *api.StateDirectives) []byte {
	t.Helper()
	b, err := json.Marshal(testAgreement(sd))
	assert.NilError(t, err)
	return b
}

func waitFor(t *testing.T, deadline time.Duration, cond func() bool) {
	t.Helper()
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not reached in time")
}

func TestSyncInitialLoadThenOutageAgesToStale(t *testing.T) {
	src := &mockSource{getKvs: [][]byte{agreementBytes(t, allowAll())}}
	cache := newPolicyCache(60 * time.Second)
	stop := make(chan struct{})
	defer close(stop)

	go syncAgreement(stop, src, agreementKey("SERVER"), cache, time.Hour, nil)

	waitFor(t, time.Second, func() bool { _, _, s, _ := cache.snapshot(); return s == sourceCached })

	// outage: no further refreshes succeed; an aged clock must yield stale
	src.setErr(errors.New("etcd down"))
	cache.mu.Lock()
	cache.lastFreshRead = cache.lastFreshRead.Add(-61 * time.Second)
	cache.mu.Unlock()
	_, _, s, ageMs := cache.snapshot()
	assert.Equal(t, s, sourceStale)
	assert.Assert(t, ageMs >= 61000)
}

func TestSyncColdStartUnavailableUntilFirstRead(t *testing.T) {
	src := &mockSource{getErr: errors.New("etcd down")}
	cache := newPolicyCache(60 * time.Second)
	stop := make(chan struct{})
	defer close(stop)

	go syncAgreement(stop, src, agreementKey("SERVER"), cache, 20*time.Millisecond, nil)

	_, _, s, _ := cache.snapshot()
	assert.Equal(t, s, sourceUnavailable)

	// etcd recovers; the poll ticker must populate the cache
	src.mu.Lock()
	src.getErr = nil
	src.getKvs = [][]byte{agreementBytes(t, allowAll())}
	src.mu.Unlock()
	waitFor(t, time.Second, func() bool { _, _, s, _ := cache.snapshot(); return s == sourceCached })
}

func TestSyncWatchEventUpdatesHash(t *testing.T) {
	src := &mockSource{getKvs: [][]byte{agreementBytes(t, allowAll())}}
	cache := newPolicyCache(60 * time.Second)
	stop := make(chan struct{})
	defer close(stop)

	go syncAgreement(stop, src, agreementKey("SERVER"), cache, time.Hour, nil)
	waitFor(t, time.Second, func() bool { _, h, _, _ := cache.snapshot(); return h != "" })
	_, h1, _, _ := cache.snapshot()

	denied := &api.StateDirectives{Allowed: false, RetentionSeconds: 900, ResumeAllowed: true, OnRevocation: "purge"}
	b, err := json.Marshal(testAgreement(denied))
	assert.NilError(t, err)
	waitFor(t, time.Second, func() bool { src.mu.Lock(); defer src.mu.Unlock(); return src.watchCh != nil })
	src.watchCh <- clientv3.WatchResponse{Events: []*clientv3.Event{
		{Type: clientv3.EventTypePut, Kv: &mvccpb.KeyValue{Value: b}},
	}}

	waitFor(t, time.Second, func() bool { _, h2, _, _ := cache.snapshot(); return h2 != h1 })
	a, _, _, _ := cache.snapshot()
	assert.Equal(t, a.Relations["u@x"].StateDirectives.Allowed, false)
}

func TestSyncDeleteEventFailsClosed(t *testing.T) {
	src := &mockSource{getKvs: [][]byte{agreementBytes(t, allowAll())}}
	cache := newPolicyCache(60 * time.Second)
	stop := make(chan struct{})
	defer close(stop)

	go syncAgreement(stop, src, agreementKey("SERVER"), cache, time.Hour, nil)
	waitFor(t, time.Second, func() bool { _, _, s, _ := cache.snapshot(); return s == sourceCached })

	waitFor(t, time.Second, func() bool { src.mu.Lock(); defer src.mu.Unlock(); return src.watchCh != nil })
	src.watchCh <- clientv3.WatchResponse{Events: []*clientv3.Event{
		{Type: clientv3.EventTypeDelete},
	}}

	// a confirmed deletion reports absent, not unavailable
	waitFor(t, time.Second, func() bool { _, _, s, _ := cache.snapshot(); return s == sourceAbsent })
}

func TestSyncUnparseableAgreementFailsClosed(t *testing.T) {
	src := &mockSource{getKvs: [][]byte{agreementBytes(t, allowAll())}}
	cache := newPolicyCache(60 * time.Second)
	stop := make(chan struct{})
	defer close(stop)

	go syncAgreement(stop, src, agreementKey("SERVER"), cache, time.Hour, nil)
	waitFor(t, time.Second, func() bool { _, _, s, _ := cache.snapshot(); return s == sourceCached })

	// the lineage's policy-removal path writes an empty string over the key
	waitFor(t, time.Second, func() bool { src.mu.Lock(); defer src.mu.Unlock(); return src.watchCh != nil })
	src.watchCh <- clientv3.WatchResponse{Events: []*clientv3.Event{
		{Type: clientv3.EventTypePut, Kv: &mvccpb.KeyValue{Value: []byte("")}},
	}}

	waitFor(t, time.Second, func() bool { _, _, s, _ := cache.snapshot(); return s == sourceAbsent })
}

func TestSyncWatchCancelReconnects(t *testing.T) {
	src := &mockSource{getKvs: [][]byte{agreementBytes(t, allowAll())}}
	cache := newPolicyCache(60 * time.Second)
	stop := make(chan struct{})
	defer close(stop)

	go syncAgreement(stop, src, agreementKey("SERVER"), cache, time.Hour, nil)
	waitFor(t, time.Second, func() bool { src.mu.Lock(); defer src.mu.Unlock(); return src.watchCh != nil })

	src.mu.Lock()
	ch := src.watchCh
	src.mu.Unlock()
	close(ch) // watch loss

	waitFor(t, 5*time.Second, func() bool { src.mu.Lock(); defer src.mu.Unlock(); return src.watchCalls >= 2 })
}

// lostWatchSource hands out watches that are already closed.
type lostWatchSource struct {
	*mockSource
}

func (s *lostWatchSource) Watch(ctx context.Context, key string, opts ...clientv3.OpOption) clientv3.WatchChan {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.watchCalls++
	ch := make(chan clientv3.WatchResponse)
	close(ch)
	return ch
}

func TestSyncPollsWhileWatchReconnects(t *testing.T) {
	src := &lostWatchSource{&mockSource{getKvs: [][]byte{agreementBytes(t, allowAll())}}}
	cache := newPolicyCache(60 * time.Second)
	stop := make(chan struct{})
	defer close(stop)
	var fresh atomic.Int64

	go syncAgreement(stop, src, agreementKey("SERVER"), cache, 10*time.Millisecond, func() { fresh.Add(1) })
	waitFor(t, time.Second, func() bool { src.mu.Lock(); defer src.mu.Unlock(); return src.watchCalls >= 1 })
	reads := func() int { src.mu.Lock(); defer src.mu.Unlock(); return src.getCalls }
	readsAtLoss, freshAtLoss := reads(), fresh.Load()

	// the first reconnect back-off lasts a second; the polls due within it must be served
	end := time.Now().Add(900 * time.Millisecond)
	for time.Now().Before(end) && reads() < readsAtLoss+20 {
		time.Sleep(5 * time.Millisecond)
	}
	assert.Assert(t, reads()-readsAtLoss >= 20, "reads since the watch was lost: %d", reads()-readsAtLoss)
	assert.Assert(t, fresh.Load() > freshAtLoss)
}

func TestVerifyRegistration(t *testing.T) {
	present := &mockSource{getKvs: [][]byte{[]byte(`{"jobName":"job-1"}`)}}
	assert.NilError(t, verifyRegistration(present, "SERVER", "u@x", "job-1"))

	absent := &mockSource{}
	err := verifyRegistration(absent, "SERVER", "u@x", "job-1")
	assert.ErrorContains(t, err, "no job registration at /agents/jobs/server/u@x/job-1")

	down := &mockSource{getErr: errors.New("etcd down")}
	err = verifyRegistration(down, "SERVER", "u@x", "job-1")
	assert.ErrorContains(t, err, "registration check unavailable")
}
