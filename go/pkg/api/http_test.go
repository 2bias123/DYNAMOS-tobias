package api

import (
	"encoding/json"
	"strings"
	"testing"

	"gotest.tools/assert"
)

func TestRelationStateDirectivesRoundTrip(t *testing.T) {
	tests := []struct {
		name       string
		relation   Relation
		wantKey    bool
		wantResume bool
	}{
		{
			name: "with state directives",
			relation: Relation{
				ID:                      "GUID-state-aware",
				RequestTypes:            []string{"vflTrainModelRequest"},
				AllowedArchetypes:       []string{"computeToData"},
				AllowedComputeProviders: []string{"server"},
				StateDirectives: &StateDirectives{
					Allowed:          true,
					RetentionSeconds: 900,
					ResumeAllowed:    true,
					OnRevocation:     "purge",
				},
			},
			wantKey:    true,
			wantResume: true,
		},
		{
			name: "without state directives",
			relation: Relation{
				ID:                      "GUID",
				RequestTypes:            []string{"sqlDataRequest", "genericRequest"},
				DataSets:                []string{"wageGap"},
				AllowedComputeProviders: []string{"SURF"},
			},
			wantKey: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			data, err := json.Marshal(tc.relation)
			assert.NilError(t, err)

			hasKey := strings.Contains(string(data), `"stateDirectives"`)
			assert.Equal(t, tc.wantKey, hasKey)

			var got Relation
			err = json.Unmarshal(data, &got)
			assert.NilError(t, err)

			// Marshalling the decoded value must reproduce the original bytes.
			roundTrip, err := json.Marshal(got)
			assert.NilError(t, err)
			assert.Equal(t, string(data), string(roundTrip))

			if tc.wantKey {
				assert.Assert(t, got.StateDirectives != nil)
				assert.Equal(t, tc.wantResume, got.StateDirectives.ResumeAllowed)
			} else {
				assert.Assert(t, got.StateDirectives == nil)
			}
		})
	}
}

// A relation written before StateDirectives existed must still decode, leaving
// the field nil and the pre-existing fields intact.
func TestRelationBackwardCompatible(t *testing.T) {
	legacy := `{
		"ID": "GUID",
		"requestTypes": ["sqlDataRequest", "genericRequest"],
		"dataSets": ["wageGap"],
		"allowedArchetypes": ["computeToData", "dataThroughTtp"],
		"allowedComputeProviders": ["SURF"]
	}`

	var got Relation
	err := json.Unmarshal([]byte(legacy), &got)
	assert.NilError(t, err)

	assert.Equal(t, "GUID", got.ID)
	assert.Equal(t, 2, len(got.RequestTypes))
	assert.Assert(t, got.StateDirectives == nil)
}
