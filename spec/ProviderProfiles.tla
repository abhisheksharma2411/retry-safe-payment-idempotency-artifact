---- MODULE ProviderProfiles ----

IdempotentReplay == "idempotent_replay"
AuthoritativeLookup == "authoritative_lookup"
OpaqueProvider == "opaque_provider"
AsynchronousSettlement == "asynchronous_settlement"

HasDedup(profile) == profile \in {IdempotentReplay, AsynchronousSettlement}
HasLookup(profile) == profile \in {AuthoritativeLookup, AsynchronousSettlement}

====
