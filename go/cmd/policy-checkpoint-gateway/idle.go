package main

import (
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/Jorrit05/DYNAMOS/pkg/etcd"
	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
)

// idleStoppedExitCode is the exit code of an idle gateway that was told to
// stop while the volume still held state.
const idleStoppedExitCode = 143

// loadIdleConfig reads what the idle form needs: the identity the state on
// the volume belongs to, without a job, and no port.
func loadIdleConfig() gatewayConfig {
	return gatewayConfig{
		identity: &pb.Identity{
			Steward:     mustEnv("DATA_STEWARD_NAME"),
			User:        mustEnv("REQUEST_USER"),
			RequestType: mustEnv("REQUEST_TYPE"),
		},
		stateDir:     mustEnv("STATE_DIR"),
		pollInterval: envSeconds("AGREEMENT_POLL_INTERVAL_SECONDS", 30),
		maxStaleness: envSeconds("MAX_AGREEMENT_STALENESS_SECONDS", 60),
	}
}

// stateEmpty reports whether the volume holds no state file. A listing that
// fails counts as not empty.
func stateEmpty(s *Store) bool {
	keys, err := s.ListData()
	return err == nil && len(keys) == 0
}

// runIdle holds the state lock of a volume no job is using and evaluates the
// agreement as the serving gateway does, without listening. It returns true
// once the volume holds no state file and false when stop closes first. The
// lock is released before it returns, and no evaluation runs after that.
func runIdle(cfg gatewayConfig, src agreementSource, lockWindow time.Duration, stop <-chan struct{}) (bool, error) {
	var mu sync.Mutex
	released := false
	empty := make(chan struct{}, 1)
	g, lockFile, err := startGateway(cfg, src, lockWindow, stop, func(g *gatewayServer) {
		mu.Lock()
		defer mu.Unlock()
		if released {
			return
		}
		if !stateEmpty(g.store) {
			g.evaluateDisposition()
		}
		if stateEmpty(g.store) {
			select {
			case empty <- struct{}{}:
			default:
			}
		}
	})
	if err != nil {
		select {
		case <-stop:
			return false, nil
		default:
		}
		return false, err
	}
	defer func() {
		g.closeStop()
		mu.Lock()
		released = true
		mu.Unlock()
		releaseLock(lockFile)
	}()
	go watchLock(g, lockFile, filepath.Join(cfg.stateDir, ".lock"), lockCheckInterval)

	if stateEmpty(g.store) {
		return true, nil
	}
	select {
	case <-empty:
		return true, nil
	case <-stop:
		return false, nil
	}
}

// idleMain runs the idle form and returns the process exit code: 0 only when
// the volume holds no state, so a stop can never read as empty.
func idleMain() int {
	cfg := loadIdleConfig()
	stop := make(chan struct{})
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM)
	go func() {
		<-sigs
		logger.Info("Stop signal received, releasing the state lock")
		close(stop)
	}()

	logger.Sugar().Warn("Idle mode: no listener, agreement sync and disposition evaluation only")
	empty, err := runIdle(cfg, etcd.GetEtcdClient(etcdEndpoints), lockRetryWindow, stop)
	if err != nil {
		logger.Sugar().Fatalf("Failed to start gateway: %v", err)
	}
	if !empty {
		return idleStoppedExitCode
	}
	logger.Info("No state on the volume, exiting")
	return 0
}
