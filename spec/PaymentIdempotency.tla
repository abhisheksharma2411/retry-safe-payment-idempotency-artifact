---- MODULE PaymentIdempotency ----
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Scenario, Mutant, ProviderProfile

Services == {"S1", "S2"}
Identities == {"I1", "I2"}
Payloads == {"FP_A", "FP_B"}
ProviderRefs == {"R1", "R2", "R3", "R4"}
ProviderKeys == {"K1", "K2", "K1_DRIFT", "RAW_SHARED", "PARENT_AMOUNT"}
Parents == {"AUTH1"}
None == "None"

TerminalStates == {"COMPLETED", "REJECTED_FINAL"}
RecordStates == {"ABSENT", "IN_PROGRESS", "UNKNOWN", "COMPLETED", "REJECTED_FINAL", "TOMBSTONE"}
SvcStates == {"Idle", "Submitted", "Read", "Claimed", "Sent", "UnknownSeen", "Recovering", "Done", "Crashed"}
RespStatus == {"PENDING", "CONFLICT", "COMPLETED", "REJECTED_FINAL", "UNKNOWN"}

IdentityRawKey(i) == "RAW_SHARED"
IdentityParent(i) == "AUTH1"
IdentityKind(i) ==
    IF Scenario = "two_equal_partial_refunds_witness" THEN "refund"
    ELSE IF Scenario \in {"partial_capture_and_refund"} /\ i = "I2" THEN "refund"
    ELSE IF Scenario = "reversal_parent_state" /\ i = "I2" THEN "reversal"
    ELSE "capture"
PayloadAmount(p) == IF p = "FP_A" THEN 10 ELSE 5
MaxDepth ==
    IF Scenario = "combined_concurrent" THEN 8
    ELSE IF Scenario = "concurrent_same_identity" THEN 10
    ELSE IF Scenario = "cross_scope_same_raw_key" THEN 7
    ELSE IF Scenario \in {"unknown_outcome_replay_provider", "unknown_outcome_lookup_provider"} THEN 10
    ELSE IF Scenario = "two_equal_partial_refunds_witness" THEN 10
    ELSE IF Scenario = "liveness_fair" THEN 5
    ELSE 6

ProviderIdentity(i) ==
    IF Mutant = "formal_m4" THEN "RAW_SHARED"
    ELSE IF Mutant = "formal_m10" /\ IdentityKind(i) = "refund" THEN "PARENT_AMOUNT"
    ELSE i

ProviderKeyFor(i, recovery) ==
    IF Mutant = "formal_m11" /\ recovery THEN "K1_DRIFT"
    ELSE IF ProviderIdentity(i) = "RAW_SHARED" THEN "RAW_SHARED"
    ELSE IF ProviderIdentity(i) = "PARENT_AMOUNT" THEN "PARENT_AMOUNT"
    ELSE IF i = "I1" THEN "K1" ELSE "K2"

ProviderRefFor(k) ==
    CASE k = "K1" -> "R1"
      [] k = "K2" -> "R2"
      [] k = "K1_DRIFT" -> "R3"
      [] k = "RAW_SHARED" -> "R1"
      [] k = "PARENT_AMOUNT" -> "R2"
      [] OTHER -> "R4"

VARIABLES
    records,
    serviceState,
    serviceIdentity,
    servicePayload,
    crashed,
    claimOwner,
    fence,
    leaseExpiry,
    logicalTime,
    providerRequests,
    providerAcks,
    providerLedger,
    providerDedup,
    providerLookups,
    businessProjection,
    clientRequests,
    clientResponses,
    networkAvailable,
    providerAvailable,
    noFurtherCrashes,
    recoveryOwner,
    localRetention,
    providerRetention,
    lifecycleCaptured,
    lifecycleRefunded,
    lifecycleReversed,
    lastAction,
    history

vars == <<records, serviceState, serviceIdentity, servicePayload, crashed,
          claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
          providerAcks, providerLedger, providerDedup, providerLookups,
          businessProjection, clientRequests, clientResponses,
          networkAvailable, providerAvailable, noFurtherCrashes,
          recoveryOwner, localRetention, providerRetention, lifecycleCaptured,
          lifecycleRefunded, lifecycleReversed, lastAction, history>>

Required(i) == \E req \in clientRequests : req.intent = i

EffectUniverse == [svc: Services, intent: Identities, providerIdentity: ProviderKeys, providerRef: ProviderRefs]
RequestUniverse == [svc: Services, intent: Identities, payload: Payloads, providerIdentity: ProviderKeys]
ResponseUniverse == [intent: Identities, payload: Payloads, status: RespStatus, providerRef: ProviderRefs \cup {None}]
LookupUniverse == [intent: Identities, providerIdentity: ProviderKeys, found: BOOLEAN]

EmptyRecord(i) == [
    state |-> "ABSENT",
    fp |-> None,
    owner |-> None,
    fence |-> 0,
    providerIdentity |-> None,
    providerRef |-> None,
    terminalPayload |-> None
]

Init ==
    /\ records = [i \in Identities |-> EmptyRecord(i)]
    /\ serviceState = [s \in Services |-> "Idle"]
    /\ serviceIdentity = [s \in Services |-> "I1"]
    /\ servicePayload = [s \in Services |-> "FP_A"]
    /\ crashed = [s \in Services |-> FALSE]
    /\ claimOwner = [i \in Identities |-> None]
    /\ fence = [i \in Identities |-> 0]
    /\ leaseExpiry = [i \in Identities |-> 0]
    /\ logicalTime = 0
    /\ providerRequests = {}
    /\ providerAcks = {}
    /\ providerLedger = {}
    /\ providerDedup = {}
    /\ providerLookups = {}
    /\ businessProjection = [p \in Parents |-> [captured |-> IF Scenario = "two_equal_partial_refunds_witness" THEN 20 ELSE 0, refunded |-> 0, reversals |-> 0]]
    /\ clientRequests = {}
    /\ clientResponses = {}
    /\ networkAvailable = TRUE
    /\ providerAvailable = TRUE
    /\ noFurtherCrashes = TRUE
    /\ recoveryOwner = [i \in Identities |-> None]
    /\ localRetention = [i \in Identities |-> TRUE]
    /\ providerRetention = [k \in ProviderKeys |-> TRUE]
    /\ lifecycleCaptured = [p \in Parents |-> IF Scenario = "two_equal_partial_refunds_witness" THEN 20 ELSE 0]
    /\ lifecycleRefunded = [p \in Parents |-> 0]
    /\ lifecycleReversed = [p \in Parents |-> FALSE]
    /\ lastAction = "Init"
    /\ history = <<>>

Hist(a) == Append(history, a)

AllowedRequest(i, p) ==
    \/ Scenario \in {"capture_minimal", "unknown_outcome_replay_provider", "unknown_outcome_lookup_provider", "unknown_outcome_opaque_provider", "projection_repair", "local_and_provider_expiry", "reversal_parent_state"} /\ i = "I1" /\ p = "FP_A"
    \/ Scenario = "changed_payload_all_states" /\ i = "I1" /\ p \in Payloads
    \/ Scenario = "concurrent_same_identity" /\ i = "I1" /\ p = "FP_A"
    \/ Scenario \in {"cross_scope_same_raw_key", "partial_capture_and_refund"} /\ i \in Identities /\ p = "FP_A"
    \/ Scenario = "combined_concurrent" /\ i \in Identities /\ p \in Payloads
    \/ Scenario = "liveness_fair" /\ i = "I1" /\ p = "FP_A"
    \/ Scenario = "two_equal_partial_refunds_witness" /\ i \in Identities /\ p = "FP_A"

AllowedService(s) == Scenario \in {"combined_concurrent", "concurrent_same_identity", "cross_scope_same_raw_key", "two_equal_partial_refunds_witness"} \/ s = "S1"

CanFault == Scenario \in {"unknown_outcome_replay_provider", "unknown_outcome_lookup_provider", "unknown_outcome_opaque_provider", "combined_concurrent"}
CanCrash == Scenario \in {"combined_concurrent", "unknown_outcome_replay_provider", "unknown_outcome_lookup_provider", "projection_repair"}

CommonUnchanged ==
    <<networkAvailable, providerAvailable, noFurtherCrashes>>

Submit(s, i, p) ==
    /\ serviceState[s] = "Idle"
    /\ ~crashed[s]
    /\ AllowedService(s)
    /\ AllowedRequest(i, p)
    /\ serviceState' = [serviceState EXCEPT ![s] = "Submitted"]
    /\ serviceIdentity' = [serviceIdentity EXCEPT ![s] = i]
    /\ servicePayload' = [servicePayload EXCEPT ![s] = p]
    /\ clientRequests' = clientRequests \cup {[svc |-> s, intent |-> i, payload |-> p, providerIdentity |-> ProviderKeyFor(i, FALSE)]}
    /\ lastAction' = "Submit"
    /\ history' = Hist("Submit")
    /\ UNCHANGED <<records, crashed, claimOwner, fence, leaseExpiry, logicalTime,
                  providerRequests, providerAcks, providerLedger, providerDedup,
                  providerLookups, businessProjection, clientResponses, recoveryOwner,
                  localRetention, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

ReadRecord(s) ==
    /\ serviceState[s] = "Submitted"
    /\ ~crashed[s]
    /\ serviceState' = [serviceState EXCEPT ![s] = "Read"]
    /\ lastAction' = "ReadRecord"
    /\ history' = Hist("ReadRecord")
    /\ UNCHANGED <<records, serviceIdentity, servicePayload, crashed, claimOwner,
                  fence, leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, clientResponses, recoveryOwner, localRetention,
                  providerRetention, lifecycleCaptured, lifecycleRefunded,
                  lifecycleReversed, networkAvailable, providerAvailable,
                  noFurtherCrashes>>

Claim(s) ==
    LET i == serviceIdentity[s]
        p == servicePayload[s]
        k == ProviderKeyFor(i, FALSE)
    IN
    /\ serviceState[s] = "Read"
    /\ ~crashed[s]
    /\ records[i].state \in {"ABSENT", "TOMBSTONE"} \/ Mutant = "formal_m3"
    /\ serviceState' = [serviceState EXCEPT ![s] = "Claimed"]
    /\ records' = [records EXCEPT ![i] = [
            state |-> "IN_PROGRESS",
            fp |-> p,
            owner |-> s,
            fence |-> fence[i] + 1,
            providerIdentity |-> k,
            providerRef |-> None,
            terminalPayload |-> None
        ]]
    /\ claimOwner' = [claimOwner EXCEPT ![i] = s]
    /\ fence' = [fence EXCEPT ![i] = @ + 1]
    /\ leaseExpiry' = [leaseExpiry EXCEPT ![i] = logicalTime + 2]
    /\ lastAction' = "Claim"
    /\ history' = Hist("Claim")
    /\ UNCHANGED <<serviceIdentity, servicePayload, crashed, logicalTime,
                  providerRequests, providerAcks, providerLedger, providerDedup,
                  providerLookups, businessProjection, clientRequests, clientResponses,
                  recoveryOwner, localRetention, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

LoseClaimRace(s) ==
    LET i == serviceIdentity[s] IN
    /\ serviceState[s] = "Read"
    /\ ~crashed[s]
    /\ records[i].state = "IN_PROGRESS"
    /\ records[i].owner # s
    /\ serviceState' = [serviceState EXCEPT ![s] = "Done"]
    /\ clientResponses' = clientResponses \cup {[intent |-> i, payload |-> servicePayload[s], status |-> "PENDING", providerRef |-> None]}
    /\ lastAction' = "LoseClaimRace"
    /\ history' = Hist("LoseClaimRace")
    /\ UNCHANGED <<records, serviceIdentity, servicePayload, crashed, claimOwner,
                  fence, leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, recoveryOwner, localRetention, providerRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

ProviderEffectCount(i) == Cardinality({e \in providerLedger : e.intent = i})
ProviderRefIntentSet(r) == {e.intent : e \in {x \in providerLedger : x.providerRef = r}}
ExactlyOneEffect(i) == ProviderEffectCount(i) = 1

AddProjection(i, p) ==
    [businessProjection EXCEPT ![IdentityParent(i)] =
        [captured |-> @.captured + IF IdentityKind(i) = "capture" THEN PayloadAmount(p) ELSE 0,
         refunded |-> @.refunded + IF IdentityKind(i) = "refund" THEN PayloadAmount(p) ELSE 0,
         reversals |-> @.reversals + IF IdentityKind(i) = "reversal" THEN 1 ELSE 0]]

SendProviderRequest(s) ==
    LET i == serviceIdentity[s]
        p == servicePayload[s]
        recovery == serviceState[s] = "Recovering"
        k == ProviderKeyFor(i, recovery)
        req == [svc |-> s, intent |-> i, payload |-> p, providerIdentity |-> k]
    IN
    /\ serviceState[s] \in {"Claimed", "Recovering"}
    /\ ~crashed[s]
    /\ providerAvailable
    /\ (records[i].owner = s \/ serviceState[s] = "Recovering" \/ Mutant = "formal_m5")
    /\ (records[i].fp = p \/ Mutant = "formal_m6")
    /\ providerRequests' = providerRequests \cup {req}
    /\ serviceState' = [serviceState EXCEPT ![s] = "Sent"]
    /\ lastAction' = "SendProviderRequest"
    /\ history' = Hist("SendProviderRequest")
    /\ UNCHANGED <<records, serviceIdentity, servicePayload, crashed, claimOwner,
                  fence, leaseExpiry, logicalTime, providerAcks, providerLedger,
                  providerDedup, providerLookups, businessProjection, clientRequests,
                  clientResponses, recoveryOwner, localRetention, providerRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

ProviderRefForService(k, s) ==
    IF k = "K1" /\ s = "S2" THEN "R3"
    ELSE IF k = "K2" /\ s = "S2" THEN "R4"
    ELSE ProviderRefFor(k)

EffectFor(s, i, k) == [svc |-> s, intent |-> i, providerIdentity |-> k, providerRef |-> ProviderRefForService(k, s)]

EffectBeforeClaim(s) ==
    LET i == serviceIdentity[s]
        k == ProviderKeyFor(i, FALSE)
    IN
    /\ Mutant = "formal_m1"
    /\ serviceState[s] = "Submitted"
    /\ providerLedger' = providerLedger \cup {EffectFor(s, i, k)}
    /\ providerDedup' = providerDedup \cup {k}
    /\ lastAction' = "EffectBeforeClaim"
    /\ history' = Hist("EffectBeforeClaim")
    /\ UNCHANGED <<records, serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
                  providerAcks, providerLookups, businessProjection, clientRequests,
                  clientResponses, recoveryOwner, localRetention, providerRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

ProviderCommit(s) ==
    LET i == serviceIdentity[s]
        p == servicePayload[s]
        k == ProviderKeyFor(i, serviceState[s] = "Recovering")
        e == EffectFor(s, i, k)
    IN
    /\ serviceState[s] = "Sent"
    /\ providerAvailable
    /\ k \notin providerDedup \/ Mutant \in {"formal_m4", "formal_m7", "formal_m10", "formal_m11"}
    /\ IdentityKind(i) # "refund" \/ lifecycleCaptured[IdentityParent(i)] >= PayloadAmount(p)
    /\ IdentityKind(i) # "reversal" \/ lifecycleCaptured[IdentityParent(i)] > 0
    /\ providerLedger' = providerLedger \cup {e}
    /\ providerDedup' = providerDedup \cup {k}
    /\ providerAcks' = providerAcks \cup {[intent |-> i, providerIdentity |-> k, found |-> TRUE]}
    /\ records' = [records EXCEPT ![i] = [
            state |-> "COMPLETED",
            fp |-> records[i].fp,
            owner |-> records[i].owner,
            fence |-> records[i].fence,
            providerIdentity |-> k,
            providerRef |-> ProviderRefFor(k),
            terminalPayload |-> p
        ]]
    /\ businessProjection' = IF Mutant = "formal_m8" THEN businessProjection ELSE AddProjection(i, p)
    /\ lifecycleCaptured' = [lifecycleCaptured EXCEPT ![IdentityParent(i)] = @ + IF IdentityKind(i) = "capture" THEN PayloadAmount(p) ELSE 0]
    /\ lifecycleRefunded' = [lifecycleRefunded EXCEPT ![IdentityParent(i)] = @ + IF IdentityKind(i) = "refund" THEN PayloadAmount(p) ELSE 0]
    /\ lifecycleReversed' = [lifecycleReversed EXCEPT ![IdentityParent(i)] = IF IdentityKind(i) = "reversal" THEN TRUE ELSE @]
    /\ clientResponses' = clientResponses \cup {[intent |-> i, payload |-> p, status |-> "COMPLETED", providerRef |-> ProviderRefFor(k)]}
    /\ serviceState' = [serviceState EXCEPT ![s] = "Done"]
    /\ lastAction' = "ProviderCommit"
    /\ history' = Hist("ProviderCommit")
    /\ UNCHANGED <<serviceIdentity, servicePayload, crashed, claimOwner, fence,
                  leaseExpiry, logicalTime, providerRequests, providerLookups,
                  clientRequests, recoveryOwner, localRetention, providerRetention,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

ProviderReject(s) ==
    LET i == serviceIdentity[s]
        p == servicePayload[s]
    IN
    /\ serviceState[s] = "Sent"
    /\ Scenario # "liveness_fair"
    /\ providerAvailable
    /\ records' = [records EXCEPT ![i] = [
            state |-> "REJECTED_FINAL",
            fp |-> records[i].fp,
            owner |-> records[i].owner,
            fence |-> records[i].fence,
            providerIdentity |-> records[i].providerIdentity,
            providerRef |-> None,
            terminalPayload |-> p
        ]]
    /\ clientResponses' = clientResponses \cup {[intent |-> i, payload |-> p, status |-> "REJECTED_FINAL", providerRef |-> None]}
    /\ serviceState' = [serviceState EXCEPT ![s] = "Done"]
    /\ lastAction' = "ProviderReject"
    /\ history' = Hist("ProviderReject")
    /\ UNCHANGED <<serviceIdentity, servicePayload, crashed, claimOwner, fence,
                  leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, recoveryOwner, localRetention, providerRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

ProviderNoCommitTimeout(s) ==
    /\ serviceState[s] = "Sent"
    /\ CanFault
    /\ serviceState' = [serviceState EXCEPT ![s] = "UnknownSeen"]
    /\ lastAction' = "ProviderNoCommitTimeout"
    /\ history' = Hist("ProviderNoCommitTimeout")
    /\ UNCHANGED <<records, serviceIdentity, servicePayload, crashed, claimOwner,
                  fence, leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, clientResponses, recoveryOwner, localRetention,
                  providerRetention, lifecycleCaptured, lifecycleRefunded,
                  lifecycleReversed, networkAvailable, providerAvailable,
                  noFurtherCrashes>>

ProviderCommitAndDropAck(s) ==
    LET i == serviceIdentity[s]
        k == ProviderKeyFor(i, FALSE)
        e == EffectFor(s, i, k)
    IN
    /\ serviceState[s] = "Sent"
    /\ CanFault
    /\ providerLedger' = providerLedger \cup {e}
    /\ providerDedup' = providerDedup \cup {k}
    /\ serviceState' = [serviceState EXCEPT ![s] = "UnknownSeen"]
    /\ lastAction' = "ProviderCommitAndDropAck"
    /\ history' = Hist("ProviderCommitAndDropAck")
    /\ UNCHANGED <<records, serviceIdentity, servicePayload, crashed, claimOwner,
                  fence, leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLookups, businessProjection, clientRequests, clientResponses,
                  recoveryOwner, localRetention, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

DeliverAck(s) ==
    LET i == serviceIdentity[s] IN
    /\ serviceState[s] = "UnknownSeen"
    /\ networkAvailable
    /\ \E ack \in providerAcks : ack.intent = i
    /\ serviceState' = [serviceState EXCEPT ![s] = "Done"]
    /\ lastAction' = "DeliverAck"
    /\ history' = Hist("DeliverAck")
    /\ UNCHANGED <<records, serviceIdentity, servicePayload, crashed, claimOwner,
                  fence, leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, clientResponses, recoveryOwner, localRetention,
                  providerRetention, lifecycleCaptured, lifecycleRefunded,
                  lifecycleReversed, networkAvailable, providerAvailable,
                  noFurtherCrashes>>

PersistCompletion(s) == ProviderCommit(s)
PersistFinalRejection(s) == ProviderReject(s)

MarkUnknown(s) ==
    LET i == serviceIdentity[s]
        p == servicePayload[s]
    IN
    /\ serviceState[s] = "UnknownSeen"
    /\ records' = [records EXCEPT ![i] = [
            state |-> IF Mutant = "formal_m2" THEN "REJECTED_FINAL" ELSE "UNKNOWN",
            fp |-> records[i].fp,
            owner |-> records[i].owner,
            fence |-> records[i].fence,
            providerIdentity |-> records[i].providerIdentity,
            providerRef |-> records[i].providerRef,
            terminalPayload |-> IF Mutant = "formal_m2" THEN p ELSE None
        ]]
    /\ clientResponses' = clientResponses \cup {[intent |-> i, payload |-> p, status |-> IF Mutant = "formal_m2" THEN "REJECTED_FINAL" ELSE "UNKNOWN", providerRef |-> None]}
    /\ serviceState' = [serviceState EXCEPT ![s] = "Done"]
    /\ lastAction' = "MarkUnknown"
    /\ history' = Hist("MarkUnknown")
    /\ UNCHANGED <<serviceIdentity, servicePayload, crashed, claimOwner, fence,
                  leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, recoveryOwner, localRetention, providerRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

Crash(s) ==
    /\ CanCrash
    /\ ~crashed[s]
    /\ crashed' = [crashed EXCEPT ![s] = TRUE]
    /\ serviceState' = [serviceState EXCEPT ![s] = "Crashed"]
    /\ lastAction' = "Crash"
    /\ history' = Hist("Crash")
    /\ UNCHANGED <<records, serviceIdentity, servicePayload, claimOwner, fence,
                  leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, clientResponses, recoveryOwner, localRetention,
                  providerRetention, lifecycleCaptured, lifecycleRefunded,
                  lifecycleReversed, networkAvailable, providerAvailable,
                  noFurtherCrashes>>

Restart(s) ==
    /\ crashed[s]
    /\ crashed' = [crashed EXCEPT ![s] = FALSE]
    /\ serviceState' = [serviceState EXCEPT ![s] = "Idle"]
    /\ lastAction' = "Restart"
    /\ history' = Hist("Restart")
    /\ UNCHANGED <<records, serviceIdentity, servicePayload, claimOwner, fence,
                  leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, clientResponses, recoveryOwner, localRetention,
                  providerRetention, lifecycleCaptured, lifecycleRefunded,
                  lifecycleReversed, networkAvailable, providerAvailable,
                  noFurtherCrashes>>

AcquireRecoveryLease(s, i) ==
    /\ serviceState[s] = "Idle"
    /\ ~crashed[s]
    /\ records[i].state = "UNKNOWN"
    /\ logicalTime >= leaseExpiry[i]
    /\ serviceState' = [serviceState EXCEPT ![s] = "Recovering"]
    /\ serviceIdentity' = [serviceIdentity EXCEPT ![s] = i]
    /\ servicePayload' = [servicePayload EXCEPT ![s] = records[i].fp]
    /\ recoveryOwner' = [recoveryOwner EXCEPT ![i] = s]
    /\ records' = [records EXCEPT ![i].owner = s, ![i].fence = records[i].fence + 1]
    /\ lastAction' = "AcquireRecoveryLease"
    /\ history' = Hist("AcquireRecoveryLease")
    /\ UNCHANGED <<crashed, claimOwner, fence, leaseExpiry, logicalTime,
                  providerRequests, providerAcks, providerLedger, providerDedup,
                  providerLookups, businessProjection, clientRequests, clientResponses,
                  localRetention, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

RecoveryLookup(s) ==
    LET i == serviceIdentity[s]
        k == ProviderKeyFor(i, FALSE)
        found == k \in providerDedup
    IN
    /\ serviceState[s] = "Recovering"
    /\ ProviderProfile = "authoritative_lookup"
    /\ providerLookups' = providerLookups \cup {[intent |-> i, providerIdentity |-> k, found |-> found]}
    /\ IF found
       THEN /\ records' = [records EXCEPT ![i].state = "COMPLETED",
                                           ![i].providerRef = ProviderRefFor(k),
                                           ![i].terminalPayload = records[i].fp]
            /\ businessProjection' = IF Mutant = "formal_m8" THEN businessProjection ELSE AddProjection(i, records[i].fp)
            /\ clientResponses' = clientResponses \cup {[intent |-> i, payload |-> records[i].fp, status |-> "COMPLETED", providerRef |-> ProviderRefFor(k)]}
            /\ serviceState' = [serviceState EXCEPT ![s] = "Done"]
       ELSE /\ records' = records
            /\ businessProjection' = businessProjection
            /\ clientResponses' = clientResponses
            /\ serviceState' = [serviceState EXCEPT ![s] = "Recovering"]
    /\ lastAction' = "RecoveryLookup"
    /\ history' = Hist("RecoveryLookup")
    /\ UNCHANGED <<serviceIdentity, servicePayload, crashed, claimOwner, fence,
                  leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLedger, providerDedup, clientRequests, recoveryOwner,
                  localRetention, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

RecoveryReplay(s) == SendProviderRequest(s)

ProjectionMatches(i) ==
    records[i].state = "COMPLETED" =>
      businessProjection[IdentityParent(i)].captured >= IF IdentityKind(i) = "capture" THEN PayloadAmount(records[i].terminalPayload) ELSE 0

RepairProjection(s, i) ==
    /\ records[i].state = "COMPLETED"
    /\ ~ProjectionMatches(i)
    /\ Mutant # "formal_m8"
    /\ businessProjection' = AddProjection(i, records[i].terminalPayload)
    /\ lastAction' = "RepairProjection"
    /\ history' = Hist("RepairProjection")
    /\ UNCHANGED <<records, serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
                  providerAcks, providerLedger, providerDedup, providerLookups,
                  clientRequests, clientResponses, recoveryOwner, localRetention,
                  providerRetention, lifecycleCaptured, lifecycleRefunded,
                  lifecycleReversed, networkAvailable, providerAvailable,
                  noFurtherCrashes>>

ExpireLocalRecord(i) ==
    /\ Scenario \in {"local_and_provider_expiry", "combined_concurrent"}
    /\ records[i].state \in TerminalStates
    /\ localRetention[i] \/ Mutant = "formal_m9"
    /\ localRetention' = [localRetention EXCEPT ![i] = FALSE]
    /\ records' = [records EXCEPT ![i].state = IF Mutant = "formal_m9" THEN "ABSENT" ELSE "TOMBSTONE"]
    /\ lastAction' = "ExpireLocalRecord"
    /\ history' = Hist("ExpireLocalRecord")
    /\ UNCHANGED <<serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
                  providerAcks, providerLedger, providerDedup, providerLookups,
                  businessProjection, clientRequests, clientResponses,
                  recoveryOwner, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

ExpireProviderRecord(k) ==
    /\ Scenario \in {"local_and_provider_expiry", "combined_concurrent"}
    /\ providerRetention[k]
    /\ providerRetention' = [providerRetention EXCEPT ![k] = FALSE]
    /\ providerDedup' = providerDedup \ {k}
    /\ lastAction' = "ExpireProviderRecord"
    /\ history' = Hist("ExpireProviderRecord")
    /\ UNCHANGED <<records, serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
                  providerAcks, providerLedger, providerLookups, businessProjection,
                  clientRequests, clientResponses, recoveryOwner, localRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

CreateTombstone(i) ==
    /\ records[i].state = "ABSENT"
    /\ Scenario # "liveness_fair"
    /\ records' = [records EXCEPT ![i].state = "TOMBSTONE"]
    /\ lastAction' = "CreateTombstone"
    /\ history' = Hist("CreateTombstone")
    /\ UNCHANGED <<serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
                  providerAcks, providerLedger, providerDedup, providerLookups,
                  businessProjection, clientRequests, clientResponses,
                  recoveryOwner, localRetention, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

AdvanceTime ==
    /\ logicalTime < 10
    /\ logicalTime' = logicalTime + 1
    /\ lastAction' = "AdvanceTime"
    /\ history' = Hist("AdvanceTime")
    /\ UNCHANGED <<records, serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, providerRequests, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, clientResponses, recoveryOwner, localRetention,
                  providerRetention, lifecycleCaptured, lifecycleRefunded,
                  lifecycleReversed, networkAvailable, providerAvailable,
                  noFurtherCrashes>>

ReplayTerminal(s, p) ==
    LET i == serviceIdentity[s] IN
    /\ serviceState[s] = "Idle"
    /\ Scenario # "liveness_fair"
    /\ records[i].state \in TerminalStates
    /\ AllowedRequest(i, p)
    /\ IF records[i].fp # p /\ Mutant # "formal_m6"
       THEN /\ clientResponses' = clientResponses \cup {[intent |-> i, payload |-> p, status |-> "CONFLICT", providerRef |-> None]}
            /\ providerRequests' = providerRequests
       ELSE /\ clientResponses' = clientResponses \cup {[intent |-> i, payload |-> p, status |-> records[i].state, providerRef |-> records[i].providerRef]}
            /\ providerRequests' = providerRequests \cup IF Mutant = "formal_m7" THEN {[svc |-> s, intent |-> i, payload |-> p, providerIdentity |-> ProviderKeyFor(i, FALSE)]} ELSE {}
    /\ lastAction' = "ReplayTerminal"
    /\ history' = Hist("ReplayTerminal")
    /\ UNCHANGED <<records, serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerAcks,
                  providerLedger, providerDedup, providerLookups, businessProjection,
                  clientRequests, recoveryOwner, localRetention, providerRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

RejectChangedPayload(s, p) == ReplayTerminal(s, p)
PartialCapture(s) == ProviderCommit(s)
Refund(s) == ProviderCommit(s)
PartialRefund(s) == ProviderCommit(s)
Reversal(s) == ProviderCommit(s)

RawKeyAliasReplay(i, j) ==
    /\ Mutant = "formal_m4"
    /\ i # j
    /\ records[i].state = "COMPLETED"
    /\ records[j].state = "ABSENT"
    /\ IdentityRawKey(i) = IdentityRawKey(j)
    /\ records' = [records EXCEPT ![j] = [
            state |-> "COMPLETED",
            fp |-> records[i].fp,
            owner |-> records[i].owner,
            fence |-> 1,
            providerIdentity |-> records[i].providerIdentity,
            providerRef |-> records[i].providerRef,
            terminalPayload |-> records[i].terminalPayload
        ]]
    /\ clientResponses' = clientResponses \cup {[intent |-> j, payload |-> records[i].fp, status |-> "COMPLETED", providerRef |-> records[i].providerRef]}
    /\ lastAction' = "RawKeyAliasReplay"
    /\ history' = Hist("RawKeyAliasReplay")
    /\ UNCHANGED <<serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
                  providerAcks, providerLedger, providerDedup, providerLookups,
                  businessProjection, clientRequests, recoveryOwner,
                  localRetention, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

ParentAmountDedupAlias(i, j) ==
    /\ Mutant = "formal_m10"
    /\ i # j
    /\ records[i].state = "COMPLETED"
    /\ records[j].state = "ABSENT"
    /\ IdentityParent(i) = IdentityParent(j)
    /\ records' = [records EXCEPT ![j] = [
            state |-> "COMPLETED",
            fp |-> records[i].fp,
            owner |-> records[i].owner,
            fence |-> 1,
            providerIdentity |-> "PARENT_AMOUNT",
            providerRef |-> records[i].providerRef,
            terminalPayload |-> records[i].terminalPayload
        ]]
    /\ clientResponses' = clientResponses \cup {[intent |-> j, payload |-> records[i].fp, status |-> "COMPLETED", providerRef |-> records[i].providerRef]}
    /\ lastAction' = "ParentAmountDedupAlias"
    /\ history' = Hist("ParentAmountDedupAlias")
    /\ UNCHANGED <<serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
                  providerAcks, providerLedger, providerDedup, providerLookups,
                  businessProjection, clientRequests, recoveryOwner,
                  localRetention, providerRetention, lifecycleCaptured,
                  lifecycleRefunded, lifecycleReversed, networkAvailable,
                  providerAvailable, noFurtherCrashes>>

LosingClaimantProviderCall(s) ==
    LET i == serviceIdentity[s]
        k == ProviderKeyFor(i, FALSE)
    IN
    /\ Mutant = "formal_m5"
    /\ serviceState[s] = "Read"
    /\ records[i].state = "IN_PROGRESS"
    /\ records[i].owner # s
    /\ providerLedger' = providerLedger \cup {EffectFor(s, i, k)}
    /\ providerDedup' = providerDedup \cup {k}
    /\ lastAction' = "LosingClaimantProviderCall"
    /\ history' = Hist("LosingClaimantProviderCall")
    /\ UNCHANGED <<records, serviceState, serviceIdentity, servicePayload, crashed,
                  claimOwner, fence, leaseExpiry, logicalTime, providerRequests,
                  providerAcks, providerLookups, businessProjection, clientRequests,
                  clientResponses, recoveryOwner, localRetention, providerRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

ProviderKeyDriftRecovery(s) ==
    LET i == serviceIdentity[s]
        k == ProviderKeyFor(i, TRUE)
    IN
    /\ Mutant = "formal_m11"
    /\ serviceState[s] = "UnknownSeen"
    /\ ProviderKeyFor(i, FALSE) \in providerDedup
    /\ providerLedger' = providerLedger \cup {EffectFor(s, i, k)}
    /\ providerDedup' = providerDedup \cup {k}
    /\ records' = [records EXCEPT ![i].state = "COMPLETED",
                                   ![i].providerIdentity = k,
                                   ![i].providerRef = ProviderRefForService(k, s),
                                   ![i].terminalPayload = records[i].fp]
    /\ clientResponses' = clientResponses \cup {[intent |-> i, payload |-> records[i].fp, status |-> "COMPLETED", providerRef |-> ProviderRefForService(k, s)]}
    /\ serviceState' = [serviceState EXCEPT ![s] = "Done"]
    /\ lastAction' = "ProviderKeyDriftRecovery"
    /\ history' = Hist("ProviderKeyDriftRecovery")
    /\ UNCHANGED <<serviceIdentity, servicePayload, crashed, claimOwner, fence,
                  leaseExpiry, logicalTime, providerRequests, providerAcks,
                  providerLookups, businessProjection, clientRequests,
                  recoveryOwner, localRetention, providerRetention,
                  lifecycleCaptured, lifecycleRefunded, lifecycleReversed,
                  networkAvailable, providerAvailable, noFurtherCrashes>>

Next ==
    /\ Len(history) < MaxDepth
    /\ \/ \E s \in Services, i \in Identities, p \in Payloads : Submit(s, i, p)
       \/ \E s \in Services : ReadRecord(s)
       \/ \E s \in Services : Claim(s)
       \/ \E s \in Services : EffectBeforeClaim(s)
       \/ \E s \in Services : LoseClaimRace(s)
       \/ \E s \in Services : SendProviderRequest(s)
       \/ \E s \in Services : LosingClaimantProviderCall(s)
       \/ \E s \in Services : ProviderKeyDriftRecovery(s)
       \/ \E s \in Services : ProviderCommit(s)
       \/ \E i, j \in Identities : RawKeyAliasReplay(i, j)
       \/ \E i, j \in Identities : ParentAmountDedupAlias(i, j)
       \/ \E s \in Services : ProviderReject(s)
       \/ \E s \in Services : ProviderNoCommitTimeout(s)
       \/ \E s \in Services : ProviderCommitAndDropAck(s)
       \/ \E s \in Services : DeliverAck(s)
       \/ \E s \in Services : MarkUnknown(s)
       \/ \E s \in Services : Crash(s)
       \/ \E s \in Services : Restart(s)
       \/ \E s \in Services, i \in Identities : AcquireRecoveryLease(s, i)
       \/ \E s \in Services : RecoveryLookup(s)
       \/ \E s \in Services, i \in Identities : RepairProjection(s, i)
       \/ \E i \in Identities : ExpireLocalRecord(i)
       \/ \E k \in ProviderKeys : ExpireProviderRecord(k)
       \/ \E i \in Identities : CreateTombstone(i)
       \/ AdvanceTime
       \/ \E s \in Services, p \in Payloads : ReplayTerminal(s, p)

TypeOK ==
    /\ records \in [Identities -> [state: RecordStates, fp: Payloads \cup {None}, owner: Services \cup {None}, fence: 0..5, providerIdentity: ProviderKeys \cup {None}, providerRef: ProviderRefs \cup {None}, terminalPayload: Payloads \cup {None}]]
    /\ serviceState \in [Services -> SvcStates]
    /\ serviceIdentity \in [Services -> Identities]
    /\ servicePayload \in [Services -> Payloads]
    /\ crashed \in [Services -> BOOLEAN]
    /\ claimOwner \in [Identities -> Services \cup {None}]
    /\ fence \in [Identities -> 0..5]
    /\ leaseExpiry \in [Identities -> 0..10]
    /\ logicalTime \in 0..10
    /\ providerRequests \subseteq RequestUniverse
    /\ providerAcks \subseteq LookupUniverse
    /\ providerLedger \subseteq EffectUniverse
    /\ providerDedup \subseteq ProviderKeys
    /\ providerLookups \subseteq LookupUniverse
    /\ businessProjection \in [Parents -> [captured: 0..30, refunded: 0..30, reversals: 0..2]]
    /\ clientRequests \subseteq RequestUniverse
    /\ clientResponses \subseteq ResponseUniverse
    /\ networkAvailable \in BOOLEAN
    /\ providerAvailable \in BOOLEAN
    /\ noFurtherCrashes \in BOOLEAN
    /\ recoveryOwner \in [Identities -> Services \cup {None}]
    /\ localRetention \in [Identities -> BOOLEAN]
    /\ providerRetention \in [ProviderKeys -> BOOLEAN]
    /\ lifecycleCaptured \in [Parents -> 0..30]
    /\ lifecycleRefunded \in [Parents -> 0..30]
    /\ lifecycleReversed \in [Parents -> BOOLEAN]
    /\ Len(history) <= 12

P1 ==
    /\ \A i \in Identities : Cardinality({e \in providerLedger : e.intent = i}) <= 1
    /\ \A e \in providerLedger : records[e.intent].fence > 0

P2 ==
    /\ \A r \in ProviderRefs : Cardinality(ProviderRefIntentSet(r)) <= 1
    /\ \A r \in ProviderRefs : Cardinality({i \in Identities : records[i].providerRef = r}) <= 1
    /\ \A e1, e2 \in providerLedger :
        e1.providerIdentity = e2.providerIdentity => e1.intent = e2.intent

ChangedPayloadSafe(i) ==
    \A r \in clientResponses :
        (r.intent = i /\ records[i].fp # None /\ r.payload # records[i].fp)
        => r.status = "CONFLICT"

P4 == \A i \in Identities : ChangedPayloadSafe(i)

TerminalReplayNoNewEffect(i) ==
    Cardinality({r \in clientResponses : r.intent = i /\ r.status \in TerminalStates}) > 0
    => /\ ProviderEffectCount(i) <= 1
       /\ Cardinality({req \in providerRequests : req.intent = i}) <= 1

P5 == \A i \in Identities : TerminalReplayNoNewEffect(i)

NoCommittedFinalRejection(i) ==
    ~(records[i].state = "REJECTED_FINAL" /\ Cardinality({e \in providerLedger : e.intent = i}) = 1)

RetentionConsistent(i) ==
    (ProviderEffectCount(i) = 1 /\ ~localRetention[i]) => records[i].state = "TOMBSTONE"

P6Inv == \A i \in Identities : ProjectionMatches(i) /\ NoCommittedFinalRejection(i) /\ RetentionConsistent(i)

P7 ==
    \A p \in Parents :
        /\ lifecycleCaptured[p] <= 20
        /\ lifecycleRefunded[p] <= lifecycleCaptured[p]
        /\ businessProjection[p].refunded <= businessProjection[p].captured

OpaqueLimitation ==
    ~(ProviderProfile = "opaque_provider"
      /\ \E i \in Identities : records[i].state = "UNKNOWN" /\ ProviderEffectCount(i) = 1)

NetworkAvailable == networkAvailable
ProviderAvailable == providerAvailable
NoFurtherCrashes == noFurtherCrashes /\ \A s \in Services : ~crashed[s]
StableNow == NetworkAvailable /\ ProviderAvailable /\ NoFurtherCrashes
EventuallyStable == <>[]StableNow

RecoverableMismatch(i) ==
    records[i].state \in {"UNKNOWN", "COMPLETED"}
    /\ Cardinality({e \in providerLedger : e.intent = i}) = 1
    /\ ~ProjectionMatches(i)

Reconciled(i) == records[i].state = "COMPLETED" /\ ProjectionMatches(i)

P3 == EventuallyStable => \A i \in Identities : Required(i) ~> ExactlyOneEffect(i)
P6 == EventuallyStable => \A i \in Identities : RecoverableMismatch(i) ~> Reconciled(i)

Fairness ==
    /\ WF_vars(\E s \in Services : DeliverAck(s))
    /\ WF_vars(\E s \in Services : RecoveryLookup(s))
    /\ WF_vars(\E s \in Services, i \in Identities : RepairProjection(s, i))
    /\ WF_vars(\E s \in Services : ReadRecord(s))
    /\ WF_vars(\E s \in Services : Claim(s))
    /\ WF_vars(\E s \in Services : SendProviderRequest(s))
    /\ WF_vars(\E s \in Services : ProviderCommit(s))

Spec == Init /\ [][Next]_vars /\ Fairness
SpecNoRecoveryFairness == Init /\ [][Next]_vars /\ WF_vars(\E s \in Services : DeliverAck(s))

SuccessfulCompletionWitness == \E i \in Identities : records[i].state = "COMPLETED" /\ ExactlyOneEffect(i)
FinalRejectionWitness == \E i \in Identities : records[i].state = "REJECTED_FINAL"
ChangedPayloadConflictWitness == \E r \in clientResponses : r.status = "CONFLICT"
ConcurrentSameIdentityWitness == \E i \in Identities : Cardinality({req \in clientRequests : req.intent = i}) >= 2
DistinctRawKeyWitness == Cardinality({req.intent : req \in {x \in clientRequests : IdentityRawKey(x.intent) = "RAW_SHARED"}}) >= 2
UnknownOutcomeWitness == \E i \in Identities : records[i].state = "UNKNOWN"
ProviderLookupRecoveryWitness == \E l \in providerLookups : l.found
ProviderReplayRecoveryWitness == \E req \in providerRequests : req.providerIdentity \in providerDedup
ProjectionMismatchWitness == \E i \in Identities : records[i].state = "COMPLETED" /\ ~ProjectionMatches(i)
ProjectionRepairWitness == \E i \in Identities : Reconciled(i)
LocalExpiryWitness == \E i \in Identities : ~localRetention[i]
ProviderExpiryWitness == \E k \in ProviderKeys : ~providerRetention[k]
PartialCaptureWitness == lifecycleCaptured["AUTH1"] > 0
TwoEqualRefundWitness == Cardinality({e \in providerLedger : IdentityKind(e.intent) = "refund"}) = 2
ReversalWitness == lifecycleReversed["AUTH1"]
CrashAfterCommitWitness == \E s \in Services : crashed[s] /\ Cardinality(providerLedger) > 0
CrashBeforeCompletionWitness == \E s \in Services : crashed[s] /\ \E i \in Identities : records[i].state = "IN_PROGRESS"
RecoveryTakeoverWitness == \E i \in Identities : recoveryOwner[i] # None

NoSuccessfulCompletionWitness == ~SuccessfulCompletionWitness
NoFinalRejectionWitness == ~FinalRejectionWitness
NoChangedPayloadConflictWitness == ~ChangedPayloadConflictWitness
NoConcurrentSameIdentityWitness == ~ConcurrentSameIdentityWitness
NoDistinctRawKeyWitness == ~DistinctRawKeyWitness
NoUnknownOutcomeWitness == ~UnknownOutcomeWitness
NoProviderLookupRecoveryWitness == ~ProviderLookupRecoveryWitness
NoProviderReplayRecoveryWitness == ~ProviderReplayRecoveryWitness
NoProjectionMismatchWitness == ~ProjectionMismatchWitness
NoLocalExpiryWitness == ~LocalExpiryWitness
NoProviderExpiryWitness == ~ProviderExpiryWitness
NoTwoEqualRefundWitness == ~TwoEqualRefundWitness

====
