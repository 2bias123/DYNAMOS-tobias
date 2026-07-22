package main

import (
	"context"
	"errors"
	"regexp"
	"testing"

	"gotest.tools/assert"
	v1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// fakePVCClient is an in-memory pvcClient; the client-go fake clientset is
// unusable here (its testing package needs a go.sum entry for json-patch
// that cannot be added offline).
type fakePVCClient struct {
	pvcs      map[string]*v1.PersistentVolumeClaim
	getErr    error
	createErr error
}

func newFakePVCClient() *fakePVCClient {
	return &fakePVCClient{pvcs: make(map[string]*v1.PersistentVolumeClaim)}
}

func (f *fakePVCClient) Get(_ context.Context, name string, _ metav1.GetOptions) (*v1.PersistentVolumeClaim, error) {
	if f.getErr != nil {
		return nil, f.getErr
	}
	if pvc, ok := f.pvcs[name]; ok {
		return pvc, nil
	}
	return nil, apierrors.NewNotFound(schema.GroupResource{Resource: "persistentvolumeclaims"}, name)
}

func (f *fakePVCClient) Create(_ context.Context, pvc *v1.PersistentVolumeClaim, _ metav1.CreateOptions) (*v1.PersistentVolumeClaim, error) {
	if f.createErr != nil {
		return nil, f.createErr
	}
	if _, ok := f.pvcs[pvc.Name]; ok {
		return nil, apierrors.NewAlreadyExists(schema.GroupResource{Resource: "persistentvolumeclaims"}, pvc.Name)
	}
	f.pvcs[pvc.Name] = pvc
	return pvc, nil
}

func TestStatePVCName(t *testing.T) {
	tests := []struct {
		name        string
		steward     string
		user        string
		requestType string
		want        string
	}{
		{
			name:        "server steward",
			steward:     "server",
			user:        "jake.jongejans@student.uva.nl",
			requestType: "vflTrainModelRequest",
			want:        "state-server-ad751c18-vfltrainmodelrequest",
		},
		{
			name:        "client steward same originating type",
			steward:     "clientone",
			user:        "jake.jongejans@student.uva.nl",
			requestType: "vflTrainModelRequest",
			want:        "state-clientone-ad751c18-vfltrainmodelrequest",
		},
		{
			name:        "uppercase steward and request type lowercased",
			steward:     "UVA",
			user:        "u@x",
			requestType: "sqlDataRequest",
			want:        "state-uva-4ab253d1-sqldatarequest",
		},
	}

	dns1123 := regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := statePVCName(tt.steward, tt.user, tt.requestType)
			assert.Equal(t, got, tt.want)
			assert.Assert(t, dns1123.MatchString(got), "not a DNS-1123 label: %s", got)
			assert.Assert(t, len(got) <= 253)
		})
	}
}

func TestEnsureStatePVC(t *testing.T) {
	ctx := context.Background()
	name := statePVCName("server", "jake.jongejans@student.uva.nl", "vflTrainModelRequest")

	t.Run("creates when absent", func(t *testing.T) {
		f := newFakePVCClient()

		assert.NilError(t, ensureStatePVC(ctx, f, name))

		created, ok := f.pvcs[name]
		assert.Assert(t, ok)
		assert.Equal(t, *created.Spec.StorageClassName, "standard")
		assert.Equal(t, len(created.Spec.AccessModes), 1)
		assert.Equal(t, created.Spec.AccessModes[0], v1.ReadWriteOnce)
		storage := created.Spec.Resources.Requests[v1.ResourceStorage]
		assert.Equal(t, storage.String(), "1Gi")
	})

	t.Run("existing PVC is left untouched", func(t *testing.T) {
		f := newFakePVCClient()
		otherClass := "other"
		f.pvcs[name] = &v1.PersistentVolumeClaim{
			ObjectMeta: metav1.ObjectMeta{Name: name},
			Spec:       v1.PersistentVolumeClaimSpec{StorageClassName: &otherClass},
		}

		assert.NilError(t, ensureStatePVC(ctx, f, name))

		assert.Equal(t, *f.pvcs[name].Spec.StorageClassName, "other")
	})

	t.Run("losing the create race is not an error", func(t *testing.T) {
		f := newFakePVCClient()
		f.createErr = apierrors.NewAlreadyExists(schema.GroupResource{Resource: "persistentvolumeclaims"}, name)

		assert.NilError(t, ensureStatePVC(ctx, f, name))
	})

	t.Run("get failure surfaces as error", func(t *testing.T) {
		f := newFakePVCClient()
		boom := errors.New("apiserver unreachable")
		f.getErr = boom

		err := ensureStatePVC(ctx, f, name)
		assert.Assert(t, err != nil)
		assert.Assert(t, errors.Is(err, boom))
	})

	t.Run("create failure surfaces as error", func(t *testing.T) {
		f := newFakePVCClient()
		boom := errors.New("forbidden")
		f.createErr = boom

		err := ensureStatePVC(ctx, f, name)
		assert.Assert(t, err != nil)
		assert.Assert(t, errors.Is(err, boom))
	})
}
