package core

import "testing"

func TestFingerprintIgnoresMapOrder(t *testing.T) {
	a := Payload{
		Amount:   100,
		Currency: "USD",
		Options:  map[string]string{"b": "2", "a": "1"},
	}
	b := Payload{
		Amount:   100,
		Currency: "USD",
		Options:  map[string]string{"a": "1", "b": "2"},
	}
	if a.Fingerprint() != b.Fingerprint() {
		t.Fatalf("fingerprint must be deterministic")
	}
}

func TestChangedPayloadRejectedBeforeReplay(t *testing.T) {
	profile := ProviderProfile{Name: "idempotent-replay", Deduplication: true, ProviderRetention: 10}
	engine := NewEngine("go-reserve-replay", profile, MutantByID("safe"))
	schedule := Schedule{
		ScheduleID: "changed_payload_before_replay",
		Events: []Event{
			{
				ID:       "e1",
				Kind:     "request",
				Actor:    "svc-a",
				Behavior: ProviderCommitReply,
				Request: &Request{
					RequestID: "r1",
					Identity: Identity{
						Tenant: "t1", OperationType: OpCapture, ParentResource: "auth-1", CallerKey: "key-1", Epoch: 0,
					},
					Payload:       Payload{Amount: 100, Currency: "USD"},
					RequireEffect: true,
				},
			},
			{
				ID:       "e2",
				Kind:     "request",
				Actor:    "svc-a",
				Behavior: ProviderCommitReply,
				Request: &Request{
					RequestID: "r2",
					Identity: Identity{
						Tenant: "t1", OperationType: OpCapture, ParentResource: "auth-1", CallerKey: "key-1", Epoch: 0,
					},
					Payload:       Payload{Amount: 101, Currency: "USD"},
					RequireEffect: true,
				},
			},
		},
	}
	result, err := engine.Run("cooperative", schedule.ScheduleID, schedule)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Responses[1].Conflict {
		t.Fatalf("expected conflict for changed payload")
	}
	for _, trace := range result.Trace {
		if trace.Action == "ReplayTerminal" && trace.EventID == "e2" {
			t.Fatalf("replay must not occur before payload conflict")
		}
	}
}

func TestUnknownSeparateFromFinalRejection(t *testing.T) {
	profile := ProviderProfile{Name: "opaque-provider"}
	engine := NewEngine("go-reserve-replay", profile, MutantByID("safe"))
	schedule := Schedule{
		ScheduleID: "unknown_opaque",
		Events: []Event{
			{
				ID:       "e1",
				Kind:     "request",
				Actor:    "svc-a",
				Behavior: ProviderCommitDropReply,
				Request: &Request{
					RequestID: "r1",
					Identity: Identity{
						Tenant: "t1", OperationType: OpCapture, ParentResource: "auth-1", CallerKey: "key-u", Epoch: 0,
					},
					Payload:       Payload{Amount: 100, Currency: "USD"},
					RequireEffect: true,
				},
			},
		},
	}
	result, err := engine.Run("cooperative", schedule.ScheduleID, schedule)
	if err != nil {
		t.Fatal(err)
	}
	record := result.Records["t1|capture|auth-1|key-u|0"]
	if record.State != StateUnknown {
		t.Fatalf("expected UNKNOWN, got %s", record.State)
	}
}

func TestLosingClaimRacerDoesNotCallProvider(t *testing.T) {
	profile := ProviderProfile{Name: "idempotent-replay", Deduplication: true, ProviderRetention: 10}
	engine := NewEngine("go-reserve-replay", profile, MutantByID("safe"))
	schedule := Schedule{
		ScheduleID: "loser_no_provider",
		Events: []Event{
			{
				ID:       "e1",
				Kind:     "request",
				Actor:    "svc-a",
				Behavior: ProviderCommitReply,
				Request: &Request{
					RequestID: "r1",
					Identity: Identity{
						Tenant: "t1", OperationType: OpCapture, ParentResource: "auth-1", CallerKey: "key-race", Epoch: 0,
					},
					Payload:       Payload{Amount: 100, Currency: "USD"},
					RequireEffect: true,
				},
			},
			{
				ID:       "e2",
				Kind:     "request",
				Actor:    "svc-b",
				Behavior: ProviderCommitReply,
				Request: &Request{
					RequestID: "r2",
					Identity: Identity{
						Tenant: "t1", OperationType: OpCapture, ParentResource: "auth-1", CallerKey: "key-race", Epoch: 0,
					},
					Payload:       Payload{Amount: 100, Currency: "USD"},
					RequireEffect: true,
				},
			},
		},
	}
	result, err := engine.Run("cooperative", schedule.ScheduleID, schedule)
	if err != nil {
		t.Fatal(err)
	}
	for _, trace := range result.Trace {
		if trace.Action == "LoserCalledProvider" {
			t.Fatalf("safe implementation must not call provider after losing claim")
		}
	}
}

func TestDistinctEqualRefundsBothComplete(t *testing.T) {
	profile := ProviderProfile{Name: "idempotent-replay", Deduplication: true, ProviderRetention: 10}
	engine := NewEngine("go-reserve-replay", profile, MutantByID("safe"))
	schedule := Schedule{
		ScheduleID: "equal_refunds",
		Events: []Event{
			{
				ID:       "c1",
				Kind:     "request",
				Actor:    "svc-a",
				Behavior: ProviderCommitReply,
				Request: &Request{
					RequestID: "cap-1",
					Identity: Identity{
						Tenant: "t1", OperationType: OpCapture, ParentResource: "pay-1", CallerKey: "cap-key", Epoch: 0,
					},
					Payload:       Payload{Amount: 100, Currency: "USD"},
					RequireEffect: true,
				},
			},
			{
				ID:       "r1",
				Kind:     "request",
				Actor:    "svc-a",
				Behavior: ProviderCommitReply,
				Request: &Request{
					RequestID: "refund-1",
					Identity: Identity{
						Tenant: "t1", OperationType: OpRefund, ParentResource: "pay-1", CallerKey: "refund-a", Epoch: 0,
					},
					Payload:       Payload{Amount: 50, Currency: "USD"},
					RequireEffect: true,
				},
			},
			{
				ID:       "r2",
				Kind:     "request",
				Actor:    "svc-b",
				Behavior: ProviderCommitReply,
				Request: &Request{
					RequestID: "refund-2",
					Identity: Identity{
						Tenant: "t1", OperationType: OpRefund, ParentResource: "pay-1", CallerKey: "refund-b", Epoch: 0,
					},
					Payload:       Payload{Amount: 50, Currency: "USD"},
					RequireEffect: true,
				},
			},
		},
	}
	result, err := engine.Run("cooperative", schedule.ScheduleID, schedule)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Observer.Passed {
		t.Fatalf("observer must accept two distinct equal refunds")
	}
	if got := result.Projection.RefundedByParent["pay-1"]; got != 100 {
		t.Fatalf("expected 100 total refunds, got %d", got)
	}
}
