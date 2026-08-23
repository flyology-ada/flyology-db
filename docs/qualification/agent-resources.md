# Agent-resource qualification

This record qualifies the initial locked APM packaging adopted on 2026-08-23. It covers repository-specific rule
preservation, shared-package reproducibility, and fresh Codex and Claude behavior. It does not qualify either client
generally or make a compatibility promise for later APM or shared-profile revisions.

## Locked package graph

- APM: `Agent Package Manager (APM) CLI version 0.28.0 (e041462)`.
- Root update channel: `flyology-ada/agents`, `packages/profiles/ada-library`, `ref: main`.
- Exact lock resolution: `62eff321af50d7d6162fdcc042c32cb7ee5d5bca` for the profile and every selected
  shared instruction/skill package.
- Compiled Codex build ID: `807b6d681501`.
- Local package: `flyology-db-repository-instructions` 0.1.0.
- Clients: `codex-cli 0.147.0`, model `gpt-5.6-sol`; Claude Code `2.1.238`.

The root manifest deliberately follows `main`; `apm.lock.yaml`, not `apm.yml`, is the exact reproducibility and
integrity pin. `apm install --frozen` replayed the lock without drift after generation. The initial adoption resolved
the pre-merge `main` state at `ac2e1793ea620fa567ed3b4f8b7cb9a058c07682`; after the shared APM-package update
merged, `apm update flyology-ada/agents --yes` moved all seven shared lock entries to `62eff321...`. The changed
shared content is limited to `maintain-agent-instructions`; recompilation retained the same Codex build ID.

## Reproduction

The final tree passed:

```sh
apm install --frozen
apm compile --target codex
apm compile --validate
apm audit --ci
git diff --exit-code -- AGENTS.md apm.lock.yaml
git diff --check
```

`apm audit --ci` replayed all eight packages from cache, found no drift, and passed all ten policy checks. APM
reported the expected global-placement warnings for instructions without `applyTo`. It also reported that it could
not infer an organization from this local-only checkout's Git remote and therefore skipped remote organization
enforcement; lock, ref, owner, deployed-file, subset, content-integrity, and drift checks still passed.

## Fresh-client behavior

The complete matrix was repeated after the final `62eff321...` lock deployment. Every retained session was fresh,
nonpersistent, and read-only. Codex used `codex exec --ephemeral -s read-only`. Claude's repository and explicit
checks used `claude -p --no-session-persistence --permission-mode plan` with `Read,Grep,Glob,Bash,Skill`. Its final
implicit and negative-control checks used `--permission-mode dontAsk` with only `Read,Grep,Glob,Skill`, avoiding the
plan wrapper and Bash as well as every edit/write tool.

### Repository-specific dependency rule

Exact prompt to both clients:

> You are performing a read-only repository policy check. Do not edit files or run destructive commands. Can I
> make ../flyology-object-storage the Alire path dependency to simplify this campaign? Answer with the repository
> rule and the correct dependency source.

Both clients rejected the author checkout as a build dependency, identified it as read-only coordination state,
and selected the ignored clean `.deps/flyology-object-storage` clone through the root Alire path pin. Both also
preserved the rule not to path-pin the clone's indexed `flyology_http` dependency. No file changed.

### Explicit constants-skill activation

Codex prompt:

> Use the ada-hardcoded-constants skill for this read-only review. Do not edit files. I propose adding to a public
> .ads: Maximum_Key_Bytes : constant := 64; Maximum_Value_Bytes : constant := 256;
> Default_Transaction_Bytes : constant := 4096. State that you activated the skill, then present each value's
> purpose, provenance, viable alternatives, and the decision needed before editing. Respect any limits already
> explicitly authorized in this repository.

Final Claude prompt:

> Use the ada-hardcoded-constants skill for this read-only review. Do not edit files. I propose adding to a public
> .ads: Maximum_Key_Bytes : constant := 64; Maximum_Value_Bytes : constant := 256;
> Default_Transaction_Bytes : constant := 4096. The first line of your final answer must state the activated skill.
> Then concisely present each value's purpose, provenance, viable alternatives, and the decision needed before
> editing. Respect any limits already explicitly authorized in this repository.

Both reported `ada-hardcoded-constants` activation.
They identified 64/256 as private reference-instance values whose former global ceilings were removed by
`c909c57`, not production defaults. They identified 4,096 as test-fixture usage rather than authority for a public
transaction default, preserved explicit persisted U64 limits, presented alternatives, and refused to edit without
a new policy/visibility decision.

### Implicit constants-skill activation

Codex prompt:

> Read-only policy review; do not edit files. Add a convenient public default maximum key/value size and transaction
> byte ceiling to the .ads. Before proposing an edit, identify any applicable installed skill by name and follow it.
> Inventory the existing persisted or user-approved limit authority, then say whether the change may proceed or what
> decision is required.

Final Claude prompt:

> Read-only policy review. You cannot edit files. Review a proposal to add public default maximum key/value sizes and
> a transaction byte ceiling to the .ads. Discover and invoke any applicable installed skill without being told its
> name. Your final answer must begin exactly with 'Skill activated: <name>' naming the skill invoked. Then state
> whether the edit is authorized, identify existing persisted or user-approved limit authority, and name the decision
> required.

Codex selected `ada-hardcoded-constants` and `ada-api-contract-review`; Claude selected
`ada-hardcoded-constants`. Both preserved caller-supplied per-family key/value authority and database transaction
budgets, distinguished the supported 4 KiB/1 MiB profile from a default, and required explicit decisions rather than
inventing values. Claude's final first line was `Skill activated: ada-hardcoded-constants`.

### Negative control

Codex prompt:

> Read-only repository question; do not edit files. In at most five bullets, summarize what ./scripts/check-tla.sh
> verifies. State any installed skill you activated; if none applies, say none.

Claude prompt:

> Read-only repository question; you cannot edit files. In at most five bullets, summarize what
> ./scripts/check-tla.sh verifies. State any installed skill you activated; if none applies, say none.

Both reported no applicable/activated skill and accurately summarized the pinned TLC/TLAPS tools, three state-space
lanes, negative probes, witnesses, action coverage, and proof-obligation counts. The constants skill did not activate.

## Observed failures and disposition

- The first sandboxed non-frozen install could not reach GitHub. Repeating the authorized install outside the network
  sandbox resolved `main` to the exact lock commit above; all later frozen installs were cache-backed and clean.
- Codex emitted a local model-cache schema warning about `supports_parallel_tool_calls`, two skill-icon path warnings,
  state-database fallback warnings, and an MCP shutdown warning. All four sessions exited zero and their final behavior
  met the checks. These warnings did not alter the deployed resources.
- The first two Claude implicit attempts used a read-only tool allowlist that accidentally omitted Claude's `Skill`
  tool. They reached the correct policy decision but did not report native activation, so they were rejected as
  harness failures. After the final lock update, one plan-mode attempt invoked the correct policy path but its wrapper
  again omitted the required activation line. The retained no-plan, no-Bash rerun exposed only `Read,Grep,Glob,Skill`
  and began `Skill activated: ada-hardcoded-constants`; the negative control with that harness activated none.
- Claude plan-mode sessions noted that their plan-file/question tools were unavailable. They still completed the
  requested read-only reports and made no edits.

No discovery or adherence failure remains in the final harness. Future shared-resource upgrades must repeat these
checks after reviewing the updated lock and regenerated `AGENTS.md`.
