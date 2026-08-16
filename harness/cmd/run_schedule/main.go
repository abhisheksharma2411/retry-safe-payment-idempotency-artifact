package main

import (
	"flag"
	"fmt"
	"os"

	"t8artifact/harness/cooperative"
	"t8artifact/harness/portable"
	"t8artifact/internal/core"
)

func main() {
	mode := flag.String("mode", "cooperative", "cooperative or portable")
	implementation := flag.String("implementation", "go-reserve-replay", "implementation name")
	schedulePath := flag.String("schedule", "", "path to schedule json")
	profilePath := flag.String("profile", "", "path to profile yaml")
	outputPath := flag.String("output", "", "path to output json")
	flag.Parse()

	if *schedulePath == "" || *profilePath == "" || *outputPath == "" {
		fmt.Fprintln(os.Stderr, "schedule, profile, and output are required")
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

	var result core.RunResult
	switch *mode {
	case "cooperative":
		result, err = cooperative.Run(schedule, profile, *implementation)
	case "portable":
		result, err = portable.Run(schedule, profile, *implementation)
	default:
		err = fmt.Errorf("unsupported mode %s", *mode)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := core.SaveJSON(*outputPath, result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
