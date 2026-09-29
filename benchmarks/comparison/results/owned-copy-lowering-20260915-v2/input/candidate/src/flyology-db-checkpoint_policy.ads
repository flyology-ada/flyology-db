with Interfaces;

--  Selects the L0 checkpoint action implied by persisted run authorities.

private package Flyology.DB.Checkpoint_Policy
  with SPARK_Mode => On
is

   type Run_Count_Array is array (Positive range <>) of Interfaces.Unsigned_32;
   type Family_Flag_Array is array (Positive range <>) of Boolean;

   type Selection is
     (Invalid_Authority, No_Work, Additive_Flush, Complete_Compaction, No_Admissible_Checkpoint);

   --  Select from exact current run counts, persisted ceilings, changed
   --  families, and complete-view nonempty families. Arrays describe the same
   --  ordered family registry. The 64-family length bound is inherited from
   --  the manifest compatibility contract, not selected by this policy.
   function Decide
     (Current_Runs       : Run_Count_Array;
      Maximum_Runs       : Run_Count_Array;
      Changed            : Family_Flag_Array;
      Nonempty           : Family_Flag_Array;
      Checkpoint_Dirty   : Boolean;
      Maximum_Total_Runs : Interfaces.Unsigned_32) return Selection
   with
     Pre =>
       Current_Runs'First = Maximum_Runs'First
       and then Current_Runs'Last = Maximum_Runs'Last
       and then Current_Runs'First = Changed'First
       and then Current_Runs'Last = Changed'Last
       and then Current_Runs'First = Nonempty'First
       and then Current_Runs'Last = Nonempty'Last
       and then Current_Runs'Length <= Maximum_Initial_Column_Families;

end Flyology.DB.Checkpoint_Policy;
