package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"

	v1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const stateStorageClass = "standard"

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
// normal here: the standard StorageClass binds on WaitForFirstConsumer, so
// the claim stays Pending until the gateway pod schedules.
func ensureStatePVC(ctx context.Context, pvcs pvcClient, name string) error {
	_, err := pvcs.Get(ctx, name, metav1.GetOptions{})
	if err == nil {
		return nil
	}
	if !apierrors.IsNotFound(err) {
		return fmt.Errorf("getting PVC %s: %w", name, err)
	}

	storageClass := stateStorageClass
	pvc := &v1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name},
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
		return nil
	}
	if err != nil {
		return fmt.Errorf("creating PVC %s: %w", name, err)
	}
	return nil
}
