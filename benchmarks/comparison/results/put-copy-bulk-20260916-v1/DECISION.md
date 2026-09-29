# Ada iterated-aggregate copy: rejected at code generation

The isolated source is based on `613ad2b054725e99b73117f03ae38e213fdfaef7`.
Its tracked binary diff is
`b05b192da6f2a0661a23b7cdae293707fc28abe6d3e7cb0ae2cac39fc5289ed9`.
Only the two payload-copy loops in `Store_Mutation` were changed relative to the
preceding attribution source. The candidate's database body SHA-256 is
`adfd70b3b5a5ddaff5ad4d131e51ae3e15debbad0035710f51446b778067b5a9`.

The retained x86_64 `alr build --release -- -f` exited zero in 204.83 seconds.
The build log SHA-256 is
`bd6e32152580b36f94b159c83327f452dbf16bb030838c2d49f39be928cb29cf`.
The resulting `flyology-db.o` SHA-256 is
`16f1c9d0167a0d2433aab854c2574756d2bd501958006fd4cf745fb5c02c3792`.
The focused `Store_Mutation` disassembly SHA-256 is
`7bf244bbf14313f89e2726a7ec2971635627a70bf732bea225aa2a41ef655894`.
The build and disassembly are retained under
`/mnt/flyology-bench/experiments/put-copy-bulk-20260916-v1-x86_64`.

The optimized function allocates a payload-sized stack temporary, fills it
with a scalar checked byte loop around offsets `0x788..0x7af`, then calls
`memcpy` at `0x7d5` to copy the temporary into the candidate. The value path
repeats a scalar checked loop around `0xeb9..0xef8` and calls `memcpy` at
`0x9d8`. Thus the aggregate adds a full-size temporary and a second payload
pass instead of removing the original per-byte work.

Reject this expression immediately. It was not performance-tested and made
no production change. The build is code-generation evidence only, not a
correctness or performance qualification. The broader commit-path objective
remains open: the same-host control was 59.974 ms for Flyology.DB versus
23.474 ms for SlateDB, and no end-to-end saving follows from this result.
