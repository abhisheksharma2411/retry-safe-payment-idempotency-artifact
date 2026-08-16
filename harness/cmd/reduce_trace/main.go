package main

import (
	"flag"
	"fmt"
	"os"

	"t8artifact/harness/cooperative"
	"t8artifact/harness/shrinker"
	"t8artifact/internal/core"
)

func main() {
	schedulePath := flag.String("schedule", "", "path to schedule")
	profilePath := flag.String("profile", "", "path to profile")
	outputPath := flag.String("output", "", "path to reduced schedule")
	reportPath := flag.String("report", "", "path to shrink report")
	flag.Parse()

	if *schedulePath == "" || *profilePath == "" || *outputPath == "" || *reportPath == "" {
		fmt.Fprintln(os.Stderr, "schedule, profile, output, and report are required")
		os.Exit(2)
	}
	schedule, err := core.LoadSchedule(*schedulePath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	profile, err := core.LoadProfile(*profilePath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	initial, err := cooperative.Run(schedule, profile, "go-reserve-replay")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	reduced, report, err := shrinker.Reduce(schedule, func(candidate core.Schedule) (core.RunResult, error) {
		return cooperative.Run(candidate, profile, "go-reserve-replay")
	}, initial.Observer.PropertyFingerprint)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := core.SaveJSON(*outputPath, reduced); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := core.SaveJSON(*reportPath, report); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
