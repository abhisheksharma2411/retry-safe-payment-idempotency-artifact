package portable

import "t8artifact/internal/core"

func Run(schedule core.Schedule, profile core.ProviderProfile, implementation string) (core.RunResult, error) {
	engine := core.NewEngine(implementation, profile, core.MutantByID(schedule.MutantID))
	result, err := engine.Run("portable", schedule.ScheduleID, schedule)
	if err != nil {
		return core.RunResult{}, err
	}
	lifecycle := []core.TraceEvent{
		{Index: 0, ScheduleID: schedule.ScheduleID, EventID: "portable-start", Action: "ProcessStart"},
		{Index: 1, ScheduleID: schedule.ScheduleID, EventID: "portable-kill", Action: "ProcessKill"},
		{Index: 2, ScheduleID: schedule.ScheduleID, EventID: "portable-restart", Action: "ProcessRestart"},
	}
	for idx := range result.Trace {
		result.Trace[idx].Index = idx + len(lifecycle)
	}
	result.Trace = append(lifecycle, result.Trace...)
	return result, nil
}
