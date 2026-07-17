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

// gatewayServer is the stub PolicyCheckpointGateway: it verifies identity
// against its injected env and always ALLOWs, with no policy logic yet.
type gatewayServer struct {
	pb.UnimplementedPolicyCheckpointGatewayServer
	store    *Store
	identity *pb.Identity
	stop     chan struct{}
	stopOnce sync.Once
	activity chan struct{}
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

func (g *gatewayServer) RequestStateWrite(ctx context.Context, req *pb.StateWriteRequest) (*pb.StateDecision, error) {
	g.touchActivity()
	if err := g.verifyIdentity(req.GetIdentity()); err != nil {
		return nil, err
	}

	if err := g.store.Write(req.GetStateClass(), req.GetStateKey(), req.GetPayload()); err != nil {
		if errors.Is(err, errInvalidName) {
			return nil, status.Error(codes.InvalidArgument, err.Error())
		}
		logger.Sugar().Errorw("State write failed", "err", err)
		return nil, status.Error(codes.Internal, "state write failed")
	}

	written := time.Now().Unix()
	g.audit(auditRecord{
		Op:                 "write",
		Reason:             "stub",
		Identity:           auditIdentityOf(req.GetIdentity()),
		StateClass:         req.GetStateClass(),
		StateKey:           req.GetStateKey(),
		WrittenUnixSeconds: written,
	})
	return &pb.StateDecision{Allowed: true, Reason: "stub", WrittenUnixSeconds: written}, nil
}

func (g *gatewayServer) ValidateStateRead(ctx context.Context, req *pb.StateReadRequest) (*pb.StateReadResponse, error) {
	g.touchActivity()
	if err := g.verifyIdentity(req.GetIdentity()); err != nil {
		return nil, err
	}

	payload, err := g.store.Read(req.GetStateClass(), req.GetStateKey())
	if err != nil {
		switch {
		case errors.Is(err, os.ErrNotExist):
			g.audit(auditRecord{
				Op:         "read",
				Reason:     "not found",
				Identity:   auditIdentityOf(req.GetIdentity()),
				StateClass: req.GetStateClass(),
				StateKey:   req.GetStateKey(),
			})
			return &pb.StateReadResponse{Allowed: false, Reason: "not found"}, nil
		case errors.Is(err, errInvalidName):
			return nil, status.Error(codes.InvalidArgument, err.Error())
		default:
			logger.Sugar().Errorw("State read failed", "err", err)
			return nil, status.Error(codes.Internal, "state read failed")
		}
	}

	g.audit(auditRecord{
		Op:         "read",
		Reason:     "stub",
		Identity:   auditIdentityOf(req.GetIdentity()),
		StateClass: req.GetStateClass(),
		StateKey:   req.GetStateKey(),
	})
	return &pb.StateReadResponse{Allowed: true, Reason: "stub", Payload: payload}, nil
}

func (g *gatewayServer) SubscribeStateEvents(req *pb.SubscribeRequest, stream pb.PolicyCheckpointGateway_SubscribeStateEventsServer) error {
	g.touchActivity()
	if err := g.verifyIdentity(req.GetIdentity()); err != nil {
		return err
	}

	g.subscribers.Add(1)
	defer func() {
		g.subscribers.Add(-1)
		// restart the inactivity window from the moment the stream closes
		g.touchActivity()
	}()

	if err := stream.Send(&pb.StateEvent{Kind: pb.StateEvent_AGREEMENT_CHANGED, Reason: "stub"}); err != nil {
		return err
	}
	g.audit(auditRecord{Op: "subscribe", Reason: "stub", Identity: auditIdentityOf(req.GetIdentity())})

	select {
	case <-stream.Context().Done():
		return stream.Context().Err()
	case <-g.stop:
		return nil
	}
}

func (g *gatewayServer) Shutdown(ctx context.Context, req *pb.ShutdownRequest) (*emptypb.Empty, error) {
	g.touchActivity()
	if err := g.verifyIdentity(req.GetIdentity()); err != nil {
		return nil, err
	}
	g.audit(auditRecord{Op: "shutdown", Reason: req.GetReason(), Identity: auditIdentityOf(req.GetIdentity())})
	g.closeStop()
	return &emptypb.Empty{}, nil
}
