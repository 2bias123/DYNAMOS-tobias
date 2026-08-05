package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Store persists intermediate state and its audit records under a single
// state directory. In the cluster that directory is the gateway's state
// mount; in tests it is a t.TempDir(). State files live under data/ and the
// audit log under audit/ — any future deletion sweep operates strictly under
// data/ and must never touch the audit path.
type Store struct {
	dataDir  string
	auditDir string
	// Every audit record is dual-written: fsynced to auditF (the durable
	// leg) and mirrored to auditW (stdout for log collection).
	auditF  *os.File
	auditW  io.Writer
	auditMu sync.Mutex
	// locks are process-local. Cross-pod exclusion on the same volume is the
	// gateway's startup flock, not this map.
	locks sync.Map
}

type auditIdentity struct {
	Steward      string `json:"steward,omitempty"`
	User         string `json:"user,omitempty"`
	RequestType  string `json:"requestType,omitempty"`
	JobID        string `json:"jobId,omitempty"`
	LocalJobName string `json:"localJobName,omitempty"`
}

// auditDirectives is the enforced StateDirectives snapshot carried by a
// decision record, so the record stays interpretable after the agreement
// itself is overwritten in etcd. Policy content only — never anything
// derived from a payload.
type auditDirectives struct {
	Allowed          bool   `json:"allowed"`
	RetentionSeconds int64  `json:"retentionSeconds"`
	ResumeAllowed    bool   `json:"resumeAllowed"`
	OnRevocation     string `json:"onRevocation"`
}

type auditRecord struct {
	Op                 string           `json:"op"`
	Decision           string           `json:"decision,omitempty"`
	Reason             string           `json:"reason,omitempty"`
	Identity           auditIdentity    `json:"identity"`
	StateClass         string           `json:"stateClass,omitempty"`
	StateKey           string           `json:"stateKey,omitempty"`
	WrittenUnixSeconds int64            `json:"writtenUnixSeconds,omitempty"`
	AgreementHash      string           `json:"agreementHash,omitempty"`
	PolicySource       string           `json:"policySource,omitempty"`
	CacheAgeMs         *int64           `json:"cacheAgeMs,omitempty"`
	RelationID         string           `json:"relationId,omitempty"`
	Directives         *auditDirectives `json:"directives,omitempty"`
}

// nameRe constrains a state class or key to a single safe path segment: no
// separators, no leading dot, so ".." and absolute paths cannot escape dataDir.
var nameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

var errInvalidName = errors.New("invalid state name")

func NewStore(stateDir string) (*Store, error) {
	s := &Store{
		dataDir:  filepath.Join(stateDir, "data"),
		auditDir: filepath.Join(stateDir, "audit"),
		auditW:   os.Stdout,
	}
	for _, dir := range []string{s.dataDir, s.auditDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("create state dir %s: %w", dir, err)
		}
	}
	f, err := os.OpenFile(filepath.Join(s.auditDir, "audit.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open audit log: %w", err)
	}
	s.auditF = f
	return s, nil
}

// ValidateNames rejects class/key values that are not safe path segments.
func (s *Store) ValidateNames(class, key string) error {
	if !nameRe.MatchString(class) || !nameRe.MatchString(key) {
		return fmt.Errorf("%w: class=%q key=%q", errInvalidName, class, key)
	}
	return nil
}

func (s *Store) keyLock(class, key string) *sync.Mutex {
	mu, _ := s.locks.LoadOrStore(class+"/"+key, &sync.Mutex{})
	return mu.(*sync.Mutex)
}

func (s *Store) Write(class, key string, payload []byte) error {
	if !nameRe.MatchString(class) || !nameRe.MatchString(key) {
		return fmt.Errorf("%w: class=%q key=%q", errInvalidName, class, key)
	}

	mu := s.keyLock(class, key)
	mu.Lock()
	defer mu.Unlock()

	classDir := filepath.Join(s.dataDir, class)
	if err := os.MkdirAll(classDir, 0o755); err != nil {
		return fmt.Errorf("create class dir %s: %w", classDir, err)
	}

	tmp, err := os.CreateTemp(classDir, key+".*.tmp")
	if err != nil {
		return fmt.Errorf("create temp: %w", err)
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(payload); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return fmt.Errorf("write temp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("close temp: %w", err)
	}

	dst := filepath.Join(classDir, key+".bin")
	if err := os.Rename(tmpName, dst); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("rename into place: %w", err)
	}
	return nil
}

// Read returns the stored payload, or an error matching os.ErrNotExist when
// the key was never written.
func (s *Store) Read(class, key string) ([]byte, error) {
	if !nameRe.MatchString(class) || !nameRe.MatchString(key) {
		return nil, fmt.Errorf("%w: class=%q key=%q", errInvalidName, class, key)
	}
	return os.ReadFile(filepath.Join(s.dataDir, class, key+".bin"))
}

// WrittenAt returns when the key was last written, or an error matching
// os.ErrNotExist when it was never written.
func (s *Store) WrittenAt(class, key string) (time.Time, error) {
	if !nameRe.MatchString(class) || !nameRe.MatchString(key) {
		return time.Time{}, fmt.Errorf("%w: class=%q key=%q", errInvalidName, class, key)
	}
	fi, err := os.Stat(filepath.Join(s.dataDir, class, key+".bin"))
	if err != nil {
		return time.Time{}, err
	}
	return fi.ModTime(), nil
}

type stateKey struct {
	Class string
	Key   string
}

// ListData returns the class/key of every state file currently on disk.
func (s *Store) ListData() ([]stateKey, error) {
	classes, err := os.ReadDir(s.dataDir)
	if err != nil {
		return nil, fmt.Errorf("read data dir: %w", err)
	}
	var keys []stateKey
	for _, c := range classes {
		if !c.IsDir() {
			continue
		}
		files, err := os.ReadDir(filepath.Join(s.dataDir, c.Name()))
		if err != nil {
			return nil, fmt.Errorf("read class dir %s: %w", c.Name(), err)
		}
		for _, f := range files {
			name, ok := strings.CutSuffix(f.Name(), ".bin")
			if !ok {
				continue
			}
			keys = append(keys, stateKey{Class: c.Name(), Key: name})
		}
	}
	return keys, nil
}

// Remove deletes one state file, under the same per-key lock writes take.
// It operates strictly under data/ and never touches the audit path.
func (s *Store) Remove(class, key string) error {
	if !nameRe.MatchString(class) || !nameRe.MatchString(key) {
		return fmt.Errorf("%w: class=%q key=%q", errInvalidName, class, key)
	}
	mu := s.keyLock(class, key)
	mu.Lock()
	defer mu.Unlock()
	return os.Remove(filepath.Join(s.dataDir, class, key+".bin"))
}

// Audit emits one NDJSON decision record: appended and fsynced to the audit
// file before the stdout mirror, so a record survives anything that happens
// after it returns. Any failure is the caller's to treat as fatal for
// operations that are about to create state.
func (s *Store) Audit(rec auditRecord) error {
	line, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("marshal audit: %w", err)
	}
	line = append(line, '\n')

	s.auditMu.Lock()
	defer s.auditMu.Unlock()
	if s.auditF != nil {
		if _, err := s.auditF.Write(line); err != nil {
			return fmt.Errorf("append audit: %w", err)
		}
		if err := s.auditF.Sync(); err != nil {
			return fmt.Errorf("fsync audit: %w", err)
		}
	}
	if _, err := s.auditW.Write(line); err != nil {
		return fmt.Errorf("write audit: %w", err)
	}
	return nil
}
