# TLA+ model

The formal model is intentionally small and finite. It covers the named scenarios and required mutant toggles with explicit state variables for:

- operation state;
- effect count;
- cross-intent aliasing;
- payload-check ordering;
- terminal replay;
- recovery repair;
- retention/tombstone;
- partial refund completion;
- reversal parent checks.

`spec/PaymentIdempotency.tla` is the entry point used by TLC.
