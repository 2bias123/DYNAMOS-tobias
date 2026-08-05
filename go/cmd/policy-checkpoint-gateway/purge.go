package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"

	"github.com/Jorrit05/DYNAMOS/pkg/api"
)

// The purge sweep is level-triggered: disposition is evaluated against the
// current policy view on every fresh observation (boot refresh, poll tick,
// watch event), never on edge transitions. A revoked agreement with
// OnRevocation "purge" and state on disk purges regardless of how the
// gateway arrived at that view — a mid-run flip, booting into an
// already-revoked agreement, or restarting after a crash mid-purge.

// validateDirectives rejects directive values the gateway cannot interpret;
// destruction must never run on a directive it cannot read. OnRevocation
// admits "" (deny but retain state on revocation) and "purge" only.
func validateDirectives(sd *api.StateDirectives) error {
	if sd.OnRevocation != "" && sd.OnRevocation != "purge" {
		return fmt.Errorf("unknown onRevocation %q", sd.OnRevocation)
	}
	if sd.RetentionSeconds < 0 {
		return fmt.Errorf("negative retentionSeconds %d", sd.RetentionSeconds)
	}
	return nil
}

// evaluateDisposition decides whether the current policy view prescribes
// destroying state, and destroys only after confirmAndPurge re-reads the
// agreement fresh. Anything unreadable — no agreement, no relation, no
// directives, invalid directives — retains state and fails closed.
func (g *gatewayServer) evaluateDisposition() {
	g.sweepMu.Lock()
	defer g.sweepMu.Unlock()

	a, hash, src, ageMs := g.policy.snapshot()
	if a == nil {
		return
	}
	sd, relID, _ := directivesFor(a, g.identity.GetUser(), g.identity.GetRequestType())
	if sd == nil {
		return
	}
	d := decision{Source: src, Hash: hash, AgeMs: ageMs, RelationID: relID, Directives: sd}
	if err := validateDirectives(sd); err != nil {
		g.auditInvalidDirectives(d, err)
		return
	}
	if !sd.Allowed && sd.OnRevocation == "purge" {
		keys, err := g.store.ListData()
		if err != nil {
			logger.Sugar().Errorw("State listing failed during purge evaluation", "err", err)
			return
		}
		if len(keys) > 0 {
			g.confirmAndPurge(d)
		}
		return
	}
	if len(g.expiredKeys(sd.RetentionSeconds)) > 0 {
		g.confirmAndExpire(d)
	}
}

// expiredKeys returns the state files older than the given retention bound.
func (g *gatewayServer) expiredKeys(retentionSeconds int64) []stateKey {
	keys, err := g.store.ListData()
	if err != nil {
		logger.Sugar().Errorw("State listing failed during retention evaluation", "err", err)
		return nil
	}
	var expired []stateKey
	for _, k := range keys {
		at, err := g.store.WrittenAt(k.Class, k.Key)
		if err != nil {
			continue
		}
		if time.Since(at) > time.Duration(retentionSeconds)*time.Second {
			expired = append(expired, k)
		}
	}
	return expired
}

// confirmAndExpire re-reads the agreement before deleting anything past
// retention: the deletion threshold is the confirmed value, so a retention
// change between observation and confirmation acts on current policy — a
// lengthened bound cancels here. An unconfirmable view defers with no
// deletion; the next fresh observation reconsiders. Each deletion appends
// and fsyncs its record before the unlink, like the purge sweep.
func (g *gatewayServer) confirmAndExpire(observed decision) {
	a, hash, err := g.confirmFresh()
	if err != nil {
		logger.Sugar().Warnw("Cannot confirm retention sweep, deferring", "err", err)
		return
	}
	if a == nil {
		return
	}
	sd, relID, _ := directivesFor(a, g.identity.GetUser(), g.identity.GetRequestType())
	if sd == nil || validateDirectives(sd) != nil {
		return
	}

	d := decision{
		Source:     sourceFresh,
		Hash:       hash,
		RelationID: relID,
		Directives: sd,
		Reason:     "retention exceeded",
	}
	deleted := 0
	for _, k := range g.expiredKeys(sd.RetentionSeconds) {
		if err := g.store.Audit(decisionRecord("expired", "DELETED", d, k.Class, k.Key, 0, g.identity)); err != nil {
			logger.Sugar().Errorw("Audit append failed, aborting retention sweep", "err", err)
			return
		}
		if err := g.store.Remove(k.Class, k.Key); err != nil {
			logger.Sugar().Errorw("State remove failed", "class", k.Class, "key", k.Key, "err", err)
			continue
		}
		deleted++
	}
	if deleted > 0 {
		logger.Sugar().Warnf("Deleted %d expired state files (retention %ds)", deleted, sd.RetentionSeconds)
	}
}

// auditInvalidDirectives records one invalid_directives line per agreement
// version; the poll re-observes the same bytes every tick and must not
// repeat the line.
func (g *gatewayServer) auditInvalidDirectives(d decision, err error) {
	if d.Hash == g.lastInvalidHash {
		return
	}
	g.lastInvalidHash = d.Hash
	rec := decisionRecord("invalid_directives", "", d, "", "", 0, g.identity)
	rec.Reason = err.Error()
	g.audit(rec)
}

// confirmFresh does the synchronous Get that must precede any destruction
// and folds the result into the cache. A confirmed absence or unparseable
// value clears the cache and returns a nil agreement (retain); an
// unreachable etcd returns an error (defer).
func (g *gatewayServer) confirmFresh() (*api.Agreement, string, error) {
	if g.source == nil {
		return nil, "", errors.New("no etcd source to confirm against")
	}
	ctx, cancel := context.WithTimeout(context.Background(), etcdRequestTimeout)
	defer cancel()
	resp, err := g.source.Get(ctx, agreementKey(g.identity.GetSteward()))
	if err != nil {
		return nil, "", fmt.Errorf("confirming get failed: %w", err)
	}
	if len(resp.Kvs) == 0 {
		// any destructive directive died with the deleted agreement: retain
		if g.policy.clear() {
			logger.Sugar().Warnf("Agreement gone at confirmation, retaining state")
		}
		return nil, "", nil
	}
	applyAgreementBytes(resp.Kvs[0].Value, g.policy)
	a, hash, _, _ := g.policy.snapshot()
	return a, hash, nil
}

// confirmAndPurge re-reads the agreement synchronously before destroying
// anything: purge acts on current policy, so a revocation regranted since
// the triggering observation cancels here, and an unconfirmable view defers
// with no deletion. Deferral is stateless — the level-triggered evaluation
// reconsiders on the next fresh observation, and every reconsideration that
// still cannot confirm appends its own DEFERRED line.
func (g *gatewayServer) confirmAndPurge(observed decision) {
	a, hash, err := g.confirmFresh()
	if err != nil {
		g.auditPurgeDeferred(observed, err.Error())
		return
	}
	if a == nil {
		return
	}
	sd, relID, _ := directivesFor(a, g.identity.GetUser(), g.identity.GetRequestType())
	if sd == nil || validateDirectives(sd) != nil || sd.Allowed || sd.OnRevocation != "purge" {
		return // current policy no longer prescribes purge: cancelled
	}

	g.purgeAll(decision{
		Source:     sourceFresh,
		Hash:       hash,
		RelationID: relID,
		Directives: sd,
		Reason:     "revoked; onRevocation=purge",
	})
}

func (g *gatewayServer) auditPurgeDeferred(observed decision, why string) {
	rec := decisionRecord("purge", "DEFERRED", observed, "", "", 0, g.identity)
	rec.Reason = why
	g.audit(rec)
}

// purgeAll destroys every state file under data/, appending and fsyncing a
// purge record before each unlink so a deletion can never outrun its record;
// a crash mid-sweep leaves records for what was destroyed and files the
// startup rescan finishes. An unappendable record aborts the sweep before
// its file is touched. The audit path itself is never deleted.
func (g *gatewayServer) purgeAll(d decision) {
	keys, err := g.store.ListData()
	if err != nil {
		logger.Sugar().Errorw("State listing failed during purge", "err", err)
		return
	}
	purged := 0
	for _, k := range keys {
		if err := g.store.Audit(decisionRecord("purge", "PURGED", d, k.Class, k.Key, 0, g.identity)); err != nil {
			logger.Sugar().Errorw("Audit append failed, aborting purge sweep", "err", err)
			return
		}
		if err := g.store.Remove(k.Class, k.Key); err != nil {
			logger.Sugar().Errorw("State remove failed", "class", k.Class, "key", k.Key, "err", err)
			continue
		}
		purged++
	}
	if purged > 0 {
		g.broadcast(&pb.StateEvent{
			Kind:          pb.StateEvent_PURGE,
			Reason:        "agreement revoked; state purged",
			AgreementHash: d.Hash,
		})
		logger.Sugar().Warnf("Purged %d state files under revoked agreement %s", purged, d.Hash)
	}
}
