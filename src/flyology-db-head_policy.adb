package body Flyology.DB.Head_Policy
  with SPARK_Mode => On
is

   function Valid_Writer_Acquisition
     (Current, Candidate : Head_State) return Boolean
   is
   begin
      return
        Candidate.Database_ID = Current.Database_ID
        and then not Is_Zero (Candidate.Database_ID)
        and then Current.Version = Current_Format
        and then Candidate.Version = Current_Format
        and then Candidate.Epoch = Current.Epoch + 1
        and then Candidate.Highest_Visible = Current.Highest_Visible
        and then Candidate.Latest_Batch = Current.Latest_Batch
        and then Candidate.Latest_Manifest = Current.Latest_Manifest
        and then not Is_Zero (Candidate.Transition_ID)
        and then Candidate.Transition_ID /= Current.Transition_ID
        and then Candidate.Predecessor_Transition = Current.Transition_ID
        and then Candidate.Transition_Number = Current.Transition_Number + 1
        and then Structurally_Valid (Candidate);
   end Valid_Writer_Acquisition;

   function Valid_Commit
     (Current, Candidate : Head_State;
      Batch_ID           : Identifier;
      Transactions       : Transaction_Count) return Boolean
   is
   begin
      return
        Candidate.Database_ID = Current.Database_ID
        and then not Is_Zero (Candidate.Database_ID)
        and then Current.Version = Current_Format
        and then Candidate.Version = Current_Format
        and then Candidate.Epoch = Current.Epoch
        and then Candidate.Highest_Visible =
          Current.Highest_Visible + Commit_Sequence (Transactions)
        and then not Is_Zero (Batch_ID)
        and then Candidate.Latest_Batch = Batch_ID
        and then Candidate.Latest_Manifest = Current.Latest_Manifest
        and then not Is_Zero (Candidate.Transition_ID)
        and then Candidate.Transition_ID /= Current.Transition_ID
        and then Candidate.Predecessor_Transition = Current.Transition_ID
        and then Candidate.Transition_Number = Current.Transition_Number + 1
        and then Structurally_Valid (Candidate);
   end Valid_Commit;

   function Reconcile
     (Expected_Predecessor : Identifier;
      Attempted_Transition : Identifier;
      Attempted_Number     : Transition_Ordinal;
      Head_Was_Read        : Boolean;
      Observed_Transition  : Identifier;
      Observed_Predecessor : Identifier;
      Observed_Number      : Transition_Ordinal) return Reconciliation_Result
   is
   begin
      if not Head_Was_Read then
         return Outcome_Unknown;
      elsif Observed_Number = Attempted_Number
        and then Observed_Transition = Attempted_Transition
      then
         return Publication_Confirmed;
      elsif Attempted_Number < Transition_Ordinal'Last
        and then Observed_Number = Attempted_Number + 1
        and then Observed_Predecessor = Attempted_Transition
      then
         return Publication_Confirmed;
      elsif Observed_Number = Attempted_Number
        and then Observed_Predecessor = Expected_Predecessor
      then
         return Precondition_Lost;
      else
         return Outcome_Unknown;
      end if;
   end Reconcile;

end Flyology.DB.Head_Policy;
