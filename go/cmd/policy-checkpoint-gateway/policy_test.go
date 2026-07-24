package main

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Jorrit05/DYNAMOS/pkg/api"
	"gotest.tools/assert"
)

func testAgreement(sd *api.StateDirectives) *api.Agreement {
	return &api.Agreement{
		Name: "server",
		Relations: map[string]api.Relation{
			"u@x": {
				ID:              "GUID-test",
				RequestTypes:    []string{"vflTrainModelRequest"},
				StateDirectives: sd,
			},
		},
	}
}

func allowAll() *api.StateDirectives {
	return &api.StateDirectives{Allowed: true, RetentionSeconds: 900, ResumeAllowed: true, OnRevocation: "purge"}
}

func TestDecideWrite(t *testing.T) {
	tests := []struct {
		name    string
		agr     *api.Agreement
		src     policySource
		user    string
		allowed bool
		reason  string
	}{
		{"no relation for user", testAgreement(allowAll()), sourceCached, "stranger@x", false, "no relation for user"},
		{"requestType not permitted", &api.Agreement{Relations: map[string]api.Relation{"u@x": {RequestTypes: []string{"other"}, StateDirectives: allowAll()}}}, sourceCached, "u@x", false, "requestType not permitted by relation"},
		{"stateDirectives absent", testAgreement(nil), sourceCached, "u@x", false, "stateDirectives absent"},
		{"allowed false", testAgreement(&api.StateDirectives{Allowed: false}), sourceCached, "u@x", false, "allowed = false"},
		{"allowed fresh", testAgreement(allowAll()), sourceFresh, "u@x", true, ""},
		{"allowed cached", testAgreement(allowAll()), sourceCached, "u@x", true, ""},
		{"allowed but stale", testAgreement(allowAll()), sourceStale, "u@x", false, "cache stale; fail closed"},
		{"allowed but unavailable", nil, sourceUnavailable, "u@x", false, "etcd unreachable; fail closed"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d := decideWrite(tc.agr, "h1", tc.src, 5, tc.user, "vflTrainModelRequest")
			assert.Equal(t, d.Allowed, tc.allowed)
			assert.Equal(t, d.Reason, tc.reason)
			assert.Equal(t, d.Hash, "h1")
			if tc.allowed {
				assert.Equal(t, d.Retention, int64(900))
			}
		})
	}
}

func TestDecideRead(t *testing.T) {
	noResume := allowAll()
	noResume.ResumeAllowed = false

	tests := []struct {
		name    string
		agr     *api.Agreement
		src     policySource
		fileAge time.Duration
		allowed bool
		reason  string
		expired bool
	}{
		{"no relation for user", &api.Agreement{Relations: map[string]api.Relation{"other@x": {RequestTypes: []string{"vflTrainModelRequest"}, StateDirectives: allowAll()}}}, sourceCached, time.Minute, false, "no relation for user", false},
		{"requestType not permitted", &api.Agreement{Relations: map[string]api.Relation{"u@x": {RequestTypes: []string{"other"}, StateDirectives: allowAll()}}}, sourceCached, time.Minute, false, "requestType not permitted by relation", false},
		{"stateDirectives absent", testAgreement(nil), sourceCached, time.Minute, false, "stateDirectives absent", false},
		{"allowed false", testAgreement(&api.StateDirectives{Allowed: false, ResumeAllowed: true}), sourceCached, time.Minute, false, "allowed = false", false},
		{"resume disabled", testAgreement(noResume), sourceCached, time.Minute, false, "resume disabled", false},
		{"within retention cached", testAgreement(allowAll()), sourceCached, 5 * time.Minute, true, "", false},
		{"within retention fresh", testAgreement(allowAll()), sourceFresh, 5 * time.Minute, true, "", false},
		{"retention exceeded fresh", testAgreement(allowAll()), sourceFresh, time.Hour, false, "retention exceeded", true},
		{"retention exceeded cached", testAgreement(allowAll()), sourceCached, time.Hour, false, "retention exceeded", true},
		{"stale", testAgreement(allowAll()), sourceStale, time.Minute, false, "cache stale; fail closed", false},
		{"unavailable", nil, sourceUnavailable, time.Minute, false, "etcd unreachable; fail closed", false},
		// source denial wins over retention: no Expired flag on a stale/unavailable deny
		{"retention exceeded but stale", testAgreement(allowAll()), sourceStale, time.Hour, false, "cache stale; fail closed", false},
		{"retention exceeded but unavailable", nil, sourceUnavailable, time.Hour, false, "etcd unreachable; fail closed", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d := decideRead(tc.agr, "h1", tc.src, 5, "u@x", "vflTrainModelRequest", tc.fileAge)
			assert.Equal(t, d.Allowed, tc.allowed)
			assert.Equal(t, d.Reason, tc.reason)
			assert.Equal(t, d.Expired, tc.expired)
		})
	}

	t.Run("remaining retention decreases with file age", func(t *testing.T) {
		d := decideRead(testAgreement(allowAll()), "h1", sourceCached, 0, "u@x", "vflTrainModelRequest", 300*time.Second)
		assert.Equal(t, d.Retention, int64(600))
	})
}

func TestPolicyCacheSourceProgression(t *testing.T) {
	clock := time.Now()
	p := newPolicyCache(60 * time.Second)
	p.now = func() time.Time { return clock }

	_, _, src, _ := p.snapshot()
	assert.Equal(t, src, sourceUnavailable)

	p.update(testAgreement(allowAll()), "h1")
	_, hash, src, ageMs := p.snapshot()
	assert.Equal(t, src, sourceCached)
	assert.Equal(t, hash, "h1")
	assert.Equal(t, ageMs, int64(0))

	clock = clock.Add(61 * time.Second)
	_, _, src, ageMs = p.snapshot()
	assert.Equal(t, src, sourceStale)
	assert.Equal(t, ageMs, int64(61000))

	p.markFresh()
	_, _, src, _ = p.snapshot()
	assert.Equal(t, src, sourceCached)
}

func TestCanonicalHashIgnoresFormatting(t *testing.T) {
	compact := []byte(`{"name":"server","relations":{"u@x":{"ID":"1","requestTypes":["t"],"stateDirectives":{"allowed":true,"retentionSeconds":900,"resumeAllowed":true,"onRevocation":"purge"}}}}`)
	spaced := []byte(`{
	  "relations": { "u@x": { "stateDirectives": { "onRevocation": "purge", "resumeAllowed": true, "retentionSeconds": 900, "allowed": true }, "requestTypes": [ "t" ], "ID": "1" } },
	  "name": "server"
	}`)

	var a, b api.Agreement
	assert.NilError(t, json.Unmarshal(compact, &a))
	assert.NilError(t, json.Unmarshal(spaced, &b))

	ha, err := canonicalHash(&a)
	assert.NilError(t, err)
	hb, err := canonicalHash(&b)
	assert.NilError(t, err)
	assert.Equal(t, ha, hb)

	changed := a
	rel := changed.Relations["u@x"]
	sd := *rel.StateDirectives
	sd.Allowed = false
	rel.StateDirectives = &sd
	changed.Relations = map[string]api.Relation{"u@x": rel}
	hc, err := canonicalHash(&changed)
	assert.NilError(t, err)
	assert.Assert(t, ha != hc)
}
