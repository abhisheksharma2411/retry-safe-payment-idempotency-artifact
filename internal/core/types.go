package core

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

type State string

const (
	StateAbsent        State = "ABSENT"
	StateInProgress    State = "IN_PROGRESS"
	StateUnknown       State = "UNKNOWN"
	StateCompleted     State = "COMPLETED"
	StateRejectedFinal State = "REJECTED_FINAL"
	StateTombstone     State = "TOMBSTONE"
)

type OperationType string

const (
	OpCapture  OperationType = "capture"
	OpRefund   OperationType = "refund"
	OpReversal OperationType = "reversal"
)

type Identity struct {
	Tenant         string        `json:"tenant"`
	OperationType  OperationType `json:"operation_type"`
	ParentResource string        `json:"parent_resource"`
	CallerKey      string        `json:"caller_key"`
	Epoch          int           `json:"epoch"`
}

func (i Identity) String() string {
	return fmt.Sprintf("%s|%s|%s|%s|%d", i.Tenant, i.OperationType, i.ParentResource, i.CallerKey, i.Epoch)
}

type Payload struct {
	Amount      int               `json:"amount"`
	Currency    string            `json:"currency"`
	Destination string            `json:"destination,omitempty"`
	Options     map[string]string `json:"options,omitempty"`
}

func (p Payload) Fingerprint() string {
	options := map[string]string{}
	for k, v := range p.Options {
		options[k] = v
	}
	keys := make([]string, 0, len(options))
	for k := range options {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	canonical := map[string]any{
		"amount":      p.Amount,
		"currency":    p.Currency,
		"destination": p.Destination,
		"options":     orderedMap(keys, options),
	}
	raw, _ := json.Marshal(canonical)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func orderedMap(keys []string, input map[string]string) []map[string]string {
	out := make([]map[string]string, 0, len(keys))
	for _, k := range keys {
		out = append(out, map[string]string{"key": k, "value": input[k]})
	}
	return out
}

type Request struct {
	RequestID     string   `json:"request_id"`
	Identity      Identity `json:"identity"`
	Payload       Payload  `json:"payload"`
	RequireEffect bool     `json:"require_effect"`
}

type Outcome struct {
	Status        string `json:"status"`
	ProviderRef   string `json:"provider_ref,omitempty"`
	Amount        int    `json:"amount"`
	Currency      string `json:"currency"`
	StableError   string `json:"stable_error,omitempty"`
	OperationID   string `json:"operation_id"`
	ReplayOfState State  `json:"replay_of_state,omitempty"`
}

func (o Outcome) StableView() string {
	parts := []string{
		o.Status,
		o.ProviderRef,
		fmt.Sprintf("%d", o.Amount),
		o.Currency,
		o.StableError,
		o.OperationID,
		string(o.ReplayOfState),
	}
	return strings.Join(parts, "|")
}

type OperationRecord struct {
	Identity       Identity `json:"identity"`
	State          State    `json:"state"`
	Fingerprint    string   `json:"fingerprint"`
	Owner          string   `json:"owner"`
	Fence          int      `json:"fence"`
	ProviderKey    string   `json:"provider_key"`
	ProviderRef    string   `json:"provider_ref,omitempty"`
	Outcome        Outcome  `json:"outcome"`
	LeaseUntilStep int      `json:"lease_until_step"`
	ExpiresAtStep  int      `json:"expires_at_step"`
	TombstoneUntil int      `json:"tombstone_until"`
}

type ProviderProfile struct {
	Name                string `json:"name"`
	Deduplication       bool   `json:"deduplication"`
	AuthoritativeLookup bool   `json:"authoritative_lookup"`
	ProviderRetention   int    `json:"provider_retention_steps"`
	AsyncSettlement     bool   `json:"async_settlement"`
	Scope               string `json:"scope"`
}

type ProviderBehavior string

const (
	ProviderCommitReply     ProviderBehavior = "commit_reply"
	ProviderCommitDropReply ProviderBehavior = "commit_drop_reply"
	ProviderTimeoutBefore   ProviderBehavior = "timeout_before_commit"
	ProviderTimeoutAfter    ProviderBehavior = "timeout_after_commit"
	ProviderRejectFinal     ProviderBehavior = "reject_final"
	ProviderDuplicateAck    ProviderBehavior = "duplicate_ack"
	ProviderDelayedSettle   ProviderBehavior = "delayed_settlement"
)

type Event struct {
	ID              string           `json:"id"`
	Kind            string           `json:"kind"`
	Actor           string           `json:"actor,omitempty"`
	Request         *Request         `json:"request,omitempty"`
	Behavior        ProviderBehavior `json:"behavior,omitempty"`
	AdvanceBy       int              `json:"advance_by,omitempty"`
	TargetRequestID string           `json:"target_request_id,omitempty"`
}

type Schedule struct {
	ScheduleID string  `json:"schedule_id"`
	Profile    string  `json:"profile"`
	MutantID   string  `json:"mutant_id,omitempty"`
	Events     []Event `json:"events"`
}

type TraceEvent struct {
	Index      int               `json:"index"`
	ScheduleID string            `json:"schedule_id"`
	EventID    string            `json:"event_id"`
	Action     string            `json:"action"`
	Identity   string            `json:"identity,omitempty"`
	Details    map[string]string `json:"details,omitempty"`
}

type ProviderLedgerEntry struct {
	Step        int              `json:"step"`
	Identity    string           `json:"identity"`
	ProviderKey string           `json:"provider_key"`
	ProviderRef string           `json:"provider_ref"`
	Behavior    ProviderBehavior `json:"behavior"`
	Committed   bool             `json:"committed"`
	FinalReject bool             `json:"final_reject"`
	Settled     bool             `json:"settled"`
}

type Projection struct {
	CapturedByParent  map[string]int `json:"captured_by_parent"`
	RefundedByParent  map[string]int `json:"refunded_by_parent"`
	ReversalsByParent map[string]int `json:"reversals_by_parent"`
}

func NewProjection() Projection {
	return Projection{
		CapturedByParent:  map[string]int{},
		RefundedByParent:  map[string]int{},
		ReversalsByParent: map[string]int{},
	}
}

type Response struct {
	RequestID string  `json:"request_id"`
	Identity  string  `json:"identity"`
	Status    string  `json:"status"`
	Conflict  bool    `json:"conflict"`
	Pending   bool    `json:"pending"`
	Unknown   bool    `json:"unknown"`
	Outcome   Outcome `json:"outcome"`
}

type RunResult struct {
	RunID          string                     `json:"run_id"`
	Mode           string                     `json:"mode"`
	Implementation string                     `json:"implementation"`
	ScheduleID     string                     `json:"schedule_id"`
	MutantID       string                     `json:"mutant_id,omitempty"`
	Profile        ProviderProfile            `json:"profile"`
	Trace          []TraceEvent               `json:"trace"`
	Responses      []Response                 `json:"responses"`
	Records        map[string]OperationRecord `json:"records"`
	ProviderLedger []ProviderLedgerEntry      `json:"provider_ledger"`
	Projection     Projection                 `json:"projection"`
	Observer       ObserverResult             `json:"observer"`
}

type PropertyResult struct {
	Name       string   `json:"name"`
	Passed     bool     `json:"passed"`
	Violations []string `json:"violations,omitempty"`
}

type ObserverResult struct {
	Passed              bool             `json:"passed"`
	Properties          []PropertyResult `json:"properties"`
	PropertyFingerprint string           `json:"property_fingerprint"`
}
