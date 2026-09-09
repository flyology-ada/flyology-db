with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Flyology.Bytes;
with Flyology.DB;
with Flyology.DB.Benchmark_Controls;
with Flyology.DB.Object_Storage;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Files;
with Flyology.Object_Storage.Client.Low_Level;
with Flyology.Operations;
with Interfaces;

package body Flyology_DB_Benchmark_Flyology is
   package DB renames Flyology.DB;
   package Benchmark_Controls renames Flyology.DB.Benchmark_Controls;
   package Binding renames Flyology.DB.Object_Storage;
   package Files renames Flyology.Object_Storage.Backends.Files;
   package HTTP renames Flyology.HTTP;
   package HTTP_Client renames Flyology.HTTP.Client;
   package Low_Level renames Flyology.Object_Storage.Client.Low_Level;
   package Operations renames Flyology.Operations;
   package OS renames Flyology.Object_Storage;
   package UStrings renames Ada.Strings.Unbounded;

   use type Ada.Real_Time.Time;
   use type DB.Byte;
   use type DB.Identifier;
   use type DB.Outcome_Code;
   use type DB.Sequence_Number;
   use type DB.Transaction_Identifier;
   use type OS.Status;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Maximum_Operations          : constant := 63;
   Maximum_Key_Length          : constant := 256;
   Maximum_Value_Length        : constant := 64 * 1_024;
   Maximum_Mutations_Per_Batch : constant := 256;
   Maximum_Pipeline_Depth       : constant := 8;
   Timeout                     : constant Duration := 30.0;
   Local_Bucket                : constant String := "flyology-db-benchmark";
   Local_Prefix                : constant String := "database";

   type Caller_Diagnostics is record
      Cohort_Total             : Interfaces.Unsigned_64 := 0;
      Member_Total             : Interfaces.Unsigned_64 := 0;
      Width_Counts             : Benchmark_Controls.Diagnostic_Cohort_Width_Counts := [others => 0];
      Preparation_Nanoseconds  : Interfaces.Unsigned_64 := 0;
      Admission_Nanoseconds    : Interfaces.Unsigned_64 := 0;
      Completion_Drive_Nanoseconds : Interfaces.Unsigned_64 := 0;
   end record;

   Latest_Diagnostics_Available : Boolean := False;
   Latest_Configuration_Available : Boolean := False;
   Latest_Runtime_Diagnostics   : Benchmark_Controls.Adaptive_Cohort_Diagnostics;
   Latest_Caller_Diagnostics    : Caller_Diagnostics;
   Latest_Batch_Publications    : Natural := 0;
   Latest_Manifest_Publications : Natural := 0;
   Latest_Head_Publications     : Natural := 0;

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Expect (Actual : DB.Outcome_Code; Context : String) is
   begin
      if Actual /= DB.Success then
         raise Program_Error
           with Context & ": " & DB.Outcome_Code'Image (Actual);
      end if;
   end Expect;

   function Required_Environment (Name : String) return String is
   begin
      if not Ada.Environment_Variables.Exists (Name)
        or else Ada.Environment_Variables.Value (Name)'Length = 0
      then
         raise Program_Error
           with "required environment variable is absent: " & Name;
      end if;
      return Ada.Environment_Variables.Value (Name);
   end Required_Environment;

   function Optional_Environment (Name : String) return String is
     (if Ada.Environment_Variables.Exists (Name)
      then Ada.Environment_Variables.Value (Name)
      else "");

   function Effective_Commit_Diagnostics return Boolean is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_COMMIT_DIAGNOSTICS");
   begin
      if Raw'Length = 0 or else Raw = "0" then
         return False;
      elsif Raw = "1" then
         return True;
      end if;
      raise Program_Error with "FLYOLOGY_DB_BENCH_COMMIT_DIAGNOSTICS must be 0 or 1";
   end Effective_Commit_Diagnostics;

   function Image (Value : Interfaces.Unsigned_64) return String is
     (Ada.Strings.Fixed.Trim (Interfaces.Unsigned_64'Image (Value), Ada.Strings.Both));

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Nanoseconds_Between
     (Started, Finished : Ada.Real_Time.Time) return Interfaces.Unsigned_64
   is
   begin
      if Finished <= Started then
         return 0;
      end if;
      return
        Interfaces.Unsigned_64
          (Long_Long_Integer
             (Ada.Real_Time.To_Duration (Finished - Started) * 1_000_000_000.0));
   exception
      when Constraint_Error =>
         return Interfaces.Unsigned_64'Last;
   end Nanoseconds_Between;

   procedure Add_Elapsed
     (Target : in out Interfaces.Unsigned_64; Started, Finished : Ada.Real_Time.Time)
   is
      Value : constant Interfaces.Unsigned_64 := Nanoseconds_Between (Started, Finished);
   begin
      if Value > Interfaces.Unsigned_64'Last - Target then
         Target := Interfaces.Unsigned_64'Last;
      else
         Target := Target + Value;
      end if;
   end Add_Elapsed;

   function Last_Run_Configuration_NDJSON
     (Participant : String; Execution_Ordinal : Natural; Transactions : Positive) return String is
   begin
      if not Latest_Configuration_Available then
         return "";
      end if;
      return
        "{""schema"":""flyology.db.benchmark.execution_configuration.v1"""
        & ",""kind"":""flyology_db_execution_configuration"""
        & ",""participant"":""" & Participant & """"
        & ",""execution_ordinal"":" & Image (Execution_Ordinal)
        & ",""transactions"":" & Image (Transactions)
        & ",""batch_publications"":" & Image (Latest_Batch_Publications)
        & ",""manifest_publications"":" & Image (Latest_Manifest_Publications)
        & ",""head_publications"":" & Image (Latest_Head_Publications)
        & "}";
   end Last_Run_Configuration_NDJSON;

   function Last_Run_Diagnostics_NDJSON
     (Execution_Ordinal : Natural; Transactions : Positive) return String
   is
      Result : UStrings.Unbounded_String;
   begin
      if not Latest_Diagnostics_Available then
         return "";
      end if;
      Result :=
        UStrings.To_Unbounded_String
          ("{""schema"":""flyology.db.benchmark.commit_diagnostics.v1"""
         & ",""kind"":""flyology_db_commit_diagnostics"""
           & ",""attribution"":""elapsed_upper_bounds_nonadditive"""
           & ",""worker_span_semantics"":""provider_inclusive_sequential"""
           & ",""caller_span_semantics"":""overlaps_worker_completion_includes_driver"""
           & ",""boundary_semantics"":""nonexclusive_predicates"""
           & ",""precompletion_semantics"":""inclusive_worker_total"""
           & ",""execution_ordinal"":" & Image (Execution_Ordinal)
           & ",""transactions"":" & Image (Transactions)
           & ",""cohort_total"":" & Image (Latest_Runtime_Diagnostics.Cohort_Total)
           & ",""member_total"":" & Image (Latest_Runtime_Diagnostics.Member_Total)
           & ",""encoded_bytes"":" & Image (Latest_Runtime_Diagnostics.Encoded_Bytes)
           & ",""width_counts"":{");
      for Width in Benchmark_Controls.Diagnostic_Cohort_Width loop
         UStrings.Append
           (Result,
            (if Width = Benchmark_Controls.Diagnostic_Cohort_Width'First then "" else ",")
            & """" & Image (Width) & """:"
            & Image (Latest_Runtime_Diagnostics.Width_Counts (Width)));
      end loop;
      UStrings.Append
        (Result,
         "},""member_boundary_total"":"
         & Image (Latest_Runtime_Diagnostics.Member_Boundary_Total)
         & ",""byte_boundary_total"":" & Image (Latest_Runtime_Diagnostics.Byte_Boundary_Total)
         & ",""hard_boundary_total"":" & Image (Latest_Runtime_Diagnostics.Hard_Boundary_Total)
         & ",""wait_boundary_total"":" & Image (Latest_Runtime_Diagnostics.Wait_Boundary_Total)
         & ",""close_boundary_total"":" & Image (Latest_Runtime_Diagnostics.Close_Boundary_Total)
         & ",""phase_cohort_total"":" & Image (Latest_Runtime_Diagnostics.Phase_Cohort_Total)
         & ",""batch_publications"":" & Image (Latest_Batch_Publications)
         & ",""manifest_publications"":" & Image (Latest_Manifest_Publications)
         & ",""head_publications"":" & Image (Latest_Head_Publications)
         & ",""prepublication_ns"":"
         & Image (Latest_Runtime_Diagnostics.Phases.Prepublication_Nanoseconds)
         & ",""build_ns"":" & Image (Latest_Runtime_Diagnostics.Phases.Build_Nanoseconds)
         & ",""validation_ns"":" & Image (Latest_Runtime_Diagnostics.Phases.Validation_Nanoseconds)
         & ",""batch_put_ns"":" & Image (Latest_Runtime_Diagnostics.Phases.Batch_Put_Nanoseconds)
         & ",""head_encode_ns"":" & Image (Latest_Runtime_Diagnostics.Phases.Head_Encode_Nanoseconds)
         & ",""head_put_ns"":" & Image (Latest_Runtime_Diagnostics.Phases.Head_Put_Nanoseconds)
         & ",""installation_ns"":" & Image (Latest_Runtime_Diagnostics.Phases.Installation_Nanoseconds)
         & ",""precompletion_ns"":"
         & Image (Latest_Runtime_Diagnostics.Phases.Precompletion_Nanoseconds)
         & ",""caller_preparation_ns"":" & Image (Latest_Caller_Diagnostics.Preparation_Nanoseconds)
         & ",""caller_admission_ns"":" & Image (Latest_Caller_Diagnostics.Admission_Nanoseconds)
         & ",""caller_completion_drive_ns"":"
         & Image (Latest_Caller_Diagnostics.Completion_Drive_Nanoseconds)
         & "}");
      return UStrings.To_String (Result);
   end Last_Run_Diagnostics_NDJSON;

   function Requested_Group_Size return Positive is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_GROUP_SIZE");
   begin
      return (if Raw'Length = 0 then 1 else Positive'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with "FLYOLOGY_DB_BENCH_GROUP_SIZE must be a positive integer";
   end Requested_Group_Size;

   function Requested_Explicit_Group return Boolean is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_EXPLICIT_GROUP");
   begin
      if Raw'Length = 0 or else Raw = "0" then
         return False;
      elsif Raw = "1" then
         return True;
      end if;
      raise Program_Error with "FLYOLOGY_DB_BENCH_EXPLICIT_GROUP must be 0 or 1";
   end Requested_Explicit_Group;

   function Requested_Pipeline_Depth return Positive is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_PIPELINE_DEPTH");
   begin
      return (if Raw'Length = 0 then 1 else Positive'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with "FLYOLOGY_DB_BENCH_PIPELINE_DEPTH must be a positive integer";
   end Requested_Pipeline_Depth;

   function Requested_Wave_Scheduling return Boolean is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_PIPELINE_SCHEDULE");
   begin
      if Raw'Length = 0 or else Raw = "rolling" then
         return False;
      elsif Raw = "waves" then
         return True;
      end if;
      raise Program_Error with "FLYOLOGY_DB_BENCH_PIPELINE_SCHEDULE must be rolling or waves";
   end Requested_Wave_Scheduling;

   function Requested_Independent_Cohort_Width return Natural is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_INDEPENDENT_COHORT_WIDTH");
   begin
      return (if Raw'Length = 0 then 0 else Natural'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with "FLYOLOGY_DB_BENCH_INDEPENDENT_COHORT_WIDTH must be a natural number";
   end Requested_Independent_Cohort_Width;

   function Requested_Aggregate_Cohort_Width return Natural is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_AGGREGATE_COHORT_WIDTH");
   begin
      return (if Raw'Length = 0 then 0 else Natural'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with "FLYOLOGY_DB_BENCH_AGGREGATE_COHORT_WIDTH must be a natural number";
   end Requested_Aggregate_Cohort_Width;

   function Requested_Aggregate_First_Batch_Ordinal return Interfaces.Unsigned_64 is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_AGGREGATE_FIRST_BATCH_ORDINAL");
   begin
      return (if Raw'Length = 0 then 0 else Interfaces.Unsigned_64'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with
           "FLYOLOGY_DB_BENCH_AGGREGATE_FIRST_BATCH_ORDINAL must be an unsigned integer";
   end Requested_Aggregate_First_Batch_Ordinal;

   function Requested_Adaptive_Maximum_Members return Natural is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_MEMBERS");
   begin
      return (if Raw'Length = 0 then 0 else Natural'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with "FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_MEMBERS must be a natural number";
   end Requested_Adaptive_Maximum_Members;

   function Requested_Adaptive_Maximum_Encoded_Bytes return Interfaces.Unsigned_64 is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_ENCODED_BYTES");
   begin
      return (if Raw'Length = 0 then 0 else Interfaces.Unsigned_64'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with
           "FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_ENCODED_BYTES must be an unsigned integer";
   end Requested_Adaptive_Maximum_Encoded_Bytes;

   function Requested_Adaptive_Maximum_Wait_Microseconds return Interfaces.Unsigned_64 is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_WAIT_US");
   begin
      return (if Raw'Length = 0 then 0 else Interfaces.Unsigned_64'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with
           "FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_WAIT_US must be an unsigned integer";
   end Requested_Adaptive_Maximum_Wait_Microseconds;

   function Requested_Adaptive_Admission_Depth return Natural is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_ADAPTIVE_ADMISSION_DEPTH");
   begin
      return (if Raw'Length = 0 then 0 else Natural'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with "FLYOLOGY_DB_BENCH_ADAPTIVE_ADMISSION_DEPTH must be a natural number";
   end Requested_Adaptive_Admission_Depth;

   function Adaptive_Wait_Duration (Microseconds : Interfaces.Unsigned_64) return Duration is
      Whole_Seconds : constant Interfaces.Unsigned_64 := Microseconds / 1_000_000;
      Remainder     : constant Interfaces.Unsigned_64 := Microseconds mod 1_000_000;
   begin
      return Duration (Whole_Seconds) + Duration (Remainder) / 1_000_000.0;
   exception
      when Constraint_Error =>
         raise Program_Error with "FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_WAIT_US exceeds Duration'Last";
   end Adaptive_Wait_Duration;

   function Numbered_ID (Value : Interfaces.Unsigned_64) return DB.Identifier
   is
      Result    : DB.Identifier := [others => 0];
      Remaining : Interfaces.Unsigned_64 := Value;
   begin
      for Position in reverse Result'Last - 7 .. Result'Last loop
         Result (Position) := DB.Byte (Remaining mod 256);
         Remaining := Remaining / 256;
      end loop;
      return Result;
   end Numbered_ID;

   function Key_For (Index : Positive; Length : Positive) return DB.Byte_Array
   is
      Result    : DB.Byte_Array (1 .. Length) := [others => 0];
      Remaining : Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Index);
   begin
      for Position in reverse Result'Last - 7 .. Result'Last loop
         Result (Position) := DB.Byte (Remaining mod 256);
         Remaining := Remaining / 256;
      end loop;
      return Result;
   end Key_For;

   function Value_For
     (Index : Positive; Length : Positive) return DB.Byte_Array
   is
      Result : DB.Byte_Array (1 .. Length);
   begin
      for Position in Result'Range loop
         Result (Position) := DB.Byte ((Index + Position * 31) mod 256);
      end loop;
      return Result;
   end Value_For;

   function Byte_String (Data : DB.Byte_Array) return String is
      Result : String (1 .. Data'Length);
   begin
      for Offset in 0 .. Data'Length - 1 loop
         Result (Result'First + Offset) :=
           Character'Val (Data (Data'First + Offset));
      end loop;
      return Result;
   end Byte_String;

   function Same
     (Left : Flyology.Bytes.Unbounded_Bytes; Right : DB.Byte_Array)
      return Boolean is
   begin
      if Flyology.Bytes.Length (Left) /= Right'Length then
         return False;
      end if;
      for Position in Right'Range loop
         if DB.Byte
              (Flyology.Bytes.Element (Left, Position - Right'First + 1))
           /= Right (Position)
         then
            return False;
         end if;
      end loop;
      return True;
   end Same;

   --  website-benchmark:start flyology-durable-transaction
   procedure Prepare_Transaction
     (Item         : in out DB.Database;
      Family       : DB.Column_Family;
      Index        : Positive;
      Mutations    : Positive;
      Key_Length   : Positive;
      Value_Length : Positive;
      Transaction  : in out DB.Transaction)
   is
      Result : DB.Outcome_Code;
   begin
      DB.Begin_Transaction
        (Item,
         DB.Transaction_Identifier
           (Numbered_ID (Interfaces.Unsigned_64 (1_000 + Index))),
         DB.Snapshot,
         Transaction,
         Result);
      Expect (Result, "begin failed");
      for Mutation in 1 .. Mutations loop
         declare
            Key_Index : constant Positive :=
              (Index - 1) * Mutations + Mutation;
         begin
            DB.Put
              (Item,
               Transaction,
               Family,
               Key_For (Key_Index, Key_Length),
               Value_For (Key_Index, Value_Length),
               Result);
            Expect (Result, "put failed");
         end;
      end loop;
   exception
      when others =>
         DB.Rollback (Transaction, Result);
         raise;
   end Prepare_Transaction;

   procedure Put_Transaction
     (Item         : in out DB.Database;
      Family       : DB.Column_Family;
      Index        : Positive;
      Mutations    : Positive;
      Key_Length   : Positive;
      Value_Length : Positive;
      Deadline     : Duration)
   is
      Transaction : DB.Transaction;
      Receipt     : DB.Commit_Receipt;
      Result      : DB.Outcome_Code;
   begin
      Prepare_Transaction
        (Item, Family, Index, Mutations, Key_Length, Value_Length, Transaction);
      DB.Commit
        (Item, Transaction, Deadline, Receipt => Receipt, Result => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve (Item, Receipt, Timeout, Result => Result);
      end if;
      Expect (Result, "durable commit failed");
   exception
      when others =>
         DB.Rollback (Transaction, Result);
         raise;
   end Put_Transaction;
   --  website-benchmark:end flyology-durable-transaction

   procedure Put_Singletons_Pipelined
     (Item           : aliased in out DB.Database;
      Family         : DB.Column_Family;
      First_Index    : Positive;
      Count          : Positive;
      Pipeline_Depth : Positive;
      Mutations      : Positive;
      Key_Length     : Positive;
      Value_Length   : Positive;
      Deadline       : Duration;
      Cohort_Width   : Natural;
      Aggregate_First_Ordinal : Interfaces.Unsigned_64;
      Adaptive_Cohort : Boolean;
      Wave_Scheduling : Boolean;
      Collect_Diagnostics : Boolean;
      Diagnostics         : in out Caller_Diagnostics)
   is
      type Operation_Access is access DB.Commit_Operation;
      procedure Free is new Ada.Unchecked_Deallocation
        (Object => DB.Commit_Operation, Name => Operation_Access);
      type Operation_Array is array (Positive range <>) of Operation_Access;
      type Boolean_Array is array (Positive range <>) of Boolean;
      type Positive_Array is array (Positive range <>) of Positive;
      type Sequence_Array is array (Positive range <>) of DB.Sequence_Number;
      type Transition_Array is array (Positive range <>) of Interfaces.Unsigned_64;
      type Batch_ID_Array is array (Positive range <>) of DB.Identifier;

      Set            : aliased Operations.Completion_Set (Pipeline_Depth);
      Work           : Operation_Array (1 .. Pipeline_Depth) := [others => null];
      Active         : Boolean_Array (Work'Range) := [others => False];
      Index_For      : Positive_Array (Work'Range) := [others => First_Index];
      Sequences      : Sequence_Array (First_Index .. First_Index + Count - 1) := [others => 0];
      Transitions    : Transition_Array (Sequences'Range) := [others => 0];
      Batch_IDs      : Batch_ID_Array (Sequences'Range) := [others => [others => 0]];
      Completed      : Operations.Completion_Batch (Set.Capacity);
      Submitted      : Natural := 0;
      Finished       : Natural := 0;
      Active_Count   : Natural := 0;
      Abort_Result   : DB.Outcome_Code;

      procedure Finish_Slot (Slot : Positive) is
         Receipt     : DB.Commit_Receipt;
         Result      : DB.Outcome_Code;
         Index       : constant Positive := Index_For (Slot);
         Expected_ID : constant DB.Transaction_Identifier :=
           DB.Transaction_Identifier
             (Numbered_ID (Interfaces.Unsigned_64 (1_000 + Index)));
         Expected_Batch_ID : constant DB.Identifier :=
           (if Adaptive_Cohort or else Aggregate_First_Ordinal = 0
            then DB.Identifier (Expected_ID)
            else Benchmark_Controls.Aggregate_Batch_ID
              (Aggregate_First_Ordinal
               + Interfaces.Unsigned_64 ((Index - 1) / Cohort_Width)));
      begin
         DB.Finish (Work (Slot).all, Receipt, Result);
         Operations.Release (Work (Slot).all);
         Active (Slot) := False;
         Active_Count := Active_Count - 1;
         Finished := Finished + 1;
         Expect (Result, "pipelined singleton commit failed");
         Require
           (DB.Receipt_Outcome (Receipt) = DB.Success,
            "pipelined singleton receipt outcome mismatch");
         Require
           (DB.Receipt_Transaction_ID (Receipt) = Expected_ID
              and then
                (Adaptive_Cohort or else DB.Receipt_Batch_ID (Receipt) = Expected_Batch_ID),
            "pipelined singleton receipt identity mismatch");
         Require
           (DB.Receipt_Sequence (Receipt) > 0,
            "pipelined singleton receipt sequence is absent");
         Sequences (Index) := DB.Receipt_Sequence (Receipt);
         Transitions (Index) := Benchmark_Controls.Attempted_Transition_Number (Receipt);
         Batch_IDs (Index) := DB.Receipt_Batch_ID (Receipt);
      end Finish_Slot;

      procedure Drain_Ready is
         Finished_Here : Natural := 0;
         Started       : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      begin
         if Collect_Diagnostics then
            Started := Ada.Real_Time.Clock;
         end if;
         Operations.Wait_Some (Set, Completed);
         if Collect_Diagnostics then
            Add_Elapsed
              (Diagnostics.Completion_Drive_Nanoseconds, Started, Ada.Real_Time.Clock);
         end if;
         Require (Completed.Count > 0, "singleton pipeline returned no completion");
         for Slot in Work'Range loop
            if Active (Slot) and then Operations.Is_Terminal (Work (Slot).all) then
               Finish_Slot (Slot);
               Finished_Here := Finished_Here + 1;
            end if;
         end loop;
         Require
           (Finished_Here = Completed.Count,
            "singleton pipeline completion batch mismatch");
      end Drain_Ready;

      procedure Release_All is
      begin
         for Slot in Work'Range loop
            if Work (Slot) /= null then
               Free (Work (Slot));
            end if;
         end loop;
      end Release_All;
   begin
      for Slot in Work'Range loop
         Work (Slot) := new DB.Commit_Operation (Set'Access, Item'Access, null);
      end loop;
      while Finished < Count loop
         while Submitted < Count and then Active_Count < Pipeline_Depth loop
            declare
               Slot        : Positive := Work'First;
               Index       : constant Positive := First_Index + Submitted;
               Transaction : DB.Transaction;
               Result      : DB.Outcome_Code;
               Started     : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
            begin
               while Active (Slot) loop
                  Slot := Slot + 1;
               end loop;
               if Collect_Diagnostics then
                  Started := Ada.Real_Time.Clock;
               end if;
               Prepare_Transaction
                 (Item, Family, Index, Mutations, Key_Length, Value_Length, Transaction);
               if Collect_Diagnostics then
                  Add_Elapsed
                    (Diagnostics.Preparation_Nanoseconds, Started, Ada.Real_Time.Clock);
                  Started := Ada.Real_Time.Clock;
               end if;
               DB.Commit (Transaction, Deadline, Work (Slot).all);
               if Collect_Diagnostics then
                  Add_Elapsed
                    (Diagnostics.Admission_Nanoseconds, Started, Ada.Real_Time.Clock);
               end if;
               Index_For (Slot) := Index;
               Active (Slot) := True;
               Active_Count := Active_Count + 1;
               Submitted := Submitted + 1;
            exception
               when others =>
                  DB.Rollback (Transaction, Result);
                  raise;
            end;
         end loop;
         Drain_Ready;
         if Wave_Scheduling then
            while Active_Count > 0 loop
               Drain_Ready;
            end loop;
         end if;
      end loop;
      for Index in Sequences'Range loop
         Require
           (Sequences (Index) > 0
              and then
                (Index = Sequences'First
                 or else Sequences (Index) = Sequences (Index - 1) + 1),
            "pipelined singleton receipt sequence mismatch");
      end loop;
      if Adaptive_Cohort then
         declare
            First : Positive := Sequences'First;
         begin
            while First <= Sequences'Last loop
               declare
                  Last  : Positive := First;
                  Width : Positive;
               begin
                  while Last < Sequences'Last
                    and then Transitions (Last + 1) = Transitions (First)
                  loop
                     Last := Last + 1;
                  end loop;
                  Width := Last - First + 1;
                  Require
                    (Width <= Cohort_Width
                       and then Batch_IDs (First)
                                  = Numbered_ID (Interfaces.Unsigned_64 (1_000 + First)),
                     "adaptive cohort leader identity or member bound changed");
                  for Index in First .. Last loop
                     Require
                       (Batch_IDs (Index) = Batch_IDs (First),
                        "adaptive cohort receipts did not share one batch identity");
                  end loop;
                  if Collect_Diagnostics then
                     Diagnostics.Cohort_Total := Diagnostics.Cohort_Total + 1;
                     Diagnostics.Member_Total :=
                       Diagnostics.Member_Total + Interfaces.Unsigned_64 (Width);
                     Diagnostics.Width_Counts (Width) := Diagnostics.Width_Counts (Width) + 1;
                  end if;
                  if First > Sequences'First then
                     Require
                       (Transitions (First) = Transitions (First - 1) + 1,
                        "adaptive cohort HEAD transition sequence changed");
                  end if;
                  exit when Last = Sequences'Last;
                  First := Last + 1;
               end;
            end loop;
         end;
      elsif Cohort_Width > 0 then
         for First in Sequences'First .. Sequences'Last loop
            if (First - Sequences'First) mod Cohort_Width = 0 then
               for Offset in Natural range 0 .. Cohort_Width - 1 loop
                  Require
                    (First + Offset <= Sequences'Last
                       and then Transitions (First + Offset) = Transitions (First),
                     "independent cohort receipts did not share one exact HEAD transition");
               end loop;
               if First > Sequences'First then
                  Require
                    (Transitions (First) = Transitions (First - 1) + 1,
                     "independent cohort HEAD transition sequence changed");
               end if;
            end if;
         end loop;
      end if;
      Release_All;
   exception
      when others =>
         if Cohort_Width > 0 then
            Benchmark_Controls.Abort_Independent_Coalescing (Item, Abort_Result);
            Require (Abort_Result = DB.Success, "independent cohort abort failed during cleanup");
         end if;
         for Slot in Work'Range loop
            if Work (Slot) /= null and then Active (Slot)
              and then Operations.Is_Active (Work (Slot).all)
            then
               Operations.Cancel (Work (Slot).all);
            end if;
         end loop;
         if Active_Count > 0 then
            Operations.Wait_All (Set);
         end if;
         for Slot in Work'Range loop
            if Work (Slot) /= null and then Active (Slot)
              and then Operations.Is_Terminal (Work (Slot).all)
            then
               declare
                  Receipt : DB.Commit_Receipt;
                  Result  : DB.Outcome_Code;
               begin
                  DB.Finish (Work (Slot).all, Receipt, Result);
                  Operations.Release (Work (Slot).all);
               end;
            end if;
         end loop;
         Release_All;
         raise;
   end Put_Singletons_Pipelined;

   procedure Put_Explicit_Groups
     (Item         : aliased in out DB.Database;
      Family       : DB.Column_Family;
      First_Index  : Positive;
      Count        : Positive;
      Group_Size   : Positive;
      Depth        : Positive;
      Mutations    : Positive;
      Key_Length   : Positive;
      Value_Length : Positive)
   is
      type Operation_Access is access DB.Commit_Group_Operation;
      procedure Free is new Ada.Unchecked_Deallocation
        (Object => DB.Commit_Group_Operation, Name => Operation_Access);
      type Operation_Array is array (Positive range <>) of Operation_Access;
      type Boolean_Array is array (Positive range <>) of Boolean;
      type Positive_Array is array (Positive range <>) of Positive;
      type Sequence_Array is array (Positive range <>) of DB.Sequence_Number;

      Set          : aliased Operations.Completion_Set (Depth);
      Work         : Operation_Array (1 .. Depth) := [others => null];
      Active       : Boolean_Array (Work'Range) := [others => False];
      First_For    : Positive_Array (Work'Range) := [others => First_Index];
      Sequences    : Sequence_Array (First_Index .. First_Index + Count - 1) := [others => 0];
      Completed    : Operations.Completion_Batch (Set.Capacity);
      Submitted    : Natural := 0;
      Finished     : Natural := 0;
      Active_Count : Natural := 0;

      procedure Finish_Slot (Slot : Positive) is
         Receipts : DB.Commit_Receipt_Array (1 .. Group_Size);
         Result   : DB.Outcome_Code;
         First    : constant Positive := First_For (Slot);
         Batch_ID : constant DB.Identifier :=
           Numbered_ID (10_000_000 + Interfaces.Unsigned_64 (First));
      begin
         DB.Finish (Work (Slot).all, Receipts, Result);
         Operations.Release (Work (Slot).all);
         Active (Slot) := False;
         Active_Count := Active_Count - 1;
         Finished := Finished + Group_Size;
         Expect (Result, "explicit group durable publication failed");
         for Member in Receipts'Range loop
            declare
               Index       : constant Positive := First + Member - 1;
               Expected_ID : constant DB.Transaction_Identifier :=
                 DB.Transaction_Identifier
                   (Numbered_ID (Interfaces.Unsigned_64 (1_000 + Index)));
            begin
               Require
                 (DB.Receipt_Outcome (Receipts (Member)) = DB.Success
                    and then DB.Receipt_Transaction_ID (Receipts (Member)) = Expected_ID
                    and then DB.Receipt_Batch_ID (Receipts (Member)) = Batch_ID,
                  "explicit group member receipt identity mismatch");
               Require
                 (DB.Receipt_Sequence (Receipts (Member)) > 0,
                  "explicit group member receipt sequence is absent");
               Sequences (Index) := DB.Receipt_Sequence (Receipts (Member));
            end;
         end loop;
      end Finish_Slot;

      procedure Drain_Ready is
         Finished_Here : Natural := 0;
      begin
         Operations.Wait_Some (Set, Completed);
         Require (Completed.Count > 0, "explicit group pipeline returned no completion");
         for Slot in Work'Range loop
            if Active (Slot) and then Operations.Is_Terminal (Work (Slot).all) then
               Finish_Slot (Slot);
               Finished_Here := Finished_Here + 1;
            end if;
         end loop;
         Require
           (Finished_Here = Completed.Count,
            "explicit group pipeline completion batch mismatch");
      end Drain_Ready;

      procedure Release_All is
      begin
         for Slot in Work'Range loop
            if Work (Slot) /= null then
               Free (Work (Slot));
            end if;
         end loop;
      end Release_All;
   begin
      Require
        (Count mod Group_Size = 0,
         "explicit group transaction count must divide by the group size");
      for Slot in Work'Range loop
         Work (Slot) := new DB.Commit_Group_Operation (Set'Access, Item'Access, null, Group_Size);
      end loop;
      while Finished < Count loop
         while Submitted < Count and then Active_Count < Depth loop
            declare
               Slot         : Positive := Work'First;
               First        : constant Positive := First_Index + Submitted;
               Transactions : DB.Transaction_Array (1 .. Group_Size);
               Result       : DB.Outcome_Code;
            begin
               while Active (Slot) loop
                  Slot := Slot + 1;
               end loop;
               for Member in Transactions'Range loop
                  Prepare_Transaction
                    (Item,
                     Family,
                     First + Member - 1,
                     Mutations,
                     Key_Length,
                     Value_Length,
                     Transactions (Member));
               end loop;
               DB.Commit_Group
                 (Numbered_ID (10_000_000 + Interfaces.Unsigned_64 (First)),
                  Transactions,
                  Timeout,
                  Work (Slot).all);
               First_For (Slot) := First;
               Active (Slot) := True;
               Active_Count := Active_Count + 1;
               Submitted := Submitted + Group_Size;
            exception
               when others =>
                  for Transaction of Transactions loop
                     DB.Rollback (Transaction, Result);
                  end loop;
                  raise;
            end;
         end loop;
         Drain_Ready;
      end loop;
      for Index in Sequences'Range loop
         Require
           (Sequences (Index) > 0
              and then
                (Index = Sequences'First
                 or else Sequences (Index) = Sequences (Index - 1) + 1),
            "explicit group member receipt sequence mismatch");
      end loop;
      Release_All;
   exception
      when others =>
         for Slot in Work'Range loop
            if Work (Slot) /= null and then Active (Slot)
              and then Operations.Is_Active (Work (Slot).all)
            then
               Operations.Cancel (Work (Slot).all);
            end if;
         end loop;
         if Active_Count > 0 then
            Operations.Wait_All (Set);
         end if;
         for Slot in Work'Range loop
            if Work (Slot) /= null and then Active (Slot)
              and then Operations.Is_Terminal (Work (Slot).all)
            then
               declare
                  Receipts : DB.Commit_Receipt_Array (1 .. Group_Size);
                  Result   : DB.Outcome_Code;
               begin
                  DB.Finish (Work (Slot).all, Receipts, Result);
                  Operations.Release (Work (Slot).all);
               end;
            end if;
         end loop;
         Release_All;
         raise;
   end Put_Explicit_Groups;

   function Verify_All
     (Item         : in out DB.Database;
      Total        : Positive;
      Key_Length   : Positive;
      Value_Length : Positive) return GNAT.SHA256.Message_Digest
   is
      Reader : DB.Transaction;
      Family : DB.Column_Family;
      Data   : Flyology.Bytes.Unbounded_Bytes;
      Result : DB.Outcome_Code;
      Digest : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
   begin
      DB.Begin_Transaction
        (Item,
         DB.Transaction_Identifier (Numbered_ID (9_000_000)),
         DB.Snapshot,
         Reader,
         Result);
      Expect (Result, "verification begin failed");
      DB.Open_Column_Family (Item, 1, Family, Result);
      Expect (Result, "verification family open failed");
      for Index in 1 .. Total loop
         declare
            Key : constant DB.Byte_Array := Key_For (Index, Key_Length);
         begin
            DB.Get (Item, Reader, Family, Key, Data, Result);
            GNAT.SHA256.Update (Digest, Byte_String (Key));
         end;
         Expect (Result, "verification get failed");
         Require
           (Same (Data, Value_For (Index, Value_Length)),
            "verification value mismatch");
         GNAT.SHA256.Update (Digest, Flyology.Bytes.To_Array (Data));
      end loop;
      DB.Rollback (Reader, Result);
      Expect (Result, "verification rollback failed");
      return GNAT.SHA256.Digest (Digest);
   exception
      when others =>
         DB.Rollback (Reader, Result);
         raise;
   end Verify_All;

   procedure Run
     (Storage             : not null access DB.Storage_Context;
      Warmup              : Natural;
      Measured            : Positive;
      Key_Length          : Positive;
      Value_Length        : Positive;
      Mutations           : Positive;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest)
   is
      Group_Size         : constant Positive := Requested_Group_Size;
      Explicit_Group     : constant Boolean := Requested_Explicit_Group;
      Pipeline_Depth     : constant Positive := Requested_Pipeline_Depth;
      Wave_Scheduling    : constant Boolean := Requested_Wave_Scheduling;
      Independent_Cohort_Width : constant Natural := Requested_Independent_Cohort_Width;
      Aggregate_Cohort_Width   : constant Natural := Requested_Aggregate_Cohort_Width;
      Aggregate_First_Ordinal  : constant Interfaces.Unsigned_64 :=
        Requested_Aggregate_First_Batch_Ordinal;
      Adaptive_Maximum_Members : constant Natural := Requested_Adaptive_Maximum_Members;
      Adaptive_Maximum_Encoded_Bytes : constant Interfaces.Unsigned_64 :=
        Requested_Adaptive_Maximum_Encoded_Bytes;
      Adaptive_Maximum_Wait_Microseconds : constant Interfaces.Unsigned_64 :=
        Requested_Adaptive_Maximum_Wait_Microseconds;
      Adaptive_Admission_Depth : constant Natural := Requested_Adaptive_Admission_Depth;
      Adaptive_Cohort    : constant Boolean := Adaptive_Maximum_Members > 0;
      Collect_Diagnostics : constant Boolean := Effective_Commit_Diagnostics;
      Cohort_Width       : constant Natural :=
        Independent_Cohort_Width + Aggregate_Cohort_Width + Adaptive_Maximum_Members;
      Commit_Deadline    : constant Duration :=
        (if Cohort_Width > 0 then Duration'Last else Timeout);
      Total_Transactions : constant Positive := Warmup + Measured;
      Total_Keys         : constant Positive :=
        Total_Transactions * Mutations;
      Batch_History      : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Total_Transactions + 1);
      Live_Bytes         : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Total_Keys)
        * Interfaces.Unsigned_64 (Key_Length + Value_Length + 256);
      Batch_Bytes        : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Mutations)
        * Interfaces.Unsigned_64 (Key_Length + Value_Length + 256);
      Maximum_Batch_Bytes : constant Interfaces.Unsigned_64 :=
        Batch_Bytes * Interfaces.Unsigned_64 (Maximum_Pipeline_Depth);
      Limits             : constant DB.Database_Limits :=
        (Maximum_Column_Families             => 1,
         Maximum_Manifest_History            => 2,
         Maximum_Batch_History               => Batch_History,
         Maximum_Transactions_Per_Batch      => Maximum_Pipeline_Depth,
         Maximum_Mutations_Per_Transaction   =>
           Interfaces.Unsigned_32 (Mutations),
         Maximum_Mutations_Per_Batch         =>
           Interfaces.Unsigned_32 (Mutations * Maximum_Pipeline_Depth),
         Maximum_Live_Entries                =>
           Interfaces.Unsigned_32 (Total_Keys),
         Maximum_Transaction_Payload_Bytes   => Batch_Bytes,
         Maximum_Batch_Payload_Bytes         => Maximum_Batch_Bytes,
         Maximum_Live_State_Bytes            => Live_Bytes,
         Maximum_Total_L0_Runs               => 1,
         Maximum_Checkpoint_Identities       =>
           Batch_History * Interfaces.Unsigned_32 (Maximum_Pipeline_Depth + 1),
         Maximum_Point_Reads_Per_Transaction => 1,
         Maximum_Scan_Ranges_Per_Transaction => 1);
      Families           : constant DB.Column_Family_Configuration_Array :=
        [DB.Configure_Column_Family
           (ID                   => 1,
            Name                 =>
              [DB.Byte (Character'Pos ('d')),
               DB.Byte (Character'Pos ('a')),
               DB.Byte (Character'Pos ('t')),
               DB.Byte (Character'Pos ('a'))],
            Max_Key_Bytes        => Interfaces.Unsigned_64 (Key_Length),
            Max_Value_Bytes      => Interfaces.Unsigned_64 (Value_Length),
            Memtable_Max_Bytes   => Live_Bytes,
            Memtable_Max_Entries => Interfaces.Unsigned_32 (Total_Keys),
            Maximum_L0_Runs      => 1)];
      Ignored_Item        : aliased DB.Database;
      Family              : DB.Column_Family;
      Create_Info         : DB.Create_Receipt;
      Result              : DB.Outcome_Code;
      Started             : Ada.Real_Time.Time;
      Finished            : Ada.Real_Time.Time;
      Warmup_Batch_Before, Warmup_Manifest_Before, Warmup_Head_Before : Natural := 0;
      Warmup_Batch_After, Warmup_Manifest_After, Warmup_Head_After    : Natural := 0;
      Measured_Batch_After, Measured_Manifest_After, Measured_Head_After : Natural := 0;
      Runtime_Diagnostics : Benchmark_Controls.Adaptive_Cohort_Diagnostics;
      Caller_Snapshot     : Caller_Diagnostics;

      procedure Require_Cohort_Geometry
        (Batch_Before, Manifest_Before, Head_Before : Natural;
         Batch_After, Manifest_After, Head_After    : Natural;
         Transactions                               : Natural;
         Context                                    : String) is
         Minimum_Publications : constant Natural :=
           (if Adaptive_Cohort
            then (Transactions + Adaptive_Maximum_Members - 1) / Adaptive_Maximum_Members
            else Transactions / Cohort_Width);
      begin
         if Adaptive_Cohort then
            Require
              (Batch_After >= Batch_Before + Minimum_Publications
                 and then Batch_After <= Batch_Before + Transactions
                 and then Manifest_After = Manifest_Before
                 and then Head_After >= Head_Before
                 and then Head_After - Head_Before = Batch_After - Batch_Before,
               Context & " adaptive cohort publication geometry changed");
         else
            Require
              (Batch_After
                 = Batch_Before
                   + (if Aggregate_Cohort_Width > 0 then Transactions / Cohort_Width else Transactions)
                 and then Manifest_After = Manifest_Before
                 and then Head_After = Head_Before + Transactions / Cohort_Width,
               Context & " cohort publication geometry changed");
         end if;
      end Require_Cohort_Geometry;
   begin
      Latest_Diagnostics_Available := False;
      Latest_Configuration_Available := False;
      Latest_Runtime_Diagnostics := (others => <>);
      Latest_Caller_Diagnostics := (others => <>);
      Latest_Batch_Publications := 0;
      Latest_Manifest_Publications := 0;
      Latest_Head_Publications := 0;
      Require
        (Total_Transactions <= Maximum_Operations,
         "operation count exceeds benchmark fixture limit");
      Require
        (Group_Size <= Maximum_Pipeline_Depth,
         "benchmark group size exceeds the eight-slot fixture capacity");
      Require
        (Pipeline_Depth <= Maximum_Pipeline_Depth,
         "benchmark pipeline depth exceeds the eight-slot fixture capacity");
      Require
        ((if Independent_Cohort_Width > 0 then 1 else 0)
           + (if Aggregate_Cohort_Width > 0 then 1 else 0)
           + (if Adaptive_Cohort then 1 else 0)
           <= 1,
         "independent, exact aggregate, and adaptive cohort profiles are mutually exclusive");
      Require
        (not Collect_Diagnostics or else Adaptive_Cohort,
         "commit diagnostics require the adaptive cohort profile");
      Require
        (Cohort_Width <= Maximum_Pipeline_Depth,
         "cohort width exceeds the eight-slot fixture capacity");
      Require
        (Independent_Cohort_Width = 0
           or else
             (not Explicit_Group
              and then Pipeline_Depth = Independent_Cohort_Width
              and then Warmup mod Independent_Cohort_Width = 0
              and then Measured mod Independent_Cohort_Width = 0),
         "independent cohort width requires equal pipeline depth and divisible transaction counts");
      Require
        (Aggregate_Cohort_Width = 0
           or else
             (not Explicit_Group
              and then Aggregate_First_Ordinal > 0
              and then Pipeline_Depth >= Aggregate_Cohort_Width
              and then Pipeline_Depth mod Aggregate_Cohort_Width = 0
              and then Warmup mod Aggregate_Cohort_Width = 0
              and then Measured mod Aggregate_Cohort_Width = 0),
         "aggregate cohort width requires an identity range and divisible pipeline geometry");
      Require
        ((Aggregate_Cohort_Width = 0 and then Aggregate_First_Ordinal = 0)
           or else (Aggregate_Cohort_Width > 0 and then Aggregate_First_Ordinal > 0),
         "aggregate identity range requires the aggregate profile");
      Require
        ((not Adaptive_Cohort
            and then Adaptive_Maximum_Encoded_Bytes = 0
            and then Adaptive_Maximum_Wait_Microseconds = 0
            and then Adaptive_Admission_Depth = 0)
           or else
             (Adaptive_Cohort
              and then not Explicit_Group
              and then Adaptive_Maximum_Encoded_Bytes > 0
              and then Adaptive_Maximum_Wait_Microseconds > 0
              and then Adaptive_Admission_Depth >= Adaptive_Maximum_Members
              and then Adaptive_Admission_Depth <= Maximum_Pipeline_Depth
              and then Pipeline_Depth <= Adaptive_Admission_Depth),
         "adaptive cohort scheduling requires a complete caller-selected profile");
      Require
        ((Explicit_Group
            and then Group_Size >= 2
            and then Group_Size * Pipeline_Depth <= Maximum_Pipeline_Depth)
           or else (not Explicit_Group and then Group_Size = 1),
         "explicit group geometry must fit eight commit slots; singletons require group size one");
      Require
        (not Explicit_Group
           or else (Warmup mod Group_Size = 0 and then Measured mod Group_Size = 0),
         "explicit-group warmup and measured counts must divide by the group size");
      Require
        (Key_Length in 8 .. Maximum_Key_Length,
         "key length is outside the benchmark fixture limit");
      Require
        (Value_Length <= Maximum_Value_Length,
         "value length exceeds the benchmark fixture limit");
      Require
        (Mutations <= Maximum_Mutations_Per_Batch,
         "mutation count exceeds the benchmark fixture limit");
      DB.Create
        (Ignored_Item,
         Storage,
         DB.Database_Identifier (Numbered_ID (1)),
         Numbered_ID (2),
         Numbered_ID (3),
         Limits,
         Families,
         Timeout,
         Receipt => Create_Info,
         Result  => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve_Create
           (Ignored_Item, Storage, Create_Info, Timeout, Result => Result);
      end if;
      Expect (Result, "create failed");
      if Independent_Cohort_Width > 0 then
         Benchmark_Controls.Enable_Independent_Coalescing
           (Ignored_Item,
            Storage,
            DB.Database_Identifier (Numbered_ID (1)),
            Numbered_ID (2),
            Positive (Independent_Cohort_Width),
            Timeout,
            Result);
         Expect (Result, "independent-coalescing profile setup failed");
      elsif Aggregate_Cohort_Width > 0 then
         Benchmark_Controls.Enable_Aggregate_Coalescing
           (Ignored_Item,
            Storage,
            DB.Database_Identifier (Numbered_ID (1)),
            Numbered_ID (2),
            Positive (Aggregate_Cohort_Width),
            Aggregate_First_Ordinal,
            Timeout,
            Result);
         Expect (Result, "aggregate-coalescing profile setup failed");
      elsif Adaptive_Cohort then
         Benchmark_Controls.Enable_Adaptive_Aggregate_Coalescing
           (Ignored_Item,
            Storage,
            DB.Database_Identifier (Numbered_ID (1)),
            Numbered_ID (2),
            Positive (Adaptive_Maximum_Members),
            Adaptive_Maximum_Encoded_Bytes,
            Adaptive_Wait_Duration (Adaptive_Maximum_Wait_Microseconds),
            Positive (Adaptive_Admission_Depth),
            Timeout,
            Result);
         Expect (Result, "adaptive aggregate-coalescing profile setup failed");
      end if;
      Latest_Configuration_Available := True;
      DB.Open_Column_Family (Ignored_Item, 1, Family, Result);
      Expect (Result, "family open failed");

      Benchmark_Controls.Publication_Counts
        (Storage.all, Warmup_Batch_Before, Warmup_Manifest_Before, Warmup_Head_Before);

      if Warmup > 0 then
         if Explicit_Group then
            Put_Explicit_Groups
              (Ignored_Item,
               Family,
               1,
               Positive (Warmup),
               Group_Size,
               Pipeline_Depth,
               Mutations,
               Key_Length,
               Value_Length);
         elsif Pipeline_Depth = 1 and then Cohort_Width = 0 then
            for Index in 1 .. Warmup loop
               Put_Transaction
                 (Ignored_Item,
                  Family,
                  Index,
                  Mutations,
                  Key_Length,
                  Value_Length,
                  Commit_Deadline);
            end loop;
         else
            Put_Singletons_Pipelined
              (Ignored_Item,
               Family,
               1,
               Positive (Warmup),
               Pipeline_Depth,
               Mutations,
               Key_Length,
               Value_Length,
               Commit_Deadline,
               Cohort_Width,
               Aggregate_First_Ordinal,
               Adaptive_Cohort,
               Wave_Scheduling,
               False,
               Caller_Snapshot);
         end if;
      end if;
      Benchmark_Controls.Publication_Counts
        (Storage.all, Warmup_Batch_After, Warmup_Manifest_After, Warmup_Head_After);
      if Cohort_Width > 0 then
         Require_Cohort_Geometry
           (Warmup_Batch_Before,
            Warmup_Manifest_Before,
            Warmup_Head_Before,
            Warmup_Batch_After,
            Warmup_Manifest_After,
            Warmup_Head_After,
            Warmup,
            "warmup");
      end if;
      if Collect_Diagnostics then
         Benchmark_Controls.Begin_Adaptive_Cohort_Diagnostics (Ignored_Item, Result);
         Expect (Result, "adaptive cohort diagnostics begin failed");
      end if;
      Started := Ada.Real_Time.Clock;
      if Explicit_Group then
         Put_Explicit_Groups
           (Ignored_Item,
            Family,
            Warmup + 1,
            Measured,
            Group_Size,
            Pipeline_Depth,
            Mutations,
            Key_Length,
            Value_Length);
      elsif Pipeline_Depth = 1 and then Cohort_Width = 0 then
         for Index in Warmup + 1 .. Total_Transactions loop
            Put_Transaction
              (Ignored_Item,
               Family,
               Index,
               Mutations,
               Key_Length,
               Value_Length,
               Commit_Deadline);
         end loop;
      else
         Put_Singletons_Pipelined
           (Ignored_Item,
            Family,
            Warmup + 1,
            Measured,
            Pipeline_Depth,
            Mutations,
            Key_Length,
            Value_Length,
            Commit_Deadline,
            Cohort_Width,
            Aggregate_First_Ordinal,
            Adaptive_Cohort,
            Wave_Scheduling,
            Collect_Diagnostics,
            Caller_Snapshot);
      end if;
      Finished := Ada.Real_Time.Clock;
      if Collect_Diagnostics then
         Benchmark_Controls.Finish_Adaptive_Cohort_Diagnostics
           (Ignored_Item, Runtime_Diagnostics, Result);
         Expect (Result, "adaptive cohort diagnostics finish failed");
      end if;
      Benchmark_Controls.Publication_Counts
        (Storage.all, Measured_Batch_After, Measured_Manifest_After, Measured_Head_After);
      Latest_Batch_Publications := Measured_Batch_After - Warmup_Batch_After;
      Latest_Manifest_Publications := Measured_Manifest_After - Warmup_Manifest_After;
      Latest_Head_Publications := Measured_Head_After - Warmup_Head_After;
      if Cohort_Width > 0 then
         Require_Cohort_Geometry
           (Warmup_Batch_After,
            Warmup_Manifest_After,
            Warmup_Head_After,
            Measured_Batch_After,
            Measured_Manifest_After,
            Measured_Head_After,
            Measured,
            "measured");
      end if;
      if Collect_Diagnostics then
         declare
            Batch_Publications : constant Natural := Measured_Batch_After - Warmup_Batch_After;
            Manifest_Publications : constant Natural :=
              Measured_Manifest_After - Warmup_Manifest_After;
            Head_Publications : constant Natural := Measured_Head_After - Warmup_Head_After;
            Primary_Nanoseconds : constant Interfaces.Unsigned_64 :=
              Nanoseconds_Between (Started, Finished);
            Worker_Component_Total : Interfaces.Unsigned_64 := 0;
            Caller_Component_Total : Interfaces.Unsigned_64 := 0;
            Worker_Difference      : Interfaces.Unsigned_64;
            Worker_Rounding_Tolerance : constant Interfaces.Unsigned_64 :=
              16 * Runtime_Diagnostics.Cohort_Total;
            Caller_Rounding_Tolerance : constant Interfaces.Unsigned_64 :=
              2 * Interfaces.Unsigned_64 (3 * Measured + 1);

            procedure Add_Component
              (Target : in out Interfaces.Unsigned_64; Value : Interfaces.Unsigned_64) is
            begin
               if Value > Interfaces.Unsigned_64'Last - Target then
                  Target := Interfaces.Unsigned_64'Last;
               else
                  Target := Target + Value;
               end if;
            end Add_Component;

            function Within_Rounding
              (Value, Bound, Tolerance : Interfaces.Unsigned_64) return Boolean is
              (Value <= Bound or else Value - Bound <= Tolerance);
         begin
            Add_Component
              (Worker_Component_Total, Runtime_Diagnostics.Phases.Prepublication_Nanoseconds);
            Add_Component (Worker_Component_Total, Runtime_Diagnostics.Phases.Build_Nanoseconds);
            Add_Component (Worker_Component_Total, Runtime_Diagnostics.Phases.Validation_Nanoseconds);
            Add_Component (Worker_Component_Total, Runtime_Diagnostics.Phases.Batch_Put_Nanoseconds);
            Add_Component (Worker_Component_Total, Runtime_Diagnostics.Phases.Head_Encode_Nanoseconds);
            Add_Component (Worker_Component_Total, Runtime_Diagnostics.Phases.Head_Put_Nanoseconds);
            Add_Component (Worker_Component_Total, Runtime_Diagnostics.Phases.Installation_Nanoseconds);
            Add_Component (Caller_Component_Total, Caller_Snapshot.Preparation_Nanoseconds);
            Add_Component (Caller_Component_Total, Caller_Snapshot.Admission_Nanoseconds);
            Add_Component (Caller_Component_Total, Caller_Snapshot.Completion_Drive_Nanoseconds);
            Worker_Difference :=
              (if Worker_Component_Total >= Runtime_Diagnostics.Phases.Precompletion_Nanoseconds
               then Worker_Component_Total - Runtime_Diagnostics.Phases.Precompletion_Nanoseconds
               else Runtime_Diagnostics.Phases.Precompletion_Nanoseconds - Worker_Component_Total);
            --  Each cohort converts seven adjacent phases and one inclusive
            --  span independently. Caller conversion count is bounded by two
            --  spans per transaction, one Wait_Some per transaction, and the
            --  primary window. The derived allowances conservatively absorb
            --  fixed-point rounding without masking a missing phase.
            Require
              (Runtime_Diagnostics.Cohort_Total = Interfaces.Unsigned_64 (Batch_Publications)
                 and then Runtime_Diagnostics.Member_Total = Interfaces.Unsigned_64 (Measured)
                 and then Runtime_Diagnostics.Phase_Cohort_Total = Runtime_Diagnostics.Cohort_Total
                 and then Runtime_Diagnostics.Encoded_Bytes > 0
                 and then Caller_Snapshot.Cohort_Total = Runtime_Diagnostics.Cohort_Total
                 and then Caller_Snapshot.Member_Total = Runtime_Diagnostics.Member_Total
                 and then Manifest_Publications = 0
                 and then Head_Publications = Batch_Publications,
               "adaptive cohort diagnostic geometry disagrees with publication evidence");
            Require
              (Primary_Nanoseconds /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Cohort_Total /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Member_Total /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Encoded_Bytes /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Member_Boundary_Total /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Byte_Boundary_Total /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Hard_Boundary_Total /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Wait_Boundary_Total /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Close_Boundary_Total /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Phase_Cohort_Total /= Interfaces.Unsigned_64'Last
                 and then Runtime_Diagnostics.Phases.Precompletion_Nanoseconds
                            /= Interfaces.Unsigned_64'Last
                 and then Worker_Component_Total /= Interfaces.Unsigned_64'Last
                 and then Caller_Component_Total /= Interfaces.Unsigned_64'Last
                 and then Worker_Difference <= Worker_Rounding_Tolerance
                 and then
                   Within_Rounding
                     (Runtime_Diagnostics.Phases.Precompletion_Nanoseconds,
                      Primary_Nanoseconds,
                      Worker_Rounding_Tolerance)
                 and then
                   Within_Rounding
                     (Caller_Component_Total, Primary_Nanoseconds, Caller_Rounding_Tolerance),
               "adaptive cohort diagnostic timing is saturated or internally inconsistent");
            for Width in Benchmark_Controls.Diagnostic_Cohort_Width loop
               Require
                 (Caller_Snapshot.Width_Counts (Width) = Runtime_Diagnostics.Width_Counts (Width)
                    and then Caller_Snapshot.Width_Counts (Width) /= Interfaces.Unsigned_64'Last,
                  "adaptive cohort receipt width disagrees with coordinator selection");
            end loop;
            Latest_Runtime_Diagnostics := Runtime_Diagnostics;
            Latest_Caller_Diagnostics := Caller_Snapshot;
            Latest_Diagnostics_Available := True;
         end;
      end if;

      DB.Close (Ignored_Item, Result);
      Expect (Result, "close failed");
      DB.Open
        (Ignored_Item,
         Storage,
         DB.Database_Identifier (Numbered_ID (1)),
         Timeout,
         Result => Result);
      Expect (Result, "reopen failed");
      State_SHA256 :=
        Verify_All (Ignored_Item, Total_Keys, Key_Length, Value_Length);
      DB.Close (Ignored_Item, Result);
      Expect (Result, "verification close failed");

      Elapsed_Nanoseconds :=
        Long_Float
          (Ada.Real_Time.To_Duration (Finished - Started)
           * 1_000_000_000.0);
      Require
        (Elapsed_Nanoseconds > 0.0,
         "timer resolution was insufficient");
      Verified_Keys := Total_Keys;
   end Run;

   procedure Run_Local
     (Root                : String;
      Warmup              : Natural;
      Measured            : Positive;
      Key_Length          : Positive;
      Value_Length        : Positive;
      Mutations           : Positive;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest)
   is
      Store        : aliased Files.Store :=
        Files.Open
          (Root,
           Maximum_Object_Size => 256 * 1_024 * 1_024,
           Commit              => Files.Power_Loss_Durable);
      Storage      : aliased DB.Storage_Context;
      Store_Result : OS.Status;
   begin
      Store.Create_Bucket
        (Local_Bucket,
         Token    => null,
         Deadline => Ada.Real_Time.Clock
           + Ada.Real_Time.To_Time_Span (Timeout),
         Result   => Store_Result);
      Require (Store_Result = OS.Success, "files bucket creation failed");
      Binding.Bind (Storage, Store'Access, Local_Bucket, Local_Prefix);
      Run
        (Storage'Access,
         Warmup,
         Measured,
         Key_Length,
         Value_Length,
         Mutations,
         Elapsed_Nanoseconds,
         Verified_Keys,
         State_SHA256);
   end Run_Local;

   procedure Run_S3
     (Endpoint            : String;
      Bucket              : String;
      Prefix              : String;
      Warmup              : Natural;
      Measured            : Positive;
      Key_Length          : Positive;
      Value_Length        : Positive;
      Mutations           : Positive;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest)
   is
      Origin   : constant HTTP.Origin := HTTP.Parse_Origin (Endpoint);
      Client   : aliased HTTP_Client.Client (Capacity => 4);
      Identity : aliased Low_Level.Credentials :=
        Low_Level.Make_Credentials
          (Required_Environment ("AWS_ACCESS_KEY_ID"),
           Required_Environment ("AWS_SECRET_ACCESS_KEY"),
           Optional_Environment ("AWS_SESSION_TOKEN"));
      Storage  : aliased DB.Storage_Context;
   begin
      HTTP_Client.Configure (Client, Origin);
      Binding.Bind_Client
        (Storage,
         Client'Access,
         Origin,
         Identity'Access,
         Bucket,
         Prefix,
         "us-east-1",
         Low_Level.Path_Style,
         "application/octet-stream",
         "",
         "",
         False);
      Run
        (Storage'Access,
         Warmup,
         Measured,
         Key_Length,
         Value_Length,
         Mutations,
         Elapsed_Nanoseconds,
         Verified_Keys,
         State_SHA256);
   end Run_S3;

end Flyology_DB_Benchmark_Flyology;
