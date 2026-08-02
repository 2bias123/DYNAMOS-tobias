package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/Jorrit05/DYNAMOS/pkg/api"
	clientv3 "go.etcd.io/etcd/client/v3"
)

// agreementSource is the etcd surface the gateway needs; *clientv3.Client
// satisfies it and tests substitute a mock.
type agreementSource interface {
	Get(ctx context.Context, key string, opts ...clientv3.OpOption) (*clientv3.GetResponse, error)
	Watch(ctx context.Context, key string, opts ...clientv3.OpOption) clientv3.WatchChan
}

const (
	agreementKeyPrefix = "/policyEnforcer/agreements/"
	jobRegistrationKey = "/agents/jobs"
	etcdRequestTimeout = 2 * time.Second
	watchReconnectMax  = 30 * time.Second
)

// The agents key etcd with their own DATA_STEWARD_NAME; the stewards that
// deploy gateways use lowercase names, while the gateway env carries the
// uppercased form.
func agreementKey(steward string) string {
	return agreementKeyPrefix + strings.ToLower(steward)
}

// applyAgreementBytes folds one observed agreement value into the cache.
// Bytes that cannot be parsed or hashed clear the cache — a confirmed
// observation that no usable agreement exists fails closed immediately
// rather than riding the previous value toward staleness.
func applyAgreementBytes(b []byte, cache *policyCache) {
	var a api.Agreement
	if err := json.Unmarshal(b, &a); err != nil {
		cache.clear()
		logger.Sugar().Errorw("Unparseable agreement, failing closed", "err", err)
		return
	}
	hash, err := canonicalHash(&a)
	if err != nil {
		cache.clear()
		logger.Sugar().Errorw("Unhashable agreement, failing closed", "err", err)
		return
	}
	old, _ := cache.update(&a, hash)
	switch {
	case old == "":
		logger.Sugar().Infof("Agreement loaded %s", hash)
	case old != hash:
		logger.Sugar().Infof("Agreement changed %s -> %s", old, hash)
	}
}

// refreshAgreement does one bounded Get and folds the result into the cache.
// A read error leaves the cache untouched (it ages toward stale); a
// successful read of an absent key clears it (fail closed on known absence).
func refreshAgreement(src agreementSource, key string, cache *policyCache) {
	ctx, cancel := context.WithTimeout(context.Background(), etcdRequestTimeout)
	defer cancel()
	resp, err := src.Get(ctx, key)
	if err != nil {
		logger.Sugar().Warnw("Agreement refresh failed", "key", key, "err", err)
		return
	}
	if len(resp.Kvs) == 0 {
		if cache.clear() {
			logger.Sugar().Warnf("Agreement %s no longer present, failing closed", key)
		}
		return
	}
	applyAgreementBytes(resp.Kvs[0].Value, cache)
}

// syncAgreement keeps the cache fresh from two directions: a periodic re-Get
// (the liveness mechanism — a healthy watch on an unchanging key delivers
// nothing) and a watch for low-latency change signals. Watch loss degrades to
// poll-only until the reconnect succeeds.
func syncAgreement(stop <-chan struct{}, src agreementSource, key string, cache *policyCache, pollInterval time.Duration) {
	refreshAgreement(src, key, cache)

	// Poll-only mode for the degraded-regime measurement: skip the watch so the
	// only path to a change is the periodic re-Get.
	watchDisabled := os.Getenv("AGREEMENT_WATCH_DISABLED") == "true"
	if watchDisabled {
		logger.Sugar().Warnw("Agreement watch disabled; poll-only regime", "pollInterval", pollInterval)
	}

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	backoff := time.Second
	for {
		var wch clientv3.WatchChan
		wcancel := context.CancelFunc(func() {})
		if !watchDisabled {
			var wctx context.Context
			wctx, wcancel = context.WithCancel(context.Background())
			wch = src.Watch(wctx, key, clientv3.WithProgressNotify())
		}

		watching := true
		for watching {
			select {
			case <-stop:
				wcancel()
				return
			case <-ticker.C:
				refreshAgreement(src, key, cache)
			case resp, ok := <-wch:
				if !ok || resp.Canceled {
					watching = false
					continue
				}
				backoff = time.Second
				if resp.IsProgressNotify() {
					cache.markFresh()
					continue
				}
				for _, ev := range resp.Events {
					switch ev.Type {
					case clientv3.EventTypePut:
						applyAgreementBytes(ev.Kv.Value, cache)
					case clientv3.EventTypeDelete:
						if cache.clear() {
							logger.Sugar().Warnf("Agreement %s deleted, failing closed", key)
						}
					}
				}
			}
		}
		wcancel()

		logger.Sugar().Warnw("Agreement watch lost, reconnecting", "key", key, "backoff", backoff)
		select {
		case <-stop:
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, watchReconnectMax)
	}
}

// verifyRegistration confirms the env-claimed user is the one the agent
// registered for this job. Unverifiable — etcd unreachable or no
// registration — fails closed.
func verifyRegistration(src agreementSource, steward, user, jobName string) error {
	ctx, cancel := context.WithTimeout(context.Background(), etcdRequestTimeout)
	defer cancel()
	key := fmt.Sprintf("%s/%s/%s/%s", jobRegistrationKey, strings.ToLower(steward), user, jobName)
	resp, err := src.Get(ctx, key)
	if err != nil {
		return fmt.Errorf("registration check unavailable: %w", err)
	}
	if len(resp.Kvs) == 0 {
		return fmt.Errorf("no job registration at %s", key)
	}
	return nil
}
