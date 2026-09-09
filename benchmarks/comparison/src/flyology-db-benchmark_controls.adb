with Ada.Real_Time;

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
      Result                : out Outcome_Code) is
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
      Set_Test_Adaptive_Aggregate_Cohort
        (Item,
         Maximum_Members,
         Maximum_Encoded_Bytes,
         Ada.Real_Time.To_Time_Span (Maximum_Wait),
         Admission_Depth,
         Result);
   end Enable_Adaptive_Aggregate_Coalescing;

   procedure Abort_Independent_Coalescing
     (Item : in out Database; Result : out Outcome_Code) is
   begin
      Abort_Test_Independent_Cohort (Item, Result);
   end Abort_Independent_Coalescing;

   procedure Begin_Adaptive_Cohort_Diagnostics
     (Item : in out Database; Result : out Outcome_Code) is
   begin
      Begin_Test_Adaptive_Cohort_Diagnostics (Item, Result);
   end Begin_Adaptive_Cohort_Diagnostics;

   procedure Finish_Adaptive_Cohort_Diagnostics
     (Item        : in out Database;
      Diagnostics : out Adaptive_Cohort_Diagnostics;
      Result      : out Outcome_Code)
   is
      Runtime_Diagnostics : Test_Adaptive_Cohort_Diagnostics;
   begin
      Diagnostics := (others => <>);
      Finish_Test_Adaptive_Cohort_Diagnostics (Item, Runtime_Diagnostics, Result);
      if Result /= Success then
         return;
      elsif Runtime_Diagnostics.Width_Counts'First /= Diagnostic_Cohort_Width_Counts'First
        or else Runtime_Diagnostics.Width_Counts'Last /= Diagnostic_Cohort_Width_Counts'Last
      then
         Result := Invalid_State;
         return;
      end if;
      Diagnostics :=
        (Cohort_Total          => Runtime_Diagnostics.Cohort_Total,
         Member_Total          => Runtime_Diagnostics.Member_Total,
         Encoded_Bytes         => Runtime_Diagnostics.Encoded_Bytes,
         Width_Counts          => Diagnostic_Cohort_Width_Counts (Runtime_Diagnostics.Width_Counts),
         Member_Boundary_Total => Runtime_Diagnostics.Member_Boundary_Total,
         Byte_Boundary_Total   => Runtime_Diagnostics.Byte_Boundary_Total,
         Hard_Boundary_Total   => Runtime_Diagnostics.Hard_Boundary_Total,
         Wait_Boundary_Total   => Runtime_Diagnostics.Wait_Boundary_Total,
         Close_Boundary_Total  => Runtime_Diagnostics.Close_Boundary_Total,
         Phase_Cohort_Total    => Runtime_Diagnostics.Phase_Cohort_Total,
         Phases                =>
           (Prepublication_Nanoseconds => Runtime_Diagnostics.Phases.Prepublication_Nanoseconds,
            Build_Nanoseconds          => Runtime_Diagnostics.Phases.Build_Nanoseconds,
            Validation_Nanoseconds     => Runtime_Diagnostics.Phases.Validation_Nanoseconds,
            Batch_Put_Nanoseconds      => Runtime_Diagnostics.Phases.Batch_Put_Nanoseconds,
            Head_Encode_Nanoseconds    => Runtime_Diagnostics.Phases.Head_Encode_Nanoseconds,
            Head_Put_Nanoseconds       => Runtime_Diagnostics.Phases.Head_Put_Nanoseconds,
            Installation_Nanoseconds   => Runtime_Diagnostics.Phases.Installation_Nanoseconds,
            Precompletion_Nanoseconds  => Runtime_Diagnostics.Phases.Precompletion_Nanoseconds));
   end Finish_Adaptive_Cohort_Diagnostics;

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
