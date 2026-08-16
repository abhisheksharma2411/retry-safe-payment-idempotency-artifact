package shrinker

import "t8artifact/internal/core"

type DeletionCheck struct {
	RemovedEventID         string `json:"removed_event_id"`
	CandidateEvents        int    `json:"candidate_events"`
	Replayed               bool   `json:"replayed"`
	SameFailureFingerprint bool   `json:"same_failure_fingerprint"`
	ObserverPassed         bool   `json:"observer_passed"`
}

type ShrinkResult struct {
	TraceID                string          `json:"trace_id"`
	OriginalEvents         int             `json:"original_events"`
	ReducedEvents          int             `json:"reduced_events"`
	ReplayCount            int             `json:"replay_count"`
	OriginalScheduleEvents int             `json:"original_schedule_events"`
	ReducedScheduleEvents  int             `json:"reduced_schedule_events"`
	ExecutionTraceEvents   int             `json:"execution_trace_events"`
	CandidateReplayCount   int             `json:"candidate_replay_count"`
	DeletionChecks         []DeletionCheck `json:"deletion_checks"`
	OneMinimal             bool            `json:"one_minimal"`
}

func Reduce(schedule core.Schedule, replay func(core.Schedule) (core.RunResult, error), propertyFingerprint string) (core.Schedule, ShrinkResult, error) {
	current := schedule
	replayCount := 0
	deletionChecks := []DeletionCheck{}
	for i := 0; i < len(current.Events); i++ {
		if len(current.Events) <= 1 {
			break
		}
		candidate := current
		candidate.Events = append([]core.Event{}, current.Events[:i]...)
		candidate.Events = append(candidate.Events, current.Events[i+1:]...)
		result, err := replay(candidate)
		replayCount++
		if err != nil {
			return core.Schedule{}, ShrinkResult{}, err
		}
		if result.Observer.PropertyFingerprint == propertyFingerprint {
			current = candidate
			i = -1
		}
	}
	oneMinimal := true
	executionTraceEvents := 0
	for i := 0; i < len(current.Events); i++ {
		candidate := current
		candidate.Events = append([]core.Event{}, current.Events[:i]...)
		candidate.Events = append(candidate.Events, current.Events[i+1:]...)
		result, err := replay(candidate)
		replayCount++
		if err != nil {
			return core.Schedule{}, ShrinkResult{}, err
		}
		if executionTraceEvents == 0 {
			executionTraceEvents = len(result.Trace)
		}
		sameFailure := result.Observer.PropertyFingerprint == propertyFingerprint
		deletionChecks = append(deletionChecks, DeletionCheck{
			RemovedEventID:         current.Events[i].ID,
			CandidateEvents:        len(candidate.Events),
			Replayed:               true,
			SameFailureFingerprint: sameFailure,
			ObserverPassed:         result.Observer.Passed,
		})
		if sameFailure {
			oneMinimal = false
			break
		}
	}
	reducedRun, err := replay(current)
	replayCount++
	if err != nil {
		return core.Schedule{}, ShrinkResult{}, err
	}
	return current, ShrinkResult{
		TraceID:                current.ScheduleID,
		OriginalEvents:         len(schedule.Events),
		ReducedEvents:          len(current.Events),
		ReplayCount:            replayCount,
		OriginalScheduleEvents: len(schedule.Events),
		ReducedScheduleEvents:  len(current.Events),
		ExecutionTraceEvents:   len(reducedRun.Trace),
		CandidateReplayCount:   replayCount,
		DeletionChecks:         deletionChecks,
		OneMinimal:             oneMinimal,
	}, nil
}
