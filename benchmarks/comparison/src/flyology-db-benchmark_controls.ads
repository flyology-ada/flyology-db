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

   --  Rewrite a fresh benchmark root to the private aggregate-coalescing
   --  profile. First_Batch_Ordinal selects a caller-owned never-reused
   --  physical identity range; the runtime derives no hardware policy.
   procedure Enable_Aggregate_Coalescing
     (Item                : in out Database;
      Storage             : not null access Storage_Context;
      Database_ID         : Database_Identifier;
      Manifest_ID         : Identifier;
      Width               : Positive;
      First_Batch_Ordinal : Interfaces.Unsigned_64;
      Timeout             : Duration;
      Result              : out Outcome_Code);

   --  Rewrite a fresh benchmark root to the private aggregate profile and
   --  select caller-owned adaptive scheduling bounds. These values are
   --  workload inputs, not persisted or public defaults.
   procedure Enable_Adaptive_Aggregate_Coalescing
     (Item                  : in out Database;
      Storage               : not null access Storage_Context;
      Database_ID           : Database_Identifier;
      Manifest_ID           : Identifier;
      Maximum_Members       : Positive;
      Maximum_Encoded_Bytes : Interfaces.Unsigned_64;
      Maximum_Wait          : Duration;
      Admission_Depth       : Positive;
      Timeout               : Duration;
      Result                : out Outcome_Code);

   --  Terminalize only queued members after a benchmark-harness failure so
   --  exact-width tail waiting cannot trap exception cleanup.
   procedure Abort_Independent_Coalescing
     (Item : in out Database; Result : out Outcome_Code);

   subtype Diagnostic_Cohort_Width is Positive range 1 .. Maximum_Group_Transactions;
   type Diagnostic_Cohort_Width_Counts is
     array (Diagnostic_Cohort_Width) of Interfaces.Unsigned_64;
   type Adaptive_Cohort_Phase_Durations is record
      Prepublication_Nanoseconds : Interfaces.Unsigned_64 := 0;
      Build_Nanoseconds          : Interfaces.Unsigned_64 := 0;
      Validation_Nanoseconds     : Interfaces.Unsigned_64 := 0;
      Batch_Put_Nanoseconds      : Interfaces.Unsigned_64 := 0;
      Head_Encode_Nanoseconds    : Interfaces.Unsigned_64 := 0;
      Head_Put_Nanoseconds       : Interfaces.Unsigned_64 := 0;
      Installation_Nanoseconds   : Interfaces.Unsigned_64 := 0;
      Precompletion_Nanoseconds  : Interfaces.Unsigned_64 := 0;
   end record;
   type Adaptive_Cohort_Diagnostics is record
      Cohort_Total          : Interfaces.Unsigned_64 := 0;
      Member_Total          : Interfaces.Unsigned_64 := 0;
      Encoded_Bytes         : Interfaces.Unsigned_64 := 0;
      Width_Counts          : Diagnostic_Cohort_Width_Counts := [others => 0];
      Member_Boundary_Total : Interfaces.Unsigned_64 := 0;
      Byte_Boundary_Total   : Interfaces.Unsigned_64 := 0;
      Hard_Boundary_Total   : Interfaces.Unsigned_64 := 0;
      Wait_Boundary_Total   : Interfaces.Unsigned_64 := 0;
      Close_Boundary_Total  : Interfaces.Unsigned_64 := 0;
      Phase_Cohort_Total    : Interfaces.Unsigned_64 := 0;
      Phases                : Adaptive_Cohort_Phase_Durations;
   end record;

   --  Enable and reset private adaptive-cohort diagnostics only at a
   --  quiescent benchmark boundary. This is measurement control, not runtime
   --  scheduling policy.
   procedure Begin_Adaptive_Cohort_Diagnostics
     (Item : in out Database; Result : out Outcome_Code);

   --  Atomically snapshot and disable the private diagnostics at a quiescent
   --  benchmark boundary.
   procedure Finish_Adaptive_Cohort_Diagnostics
     (Item        : in out Database;
      Diagnostics : out Adaptive_Cohort_Diagnostics;
      Result      : out Outcome_Code);

   procedure Publication_Counts
     (Item          : in out Storage_Context;
      Batch_Puts    : out Natural;
      Manifest_Puts : out Natural;
      Head_Puts     : out Natural);

   function Attempted_Transition_Number (Item : Commit_Receipt) return Interfaces.Unsigned_64;

   function Aggregate_Batch_ID (Ordinal : Interfaces.Unsigned_64) return Identifier;

end Flyology.DB.Benchmark_Controls;
