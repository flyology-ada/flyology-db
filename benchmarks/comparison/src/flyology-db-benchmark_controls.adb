package body Flyology.DB.Benchmark_Controls is

   procedure Enable_Independent_Coalescing
     (Item        : in out Database;
      Storage     : not null access Storage_Context;
      Database_ID : Database_Identifier;
      Manifest_ID : Identifier;
      Width       : Positive;
      Timeout     : Duration;
      Result      : out Outcome_Code) is
   begin
      Close (Item, Result);
      if Result /= Success then
         return;
      end if;
      Rewrite_Test_Manifest_Profile (Storage.all, Manifest_ID, Database_ID, Result);
      if Result /= Success then
         return;
      end if;
      Open (Item, Storage, Database_ID, Timeout, Result => Result);
      if Result /= Success then
         return;
      end if;
      Set_Test_Independent_Cohort_Width (Item, Width, Result);
   end Enable_Independent_Coalescing;

   procedure Enable_Aggregate_Coalescing
     (Item                : in out Database;
      Storage             : not null access Storage_Context;
      Database_ID         : Database_Identifier;
      Manifest_ID         : Identifier;
      Width               : Positive;
      First_Batch_Ordinal : Interfaces.Unsigned_64;
      Timeout             : Duration;
      Result              : out Outcome_Code) is
   begin
      Close (Item, Result);
      if Result /= Success then
         return;
      end if;
      Rewrite_Test_Manifest_Profile
        (Storage.all, Manifest_ID, Database_ID, Result, Aggregate_Profile => True);
      if Result /= Success then
         return;
      end if;
      Open (Item, Storage, Database_ID, Timeout, Result => Result);
      if Result /= Success then
         return;
      end if;
      Set_Test_Aggregate_Cohort_Width (Item, Width, First_Batch_Ordinal, Result);
   end Enable_Aggregate_Coalescing;

   procedure Abort_Independent_Coalescing
     (Item : in out Database; Result : out Outcome_Code) is
   begin
      Abort_Test_Independent_Cohort (Item, Result);
   end Abort_Independent_Coalescing;

   procedure Publication_Counts
     (Item          : in out Storage_Context;
      Batch_Puts    : out Natural;
      Manifest_Puts : out Natural;
      Head_Puts     : out Natural) is
   begin
      Item.Test_Control.Publication_Counts (Batch_Puts, Manifest_Puts, Head_Puts);
   end Publication_Counts;

   function Attempted_Transition_Number (Item : Commit_Receipt) return Interfaces.Unsigned_64
   is (Item.Attempted_Head.Transition_Number);

   function Aggregate_Batch_ID (Ordinal : Interfaces.Unsigned_64) return Identifier
   is (Structural_ID (16#C5#, Ordinal));

end Flyology.DB.Benchmark_Controls;
