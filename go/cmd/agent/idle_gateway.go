package main

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	v1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const gatewayContainerName = "policy-checkpoint-gateway"

// Label on the idle job and its pod; a chain job does not carry it.
const (
	idleGatewayLabel = "dynamos/gateway"
	idleGatewayValue = "idle"
)

const idleGatewayGracePeriodSeconds = int64(10)

// idleGatewayNotStoppedMarker is the fixed text in the line the agent logs
// when it deploys a chain job without having seen the PVC's idle job go.
const idleGatewayNotStoppedMarker = "IDLE_GATEWAY_NOT_STOPPED"

var errIdleGatewayNotStopped = errors.New(idleGatewayNotStoppedMarker)

// idleGatewayNotRunningMarker is the fixed text in the line the agent logs
// when it deletes an idle job whose gateway has never run.
const idleGatewayNotRunningMarker = "IDLE_GATEWAY_NOT_RUNNING"

var errIdleGatewayNotRunning = errors.New(idleGatewayNotRunningMarker)

// An idle job this old whose gateway has never run is deleted.
const idleNotRunningAfter = 120 * time.Second

const (
	handOverWait     = 30 * time.Second
	handOverInterval = 500 * time.Millisecond
)

// idleGatewayMutex is held from the stop of a PVC's idle job until the chain
// job that takes the PVC over exists.
var idleGatewayMutex = &sync.Mutex{}

// idleJobClient is the slice of the namespaced Job API the hand-over needs;
// satisfied by clientSet.BatchV1().Jobs(namespace).
type idleJobClient interface {
	Get(ctx context.Context, name string, opts metav1.GetOptions) (*batchv1.Job, error)
	Delete(ctx context.Context, name string, opts metav1.DeleteOptions) error
}

// podLister is satisfied by clientSet.CoreV1().Pods(namespace).
type podLister interface {
	List(ctx context.Context, opts metav1.ListOptions) (*v1.PodList, error)
}

const supervisionPeriod = 30 * time.Second

// statePVCLister is satisfied by
// clientSet.CoreV1().PersistentVolumeClaims(namespace).
type statePVCLister interface {
	List(ctx context.Context, opts metav1.ListOptions) (*v1.PersistentVolumeClaimList, error)
}

// supervisionJobClient is the slice of the namespaced Job API a supervision
// pass needs; satisfied by clientSet.BatchV1().Jobs(namespace).
type supervisionJobClient interface {
	List(ctx context.Context, opts metav1.ListOptions) (*batchv1.JobList, error)
	Create(ctx context.Context, job *batchv1.Job, opts metav1.CreateOptions) (*batchv1.Job, error)
	Delete(ctx context.Context, name string, opts metav1.DeleteOptions) error
}

func idleJobName(pvcName string) string {
	return "idle-" + pvcName
}

// stampOf reads the identity back from a state PVC. A PVC that lacks one of
// the three annotations has no identity to run a gateway under.
func stampOf(pvc *v1.PersistentVolumeClaim) (pvcStamp, error) {
	for _, key := range []string{stampDataSteward, stampRequestUser, stampRequestType} {
		if _, ok := pvc.Annotations[key]; !ok {
			return pvcStamp{}, fmt.Errorf("%w: PVC %s has no annotation %s", errStampMismatch, pvc.Name, key)
		}
	}
	return pvcStamp{
		dataSteward: pvc.Annotations[stampDataSteward],
		requestUser: pvc.Annotations[stampRequestUser],
		requestType: pvc.Annotations[stampRequestType],
	}, nil
}

// idleGatewayJob builds the job that runs the gateway's idle form on a
// state PVC, with the identity the PVC is stamped with. The job has no TTL
// and no deadline: completed, it marks the PVC as empty.
func idleGatewayJob(pvc *v1.PersistentVolumeClaim, dataStewardName string) (*batchv1.Job, error) {
	stamp, err := stampOf(pvc)
	if err != nil {
		return nil, err
	}

	repositoryName := cmp.Or(os.Getenv("MICROSERVICE_REPOSITORY_NAME"), "dynamos1")
	fullImage := fmt.Sprintf("%s/%s:%s", repositoryName, gatewayContainerName, getMicroserviceTag(gatewayContainerName))

	gracePeriod := idleGatewayGracePeriodSeconds
	podSpec := v1.PodSpec{
		RestartPolicy:                 v1.RestartPolicyOnFailure,
		TerminationGracePeriodSeconds: &gracePeriod,
		Containers: []v1.Container{
			{
				Name:            gatewayContainerName,
				Image:           fullImage,
				ImagePullPolicy: v1.PullIfNotPresent,
				// The binary, not the image's shell entry: the exit code must
				// be the gateway's, and the stop signal must reach it.
				Command: []string{"/app/" + gatewayContainerName},
				Env: []v1.EnvVar{
					{Name: "DATA_STEWARD_NAME", Value: stamp.dataSteward},
					{Name: "REQUEST_USER", Value: stamp.requestUser},
					{Name: "REQUEST_TYPE", Value: stamp.requestType},
					{Name: "GATEWAY_IDLE", Value: "true"},
					{Name: "STATE_DIR", Value: "/state"},
				},
				VolumeMounts: []v1.VolumeMount{
					{Name: "gateway-state", MountPath: "/state"},
				},
			},
		},
		Volumes: []v1.Volume{
			{
				Name: "gateway-state",
				VolumeSource: v1.VolumeSource{
					PersistentVolumeClaim: &v1.PersistentVolumeClaimVolumeSource{ClaimName: pvc.Name},
				},
			},
		},
	}
	if strings.ToLower(os.Getenv("LOCAL_DEV")) != "true" {
		podSpec.NodeName = dataStewardName
	}

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      idleJobName(pvc.Name),
			Namespace: dataStewardName,
			Labels:    map[string]string{idleGatewayLabel: idleGatewayValue},
		},
		Spec: batchv1.JobSpec{
			Template: v1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{idleGatewayLabel: idleGatewayValue},
				},
				Spec: podSpec,
			},
		},
	}, nil
}

func mountsPVC(spec v1.PodSpec, pvcName string) bool {
	return slices.ContainsFunc(spec.Volumes, func(volume v1.Volume) bool {
		return volume.PersistentVolumeClaim != nil && volume.PersistentVolumeClaim.ClaimName == pvcName
	})
}

func jobFinished(job batchv1.Job) bool {
	return slices.ContainsFunc(job.Status.Conditions, func(condition batchv1.JobCondition) bool {
		return (condition.Type == batchv1.JobComplete || condition.Type == batchv1.JobFailed) && condition.Status == v1.ConditionTrue
	})
}

// gatewayContainerAlive reports whether the pod's gateway container runs or
// will run. A gateway that exited cleanly is not restarted, so it does not
// count, even while the pod's other containers keep the pod running.
func gatewayContainerAlive(pod v1.Pod) bool {
	if pod.Status.Phase == v1.PodSucceeded || pod.Status.Phase == v1.PodFailed {
		return false
	}
	if !slices.ContainsFunc(pod.Spec.Containers, func(container v1.Container) bool { return container.Name == gatewayContainerName }) {
		return false
	}
	for _, status := range pod.Status.ContainerStatuses {
		if status.Name != gatewayContainerName {
			continue
		}
		if terminated := status.State.Terminated; terminated != nil {
			return terminated.ExitCode != 0 && pod.Spec.RestartPolicy != v1.RestartPolicyNever
		}
		return true
	}
	// No status yet: the container has not been started.
	return true
}

// gatewayAlive reports whether a gateway on the state PVC is running or on
// its way: a pod that mounts the PVC has a live gateway container, or an
// unfinished job mounts the PVC and has no pod yet.
func gatewayAlive(pvcName string, jobs []batchv1.Job, pods []v1.Pod) bool {
	for _, pod := range pods {
		if mountsPVC(pod.Spec, pvcName) && gatewayContainerAlive(pod) {
			return true
		}
	}
	for _, job := range jobs {
		if !mountsPVC(job.Spec.Template.Spec, pvcName) || jobFinished(job) {
			continue
		}
		if !slices.ContainsFunc(pods, func(pod v1.Pod) bool { return metav1.IsControlledBy(&pod, &job) }) {
			return true
		}
	}
	return false
}

// idleGatewayGone reports whether neither the idle job nor a pod of it is
// left.
func idleGatewayGone(ctx context.Context, jobs idleJobClient, pods podLister, name string) (bool, error) {
	_, err := jobs.Get(ctx, name, metav1.GetOptions{})
	if err == nil {
		return false, nil
	}
	if !apierrors.IsNotFound(err) {
		return false, fmt.Errorf("getting job %s: %w", name, err)
	}
	left, err := pods.List(ctx, metav1.ListOptions{LabelSelector: "job-name=" + name})
	if err != nil {
		return false, fmt.Errorf("listing the pods of job %s: %w", name, err)
	}
	return len(left.Items) == 0, nil
}

// stopIdleGateway deletes the PVC's idle job and returns once the job and
// its pod are gone, which is when the state lock is free. Without an idle
// job it returns at once. Every error carries the marker.
func stopIdleGateway(ctx context.Context, jobs idleJobClient, pods podLister, pvcName string, wait, interval time.Duration) error {
	name := idleJobName(pvcName)
	// In the foreground the job stays until its pod is gone.
	foreground := metav1.DeletePropagationForeground
	err := jobs.Delete(ctx, name, metav1.DeleteOptions{PropagationPolicy: &foreground})
	if err != nil && !apierrors.IsNotFound(err) {
		return fmt.Errorf("%w: deleting job %s: %w", errIdleGatewayNotStopped, name, err)
	}

	deadline := time.Now().Add(wait)
	for {
		gone, err := idleGatewayGone(ctx, jobs, pods, name)
		if err != nil {
			return fmt.Errorf("%w: %w", errIdleGatewayNotStopped, err)
		}
		if gone {
			return nil
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("%w: job %s or its pod still there after %s", errIdleGatewayNotStopped, name, wait)
		}
		time.Sleep(interval)
	}
}

// handOverStatePVC stops the PVC's idle gateway for a chain job that is
// about to be created. The caller calls release once that job exists. A
// stop that fails is logged and does not hold the deploy back: the chain
// job's gateway waits for the lock itself.
func handOverStatePVC(ctx context.Context, jobs idleJobClient, pods podLister, pvcName string) (release func()) {
	idleGatewayMutex.Lock()
	start := time.Now()
	if err := stopIdleGateway(ctx, jobs, pods, pvcName, handOverWait, handOverInterval); err != nil {
		logger.Sugar().Errorf("Deploying on PVC %s anyway: %v", pvcName, err)
	} else {
		logger.Sugar().Infof("No idle gateway left on PVC %s after %s", pvcName, time.Since(start))
	}
	return idleGatewayMutex.Unlock
}

// ownStamp refuses a PVC whose stamp names another steward or another PVC:
// a deploy refuses it too, so no gateway runs under that identity.
func ownStamp(pvc *v1.PersistentVolumeClaim, dataStewardName string) error {
	stamp, err := stampOf(pvc)
	if err != nil {
		return err
	}
	if !strings.EqualFold(stamp.dataSteward, dataStewardName) || statePVCName(stamp.dataSteward, stamp.requestUser, stamp.requestType) != pvc.Name {
		return fmt.Errorf("%w: PVC %s is not the one its stamp names", errStampMismatch, pvc.Name)
	}
	return nil
}

func jobFailed(job batchv1.Job) bool {
	return slices.ContainsFunc(job.Status.Conditions, func(condition batchv1.JobCondition) bool {
		return condition.Type == batchv1.JobFailed && condition.Status == v1.ConditionTrue
	})
}

// idleJobStale reports whether a gateway may have written on the PVC since
// the completed idle job marked it as empty: a pod that is not the job's own
// mounts the PVC, has a gateway container, and was created at or after the
// completion. The times have whole seconds, so the same second counts; with
// no completion time every such pod does.
func idleJobStale(job batchv1.Job, pvcName string, pods []v1.Pod) bool {
	i := slices.IndexFunc(job.Status.Conditions, func(condition batchv1.JobCondition) bool {
		return condition.Type == batchv1.JobComplete && condition.Status == v1.ConditionTrue
	})
	if i < 0 {
		return false
	}
	completed := job.Status.Conditions[i].LastTransitionTime
	if job.Status.CompletionTime != nil {
		completed = *job.Status.CompletionTime
	}
	return slices.ContainsFunc(pods, func(pod v1.Pod) bool {
		return !metav1.IsControlledBy(&pod, &job) && mountsPVC(pod.Spec, pvcName) &&
			slices.ContainsFunc(pod.Spec.Containers, func(container v1.Container) bool { return container.Name == gatewayContainerName }) &&
			!pod.CreationTimestamp.Time.Before(completed.Time)
	})
}

// idleJobNotRunning returns the marked error for an unfinished idle job that
// is idleNotRunningAfter old and whose gateway has never run: it has no pod,
// or no pod of it has a gateway container that runs, has exited or was
// restarted. A gateway that runs and fails is the failed job's case.
func idleJobNotRunning(job batchv1.Job, pvcName string, pods []v1.Pod) error {
	age := time.Since(job.CreationTimestamp.Time)
	if jobFinished(job) || age < idleNotRunningAfter {
		return nil
	}
	shows := "no pod"
	for _, pod := range pods {
		if !metav1.IsControlledBy(&pod, &job) {
			continue
		}
		shows = "pod " + string(pod.Status.Phase)
		for _, status := range pod.Status.ContainerStatuses {
			if status.Name != gatewayContainerName {
				continue
			}
			if status.State.Running != nil || status.State.Terminated != nil || status.RestartCount > 0 {
				return nil
			}
			if status.State.Waiting != nil {
				shows = "container waiting, " + status.State.Waiting.Reason
			}
		}
	}
	return fmt.Errorf("%w: job %s on PVC %s is %s old: %s", errIdleGatewayNotRunning, job.Name, pvcName, age.Round(time.Second), shows)
}

// gatewayEnforces reports whether the agent deploys its gateways in the
// enforcing mode. Under passthrough or store-only a PVC gets no idle job.
func gatewayEnforces() bool {
	return os.Getenv("GATEWAY_PASSTHROUGH") != "true" && os.Getenv("GATEWAY_STORE_ONLY") != "true"
}

// superviseStatePVCs is one supervision pass over the steward's state PVCs.
// A PVC with no gateway alive and no idle job gets an idle job. A completed
// idle job stays: it marks the PVC as empty. It is deleted once a gateway
// has used the PVC after it. A failed one is deleted, and a later pass
// replaces it; so is one whose gateway has never run, with the marked
// error. A PVC that is being deleted loses its idle job and gets none.
// Nothing is changed unless all three lists succeed.
func superviseStatePVCs(ctx context.Context, pvcs statePVCLister, jobs supervisionJobClient, pods podLister, dataStewardName string) error {
	idleGatewayMutex.Lock()
	defer idleGatewayMutex.Unlock()

	var errs []error
	failed := func(err error) {
		logger.Sugar().Errorf("Supervision of the state PVCs: %v", err)
		errs = append(errs, err)
	}

	pvcList, err := pvcs.List(ctx, metav1.ListOptions{})
	if err != nil {
		failed(fmt.Errorf("listing PVCs: %w", err))
		return errors.Join(errs...)
	}
	jobList, err := jobs.List(ctx, metav1.ListOptions{})
	if err != nil {
		failed(fmt.Errorf("listing jobs: %w", err))
		return errors.Join(errs...)
	}
	podList, err := pods.List(ctx, metav1.ListOptions{})
	if err != nil {
		failed(fmt.Errorf("listing pods: %w", err))
		return errors.Join(errs...)
	}

	// In the background the job goes at once and its pod follows.
	background := metav1.DeletePropagationBackground
	for _, pvc := range pvcList.Items {
		if pvc.Spec.StorageClassName == nil || *pvc.Spec.StorageClassName != stateStorageClass {
			continue
		}
		name := idleJobName(pvc.Name)
		i := slices.IndexFunc(jobList.Items, func(job batchv1.Job) bool { return job.Name == name })
		if i >= 0 {
			var reason string
			notRunning := idleJobNotRunning(jobList.Items[i], pvc.Name, podList.Items)
			switch {
			case pvc.DeletionTimestamp != nil:
				reason = "its PVC is being deleted"
			case jobFailed(jobList.Items[i]):
				reason = "it failed"
			case idleJobStale(jobList.Items[i], pvc.Name, podList.Items):
				reason = "an enforcement point used the PVC after it completed"
			case notRunning != nil:
				failed(notRunning)
				reason = "its gateway never ran"
			default:
				continue
			}
			if err := jobs.Delete(ctx, name, metav1.DeleteOptions{PropagationPolicy: &background}); err != nil && !apierrors.IsNotFound(err) {
				failed(fmt.Errorf("deleting job %s: %w", name, err))
				continue
			}
			logger.Sugar().Infof("Idle job %s deleted: %s", name, reason)
			continue
		}
		if pvc.DeletionTimestamp != nil || !gatewayEnforces() || gatewayAlive(pvc.Name, jobList.Items, podList.Items) {
			continue
		}
		if err := ownStamp(&pvc, dataStewardName); err != nil {
			failed(err)
			continue
		}
		job, err := idleGatewayJob(&pvc, dataStewardName)
		if err != nil {
			failed(err)
			continue
		}
		_, err = jobs.Create(ctx, job, metav1.CreateOptions{})
		if apierrors.IsAlreadyExists(err) {
			continue
		}
		if err != nil {
			failed(fmt.Errorf("creating job %s: %w", name, err))
			continue
		}
		logger.Sugar().Infof("Idle gateway started on PVC %s", pvc.Name)
	}
	logger.Sugar().Debugf("Supervision pass done, %d PVCs listed", len(pvcList.Items))
	return errors.Join(errs...)
}

// superviseSteward supervises the state PVCs in the steward's namespace. A
// pass holds the hand-over's mutex, so it gets no longer than one period.
func superviseSteward(ctx context.Context) {
	dataStewardName := strings.ToLower(serviceName)
	if dataStewardName == "" {
		logger.Sugar().Error("No supervision of state PVCs: env variable DATA_STEWARD_NAME not defined")
		return
	}
	superviseLoop(ctx, supervisionPeriod, func(ctx context.Context) {
		ctx, cancel := context.WithTimeout(ctx, supervisionPeriod)
		defer cancel()
		superviseStatePVCs(ctx, clientSet.CoreV1().PersistentVolumeClaims(dataStewardName), clientSet.BatchV1().Jobs(dataStewardName), clientSet.CoreV1().Pods(dataStewardName), dataStewardName)
	})
}

// superviseLoop runs pass at once and then once per period, until ctx ends.
func superviseLoop(ctx context.Context, period time.Duration, pass func(ctx context.Context)) {
	ticker := time.NewTicker(period)
	defer ticker.Stop()
	for {
		pass(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
