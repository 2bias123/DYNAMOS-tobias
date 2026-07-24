# e1-decision-correctness — captures

One line per artifact, newest last:
`<path> | YYYYMMDD-HHMMSS | <exact command> | <dynamos commit> | <what it shows / FAILED-run flag>`
`e1-decision-correctness/bufconn/20260724-165421_go-test-bufconn-oracle.txt | 20260724-165421 | (cd go && go test -v -count=1 -run '^(TestDecideWrite|TestDecideRead|TestRequestStateWriteAllowsAndPersists|TestValidateStateReadExistingAndMissing|TestReadDenialHidesFileExistence|TestWriteDeniedWhenCacheStale|TestWriteDeniedAfterPolicyFlip|TestIdentityMismatchDeniedAndAudited|TestUnregisteredIdentityDenied|TestAcquireLockConflict|TestWriteProducesLineBeforeFileInvariantHolds|TestWriteRefusedWhenAuditUnavailable|TestCrashBetweenAuditAndRenameLeavesLineNoFile)$' ./cmd/policy-checkpoint-gateway/) | be99f0d | E1 bufconn oracle run`
