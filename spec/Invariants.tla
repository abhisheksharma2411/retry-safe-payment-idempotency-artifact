---- MODULE Invariants ----
EXTENDS Naturals

TypeOK(vars) ==
    /\ vars.state \in {"ABSENT", "IN_PROGRESS", "UNKNOWN", "COMPLETED", "REJECTED_FINAL", "TOMBSTONE"}
    /\ vars.effectCount \in 0..2
    /\ vars.aliasing \in BOOLEAN
    /\ vars.projectionOk \in BOOLEAN
    /\ vars.latePayloadReplay \in BOOLEAN
    /\ vars.replayReexec \in BOOLEAN
    /\ vars.loserCalledProvider \in BOOLEAN
    /\ vars.unknownAsRejected \in BOOLEAN
    /\ vars.captured \in 0..2
    /\ vars.refunded \in 0..2
    /\ vars.reversalCount \in 0..1
    /\ vars.phase \in 0..7
    /\ vars.stable \in BOOLEAN
    /\ vars.retentionOk \in BOOLEAN
    /\ vars.secondRefundCompleted \in BOOLEAN

P1(vars) == vars.effectCount <= 1 /\ ~vars.loserCalledProvider
P2(vars) == ~vars.aliasing
P3(vars) == ~(vars.required /\ vars.stable /\ vars.state # "COMPLETED")
P4(vars) == ~vars.latePayloadReplay
P5(vars) == ~vars.replayReexec
P6(vars) == vars.projectionOk /\ ~(vars.state = "REJECTED_FINAL" /\ vars.effectCount = 1)
P7(vars) == vars.refunded <= vars.captured

====
