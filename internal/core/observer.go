package core

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
)

func Observe(result RunResult) ObserverResult {
	props := []PropertyResult{
		checkP1(result),
		checkP2(result),
		checkP3(result),
		checkP4(result),
		checkP5(result),
		checkP6(result),
		checkP7(result),
	}
	passed := true
	fingerprintParts := make([]string, 0, len(props))
	for _, prop := range props {
		if !prop.Passed {
			passed = false
		}
		fingerprintParts = append(fingerprintParts, fmt.Sprintf("%s=%t:%d", prop.Name, prop.Passed, len(prop.Violations)))
	}
	sort.Strings(fingerprintParts)
	sum := sha256.Sum256([]byte(fmt.Sprint(fingerprintParts)))
	return ObserverResult{
		Passed:              passed,
		Properties:          props,
		PropertyFingerprint: hex.EncodeToString(sum[:]),
	}
}

func checkP1(result RunResult) PropertyResult {
	counts := map[string]int{}
	for _, entry := range result.ProviderLedger {
		if entry.Committed {
			counts[entry.Identity]++
		}
	}
	var violations []string
	for identity, count := range counts {
		if count > 1 {
			violations = append(violations, fmt.Sprintf("%s has %d committed effects", identity, count))
		}
	}
	for _, trace := range result.Trace {
		switch trace.Action {
		case "LoserCalledProvider":
			violations = append(violations, fmt.Sprintf("%s losing claim racer called provider", trace.Identity))
		case "ProviderCalledBeforeClaim":
			violations = append(violations, fmt.Sprintf("%s provider was called before durable claim", trace.Identity))
		case "NonAtomicDoubleClaim":
			violations = append(violations, fmt.Sprintf("%s non-atomic claim allowed re-execution", trace.Identity))
		}
	}
	return PropertyResult{Name: "P1", Passed: len(violations) == 0, Violations: violations}
}

func checkP2(result RunResult) PropertyResult {
	refs := map[string]string{}
	var violations []string
	for _, entry := range result.ProviderLedger {
		if !entry.Committed {
			continue
		}
		if prior, ok := refs[entry.ProviderRef]; ok && prior != entry.Identity {
			violations = append(violations, fmt.Sprintf("provider ref %s shared by %s and %s", entry.ProviderRef, prior, entry.Identity))
		} else {
			refs[entry.ProviderRef] = entry.Identity
		}
	}
	for _, trace := range result.Trace {
		if trace.Action == "RawKeyOnlyScope" {
			violations = append(violations, fmt.Sprintf("%s used raw caller key without full semantic scope", trace.Identity))
		}
	}
	return PropertyResult{Name: "P2", Passed: len(violations) == 0, Violations: violations}
}

func checkP3(result RunResult) PropertyResult {
	var violations []string
	for _, response := range result.Responses {
		if response.Pending || response.Conflict {
			continue
		}
		record, ok := result.Records[response.Identity]
		if !ok {
			continue
		}
		if record.State == StateUnknown {
			continue
		}
		count := 0
		for _, entry := range result.ProviderLedger {
			if entry.Identity == response.Identity && entry.Committed {
				count++
			}
		}
		if record.State == StateCompleted && count != 1 {
			violations = append(violations, fmt.Sprintf("%s completed with %d committed effects", response.Identity, count))
		}
	}
	for _, trace := range result.Trace {
		if trace.Action == "ParentAmountDedup" {
			violations = append(violations, fmt.Sprintf("%s deduplicated partial operation by parent and amount", trace.Identity))
		}
	}
	return PropertyResult{Name: "P3", Passed: len(violations) == 0, Violations: violations}
}

func checkP4(result RunResult) PropertyResult {
	var violations []string
	for _, trace := range result.Trace {
		if trace.Action == "LatePayloadConflict" {
			violations = append(violations, fmt.Sprintf("%s checked payload after replay", trace.Identity))
		}
	}
	return PropertyResult{Name: "P4", Passed: len(violations) == 0, Violations: violations}
}

func checkP5(result RunResult) PropertyResult {
	var violations []string
	for _, trace := range result.Trace {
		if trace.Action == "TerminalReplayReexecuted" {
			violations = append(violations, fmt.Sprintf("%s re-executed terminal replay", trace.Identity))
		}
	}
	return PropertyResult{Name: "P5", Passed: len(violations) == 0, Violations: violations}
}

func checkP6(result RunResult) PropertyResult {
	var violations []string
	for identity, record := range result.Records {
		if record.State == StateCompleted {
			found := false
			for _, entry := range result.ProviderLedger {
				if entry.Identity == identity && entry.Committed {
					found = true
					break
				}
			}
			if !found {
				violations = append(violations, fmt.Sprintf("%s completed without provider evidence", identity))
			}
			parent := record.Identity.ParentResource
			switch record.Identity.OperationType {
			case OpCapture:
				if result.Projection.CapturedByParent[parent] < record.Outcome.Amount {
					violations = append(violations, fmt.Sprintf("%s completed capture missing from projection", identity))
				}
			case OpRefund:
				if result.Projection.RefundedByParent[parent] < record.Outcome.Amount {
					violations = append(violations, fmt.Sprintf("%s completed refund missing from projection", identity))
				}
			case OpReversal:
				if result.Projection.ReversalsByParent[parent] < 1 {
					violations = append(violations, fmt.Sprintf("%s completed reversal missing from projection", identity))
				}
			}
		}
		if record.State == StateRejectedFinal {
			for _, entry := range result.ProviderLedger {
				if entry.Identity == record.Identity.String() && entry.Committed {
					violations = append(violations, fmt.Sprintf("%s stored committed unknown as final rejection", identity))
				}
			}
		}
	}
	for _, trace := range result.Trace {
		if trace.Action == "ShortRetentionExpired" {
			violations = append(violations, fmt.Sprintf("%s expired before promised retention horizon", trace.Identity))
		}
	}
	return PropertyResult{Name: "P6", Passed: len(violations) == 0, Violations: violations}
}

func checkP7(result RunResult) PropertyResult {
	var violations []string
	for parent, refunded := range result.Projection.RefundedByParent {
		captured := result.Projection.CapturedByParent[parent]
		if refunded > captured {
			violations = append(violations, fmt.Sprintf("%s refunded %d over captured %d", parent, refunded, captured))
		}
	}
	return PropertyResult{Name: "P7", Passed: len(violations) == 0, Violations: violations}
}
