package shrinker

import (
	"testing"

	"t8artifact/harness/cooperative"
	"t8artifact/internal/core"
)

func TestReducePreservesFingerprint(t *testing.T) {
	profile := core.ProviderProfile{Name: "opaque-provider"}
	schedule := core.Schedule{
		ScheduleID: "shrink-case",
		MutantID:   "exec_m1",
		Events: []core.Event{
			{
				ID:       "e1",
				Kind:     "request",
				Actor:    "svc-a",
				Behavior: core.ProviderCommitReply,
				Request: &core.Request{
					RequestID:     "r1",
					Identity:      core.Identity{Tenant: "t", OperationType: core.OpCapture, ParentResource: "p", CallerKey: "k", Epoch: 0},
					Payload:       core.Payload{Amount: 100, Currency: "USD"},
					RequireEffect: true,
				},
			},
			{ID: "e2", Kind: "advance_time", AdvanceBy: 1},
		},
	}
	initial, err := cooperative.Run(schedule, profile, "go-reserve-replay")
	if err != nil {
		t.Fatal(err)
	}
	reduced, report, err := Reduce(schedule, func(candidate core.Schedule) (core.RunResult, error) {
		return cooperative.Run(candidate, profile, "go-reserve-replay")
	}, initial.Observer.PropertyFingerprint)
	if err != nil {
		t.Fatal(err)
	}
	if len(reduced.Events) >= len(schedule.Events) {
		t.Fatalf("expected some reduction")
	}
	if !report.OneMinimal {
		t.Fatalf("expected 1-minimal report")
	}
}
