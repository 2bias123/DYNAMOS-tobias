package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	v1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const stateStorageClass = "gateway-state"

// Annotations that stamp a state PVC with the identity it was created for.
const (
	stampDataSteward = "dynamos/data-steward"
	stampRequestUser = "dynamos/request-user"
	stampRequestType = "dynamos/request-type"
)

const selectedNodeAnnotation = "volume.kubernetes.io/selected-node"

var errStampMismatch = errors.New("state PVC is not stamped for this identity")

// pvcStamp is the identity a state PVC belongs to, in the exact strings the
// job's gateway receives as DATA_STEWARD_NAME, REQUEST_USER and REQUEST_TYPE.
// The PVC name does not carry them: it hashes the user and lowercases the
// rest.
type pvcStamp struct {
	dataSteward string
	requestUser string
	requestType string
	// selectedNode is the node the steward's jobs are pinned to, empty when
	// the scheduler places them. It is written on a new PVC only and is not
	// part of the identity: matches does not compare it.
	selectedNode string
}

func newPVCStamp(dataStewardName string, compositionRequest *pb.CompositionRequest) pvcStamp {
	return pvcStamp{
		dataSteward: strings.ToUpper(dataStewardName),
		requestUser: compositionRequest.GetUser().GetUserName(),
		requestType: compositionRequest.RequestType,
	}
}

func (s pvcStamp) annotations() map[string]string {
	annotations := map[string]string{
		stampDataSteward: s.dataSteward,
		stampRequestUser: s.requestUser,
		stampRequestType: s.requestType,
	}
	// A pinned pod bypasses the scheduler, which is what names the node on a
	// WaitForFirstConsumer PVC; without the annotation the PVC never binds.
	if s.selectedNode != "" {
		annotations[selectedNodeAnnotation] = s.selectedNode
	}
	return annotations
}

// matches fails closed: a PVC that lacks an annotation is refused like one
// that carries another value.
func (s pvcStamp) matches(pvc *v1.PersistentVolumeClaim) error {
	want := s.annotations()
	for _, key := range []string{stampDataSteward, stampRequestUser, stampRequestType} {
		got, ok := pvc.Annotations[key]
		if !ok {
			return fmt.Errorf("%w: PVC %s has no annotation %s", errStampMismatch, pvc.Name, key)
		}
		if got != want[key] {
			return fmt.Errorf("%w: PVC %s has %s=%q, want %q", errStampMismatch, pvc.Name, key, got, want[key])
		}
	}
	return nil
}

// pvcClient is the slice of the namespaced PVC API ensureStatePVC needs;
// satisfied by clientSet.CoreV1().PersistentVolumeClaims(namespace).
type pvcClient interface {
	Get(ctx context.Context, name string, opts metav1.GetOptions) (*v1.PersistentVolumeClaim, error)
	Create(ctx context.Context, pvc *v1.PersistentVolumeClaim, opts metav1.CreateOptions) (*v1.PersistentVolumeClaim, error)
}

// statePVCName builds the deterministic identity-tuple PVC name
// state-{steward}-{userhash8}-{requesttype}. The user is hashed because
// emails contain characters invalid in DNS-1123 names; steward and request
// type are lowercased for the same reason. The local job name is deliberately
// not part of the name: its counter suffix changes per request, and the PVC
// must be the same across runs of the same identity tuple.
func statePVCName(steward, user, requestType string) string {
	sum := sha256.Sum256([]byte(user))
	return fmt.Sprintf("state-%s-%s-%s",
		strings.ToLower(steward),
		hex.EncodeToString(sum[:4]),
		strings.ToLower(requestType))
}

// ensureStatePVC gets or creates the identity-tuple PVC. A Pending PVC is
// normal here: the gateway-state StorageClass binds on WaitForFirstConsumer,
// so the claim stays Pending until the gateway pod schedules. A new PVC is
// created with the stamp; one that exists is used only if its stamp matches,
// and is never changed.
func ensureStatePVC(ctx context.Context, pvcs pvcClient, name string, stamp pvcStamp) error {
	existing, err := pvcs.Get(ctx, name, metav1.GetOptions{})
	if err == nil {
		return stamp.matches(existing)
	}
	if !apierrors.IsNotFound(err) {
		return fmt.Errorf("getting PVC %s: %w", name, err)
	}

	storageClass := stateStorageClass
	pvc := &v1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Annotations: stamp.annotations()},
		Spec: v1.PersistentVolumeClaimSpec{
			AccessModes:      []v1.PersistentVolumeAccessMode{v1.ReadWriteOnce},
			StorageClassName: &storageClass,
			Resources: v1.VolumeResourceRequirements{
				Requests: v1.ResourceList{
					v1.ResourceStorage: resource.MustParse("1Gi"),
				},
			},
		},
	}

	_, err = pvcs.Create(ctx, pvc, metav1.CreateOptions{})
	if apierrors.IsAlreadyExists(err) {
		winner, err := pvcs.Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return fmt.Errorf("getting PVC %s after losing the create race: %w", name, err)
		}
		return stamp.matches(winner)
	}
	if err != nil {
		return fmt.Errorf("creating PVC %s: %w", name, err)
	}
	return nil
}
