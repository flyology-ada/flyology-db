with Interfaces;

--  Defines deterministic database-head transitions and ambiguous-outcome reconciliation.
private package Flyology.DB.Head_Policy
  with SPARK_Mode => On
is

   use type Interfaces.Unsigned_64;

   Identifier_Length : constant := 16;
   subtype Identifier_Index is Positive range 1 .. Identifier_Length;
   type Identifier is array (Identifier_Index) of Interfaces.Unsigned_8;

   Zero_Identifier : constant Identifier := (others => 0);

   --  Whether an identifier is the reserved absent value.
   function Is_Zero (Value : Identifier) return Boolean is (Value = Zero_Identifier);

   type Format_Version is new Interfaces.Unsigned_16 range 1 .. Interfaces.Unsigned_16'Last;
   Legacy_Format  : constant Format_Version := 1;
   Current_Format : constant Format_Version := 2;

   type Writer_Epoch is new Interfaces.Unsigned_64;
   type Commit_Sequence is new Interfaces.Unsigned_64;
   type Transition_Ordinal is new Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64'Last;
   type Transaction_Count is new Interfaces.Unsigned_32 range 1 .. 4_096;

   type Head_State is record
      Database_ID             : Identifier := Zero_Identifier;
      Version                 : Format_Version := Current_Format;
      Epoch                   : Writer_Epoch := 0;
      Highest_Visible         : Commit_Sequence := 0;
      Latest_Batch            : Identifier := Zero_Identifier;
      Latest_Manifest         : Identifier := Zero_Identifier;
      Transition_ID           : Identifier := Zero_Identifier;
      Predecessor_Transition  : Identifier := Zero_Identifier;
      Transition_Number       : Transition_Ordinal := Transition_Ordinal'First;
   end record;

   --  Whether Candidate has a reachable inspection-only version-1 head shape.
   function Structurally_Valid_V1 (Candidate : Head_State) return Boolean is
     (not Is_Zero (Candidate.Database_ID)
      and then Candidate.Version = Legacy_Format
      and then Candidate.Epoch > 0
      and then not Is_Zero (Candidate.Transition_ID)
      and then Is_Zero (Candidate.Latest_Manifest)
      and then
      (if Candidate.Highest_Visible = 0 then
         Is_Zero (Candidate.Latest_Batch)
         and then Interfaces.Unsigned_64 (Candidate.Epoch) =
           Interfaces.Unsigned_64 (Candidate.Transition_Number)
       else
         not Is_Zero (Candidate.Latest_Batch)
         and then Interfaces.Unsigned_64 (Candidate.Epoch) <
           Interfaces.Unsigned_64 (Candidate.Transition_Number))
      and then
      (if Candidate.Transition_Number = Transition_Ordinal'First then
         Candidate.Epoch = 1
         and then Candidate.Highest_Visible = 0
         and then Is_Zero (Candidate.Latest_Batch)
         and then Is_Zero (Candidate.Predecessor_Transition)
       else
         not Is_Zero (Candidate.Predecessor_Transition)
         and then Candidate.Transition_ID /= Candidate.Predecessor_Transition));

   --  Whether Candidate has a reachable manifest-bearing version-2 head shape.
   function Structurally_Valid_V2 (Candidate : Head_State) return Boolean is
     (not Is_Zero (Candidate.Database_ID)
      and then Candidate.Version = Current_Format
      and then Candidate.Epoch > 0
      and then Interfaces.Unsigned_64 (Candidate.Epoch) <=
        Interfaces.Unsigned_64 (Candidate.Transition_Number)
      and then not Is_Zero (Candidate.Latest_Manifest)
      and then not Is_Zero (Candidate.Transition_ID)
      and then
      (if Candidate.Highest_Visible = 0 then
         Is_Zero (Candidate.Latest_Batch)
       else
         not Is_Zero (Candidate.Latest_Batch)
         and then Interfaces.Unsigned_64 (Candidate.Epoch) <
           Interfaces.Unsigned_64 (Candidate.Transition_Number))
      and then
      (if Candidate.Transition_Number = Transition_Ordinal'First then
         Candidate.Epoch = 1
         and then Candidate.Highest_Visible = 0
         and then Is_Zero (Candidate.Latest_Batch)
         and then Is_Zero (Candidate.Predecessor_Transition)
       else
         not Is_Zero (Candidate.Predecessor_Transition)
         and then Candidate.Transition_ID /= Candidate.Predecessor_Transition));

   --  Whether Candidate uses one supported, structurally reachable HEAD version.
   function Structurally_Valid (Candidate : Head_State) return Boolean is
     (if Candidate.Version = Legacy_Format then
        Structurally_Valid_V1 (Candidate)
      elsif Candidate.Version = Current_Format then
        Structurally_Valid_V2 (Candidate)
      else
        False);

   --  Whether a head is a valid initial database publication.
   function Valid_Initial (Candidate : Head_State) return Boolean is
     (Structurally_Valid (Candidate)
      and then Candidate.Transition_Number = Transition_Ordinal'First);

   --  Whether Candidate conditionally acquires a new writer epoch from Current.
   function Valid_Writer_Acquisition
     (Current, Candidate : Head_State) return Boolean
   with
     Pre => Structurally_Valid (Current)
       and then Current.Epoch < Writer_Epoch'Last
       and then Current.Transition_Number < Transition_Ordinal'Last;

   --  Whether Candidate publishes one immutable batch from Current.
   function Valid_Commit
     (Current, Candidate : Head_State;
      Batch_ID           : Identifier;
      Transactions       : Transaction_Count) return Boolean
   with
     Pre => Structurally_Valid (Current)
       and then Current.Highest_Visible <=
         Commit_Sequence'Last - Commit_Sequence (Transactions)
       and then Current.Transition_Number < Transition_Ordinal'Last;

   type Reconciliation_Result is
     (Publication_Confirmed, Precondition_Lost, Outcome_Unknown);

   --  Classify an exact head observation after a conditional replacement returned
   --  an unknown outcome.
   --  A direct successor of the attempted transition proves publication. A sibling
   --  transition from the expected predecessor proves that another writer won the
   --  condition. All other observations remain unknown.
   function Reconcile
     (Expected_Predecessor : Identifier;
      Attempted_Transition : Identifier;
      Attempted_Number     : Transition_Ordinal;
      Head_Was_Read        : Boolean;
      Observed_Transition  : Identifier;
      Observed_Predecessor : Identifier;
      Observed_Number      : Transition_Ordinal) return Reconciliation_Result
   with
     Pre => not Is_Zero (Expected_Predecessor)
       and then not Is_Zero (Attempted_Transition)
       and then Expected_Predecessor /= Attempted_Transition
       and then Attempted_Number > Transition_Ordinal'First,
     Post =>
       (if Reconcile'Result = Publication_Confirmed then
          Head_Was_Read
          and then
          ((Observed_Number = Attempted_Number
            and then Observed_Transition = Attempted_Transition)
           or else
           (Attempted_Number < Transition_Ordinal'Last
            and then Observed_Number = Attempted_Number + 1
            and then Observed_Predecessor = Attempted_Transition)))
       and then
       (if Reconcile'Result = Precondition_Lost then
          Head_Was_Read
          and then Observed_Number = Attempted_Number
          and then Observed_Transition /= Attempted_Transition
          and then Observed_Predecessor /= Attempted_Transition
          and then Observed_Predecessor = Expected_Predecessor);

end Flyology.DB.Head_Policy;
