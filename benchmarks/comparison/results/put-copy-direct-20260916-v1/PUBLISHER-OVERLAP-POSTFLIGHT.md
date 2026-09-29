# Interrupted publisher-overlap screen: postflight

The exploratory driver completed arms 01 and 02. The primary agent sent
SIGINT to its exact owned Python process during arm 03 after the C2 slowdown
and publication fragmentation triggered the user's stop rule. The driver
terminated its exact child process group and exited nonzero. There is no
arm-03 measurement or campaign summary. The retained `03-overlap.log` is an
empty file, so it is not an interruption receipt by itself.

After retaining the completed raw files, a remote read-only check found one
interrupted-run scratch directory:

`/mnt/flyology-bench/experiments/put-copy-direct-20260916-v1-x86_64/publisher-overlap-scratch-v1/flyology-db-bench.899550.19`

It was a real, nonsymlink, root-owned directory of 23 MB. A process check
found no benchmark driver or panel child. Only that exact scratch directory
was removed with `sudo -n rm -r -- <exact path>`; the retained raw evidence
and all other experiment paths were left intact. A subsequent check confirmed
the exact target absent and the scratch parent empty. The remaining executable
basenames (`alr`, `gprbuild`, `gnat1`, `cargo`, `rustc`, `perf`) were absent; a
separate full-command-line check found no long-named benchmark panel or
publisher-overlap driver. The x86 DB benchmark lane was then released.

This record transcribes the terminal audit, not a separately signed machine
receipt. Neither the interrupted arm nor the cleanup contributes a timing
sample or performance qualification.
