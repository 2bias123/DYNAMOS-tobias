package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
	"sync"
	"time"

	"github.com/Jorrit05/DYNAMOS/pkg/api"
)

// policySource records how current the agreement behind a decision was.
type policySource string

const (
	sourceFresh  policySource = "fresh"
	sourceCached policySource = "cached"
	sourceStale  policySource = "stale"
	// sourceUnavailable: no agreement view at all — never loaded, or etcd
	// unreachable. sourceAbsent: a fresh observation confirmed there is no
	// usable agreement (deleted key, unparseable bytes). Both deny; the
	// audited reasons differ so a confirmed deletion is not misrecorded as
	// an outage.
	sourceUnavailable policySource = "unavailable"
	sourceAbsent      policySource = "absent"
)

// policyCache holds the last agreement observed for this steward plus its
// freshness bookkeeping. Readings older than maxStaleness fail closed.
type policyCache struct {
	mu            sync.Mutex
	agreement     *api.Agreement
	hash          string
	absent        bool
	lastFreshRead time.Time
	maxStaleness  time.Duration
	now           func() time.Time
}

func newPolicyCache(maxStaleness time.Duration) *policyCache {
	return &policyCache{maxStaleness: maxStaleness, now: time.Now}
}

// update replaces the cached agreement and advances the freshness clock.
// Returns the previous and new hash so callers can log transitions.
func (p *policyCache) update(a *api.Agreement, hash string) (oldHash, newHash string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	oldHash = p.hash
	p.agreement = a
	p.hash = hash
	p.absent = false
	p.lastFreshRead = p.now()
	return oldHash, hash
}

// markFresh advances the freshness clock without changing the cached value
// (a successful re-read or progress notification of an unchanged agreement).
func (p *policyCache) markFresh() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lastFreshRead = p.now()
}

// clear drops the cached agreement: confirmed absence fails closed
// immediately rather than aging out, and is remembered as absent (not
// unavailable) until a later update. Reports whether a value was held.
func (p *policyCache) clear() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	had := p.agreement != nil
	p.agreement = nil
	p.hash = ""
	p.absent = true
	return had
}

// snapshot returns the cached agreement with its provenance for one decision.
func (p *policyCache) snapshot() (a *api.Agreement, hash string, src policySource, ageMs int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.agreement == nil {
		if p.absent {
			return nil, "", sourceAbsent, 0
		}
		return nil, "", sourceUnavailable, 0
	}
	age := p.now().Sub(p.lastFreshRead)
	ageMs = age.Milliseconds()
	if age <= p.maxStaleness {
		return p.agreement, p.hash, sourceCached, ageMs
	}
	return p.agreement, p.hash, sourceStale, ageMs
}

// canonicalHash hashes the agreement as re-marshalled canonical JSON, so the
// version identity does not depend on formatting of the stored bytes.
func canonicalHash(a *api.Agreement) (string, error) {
	b, err := json.Marshal(a)
	if err != nil {
		return "", fmt.Errorf("marshal agreement: %w", err)
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

// directivesFor resolves the StateDirectives governing one user+requestType,
// along with the ID of the relation consulted. A missing relation, unlisted
// request type, or absent directives all deny; the distinct reasons keep the
// audit trail precise.
func directivesFor(a *api.Agreement, user, requestType string) (sd *api.StateDirectives, relationID, reason string) {
	rel, ok := a.Relations[user]
	if !ok {
		return nil, "", "no relation for user"
	}
	if !slices.Contains(rel.RequestTypes, requestType) {
		return nil, rel.ID, "requestType not permitted by relation"
	}
	if rel.StateDirectives == nil {
		return nil, rel.ID, "stateDirectives absent"
	}
	return rel.StateDirectives, rel.ID, ""
}

// decision is the outcome of one policy evaluation, ready for audit.
// RelationID and Directives are set once evaluation reached a relation, on
// denials too, so the record shows the values the decision was made against.
type decision struct {
	Allowed    bool
	Reason     string
	Source     policySource
	Hash       string
	AgeMs      int64
	Retention  int64
	Expired    bool
	RelationID string
	Directives *api.StateDirectives
}

func denySource(src policySource) (string, bool) {
	switch src {
	case sourceStale:
		return "cache stale; fail closed", true
	case sourceUnavailable:
		return "etcd unreachable; fail closed", true
	case sourceAbsent:
		return "agreement confirmed absent; fail closed", true
	}
	return "", false
}

// decideWrite: a write is allowed only when directives exist, permit state,
// and the agreement is fresh or recently cached; everything else denies.
func decideWrite(a *api.Agreement, hash string, src policySource, ageMs int64, user, requestType string) decision {
	d := decision{Source: src, Hash: hash, AgeMs: ageMs}
	if reason, deny := denySource(src); deny {
		d.Reason = reason
		return d
	}
	sd, relID, reason := directivesFor(a, user, requestType)
	d.RelationID = relID
	if sd == nil {
		d.Reason = reason
		return d
	}
	d.Directives = sd
	if err := validateDirectives(sd); err != nil {
		d.Reason = "invalid stateDirectives; fail closed"
		return d
	}
	if !sd.Allowed {
		d.Reason = "allowed = false"
		return d
	}
	d.Allowed = true
	d.Retention = sd.RetentionSeconds
	return d
}

// decideRead: a read additionally requires resume permission and a file still
// within its retention window. An expired file is denied here but not
// deleted — destruction happens elsewhere and only under fresh policy.
func decideRead(a *api.Agreement, hash string, src policySource, ageMs int64, user, requestType string, fileAge time.Duration) decision {
	d := decision{Source: src, Hash: hash, AgeMs: ageMs}
	if reason, deny := denySource(src); deny {
		d.Reason = reason
		return d
	}
	sd, relID, reason := directivesFor(a, user, requestType)
	d.RelationID = relID
	if sd == nil {
		d.Reason = reason
		return d
	}
	d.Directives = sd
	if err := validateDirectives(sd); err != nil {
		d.Reason = "invalid stateDirectives; fail closed"
		return d
	}
	if !sd.Allowed {
		d.Reason = "allowed = false"
		return d
	}
	if !sd.ResumeAllowed {
		d.Reason = "resume disabled"
		return d
	}
	retention := time.Duration(sd.RetentionSeconds) * time.Second
	if fileAge > retention {
		d.Reason = "retention exceeded"
		d.Expired = true
		return d
	}
	d.Allowed = true
	d.Retention = sd.RetentionSeconds - int64(fileAge.Seconds())
	return d
}
