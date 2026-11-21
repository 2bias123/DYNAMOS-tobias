# e1 unit-tests, attempt 1

- outcome: pass

## What ran

- cases.csv: 1 rows
- unit-build.csv: 1 rows
- unit-tests.csv: 68 rows

## Checks

- check missing values: pass
- check cases.csv unit · the gateway package's tests · control: pass
- check unit-tests.csv TestWriteProducesLineBeforeFileInvariantHolds: pass
- check unit-tests.csv TestEveryRecordCarriesDecisionTime: pass
- check unit-tests.csv TestWriteRefusedWhenAuditUnavailable: pass
- check unit-tests.csv TestReadRefusedWhenAuditUnavailable: pass
- check unit-tests.csv TestCrashBetweenAuditAndRenameLeavesLineNoFile: pass
- check unit-tests.csv TestRequestStateWriteAllowsAndPersists: pass
- check unit-tests.csv TestIdentityMismatchDeniedAndAudited: pass
- check unit-tests.csv TestValidateStateReadExistingAndMissing: pass
- check unit-tests.csv TestReadDenialHidesFileExistence: pass
- check unit-tests.csv TestInvalidNamesInvalidArgument: pass
- check unit-tests.csv TestSubscribeStateEventsInitialEvent: pass
- check unit-tests.csv TestInactivitySuppressedWhileSubscribed: pass
- check unit-tests.csv TestWriteDeniedWhenCacheStale: pass
- check unit-tests.csv TestWriteDeniedAfterPolicyFlip: pass
- check unit-tests.csv TestUnregisteredIdentityDenied: pass
- check unit-tests.csv TestShutdownClosesStop: pass
- check unit-tests.csv TestAcquireLockConflict: pass
- check unit-tests.csv TestPassthroughWriteAuditsButDoesNotPersist: pass
- check unit-tests.csv TestStoreOnlyServesStateWithoutGovernance: pass
- check unit-tests.csv TestStoreOnlyMissingAndInvalidNames: pass
- check unit-tests.csv TestIdleDeletesDueStateAndReportsEmpty: pass
- check unit-tests.csv TestIdleKeepsRunningWhileNothingIsDue: pass
- check unit-tests.csv TestIdleReturnsAtOnceWhenEmpty: pass
- check unit-tests.csv TestIdleStopReleasesLock: pass
- check unit-tests.csv TestIdleLockHeldElsewhere: pass
- check unit-tests.csv TestIdleStopWhileWaitingForLock: pass
- check unit-tests.csv TestLoadIdleConfigNeedsNoPortOrJob: pass
- check unit-tests.csv TestAcquireLockWithRetryHolderReleases: pass
- check unit-tests.csv TestAcquireLockWithRetryWindowPasses: pass
- check unit-tests.csv TestStartGatewayTouchesNothingWithoutLock: pass
- check unit-tests.csv TestStartGatewayHoldsLockAndSyncs: pass
- check unit-tests.csv TestLockLost: pass
- check unit-tests.csv TestDecideWrite: pass
- check unit-tests.csv TestDecideRead: pass
- check unit-tests.csv TestPolicyCacheSourceProgression: pass
- check unit-tests.csv TestCanonicalHashIgnoresFormatting: pass
- check unit-tests.csv TestLaunchFileDeniesStateForVFLStewards: pass
- check unit-tests.csv TestSweepPurgesRevokedStateAfterConfirm: pass
- check unit-tests.csv TestSweepDefersWhenConfirmFails: pass
- check unit-tests.csv TestSweepCancelsOnRegrant: pass
- check unit-tests.csv TestSweepRetainsWithoutPurgeDirective: pass
- check unit-tests.csv TestSweepInvalidDirectivesAuditedNoPurge: pass
- check unit-tests.csv TestSweepDeletesExpiredAfterConfirm: pass
- check unit-tests.csv TestSweepRetainsExpiredWhenConfirmFails: pass
- check unit-tests.csv TestSweepDefersExpiryOnEveryReconsideration: pass
- check unit-tests.csv TestSweepExpiryCancelledByLongerRetention: pass
- check unit-tests.csv TestSweepPurgeCancelledByRegrantRecordedOnce: pass
- check unit-tests.csv TestSweepCancelledWhenAgreementGoneAtConfirm: pass
- check unit-tests.csv TestBootIntoRevokedPurgesAtStartup: pass
- check unit-tests.csv TestPurgeEventReachesSubscriber: pass
- check unit-tests.csv TestNewStoreCreatesDirs: pass
- check unit-tests.csv TestStoreWriteReadRoundTrip: pass
- check unit-tests.csv TestStoreReadMissing: pass
- check unit-tests.csv TestStoreWriteOverwrites: pass
- check unit-tests.csv TestStoreInvalidNames: pass
- check unit-tests.csv TestStoreWriteLeavesNoTemp: pass
- check unit-tests.csv TestStoreAuditEmitsNDJSON: pass
- check unit-tests.csv TestStoreAuditStampsDecisionTime: pass
- check unit-tests.csv TestStoreAuditDecisionTimeNeverDecreases: pass
- check unit-tests.csv TestStoreConcurrentWritesOneKey: pass
- check unit-tests.csv TestSyncInitialLoadThenOutageAgesToStale: pass
- check unit-tests.csv TestSyncColdStartUnavailableUntilFirstRead: pass
- check unit-tests.csv TestSyncWatchEventUpdatesHash: pass
- check unit-tests.csv TestSyncDeleteEventFailsClosed: pass
- check unit-tests.csv TestSyncUnparseableAgreementFailsClosed: pass
- check unit-tests.csv TestSyncWatchCancelReconnects: pass
- check unit-tests.csv TestSyncPollsWhileWatchReconnects: pass
- check unit-tests.csv TestVerifyRegistration: pass
- check verdict: pass

## Values

Intervals from the CSVs' µs values, in ms rounded to 0.1 ms; the median of an even n is the mean of the middle two.

- no interval column

## Rows

| row | case | steward | expected | observed | result |
|---|---|---|---|---|---|
| unit | the gateway package's tests | control | 68 test functions (the set's source), every one PASS, exit 0 | 68 run: 68 PASS, 0 FAIL, 0 SKIP, exit 0, 2.4 s | pass |
