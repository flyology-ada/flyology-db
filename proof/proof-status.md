# Proof Status: Flyology.DB LSM reference formats
<!-- Reflect the top-level goal given. Items in the list below are moved from
     Not Started to In Progress to Reviewed and finally to Proved and Finalized. -->

Initial level-0 assessment generated checks for the proof instantiation and found cursor, accumulator, decoder
postcondition, and exact-extent obligations. Wire types are fixed; internal proof subtypes and decomposition may use
only bounds derived from the exact format formulas.

## Proved and Finalized
<!-- Before marking an item complete here, follow the Widen Scope step
     (Strategic Loop Step 5) in workflow.md in the /gnatprove Skill.
     Remember: changes to types used by or called subprograms in a given
     subprogram may cause it to regress to an unproved state. Reproving at the
     wider scope is thus a critical means to detect these situations. -->

- [x] LSM reference-format proof instance (level 1, mode all)
  - [x] `Flyology.DB.LSM_Formats.Reference`: 435/435 checks in the focused instance
  - [x] Repository selected-unit widening: 1,078/1,078 checks, 164 flow and 914 prover
- [x] Checkpoint-manifest decoder proof-robustness decomposition
  - [x] Public fail-closed wrapper: 2/2 checks
  - [x] Private success-only candidate parser: 118/118 checks
  - [x] Repository selected-unit widening: 1,103/1,103 checks, 172 flow and 931 prover

## Reviewed
<!-- Before marking an item complete here, review it following the Review
     step (Strategic Loop Step 4) in workflow.md in the /gnatprove Skill -->

- [x] Encoder, decoder, structural-validation, exact-length, and identifier helper obligations reviewed after the
      focused instance proved
- [x] Independent read-only review confirmed the open decoder goal was solver-resource
      fragility and that parser/result decomposition preserves the public contract and
      runtime outcomes

## In Progress
<!-- A subagent executes the Tactical Loop for the subprogram below.
     It should update this section as it works. -->

## Not Started
<!-- Whenever a subprogram is added (due to refactoring) or discovered
     during assessment (Strategic Loop Steps 1-2), list it here so it
     is not forgotten. -->


## Discovered Obligations

- [x] Widen from each proved subprogram to the instantiated unit and then the repository proof suite
