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

	"github.com/Jorrit05/DYNAMOS/pkg/lib"
	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	"go.opencensus.io/plugin/ocgrpc"
	"google.golang.org/grpc"
)

var logger = lib.InitLogger(logLevel)

func newGatewayServer(store *Store, identity *pb.Identity) *gatewayServer {
	return &gatewayServer{
		store:    store,
		identity: identity,
		stop:     make(chan struct{}),
		activity: make(chan struct{}, 1),
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
			logger.Sugar().Infof("Inactivity timeout (%s) reached, stopping gateway", timeout)
			g.closeStop()
			return
		case <-g.stop:
			return
		}
	}
}

type gatewayConfig struct {
	identity   *pb.Identity
	stateDir   string
	port       int
	inactivity time.Duration
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
		stateDir:   mustEnv("STATE_DIR"),
		port:       port,
		inactivity: inactivity,
	}
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

	lockFile, err := acquireLock(filepath.Join(cfg.stateDir, ".lock"))
	if err != nil {
		g.audit(auditRecord{Op: "lock_conflict", Reason: err.Error(), Identity: auditIdentityOf(cfg.identity)})
		logger.Sugar().Fatalf("Failed to acquire state lock: %v", err)
	}

	lis := setupListener(cfg.port)
	grpcServer := setupGRPCServer(g)

	finished := make(chan struct{})
	go stopGateway(grpcServer, g, lockFile, finished)
	go g.inactivityWatch(cfg.inactivity)

	if err := grpcServer.Serve(lis); err != nil {
		logger.Sugar().Fatalw("failed to serve: %v", err)
	}

	<-finished
	logger.Sugar().Infof("Exiting gateway server")
	os.Exit(0)
}
