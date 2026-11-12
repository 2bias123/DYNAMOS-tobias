package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Jorrit05/DYNAMOS/pkg/api"
	pb "github.com/Jorrit05/DYNAMOS/pkg/proto"
	"gotest.tools/assert"
)

// holdGuard marks requestID as the active job, as requestHandler does when it
// accepts a request, and frees the guard again when the test ends.
func holdGuard(t *testing.T, requestID string) {
	activeJobLock.Lock()
	activeJobID = requestID
	activeJobLock.Unlock()
	trainingRequests.Store(requestID, TrainingRequestData{Status: StatusPending})
	t.Cleanup(func() {
		activeJobLock.Lock()
		activeJobID = ""
		activeJobLock.Unlock()
		trainingRequests.Delete(requestID)
	})
}

func guardHolder() string {
	activeJobLock.Lock()
	defer activeJobLock.Unlock()
	return activeJobID
}

func TestRequestHandlerRefusesWhileJobActive(t *testing.T) {
	holdGuard(t, "active-request")

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/requestApproval", strings.NewReader("{}"))
	requestHandler().ServeHTTP(rec, req)

	assert.Equal(t, rec.Code, http.StatusTooManyRequests)
	assert.Assert(t, strings.Contains(rec.Body.String(), `"active_request_id":"active-request"`), rec.Body.String())
	assert.Equal(t, guardHolder(), "active-request")
}

// With no messaging client, startTraining panics at its first send and
// recovers.
func TestStartTrainingReleasesGuardAfterPanic(t *testing.T) {
	tests := []struct {
		name   string
		holder string
		want   string
	}{
		{name: "the request's own guard is released", holder: "panicking-request", want: ""},
		{name: "another request's guard stays held", holder: "other-request", want: "other-request"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			holdGuard(t, tt.holder)
			user := &pb.User{Id: "guard-test-user"}
			t.Cleanup(func() {
				requestApprovalMutex.Lock()
				delete(requestApprovalMap, user.Id)
				requestApprovalMutex.Unlock()
			})

			req := httptest.NewRequest(http.MethodPost, "/requestApproval", strings.NewReader("{}"))
			startTraining(&pb.RequestApproval{User: user}, map[string]any{}, api.RequestApproval{}, req, "panicking-request")

			assert.Equal(t, guardHolder(), tt.want)
		})
	}
}
