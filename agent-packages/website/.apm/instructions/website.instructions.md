---
description: Apply Flyology's documentation rules to the Flyology.DB website.
applyTo: "website/**"
---

# Flyology.DB website documentation guide

## Scope

Apply the technical writing style to hand-written documentation in `guide/**`,
`architecture/**`, and `support/**`. These rules do not apply to the home page
or generated API reference.

## Technical writing style

Use the useful parts of ASD-STE100 as a house style. Do not claim that the
documentation complies with ASD-STE100.

- Use the project vocabulary in the root `AGENTS.md`. Use one term for one
  concept. Do not add synonyms only for variety.
- Define an unfamiliar term before its first use. Keep Flyology.DB, Ada,
  object-storage, transaction, LSM, and persisted-format terms exact.
- Put one main idea or one instruction in each sentence. Use a list when three
  or more parallel facts would make a long sentence.
- Keep closely related cause, contrast, sequence, and consequence in the same
  paragraph. Do not split connected reasoning only to shorten sentences.
- Prefer sentences of 25 words or fewer. Prefer 20 words or fewer for an
  instruction. Treat these limits as review signals, not mechanical rules.
- Use active voice when the actor matters. Name the actor instead of using an
  unclear `it`, `this`, or `they`.
- Preserve modal meaning. Use `must` for a requirement, `can` for capability,
  and `may` for possibility. Rewrite ambiguous capability or possibility.
- Use present tense for current behavior and the imperative for instructions.
  Put a condition before the action when the condition controls it.
- Put a prerequisite or safety condition before its action. Natural forms
  such as "use X when Y" are acceptable when the condition does not gate
  safety, validity, or ownership.
- Use direct, sentence-case headings. State the subject or action.
- Prefer concrete verbs. Avoid stacked modifiers, nominalizations, rhetorical
  questions, idioms, metaphors, personification, filler, and promotional prose.
- Keep limits next to the capability that they qualify. Do not remove a
  condition, ownership rule, exception, or timing fact to shorten prose.
- Use short paragraphs. Start a new paragraph when the subject changes.

The result must read like normal software documentation. Do not imitate an
aircraft maintenance manual, force a restricted dictionary, repeat nouns when
the reference is clear, or split connected reasoning into unnatural fragments.

Examples and walkthroughs can use a slightly more human cadence. Their setup
may explain why a realistic case matters, and their explanation may vary
sentence length to connect cause and effect. Use this allowance with restraint.
Commands, contracts, warnings, and limits still use the tighter style. Do not
add a fictional user, dramatic scenario, metaphor, or extra personality when
it does not improve understanding.

Before finishing, check term consistency, sentence length, HTML syntax, local
links, and code examples. Sentence-length scripts are triage tools, not gates.
Review the meaning and cadence of every flagged sentence before changing it.

## Flyology.DB claim rules

- State that Flyology.DB is experimental. Do not make a production,
  portability, real-time, durability, or performance claim without retained
  evidence from a maintained gate.
- Keep object storage as the sole authority for acknowledged durable state.
  Do not describe memory, local caches, listing, or an unconfirmed upload as
  durable authority.
- Describe one fenced writer, one global commit sequence, one database-wide
  transaction log, stable never-reused family IDs, and read-only replicas as
  the current topology. Do not imply automatic writer promotion.
- Keep the exact publication boundary: complete immutable batch storage,
  conditional HEAD transition from the expected generation, then confirmation
  or same-identity reconciliation.
- State that an unknown outcome stays unknown until the attempted transition
  or a conclusive successor is observed. Never describe application replay
  under a replacement identity as recovery.
- Keep explicit limits, identities, deadlines, provider configuration, and
  maintenance decisions attached to the caller. Example values are not
  library defaults or production recommendations.
- Distinguish synchronous convenience calls from caller-composable operations.
  Both forms use the same state machines and certainty rules.
- Distinguish explicit `Flush` and caller-selected `Compact` from automatic
  maintenance. The current profile has no automatic compaction, garbage
  collection, cleanup, retention, or retry policy.
- Distinguish installed read-only configuration from mutation. The current API
  does not provide family rename, drop, reconfiguration, migration, TTL, or
  codec policy.
- Distinguish a caller-triggered replica refresh from registration, polling,
  leasing, retention coordination, or promotion.
- Keep Files and S3-compatible provider evidence within its exact maintained
  matrix. Do not turn compatible-provider evidence into general cloud or
  production qualification.
- Describe durable Commit authority as a bearer blob that contains application
  keys and values. Its CRC detects corruption, not substitution. It requires
  authenticated, confidential storage and higher-level request binding.
- State that durable Commit authority begins only after `Commit` returned
  `Outcome_Unknown`. It does not cover termination inside `Commit` or another
  receipt family.
- Treat public specifications, bodies, tests, runners, architecture contracts,
  and qualification records as stronger evidence than earlier website prose.

## API links

On each Guide, Architecture, or Support page, link the first visible
explanatory mention of a public Flyology.DB API entity to its generated
GNATdoc entry.

- Write `<a data-api="Qualified.Name"><code>Entity_Name</code></a>` in authored
  source. The site build resolves the declaration through the generated search
  index and verifies the target.
- Link a package name to its GNATdoc unit page. Link a declaration to its exact
  entity anchor when that anchor exists.
- For an overloaded subprogram, add a reviewed `data-api-signature` selector.
  If prose refers to the overload family, link the package page instead.
- Do not guess a generated filename or anchor. Use the resolver and verify that
  the target and fragment exist.
- Link only the first explanatory mention of an entity on a page. Repeat a link
  only when the spelling refers to another entity or a long page needs a
  deliberate navigation aid.
- Do not link Ada constructs, shell commands, scripts, environment variables,
  or external APIs to Flyology.DB GNATdoc.
- When no generated entry exists for a public Flyology.DB identifier, record a
  review finding. Do not silently link to an unrelated package.

## Executable examples

Every Ada code sample must identify a named region in a maintained source under
`examples/`. The site verifier compares the decoded HTML block with the exact
source bytes between its markers. Keep the source executable through the
maintained example GPR and runner.

Do not add illustrative pseudocode that resembles a public call but does not
compile. Keep every example profile, capacity, deadline, and identity explicit.
State that example values are not library defaults.

## Review roles

For a broad rewrite of three or more pages, perform three separate read-only
reviews on the settled draft. Run a technical review for every changed
capability, limit, ownership, timing, or lifecycle claim.

Do not edit the reviewed files during a review pass. Each finding identifies
its severity, exact location, relevant wording, violated rule, and proposed
correction. A technical finding also names the implementation, script,
contract, or invariant that supports it.

### Editorial reviewer

- Review headings, paragraph order, cadence, transitions, and cognitive load.
- Identify mechanical splitting, repeated openings, vague headings, and prose
  that needs list structure.
- Give examples enough connective prose to explain sequence and purpose.
- Review navigation labels, metadata, callouts, captions, and code comments.

### Technical reviewer

- Compare the website with public specs, bodies, tests, runners, architecture
  contracts, qualification records, and root `AGENTS.md`.
- Check each API link against exact generated GNATdoc output.
- Check every limit, identity, lifecycle, ownership, certainty, publication,
  recovery, isolation, provider, and experimental-status claim.
- Check that every `must`, `can`, and `may` retains its intended meaning.
- Report any fact that became weaker, broader, or ambiguous. Treat executable
  code and maintained scripts as stronger evidence than earlier prose.

### ASD-STE100-inspired controlled-language reviewer

- Apply this file without claiming ASD-STE100 compliance.
- Check one term per concept, active voice, clear actors and references,
  condition-before-action order, direct headings, and concrete verbs.
- Flag long or complex sentences, excessive splitting, and unnatural repeated
  nouns.
- Apply tighter targets to instructions and warnings, not mechanically to
  explanatory examples.

Reconcile all three reviews. Technical fidelity wins when a style suggestion
would remove meaning. Resolve technical findings first, then editorial and
controlled-language findings. Run a targeted technical review on factual text
changed during reconciliation.

If separate reviewers are unavailable, perform and label the three reviews in
sequence. Do not collapse them into one generic prose pass.
