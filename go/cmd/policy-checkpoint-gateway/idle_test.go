package main

import (
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

// idleTestConfig is the idle form's configuration for the relation of
// sweepAgreement: an identity without job fields.
func idleTestConfig(stateDir string, pollInterval time.Duration) gatewayConfig {
	return gatewayConfig{
		identity:     &pb.Identity{Steward: "UVA", User: "u@x", RequestType: "sqlDataRequest"},
		stateDir:     stateDir,
		pollInterval: pollInterval,
		maxStaleness: 60 * time.Second,
	}
}

func seedState(t *testing.T, stateDir, class, key string, age time.Duration) {
	t.Helper()
	classDir := filepath.Join(stateDir, "data", class)
	assert.NilError(t, os.MkdirAll(classDir, 0o755))
	path := filepath.Join(classDir, key+".bin")
	assert.NilError(t, os.WriteFile(path, []byte("a"), 0o644))
	past := time.Now().Add(-age)
	assert.NilError(t, os.Chtimes(path, past, past))
}

func stateExists(stateDir, class, key string) bool {
	_, err := os.Stat(filepath.Join(stateDir, "data", class, key+".bin"))
	return err == nil
}

func auditFileLines(t *testing.T, stateDir string) []string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(stateDir, "audit", "audit.log"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	assert.NilError(t, err)
	if len(b) == 0 {
		return nil
	}
	return strings.Split(strings.TrimRight(string(b), "\n"), "\n")
}

type idleResult struct {
	empty bool
	err   error
}

// startIdle runs the idle form in the background; the returned channel
// delivers its result once it returns.
func startIdle(cfg gatewayConfig, src agreementSource, stop <-chan struct{}) <-chan idleResult {
	done := make(chan idleResult, 1)
	go func() {
		empty, err := runIdle(cfg, src, 50*time.Millisecond, stop)
		done <- idleResult{empty: empty, err: err}
	}()
	return done
}

func waitIdle(t *testing.T, done <-chan idleResult) idleResult {
	t.Helper()
	select {
	case res := <-done:
		return res
	case <-time.After(2 * time.Second):
		t.Fatal("idle form did not return in time")
		return idleResult{}
	}
}

func waitPolls(t *testing.T, src *mockSource, n int) {
	t.Helper()
	waitFor(t, 2*time.Second, func() bool {
		src.mu.Lock()
		defer src.mu.Unlock()
		return src.getCalls >= n
	})
}

func TestIdleDeletesDueStateAndReportsEmpty(t *testing.T) {
	tests := []struct {
		name     string
		sd       *api.StateDirectives
		age      time.Duration
		wantLine string
	}{
		{
			name:     "revoked with deletion on revocation",
			sd:       revokedPurge(),
			wantLine: `"op":"purge","decision":"PURGED"`,
		},
		{
			name:     "retention exceeded",
			sd:       allowAll(),
			age:      20 * time.Minute, // retention is 900s
			wantLine: `"op":"expired","decision":"DELETED"`,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			seedState(t, dir, "kv", "k1", tc.age)
			seedState(t, dir, "model", "latest", tc.age)
			src := &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, tc.sd)}}
			stop := make(chan struct{})
			defer close(stop)

			res := waitIdle(t, startIdle(idleTestConfig(dir, time.Hour), src, stop))

			assert.NilError(t, res.err)
			assert.Equal(t, res.empty, true)
			assert.Assert(t, !stateExists(dir, "kv", "k1"))
			assert.Assert(t, !stateExists(dir, "model", "latest"))
			lines := auditFileLines(t, dir)
			assert.Equal(t, len(lines), 2)
			for _, line := range lines {
				assert.Assert(t, strings.Contains(line, tc.wantLine), line)
				assert.Assert(t, strings.Contains(line, `"policySource":"fresh"`), line)
				// an idle record carries the claim's identity and no job
				assert.Assert(t, strings.Contains(line, `"identity":{"steward":"UVA","user":"u@x","requestType":"sqlDataRequest"}`), line)
			}
			out := strings.Join(lines, "\n")
			assert.Assert(t, strings.Contains(out, `"stateKey":"k1"`))
			assert.Assert(t, strings.Contains(out, `"stateKey":"latest"`))
		})
	}
}

func TestIdleKeepsRunningWhileNothingIsDue(t *testing.T) {
	tests := []struct {
		name   string
		getKvs [][]byte
		age    time.Duration
	}{
		{
			name:   "terms prescribe no deletion",
			getKvs: [][]byte{sweepAgreementBytes(t, allowAll())},
		},
		{
			name:   "agreement absent",
			getKvs: nil,
			age:    20 * time.Minute, // past any retention the terms could have carried
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			seedState(t, dir, "kv", "k1", tc.age)
			src := &mockSource{getKvs: tc.getKvs}
			stop := make(chan struct{})
			done := startIdle(idleTestConfig(dir, 10*time.Millisecond), src, stop)

			waitPolls(t, src, 5)

			select {
			case res := <-done:
				t.Fatalf("idle form returned (empty=%v, err=%v) while the volume holds state", res.empty, res.err)
			default:
			}
			assert.Assert(t, stateExists(dir, "kv", "k1"))
			assert.Equal(t, len(auditFileLines(t, dir)), 0)

			close(stop)
			res := waitIdle(t, done)
			assert.NilError(t, res.err)
			assert.Equal(t, res.empty, false)
			assert.Assert(t, stateExists(dir, "kv", "k1"))
		})
	}
}

func TestIdleReturnsAtOnceWhenEmpty(t *testing.T) {
	invalid := revokedPurge()
	invalid.OnRevocation = "freeze"
	tests := []struct {
		name string
		src  *mockSource
	}{
		{
			name: "policy store unreachable",
			src:  &mockSource{getErr: errors.New("etcd down")},
		},
		{
			name: "terms that would be recorded as invalid",
			src:  &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, invalid)}},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			stop := make(chan struct{})
			defer close(stop)

			res := waitIdle(t, startIdle(idleTestConfig(dir, time.Hour), tc.src, stop))

			assert.NilError(t, res.err)
			assert.Equal(t, res.empty, true)
			assert.Equal(t, len(auditFileLines(t, dir)), 0)
		})
	}
}

func TestIdleStopReleasesLock(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, ".lock")
	seedState(t, dir, "kv", "k1", 0)
	src := &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, allowAll())}}
	stop := make(chan struct{})
	done := startIdle(idleTestConfig(dir, time.Hour), src, stop)

	waitPolls(t, src, 1)
	_, err := acquireLock(lockPath)
	assert.Assert(t, err != nil) // held by the idle form

	close(stop)
	start := time.Now()
	res := waitIdle(t, done)
	assert.Assert(t, time.Since(start) < time.Second)
	assert.NilError(t, res.err)
	assert.Equal(t, res.empty, false)

	f, err := acquireLock(lockPath)
	assert.NilError(t, err)
	releaseLock(f)
	assert.Assert(t, stateExists(dir, "kv", "k1"))
}

func TestIdleLockHeldElsewhere(t *testing.T) {
	dir := t.TempDir()
	holder, err := acquireLock(filepath.Join(dir, ".lock"))
	assert.NilError(t, err)
	defer releaseLock(holder)
	seedState(t, dir, "kv", "k1", 0)
	src := &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, revokedPurge())}}
	stop := make(chan struct{})
	defer close(stop)

	res := waitIdle(t, startIdle(idleTestConfig(dir, time.Hour), src, stop))

	assert.Assert(t, errors.Is(res.err, errLockNotAcquired))
	assert.Equal(t, res.empty, false)
	assert.Assert(t, stateExists(dir, "kv", "k1"))
	assert.Equal(t, len(auditFileLines(t, dir)), 0)
}

func TestIdleStopWhileWaitingForLock(t *testing.T) {
	dir := t.TempDir()
	holder, err := acquireLock(filepath.Join(dir, ".lock"))
	assert.NilError(t, err)
	defer releaseLock(holder)
	seedState(t, dir, "kv", "k1", 0)
	src := &mockSource{getKvs: [][]byte{sweepAgreementBytes(t, revokedPurge())}}
	stop := make(chan struct{})
	done := make(chan idleResult, 1)
	go func() {
		empty, err := runIdle(idleTestConfig(dir, time.Hour), src, 10*time.Second, stop)
		done <- idleResult{empty: empty, err: err}
	}()

	time.Sleep(50 * time.Millisecond)
	close(stop)
	start := time.Now()
	res := waitIdle(t, done)
	assert.Assert(t, time.Since(start) < time.Second)
	assert.NilError(t, res.err)
	assert.Equal(t, res.empty, false)
	assert.Assert(t, stateExists(dir, "kv", "k1"))
	assert.Equal(t, len(auditFileLines(t, dir)), 0)
}

func TestLoadIdleConfigNeedsNoPortOrJob(t *testing.T) {
	t.Setenv("DATA_STEWARD_NAME", "UVA")
	t.Setenv("REQUEST_USER", "u@x")
	t.Setenv("REQUEST_TYPE", "sqlDataRequest")
	t.Setenv("STATE_DIR", "/state")
	for _, key := range []string{"GATEWAY_PORT", "JOB_NAME", "LOCAL_JOB_NAME", "REQUEST_JOB_NAME",
		"AGREEMENT_POLL_INTERVAL_SECONDS", "MAX_AGREEMENT_STALENESS_SECONDS"} {
		t.Setenv(key, "")
	}

	cfg := loadIdleConfig()

	assert.Equal(t, cfg.identity.GetSteward(), "UVA")
	assert.Equal(t, cfg.identity.GetUser(), "u@x")
	assert.Equal(t, cfg.identity.GetRequestType(), "sqlDataRequest")
	assert.Equal(t, cfg.identity.GetJobId(), "")
	assert.Equal(t, cfg.identity.GetLocalJobName(), "")
	assert.Equal(t, cfg.stateDir, "/state")
	assert.Equal(t, cfg.port, 0)
	assert.Equal(t, cfg.pollInterval, 30*time.Second)
	assert.Equal(t, cfg.maxStaleness, 60*time.Second)
	assert.Equal(t, cfg.regJobName, "")
}
