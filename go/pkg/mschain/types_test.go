package mschain

import (
	"encoding/json"
	"strings"
	"testing"

	"gotest.tools/assert"
)

func TestMicroserviceMetadataRequiresGateway(t *testing.T) {
	tests := []struct {
		name     string
		metadata MicroserviceMetadata
		wantKey  bool
	}{
		{
			name: "stateful microservice requires gateway",
			metadata: MicroserviceMetadata{
				Name:            "vfl-train-model-demo",
				Label:           "computeProvider",
				RequiresGateway: true,
			},
			wantKey: true,
		},
		{
			name: "stateless microservice omits the flag",
			metadata: MicroserviceMetadata{
				Name:  "anonymize-test",
				Label: "computeProvider",
			},
			wantKey: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			data, err := json.Marshal(tc.metadata)
			assert.NilError(t, err)

			// omitempty keeps the flag out of the wire form when false.
			hasKey := strings.Contains(string(data), `"requiresGateway"`)
			assert.Equal(t, tc.wantKey, hasKey)

			var got MicroserviceMetadata
			err = json.Unmarshal(data, &got)
			assert.NilError(t, err)
			assert.Equal(t, tc.metadata.RequiresGateway, got.RequiresGateway)
		})
	}
}

// Metadata written before RequiresGateway existed must decode with the flag
// defaulting to false.
func TestMicroserviceMetadataBackwardCompatible(t *testing.T) {
	legacy := `{"name":"anonymize-test","label":"computeProvider","allowedOutputs":["*"]}`

	var got MicroserviceMetadata
	err := json.Unmarshal([]byte(legacy), &got)
	assert.NilError(t, err)

	assert.Equal(t, "anonymize-test", got.Name)
	assert.Equal(t, false, got.RequiresGateway)
}
