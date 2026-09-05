with Interfaces;

package Flyology.DB.Benchmark_Controls is

   --  Rewrite a fresh benchmark root to the private independent-coalescing
   --  profile, reopen it, and select the exact experimental cohort width.
   procedure Enable_Independent_Coalescing
     (Item        : in out Database;
      Storage     : not null access Storage_Context;
      Database_ID : Database_Identifier;
      Manifest_ID : Identifier;
      Width       : Positive;
      Timeout     : Duration;
      Result      : out Outcome_Code);

   --  Terminalize only queued members after a benchmark-harness failure so
   --  exact-width tail waiting cannot trap exception cleanup.
   procedure Abort_Independent_Coalescing
     (Item : in out Database; Result : out Outcome_Code);

   procedure Publication_Counts
     (Item          : in out Storage_Context;
      Batch_Puts    : out Natural;
      Manifest_Puts : out Natural;
      Head_Puts     : out Natural);

   function Attempted_Transition_Number (Item : Commit_Receipt) return Interfaces.Unsigned_64;

end Flyology.DB.Benchmark_Controls;
