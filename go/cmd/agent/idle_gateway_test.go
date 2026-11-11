package main

import (
	"cmp"
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	"gotest.tools/assert"
	batchv1 "k8s.io/api/batch/v1"
	v1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
)

// podOnPVC is a running pod that mounts the PVC, with one container per name
// and no container status yet.
func podOnPVC(name, pvcName string, containers ...string) v1.Pod {
	pod := v1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: v1.PodSpec{
			RestartPolicy: v1.RestartPolicyOnFailure,
			Volumes: []v1.Volume{{
				Name: "gateway-state",
				VolumeSource: v1.VolumeSource{
					PersistentVolumeClaim: &v1.PersistentVolumeClaimVolumeSource{ClaimName: pvcName},
				},
			}},
		},
		Status: v1.PodStatus{Phase: v1.PodRunning},
	}
	for _, container := range containers {
		pod.Spec.Containers = append(pod.Spec.Containers, v1.Container{Name: container})
	}
	return pod
}

func withState(pod v1.Pod, container string, state v1.ContainerState) v1.Pod {
	pod.Status.ContainerStatuses = append(pod.Status.ContainerStatuses, v1.ContainerStatus{Name: container, State: state})
	return pod
}

func withPhase(pod v1.Pod, phase v1.PodPhase) v1.Pod {
	pod.Status.Phase = phase
	return pod
}

func withRestartPolicy(pod v1.Pod, policy v1.RestartPolicy) v1.Pod {
	pod.Spec.RestartPolicy = policy
	return pod
}

func ownedBy(pod v1.Pod, job batchv1.Job) v1.Pod {
	controller := true
	pod.OwnerReferences = []metav1.OwnerReference{{Kind: "Job", Name: job.Name, UID: job.UID, Controller: &controller}}
	return pod
}

// jobOnPVC is a job whose pod template mounts the PVC; it is unfinished
// unless a condition says otherwise.
func jobOnPVC(name, pvcName string, conditions ...batchv1.JobConditionType) batchv1.Job {
	job := batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: name, UID: types.UID("uid-" + name)},
		Spec:       batchv1.JobSpec{Template: v1.PodTemplateSpec{Spec: podOnPVC("", pvcName).Spec}},
	}
	for _, condition := range conditions {
		job.Status.Conditions = append(job.Status.Conditions, batchv1.JobCondition{Type: condition, Status: v1.ConditionTrue})
	}
	return job
}

func TestGatewayAlive(t *testing.T) {
	const pvcName = "state-server-ad751c18-vfltrainmodelrequest"
	const otherPVC = "state-server-4ab253d1-vfltrainmodelrequest"
	const gateway = "policy-checkpoint-gateway"

	running := v1.ContainerState{Running: &v1.ContainerStateRunning{}}
	waiting := v1.ContainerState{Waiting: &v1.ContainerStateWaiting{Reason: "CrashLoopBackOff"}}
	exited := func(code int32) v1.ContainerState {
		return v1.ContainerState{Terminated: &v1.ContainerStateTerminated{ExitCode: code}}
	}

	chainJob := jobOnPVC("jake-jongejans-1a2b3c4d1", pvcName)
	chainPod := ownedBy(podOnPVC("jake-jongejans-1a2b3c4d1-x7k2p", pvcName, "vfl-train-model-demo", "sidecar", gateway), chainJob)
	idleJob := jobOnPVC("idle-"+pvcName, pvcName)
	idlePod := ownedBy(podOnPVC("idle-"+pvcName+"-9qw4z", pvcName, gateway), idleJob)

	tests := []struct {
		name string
		jobs []batchv1.Job
		pods []v1.Pod
		want bool
	}{
		{
			name: "no pod and no job",
			want: false,
		},
		{
			name: "pending pod with no container status",
			jobs: []batchv1.Job{chainJob},
			pods: []v1.Pod{withPhase(chainPod, v1.PodPending)},
			want: true,
		},
		{
			name: "gateway container running",
			jobs: []batchv1.Job{chainJob},
			pods: []v1.Pod{withState(chainPod, gateway, running)},
			want: true,
		},
		{
			name: "gateway container waiting",
			jobs: []batchv1.Job{chainJob},
			pods: []v1.Pod{withState(chainPod, gateway, waiting)},
			want: true,
		},
		{
			name: "gateway exited cleanly while the pod's other containers run",
			jobs: []batchv1.Job{chainJob},
			pods: []v1.Pod{withState(withState(withState(chainPod, "vfl-train-model-demo", exited(0)), "sidecar", running), gateway, exited(0))},
			want: false,
		},
		{
			name: "gateway failed and the pod restarts on failure",
			jobs: []batchv1.Job{chainJob},
			pods: []v1.Pod{withState(chainPod, gateway, exited(1))},
			want: true,
		},
		{
			name: "gateway failed and the pod never restarts",
			pods: []v1.Pod{withRestartPolicy(withState(podOnPVC("fixture", pvcName, gateway), gateway, exited(1)), v1.RestartPolicyNever)},
			want: false,
		},
		{
			name: "pod succeeded",
			jobs: []batchv1.Job{chainJob},
			pods: []v1.Pod{withPhase(withState(chainPod, gateway, running), v1.PodSucceeded)},
			want: false,
		},
		{
			name: "pod failed",
			jobs: []batchv1.Job{chainJob},
			pods: []v1.Pod{withPhase(withState(chainPod, gateway, exited(1)), v1.PodFailed)},
			want: false,
		},
		{
			name: "running gateway on another PVC",
			jobs: []batchv1.Job{jobOnPVC("jake-jongejans-5e6f7a8b1", otherPVC)},
			pods: []v1.Pod{withState(podOnPVC("jake-jongejans-5e6f7a8b1-k2m9d", otherPVC, gateway), gateway, running)},
			want: false,
		},
		{
			name: "pod on the PVC without a gateway container",
			pods: []v1.Pod{withState(podOnPVC("inspector", pvcName, "inspector"), "inspector", running)},
			want: false,
		},
		{
			name: "unfinished job with no pod yet",
			jobs: []batchv1.Job{chainJob},
			want: true,
		},
		{
			name: "unfinished job with no pod yet, beside another job's pod",
			jobs: []batchv1.Job{chainJob, idleJob},
			pods: []v1.Pod{withPhase(withState(idlePod, gateway, exited(0)), v1.PodSucceeded)},
			want: true,
		},
		{
			name: "unfinished job on another PVC with no pod yet",
			jobs: []batchv1.Job{jobOnPVC("jake-jongejans-5e6f7a8b1", otherPVC)},
			want: false,
		},
		{
			name: "complete job",
			jobs: []batchv1.Job{jobOnPVC("idle-"+pvcName, pvcName, batchv1.JobComplete)},
			want: false,
		},
		{
			name: "failed job",
			jobs: []batchv1.Job{jobOnPVC("idle-"+pvcName, pvcName, batchv1.JobFailed)},
			want: false,
		},
		{
			name: "the idle job's own pod, running",
			jobs: []batchv1.Job{idleJob},
			pods: []v1.Pod{withState(idlePod, gateway, running)},
			want: true,
		},
		{
			name: "finished chain job's pod beside the idle job's running pod",
			jobs: []batchv1.Job{chainJob, idleJob},
			pods: []v1.Pod{withState(chainPod, gateway, exited(0)), withState(idlePod, gateway, running)},
			want: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, gatewayAlive(pvcName, tt.jobs, tt.pods), tt.want)
		})
	}

	// The container looked for is the one addGateway puts into a job.
	request := &pb.CompositionRequest{User: &pb.User{UserName: "jake.jongejans@student.uva.nl"}, RequestType: "vflTrainModelRequest"}
	assert.Equal(t, gatewayContainerName, addGateway("server", "jake-jongejans-1a2b3c4d1", request).Name)
}

func TestIdleGatewayJob(t *testing.T) {
	stamp := pvcStamp{dataSteward: "SERVER", requestUser: "jake.jongejans@student.uva.nl", requestType: "vflTrainModelRequest"}
	pvcName := statePVCName("server", stamp.requestUser, stamp.requestType)
	stamped := func(s pvcStamp) *v1.PersistentVolumeClaim {
		return &v1.PersistentVolumeClaim{
			ObjectMeta: metav1.ObjectMeta{Name: pvcName, Annotations: stampedAnnotations(s)},
		}
	}
	request := &pb.CompositionRequest{User: &pb.User{UserName: stamp.requestUser}, RequestType: stamp.requestType}
	env := func(job *batchv1.Job) map[string]string {
		got := make(map[string]string)
		for _, container := range job.Spec.Template.Spec.Containers {
			for _, e := range container.Env {
				got[e.Name] = e.Value
			}
		}
		return got
	}

	t.Run("the job and its pod", func(t *testing.T) {
		t.Setenv("LOCAL_DEV", "true")

		job, err := idleGatewayJob(stamped(stamp), "server")
		assert.NilError(t, err)

		assert.Equal(t, job.Name, "idle-state-server-ad751c18-vfltrainmodelrequest")
		assert.Equal(t, job.Namespace, "server")
		assert.DeepEqual(t, job.Labels, map[string]string{"dynamos/gateway": "idle"})
		assert.DeepEqual(t, job.Spec.Template.Labels, map[string]string{"dynamos/gateway": "idle"})
		assert.Assert(t, job.Spec.TTLSecondsAfterFinished == nil)
		assert.Assert(t, job.Spec.ActiveDeadlineSeconds == nil)

		spec := job.Spec.Template.Spec
		assert.Equal(t, spec.RestartPolicy, v1.RestartPolicyOnFailure)
		assert.Assert(t, spec.ActiveDeadlineSeconds == nil)
		assert.Assert(t, spec.TerminationGracePeriodSeconds != nil)
		assert.Equal(t, *spec.TerminationGracePeriodSeconds, int64(10))
		assert.Equal(t, spec.NodeName, "")
		assert.Equal(t, len(spec.Volumes), 1)
		assert.Equal(t, spec.Volumes[0].PersistentVolumeClaim.ClaimName, pvcName)
		assert.Assert(t, mountsPVC(spec, pvcName))

		assert.Equal(t, len(spec.Containers), 1)
		container := spec.Containers[0]
		assert.Equal(t, container.Name, "policy-checkpoint-gateway")
		assert.DeepEqual(t, container.Command, []string{"/app/policy-checkpoint-gateway"})
		assert.Equal(t, len(container.Args), 0)
		assert.DeepEqual(t, container.VolumeMounts, []v1.VolumeMount{{Name: spec.Volumes[0].Name, MountPath: "/state"}})
		assert.DeepEqual(t, env(job), map[string]string{
			"DATA_STEWARD_NAME": "SERVER",
			"REQUEST_USER":      "jake.jongejans@student.uva.nl",
			"REQUEST_TYPE":      "vflTrainModelRequest",
			"GATEWAY_IDLE":      "true",
			"STATE_DIR":         "/state",
		})
		assert.Equal(t, len(container.Env), 5)
	})

	t.Run("the identity is the stamp's, string for string", func(t *testing.T) {
		odd := pvcStamp{dataSteward: "Server", requestUser: " Jake.Jongejans@Student.UvA.nl", requestType: "VFLtrainModelRequest"}

		job, err := idleGatewayJob(stamped(odd), "server")
		assert.NilError(t, err)

		got := env(job)
		assert.Equal(t, got["DATA_STEWARD_NAME"], odd.dataSteward)
		assert.Equal(t, got["REQUEST_USER"], odd.requestUser)
		assert.Equal(t, got["REQUEST_TYPE"], odd.requestType)
	})

	t.Run("the identity is what a chain job's gateway is given", func(t *testing.T) {
		job, err := idleGatewayJob(stamped(newPVCStamp("server", request)), "server")
		assert.NilError(t, err)

		gatewayEnv := make(map[string]string)
		for _, e := range addGateway("server", "jake-jongejans-1a2b3c4d1", request).Env {
			gatewayEnv[e.Name] = e.Value
		}
		got := env(job)
		for _, name := range []string{"DATA_STEWARD_NAME", "REQUEST_USER", "REQUEST_TYPE", "STATE_DIR"} {
			assert.Equal(t, got[name], gatewayEnv[name], name)
		}
	})

	images := []struct {
		name       string
		repository string
		tag        string
		want       string
	}{
		{name: "defaults", want: "dynamos1/policy-checkpoint-gateway:latest"},
		{name: "repository set", repository: "tamjiyan", want: "tamjiyan/policy-checkpoint-gateway:latest"},
		{name: "repository and tag set", repository: "tamjiyan", tag: "stay-up-enforcement", want: "tamjiyan/policy-checkpoint-gateway:stay-up-enforcement"},
	}
	for _, tt := range images {
		t.Run("the image is the one addGateway resolves: "+tt.name, func(t *testing.T) {
			t.Setenv("MICROSERVICE_REPOSITORY_NAME", tt.repository)
			t.Setenv("POLICY-CHECKPOINT-GATEWAY_TAG", tt.tag)

			job, err := idleGatewayJob(stamped(stamp), "server")
			assert.NilError(t, err)

			chain := addGateway("server", "jake-jongejans-1a2b3c4d1", request)
			assert.Equal(t, len(job.Spec.Template.Spec.Containers), 1)
			assert.Equal(t, job.Spec.Template.Spec.Containers[0].Image, chain.Image)
			assert.Equal(t, job.Spec.Template.Spec.Containers[0].Image, tt.want)
			assert.Equal(t, job.Spec.Template.Spec.Containers[0].ImagePullPolicy, chain.ImagePullPolicy)
		})
	}

	pinned := []struct {
		name     string
		localDev string
		want     string
	}{
		{name: "LOCAL_DEV true", localDev: "true", want: ""},
		{name: "LOCAL_DEV True", localDev: "True", want: ""},
		{name: "LOCAL_DEV false", localDev: "false", want: "server"},
		{name: "LOCAL_DEV empty", localDev: "", want: "server"},
	}
	for _, tt := range pinned {
		t.Run("a node name only when jobs are pinned: "+tt.name, func(t *testing.T) {
			t.Setenv("LOCAL_DEV", tt.localDev)

			job, err := idleGatewayJob(stamped(stamp), "server")
			assert.NilError(t, err)

			assert.Equal(t, job.Name, "idle-"+pvcName)
			assert.Equal(t, job.Spec.Template.Spec.NodeName, tt.want)
		})
	}

	withoutType := stamped(stamp)
	delete(withoutType.Annotations, "dynamos/request-type")
	refused := []struct {
		name  string
		pvc   *v1.PersistentVolumeClaim
		field string
	}{
		{
			name:  "no stamp",
			pvc:   &v1.PersistentVolumeClaim{ObjectMeta: metav1.ObjectMeta{Name: pvcName}},
			field: "dynamos/data-steward",
		},
		{
			name:  "stamp without the request type",
			pvc:   withoutType,
			field: "dynamos/request-type",
		},
	}
	for _, tt := range refused {
		t.Run("PVC refused: "+tt.name, func(t *testing.T) {
			job, err := idleGatewayJob(tt.pvc, "server")

			assert.Assert(t, errors.Is(err, errStampMismatch), "got: %v", err)
			assert.ErrorContains(t, err, tt.field)
			assert.ErrorContains(t, err, pvcName)
			assert.Assert(t, job == nil)
		})
	}
}

// fakeJobClient is an in-memory idleJobClient. Delete marks a job as being
// deleted and leaves it in place, as a job deleted in the foreground stays
// until its pod is gone; a test removes it through afterGet.
type fakeJobClient struct {
	jobs      map[string]*batchv1.Job
	deleted   []string
	policies  []metav1.DeletionPropagation
	gets      int
	deleteErr error
	getErr    error
	afterGet  func(gets int)
	created   []*batchv1.Job
	lists     int
	createErr error
	listErr   error
}

func newFakeJobClient(jobs ...batchv1.Job) *fakeJobClient {
	f := &fakeJobClient{jobs: make(map[string]*batchv1.Job)}
	for _, job := range jobs {
		f.jobs[job.Name] = job.DeepCopy()
	}
	return f
}

func (f *fakeJobClient) Get(_ context.Context, name string, _ metav1.GetOptions) (*batchv1.Job, error) {
	f.gets++
	if f.afterGet != nil {
		defer f.afterGet(f.gets)
	}
	if f.getErr != nil {
		return nil, f.getErr
	}
	if job, ok := f.jobs[name]; ok {
		return job, nil
	}
	return nil, apierrors.NewNotFound(schema.GroupResource{Group: "batch", Resource: "jobs"}, name)
}

func (f *fakeJobClient) Delete(_ context.Context, name string, opts metav1.DeleteOptions) error {
	f.deleted = append(f.deleted, name)
	if opts.PropagationPolicy != nil {
		f.policies = append(f.policies, *opts.PropagationPolicy)
	}
	if f.deleteErr != nil {
		return f.deleteErr
	}
	job, ok := f.jobs[name]
	if !ok {
		return apierrors.NewNotFound(schema.GroupResource{Group: "batch", Resource: "jobs"}, name)
	}
	now := metav1.Now()
	job.DeletionTimestamp = &now
	return nil
}

// List returns the jobs by name.
func (f *fakeJobClient) List(_ context.Context, _ metav1.ListOptions) (*batchv1.JobList, error) {
	f.lists++
	if f.listErr != nil {
		return nil, f.listErr
	}
	list := &batchv1.JobList{}
	for _, job := range f.jobs {
		list.Items = append(list.Items, *job)
	}
	slices.SortFunc(list.Items, func(a, b batchv1.Job) int { return cmp.Compare(a.Name, b.Name) })
	return list, nil
}

// Create refuses a name that is taken, as the API server does.
func (f *fakeJobClient) Create(_ context.Context, job *batchv1.Job, _ metav1.CreateOptions) (*batchv1.Job, error) {
	f.created = append(f.created, job)
	if f.createErr != nil {
		return nil, f.createErr
	}
	if _, ok := f.jobs[job.Name]; ok {
		return nil, apierrors.NewAlreadyExists(schema.GroupResource{Group: "batch", Resource: "jobs"}, job.Name)
	}
	f.jobs[job.Name] = job.DeepCopy()
	return job, nil
}

// fakePVCLister is an in-memory statePVCLister.
type fakePVCLister struct {
	pvcs    []v1.PersistentVolumeClaim
	lists   int
	listErr error
}

func (f *fakePVCLister) List(_ context.Context, _ metav1.ListOptions) (*v1.PersistentVolumeClaimList, error) {
	f.lists++
	if f.listErr != nil {
		return nil, f.listErr
	}
	return &v1.PersistentVolumeClaimList{Items: f.pvcs}, nil
}

// fakePodLister is an in-memory podLister that honours the label selector.
type fakePodLister struct {
	pods      []v1.Pod
	lists     int
	listErr   error
	afterList func(lists int)
}

func (f *fakePodLister) List(_ context.Context, opts metav1.ListOptions) (*v1.PodList, error) {
	f.lists++
	if f.afterList != nil {
		defer f.afterList(f.lists)
	}
	if f.listErr != nil {
		return nil, f.listErr
	}
	selector, err := labels.Parse(opts.LabelSelector)
	if err != nil {
		return nil, err
	}
	list := &v1.PodList{}
	for _, pod := range f.pods {
		if selector.Matches(labels.Set(pod.Labels)) {
			list.Items = append(list.Items, pod)
		}
	}
	return list, nil
}

// podOfJob is a pod as the job controller makes it: owned by the job and
// labelled with the job's name.
func podOfJob(pod v1.Pod, job batchv1.Job) v1.Pod {
	pod = ownedBy(pod, job)
	pod.Labels = map[string]string{"job-name": job.Name, "batch.kubernetes.io/job-name": job.Name}
	return pod
}

func TestStopIdleGateway(t *testing.T) {
	ctx := context.Background()
	const pvcName = "state-server-ad751c18-vfltrainmodelrequest"
	const otherPVC = "state-server-4ab253d1-vfltrainmodelrequest"
	const gateway = "policy-checkpoint-gateway"
	const interval = 10 * time.Millisecond

	idleJob := jobOnPVC("idle-"+pvcName, pvcName)
	idlePod := podOfJob(withState(podOnPVC("idle-"+pvcName+"-9qw4z", pvcName, gateway), gateway, v1.ContainerState{Running: &v1.ContainerStateRunning{}}), idleJob)
	otherJob := jobOnPVC("idle-"+otherPVC, otherPVC)
	otherPod := podOfJob(podOnPVC("idle-"+otherPVC+"-c3v8n", otherPVC, gateway), otherJob)

	t.Run("no idle job: returns at once", func(t *testing.T) {
		jobs := newFakeJobClient()
		pods := &fakePodLister{}

		assert.NilError(t, stopIdleGateway(ctx, jobs, pods, pvcName, time.Minute, time.Minute))

		assert.DeepEqual(t, jobs.deleted, []string{"idle-" + pvcName})
		assert.Equal(t, jobs.gets, 1)
		assert.Equal(t, pods.lists, 1)
	})

	t.Run("idle job present: deleted in the foreground, and gone with its pod at the return", func(t *testing.T) {
		jobs := newFakeJobClient(idleJob, otherJob)
		pods := &fakePodLister{pods: []v1.Pod{idlePod, otherPod}}
		// The pod ends after the second look, the job after the third.
		jobs.afterGet = func(gets int) {
			switch gets {
			case 2:
				pods.pods = []v1.Pod{otherPod}
			case 3:
				delete(jobs.jobs, idleJob.Name)
			}
		}

		assert.NilError(t, stopIdleGateway(ctx, jobs, pods, pvcName, time.Minute, interval))

		assert.DeepEqual(t, jobs.deleted, []string{"idle-" + pvcName})
		assert.DeepEqual(t, jobs.policies, []metav1.DeletionPropagation{metav1.DeletePropagationForeground})
		assert.Equal(t, jobs.gets, 4)
		_, there := jobs.jobs[idleJob.Name]
		assert.Assert(t, !there)

		// Another PVC's idle job and its pod are left alone.
		other, ok := jobs.jobs[otherJob.Name]
		assert.Assert(t, ok)
		assert.Assert(t, other.DeletionTimestamp == nil)
		assert.Equal(t, len(pods.pods), 1)
	})

	t.Run("the job is gone and its pod is not: waits for the pod", func(t *testing.T) {
		jobs := newFakeJobClient()
		pods := &fakePodLister{pods: []v1.Pod{idlePod}}
		pods.afterList = func(lists int) {
			if lists == 2 {
				pods.pods = nil
			}
		}

		assert.NilError(t, stopIdleGateway(ctx, jobs, pods, pvcName, time.Minute, interval))

		assert.Equal(t, pods.lists, 3)
		assert.Equal(t, len(pods.pods), 0)
	})

	stuck := []struct {
		name string
		jobs *fakeJobClient
		pods *fakePodLister
	}{
		{name: "the job never goes", jobs: newFakeJobClient(idleJob), pods: &fakePodLister{pods: []v1.Pod{idlePod}}},
		{name: "the pod never goes", jobs: newFakeJobClient(), pods: &fakePodLister{pods: []v1.Pod{idlePod}}},
	}
	for _, tt := range stuck {
		t.Run(tt.name+": the marked error after the bound", func(t *testing.T) {
			const wait = 200 * time.Millisecond
			start := time.Now()

			err := stopIdleGateway(ctx, tt.jobs, tt.pods, pvcName, wait, interval)

			assert.Assert(t, errors.Is(err, errIdleGatewayNotStopped), "got: %v", err)
			assert.ErrorContains(t, err, "IDLE_GATEWAY_NOT_STOPPED")
			assert.ErrorContains(t, err, "idle-"+pvcName)
			assert.Assert(t, time.Since(start) >= wait)
			assert.Assert(t, time.Since(start) < wait+5*time.Second)
			assert.DeepEqual(t, tt.jobs.deleted, []string{"idle-" + pvcName})
		})
	}

	boom := errors.New("apiserver unreachable")
	failing := []struct {
		name string
		jobs *fakeJobClient
		pods *fakePodLister
	}{
		{name: "delete fails", jobs: &fakeJobClient{deleteErr: boom}, pods: &fakePodLister{}},
		{name: "get fails", jobs: &fakeJobClient{jobs: map[string]*batchv1.Job{}, getErr: boom}, pods: &fakePodLister{}},
		{name: "list fails", jobs: newFakeJobClient(), pods: &fakePodLister{listErr: boom}},
	}
	for _, tt := range failing {
		t.Run(tt.name+": the marked error at once", func(t *testing.T) {
			err := stopIdleGateway(ctx, tt.jobs, tt.pods, pvcName, time.Minute, time.Minute)

			assert.Assert(t, errors.Is(err, errIdleGatewayNotStopped), "got: %v", err)
			assert.Assert(t, errors.Is(err, boom), "got: %v", err)
			assert.ErrorContains(t, err, "IDLE_GATEWAY_NOT_STOPPED")
		})
	}
}

func TestHandOverStatePVC(t *testing.T) {
	ctx := context.Background()
	const pvcName = "state-server-ad751c18-vfltrainmodelrequest"

	// held reports whether idleGatewayMutex is locked, leaving it as it was.
	held := func() bool {
		if idleGatewayMutex.TryLock() {
			idleGatewayMutex.Unlock()
			return false
		}
		return true
	}

	t.Run("the mutex is held from the stop until the release", func(t *testing.T) {
		jobs := newFakeJobClient(jobOnPVC("idle-"+pvcName, pvcName))
		during := false
		jobs.afterGet = func(int) {
			during = held()
			delete(jobs.jobs, "idle-"+pvcName)
		}

		release := handOverStatePVC(ctx, jobs, &fakePodLister{}, pvcName)
		after := held()
		release()

		assert.DeepEqual(t, jobs.deleted, []string{"idle-" + pvcName})
		assert.Assert(t, during)
		assert.Assert(t, after)
		assert.Assert(t, !held())
	})

	t.Run("a stop that fails does not hold the deploy back", func(t *testing.T) {
		jobs := &fakeJobClient{deleteErr: errors.New("apiserver unreachable")}

		release := handOverStatePVC(ctx, jobs, &fakePodLister{}, pvcName)
		after := held()
		release()

		assert.Equal(t, len(jobs.deleted), 1)
		assert.Assert(t, after)
		assert.Assert(t, !held())
	})
}

// statePVC is a state PVC as ensureStatePVC creates it, with the stamp.
func statePVC(name string, stamp pvcStamp) v1.PersistentVolumeClaim {
	storageClass := stateStorageClass
	return v1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: name, Annotations: stampedAnnotations(stamp)},
		Spec:       v1.PersistentVolumeClaimSpec{StorageClassName: &storageClass},
	}
}

func beingDeleted(pvc v1.PersistentVolumeClaim) v1.PersistentVolumeClaim {
	now := metav1.Now()
	pvc.DeletionTimestamp = &now
	return pvc
}

// idleGatewayMutexHeld reports whether idleGatewayMutex is locked, leaving
// it as it was.
func idleGatewayMutexHeld() bool {
	if idleGatewayMutex.TryLock() {
		idleGatewayMutex.Unlock()
		return false
	}
	return true
}

func TestSuperviseStatePVCs(t *testing.T) {
	ctx := context.Background()
	t.Setenv("LOCAL_DEV", "true")
	const gateway = "policy-checkpoint-gateway"

	stamp := pvcStamp{dataSteward: "SERVER", requestUser: "jake.jongejans@student.uva.nl", requestType: "vflTrainModelRequest"}
	otherStamp := pvcStamp{dataSteward: "SERVER", requestUser: "someone.else@example.org", requestType: "vflTrainModelRequest"}
	pvcName := statePVCName("server", stamp.requestUser, stamp.requestType)
	otherName := statePVCName("server", otherStamp.requestUser, otherStamp.requestType)
	pvc := statePVC(pvcName, stamp)
	otherPVC := statePVC(otherName, otherStamp)
	unstamped := statePVC(pvcName, stamp)
	unstamped.Annotations = nil
	otherClass := statePVC(pvcName, stamp)
	standard := "standard"
	otherClass.Spec.StorageClassName = &standard
	noClass := statePVC(pvcName, stamp)
	noClass.Spec.StorageClassName = nil

	running := v1.ContainerState{Running: &v1.ContainerStateRunning{}}
	exited := v1.ContainerState{Terminated: &v1.ContainerStateTerminated{ExitCode: 0}}
	chainJob := jobOnPVC("jake-jongejans-1a2b3c4d1", pvcName)
	chainPod := podOfJob(podOnPVC("jake-jongejans-1a2b3c4d1-x7k2p", pvcName, "vfl-train-model-demo", "sidecar", gateway), chainJob)
	idleJob := jobOnPVC("idle-"+pvcName, pvcName)
	idlePod := podOfJob(podOnPVC("idle-"+pvcName+"-9qw4z", pvcName, gateway), idleJob)
	completeIdleJob := jobOnPVC("idle-"+pvcName, pvcName, batchv1.JobComplete)
	failedIdleJob := jobOnPVC("idle-"+pvcName, pvcName, batchv1.JobFailed)

	boom := errors.New("apiserver unreachable")

	tests := []struct {
		name      string
		pvcs      []v1.PersistentVolumeClaim
		jobs      []batchv1.Job
		pods      []v1.Pod
		createErr error
		deleteErr error
		created   []string
		deleted   []string
		wantErr   error
	}{
		{
			name:    "stamped PVC with no gateway and no idle job: an idle job is created",
			pvcs:    []v1.PersistentVolumeClaim{pvc},
			created: []string{"idle-" + pvcName},
		},
		{
			name:    "a finished chain job's pod is all that is left on the PVC: an idle job is created",
			pvcs:    []v1.PersistentVolumeClaim{pvc},
			jobs:    []batchv1.Job{chainJob},
			pods:    []v1.Pod{withState(chainPod, gateway, exited)},
			created: []string{"idle-" + pvcName},
		},
		{
			name: "a chain job's gateway runs: nothing",
			pvcs: []v1.PersistentVolumeClaim{pvc},
			jobs: []batchv1.Job{chainJob},
			pods: []v1.Pod{withState(chainPod, gateway, running)},
		},
		{
			name: "a chain job has no pod yet: nothing",
			pvcs: []v1.PersistentVolumeClaim{pvc},
			jobs: []batchv1.Job{chainJob},
		},
		{
			name: "the idle job runs: nothing",
			pvcs: []v1.PersistentVolumeClaim{pvc},
			jobs: []batchv1.Job{idleJob},
			pods: []v1.Pod{withState(idlePod, gateway, running)},
		},
		{
			name: "the idle job is unfinished and its gateway has exited: nothing",
			pvcs: []v1.PersistentVolumeClaim{pvc},
			jobs: []batchv1.Job{idleJob},
			pods: []v1.Pod{withState(idlePod, gateway, exited)},
		},
		{
			name: "the idle job is complete: nothing",
			pvcs: []v1.PersistentVolumeClaim{pvc},
			jobs: []batchv1.Job{completeIdleJob},
			pods: []v1.Pod{withPhase(withState(idlePod, gateway, exited), v1.PodSucceeded)},
		},
		{
			name:    "the idle job has failed: it is deleted and none is created in the same pass",
			pvcs:    []v1.PersistentVolumeClaim{pvc},
			jobs:    []batchv1.Job{failedIdleJob},
			deleted: []string{"idle-" + pvcName},
		},
		{
			name:      "the failed idle job cannot be deleted: the error, and none is created",
			pvcs:      []v1.PersistentVolumeClaim{pvc},
			jobs:      []batchv1.Job{failedIdleJob},
			deleteErr: boom,
			deleted:   []string{"idle-" + pvcName},
			wantErr:   boom,
		},
		{
			name:    "PVC being deleted with a running idle job: the job is deleted and none is created",
			pvcs:    []v1.PersistentVolumeClaim{beingDeleted(pvc)},
			jobs:    []batchv1.Job{idleJob},
			pods:    []v1.Pod{withState(idlePod, gateway, running)},
			deleted: []string{"idle-" + pvcName},
		},
		{
			name:    "PVC being deleted with a complete idle job: the job is deleted",
			pvcs:    []v1.PersistentVolumeClaim{beingDeleted(pvc)},
			jobs:    []batchv1.Job{completeIdleJob},
			deleted: []string{"idle-" + pvcName},
		},
		{
			name: "PVC being deleted with no idle job: none is created",
			pvcs: []v1.PersistentVolumeClaim{beingDeleted(pvc)},
		},
		{
			name:    "PVC without a stamp: skipped, with the error that names the annotation",
			pvcs:    []v1.PersistentVolumeClaim{unstamped},
			wantErr: errStampMismatch,
		},
		{
			name:    "PVC named for one user and stamped for another: skipped, with the error",
			pvcs:    []v1.PersistentVolumeClaim{statePVC(pvcName, otherStamp)},
			wantErr: errStampMismatch,
		},
		{
			name:    "PVC named and stamped for another steward: skipped, with the error",
			pvcs:    []v1.PersistentVolumeClaim{statePVC(statePVCName("clientone", stamp.requestUser, stamp.requestType), pvcStamp{dataSteward: "CLIENTONE", requestUser: stamp.requestUser, requestType: stamp.requestType})},
			wantErr: errStampMismatch,
		},
		{
			name: "PVC of another storage class: ignored",
			pvcs: []v1.PersistentVolumeClaim{otherClass, noClass},
		},
		{
			name:    "two PVCs, a gateway on one: only the other gets an idle job",
			pvcs:    []v1.PersistentVolumeClaim{pvc, otherPVC},
			jobs:    []batchv1.Job{chainJob},
			pods:    []v1.Pod{withState(chainPod, gateway, running)},
			created: []string{"idle-" + otherName},
		},
		{
			name:    "two PVCs, neither with a gateway: each gets its idle job",
			pvcs:    []v1.PersistentVolumeClaim{pvc, otherPVC},
			created: []string{"idle-" + pvcName, "idle-" + otherName},
		},
		{
			name:    "two PVCs, the first without a stamp: the second still gets its idle job",
			pvcs:    []v1.PersistentVolumeClaim{unstamped, otherPVC},
			created: []string{"idle-" + otherName},
			wantErr: errStampMismatch,
		},
		{
			name:    "two PVCs, the first one's failed idle job deleted: the second still gets its idle job",
			pvcs:    []v1.PersistentVolumeClaim{pvc, otherPVC},
			jobs:    []batchv1.Job{failedIdleJob},
			created: []string{"idle-" + otherName},
			deleted: []string{"idle-" + pvcName},
		},
		{
			name:      "the name is taken at the create: not an error, and the next PVC is handled",
			pvcs:      []v1.PersistentVolumeClaim{pvc, otherPVC},
			createErr: apierrors.NewAlreadyExists(schema.GroupResource{Group: "batch", Resource: "jobs"}, "idle-"+pvcName),
			created:   []string{"idle-" + pvcName, "idle-" + otherName},
		},
		{
			name:      "a create fails: the error, and the next PVC is handled",
			pvcs:      []v1.PersistentVolumeClaim{pvc, otherPVC},
			createErr: boom,
			created:   []string{"idle-" + pvcName, "idle-" + otherName},
			wantErr:   boom,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pvcs := &fakePVCLister{pvcs: tt.pvcs}
			jobs := newFakeJobClient(tt.jobs...)
			jobs.createErr = tt.createErr
			jobs.deleteErr = tt.deleteErr
			pods := &fakePodLister{pods: tt.pods}

			err := superviseStatePVCs(ctx, pvcs, jobs, pods, "server")

			if tt.wantErr == nil {
				assert.NilError(t, err)
			} else {
				assert.Assert(t, errors.Is(err, tt.wantErr), "got: %v", err)
			}
			var created []string
			for _, job := range jobs.created {
				created = append(created, job.Name)
				// The job is the builder's, for the PVC it is named after.
				for _, pvc := range tt.pvcs {
					if "idle-"+pvc.Name != job.Name {
						continue
					}
					want, err := idleGatewayJob(&pvc, "server")
					assert.NilError(t, err)
					assert.DeepEqual(t, job, want)
				}
			}
			assert.DeepEqual(t, created, tt.created)
			assert.DeepEqual(t, jobs.deleted, tt.deleted)
			// A deleted job takes its pod along.
			for _, policy := range jobs.policies {
				assert.Equal(t, policy, metav1.DeletePropagationBackground)
			}
			assert.Equal(t, len(jobs.policies), len(tt.deleted))
			assert.Equal(t, pvcs.lists, 1)
			assert.Assert(t, !idleGatewayMutexHeld())
		})
	}

	// Without the failure the passes that list PVCs would create one job and
	// delete another.
	failing := []struct {
		name string
		pvcs *fakePVCLister
		jobs *fakeJobClient
		pods *fakePodLister
	}{
		{name: "PVCs", pvcs: &fakePVCLister{listErr: boom}, jobs: newFakeJobClient(failedIdleJob), pods: &fakePodLister{}},
		{name: "jobs", pvcs: &fakePVCLister{pvcs: []v1.PersistentVolumeClaim{pvc, otherPVC}}, jobs: &fakeJobClient{listErr: boom}, pods: &fakePodLister{}},
		{name: "pods", pvcs: &fakePVCLister{pvcs: []v1.PersistentVolumeClaim{pvc, otherPVC}}, jobs: newFakeJobClient(failedIdleJob), pods: &fakePodLister{listErr: boom}},
	}
	for _, tt := range failing {
		t.Run("the list of "+tt.name+" fails: the error, and nothing is created or deleted", func(t *testing.T) {
			err := superviseStatePVCs(ctx, tt.pvcs, tt.jobs, tt.pods, "server")

			assert.Assert(t, errors.Is(err, boom), "got: %v", err)
			assert.Equal(t, len(tt.jobs.created), 0)
			assert.Equal(t, len(tt.jobs.deleted), 0)
			assert.Assert(t, !idleGatewayMutexHeld())
		})
	}

	t.Run("the mutex is held for the whole pass", func(t *testing.T) {
		pvcs := &fakePVCLister{pvcs: []v1.PersistentVolumeClaim{pvc}}
		jobs := newFakeJobClient()
		during := false
		pods := &fakePodLister{}
		pods.afterList = func(int) { during = idleGatewayMutexHeld() }

		assert.NilError(t, superviseStatePVCs(ctx, pvcs, jobs, pods, "server"))

		assert.Assert(t, during)
		assert.Assert(t, !idleGatewayMutexHeld())
	})

	t.Run("a pass waits until a hand-over is released", func(t *testing.T) {
		pvcs := &fakePVCLister{pvcs: []v1.PersistentVolumeClaim{pvc}}
		jobs := newFakeJobClient()
		pods := &fakePodLister{}

		release := handOverStatePVC(ctx, newFakeJobClient(), &fakePodLister{}, pvcName)
		done := make(chan error, 1)
		go func() { done <- superviseStatePVCs(ctx, pvcs, jobs, pods, "server") }()

		returned := false
		select {
		case <-done:
			returned = true
		case <-time.After(200 * time.Millisecond):
		}
		release()
		assert.Assert(t, !returned, "the pass returned while the hand-over held the mutex")

		select {
		case err := <-done:
			assert.NilError(t, err)
		case <-time.After(5 * time.Second):
			t.Fatal("the pass did not return after the release")
		}
		assert.Equal(t, pvcs.lists, 1)
		assert.Equal(t, len(jobs.created), 1)
	})

	t.Run("a hand-over waits until a pass is over", func(t *testing.T) {
		pvcs := &fakePVCLister{pvcs: []v1.PersistentVolumeClaim{pvc}}
		jobs := newFakeJobClient()
		inPass := make(chan struct{})
		resume := make(chan struct{})
		pods := &fakePodLister{}
		pods.afterList = func(int) {
			close(inPass)
			<-resume
		}

		passed := make(chan error, 1)
		go func() { passed <- superviseStatePVCs(ctx, pvcs, jobs, pods, "server") }()
		select {
		case <-inPass:
		case <-time.After(5 * time.Second):
			close(resume)
			t.Fatal("the pass did not reach its pod list")
		}

		handOverJobs := newFakeJobClient()
		handedOver := make(chan func(), 1)
		go func() { handedOver <- handOverStatePVC(ctx, handOverJobs, &fakePodLister{}, pvcName) }()
		var release func()
		select {
		case release = <-handedOver:
		case <-time.After(200 * time.Millisecond):
		}
		close(resume)
		early := release != nil
		if release == nil {
			select {
			case release = <-handedOver:
			case <-time.After(5 * time.Second):
				t.Fatal("the hand-over did not return after the pass")
			}
		}
		release()

		assert.Assert(t, !early, "the hand-over returned while the pass held the mutex")
		assert.NilError(t, <-passed)
		assert.Equal(t, len(jobs.created), 1)
		assert.Assert(t, !idleGatewayMutexHeld())
	})
}

func TestSuperviseStatePVCsGatewayMode(t *testing.T) {
	ctx := context.Background()
	t.Setenv("LOCAL_DEV", "true")

	stamp := pvcStamp{dataSteward: "SERVER", requestUser: "jake.jongejans@student.uva.nl", requestType: "vflTrainModelRequest"}
	pvcName := statePVCName("server", stamp.requestUser, stamp.requestType)
	pvc := statePVC(pvcName, stamp)

	tests := []struct {
		name    string
		env     string
		created []string
	}{
		{
			name: "GATEWAY_STORE_ONLY=true: no idle job is created",
			env:  "GATEWAY_STORE_ONLY",
		},
		{
			name: "GATEWAY_PASSTHROUGH=true: no idle job is created",
			env:  "GATEWAY_PASSTHROUGH",
		},
		{
			name:    "neither: an idle job is created",
			created: []string{"idle-" + pvcName},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("GATEWAY_STORE_ONLY", "")
			t.Setenv("GATEWAY_PASSTHROUGH", "")
			if tt.env != "" {
				t.Setenv(tt.env, "true")
			}
			pvcs := &fakePVCLister{pvcs: []v1.PersistentVolumeClaim{pvc}}
			jobs := newFakeJobClient()
			pods := &fakePodLister{}

			assert.NilError(t, superviseStatePVCs(ctx, pvcs, jobs, pods, "server"))

			var created []string
			for _, job := range jobs.created {
				created = append(created, job.Name)
			}
			assert.DeepEqual(t, created, tt.created)
			assert.Equal(t, len(jobs.deleted), 0)
		})
	}
}

func TestSuperviseLoop(t *testing.T) {
	t.Run("a pass at once, before the first period is over", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		passes := make(chan struct{}, 10)

		go superviseLoop(ctx, time.Hour, func(context.Context) { passes <- struct{}{} })

		select {
		case <-passes:
		case <-time.After(5 * time.Second):
			t.Fatal("no pass at the start")
		}
	})

	t.Run("a pass per period, until the context ends", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		passes := make(chan struct{}, 100)
		returned := make(chan struct{})

		go func() {
			superviseLoop(ctx, 10*time.Millisecond, func(context.Context) {
				select {
				case passes <- struct{}{}:
				default:
				}
			})
			close(returned)
		}()

		for range 3 {
			select {
			case <-passes:
			case <-time.After(5 * time.Second):
				t.Fatal("fewer than three passes")
			}
		}
		cancel()
		select {
		case <-returned:
		case <-time.After(5 * time.Second):
			t.Fatal("the loop did not return when the context ended")
		}
	})
}
