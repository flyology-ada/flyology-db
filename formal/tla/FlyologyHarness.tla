------------------------- MODULE FlyologyHarness --------------------------

TraceAlias(Action, Role, Input, Outcome, State) ==
    [action |-> Action,
     role |-> Role,
     input |-> Input,
     outcome |-> Outcome,
     state |-> State,
     model_source |-> Action]

CheckedWitnessAlias(Action, State) ==
    TraceAlias(Action, "witness", [action |-> Action], [accepted |-> TRUE], State)

=============================================================================
