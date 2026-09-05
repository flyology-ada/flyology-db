with Ada.Environment_Variables;
with Ada.Real_Time;
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

   function Requested_Independent_Cohort_Width return Natural is
      Raw : constant String := Optional_Environment ("FLYOLOGY_DB_BENCH_INDEPENDENT_COHORT_WIDTH");
   begin
      return (if Raw'Length = 0 then 0 else Natural'Value (Raw));
   exception
      when Constraint_Error =>
         raise Program_Error with "FLYOLOGY_DB_BENCH_INDEPENDENT_COHORT_WIDTH must be a natural number";
   end Requested_Independent_Cohort_Width;

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
      Cohort_Width   : Natural)
   is
      type Operation_Access is access DB.Commit_Operation;
      procedure Free is new Ada.Unchecked_Deallocation
        (Object => DB.Commit_Operation, Name => Operation_Access);
      type Operation_Array is array (Positive range <>) of Operation_Access;
      type Boolean_Array is array (Positive range <>) of Boolean;
      type Positive_Array is array (Positive range <>) of Positive;
      type Sequence_Array is array (Positive range <>) of DB.Sequence_Number;
      type Transition_Array is array (Positive range <>) of Interfaces.Unsigned_64;

      Set            : aliased Operations.Completion_Set (Pipeline_Depth);
      Work           : Operation_Array (1 .. Pipeline_Depth) := [others => null];
      Active         : Boolean_Array (Work'Range) := [others => False];
      Index_For      : Positive_Array (Work'Range) := [others => First_Index];
      Sequences      : Sequence_Array (First_Index .. First_Index + Count - 1) := [others => 0];
      Transitions    : Transition_Array (Sequences'Range) := [others => 0];
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
              and then DB.Receipt_Batch_ID (Receipt) = DB.Identifier (Expected_ID),
            "pipelined singleton receipt identity mismatch");
         Require
           (DB.Receipt_Sequence (Receipt) > 0,
            "pipelined singleton receipt sequence is absent");
         Sequences (Index) := DB.Receipt_Sequence (Receipt);
         Transitions (Index) := Benchmark_Controls.Attempted_Transition_Number (Receipt);
      end Finish_Slot;

      procedure Drain_Ready is
         Finished_Here : Natural := 0;
      begin
         Operations.Wait_Some (Set, Completed);
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
            begin
               while Active (Slot) loop
                  Slot := Slot + 1;
               end loop;
               Prepare_Transaction
                 (Item, Family, Index, Mutations, Key_Length, Value_Length, Transaction);
               DB.Commit (Transaction, Deadline, Work (Slot).all);
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
      end loop;
      for Index in Sequences'Range loop
         Require
           (Sequences (Index) > 0
              and then
                (Index = Sequences'First
                 or else Sequences (Index) = Sequences (Index - 1) + 1),
            "pipelined singleton receipt sequence mismatch");
      end loop;
      if Cohort_Width > 0 then
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
      Cohort_Width       : constant Natural := Requested_Independent_Cohort_Width;
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

      procedure Require_Cohort_Geometry
        (Batch_Before, Manifest_Before, Head_Before : Natural;
         Batch_After, Manifest_After, Head_After    : Natural;
         Transactions                               : Natural;
         Context                                    : String) is
      begin
         Require
           (Batch_After = Batch_Before + Transactions
              and then Manifest_After = Manifest_Before
              and then Head_After = Head_Before + Transactions / Cohort_Width,
            Context & " independent-cohort publication geometry changed");
      end Require_Cohort_Geometry;
   begin
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
        (Cohort_Width <= Maximum_Pipeline_Depth,
         "independent cohort width exceeds the eight-slot fixture capacity");
      Require
        (Cohort_Width = 0
           or else
             (not Explicit_Group
              and then Pipeline_Depth = Cohort_Width
              and then Warmup mod Cohort_Width = 0
              and then Measured mod Cohort_Width = 0),
         "independent cohort width requires equal pipeline depth and divisible transaction counts");
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
      if Cohort_Width > 0 then
         Benchmark_Controls.Enable_Independent_Coalescing
           (Ignored_Item,
            Storage,
            DB.Database_Identifier (Numbered_ID (1)),
            Numbered_ID (2),
            Positive (Cohort_Width),
            Timeout,
            Result);
         Expect (Result, "independent-coalescing profile setup failed");
      end if;
      DB.Open_Column_Family (Ignored_Item, 1, Family, Result);
      Expect (Result, "family open failed");

      if Cohort_Width > 0 then
         Benchmark_Controls.Publication_Counts
           (Storage.all, Warmup_Batch_Before, Warmup_Manifest_Before, Warmup_Head_Before);
      end if;

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
               Cohort_Width);
         end if;
      end if;
      if Cohort_Width > 0 then
         Benchmark_Controls.Publication_Counts
           (Storage.all, Warmup_Batch_After, Warmup_Manifest_After, Warmup_Head_After);
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
            Cohort_Width);
      end if;
      Finished := Ada.Real_Time.Clock;
      if Cohort_Width > 0 then
         Benchmark_Controls.Publication_Counts
           (Storage.all, Measured_Batch_After, Measured_Manifest_After, Measured_Head_After);
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
