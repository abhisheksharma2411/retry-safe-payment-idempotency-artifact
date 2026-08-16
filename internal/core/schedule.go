package core

import (
	"encoding/json"
	"os"
)

func LoadSchedule(path string) (Schedule, error) {
	var schedule Schedule
	raw, err := os.ReadFile(path)
	if err != nil {
		return schedule, err
	}
	err = json.Unmarshal(raw, &schedule)
	return schedule, err
}

func SaveJSON(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	return os.WriteFile(path, raw, 0o644)
}
