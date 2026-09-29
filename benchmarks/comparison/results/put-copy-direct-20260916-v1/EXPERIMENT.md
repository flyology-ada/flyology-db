# Direct owned-payload copy experiment

This isolated source tree tests whether a fixed-signature Ada import of C
`memcpy` removes the checked per-byte copy in `Store_Mutation`. It is not a
publication, ownership-policy, or public API change. The input validation,
allocation, failure guard, abort-deferred adoption, and transaction accounting
must remain byte-equivalent to the current code.

First reject the candidate if the optimized object still contains a payload
loop or a full-size intermediate. Then require exact correctness fixtures,
same-state balanced paired workloads, and both x86_64 and ARM64 evidence.
Even a passing copy result is not by itself the architectural parity route.
