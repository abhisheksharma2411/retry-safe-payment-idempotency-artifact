package cooperative

import "t8artifact/internal/core"

func Run(schedule core.Schedule, profile core.ProviderProfile, implementation string) (core.RunResult, error) {
	engine := core.NewEngine(implementation, profile, core.MutantByID(schedule.MutantID))
	return engine.Run("cooperative", schedule.ScheduleID, schedule)
}
