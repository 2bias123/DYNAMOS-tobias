package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/Jorrit05/DYNAMOS/pkg/etcd"
	"github.com/Jorrit05/DYNAMOS/pkg/lib"
	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	"go.opencensus.io/plugin/ocgrpc"
	"google.golang.org/grpc"
)

var logger = lib.InitLogger(logLevel)

const lockCheckInterval = 10 * time.Second

func newGatewayServer(store *Store, identity *pb.Identity) *gatewayServer {
	return &gatewayServer{
		store:    store,
		identity: identity,
		stop:     make(chan struct{}),
		activity: make(chan struct{}, 1),
		subs:     make(map[chan *pb.StateEvent]struct{}),
	}
}

func (g *gatewayServer) closeStop() {
	g.stopOnce.Do(func() { close(g.stop) })
}

func (g *gatewayServer) touchActivity() {
	select {
	case g.activity <- struct{}{}:
	default:
	}
}

func (g *gatewayServer) inactivityWatch(timeout time.Duration) {
	if timeout <= 0 {
		return
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case <-g.activity:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(timeout)
		case <-timer.C:
			if g.subscribers.Load() > 0 {
				timer.Reset(timeout)
				continue
			}
			logger.Sugar().Infof("Inactivity timeout (%s) reached, stopping gateway", timeout)
			g.closeStop()
			return
		case <-g.stop:
			return
		}
	}
}

type gatewayConfig struct {
	identity     *pb.Identity
	stateDir     string
	port         int
	inactivity   time.Duration
	pollInterval time.Duration
	maxStaleness time.Duration
	regJobName   string
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		logger.Sugar().Fatalf("Required env %s is empty", key)
	}
	return v
}

func loadConfig() gatewayConfig {
	port, err := strconv.Atoi(mustEnv("GATEWAY_PORT"))
	if err != nil {
		logger.Sugar().Fatalf("Invalid GATEWAY_PORT: %v", err)
	}

	inactivity := 300 * time.Second
	if v := os.Getenv("INACTIVITY_TIMEOUT_SECONDS"); v != "" {
		secs, err := strconv.Atoi(v)
		if err != nil {
			logger.Sugar().Fatalf("Invalid INACTIVITY_TIMEOUT_SECONDS: %v", err)
		}
		inactivity = time.Duration(secs) * time.Second
	}

	return gatewayConfig{
		identity: &pb.Identity{
			Steward:      mustEnv("DATA_STEWARD_NAME"),
			User:         mustEnv("REQUEST_USER"),
			RequestType:  mustEnv("REQUEST_TYPE"),
			JobId:        mustEnv("JOB_NAME"),
			LocalJobName: mustEnv("LOCAL_JOB_NAME"),
		},
		stateDir:     mustEnv("STATE_DIR"),
		port:         port,
		inactivity:   inactivity,
		pollInterval: envSeconds("AGREEMENT_POLL_INTERVAL_SECONDS", 30),
		maxStaleness: envSeconds("MAX_AGREEMENT_STALENESS_SECONDS", 60),
		regJobName:   os.Getenv("REQUEST_JOB_NAME"),
	}
}

func envSeconds(key string, def int) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return time.Duration(def) * time.Second
	}
	secs, err := strconv.Atoi(v)
	if err != nil {
		logger.Sugar().Fatalf("Invalid %s: %v", key, err)
	}
	return time.Duration(secs) * time.Second
}

func setupListener(port int) net.Listener {
	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		logger.Sugar().Fatalw("Failed to listen: %v", err)
	}
	logger.Sugar().Infof("Serving on %v", port)
	return lis
}

func setupGRPCServer(g *gatewayServer) *grpc.Server {
	grpcServer := grpc.NewServer(grpc.StatsHandler(&ocgrpc.ServerHandler{}))
	pb.RegisterPolicyCheckpointGatewayServer(grpcServer, g)
	return grpcServer
}

// acquireLock takes an exclusive, non-blocking flock so only one gateway can
// serve a given state volume. A second process on the same volume fails here.
func acquireLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

// lockLost reports whether the held lock no longer guards the state volume.
// A flock cannot be taken from a live fd, but if the lock file is removed or
// replaced, another process can lock the new inode and exclusivity is gone.
// Any stat failure counts as lost.
func lockLost(f *os.File, path string) bool {
	held, err := f.Stat()
	if err != nil {
		return true
	}
	current, err := os.Stat(path)
	if err != nil {
		return true
	}
	return !os.SameFile(held, current)
}

func watchLock(g *gatewayServer, f *os.File, path string, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if lockLost(f, path) {
				g.audit(auditRecord{Op: "lock_lost", Reason: "state lock file removed or replaced", Identity: auditIdentityOf(g.identity)})
				logger.Sugar().Fatalf("State lock lost, exiting")
			}
		case <-g.stop:
			return
		}
	}
}

func releaseLock(f *os.File) {
	if f == nil {
		return
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_UN); err != nil {
		logger.Sugar().Warnw("Failed to release state lock", "err", err)
	}
	f.Close()
}

func stopGateway(s *grpc.Server, g *gatewayServer, lockFile *os.File, finished chan struct{}) {
	<-g.stop
	logger.Info("Stopping gateway, draining briefly before stop")
	time.Sleep(2 * time.Second)
	s.Stop()
	releaseLock(lockFile)
	close(finished)
}

func main() {
	flag.Parse()
	cfg := loadConfig()

	store, err := NewStore(cfg.stateDir)
	if err != nil {
		logger.Sugar().Fatalf("Failed to init store: %v", err)
	}

	g := newGatewayServer(store, cfg.identity)
	g.policy = newPolicyCache(cfg.maxStaleness)
	g.regJobName = cfg.regJobName
	if os.Getenv("GATEWAY_PASSTHROUGH") == "true" {
		g.passthrough = true
		logger.Sugar().Warn("Pass-through mode: decisions and audit only, state writes skipped")
	}
	if os.Getenv("GATEWAY_STORE_ONLY") == "true" {
		if g.passthrough {
			logger.Sugar().Fatalf("GATEWAY_STORE_ONLY and GATEWAY_PASSTHROUGH are mutually exclusive")
		}
		g.storeOnly = true
		logger.Sugar().Warn("Store-only mode: governance and audit skipped, state I/O only")
	}

	etcdClient := etcd.GetEtcdClient(etcdEndpoints)
	g.source = etcdClient
	go syncAgreement(g.stop, etcdClient, agreementKey(cfg.identity.GetSteward()), g.policy, cfg.pollInterval, g.evaluateDisposition)

	lockPath := filepath.Join(cfg.stateDir, ".lock")
	lockFile, err := acquireLock(lockPath)
	if err != nil {
		g.audit(auditRecord{Op: "lock_conflict", Reason: err.Error(), Identity: auditIdentityOf(cfg.identity)})
		logger.Sugar().Fatalf("Failed to acquire state lock: %v", err)
	}

	lis := setupListener(cfg.port)
	grpcServer := setupGRPCServer(g)

	finished := make(chan struct{})
	go stopGateway(grpcServer, g, lockFile, finished)
	go g.inactivityWatch(cfg.inactivity)
	go watchLock(g, lockFile, lockPath, lockCheckInterval)

	if err := grpcServer.Serve(lis); err != nil {
		logger.Sugar().Fatalw("failed to serve: %v", err)
	}

	<-finished
	logger.Sugar().Infof("Exiting gateway server")
	os.Exit(0)
}
