---- MODULE Identity ----
EXTENDS Sequences

Identity(tenant, operationType, parentResource, callerKey, epoch) ==
    <<tenant, operationType, parentResource, callerKey, epoch>>

Fingerprint(amount, currency, destination, options) ==
    <<amount, currency, destination, options>>

====
