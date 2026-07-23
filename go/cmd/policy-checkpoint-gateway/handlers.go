package main

import (
	"context"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"time"

	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// gatewayServer is the PolicyCheckpointGateway: it verifies identity against
// its injected env and decides each state operation from the cached
// agreement's StateDirectives, failing closed on anything unknown or stale.
type gatewayServer struct {
	pb.UnimplementedPolicyCheckpointGatewayServer
	store    *Store
	identity *pb.Identity
	policy   *policyCache
	// source and regJobName back the one-time job-registration check; either
	// being unset skips the check (local runs without etcd).
	source      agreementSource
	regJobName  string
	registered  atomic.Bool
	regSkipWarn sync.Once
	stop        chan struct{}
	stopOnce    sync.Once
	activity    chan struct{}
	// open SubscribeStateEvents streams; the inactivity timeout must not
	// fire while a dependent MS still holds its event stream
	subscribers atomic.Int64
}

func (g *gatewayServer) audit(rec auditRecord) {
	if err := g.store.Audit(rec); err != nil {
		logger.Sugar().Errorw("Audit write failed", "op", rec.Op, "err", err)
	}
}

func identityEqual(a, b *pb.Identity) bool {
	return a.GetSteward() == b.GetSteward() &&
		a.GetUser() == b.GetUser() &&
		a.GetRequestType() == b.GetRequestType() &&
		a.GetJobId() == b.GetJobId() &&
		a.GetLocalJobName() == b.GetLocalJobName()
}

func auditIdentityOf(id *pb.Identity) auditIdentity {
	return auditIdentity{
		Steward:      id.GetSteward(),
		User:         id.GetUser(),
		RequestType:  id.GetRequestType(),
		JobID:        id.GetJobId(),
		LocalJobName: id.GetLocalJobName(),
	}
}

// verifyIdentity fails closed: a nil or mismatched identity is denied and
// audited before the RPC returns.
func (g *gatewayServer) verifyIdentity(id *pb.Identity) error {
	if identityEqual(id, g.identity) {
		return nil
	}
	g.audit(auditRecord{
		Op:       "identity_mismatch",
		Reason:   "identity does not match gateway env",
		Identity: auditIdentityOf(id),
	})
	return status.Error(codes.PermissionDenied, "identity mismatch")
}

// checkRegistration confirms once per process that the env-claimed user is
// registered for this job in etcd; until it succeeds every RPC re-tries and
// fails closed. Skipped when no etcd source or job name is configured.
func (g *gatewayServer) checkRegistration() error {
	if g.registered.Load() {
		return nil
	}
	if g.source == nil || g.regJobName == "" {
		g.regSkipWarn.Do(func() {
			logger.Sugar().Warn("Job registration check skipped: no etcd source or job name configured")
		})
		return nil
	}
	if err := verifyRegistration(g.source, g.identity.GetSteward(), g.identity.GetUser(), g.regJobName); err != nil {
		return err
	}
	g.registered.Store(true)
	return nil
}

func (g *gatewayServer) authorize(id *pb.Identity) error {
	if err := g.verifyIdentity(id); err != nil {
		return err
	}
	if err := g.checkRegistration(); err != nil {
		g.audit(auditRecord{Op: "identity_unregistered", Reason: err.Error(), Identity: auditIdentityOf(id)})
		return status.Error(codes.PermissionDenied, "identity not registered for this job")
	}
	return nil
}

func decisionRecord(op, verdict string, d decision, class, key string, written int64, id *pb.Identity) auditRecord {
	age := d.AgeMs
	return auditRecord{
		Op:                 op,
		Decision:           verdict,
		Reason:             d.Reason,
		Identity:           auditIdentityOf(id),
		StateClass:         class,
		StateKey:           key,
		WrittenUnixSeconds: written,
		AgreementHash:      d.Hash,
		PolicySource:       string(d.Source),
		CacheAgeMs:         &age,
	}
}

func (g *gatewayServer) auditDecision(op, verdict string, d decision, class, key string, written int64, id *pb.Identity) {
	g.audit(decisionRecord(op, verdict, d, class, key, written, id))
}

func (g *gatewayServer) RequestStateWrite(ctx context.Context, req *pb.StateWriteRequest) (*pb.StateDecision, error) {
	g.touchActivity()
	if err := g.authorize(req.GetIdentity()); err != nil {
		return nil, err
	}

	if err := g.store.ValidateNames(req.GetStateClass(), req.GetStateKey()); err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}

	a, hash, src, ageMs := g.policy.snapshot()
	d := decideWrite(a, hash, src, ageMs, g.identity.GetUser(), g.identity.GetRequestType())
	if !d.Allowed {
		g.auditDecision("write", "DENY", d, req.GetStateClass(), req.GetStateKey(), 0, req.GetIdentity())
		return &pb.StateDecision{Allowed: false, Reason: d.Reason, AgreementHash: d.Hash}, nil
	}

	// The audit record is appended and fsynced before the file appears, so
	// every state file on disk has a preceding audit line. A crash in
	// between leaves a recorded intent, never an unrecorded file; an
	// unappendable audit refuses the write outright.
	written := time.Now().Unix()
	if err := g.store.Audit(decisionRecord("write", "ALLOW", d, req.GetStateClass(), req.GetStateKey(), written, req.GetIdentity())); err != nil {
		logger.Sugar().Errorw("Audit append failed, refusing write", "err", err)
		return nil, status.Error(codes.Internal, "audit unavailable; failing closed")
	}

	if err := g.store.Write(req.GetStateClass(), req.GetStateKey(), req.GetPayload()); err != nil {
		logger.Sugar().Errorw("State write failed", "err", err)
		return nil, status.Error(codes.Internal, "state write failed")
	}

	return &pb.StateDecision{
		Allowed:                   true,
		RetentionSecondsRemaining: d.Retention,
		AgreementHash:             d.Hash,
		WrittenUnixSeconds:        written,
	}, nil
}

func (g *gatewayServer) ValidateStateRead(ctx context.Context, req *pb.StateReadRequest) (*pb.StateReadResponse, error) {
	g.touchActivity()
	if err := g.authorize(req.GetIdentity()); err != nil {
		return nil, err
	}

	writtenAt, statErr := g.store.WrittenAt(req.GetStateClass(), req.GetStateKey())
	if statErr != nil && errors.Is(statErr, errInvalidName) {
		return nil, status.Error(codes.InvalidArgument, statErr.Error())
	}
	missing := statErr != nil && errors.Is(statErr, os.ErrNotExist)
	if statErr != nil && !missing {
		logger.Sugar().Errorw("State stat failed", "err", statErr)
		return nil, status.Error(codes.Internal, "state read failed")
	}
	var fileAge time.Duration
	if !missing {
		fileAge = time.Since(writtenAt)
	}

	// Policy is evaluated before existence so a denial never reveals
	// whether state is present.
	a, hash, src, ageMs := g.policy.snapshot()
	d := decideRead(a, hash, src, ageMs, g.identity.GetUser(), g.identity.GetRequestType(), fileAge)
	if !d.Allowed {
		g.auditDecision("read", "DENY", d, req.GetStateClass(), req.GetStateKey(), 0, req.GetIdentity())
		return &pb.StateReadResponse{Allowed: false, Reason: d.Reason, AgreementHash: d.Hash}, nil
	}
	if missing {
		d.Reason = "not found"
		g.auditDecision("read", "DENY", d, req.GetStateClass(), req.GetStateKey(), 0, req.GetIdentity())
		return &pb.StateReadResponse{Allowed: false, Reason: "not found", AgreementHash: d.Hash}, nil
	}

	payload, err := g.store.Read(req.GetStateClass(), req.GetStateKey())
	if err != nil {
		logger.Sugar().Errorw("State read failed", "err", err)
		return nil, status.Error(codes.Internal, "state read failed")
	}

	g.auditDecision("read", "ALLOW", d, req.GetStateClass(), req.GetStateKey(), writtenAt.Unix(), req.GetIdentity())
	return &pb.StateReadResponse{
		Allowed:                   true,
		Payload:                   payload,
		RetentionSecondsRemaining: d.Retention,
		AgreementHash:             d.Hash,
		WrittenUnixSeconds:        writtenAt.Unix(),
	}, nil
}

func (g *gatewayServer) SubscribeStateEvents(req *pb.SubscribeRequest, stream pb.PolicyCheckpointGateway_SubscribeStateEventsServer) error {
	g.touchActivity()
	if err := g.authorize(req.GetIdentity()); err != nil {
		return err
	}

	g.subscribers.Add(1)
	defer func() {
		g.subscribers.Add(-1)
		// restart the inactivity window from the moment the stream closes
		g.touchActivity()
	}()

	_, hash, src, _ := g.policy.snapshot()
	if err := stream.Send(&pb.StateEvent{Kind: pb.StateEvent_AGREEMENT_CHANGED, Reason: "subscription established"}); err != nil {
		return err
	}
	g.audit(auditRecord{Op: "subscribe", Reason: "subscription established", AgreementHash: hash, PolicySource: string(src), Identity: auditIdentityOf(req.GetIdentity())})

	select {
	case <-stream.Context().Done():
		return stream.Context().Err()
	case <-g.stop:
		return nil
	}
}

func (g *gatewayServer) Shutdown(ctx context.Context, req *pb.ShutdownRequest) (*emptypb.Empty, error) {
	g.touchActivity()
	if err := g.authorize(req.GetIdentity()); err != nil {
		return nil, err
	}
	g.audit(auditRecord{Op: "shutdown", Reason: req.GetReason(), Identity: auditIdentityOf(req.GetIdentity())})
	g.closeStop()
	return &emptypb.Empty{}, nil
}
