package core

import "fmt"

type Provider struct {
	profile ProviderProfile
	ledger  []ProviderLedgerEntry
}

func NewProvider(profile ProviderProfile) *Provider {
	return &Provider{profile: profile, ledger: []ProviderLedgerEntry{}}
}

func (p *Provider) Ledger() []ProviderLedgerEntry {
	out := make([]ProviderLedgerEntry, len(p.ledger))
	copy(out, p.ledger)
	return out
}

func (p *Provider) HasCommitted(providerKey string) (ProviderLedgerEntry, bool) {
	for _, entry := range p.ledger {
		if entry.ProviderKey == providerKey && entry.Committed {
			return entry, true
		}
	}
	return ProviderLedgerEntry{}, false
}

func (p *Provider) Lookup(providerKey string) (ProviderLedgerEntry, bool) {
	return p.HasCommitted(providerKey)
}

func (p *Provider) Execute(step int, identity Identity, providerKey string, behavior ProviderBehavior) (Outcome, string, error) {
	if p.profile.Deduplication {
		if prior, ok := p.HasCommitted(providerKey); ok {
			return Outcome{
				Status:      "completed",
				ProviderRef: prior.ProviderRef,
				Amount:      0,
				Currency:    "",
				OperationID: identity.String(),
			}, "duplicate_ack", nil
		}
	}

	ref := fmt.Sprintf("prov-%s-%d", providerKey, len(p.ledger)+1)
	entry := ProviderLedgerEntry{
		Step:        step,
		Identity:    identity.String(),
		ProviderKey: providerKey,
		ProviderRef: ref,
		Behavior:    behavior,
	}
	switch behavior {
	case ProviderTimeoutBefore:
		p.ledger = append(p.ledger, entry)
		return Outcome{}, "timeout_before", fmt.Errorf("timeout before commit")
	case ProviderRejectFinal:
		entry.FinalReject = true
		p.ledger = append(p.ledger, entry)
		return Outcome{
			Status:      "rejected_final",
			ProviderRef: ref,
			OperationID: identity.String(),
			StableError: "FINAL_REJECT",
		}, "reject_final", nil
	case ProviderCommitReply, ProviderDuplicateAck:
		entry.Committed = true
		entry.Settled = true
		p.ledger = append(p.ledger, entry)
		return Outcome{
			Status:      "completed",
			ProviderRef: ref,
			OperationID: identity.String(),
		}, "commit_reply", nil
	case ProviderCommitDropReply, ProviderTimeoutAfter:
		entry.Committed = true
		p.ledger = append(p.ledger, entry)
		return Outcome{}, "unknown_after_commit", fmt.Errorf("reply lost after commit")
	case ProviderDelayedSettle:
		entry.Committed = true
		entry.Settled = false
		p.ledger = append(p.ledger, entry)
		return Outcome{
			Status:      "accepted_pending_settlement",
			ProviderRef: ref,
			OperationID: identity.String(),
		}, "delayed_settle", nil
	default:
		return Outcome{}, "unsupported", fmt.Errorf("unsupported behavior %s", behavior)
	}
}
