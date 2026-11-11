package main

import (
	"context"
	"errors"
	"reflect"
	"regexp"
	"testing"

	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
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

// racingPVCClient is a fakePVCClient that counts the Create calls. When
// winner is set, the next Create stores it and reports AlreadyExists: another
// creator got in between the Get and the Create.
type racingPVCClient struct {
	*fakePVCClient
	winner  *v1.PersistentVolumeClaim
	creates int
}

func newRacingPVCClient() *racingPVCClient {
	return &racingPVCClient{fakePVCClient: newFakePVCClient()}
}

func (r *racingPVCClient) Create(ctx context.Context, pvc *v1.PersistentVolumeClaim, opts metav1.CreateOptions) (*v1.PersistentVolumeClaim, error) {
	r.creates++
	if r.winner != nil {
		r.pvcs[pvc.Name] = r.winner
		r.winner = nil
	}
	return r.fakePVCClient.Create(ctx, pvc, opts)
}

// stampedAnnotations spells the three annotations out, so that a fixture
// does not depend on pvcStamp.annotations.
func stampedAnnotations(s pvcStamp) map[string]string {
	return map[string]string{
		"dynamos/data-steward": s.dataSteward,
		"dynamos/request-user": s.requestUser,
		"dynamos/request-type": s.requestType,
	}
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
	stamp := pvcStamp{dataSteward: "SERVER", requestUser: "jake.jongejans@student.uva.nl", requestType: "vflTrainModelRequest"}

	t.Run("creates when absent", func(t *testing.T) {
		f := newFakePVCClient()

		assert.NilError(t, ensureStatePVC(ctx, f, name, stamp))

		created, ok := f.pvcs[name]
		assert.Assert(t, ok)
		assert.Equal(t, *created.Spec.StorageClassName, "gateway-state")
		assert.Equal(t, len(created.Spec.AccessModes), 1)
		assert.Equal(t, created.Spec.AccessModes[0], v1.ReadWriteOnce)
		storage := created.Spec.Resources.Requests[v1.ResourceStorage]
		assert.Equal(t, storage.String(), "1Gi")
	})

	t.Run("existing PVC is left untouched", func(t *testing.T) {
		f := newFakePVCClient()
		otherClass := "other"
		f.pvcs[name] = &v1.PersistentVolumeClaim{
			ObjectMeta: metav1.ObjectMeta{Name: name, Annotations: stampedAnnotations(stamp)},
			Spec:       v1.PersistentVolumeClaimSpec{StorageClassName: &otherClass},
		}

		assert.NilError(t, ensureStatePVC(ctx, f, name, stamp))

		assert.Equal(t, *f.pvcs[name].Spec.StorageClassName, "other")
	})

	t.Run("losing the create race is not an error", func(t *testing.T) {
		f := newRacingPVCClient()
		f.winner = &v1.PersistentVolumeClaim{
			ObjectMeta: metav1.ObjectMeta{Name: name, Annotations: stampedAnnotations(stamp)},
		}

		assert.NilError(t, ensureStatePVC(ctx, f, name, stamp))
	})

	t.Run("get failure surfaces as error", func(t *testing.T) {
		f := newFakePVCClient()
		boom := errors.New("apiserver unreachable")
		f.getErr = boom

		err := ensureStatePVC(ctx, f, name, stamp)
		assert.Assert(t, err != nil)
		assert.Assert(t, errors.Is(err, boom))
	})

	t.Run("create failure surfaces as error", func(t *testing.T) {
		f := newFakePVCClient()
		boom := errors.New("forbidden")
		f.createErr = boom

		err := ensureStatePVC(ctx, f, name, stamp)
		assert.Assert(t, err != nil)
		assert.Assert(t, errors.Is(err, boom))
	})
}

func TestNewPVCStamp(t *testing.T) {
	request := &pb.CompositionRequest{
		User:        &pb.User{Id: "1234", UserName: "jake.jongejans@student.uva.nl"},
		RequestType: "vflTrainModelRequest",
		JobName:     "jake-jongejans-1a2b3c4d",
	}

	stamp := newPVCStamp("server", request)

	// The stamp must hold what the job's gateway is given, string for string.
	gatewayEnv := make(map[string]string)
	for _, env := range addGateway("server", "jake-jongejans-1a2b3c4d1", request).Env {
		gatewayEnv[env.Name] = env.Value
	}
	assert.Equal(t, stamp.dataSteward, gatewayEnv["DATA_STEWARD_NAME"])
	assert.Equal(t, stamp.requestUser, gatewayEnv["REQUEST_USER"])
	assert.Equal(t, stamp.requestType, gatewayEnv["REQUEST_TYPE"])
	assert.DeepEqual(t, stamp.annotations(), map[string]string{
		"dynamos/data-steward": "SERVER",
		"dynamos/request-user": "jake.jongejans@student.uva.nl",
		"dynamos/request-type": "vflTrainModelRequest",
	})
}

func TestEnsureStatePVCStamp(t *testing.T) {
	ctx := context.Background()
	stamp := pvcStamp{dataSteward: "SERVER", requestUser: "jake.jongejans@student.uva.nl", requestType: "vflTrainModelRequest"}
	name := statePVCName("server", stamp.requestUser, stamp.requestType)
	stamped := func(s pvcStamp) *v1.PersistentVolumeClaim {
		return &v1.PersistentVolumeClaim{
			ObjectMeta: metav1.ObjectMeta{Name: name, Annotations: stampedAnnotations(s)},
		}
	}

	t.Run("created with the stamp", func(t *testing.T) {
		f := newFakePVCClient()

		assert.NilError(t, ensureStatePVC(ctx, f, name, stamp))

		assert.DeepEqual(t, f.pvcs[name].Annotations, stampedAnnotations(stamp))
	})

	t.Run("equal stamp is accepted and the PVC left as it is", func(t *testing.T) {
		f := newRacingPVCClient()
		existing := stamped(stamp)
		existing.Annotations["volume.kubernetes.io/selected-node"] = "node-a"
		want := existing.DeepCopy()
		f.pvcs[name] = existing

		assert.NilError(t, ensureStatePVC(ctx, f, name, stamp))

		assert.Assert(t, f.pvcs[name] == existing)
		assert.Assert(t, reflect.DeepEqual(existing, want))
		assert.Equal(t, f.creates, 0)
	})

	withoutUser := stamped(stamp)
	delete(withoutUser.Annotations, "dynamos/request-user")
	refused := []struct {
		name     string
		existing *v1.PersistentVolumeClaim
		field    string
	}{
		{
			name:     "another steward",
			existing: stamped(pvcStamp{dataSteward: "CLIENTONE", requestUser: stamp.requestUser, requestType: stamp.requestType}),
			field:    "dynamos/data-steward",
		},
		{
			name:     "another user",
			existing: stamped(pvcStamp{dataSteward: stamp.dataSteward, requestUser: "someone.else@student.uva.nl", requestType: stamp.requestType}),
			field:    "dynamos/request-user",
		},
		{
			// Differs in case only, so the PVC name is the same.
			name:     "another request type",
			existing: stamped(pvcStamp{dataSteward: stamp.dataSteward, requestUser: stamp.requestUser, requestType: "vfltrainmodelrequest"}),
			field:    "dynamos/request-type",
		},
		{
			name:     "no stamp",
			existing: &v1.PersistentVolumeClaim{ObjectMeta: metav1.ObjectMeta{Name: name}},
			field:    "dynamos/data-steward",
		},
		{
			name:     "stamp without the user",
			existing: withoutUser,
			field:    "dynamos/request-user",
		},
	}
	for _, tt := range refused {
		t.Run("existing PVC refused: "+tt.name, func(t *testing.T) {
			f := newRacingPVCClient()
			want := tt.existing.DeepCopy()
			f.pvcs[name] = tt.existing

			err := ensureStatePVC(ctx, f, name, stamp)

			assert.Assert(t, errors.Is(err, errStampMismatch), "got: %v", err)
			assert.ErrorContains(t, err, tt.field)
			assert.Equal(t, f.creates, 0)
			assert.Assert(t, reflect.DeepEqual(f.pvcs[name], want))
		})
	}

	t.Run("lost create race: the winner's stamp is checked", func(t *testing.T) {
		f := newRacingPVCClient()
		winner := stamped(pvcStamp{dataSteward: stamp.dataSteward, requestUser: "someone.else@student.uva.nl", requestType: stamp.requestType})
		want := winner.DeepCopy()
		f.winner = winner

		err := ensureStatePVC(ctx, f, name, stamp)

		assert.Assert(t, errors.Is(err, errStampMismatch), "got: %v", err)
		assert.ErrorContains(t, err, "dynamos/request-user")
		assert.Equal(t, f.creates, 1)
		assert.Assert(t, reflect.DeepEqual(f.pvcs[name], want))
	})

	t.Run("lost create race: a winner that cannot be read back is refused", func(t *testing.T) {
		f := newFakePVCClient()
		f.createErr = apierrors.NewAlreadyExists(schema.GroupResource{Resource: "persistentvolumeclaims"}, name)

		err := ensureStatePVC(ctx, f, name, stamp)

		assert.Assert(t, err != nil)
		assert.Assert(t, apierrors.IsNotFound(err), "got: %v", err)
	})
}

func TestEnsureStatePVCSelectedNode(t *testing.T) {
	ctx := context.Background()
	stamp := pvcStamp{dataSteward: "SERVER", requestUser: "jake.jongejans@student.uva.nl", requestType: "vflTrainModelRequest"}
	name := statePVCName("server", stamp.requestUser, stamp.requestType)

	t.Run("pinned jobs: the new PVC names the node", func(t *testing.T) {
		f := newFakePVCClient()
		pinned := stamp
		pinned.selectedNode = "server"

		assert.NilError(t, ensureStatePVC(ctx, f, name, pinned))

		want := stampedAnnotations(stamp)
		want["volume.kubernetes.io/selected-node"] = "server"
		assert.DeepEqual(t, f.pvcs[name].Annotations, want)
	})

	t.Run("jobs placed by the scheduler: the new PVC names no node", func(t *testing.T) {
		f := newFakePVCClient()

		assert.NilError(t, ensureStatePVC(ctx, f, name, stamp))

		_, ok := f.pvcs[name].Annotations["volume.kubernetes.io/selected-node"]
		assert.Assert(t, !ok)
	})

	// What a state PVC needs to bind on a rig that pins jobs, as a manifest:
	//
	//   metadata:
	//     name: <name>
	//     annotations: { volume.kubernetes.io/selected-node: "<steward>" }
	//   spec:
	//     accessModes: [ReadWriteOnce]
	//     storageClassName: gateway-state
	//     resources: { requests: { storage: 1Gi } }
	t.Run("pinned jobs: the new PVC is that manifest plus the identity", func(t *testing.T) {
		f := newFakePVCClient()
		pinned := stamp
		pinned.selectedNode = "server"

		assert.NilError(t, ensureStatePVC(ctx, f, name, pinned))

		created := f.pvcs[name].DeepCopy()
		assert.Equal(t, created.Name, name)
		for key := range stampedAnnotations(stamp) {
			delete(created.Annotations, key)
		}
		assert.DeepEqual(t, created.Annotations, map[string]string{"volume.kubernetes.io/selected-node": "server"})
		assert.DeepEqual(t, created.Spec.AccessModes, []v1.PersistentVolumeAccessMode{v1.ReadWriteOnce})
		assert.Equal(t, *created.Spec.StorageClassName, "gateway-state")
		assert.Equal(t, len(created.Spec.Resources.Requests), 1)
		storage := created.Spec.Resources.Requests[v1.ResourceStorage]
		assert.Equal(t, storage.String(), "1Gi")

		// Nothing beyond the manifest's fields is set.
		created.Name = ""
		created.Annotations = nil
		created.Spec.AccessModes = nil
		created.Spec.StorageClassName = nil
		created.Spec.Resources.Requests = nil
		assert.Assert(t, reflect.DeepEqual(created, &v1.PersistentVolumeClaim{}))
	})

	t.Run("existing PVC without the node is accepted and not changed", func(t *testing.T) {
		f := newRacingPVCClient()
		existing := &v1.PersistentVolumeClaim{
			ObjectMeta: metav1.ObjectMeta{Name: name, Annotations: stampedAnnotations(stamp)},
		}
		want := existing.DeepCopy()
		f.pvcs[name] = existing
		pinned := stamp
		pinned.selectedNode = "server"

		assert.NilError(t, ensureStatePVC(ctx, f, name, pinned))

		assert.Assert(t, reflect.DeepEqual(f.pvcs[name], want))
		assert.Equal(t, f.creates, 0)
	})
}
