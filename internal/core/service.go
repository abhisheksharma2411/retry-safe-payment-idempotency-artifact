package core

import "fmt"

type MutantConfig struct {
	ID                          string
	EffectBeforeClaim           bool
	UnknownAsRejected           bool
	NonAtomicClaim              bool
	RawKeyOnlyScope             bool
	LoserCallsProvider          bool
	PayloadCheckedAfterReplay   bool
	TerminalReplayCallsProvider bool
	NoProjectionRepair          bool
	ShortRetention              bool
	ParentAmountDedup           bool
	ProviderKeyDrift            bool
	StaleWorkerAllowed          bool
}

func MutantByID(id string) MutantConfig {
	switch id {
	case "", "safe":
		return MutantConfig{ID: "safe"}
	case "formal_m1", "exec_m1":
		return MutantConfig{ID: id, EffectBeforeClaim: true}
	case "formal_m2", "exec_m2":
		return MutantConfig{ID: id, UnknownAsRejected: true}
	case "formal_m3", "exec_m3":
		return MutantConfig{ID: id, NonAtomicClaim: true}
	case "formal_m4", "exec_m4":
		return MutantConfig{ID: id, RawKeyOnlyScope: true}
	case "formal_m5", "exec_m5":
		return MutantConfig{ID: id, LoserCallsProvider: true}
	case "formal_m6", "exec_m6":
		return MutantConfig{ID: id, PayloadCheckedAfterReplay: true}
	case "formal_m7", "exec_m7":
		return MutantConfig{ID: id, TerminalReplayCallsProvider: true}
	case "formal_m8", "exec_m8":
		return MutantConfig{ID: id, NoProjectionRepair: true}
	case "formal_m9", "exec_m9":
		return MutantConfig{ID: id, ShortRetention: true}
	case "formal_m10", "exec_m10":
		return MutantConfig{ID: id, ParentAmountDedup: true}
	case "formal_m11", "exec_m11":
		return MutantConfig{ID: id, ProviderKeyDrift: true}
	case "exec_stale_worker":
		return MutantConfig{ID: id, StaleWorkerAllowed: true}
	default:
		return MutantConfig{ID: id}
	}
}

type Engine struct {
	impl       string
	profile    ProviderProfile
	mutant     MutantConfig
	provider   *Provider
	records    map[string]OperationRecord
	projection Projection
	trace      []TraceEvent
	responses  []Response
	step       int
}

func NewEngine(impl string, profile ProviderProfile, mutant MutantConfig) *Engine {
	return &Engine{
		impl:       impl,
		profile:    profile,
		mutant:     mutant,
		provider:   NewProvider(profile),
		records:    map[string]OperationRecord{},
		projection: NewProjection(),
		trace:      []TraceEvent{},
		responses:  []Response{},
	}
}

func (e *Engine) appendTrace(scheduleID, eventID, action, identity string, details map[string]string) {
	e.trace = append(e.trace, TraceEvent{
		Index:      len(e.trace),
		ScheduleID: scheduleID,
		EventID:    eventID,
		Action:     action,
		Identity:   identity,
		Details:    details,
	})
}

func (e *Engine) identityKey(req Request) string {
	if e.mutant.RawKeyOnlyScope {
		return req.Identity.CallerKey
	}
	if e.mutant.ParentAmountDedup && req.Identity.OperationType == OpRefund {
		return fmt.Sprintf("%s|refund|%d", req.Identity.ParentResource, req.Payload.Amount)
	}
	return req.Identity.String()
}

func (e *Engine) providerKey(req Request, identityKey string) string {
	if e.mutant.ProviderKeyDrift {
		return fmt.Sprintf("%s-%d", identityKey, e.step)
	}
	return identityKey
}

func (e *Engine) applyProjection(req Request, record OperationRecord) {
	if e.mutant.NoProjectionRepair {
		return
	}
	switch req.Identity.OperationType {
	case OpCapture:
		e.projection.CapturedByParent[req.Identity.ParentResource] += req.Payload.Amount
	case OpRefund:
		e.projection.RefundedByParent[req.Identity.ParentResource] += req.Payload.Amount
	case OpReversal:
		e.projection.ReversalsByParent[req.Identity.ParentResource]++
	}
	record.ExpiresAtStep = e.step + 12
	e.records[e.identityKey(req)] = record
}

func (e *Engine) claim(identityKey, fingerprint, actor, providerKey string, req Request) (OperationRecord, bool) {
	if current, ok := e.records[identityKey]; ok && current.State != StateTombstone {
		return current, false
	}
	record := OperationRecord{
		Identity:       req.Identity,
		State:          StateInProgress,
		Fingerprint:    fingerprint,
		Owner:          actor,
		Fence:          1,
		ProviderKey:    providerKey,
		LeaseUntilStep: e.step + 1,
		ExpiresAtStep:  e.step + 12,
		TombstoneUntil: e.step + 20,
	}
	e.records[identityKey] = record
	return record, true
}

func (e *Engine) replayResponse(req Request, state State, outcome Outcome) Response {
	outcome.ReplayOfState = state
	return Response{
		RequestID: req.RequestID,
		Identity:  req.Identity.String(),
		Status:    "replay",
		Outcome:   outcome,
	}
}

func (e *Engine) HandleRequest(scheduleID string, event Event) error {
	e.step++
	req := *event.Request
	identityKey := e.identityKey(req)
	fingerprint := req.Payload.Fingerprint()
	providerKey := e.providerKey(req, identityKey)
	record, hasRecord := e.records[identityKey]
	if e.mutant.RawKeyOnlyScope {
		e.appendTrace(scheduleID, event.ID, "RawKeyOnlyScope", identityKey, map[string]string{"semantic_identity": req.Identity.String()})
	}
	if e.mutant.ParentAmountDedup && req.Identity.OperationType == OpRefund {
		e.appendTrace(scheduleID, event.ID, "ParentAmountDedup", identityKey, map[string]string{"semantic_identity": req.Identity.String()})
	}

	if hasRecord && !e.mutant.PayloadCheckedAfterReplay && record.Fingerprint != "" && record.Fingerprint != fingerprint {
		e.appendTrace(scheduleID, event.ID, "PayloadConflict", identityKey, nil)
		e.responses = append(e.responses, Response{
			RequestID: req.RequestID,
			Identity:  req.Identity.String(),
			Status:    "conflict",
			Conflict:  true,
			Outcome: Outcome{
				Status:      "conflict",
				StableError: "PAYLOAD_CONFLICT",
				OperationID: req.Identity.String(),
				Amount:      req.Payload.Amount,
				Currency:    req.Payload.Currency,
			},
		})
		return nil
	}

	if hasRecord && (record.State == StateCompleted || record.State == StateRejectedFinal) {
		e.appendTrace(scheduleID, event.ID, "ReplayTerminal", identityKey, map[string]string{"state": string(record.State)})
		if e.mutant.NonAtomicClaim {
			if _, _, err := e.provider.Execute(e.step, req.Identity, providerKey, event.Behavior); err == nil {
				e.appendTrace(scheduleID, event.ID, "NonAtomicDoubleClaim", identityKey, nil)
			}
		}
		if e.mutant.LoserCallsProvider {
			if _, _, err := e.provider.Execute(e.step, req.Identity, providerKey, event.Behavior); err == nil {
				e.appendTrace(scheduleID, event.ID, "LoserCalledProvider", identityKey, nil)
			}
		}
		if e.mutant.TerminalReplayCallsProvider {
			if _, _, err := e.provider.Execute(e.step, req.Identity, providerKey, event.Behavior); err == nil {
				e.appendTrace(scheduleID, event.ID, "TerminalReplayReexecuted", identityKey, nil)
			}
		}
		if e.mutant.PayloadCheckedAfterReplay && record.Fingerprint != fingerprint {
			e.appendTrace(scheduleID, event.ID, "LatePayloadConflict", identityKey, nil)
		}
		e.responses = append(e.responses, e.replayResponse(req, record.State, record.Outcome))
		return nil
	}

	if !hasRecord {
		if e.mutant.EffectBeforeClaim {
			if _, _, err := e.provider.Execute(e.step, req.Identity, providerKey, event.Behavior); err == nil {
				e.appendTrace(scheduleID, event.ID, "ProviderCalledBeforeClaim", identityKey, nil)
			}
		}
		var claimed bool
		record, claimed = e.claim(identityKey, fingerprint, event.Actor, providerKey, req)
		e.appendTrace(scheduleID, event.ID, "Claim", identityKey, map[string]string{"claimed": fmt.Sprintf("%t", claimed)})
		if !claimed && !e.mutant.NonAtomicClaim {
			e.responses = append(e.responses, Response{
				RequestID: req.RequestID,
				Identity:  req.Identity.String(),
				Status:    "pending",
				Pending:   true,
			})
			return nil
		}
	}

	if hasRecord && record.Owner != "" && record.Owner != event.Actor && !e.mutant.StaleWorkerAllowed {
		record.Owner = event.Actor
		record.Fence++
		record.LeaseUntilStep = e.step + 1
		e.records[identityKey] = record
		e.appendTrace(scheduleID, event.ID, "Takeover", identityKey, map[string]string{"owner": event.Actor})
	}

	if hasRecord && record.Owner != "" && record.Owner != event.Actor && e.mutant.LoserCallsProvider {
		if _, _, err := e.provider.Execute(e.step, req.Identity, providerKey, event.Behavior); err == nil {
			e.appendTrace(scheduleID, event.ID, "LoserCalledProvider", identityKey, nil)
		}
	}

	outcome, providerAction, err := e.provider.Execute(e.step, req.Identity, providerKey, event.Behavior)
	e.appendTrace(scheduleID, event.ID, "ProviderAction", identityKey, map[string]string{"provider_action": providerAction})
	if err != nil {
		record = e.records[identityKey]
		record.ProviderKey = providerKey
		if e.profile.AuthoritativeLookup {
			if found, ok := e.provider.Lookup(providerKey); ok {
				record.State = StateCompleted
				record.ProviderRef = found.ProviderRef
				record.Outcome = Outcome{
					Status:      "completed",
					ProviderRef: found.ProviderRef,
					Amount:      req.Payload.Amount,
					Currency:    req.Payload.Currency,
					OperationID: req.Identity.String(),
				}
				e.records[identityKey] = record
				e.applyProjection(req, record)
				e.responses = append(e.responses, Response{
					RequestID: req.RequestID,
					Identity:  req.Identity.String(),
					Status:    "completed_after_lookup",
					Outcome:   record.Outcome,
				})
				return nil
			}
		}
		if e.profile.Deduplication && e.profile.ProviderRetention > 0 {
			if e.mutant.ProviderKeyDrift {
				driftedKey := providerKey + "-recovery"
				replayOutcome, _, replayErr := e.provider.Execute(e.step+1, req.Identity, driftedKey, ProviderCommitReply)
				if replayErr == nil {
					e.appendTrace(scheduleID, event.ID, "ProviderKeyDrift", identityKey, map[string]string{"initial_provider_key": providerKey, "recovery_provider_key": driftedKey})
					record.State = StateCompleted
					record.Outcome = replayOutcome
					record.ProviderRef = replayOutcome.ProviderRef
					e.records[identityKey] = record
					e.applyProjection(req, record)
					e.responses = append(e.responses, Response{
						RequestID: req.RequestID,
						Identity:  req.Identity.String(),
						Status:    "completed_after_replay",
						Outcome:   record.Outcome,
					})
					return nil
				}
			}
			replayOutcome, _, replayErr := e.provider.Execute(e.step+1, req.Identity, providerKey, ProviderCommitReply)
			if replayErr == nil {
				record.State = StateCompleted
				record.Outcome = replayOutcome
				record.ProviderRef = replayOutcome.ProviderRef
				e.records[identityKey] = record
				e.applyProjection(req, record)
				e.responses = append(e.responses, Response{
					RequestID: req.RequestID,
					Identity:  req.Identity.String(),
					Status:    "completed_after_replay",
					Outcome:   record.Outcome,
				})
				return nil
			}
		}
		if e.mutant.UnknownAsRejected {
			record.State = StateRejectedFinal
			record.Outcome = Outcome{
				Status:      "rejected_final",
				StableError: "WRONG_UNKNOWN_AS_FINAL",
				OperationID: req.Identity.String(),
			}
			e.records[identityKey] = record
			e.responses = append(e.responses, Response{
				RequestID: req.RequestID,
				Identity:  req.Identity.String(),
				Status:    "rejected_final",
				Outcome:   record.Outcome,
			})
			return nil
		}
		record.State = StateUnknown
		e.records[identityKey] = record
		e.responses = append(e.responses, Response{
			RequestID: req.RequestID,
			Identity:  req.Identity.String(),
			Status:    "unknown",
			Unknown:   true,
			Outcome: Outcome{
				Status:      "unknown",
				OperationID: req.Identity.String(),
			},
		})
		return nil
	}

	record = e.records[identityKey]
	record.ProviderKey = providerKey
	record.ProviderRef = outcome.ProviderRef
	switch outcome.Status {
	case "rejected_final":
		record.State = StateRejectedFinal
	case "accepted_pending_settlement":
		record.State = StateCompleted
	default:
		record.State = StateCompleted
	}
	outcome.Amount = req.Payload.Amount
	outcome.Currency = req.Payload.Currency
	record.Outcome = outcome
	e.records[identityKey] = record
	e.applyProjection(req, record)
	e.responses = append(e.responses, Response{
		RequestID: req.RequestID,
		Identity:  req.Identity.String(),
		Status:    outcome.Status,
		Outcome:   outcome,
	})
	return nil
}

func (e *Engine) AdvanceTime(scheduleID string, event Event) {
	e.step += event.AdvanceBy
	for key, record := range e.records {
		retention := 12
		if e.mutant.ShortRetention {
			retention = 1
		}
		if record.ExpiresAtStep > 0 && e.step-record.ExpiresAtStep >= retention {
			record.State = StateTombstone
			e.records[key] = record
			action := "ExpireToTombstone"
			if e.mutant.ShortRetention {
				action = "ShortRetentionExpired"
			}
			e.appendTrace(scheduleID, event.ID, action, key, nil)
		}
	}
}

func (e *Engine) Run(mode, scheduleID string, schedule Schedule) (RunResult, error) {
	for _, event := range schedule.Events {
		switch event.Kind {
		case "request":
			if event.Request == nil {
				return RunResult{}, fmt.Errorf("request event %s missing request body", event.ID)
			}
			if err := e.HandleRequest(scheduleID, event); err != nil {
				return RunResult{}, err
			}
		case "advance_time":
			e.AdvanceTime(scheduleID, event)
		case "crash":
			e.step++
			e.appendTrace(scheduleID, event.ID, "Crash", event.Actor, nil)
		case "restart":
			e.step++
			e.appendTrace(scheduleID, event.ID, "Restart", event.Actor, nil)
		default:
			return RunResult{}, fmt.Errorf("unsupported event kind %q", event.Kind)
		}
	}
	result := RunResult{
		RunID:          fmt.Sprintf("%s-%s-%s", mode, e.impl, schedule.ScheduleID),
		Mode:           mode,
		Implementation: e.impl,
		ScheduleID:     schedule.ScheduleID,
		MutantID:       schedule.MutantID,
		Profile:        e.profile,
		Trace:          e.trace,
		Responses:      e.responses,
		Records:        e.records,
		ProviderLedger: e.provider.Ledger(),
		Projection:     e.projection,
	}
	result.Observer = Observe(result)
	return result, nil
}
