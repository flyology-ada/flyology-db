with Ada.Directories;
with Ada.Real_Time;
with Ada.Unchecked_Deallocation;
with Interfaces;
with Flyology.Cancellation;
with Flyology.Bytes;
with Flyology.DB.Batch_Format_Tests;
with Flyology.DB.Formats;
with Flyology.DB.LSM_Formats;
with Flyology.DB.Object_Storage;
with Flyology.DB.Testing;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends;
with Flyology.Object_Storage.Backends.Files;
with Flyology.Object_Storage.Backends.Memory;

package body Flyology.DB.Engine_Tests is

   package Binding renames Flyology.DB.Object_Storage;
   package Batch_Tests renames Flyology.DB.Batch_Format_Tests;
   package Formats renames Flyology.DB.Formats;
   package LSM renames Flyology.DB.LSM_Formats;
   package Root_DB renames Flyology.DB;
   package Testing renames Flyology.DB.Testing;
   package OS renames Flyology.Object_Storage;
   package Backends renames Flyology.Object_Storage.Backends;
   package Files renames Flyology.Object_Storage.Backends.Files;
   package Memory renames Flyology.Object_Storage.Backends.Memory;

   use type Byte;
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type OS.Status;

   --  Test-only object namespace and reference-corpus byte dimensions. The
   --  latter deliberately mirror the bounded batch reference codec; they do
   --  not override persisted per-family limits used by production allocation.
   Bucket              : constant String := "flyology-db-tests";
   Maximum_Key_Bytes   : constant := Reference_Maximum_Key_Bytes;
   Maximum_Value_Bytes : constant := Reference_Maximum_Value_Bytes;

   --  Ordinary engine-test calls receive ten seconds; the MiB-scale allocation
   --  campaign receives twenty. These are runner-stability budgets, not DB API
   --  defaults, retry policy, or persisted workload deadlines.
   Test_Operation_Timeout          : constant Duration := 10.0;
   Large_Profile_Operation_Timeout : constant Duration := 20.0;
   --  Zero is the explicit already-expired boundary used only by timeout tests;
   --  it must never become an ordinary operation default.
   Expired_Operation_Timeout       : constant Duration := 0.0;
   --  A zero-duration delay is the Ada tasking yield used by deterministic
   --  polling loops; it is scheduler/test policy, not an operation timeout.
   Test_Poll_Yield                 : constant Duration := 0.0;
   --  The queued-timeout test gives one call 50 ms and holds the coordinator
   --  for 100 ms, a two-times deterministic expiry margin. These are test
   --  scheduling parameters and do not define production polling or deadlines.
   Short_Queue_Timeout             : constant Duration := 0.05;
   Short_Queue_Expiry_Hold         : constant Duration := 0.10;

   subtype Test_Key_Length is Natural range 0 .. Reference_Maximum_Key_Bytes;
   subtype Test_Value_Length is Natural range 0 .. Reference_Maximum_Value_Bytes;
   type Key is record
      Length : Test_Key_Length := 0;
      Bytes  : Byte_Array (1 .. Reference_Maximum_Key_Bytes) := [others => 0];
   end record;
   type Value is record
      Length : Test_Value_Length := 0;
      Bytes  : Byte_Array (1 .. Reference_Maximum_Value_Bytes) := [others => 0];
   end record;

   function To_Key (Data : Byte_Array) return Key is
   begin
      return Result : Key do
         Result.Length := Data'Length;
         for Offset in Natural range 0 .. Data'Length - 1 loop
            Result.Bytes (Offset + 1) := Data (Data'First + Offset);
         end loop;
      end return;
   end To_Key;

   function To_Value (Data : Byte_Array) return Value is
   begin
      return Result : Value do
         Result.Length := Data'Length;
         for Offset in Natural range 0 .. Data'Length - 1 loop
            Result.Bytes (Offset + 1) := Data (Data'First + Offset);
         end loop;
      end return;
   end To_Value;

   function Key_Data (Item : Key) return Byte_Array is
   begin
      return Result : Byte_Array (1 .. Item.Length) do
         Result := Item.Bytes (1 .. Item.Length);
      end return;
   end Key_Data;

   function Value_Data (Item : Value) return Byte_Array is
   begin
      return Result : Byte_Array (1 .. Item.Length) do
         Result := Item.Bytes (1 .. Item.Length);
      end return;
   end Value_Data;

   function ID (Last : Byte) return Identifier is
      Result : Identifier := [others => 0];
   begin
      Result (Result'Last) := Last;
      return Result;
   end ID;

   function Numbered_ID (Value : Natural) return Identifier is
      Result : Identifier := [others => 0];
   begin
      Result (Result'Last - 1) := Byte ((Value / 256) mod 256);
      Result (Result'Last) := Byte (Value mod 256);
      return Result;
   end Numbered_ID;

   function Numbered_TX_ID (Value : Natural) return Transaction_Identifier
   is (Transaction_Identifier (Numbered_ID (Value)));

   function DB_ID (Last : Byte) return Database_Identifier
   is (Database_Identifier (ID (Last)));

   function TX_ID (Last : Byte) return Transaction_Identifier
   is (Transaction_Identifier (ID (Last)));

   procedure Expect (Actual : Outcome_Code; Expected : Outcome_Code; Context : String) is
   begin
      if Actual /= Expected then
         raise Program_Error with Context & ": " & Outcome_Code'Image (Actual);
      end if;
   end Expect;

   type Ownership_Snapshot is record
      Images_Allocated : Interfaces.Unsigned_64;
      Images_Released  : Interfaces.Unsigned_64;
      Arenas_Allocated : Interfaces.Unsigned_64;
      Arenas_Released  : Interfaces.Unsigned_64;
   end record;

   function Current_Ownership return Ownership_Snapshot is
      Result            : Ownership_Snapshot;
      Transaction_Bytes : Interfaces.Unsigned_64;
      Source_Bytes      : Interfaces.Unsigned_64;
      Sink_Bytes        : Interfaces.Unsigned_64;
   begin
      Testing.Image_Statistics
        (Result.Images_Allocated,
         Result.Images_Released,
         Result.Arenas_Allocated,
         Result.Arenas_Released,
         Transaction_Bytes,
         Source_Bytes,
         Sink_Bytes);
      return Result;
   end Current_Ownership;

   procedure Expect_No_Owner_Growth (Before : Ownership_Snapshot; Context : String) is
      After : constant Ownership_Snapshot := Current_Ownership;
   begin
      if After.Images_Allocated - After.Images_Released /= Before.Images_Allocated - Before.Images_Released
      then
         raise Program_Error with Context & ": leaked a shared image owner";
      elsif After.Arenas_Allocated - After.Arenas_Released /= Before.Arenas_Allocated - Before.Arenas_Released
      then
         raise Program_Error with Context & ": leaked a transaction arena";
      end if;
   end Expect_No_Owner_Growth;

   function Visible (Item : in out Database) return Sequence_Number is
      Value  : Sequence_Number;
      Result : Outcome_Code;
   begin
      Highest_Visible (Item, Value, Result);
      Expect (Result, Success, "highest-visible query failed");
      return Value;
   end Visible;

   procedure Bind_Context
     (Context : in out Storage_Context; Backend : not null access Backends.Backend'Class; Prefix : String) is
   begin
      Binding.Bind (Context, Backend, Bucket, Prefix);
   end Bind_Context;

   --  Shared engine-test database policy: eight families/group members, the
   --  current 64-entry history/mutation reference dimensions, and byte
   --  budgets large enough for ordinary fixtures. These values define corpus
   --  coverage only and are always persisted explicitly by Create_DB.
   Default_Limits : constant Database_Limits :=
     (Maximum_Column_Families           => 8,
      Maximum_Manifest_History          => 64,
      Maximum_Batch_History             => 64,
      Maximum_Transactions_Per_Batch    => 8,
      Maximum_Mutations_Per_Transaction => 64,
      Maximum_Mutations_Per_Batch       => 64,
      Maximum_Live_Entries              => 256,
      Maximum_Transaction_Payload_Bytes => 4_096,
      Maximum_Batch_Payload_Bytes       => 16_384,
      Maximum_Live_State_Bytes          => 81_920,
      --  One potential L0 run per family and the exact current reservation
      --  capacity (64 histories * (8 transaction IDs + one group ID)). These
      --  are persisted corpus choices, not library defaults.
      Maximum_Total_L0_Runs             => 8,
      Maximum_Checkpoint_Identities     => 576);

   function Configure_Test_Family
     (ID : Column_Family_ID; Name : Byte_Array; Max_Key, Max_Value : Interfaces.Unsigned_64)
      return Column_Family_Configuration is
   begin
      if Max_Key > Interfaces.Unsigned_64'Last - Max_Value then
         raise Constraint_Error with "test family extent overflow";
      end if;
      --  The fixture memtable holds one maximum-sized entry and one first-L0
      --  run. Call sites vary key/value authority independently; this helper
      --  deliberately supplies no production default.
      return Configure_Column_Family (ID, Name, Max_Key, Max_Value, Max_Key + Max_Value, 1, 1);
   end Configure_Test_Family;

   --  Eight deterministic family profiles exercise unequal per-family limits;
   --  64/256 are reference-corpus dimensions, while 16/16 and 8/8 prove that
   --  the selected family, not a global default, governs admission.
   Default_Families : constant Column_Family_Configuration_Array :=
     [Configure_Test_Family (1, [Byte (Character'Pos ('a'))], 64, 256),
      Configure_Test_Family (2, [Byte (Character'Pos ('b'))], 16, 16),
      Configure_Test_Family (3, [Byte (Character'Pos ('c'))], 8, 8),
      Configure_Test_Family (4, [Byte (Character'Pos ('d'))], 64, 256),
      Configure_Test_Family (5, [Byte (Character'Pos ('e'))], 64, 256),
      Configure_Test_Family (6, [Byte (Character'Pos ('f'))], 64, 256),
      Configure_Test_Family (7, [Byte (Character'Pos ('g'))], 64, 256),
      Configure_Test_Family (8, [Byte (Character'Pos ('h'))], 64, 256)];

   function Manifest_ID_For (Transition_ID : Identifier) return Identifier is
      Result : Identifier := Transition_ID;
   begin
      --  Test-only 4D domain separation makes manifest IDs distinct while
      --  preserving deterministic fixture suffixes; it is not a wire tag.
      Result (Result'First) := 16#4D#;
      return Result;
   end Manifest_ID_For;

   procedure Create_DB
     (Item          : in out Database;
      Context       : not null access Storage_Context;
      Database_ID   : Database_Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code)
   is
      Receipt      : Create_Receipt;
      Version      : Interfaces.Unsigned_16;
      Inspect      : Outcome_Code;
      Close_Result : Outcome_Code;
   begin
      Create
        (Item,
         Context,
         Database_ID,
         Manifest_ID_For (Transition_ID),
         Transition_ID,
         Default_Limits,
         Default_Families,
         Test_Operation_Timeout,
         Receipt => Receipt,
         Result  => Result);
      if Result = Success then
         Testing.Manifest_Version (Context.all, Manifest_ID_For (Transition_ID), Version, Inspect);
         if Inspect /= Success or else Version /= LSM.Checkpoint_Manifest_Format_Version then
            Close (Item, Close_Result);
            Result := Corrupt;
         end if;
      end if;
   end Create_DB;

   procedure Get
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
      Data     : out Value;
      Result   : out Outcome_Code)
   is
      Handle : Column_Family;
      Owned  : Flyology.Bytes.Unbounded_Bytes;
   begin
      Open_Column_Family (Item, Family, Handle, Result);
      if Result = Success then
         Root_DB.Get (Item, Txn, Handle, Key_Data (Item_Key), Owned, Result);
         Data := (others => <>);
         if Result = Success then
            if Flyology.Bytes.Length (Owned) > Test_Value_Length'Last then
               Result := Capacity_Exceeded;
            else
               Data.Length := Flyology.Bytes.Length (Owned);
               for Index in Positive range 1 .. Data.Length loop
                  Data.Bytes (Index) := Byte (Flyology.Bytes.Element (Owned, Index));
               end loop;
            end if;
         end if;
      end if;
   end Get;

   procedure Put
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
      Data     : Value;
      Result   : out Outcome_Code)
   is
      Handle : Column_Family;
   begin
      Open_Column_Family (Item, Family, Handle, Result);
      if Result = Success then
         Root_DB.Put (Item, Txn, Handle, Key_Data (Item_Key), Value_Data (Data), Result);
      end if;
   end Put;

   procedure Delete
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
      Result   : out Outcome_Code)
   is
      Handle : Column_Family;
   begin
      Open_Column_Family (Item, Family, Handle, Result);
      if Result = Success then
         Root_DB.Delete (Item, Txn, Handle, Key_Data (Item_Key), Result);
      end if;
   end Delete;

   procedure Get
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Key;
      Data     : out Value;
      Result   : out Outcome_Code)
   is
      Owned : Flyology.Bytes.Unbounded_Bytes;
   begin
      Root_DB.Get (Item, Txn, Family, Key_Data (Item_Key), Owned, Result);
      Data := (others => <>);
      if Result = Success then
         if Flyology.Bytes.Length (Owned) > Test_Value_Length'Last then
            Result := Capacity_Exceeded;
         else
            Data.Length := Flyology.Bytes.Length (Owned);
            for Index in Positive range 1 .. Data.Length loop
               Data.Bytes (Index) := Byte (Flyology.Bytes.Element (Owned, Index));
            end loop;
         end if;
      end if;
   end Get;

   procedure Put
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Key;
      Data     : Value;
      Result   : out Outcome_Code) is
   begin
      Root_DB.Put (Item, Txn, Family, Key_Data (Item_Key), Value_Data (Data), Result);
   end Put;

   procedure Delete
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Key;
      Result   : out Outcome_Code) is
   begin
      Root_DB.Delete (Item, Txn, Family, Key_Data (Item_Key), Result);
   end Delete;

   procedure Test_CRUD_And_Recovery
     (Backend : not null access Backends.Backend'Class; Prefix : String; Tag : Byte)
   is
      Context      : aliased Storage_Context;
      Lost_Context : aliased Storage_Context;
      Item         : Database;
      Reopened     : Database;
      Txn          : Transaction;
      Reader       : Transaction;
      Receipt      : Commit_Receipt;
      Result       : Outcome_Code;
      Data         : Value;
      --  CRUD corpus covers empty, zero, and high-bit byte sequences across
      --  families and recovery. Tag supplies the deterministic database ID;
      --  none of these byte strings is application policy.
      Key_A        : constant Key := To_Key ([16#00#, 16#FF#]);
      Empty_Key    : constant Key := To_Key ([]);
      Value_One    : constant Value := To_Value ([16#01#, 16#02#]);
      Value_Two    : constant Value := To_Value ([16#80#]);
      Empty_Value  : constant Value := To_Value ([]);
      Database_ID  : constant Database_Identifier := DB_ID (Tag);
   begin
      Bind_Context (Context, Backend, Prefix);
      Create_DB (Item, Context'Access, Database_ID, ID (Tag + 1), Result);
      Expect (Result, Success, "create failed");
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Invalid_State, "double-open database was accepted");
      Begin_Transaction (Item, Zero_Transaction_ID, Txn, Result);
      Expect (Result, Invalid_State, "zero transaction ID was accepted");

      Begin_Transaction (Item, TX_ID (Tag + 2), Txn, Result);
      Expect (Result, Success, "begin failed");
      Put (Item, Txn, 1, Key_A, Value_One, Result);
      Expect (Result, Success, "first-family put failed");
      Put (Item, Txn, 2, Key_A, Value_Two, Result);
      Expect (Result, Success, "second-family put failed");
      Put (Item, Txn, 3, Empty_Key, Empty_Value, Result);
      Expect (Result, Success, "empty key/value put failed");
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "cross-family commit failed");
      if Receipt_Sequence (Receipt) /= 1 or else Visible (Item) /= 1 then
         raise Program_Error with "commit sequence was not retained";
      end if;

      declare
         protected Start_Gate is
            procedure Ready;
            entry Go;
         private
            Ready_Count : Natural range 0 .. 2 := 0;
         end Start_Gate;

         protected body Start_Gate is
            procedure Ready is
            begin
               Ready_Count := Ready_Count + 1;
            end Ready;

            entry Go when Ready_Count = 2 is
            begin
               null;
            end Go;
         end Start_Gate;

         task type Commit_Call
           (Identity : Byte;
            Family   : Column_Family_ID)
         is
            entry Wait (Call_Result : out Outcome_Code; Sequence : out Sequence_Number);
         end Commit_Call;

         task body Commit_Call is
            Local_Txn     : Transaction;
            Local_Receipt : Commit_Receipt;
            Local_Result  : Outcome_Code;
         begin
            Begin_Transaction (Item, TX_ID (Identity), Local_Txn, Local_Result);
            if Local_Result = Success then
               Put (Item, Local_Txn, Family, To_Key ([Identity]), To_Value ([Identity]), Local_Result);
            end if;
            Start_Gate.Ready;
            Start_Gate.Go;
            if Local_Result = Success then
               Commit
                 (Item, Local_Txn, Test_Operation_Timeout, Receipt => Local_Receipt, Result => Local_Result);
            end if;
            accept Wait (Call_Result : out Outcome_Code; Sequence : out Sequence_Number) do
               Call_Result := Local_Result;
               Sequence := Receipt_Sequence (Local_Receipt);
            end Wait;
         end Commit_Call;

         First_Call                      : Commit_Call (Tag + 20, 1);
         Second_Call                     : Commit_Call (Tag + 21, 2);
         First_Result, Second_Result     : Outcome_Code;
         First_Sequence, Second_Sequence : Sequence_Number;
      begin
         First_Call.Wait (First_Result, First_Sequence);
         Second_Call.Wait (Second_Result, Second_Sequence);
         Expect (First_Result, Success, "first concurrent commit failed");
         Expect (Second_Result, Success, "second concurrent commit failed");
         if First_Sequence = Second_Sequence
           or else First_Sequence not in 2 .. 3
           or else Second_Sequence not in 2 .. 3
         then
            raise Program_Error with "concurrent completion slots lost sequence identity";
         end if;
      end;

      Begin_Transaction (Item, TX_ID (Tag + 3), Reader, Result);
      Expect (Result, Success, "reader begin failed");
      Get (Item, Reader, 1, Key_A, Data, Result);
      Expect (Result, Success, "first-family read failed");
      if Data /= Value_One then
         raise Program_Error with "first-family value changed";
      end if;
      Get (Item, Reader, 2, Key_A, Data, Result);
      Expect (Result, Success, "second-family read failed");
      if Data /= Value_Two then
         raise Program_Error with "column-family namespaces were not isolated";
      end if;
      Get (Item, Reader, 3, Empty_Key, Data, Result);
      Expect (Result, Success, "empty key/value read failed");
      if Data /= Empty_Value then
         raise Program_Error with "empty value changed";
      end if;
      Rollback (Reader, Result);
      Expect (Result, Success, "reader rollback failed");
      Begin_Transaction (Item, TX_ID (Tag + 5), Txn, Result);
      Expect (Result, Success, "delete transaction begin failed");
      Delete (Item, Txn, 1, Key_A, Result);
      Expect (Result, Success, "delete failed");
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "delete commit failed");
      Close (Item, Result);
      Expect (Result, Success, "first close failed");

      Bind_Context (Lost_Context, Backend, Prefix);
      Open (Reopened, Lost_Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "complete-local-state-loss recovery failed");
      Begin_Transaction (Reopened, TX_ID (Tag + 2), Reader, Result);
      Expect (Result, Conflict, "recovery accepted a reused transaction ID");
      Begin_Transaction (Reopened, TX_ID (Tag + 4), Reader, Result);
      Expect (Result, Success, "recovered reader begin failed");
      Get (Reopened, Reader, 1, Key_A, Data, Result);
      Expect (Result, Not_Found, "recovered delete was ignored");
      Get (Reopened, Reader, 2, Key_A, Data, Result);
      Expect (Result, Success, "recovered second-family read failed");
      if Data /= Value_Two then
         raise Program_Error with "recovered second-family bytes changed";
      end if;
      Get (Reopened, Reader, 3, Empty_Key, Data, Result);
      Expect (Result, Success, "recovered empty key/value read failed");
      if Data /= Empty_Value then
         raise Program_Error with "recovered empty value changed";
      end if;
      Rollback (Reader, Result);
      Close (Reopened, Result);
      Expect (Result, Success, "recovered close failed");
   end Test_CRUD_And_Recovery;

   procedure Test_Runtime_Sized_Value
     (Backend : not null access Backends.Backend'Class; Prefix : String; Tag : Byte)
   is
      Context      : aliased Storage_Context;
      Lost_Context : aliased Storage_Context;
      Item         : Database;
      Reopened     : Database;
      Txn          : Transaction;
      Reader       : Transaction;
      Family       : Column_Family;
      Receipt      : Commit_Receipt;
      Create_Info  : Create_Receipt;
      Result       : Outcome_Code;
      Data         : Flyology.Bytes.Unbounded_Bytes;
      Key_Data     : Byte_Array (1 .. 20);
      Value_Data   : Byte_Array (1 .. 400);
      --  Persisted test policy deliberately exceeds the reference value bound:
      --  family 17 admits a 4 KiB key and 1 MiB value, while aggregate budgets
      --  leave room for the exact campaign. This proves runtime sizing from the
      --  family/database records rather than supplying defaults. One L0 run is
      --  reserved for the sole family; 24 identities derive from 8 histories *
      --  (2 transaction IDs + one group ID).
      Limits       : constant Database_Limits :=
        (Maximum_Column_Families           => 1,
         Maximum_Manifest_History          => 4,
         Maximum_Batch_History             => 8,
         Maximum_Transactions_Per_Batch    => 2,
         Maximum_Mutations_Per_Transaction => 4,
         Maximum_Mutations_Per_Batch       => 8,
         Maximum_Live_Entries              => 8,
         Maximum_Transaction_Payload_Bytes => 1_100_000,
         Maximum_Batch_Payload_Bytes       => 2_200_000,
         Maximum_Live_State_Bytes          => 4_400_000,
         Maximum_Total_L0_Runs             => 1,
         Maximum_Checkpoint_Identities     => 24);
      Families     : constant Column_Family_Configuration_Array :=
        [Configure_Test_Family (17, [16#72#, 16#75#, 16#6E#], 4_096, 1_048_576)];
      Database_ID  : constant Database_Identifier := DB_ID (Tag);
   begin
      for Index in Key_Data'Range loop
         Key_Data (Index) := Byte ((Natural (Tag) + Index * 3) mod 256);
      end loop;
      Key_Data (1) := 0;
      for Index in Value_Data'Range loop
         Value_Data (Index) := Byte ((Natural (Tag) + Index * 7) mod 256);
      end loop;
      Value_Data (1) := 0;

      Bind_Context (Context, Backend, Prefix);
      Create
        (Item,
         Context'Access,
         Database_ID,
         Numbered_ID (40_000 + Natural (Tag)),
         Numbered_ID (41_000 + Natural (Tag)),
         Limits,
         Families,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Success, "runtime-sized database create failed");
      Open_Column_Family (Item, 17, Family, Result);
      Expect (Result, Success, "runtime-sized family open failed");
      Begin_Transaction (Item, Numbered_TX_ID (42_000 + Natural (Tag)), Txn, Result);
      Expect (Result, Success, "runtime-sized transaction begin failed");
      Root_DB.Put (Item, Txn, Family, Key_Data, Value_Data, Result);
      Expect (Result, Success, "400-byte value put failed");
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "400-byte value commit failed");
      Close (Item, Result);
      Expect (Result, Success, "runtime-sized database close failed");

      Bind_Context (Lost_Context, Backend, Prefix);
      Open (Reopened, Lost_Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "400-byte value cacheless reopen failed");
      Open_Column_Family (Reopened, 17, Family, Result);
      Expect (Result, Success, "runtime-sized reopened family failed");
      Begin_Transaction (Reopened, Numbered_TX_ID (43_000 + Natural (Tag)), Reader, Result);
      Expect (Result, Success, "runtime-sized reader begin failed");
      Root_DB.Get (Reopened, Reader, Family, Key_Data, Data, Result);
      Expect (Result, Success, "400-byte value reopen read failed");
      if Flyology.Bytes.Length (Data) /= Value_Data'Length then
         raise Program_Error with "400-byte value reopen length changed";
      end if;
      for Index in Value_Data'Range loop
         if Byte (Flyology.Bytes.Element (Data, Index)) /= Value_Data (Index) then
            raise Program_Error with "400-byte value reopen bytes changed";
         end if;
      end loop;
      Rollback (Reader, Result);
      Close (Reopened, Result);
      Expect (Result, Success, "runtime-sized reopened close failed");
   end Test_Runtime_Sized_Value;

   procedure Test_Large_Production_Profile
     (Backend : not null access Backends.Backend'Class; Prefix : String; Tag : Byte)
   is
      type Byte_Array_Access is access Byte_Array;
      procedure Free_Bytes is new Ada.Unchecked_Deallocation (Byte_Array, Byte_Array_Access);

      --  MiB-scale test dimensions (4 KiB key, 1 MiB value) exercise
      --  host allocation beyond the small reference codec. Exact_Two_Bytes is
      --  deliberately one byte short of two full entries to prove aggregate
      --  enforcement; these remain explicit persisted test inputs.
      Key_Bytes       : constant Natural := 4_096;
      Value_Bytes     : constant Natural := 1_048_576;
      Entry_Bytes     : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Key_Bytes + Value_Bytes);
      Exact_Two_Bytes : constant Interfaces.Unsigned_64 := 2 * Entry_Bytes - 1;
      Context         : aliased Storage_Context;
      Lost_Context    : aliased Storage_Context;
      Item            : Database;
      Reopened        : Database;
      Txn             : Transaction;
      Reader          : Transaction;
      Family_A        : Column_Family;
      Family_B        : Column_Family;
      Receipt         : Commit_Receipt;
      Create_Info     : Create_Receipt;
      Result          : Outcome_Code;
      Data            : Flyology.Bytes.Unbounded_Bytes;
      Key_A           : Byte_Array_Access := new Byte_Array (1 .. Key_Bytes);
      Key_B           : Byte_Array_Access := new Byte_Array (1 .. Key_Bytes);
      Key_C           : Byte_Array_Access := new Byte_Array (1 .. Key_Bytes);
      Key_Over        : Byte_Array_Access := new Byte_Array (1 .. Key_Bytes + 1);
      Value_Max       : Byte_Array_Access := new Byte_Array (1 .. Value_Bytes);
      Value_Short     : Byte_Array_Access := new Byte_Array (1 .. Value_Bytes - 1);
      Value_Over      : Byte_Array_Access := new Byte_Array (1 .. Value_Bytes + 1);
      --  Two first-L0 runs match the two families; 108 identities derive from
      --  12 histories * (8 transaction IDs + one group ID). These are exact
      --  stress-corpus reservations, not runtime defaults.
      Limits          : constant Database_Limits :=
        (Maximum_Column_Families           => 2,
         Maximum_Manifest_History          => 4,
         Maximum_Batch_History             => 12,
         Maximum_Transactions_Per_Batch    => 8,
         Maximum_Mutations_Per_Transaction => 8,
         Maximum_Mutations_Per_Batch       => 16,
         Maximum_Live_Entries              => 2,
         Maximum_Transaction_Payload_Bytes => Entry_Bytes,
         Maximum_Batch_Payload_Bytes       => Exact_Two_Bytes,
         Maximum_Live_State_Bytes          => Exact_Two_Bytes,
         Maximum_Total_L0_Runs             => 2,
         Maximum_Checkpoint_Identities     => 108);
      Families        : constant Column_Family_Configuration_Array :=
        [Configure_Test_Family
           (17, [16#6C#, 16#61#], Interfaces.Unsigned_64 (Key_Bytes), Interfaces.Unsigned_64 (Value_Bytes)),
         Configure_Test_Family
           (18, [16#6C#, 16#62#], Interfaces.Unsigned_64 (Key_Bytes), Interfaces.Unsigned_64 (Value_Bytes))];
      Database_ID     : constant Database_Identifier := DB_ID (Tag);

      procedure Check_Bytes (Actual : Flyology.Bytes.Unbounded_Bytes; Expected : Byte_Array; Context : String)
      is
      begin
         if Flyology.Bytes.Length (Actual) /= Expected'Length then
            raise Program_Error with Context & ": length changed";
         end if;
         for Offset in Natural range 0 .. Expected'Length - 1 loop
            if Byte (Flyology.Bytes.Element (Actual, Offset + 1)) /= Expected (Expected'First + Offset) then
               raise Program_Error with Context & ": bytes changed";
            end if;
         end loop;
      end Check_Bytes;

      procedure Start_Txn (Identity : Natural; Target : out Transaction) is
      begin
         Begin_Transaction (Item, Numbered_TX_ID (Identity), Target, Result);
         Expect (Result, Success, "large-profile transaction begin failed");
      end Start_Txn;

      procedure Release_Test_Bytes is
      begin
         Free_Bytes (Key_A);
         Free_Bytes (Key_B);
         Free_Bytes (Key_C);
         Free_Bytes (Key_Over);
         Free_Bytes (Value_Max);
         Free_Bytes (Value_Short);
         Free_Bytes (Value_Over);
      end Release_Test_Bytes;
   begin
      for Index in 1 .. Key_Bytes loop
         Key_A (Index) := Byte ((Index * 3 + Natural (Tag)) mod 256);
         Key_B (Index) := Byte ((Index * 5 + Natural (Tag)) mod 256);
         Key_C (Index) := Byte ((Index * 11 + Natural (Tag)) mod 256);
         Key_Over (Index) := Key_A (Index);
      end loop;
      Key_A (1) := 0;
      Key_B (2) := 0;
      Key_C (3) := 0;
      Key_Over (Key_Over'Last) := 1;
      for Index in 1 .. Value_Bytes loop
         Value_Max (Index) := Byte ((Index * 7 + Natural (Tag)) mod 256);
         Value_Over (Index) := Value_Max (Index);
         if Index < Value_Bytes then
            Value_Short (Index) := Byte ((Index * 13 + Natural (Tag)) mod 256);
         end if;
      end loop;
      Value_Max (1) := 0;
      Value_Over (Value_Over'Last) := 1;

      Bind_Context (Context, Backend, Prefix);
      Create
        (Item,
         Context'Access,
         Database_ID,
         Numbered_ID (44_000 + Natural (Tag)),
         Numbered_ID (45_000 + Natural (Tag)),
         Limits,
         Families,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Success, "large-profile database create failed");
      Open_Column_Family (Item, 17, Family_A, Result);
      Expect (Result, Success, "large-profile family A open failed");
      Open_Column_Family (Item, 18, Family_B, Result);
      Expect (Result, Success, "large-profile family B open failed");

      declare
         Transactions : Transaction_Array (1 .. 2);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         Start_Txn (46_000 + Natural (Tag), Transactions (1));
         Root_DB.Put (Item, Transactions (1), Family_A, Key_A.all, Value_Max.all, Result);
         Expect (Result, Success, "4KiB/1MiB family A put failed");
         Start_Txn (47_000 + Natural (Tag), Transactions (2));
         Root_DB.Put (Item, Transactions (2), Family_B, Key_B.all, Value_Short.all, Result);
         Expect (Result, Success, "4KiB/(1MiB-1) family B put failed");
         Commit_Group
           (Item,
            Numbered_ID (48_000 + Natural (Tag)),
            Transactions,
            Large_Profile_Operation_Timeout,
            Receipts => Receipts,
            Result   => Result);
         Expect (Result, Success, "exact batch/live byte group failed");
      end;

      Start_Txn (49_000 + Natural (Tag), Txn);
      Root_DB.Put (Item, Txn, Family_A, Key_Over.all, [1], Result);
      Expect (Result, Capacity_Exceeded, "4KiB+1 family key was admitted");
      Root_DB.Put (Item, Txn, Family_A, [1], Value_Over.all, Result);
      Expect (Result, Capacity_Exceeded, "1MiB+1 family value was admitted");
      Root_DB.Put (Item, Txn, Family_A, Key_A.all, Value_Max.all, Result);
      Expect (Result, Success, "exact transaction payload was rejected");
      Root_DB.Put (Item, Txn, Family_A, [1], [], Result);
      Expect (Result, Capacity_Exceeded, "transaction payload one-over was admitted");
      Rollback (Txn, Result);
      Expect (Result, Success, "transaction-cap rejection consumed transaction");

      declare
         Transactions : Transaction_Array (1 .. 2);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         Start_Txn (50_000 + Natural (Tag), Transactions (1));
         Root_DB.Put (Item, Transactions (1), Family_A, Key_A.all, Value_Max.all, Result);
         Start_Txn (51_000 + Natural (Tag), Transactions (2));
         Root_DB.Put (Item, Transactions (2), Family_B, Key_B.all, Value_Max.all, Result);
         Commit_Group
           (Item,
            Numbered_ID (52_000 + Natural (Tag)),
            Transactions,
            Large_Profile_Operation_Timeout,
            Receipts => Receipts,
            Result   => Result);
         Expect (Result, Capacity_Exceeded, "batch payload one-over was admitted");
         for Index in Transactions'Range loop
            Rollback (Transactions (Index), Result);
            Expect (Result, Success, "batch-cap rejection consumed a group member");
         end loop;
      end;

      declare
         Before_Batch, Before_Manifest, Before_Head : Natural;
         After_Batch, After_Manifest, After_Head    : Natural;
      begin
         Testing.Publication_Counts (Context, Before_Batch, Before_Manifest, Before_Head);
         Start_Txn (53_000 + Natural (Tag), Txn);
         Root_DB.Put (Item, Txn, Family_B, Key_B.all, Value_Max.all, Result);
         Commit (Item, Txn, Large_Profile_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Capacity_Exceeded, "live byte cap one-over was published");
         Rollback (Txn, Result);
         Expect (Result, Invalid_State, "post-admission live-byte rejection left transaction active");
         Testing.Publication_Counts (Context, After_Batch, After_Manifest, After_Head);
         if After_Batch /= Before_Batch
           or else After_Manifest /= Before_Manifest
           or else After_Head /= Before_Head
         then
            raise Program_Error with "live-byte rejection caused storage effects";
         end if;

         Start_Txn (54_000 + Natural (Tag), Txn);
         Root_DB.Put (Item, Txn, Family_A, [], [], Result);
         Expect (Result, Success, "empty key/value was rejected before live-entry projection");
         Commit (Item, Txn, Large_Profile_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Capacity_Exceeded, "live entry cap one-over was published");
         Testing.Publication_Counts (Context, After_Batch, After_Manifest, After_Head);
         if After_Batch /= Before_Batch
           or else After_Manifest /= Before_Manifest
           or else After_Head /= Before_Head
         then
            raise Program_Error with "live-entry rejection caused storage effects";
         end if;
      end;

      Start_Txn (55_000 + Natural (Tag), Txn);
      Root_DB.Put (Item, Txn, Family_A, Key_A.all, Value_Max.all, Result);
      Commit (Item, Txn, Large_Profile_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "overwrite at exact live cap failed");

      declare
         Transactions : Transaction_Array (1 .. 2);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         Start_Txn (56_000 + Natural (Tag), Transactions (1));
         Root_DB.Delete (Item, Transactions (1), Family_A, Key_A.all, Result);
         Start_Txn (57_000 + Natural (Tag), Transactions (2));
         Root_DB.Put (Item, Transactions (2), Family_A, Key_C.all, Value_Max.all, Result);
         Commit_Group
           (Item,
            Numbered_ID (58_000 + Natural (Tag)),
            Transactions,
            Large_Profile_Operation_Timeout,
            Receipts => Receipts,
            Result   => Result);
         Expect (Result, Success, "delete+put final-state projection at cap failed");
      end;

      declare
         Transactions : Transaction_Array (1 .. 2);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         Start_Txn (59_000 + Natural (Tag), Transactions (1));
         Root_DB.Delete (Item, Transactions (1), Family_B, Key_B.all, Result);
         Start_Txn (60_000 + Natural (Tag), Transactions (2));
         Root_DB.Put (Item, Transactions (2), Family_B, [], [], Result);
         Commit_Group
           (Item,
            Numbered_ID (61_000 + Natural (Tag)),
            Transactions,
            Large_Profile_Operation_Timeout,
            Receipts => Receipts,
            Result   => Result);
         Expect (Result, Success, "empty key/value replacement group failed");
      end;
      Close (Item, Result);
      Expect (Result, Success, "large-profile close failed");

      Bind_Context (Lost_Context, Backend, Prefix);
      Open (Reopened, Lost_Context'Access, Database_ID, Large_Profile_Operation_Timeout, Result => Result);
      Expect (Result, Success, "large-profile complete-loss reopen failed");
      Open_Column_Family (Reopened, 17, Family_A, Result);
      Open_Column_Family (Reopened, 18, Family_B, Result);
      Begin_Transaction (Reopened, Numbered_TX_ID (62_000 + Natural (Tag)), Reader, Result);
      Root_DB.Get (Reopened, Reader, Family_A, Key_C.all, Data, Result);
      Expect (Result, Success, "large-profile recovered 1MiB read failed");
      Check_Bytes (Data, Value_Max.all, "large-profile recovered 1MiB value");
      Root_DB.Get (Reopened, Reader, Family_B, [], Data, Result);
      Expect (Result, Success, "large-profile recovered empty key read failed");
      if Flyology.Bytes.Length (Data) /= 0 then
         raise Program_Error with "large-profile recovered empty value changed";
      end if;
      Rollback (Reader, Result);
      Close (Reopened, Result);
      Expect (Result, Success, "large-profile recovered close failed");
      Release_Test_Bytes;
   exception
      when others =>
         Release_Test_Bytes;
         raise;
   end Test_Large_Production_Profile;

   procedure Test_Dynamic_Mutation_Descriptors
     (Backend : not null access Backends.Backend'Class; Prefix : String; Tag : Byte)
   is
      Context      : aliased Storage_Context;
      Lost_Context : aliased Storage_Context;
      Item         : Database;
      Reopened     : Database;
      Txn          : Transaction;
      Family       : Column_Family;
      Receipt      : Commit_Receipt;
      Create_Info  : Create_Receipt;
      Result       : Outcome_Code;
      --  257 mutation descriptors is deliberately one over the common 256-item
      --  hidden-cap boundary. One two-byte entry per mutation makes the
      --  514-byte aggregate exact and proves persisted dynamic allocation. One
      --  L0 run covers the sole family; 6 identities derive from 2 histories *
      --  (2 transaction IDs + one group ID).
      Limits       : constant Database_Limits :=
        (Maximum_Column_Families           => 1,
         Maximum_Manifest_History          => 2,
         Maximum_Batch_History             => 2,
         Maximum_Transactions_Per_Batch    => 2,
         Maximum_Mutations_Per_Transaction => 257,
         Maximum_Mutations_Per_Batch       => 257,
         Maximum_Live_Entries              => 257,
         Maximum_Transaction_Payload_Bytes => 514,
         Maximum_Batch_Payload_Bytes       => 514,
         Maximum_Live_State_Bytes          => 514,
         Maximum_Total_L0_Runs             => 1,
         Maximum_Checkpoint_Identities     => 6);
      Families     : constant Column_Family_Configuration_Array :=
        [Configure_Test_Family (23, [16#64#, 16#79#, 16#6E#], 2, 1)];
      Database_ID  : constant Database_Identifier := DB_ID (Tag);
   begin
      Bind_Context (Context, Backend, Prefix);
      Create
        (Item,
         Context'Access,
         Database_ID,
         Numbered_ID (63_000 + Natural (Tag)),
         Numbered_ID (63_100 + Natural (Tag)),
         Limits,
         Families,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Success, "dynamic-mutation database create failed");
      Open_Column_Family (Item, 23, Family, Result);

      declare
         Transactions : Transaction_Array (1 .. 2);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         Begin_Transaction (Item, Numbered_TX_ID (63_150 + Natural (Tag)), Transactions (1), Result);
         for Index in 1 .. 128 loop
            Root_DB.Put
              (Item, Transactions (1), Family, [Byte (Index / 256), Byte (Index mod 256)], [], Result);
            Expect (Result, Success, "first dynamic batch-cap member failed");
         end loop;
         Begin_Transaction (Item, Numbered_TX_ID (63_160 + Natural (Tag)), Transactions (2), Result);
         for Index in 129 .. 258 loop
            Root_DB.Put
              (Item, Transactions (2), Family, [Byte (Index / 256), Byte (Index mod 256)], [], Result);
            Expect (Result, Success, "second dynamic batch-cap member failed");
         end loop;
         Commit_Group
           (Item,
            Numbered_ID (63_170 + Natural (Tag)),
            Transactions,
            Test_Operation_Timeout,
            Receipts => Receipts,
            Result   => Result);
         Expect (Result, Capacity_Exceeded, "dynamic batch mutation/payload one-over was admitted");
         for Index in Transactions'Range loop
            Rollback (Transactions (Index), Result);
            Expect (Result, Success, "dynamic batch-cap rejection consumed a member");
         end loop;
      end;

      Begin_Transaction (Item, Numbered_TX_ID (63_200 + Natural (Tag)), Txn, Result);
      for Index in 1 .. 257 loop
         Root_DB.Put (Item, Txn, Family, [Byte (Index / 256), Byte (Index mod 256)], [], Result);
         Expect (Result, Success, "257-mutation transaction was narrowed to the reference instance");
      end loop;
      Root_DB.Put (Item, Txn, Family, [1, 2], [], Result);
      Expect (Result, Capacity_Exceeded, "dynamic transaction mutation one-over was admitted");
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "257-mutation/live-entry runtime batch failed");

      Begin_Transaction (Item, Numbered_TX_ID (63_300 + Natural (Tag)), Txn, Result);
      Root_DB.Put (Item, Txn, Family, [1, 2], [], Result);
      Expect (Result, Success, "dynamic live-entry one-over mutation was rejected before projection");
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Capacity_Exceeded, "dynamic live-entry one-over was published");
      Rollback (Txn, Result);
      Expect (Result, Invalid_State, "post-admission dynamic live rejection left transaction active");
      Close (Item, Result);

      Bind_Context (Lost_Context, Backend, Prefix);
      Open (Reopened, Lost_Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "257-mutation runtime batch did not cachelessly reopen");
      Open_Column_Family (Reopened, 23, Family, Result);
      Begin_Transaction (Reopened, Numbered_TX_ID (63_400 + Natural (Tag)), Txn, Result);
      declare
         Data : Flyology.Bytes.Unbounded_Bytes;
      begin
         Root_DB.Get (Reopened, Txn, Family, [1, 1], Data, Result);
         Expect (Result, Success, "dynamic state table lost its last exact entry");
         if Flyology.Bytes.Length (Data) /= 0 then
            raise Program_Error with "dynamic state table changed an empty value";
         end if;
      end;
      Rollback (Txn, Result);
      Close (Reopened, Result);
      Expect (Result, Success, "dynamic-mutation reopened close failed");
   end Test_Dynamic_Mutation_Descriptors;

   procedure Test_Allocation_Failures (Backend : not null access Backends.Backend'Class) is
      Context      : aliased Storage_Context;
      Item         : Database;
      Probe        : Database;
      Txn          : Transaction;
      Receipt      : Commit_Receipt;
      Result       : Outcome_Code;
      Before       : Ownership_Snapshot;
      Before_Batch : Natural;
      Before_Head  : Natural;
      After_Batch  : Natural;
      After_Head   : Natural;

      procedure Expect_Closed_Allocation_Failure
        (Point : Testing.Allocation_Fault_Point; Context_Text : String) is
      begin
         Before := Current_Ownership;
         Testing.Fail_Next_Allocation (Point);
         Open (Probe, Context'Access, DB_ID (24), Test_Operation_Timeout, Result => Result);
         Expect (Result, Capacity_Exceeded, Context_Text & " was not typed capacity");
         Expect_No_Owner_Growth (Before, Context_Text);
         Close (Probe, Result);
         Expect (Result, Invalid_State, Context_Text & " partially opened the database");
      end Expect_Closed_Allocation_Failure;
   begin
      Bind_Context (Context, Backend, "allocation-failures");
      Create_DB (Item, Context'Access, DB_ID (24), ID (25), Result);
      Expect (Result, Success, "allocation-failure database create failed");

      Testing.Fail_Next_Allocation (Testing.Transaction_Arena);
      Begin_Transaction (Item, TX_ID (26), Txn, Result);
      Expect (Result, Capacity_Exceeded, "transaction arena allocation failure was not typed capacity");

      Begin_Transaction (Item, TX_ID (27), Txn, Result);
      Expect (Result, Success, "allocation payload transaction begin failed");
      Testing.Fail_Next_Allocation (Testing.Transaction_Payload);
      Put (Item, Txn, Default_Families (1).ID, To_Key ([1]), To_Value ([1]), Result);
      Expect (Result, Capacity_Exceeded, "transaction payload allocation failure was not typed capacity");
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Invalid_State, "empty transaction after allocation failure was admitted");
      if Receipt_Transaction_ID (Receipt) /= Zero_Transaction_ID
        or else Receipt_Batch_ID (Receipt) /= Zero_Identifier
      then
         raise Program_Error with "pre-admission allocation failure returned a nonempty receipt";
      end if;
      Rollback (Txn, Result);
      Expect (Result, Success, "pre-admission allocation failure consumed transaction");

      Begin_Transaction (Item, TX_ID (28), Txn, Result);
      Put (Item, Txn, 1, To_Key ([2]), To_Value ([2]), Result);
      Testing.Publication_Counts (Context, Before_Batch, Before_Head);
      Testing.Fail_Next_Allocation (Testing.Batch_Descriptors);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Capacity_Exceeded, "post-admission encoder allocation failure was not typed capacity");
      if Receipt_Transaction_ID (Receipt) /= TX_ID (28) or else Receipt_Batch_ID (Receipt) /= ID (28) then
         raise Program_Error with "post-admission encoder failure lost stable receipt identity";
      end if;
      Rollback (Txn, Result);
      Expect (Result, Invalid_State, "post-admission encoder failure left transaction active");
      Testing.Publication_Counts (Context, After_Batch, After_Head);
      if After_Batch /= Before_Batch or else After_Head /= Before_Head then
         raise Program_Error with "encoder allocation failure reached storage publication";
      end if;

      Begin_Transaction (Item, TX_ID (29), Txn, Result);
      Put (Item, Txn, 1, To_Key ([3]), To_Value ([3]), Result);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "allocation recovery fixture commit failed");
      Close (Item, Result);

      Expect_Closed_Allocation_Failure (Testing.Storage_Sink, "storage sink allocation failure");
      Expect_Closed_Allocation_Failure (Testing.Recovery_History, "recovery history allocation failure");
      Expect_Closed_Allocation_Failure (Testing.Engine_State, "engine state allocation failure");
      Expect_Closed_Allocation_Failure (Testing.Identity_Tables, "identity-table allocation failure");
      Expect_Closed_Allocation_Failure (Testing.Projection_Scratch, "projection-scratch allocation failure");

      Open (Probe, Context'Access, DB_ID (24), Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "database did not reopen after allocation-failure campaign");
      Close (Probe, Result);
   end Test_Allocation_Failures;

   procedure Test_Runtime_Codec is
      --  The operational decoder must accept the exact independently frozen
      --  batch image. Wire_Boundary is derived from the narrower of host
      --  Natural and U32, the persisted frame-length representation.
      Golden        : constant Byte_Array := Batch_Tests.Frozen_Golden;
      Wire_Boundary : constant Natural :=
        Natural
          (Interfaces.Unsigned_64'Min
             (Interfaces.Unsigned_64 (Natural'Last), Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)));
      Result        : Outcome_Code;

      procedure Put_U32 (Data : in out Byte_Array; Position : Natural; Value : Interfaces.Unsigned_32) is
      begin
         for Offset in Natural range 0 .. 3 loop
            Data (Data'First + Position + Offset) :=
              Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
         end loop;
      end Put_U32;

      procedure Repair_Checksums (Data : in out Byte_Array) is
         Header : Formats.Byte_Array (0 .. 155);
         Whole  : Formats.Byte_Array (0 .. Data'Length - 5);
      begin
         Data (Data'First + 40 .. Data'First + 43) := [others => 0];
         for Offset in Header'Range loop
            Header (Offset) := Data (Data'First + Offset);
         end loop;
         Put_U32 (Data, 40, Formats.CRC_32C (Header));
         for Offset in Whole'Range loop
            Whole (Offset) := Data (Data'First + Offset);
         end loop;
         Put_U32 (Data, Data'Length - 4, Formats.CRC_32C (Whole));
      end Repair_Checksums;

      procedure Expect_Runtime
        (Data       : Byte_Array;
         Expected   : Outcome_Code;
         Context    : String;
         Wrong_DB   : Boolean := False;
         Wrong_Head : Boolean := False) is
      begin
         Testing.Decode_Runtime_Image (Data, Wrong_DB, Wrong_Head, Result);
         Expect (Result, Expected, Context);
      end Expect_Runtime;

      procedure Expect_Runtime_No_Image_Allocation
        (Data : Byte_Array; Expected : Outcome_Code; Context : String)
      is
         Before : constant Ownership_Snapshot := Current_Ownership;
         After  : Ownership_Snapshot;
      begin
         Expect_Runtime (Data, Expected, Context);
         After := Current_Ownership;
         if After.Images_Allocated /= Before.Images_Allocated then
            raise Program_Error with Context & ": allocated an image before structural rejection";
         end if;
         Expect_No_Owner_Growth (Before, Context);
      end Expect_Runtime_No_Image_Allocation;
   begin
      if not Testing.Group_Mutation_Total_Fits_Wire (Wire_Boundary) then
         raise Program_Error with "wire-sized group mutation total was rejected";
      end if;
      --  Natural'Last is below U32'Last on the qualified runtime, so a
      --  representable one-over value does not exist in this campaign.
      Expect_Runtime (Golden, Success, "independent golden runtime decode");
      Testing.Check_Runtime_Reference_Parity (Result);
      Expect (Result, Success, "generated operational/reference codec parity");

      for Size in Natural range 0 .. Golden'Length - 1 loop
         declare
            Short : Byte_Array (1 .. Size);
         begin
            for Offset in Natural range 0 .. Size - 1 loop
               Short (Offset + 1) := Golden (Golden'First + Offset);
            end loop;
            Expect_Runtime (Short, Corrupt, "runtime truncation");
         end;
      end loop;
      declare
         Trailing : Byte_Array (1 .. Golden'Length + 1) := [others => 0];
      begin
         Trailing (1 .. Golden'Length) := Golden;
         Expect_Runtime (Trailing, Corrupt, "runtime trailing byte");
      end;
      declare
         Mutated : Byte_Array := Golden;
      begin
         Mutated (Mutated'Last) := Mutated (Mutated'Last) xor 1;
         Expect_Runtime (Mutated, Corrupt, "runtime whole-object checksum");

         Mutated := Golden;
         Mutated (Mutated'First + 40) := Mutated (Mutated'First + 40) xor 1;
         Expect_Runtime (Mutated, Corrupt, "runtime header checksum");

         Mutated := Golden;
         Mutated (Mutated'First) := Mutated (Mutated'First) xor 1;
         Repair_Checksums (Mutated);
         Expect_Runtime (Mutated, Corrupt, "runtime repaired magic");

         Mutated := Golden;
         Mutated (Mutated'First + 9) := 2;
         Repair_Checksums (Mutated);
         Expect_Runtime (Mutated, Corrupt, "runtime repaired version");

         Mutated := Golden;
         Mutated (Mutated'First + 10) := 1;
         Repair_Checksums (Mutated);
         Expect_Runtime (Mutated, Corrupt, "runtime repaired kind");

         Mutated := Golden;
         Mutated (Mutated'First + 11) := 1;
         Repair_Checksums (Mutated);
         Expect_Runtime (Mutated, Corrupt, "runtime repaired flags");

         Mutated := Golden;
         Mutated (Mutated'First + 52 .. Mutated'First + 67) := [others => 0];
         Repair_Checksums (Mutated);
         Expect_Runtime (Mutated, Corrupt, "runtime zero batch identity");

         Mutated := Golden;
         Put_U32 (Mutated, 148, Interfaces.Unsigned_32'Last);
         Repair_Checksums (Mutated);
         Expect_Runtime (Mutated, Capacity_Exceeded, "runtime transaction-count resource overflow");

         Mutated := Golden;
         Put_U32 (Mutated, 148, 257);
         Put_U32 (Mutated, 152, 257);
         Repair_Checksums (Mutated);
         Expect_Runtime_No_Image_Allocation
           (Mutated, Corrupt, "runtime admitted counts exceeded the available framing");

         Mutated := Golden;
         Put_U32 (Mutated, 148, 2);
         Put_U32 (Mutated, 152, 1);
         Repair_Checksums (Mutated);
         Expect_Runtime_No_Image_Allocation
           (Mutated, Corrupt, "runtime transaction count exceeded mutation count");

         Mutated := Golden;
         Mutated (Mutated'First + 192) := 3;
         Repair_Checksums (Mutated);
         Expect_Runtime (Mutated, Corrupt, "runtime invalid mutation operation");
      end;
      Expect_Runtime (Golden, Corrupt, "runtime wrong database binding", Wrong_DB => True);
      Expect_Runtime (Golden, Corrupt, "runtime wrong HEAD binding", Wrong_Head => True);
   end Test_Runtime_Codec;

   procedure Test_Manifest_And_Family_API (Backend : not null access Backends.Backend'Class) is
      Context                                    : aliased Storage_Context;
      Other_Ctx                                  : aliased Storage_Context;
      Over_Ctx                                   : aliased Storage_Context;
      Invalid_Ctx                                : aliased Storage_Context;
      Allocation_Ctx                             : aliased Storage_Context;
      Item                                       : Database;
      Retry                                      : Database;
      Other                                      : Database;
      Over_Item                                  : Database;
      Invalid_Item                               : Database;
      Allocation_Item                            : Database;
      Txn                                        : Transaction;
      Receipt                                    : Commit_Receipt;
      Create_Info                                : Create_Receipt;
      Family_By_ID, Family_By_Name, Stale_Family : Column_Family;
      Family_Seven                               : Column_Family;
      Result                                     : Outcome_Code;
      Data                                       : Value;
      Live_Sequence                              : Sequence_Number;
      Expected_Live_Sequence                     : Sequence_Number;
      Batch_Puts, Manifest_Puts, Head_Puts       : Natural;
      --  API fixture persists two unequal families and tight aggregate limits.
      --  Permuted proves canonical ordering, Different changes one persisted
      --  family value, and Over_* isolate explicit admission/capacity failures;
      --  none is an implicit configuration default. Two first-L0 runs match
      --  the families; 24 identities derive from 8 histories * (2 transaction
      --  IDs + one group ID). Family 7's 48-byte memtable derives from three
      --  entries * (8 key + 8 value bytes) for the ordering corpus.
      Limits                                     : constant Database_Limits :=
        (Maximum_Column_Families           => 2,
         Maximum_Manifest_History          => 4,
         Maximum_Batch_History             => 8,
         Maximum_Transactions_Per_Batch    => 2,
         Maximum_Mutations_Per_Transaction => 4,
         Maximum_Mutations_Per_Batch       => 4,
         Maximum_Live_Entries              => 4,
         Maximum_Transaction_Payload_Bytes => 16,
         Maximum_Batch_Payload_Bytes       => 32,
         Maximum_Live_State_Bytes          => 24,
         Maximum_Total_L0_Runs             => 2,
         Maximum_Checkpoint_Identities     => 24);
      Families                                   : constant Column_Family_Configuration_Array :=
        [Configure_Column_Family (7, [16#77#], 8, 8, 48, 3, 1),
         Configure_Test_Family (2, [16#C3#, 16#A9#], 2, 3)];
      Permuted                                   : constant Column_Family_Configuration_Array :=
        [Families (2), Families (1)];
      Different                                  : constant Column_Family_Configuration_Array :=
        [Configure_Test_Family (2, [16#C3#, 16#A9#], 2, 4), Families (1)];
      --  Six bytes deliberately changes only family 2's persisted memtable
      --  policy; its registry/name/key/value base projection remains exact.
      Different_LSM                              : constant Column_Family_Configuration_Array :=
        [Configure_Column_Family (2, [16#C3#, 16#A9#], 2, 3, 6, 1, 1), Families (1)];
      Over_Families                              : constant Column_Family_Configuration_Array :=
        [Configure_Test_Family (1, [16#78#], Maximum_Key_Bytes + 1, 1)];
      Over_Limits                                : constant Database_Limits :=
        (Default_Limits with delta Maximum_Column_Families => 1, Maximum_Live_Entries => 257);
      --  Zero is the public invalid-policy sentinel for each required database
      --  LSM authority; these variants prove rejection before publication.
      Invalid_LSM_Limits                         : constant Database_Limits :=
        (Limits with delta Maximum_Total_L0_Runs => 0);
      Invalid_Identity_Limits                    : constant Database_Limits :=
        (Limits with delta Maximum_Checkpoint_Identities => 0);
      --  These three injected sites cover every exact allocation introduced
      --  by empty-root construction before storage admission.
      Root_Allocation_Points                     :
        constant array (Positive range 1 .. 3) of Testing.Allocation_Fault_Point :=
          [Testing.Root_Checkpoint_State, Testing.Root_Checkpoint_Image, Testing.Root_Manifest_Retention];
      Database_ID                                : constant Database_Identifier := DB_ID (200);
      Manifest_ID                                : constant Identifier := ID (201);
      Transition                                 : constant Identifier := ID (202);
      --  This same-width replacement isolates last-write sequence retention;
      --  it adds no key/value capacity or public default.
      Replacement_Value                          : constant Value := To_Value ([3, 2, 1]);
      --  This stable test run identity is supplied by the operation fixture;
      --  changing it affects only the unpublished SST-builder corpus.
      First_Run_ID                               : constant Identifier := ID (223);

      procedure Expect_Live_LSM_Authority (Target : in out Database; Context_Text : String) is
         Replay, Memtable_Bytes                                    : Interfaces.Unsigned_64;
         Total_Runs, Identity_Total, Memtable_Entries, Family_Runs : Interfaces.Unsigned_32;
         Inspect                                                   : Outcome_Code;
      begin
         Testing.Live_LSM_Limits
           (Target,
            2,
            Replay,
            Total_Runs,
            Identity_Total,
            Memtable_Bytes,
            Memtable_Entries,
            Family_Runs,
            Inspect);
         if Inspect /= Success
           or else Replay /= 0
           or else Total_Runs /= Limits.Maximum_Total_L0_Runs
           or else Identity_Total /= Limits.Maximum_Checkpoint_Identities
           or else Memtable_Bytes /= 5
           or else Memtable_Entries /= 1
           or else Family_Runs /= 1
         then
            raise Program_Error with Context_Text & " lost authenticated live LSM authority";
         end if;
      end Expect_Live_LSM_Authority;

      procedure Expect_Live_Entry_Sequence (Target : in out Database; Context_Text : String) is
         Inspect : Outcome_Code;
      begin
         Testing.Live_Entry_Sequence (Target, 2, [16#00#, 16#FF#], Live_Sequence, Inspect);
         if Inspect /= Success or else Live_Sequence /= Expected_Live_Sequence then
            raise Program_Error with Context_Text & " lost the exact live-entry sequence";
         end if;
      end Expect_Live_Entry_Sequence;
   begin
      Bind_Context (Context, Backend, "manifest-family-api");
      Create
        (Item,
         Context'Access,
         Database_ID,
         Manifest_ID,
         Transition,
         Limits,
         Families,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Success, "multi-family manifest create failed");
      Expect_Live_LSM_Authority (Item, "create activation");
      declare
         --  Family 2's fixture authority is exactly one maximum 2+3-byte
         --  entry and one run, as derived by Configure_Test_Family above.
         Total_Runs, Identity_Total, Memtable_Entries, Family_Runs : Interfaces.Unsigned_32;
         Memtable_Bytes                                            : Interfaces.Unsigned_64;
      begin
         Testing.Root_LSM_Limits
           (Context,
            Manifest_ID,
            Database_ID,
            2,
            Total_Runs,
            Identity_Total,
            Memtable_Bytes,
            Memtable_Entries,
            Family_Runs,
            Result);
         if Result /= Success
           or else Total_Runs /= Limits.Maximum_Total_L0_Runs
           or else Identity_Total /= Limits.Maximum_Checkpoint_Identities
           or else Memtable_Bytes /= 5
           or else Memtable_Entries /= 1
           or else Family_Runs /= 1
         then
            raise Program_Error with "manifest-v2 root did not preserve explicit LSM authority";
         end if;
      end;

      Create
        (Retry,
         Context'Access,
         Database_ID,
         Manifest_ID,
         Transition,
         Limits,
         Permuted,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Success, "permuted canonical family retry changed persisted bytes");
      Close (Retry, Result);

      Create
        (Retry,
         Context'Access,
         Database_ID,
         Manifest_ID,
         Transition,
         Limits,
         Different,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Already_Exists, "different family configuration matched existing manifest");

      Create
        (Retry,
         Context'Access,
         Database_ID,
         ID (220),
         ID (221),
         Limits,
         Different_LSM,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Already_Exists, "different LSM policy matched the existing root");

      Open_Column_Family (Item, 2, Family_By_ID, Result);
      Expect (Result, Success, "family ID lookup failed");
      Open_Column_Family (Item, 7, Family_Seven, Result);
      Expect (Result, Success, "second family ID lookup failed");
      Open_Column_Family (Item, [16#C3#, 16#A9#], Family_By_Name, Result);
      Expect (Result, Success, "exact UTF-8 family name lookup failed");
      Open_Column_Family (Item, [16#C3#, 16#A8#], Stale_Family, Result);
      Expect (Result, Not_Found, "nonexact family name lookup succeeded");

      Begin_Transaction (Item, TX_ID (203), Txn, Result);
      Expect (Result, Success, "family-limit transaction begin failed");
      Put (Item, Txn, Family_By_ID, To_Key ([16#00#, 16#FF#]), To_Value ([1, 2, 3]), Result);
      Expect (Result, Success, "exact family key/value limits were rejected");
      Put (Item, Txn, Family_By_ID, To_Key ([1, 2, 3]), To_Value ([1]), Result);
      Expect (Result, Capacity_Exceeded, "family key limit plus one was admitted");
      Put (Item, Txn, Family_By_Name, To_Key ([1]), To_Value ([1, 2, 3, 4]), Result);
      Expect (Result, Capacity_Exceeded, "family value limit plus one was admitted");
      --  Insert in deliberately descending/noncanonical order. Snapshot
      --  construction must sort exact arbitrary bytes before SST encoding.
      Put (Item, Txn, Family_Seven, To_Key ([16#FF#]), To_Value ([30]), Result);
      Expect (Result, Success, "first snapshot-order mutation failed");
      Put (Item, Txn, Family_Seven, To_Key ([]), To_Value ([10]), Result);
      Expect (Result, Success, "second snapshot-order mutation failed");
      Put (Item, Txn, Family_Seven, To_Key ([16#80#]), To_Value ([20]), Result);
      Expect (Result, Success, "third snapshot-order mutation failed");
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "family-limit rejection changed the exact admitted mutation");
      Expected_Live_Sequence := Receipt_Sequence (Receipt);
      Expect_Live_Entry_Sequence (Item, "first commit");

      declare
         Snapshot_Entries                               : Natural;
         Snapshot_Low, Snapshot_High                    : Sequence_Number;
         Before_Batches, Before_Manifests, Before_Heads : Natural;
         After_Batches, After_Manifests, After_Heads    : Natural;
         Snapshot_Allocation_Points                     :
           constant array (Positive range 1 .. 2) of Testing.Allocation_Fault_Point :=
             [Testing.Checkpoint_References, Testing.Checkpoint_SST];
      begin
         Testing.Publication_Counts (Context, Before_Batches, Before_Manifests, Before_Heads);
         for Point of Snapshot_Allocation_Points loop
            Testing.Fail_Next_Allocation (Point);
            Testing.Build_First_SST
              (Item, 7, First_Run_ID, Snapshot_Entries, Snapshot_Low, Snapshot_High, Result);
            Expect (Result, Capacity_Exceeded, "snapshot allocation failure was not typed capacity");
         end loop;
         Testing.Publication_Counts (Context, After_Batches, After_Manifests, After_Heads);
         if After_Batches /= Before_Batches
           or else After_Manifests /= Before_Manifests
           or else After_Heads /= Before_Heads
         then
            raise Program_Error with "snapshot allocation failure published an object";
         end if;
         Testing.Build_First_SST
           (Item, 7, First_Run_ID, Snapshot_Entries, Snapshot_Low, Snapshot_High, Result);
         if Result /= Success
           or else Snapshot_Entries /= 3
           or else Snapshot_Low /= Expected_Live_Sequence
           or else Snapshot_High /= Expected_Live_Sequence
         then
            raise Program_Error with "exact first-SST snapshot construction failed";
         end if;
      end;

      Begin_Transaction (Item, TX_ID (204), Txn, Result);
      Expect (Result, Success, "replacement transaction begin failed");
      Put (Item, Txn, Family_By_ID, To_Key ([16#00#, 16#FF#]), Replacement_Value, Result);
      Expect (Result, Success, "same-key replacement was rejected");
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "same-key replacement commit failed");
      if Receipt_Sequence (Receipt) /= Expected_Live_Sequence + 1 then
         raise Program_Error with "same-key replacement did not advance by one sequence";
      end if;
      Expected_Live_Sequence := Receipt_Sequence (Receipt);
      Expect_Live_Entry_Sequence (Item, "replacement commit");

      Stale_Family := Family_By_ID;
      Close (Item, Result);
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "family-handle database reopen failed");
      Expect_Live_LSM_Authority (Item, "cacheless reopen");
      Expect_Live_Entry_Sequence (Item, "cacheless reopen");
      Begin_Transaction (Item, TX_ID (205), Txn, Result);
      Get (Item, Txn, Stale_Family, To_Key ([16#00#, 16#FF#]), Data, Result);
      Expect (Result, Invalid_State, "stale family handle survived engine incarnation change");
      Open_Column_Family (Item, [16#C3#, 16#A9#], Family_By_Name, Result);
      Get (Item, Txn, Family_By_Name, To_Key ([16#00#, 16#FF#]), Data, Result);
      Expect (Result, Success, "reopened exact-name family handle could not read persisted data");
      if Data /= Replacement_Value then
         raise Program_Error with "reopened replacement value changed";
      end if;
      Rollback (Txn, Result);

      Bind_Context (Other_Ctx, Backend, "manifest-family-other");
      Create_DB (Other, Other_Ctx'Access, DB_ID (205), ID (206), Result);
      Expect (Result, Success, "cross-database handle setup failed");
      Begin_Transaction (Other, TX_ID (207), Txn, Result);
      Put (Other, Txn, Family_By_Name, To_Key ([1]), To_Value ([1]), Result);
      Expect (Result, Invalid_State, "cross-database family handle was accepted");
      Rollback (Txn, Result);
      Close (Other, Result);
      Close (Item, Result);

      declare
         Rejected : Boolean := False;
      begin
         begin
            declare
               Ignored : constant Column_Family_Configuration :=
                 Configure_Column_Family (1, [16#78#], 1, 1, 0, 1, 1);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when Constraint_Error =>
               Rejected := True;
         end;
         if not Rejected then
            raise Program_Error with "zero memtable authority was accepted";
         end if;
      end;

      Bind_Context (Invalid_Ctx, Backend, "manifest-family-invalid-lsm-policy");
      Testing.Publication_Counts (Invalid_Ctx, Batch_Puts, Manifest_Puts, Head_Puts);
      Create
        (Invalid_Item,
         Invalid_Ctx'Access,
         DB_ID (211),
         ID (212),
         ID (213),
         Invalid_LSM_Limits,
         Families,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Invalid_State, "zero database L0 authority reached publication");
      Create
        (Invalid_Item,
         Invalid_Ctx'Access,
         DB_ID (214),
         ID (215),
         ID (216),
         Invalid_Identity_Limits,
         Families,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Invalid_State, "zero checkpoint identity authority reached publication");
      declare
         After_Batch, After_Manifest, After_Head : Natural;
      begin
         Testing.Publication_Counts (Invalid_Ctx, After_Batch, After_Manifest, After_Head);
         if After_Batch /= Batch_Puts or else After_Manifest /= Manifest_Puts or else After_Head /= Head_Puts
         then
            raise Program_Error with "invalid LSM policy published an object";
         end if;
      end;

      Bind_Context (Allocation_Ctx, Backend, "manifest-family-root-allocation");
      Testing.Publication_Counts (Allocation_Ctx, Batch_Puts, Manifest_Puts, Head_Puts);
      for Point of Root_Allocation_Points loop
         Testing.Fail_Next_Allocation (Point);
         Create
           (Allocation_Item,
            Allocation_Ctx'Access,
            DB_ID (217),
            ID (218),
            ID (219),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Capacity_Exceeded, "root allocation failure was not typed capacity");
         if Create_Receipt_Manifest_ID (Create_Info) /= Zero_Identifier then
            raise Program_Error with "root allocation failure retained a prepublication identity";
         end if;
      end loop;
      declare
         After_Batch, After_Manifest, After_Head : Natural;
      begin
         Testing.Publication_Counts (Allocation_Ctx, After_Batch, After_Manifest, After_Head);
         if After_Batch /= Batch_Puts or else After_Manifest /= Manifest_Puts or else After_Head /= Head_Puts
         then
            raise Program_Error with "root allocation failure published an object";
         end if;
      end;

      Bind_Context (Over_Ctx, Backend, "manifest-family-over-build");
      Testing.Publication_Counts (Over_Ctx, Batch_Puts, Manifest_Puts, Head_Puts);
      Create
        (Over_Item,
         Over_Ctx'Access,
         DB_ID (208),
         ID (209),
         ID (210),
         Over_Limits,
         Over_Families,
         Test_Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, Success, "persisted descriptor capacity was not allocated dynamically");
      declare
         After_Batch, After_Manifest, After_Head : Natural;
      begin
         Testing.Publication_Counts (Over_Ctx, After_Batch, After_Manifest, After_Head);
         if After_Batch /= Batch_Puts
           or else After_Manifest /= Manifest_Puts + 1
           or else After_Head /= Head_Puts + 1
         then
            raise Program_Error with "dynamic descriptor create publication counts changed";
         end if;
      end;
      Close (Over_Item, Result);
      Expect (Result, Success, "dynamic descriptor database close failed");
   end Test_Manifest_And_Family_API;

   procedure Test_Create_Publication (Backend : not null access Backends.Backend'Class) is
      Context : aliased Storage_Context;
      Item    : Database;
      Probe   : Database;
      Receipt : Create_Receipt;
      Result  : Outcome_Code;

      procedure Prepare (Prefix : String) is
      begin
         Bind_Context (Context, Backend, Prefix);
      end Prepare;
   begin
      Prepare ("create-manifest-unknown-stored");
      Testing.Arm (Context, After_Manifest_Put, Unknown_After_Entry);
      Testing.Arm (Context, Before_Manifest_Get, Definite_Failure);
      Create
        (Item,
         Context'Access,
         DB_ID (211),
         ID (212),
         ID (213),
         Default_Limits,
         Default_Families,
         Test_Operation_Timeout,
         Receipt => Receipt,
         Result  => Result);
      Expect (Result, Outcome_Unknown, "stored manifest lost response was falsely classified");
      if not Testing.Create_Receipt_Retains_Manifest (Receipt) then
         raise Program_Error with "ambiguous manifest create lost its exact owned image";
      end if;
      if Create_Receipt_Manifest_ID (Receipt) /= ID (212)
        or else Create_Receipt_Transition_ID (Receipt) /= Zero_Identifier
      then
         raise Program_Error with "pre-HEAD create receipt lost stable manifest-only identity";
      end if;
      Resolve_Create (Item, Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "stored manifest create did not resume from receipt");
      if Testing.Create_Receipt_Retains_Manifest (Receipt) then
         raise Program_Error with "conclusive create resolution retained its manifest image";
      end if;
      Close (Item, Result);

      declare
         Missing_Context : aliased Storage_Context;
         Missing_Item    : Database;
      begin
         Bind_Context (Missing_Context, Backend, "create-manifest-unknown-absent");
         Testing.Arm (Missing_Context, Before_Manifest_Put, Unknown_After_Entry);
         Create
           (Missing_Item,
            Missing_Context'Access,
            DB_ID (214),
            ID (215),
            ID (216),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Receipt,
            Result  => Result);
         Expect (Result, Outcome_Unknown, "absent ambiguous manifest was falsely classified");
         if not Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "absent ambiguous manifest lost its resumable image";
         end if;
         Resolve_Create
           (Missing_Item, Missing_Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Storage_Failure, "absent ambiguous manifest was falsely confirmed");
      end;

      declare
         Orphan_Context : aliased Storage_Context;
         Orphan_Item    : Database;
      begin
         Bind_Context (Orphan_Context, Backend, "create-orphan-manifest");
         Testing.Arm (Orphan_Context, Before_Head_Put, Definite_Failure);
         Create
           (Orphan_Item,
            Orphan_Context'Access,
            DB_ID (217),
            ID (218),
            ID (219),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Receipt,
            Result  => Result);
         Expect (Result, Storage_Failure, "pre-HEAD create failure was not definite");
         if not Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "confirmed orphan manifest lost its resumable image";
         end if;
         Open (Probe, Orphan_Context'Access, DB_ID (217), Test_Operation_Timeout, Result => Result);
         Expect (Result, Not_Found, "orphan root manifest became visible without HEAD");
         Resolve_Create
           (Orphan_Item, Orphan_Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "confirmed orphan manifest could not resume exact HEAD publication");
         if Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "resumed orphan create retained its manifest image";
         end if;
         Close (Orphan_Item, Result);
      end;

      declare
         Head_Context : aliased Storage_Context;
         Head_Item    : Database;
      begin
         Bind_Context (Head_Context, Backend, "create-head-unknown");
         Testing.Arm (Head_Context, After_Head_Put, Unknown_After_Entry);
         Testing.Arm (Head_Context, Before_Get, Definite_Failure);
         Create
           (Head_Item,
            Head_Context'Access,
            DB_ID (220),
            ID (221),
            ID (222),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Receipt,
            Result  => Result);
         Expect (Result, Outcome_Unknown, "lost root HEAD response was falsely classified");
         if not Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "unknown root HEAD lost its exact manifest image";
         end if;
         if Create_Receipt_Transition_ID (Receipt) /= ID (222) then
            raise Program_Error with "post-admission create receipt lost HEAD identity";
         end if;
         Resolve_Create (Head_Item, Head_Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "lost root HEAD response did not resolve read-only");
         if Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "resolved root HEAD retained its manifest image";
         end if;
         Close (Head_Item, Result);
      end;

      declare
         Activation_Context : aliased Storage_Context;
         Activation_Item    : Database;
      begin
         Bind_Context (Activation_Context, Backend, "create-local-activation");
         Testing.Arm (Activation_Context, Before_Local_Activation, Definite_Failure);
         Create
           (Activation_Item,
            Activation_Context'Access,
            DB_ID (223),
            ID (224),
            ID (225),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Receipt,
            Result  => Result);
         Expect (Result, Local_Activation_Failed, "durable HEAD lost local activation outcome");
         if Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "durable create retained manifest after local activation failure";
         end if;
         Open
           (Activation_Item,
            Activation_Context'Access,
            DB_ID (223),
            Test_Operation_Timeout,
            Result => Result);
         Expect (Result, Success, "durable create did not recover through ordinary open");
         Close (Activation_Item, Result);
      end;

      declare
         Later_Context : aliased Storage_Context;
         Writer        : Database;
         Retry         : Database;
         Txn           : Transaction;
         Commit_Info   : Commit_Receipt;
         Create_Info   : Create_Receipt;
         Family        : Column_Family;
      begin
         Bind_Context (Later_Context, Backend, "create-later-commit");
         Create
           (Writer,
            Later_Context'Access,
            DB_ID (150),
            ID (151),
            ID (152),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Success, "later-commit create setup failed");
         Open_Column_Family (Writer, 1, Family, Result);
         Begin_Transaction (Writer, TX_ID (153), Txn, Result);
         Put (Writer, Txn, Family, To_Key ([1]), To_Value ([2]), Result);
         Commit (Writer, Txn, Test_Operation_Timeout, Receipt => Commit_Info, Result => Result);
         Expect (Result, Success, "later-commit setup publication failed");
         Close (Writer, Result);

         Create
           (Retry,
            Later_Context'Access,
            DB_ID (150),
            ID (151),
            ID (152),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Success, "idempotent create rejected a reachable later commit");
         if Visible (Retry) /= 1 then
            raise Program_Error with "idempotent create did not activate the later commit";
         end if;
         Close (Retry, Result);
      end;

      declare
         Later_Context : aliased Storage_Context;
         Lost_Item     : Database;
         Writer        : Database;
         Txn           : Transaction;
         Commit_Info   : Commit_Receipt;
         Family        : Column_Family;
      begin
         Bind_Context (Later_Context, Backend, "resolve-create-later-chain");
         Testing.Arm (Later_Context, After_Head_Put, Unknown_After_Entry);
         Testing.Arm (Later_Context, Before_Get, Definite_Failure);
         Create
           (Lost_Item,
            Later_Context'Access,
            DB_ID (154),
            ID (155),
            ID (156),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Receipt,
            Result  => Result);
         Expect (Result, Outcome_Unknown, "later-chain create did not retain an unknown receipt");
         if not Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "later-chain create lost its exact manifest image";
         end if;
         Open (Writer, Later_Context'Access, DB_ID (154), Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "later-chain writer open failed");
         Open_Column_Family (Writer, 1, Family, Result);
         for Number in Byte range 157 .. 158 loop
            Begin_Transaction (Writer, TX_ID (Number), Txn, Result);
            Put (Writer, Txn, Family, To_Key ([Number]), To_Value ([Number]), Result);
            Commit (Writer, Txn, Test_Operation_Timeout, Receipt => Commit_Info, Result => Result);
            Expect (Result, Success, "later-chain commit failed");
         end loop;
         Close (Writer, Result);
         Resolve_Create (Lost_Item, Later_Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "create receipt did not resolve through two later transitions");
         if Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "later-chain resolution retained its manifest image";
         end if;
         if Visible (Lost_Item) /= 2 then
            raise Program_Error with "resolved create did not activate the complete later chain";
         end if;
         Close (Lost_Item, Result);
      end;

      declare
         Missing_Context : aliased Storage_Context;
         Missing_Item    : Database;
      begin
         Bind_Context (Missing_Context, Backend, "resolve-create-missing-manifest");
         Testing.Arm (Missing_Context, Before_Head_Put, Definite_Failure);
         Create
           (Missing_Item,
            Missing_Context'Access,
            DB_ID (159),
            ID (160),
            ID (161),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Receipt,
            Result  => Result);
         Expect (Result, Storage_Failure, "missing-manifest resume setup failed");
         Testing.Remove_Manifest (Missing_Context, ID (160), Result);
         Expect (Result, Success, "confirmed manifest removal fixture failed");
         Resolve_Create
           (Missing_Item, Missing_Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "missing confirmed manifest was trusted from receipt bytes");
         if Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "corrupt missing-manifest receipt retained its image";
         end if;
      end;

      declare
         Different_Context : aliased Storage_Context;
         Different_Item    : Database;
      begin
         Bind_Context (Different_Context, Backend, "resolve-create-different-manifest");
         Testing.Arm (Different_Context, After_Head_Put, Unknown_After_Entry);
         Testing.Arm (Different_Context, Before_Get, Definite_Failure);
         Create
           (Different_Item,
            Different_Context'Access,
            DB_ID (162),
            ID (163),
            ID (164),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Receipt,
            Result  => Result);
         Expect (Result, Outcome_Unknown, "different-manifest resume setup failed");
         Testing.Rewrite_Manifest (Different_Context, ID (163), DB_ID (162), DB_ID (165), False, Result);
         Expect (Result, Success, "different manifest fixture rewrite failed");
         Resolve_Create
           (Different_Item, Different_Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "different immutable manifest was trusted from receipt bytes");
         if Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "corrupt different-manifest receipt retained its image";
         end if;
      end;

      declare
         Unavailable_Context : aliased Storage_Context;
         Unavailable_Item    : Database;
      begin
         Bind_Context (Unavailable_Context, Backend, "resolve-create-manifest-unavailable");
         Testing.Arm (Unavailable_Context, After_Head_Put, Unknown_After_Entry);
         Testing.Arm (Unavailable_Context, Before_Get, Definite_Failure);
         Create
           (Unavailable_Item,
            Unavailable_Context'Access,
            DB_ID (166),
            ID (167),
            ID (168),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Receipt,
            Result  => Result);
         Expect (Result, Outcome_Unknown, "unavailable-manifest resume setup failed");
         Testing.Arm (Unavailable_Context, Before_Manifest_Get, Definite_Failure);
         Resolve_Create
           (Unavailable_Item, Unavailable_Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Outcome_Unknown, "unavailable confirmed manifest was falsely classified");
         if not Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "transient manifest read lost its resumable image";
         end if;
         Resolve_Create
           (Unavailable_Item, Unavailable_Context'Access, Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "available confirmed manifest did not resume after transient failure");
         if Testing.Create_Receipt_Retains_Manifest (Receipt) then
            raise Program_Error with "resumed transient create retained its manifest image";
         end if;
         Close (Unavailable_Item, Result);
      end;

      declare
         Retry_Context : aliased Storage_Context;
         First         : Database;
         Retry         : Database;
         Create_Info   : Create_Receipt;
      begin
         Bind_Context (Retry_Context, Backend, "create-precondition-unavailable");
         Create
           (First,
            Retry_Context'Access,
            DB_ID (182),
            ID (183),
            ID (184),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Success, "precondition-unavailable create setup failed");
         Close (First, Result);
         Testing.Arm (Retry_Context, Before_Manifest_Get, Definite_Failure);
         Create
           (Retry,
            Retry_Context'Access,
            DB_ID (182),
            ID (183),
            ID (184),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Outcome_Unknown, "manifest precondition plus unavailable read was conclusive");
         Testing.Arm (Retry_Context, Before_Get, Definite_Failure);
         Create
           (Retry,
            Retry_Context'Access,
            DB_ID (182),
            ID (183),
            ID (184),
            Default_Limits,
            Default_Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Outcome_Unknown, "HEAD precondition plus unavailable read was conclusive");
      end;
   end Test_Create_Publication;

   procedure Test_Lower_Live_Budgets (Backend : not null access Backends.Backend'Class) is
      procedure Run_Case
        (Prefix        : String;
         Database_Last : Byte;
         Live_Entries  : Interfaces.Unsigned_32;
         Live_Bytes    : Interfaces.Unsigned_64;
         Context_Text  : String)
      is
         Context                                    : aliased Storage_Context;
         Item                                       : Database;
         Txn                                        : Transaction;
         Reader                                     : Transaction;
         Receipt                                    : Commit_Receipt;
         Create_Info                                : Create_Receipt;
         Family                                     : Column_Family;
         Data                                       : Value;
         Result                                     : Outcome_Code;
         Before_Batch, Before_Manifest, Before_Head : Natural;
         After_Batch, After_Manifest, After_Head    : Natural;
         --  Live_Entries/Live_Bytes are the case's persisted authority; the
         --  single family admits an exact two-byte key plus three-byte value.
         --  The following one-over write must fail without publication.
         Limits                                     : constant Database_Limits :=
           (Default_Limits
            with delta
              Maximum_Column_Families  => 1,
              Maximum_Live_Entries     => Live_Entries,
              Maximum_Live_State_Bytes => Live_Bytes);
         Families                                   : constant Column_Family_Configuration_Array :=
           [Configure_Test_Family (1, [16#61#], 2, 3)];
      begin
         Bind_Context (Context, Backend, Prefix);
         Create
           (Item,
            Context'Access,
            DB_ID (Database_Last),
            ID (Database_Last + 1),
            ID (Database_Last + 2),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Success, Context_Text & " create failed");
         Open_Column_Family (Item, 1, Family, Result);
         Begin_Transaction (Item, TX_ID (Database_Last + 3), Txn, Result);
         Put (Item, Txn, Family, To_Key ([16#00#, 16#FF#]), To_Value ([1, 2, 3]), Result);
         Expect (Result, Success, Context_Text & " exact mutation rejected");
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Success, Context_Text & " exact live budget rejected");

         Testing.Publication_Counts (Context, Before_Batch, Before_Manifest, Before_Head);
         Begin_Transaction (Item, TX_ID (Database_Last + 4), Txn, Result);
         Put (Item, Txn, Family, To_Key ([2]), To_Value ([4]), Result);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Capacity_Exceeded, Context_Text & " one-over mutation was published");
         Rollback (Txn, Result);
         Expect (Result, Invalid_State, Context_Text & " admitted one-over transaction was not consumed");
         Testing.Publication_Counts (Context, After_Batch, After_Manifest, After_Head);
         if After_Batch /= Before_Batch
           or else After_Manifest /= Before_Manifest
           or else After_Head /= Before_Head
         then
            raise Program_Error with Context_Text & " one-over changed object storage";
         end if;

         Begin_Transaction (Item, TX_ID (Database_Last + 5), Reader, Result);
         Get (Item, Reader, Family, To_Key ([16#00#, 16#FF#]), Data, Result);
         Expect (Result, Success, Context_Text & " exact value was not retained atomically");
         Get (Item, Reader, Family, To_Key ([2]), Data, Result);
         Expect (Result, Not_Found, Context_Text & " rejected value entered live state");
         Rollback (Reader, Result);
         Close (Item, Result);
         Open (Item, Context'Access, DB_ID (Database_Last), Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, Context_Text & " exact state did not reopen");
         Close (Item, Result);
      end Run_Case;

      procedure Run_Projection_Case is
         Context                                    : aliased Storage_Context;
         Item                                       : Database;
         Txn                                        : Transaction;
         Reader                                     : Transaction;
         Group                                      : Transaction_Array (1 .. 2);
         Receipt                                    : Commit_Receipt;
         Receipts                                   : Commit_Receipt_Array (Group'Range);
         Create_Info                                : Create_Receipt;
         Family                                     : Column_Family;
         Data                                       : Value;
         Result                                     : Outcome_Code;
         Batch_Before, Manifest_Before, Head_Before : Natural;
         Batch_After, Manifest_After, Head_After    : Natural;
         --  One five-byte live entry is the exact persisted projection budget.
         --  Old/New keys make replacement versus growth observable; these are
         --  boundary fixtures, not default family sizes.
         Limits                                     : constant Database_Limits :=
           (Default_Limits
            with delta
              Maximum_Column_Families  => 1,
              Maximum_Live_Entries     => 1,
              Maximum_Live_State_Bytes => 5);
         Families                                   : constant Column_Family_Configuration_Array :=
           [Configure_Test_Family (1, [16#61#], 2, 3)];
         Old_Key                                    : constant Key := To_Key ([16#00#, 16#FF#]);
         New_Key                                    : constant Key := To_Key ([16#80#, 16#81#]);
      begin
         Bind_Context (Context, Backend, "live-cap-projection");
         Create
           (Item,
            Context'Access,
            DB_ID (169),
            ID (170),
            ID (171),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Success, "live-cap projection create failed");
         Open_Column_Family (Item, 1, Family, Result);

         Begin_Transaction (Item, TX_ID (172), Txn, Result);
         Put (Item, Txn, Family, Old_Key, To_Value ([1, 2, 3]), Result);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "live-cap initial exact state failed");

         Testing.Publication_Counts (Context, Batch_Before, Manifest_Before, Head_Before);
         Begin_Transaction (Item, TX_ID (173), Txn, Result);
         Put (Item, Txn, Family, Old_Key, To_Value ([3, 2, 1]), Result);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "overwrite at exact entry and byte cap was rejected");
         Testing.Publication_Counts (Context, Batch_After, Manifest_After, Head_After);
         if Batch_After /= Batch_Before + 1
           or else Manifest_After /= Manifest_Before
           or else Head_After /= Head_Before + 1
         then
            raise Program_Error with "exact-cap overwrite publication counters were inconsistent";
         end if;

         Begin_Transaction (Item, TX_ID (174), Group (1), Result);
         Delete (Item, Group (1), Family, Old_Key, Result);
         Begin_Transaction (Item, TX_ID (175), Group (2), Result);
         Put (Item, Group (2), Family, New_Key, To_Value ([4, 5, 6]), Result);
         Testing.Publication_Counts (Context, Batch_Before, Manifest_Before, Head_Before);
         Commit_Group (Item, ID (176), Group, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Success, "delete-plus-put group at exact live caps was rejected");
         Testing.Publication_Counts (Context, Batch_After, Manifest_After, Head_After);
         if Batch_After /= Batch_Before + 1
           or else Manifest_After /= Manifest_Before
           or else Head_After /= Head_Before + 1
         then
            raise Program_Error with "exact-cap group publication counters were inconsistent";
         end if;
         if Visible (Item) /= 4 then
            raise Program_Error with "exact-cap group assigned an inconsistent sequence range";
         end if;

         Begin_Transaction (Item, TX_ID (177), Reader, Result);
         Get (Item, Reader, Family, Old_Key, Data, Result);
         Expect (Result, Not_Found, "exact-cap group retained its deleted key");
         Get (Item, Reader, Family, New_Key, Data, Result);
         Expect (Result, Success, "exact-cap group lost its replacement key");
         if Data /= To_Value ([4, 5, 6]) then
            raise Program_Error with "exact-cap group installed the wrong replacement value";
         end if;
         Rollback (Reader, Result);

         Begin_Transaction (Item, TX_ID (179), Group (1), Result);
         Put (Item, Group (1), Family, Old_Key, To_Value ([7, 8, 9]), Result);
         Begin_Transaction (Item, TX_ID (180), Group (2), Result);
         Delete (Item, Group (2), Family, New_Key, Result);
         Testing.Publication_Counts (Context, Batch_Before, Manifest_Before, Head_Before);
         Commit_Group (Item, ID (181), Group, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Success, "put-before-delete group at exact live caps was rejected");
         Testing.Publication_Counts (Context, Batch_After, Manifest_After, Head_After);
         if Batch_After /= Batch_Before + 1
           or else Manifest_After /= Manifest_Before
           or else Head_After /= Head_Before + 1
         then
            raise Program_Error with "put-before-delete publication counters were inconsistent";
         end if;
         if Visible (Item) /= 6 then
            raise Program_Error with "put-before-delete group assigned an inconsistent sequence range";
         end if;
         Begin_Transaction (Item, TX_ID (182), Reader, Result);
         Get (Item, Reader, Family, Old_Key, Data, Result);
         Expect (Result, Success, "put-before-delete group lost its replacement key");
         if Data /= To_Value ([7, 8, 9]) then
            raise Program_Error with "put-before-delete group installed the wrong value";
         end if;
         Get (Item, Reader, Family, New_Key, Data, Result);
         Expect (Result, Not_Found, "put-before-delete group retained its deleted key");
         Rollback (Reader, Result);

         Close (Item, Result);
         Open (Item, Context'Access, DB_ID (169), Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "exact-cap projected state did not reopen");
         Open_Column_Family (Item, 1, Family, Result);
         Begin_Transaction (Item, TX_ID (178), Reader, Result);
         Get (Item, Reader, Family, Old_Key, Data, Result);
         Expect (Result, Success, "reopen lost the put-before-delete replacement key");
         if Data /= To_Value ([7, 8, 9]) then
            raise Program_Error with "reopen changed the put-before-delete replacement value";
         end if;
         Get (Item, Reader, Family, New_Key, Data, Result);
         Expect (Result, Not_Found, "reopen restored the put-before-delete deleted key");
         Rollback (Reader, Result);
         Close (Item, Result);
      end Run_Projection_Case;
   begin
      Run_Case ("live-entry-budget", 180, 1, 16, "lower live-entry budget");
      Run_Case ("live-byte-budget", 186, 4, 5, "lower live-byte budget");
      Run_Projection_Case;
   end Test_Lower_Live_Budgets;

   procedure Test_Recovery_Format_Edges (Backend : not null access Backends.Backend'Class) is
      Result : Outcome_Code;
   begin
      declare
         Context                                    : aliased Storage_Context;
         Item                                       : Database;
         Batch_Before, Manifest_Before, Head_Before : Natural;
         Batch_After, Manifest_After, Head_After    : Natural;
      begin
         Bind_Context (Context, Backend, "open-v1-unsupported");
         Testing.Install_Head (Context, DB_ID (226), Zero_Identifier, ID (227), True, Result);
         Expect (Result, Success, "legacy HEAD fixture installation failed");
         Testing.Publication_Counts (Context, Batch_Before, Manifest_Before, Head_Before);
         Open (Item, Context'Access, DB_ID (226), Test_Operation_Timeout, Result => Result);
         Expect (Result, Unsupported_Format, "operational Open accepted legacy HEAD v1");
         Testing.Publication_Counts (Context, Batch_After, Manifest_After, Head_After);
         if Batch_After /= Batch_Before
           or else Manifest_After /= Manifest_Before
           or else Head_After /= Head_Before
         then
            raise Program_Error with "legacy HEAD inspection caused storage writes";
         end if;
      end;

      declare
         Context                                    : aliased Storage_Context;
         Item                                       : Database;
         Batch_Before, Manifest_Before, Head_Before : Natural;
         Batch_After, Manifest_After, Head_After    : Natural;
      begin
         Bind_Context (Context, Backend, "open-unknown-head-version");
         Testing.Install_Unsupported_Head (Context, DB_ID (179), ID (180), ID (181), Result);
         Expect (Result, Success, "unknown-version HEAD fixture installation failed");
         Testing.Publication_Counts (Context, Batch_Before, Manifest_Before, Head_Before);
         Open (Item, Context'Access, DB_ID (179), Test_Operation_Timeout, Result => Result);
         Expect (Result, Unsupported_Format, "operational Open misclassified an unknown HEAD version");
         Testing.Publication_Counts (Context, Batch_After, Manifest_After, Head_After);
         if Batch_After /= Batch_Before
           or else Manifest_After /= Manifest_Before
           or else Head_After /= Head_Before
         then
            raise Program_Error with "unknown HEAD version caused storage writes";
         end if;
      end;

      declare
         Context                                    : aliased Storage_Context;
         Item                                       : Database;
         Batch_Before, Manifest_Before, Head_Before : Natural;
         Batch_After, Manifest_After, Head_After    : Natural;
         Before                                     : Ownership_Snapshot;
      begin
         Bind_Context (Context, Backend, "open-invalid-v2-head");
         Testing.Install_Invalid_V2_Head (Context, DB_ID (185), ID (186), ID (187), Result);
         Expect (Result, Success, "invalid-v2 HEAD fixture installation failed");
         Before := Current_Ownership;
         Testing.Publication_Counts (Context, Batch_Before, Manifest_Before, Head_Before);
         Open (Item, Context'Access, DB_ID (185), Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "operational Open misclassified malformed known HEAD v2");
         Expect_No_Owner_Growth (Before, "malformed HEAD open");
         Testing.Publication_Counts (Context, Batch_After, Manifest_After, Head_After);
         if Batch_After /= Batch_Before
           or else Manifest_After /= Manifest_Before
           or else Head_After /= Head_Before
         then
            raise Program_Error with "malformed known HEAD v2 caused storage writes";
         end if;
      end;

      declare
         Context : aliased Storage_Context;
         Item    : Database;
         Before  : Ownership_Snapshot;
      begin
         Bind_Context (Context, Backend, "open-missing-manifest");
         Testing.Install_Head (Context, DB_ID (228), ID (229), ID (230), False, Result);
         Expect (Result, Success, "missing-manifest HEAD fixture installation failed");
         Before := Current_Ownership;
         Open (Item, Context'Access, DB_ID (228), Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "HEAD with missing latest manifest was accepted");
         Expect_No_Owner_Growth (Before, "missing manifest open");
      end;

      declare
         Context : aliased Storage_Context;
         Item    : Database;
         Before  : Ownership_Snapshot;
      begin
         Bind_Context (Context, Backend, "open-corrupt-manifest");
         Create_DB (Item, Context'Access, DB_ID (231), ID (232), Result);
         Close (Item, Result);
         Testing.Corrupt_Manifest (Context, Manifest_ID_For (ID (232)), Result);
         Expect (Result, Success, "manifest corruption fixture installation failed");
         Before := Current_Ownership;
         Open (Item, Context'Access, DB_ID (231), Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "corrupt latest manifest was accepted");
         Expect_No_Owner_Growth (Before, "corrupt manifest open");
      end;

      declare
         Context : aliased Storage_Context;
         Item    : Database;
      begin
         Bind_Context (Context, Backend, "open-wrong-db-manifest");
         Create_DB (Item, Context'Access, DB_ID (233), ID (234), Result);
         Close (Item, Result);
         Testing.Rewrite_Manifest
           (Context, Manifest_ID_For (ID (234)), DB_ID (233), DB_ID (235), False, Result);
         Expect (Result, Success, "wrong-database manifest fixture installation failed");
         Open (Item, Context'Access, DB_ID (233), Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "wrong-database latest manifest was accepted");
      end;

      declare
         Context : aliased Storage_Context;
         Item    : Database;
         Before  : Ownership_Snapshot;
      begin
         Bind_Context (Context, Backend, "open-runtime-sized-manifest");
         Create_DB (Item, Context'Access, DB_ID (236), ID (237), Result);
         Close (Item, Result);
         Testing.Rewrite_Manifest
           (Context, Manifest_ID_For (ID (237)), DB_ID (236), Zero_Database_ID, True, Result);
         Expect (Result, Success, "runtime-sized manifest fixture installation failed");
         Before := Current_Ownership;
         Open (Item, Context'Access, DB_ID (236), Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "valid runtime-sized manifest was not activated");
         Close (Item, Result);
         Expect (Result, Success, "runtime-sized manifest close failed");
         Expect_No_Owner_Growth (Before, "runtime-sized manifest open/close");
      end;

      declare
         Context : aliased Storage_Context;
         Item    : Database;
         Txn     : Transaction;
         Receipt : Commit_Receipt;
         Before  : Ownership_Snapshot;
      begin
         Bind_Context (Context, Backend, "open-batch-unknown-family");
         Create_DB (Item, Context'Access, DB_ID (244), ID (245), Result);
         Begin_Transaction (Item, TX_ID (246), Txn, Result);
         Put (Item, Txn, 8, To_Key ([1]), To_Value ([2]), Result);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "unknown-family recovery fixture commit failed");
         Close (Item, Result);
         Testing.Restrict_Manifest (Context, Manifest_ID_For (ID (245)), DB_ID (244), True, 0, 0, Result);
         Expect (Result, Success, "unknown-family recovery fixture rewrite failed");
         Before := Current_Ownership;
         Open (Item, Context'Access, DB_ID (244), Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "batch referencing an unregistered family was partially applied");
         Expect_No_Owner_Growth (Before, "unknown-family batch recovery");
      end;

      declare
         Context : aliased Storage_Context;
         Item    : Database;
         Txn     : Transaction;
         Receipt : Commit_Receipt;
         Before  : Ownership_Snapshot;
      begin
         Bind_Context (Context, Backend, "open-batch-family-limit");
         Create_DB (Item, Context'Access, DB_ID (247), ID (248), Result);
         Begin_Transaction (Item, TX_ID (249), Txn, Result);
         Put (Item, Txn, 2, To_Key ([1, 2]), To_Value ([3]), Result);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "family-limit recovery fixture commit failed");
         Close (Item, Result);
         Testing.Restrict_Manifest (Context, Manifest_ID_For (ID (248)), DB_ID (247), False, 2, 1, Result);
         Expect (Result, Success, "family-limit recovery fixture rewrite failed");
         Before := Current_Ownership;
         Open (Item, Context'Access, DB_ID (247), Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "batch exceeding recovered family limits was partially applied");
         Expect_No_Owner_Growth (Before, "family-limit batch recovery");
      end;

      declare
         Context     : aliased Storage_Context;
         Item        : Database;
         Create_Info : Create_Receipt;
         --  A persisted manifest-history bound of two admits root plus one
         --  successor; installing two successors is the exact one-over recovery
         --  corruption fixture.
         Limits      : constant Database_Limits :=
           (Default_Limits with delta Maximum_Column_Families => 3, Maximum_Manifest_History => 2);
         Families    : constant Column_Family_Configuration_Array :=
           [Configure_Test_Family (1, [16#61#], 1, 1)];
      begin
         Bind_Context (Context, Backend, "open-overlong-manifest-chain");
         Create
           (Item,
            Context'Access,
            DB_ID (238),
            ID (239),
            ID (240),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Success, "manifest-chain root create failed");
         Close (Item, Result);
         Testing.Extend_Manifest_Chain (Context, DB_ID (238), ID (239), 2, Result);
         Expect (Result, Success, "overlong manifest-chain fixture installation failed");
         Open (Item, Context'Access, DB_ID (238), Test_Operation_Timeout, Result => Result);
         Expect (Result, Corrupt, "manifest history cap plus one was not classified corrupt");
      end;

      declare
         Context     : aliased Storage_Context;
         Item        : Database;
         Create_Info : Create_Receipt;
         --  The peer case uses the same persisted history bound of two and
         --  installs exactly one successor, proving the inclusive boundary.
         Limits      : constant Database_Limits :=
           (Default_Limits with delta Maximum_Column_Families => 2, Maximum_Manifest_History => 2);
         Families    : constant Column_Family_Configuration_Array :=
           [Configure_Test_Family (1, [16#61#], 1, 1)];
      begin
         Bind_Context (Context, Backend, "open-exact-manifest-chain");
         Create
           (Item,
            Context'Access,
            DB_ID (241),
            ID (242),
            ID (243),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Expect (Result, Success, "exact manifest-chain root create failed");
         Close (Item, Result);
         Testing.Extend_Manifest_Chain (Context, DB_ID (241), ID (242), 1, Result);
         Expect (Result, Success, "exact manifest-chain fixture installation failed");
         Open (Item, Context'Access, DB_ID (241), Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "manifest history exact cap was rejected");
         Close (Item, Result);
      end;

      declare
         Context : aliased Storage_Context;
         Item    : Database;
         Stop    : aliased Flyology.Cancellation.Token;
         Before  : Ownership_Snapshot;
      begin
         Bind_Context (Context, Backend, "open-cancel-timeout-ownership");
         Create_DB (Item, Context'Access, DB_ID (250), ID (251), Result);
         Expect (Result, Success, "cancel/timeout ownership fixture create failed");
         Close (Item, Result);
         Stop.Request;
         Before := Current_Ownership;
         Open (Item, Context'Access, DB_ID (250), Test_Operation_Timeout, Stop'Access, Result);
         Expect (Result, Cancelled, "cancelled open was not classified before activation");
         Expect_No_Owner_Growth (Before, "cancelled open");
         Before := Current_Ownership;
         Open (Item, Context'Access, DB_ID (250), Expired_Operation_Timeout, Result => Result);
         Expect (Result, Timed_Out, "expired open was not classified before activation");
         Expect_No_Owner_Growth (Before, "expired open");
      end;
   end Test_Recovery_Format_Edges;

   procedure Test_Faults (Backend : not null access Backends.Backend'Class; Prefix : String; Tag : Byte) is
      Context            : aliased Storage_Context;
      Item               : Database;
      Other              : Database;
      Retry              : Database;
      Rival              : Database;
      Txn                : Transaction;
      Receipt            : Commit_Receipt;
      Unaccepted_Receipt : Commit_Receipt;
      Result             : Outcome_Code;
      Data               : Value;
      Stop               : aliased Flyology.Cancellation.Token;
      --  One-byte deterministic key/value and Tag-derived database ID isolate
      --  publication-certainty transitions; they carry no application policy.
      Key_A              : constant Key := To_Key ([16#61#]);
      Value_A            : constant Value := To_Value ([16#62#]);
      Database_ID        : constant Database_Identifier := DB_ID (Tag);
   begin
      Bind_Context (Context, Backend, Prefix);
      Testing.Arm (Context, After_Head_Put, Unknown_After_Entry);
      Testing.Arm (Context, Before_Get, Definite_Failure);
      Create_DB (Item, Context'Access, Database_ID, ID (Tag + 1), Result);
      Expect (Result, Outcome_Unknown, "lost create response was falsely classified without a read");
      Create_DB (Retry, Context'Access, Database_ID, ID (Tag + 1), Result);
      Expect (Result, Success, "identical create retry was not idempotent");
      Close (Retry, Result);
      Expect (Result, Success, "identical create retry did not close");
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "database did not open after identical create retry");
      Create_DB (Rival, Context'Access, Database_ID, ID (Tag + 13), Result);
      Expect (Result, Already_Exists, "different creator was mistaken for own lost response");

      Begin_Transaction (Item, TX_ID (Tag + 2), Txn, Result);
      Put (Item, Txn, 1, Key_A, Value_A, Result);
      Testing.Arm (Context, Before_Batch_Put, Definite_Failure);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Storage_Failure, "pre-batch failure was not definite");
      if Receipt_Transaction_ID (Receipt) /= TX_ID (Tag + 2)
        or else Receipt_Batch_ID (Receipt) /= ID (Tag + 2)
        or else Receipt_Outcome (Receipt) /= Storage_Failure
      then
         raise Program_Error with "admitted definite batch failure lost its receipt identity";
      end if;
      Rollback (Txn, Result);
      Expect (Result, Invalid_State, "admitted definite batch failure did not consume transaction");
      Begin_Transaction (Item, TX_ID (Tag + 2), Txn, Result);
      Expect (Result, Conflict, "admitted definite batch identity was replayable");
      if Visible (Item) /= 0 then
         raise Program_Error with "pre-batch failure changed visibility";
      end if;

      Begin_Transaction (Item, TX_ID (Tag + 3), Txn, Result);
      Put (Item, Txn, 1, Key_A, Value_A, Result);
      Testing.Arm (Context, After_Batch_Put, Unknown_After_Entry);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "unknown batch put was not byte-reconciled before HEAD");

      Begin_Transaction (Item, TX_ID (Tag + 4), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#63#]), Value_A, Result);
      Testing.Arm (Context, Before_Head_Put, Definite_Failure);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Storage_Failure, "pre-HEAD failure was not definite");
      if Visible (Item) /= 1 then
         raise Program_Error with "orphan batch became visible";
      end if;
      declare
         Transactions : Transaction_Array (1 .. 2);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         for Index in Transactions'Range loop
            Begin_Transaction (Item, TX_ID (Tag + Byte (13 + Index)), Transactions (Index), Result);
            Put (Item, Transactions (Index), 1, To_Key ([Byte (13 + Index)]), Value_A, Result);
         end loop;
         Commit_Group
           (Item, ID (Tag + 4), Transactions, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Conflict, "group reused an admitted orphan singleton identity");
         for Index in Transactions'Range loop
            Rollback (Transactions (Index), Result);
            Expect (Result, Success, "orphan cross-kind rejection consumed group transaction");
         end loop;
      end;
      Begin_Transaction (Item, TX_ID (Tag + 4), Txn, Result);
      Expect (Result, Conflict, "admitted orphan singleton identity was replayable");
      Close (Item, Result);
      Expect (Result, Success, "orphan replay setup did not close");
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "orphan replay setup did not reopen");
      Begin_Transaction (Item, TX_ID (Tag + 4), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#63#]), Value_A, Result);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Conflict, "orphan batch was replayed after local reservation loss");
      Rollback (Txn, Result);
      Expect (Result, Invalid_State, "admitted orphan replay did not consume transaction");
      Close (Item, Result);
      Expect (Result, Success, "orphan replay fence did not close");
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "orphan replay fence did not recover");

      declare
         Reader            : Transaction;
         Singleton         : Transaction;
         Group             : Transaction_Array (1 .. 2);
         Rejected_Receipt  : Commit_Receipt;
         Rejected_Receipts : Commit_Receipt_Array (Group'Range);
      begin
         Begin_Transaction (Item, TX_ID (Tag + 20), Reader, Result);
         Expect (Result, Success, "uncertain-state active reader setup failed");
         Begin_Transaction (Item, TX_ID (Tag + 21), Singleton, Result);
         Put (Item, Singleton, 1, To_Key ([16#71#]), Value_A, Result);
         for Index in Group'Range loop
            Begin_Transaction (Item, TX_ID (Tag + Byte (21 + Index)), Group (Index), Result);
            Put (Item, Group (Index), 1, To_Key ([Byte (16#71# + Index)]), Value_A, Result);
         end loop;

         Begin_Transaction (Item, TX_ID (Tag + 5), Txn, Result);
         Put (Item, Txn, 2, To_Key ([16#64#]), Value_A, Result);
         Testing.Arm (Context, After_Head_Put, Unknown_After_Entry);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Outcome_Unknown, "lost HEAD response was not ambiguous");
         if Receipt_Outcome (Receipt) /= Outcome_Unknown then
            raise Program_Error with "ambiguous receipt lost its outcome";
         end if;
         if not Testing.Receipt_Retains_Image (Receipt) then
            raise Program_Error with "ambiguous receipt did not retain its exact batch image";
         end if;

         Get (Item, Reader, 1, Key_A, Data, Result);
         Expect (Result, Outcome_Unknown, "active reader bypassed uncertain writer state");
         Get (Item, Group (1), 1, To_Key ([16#72#]), Data, Result);
         Expect (Result, Outcome_Unknown, "buffered own write bypassed uncertain writer state");
         Put (Item, Group (1), 1, To_Key ([16#74#]), Value_A, Result);
         Expect (Result, Outcome_Unknown, "active transaction buffered Put while uncertain");
         Delete (Item, Group (1), 1, To_Key ([16#72#]), Result);
         Expect (Result, Outcome_Unknown, "active transaction buffered Delete while uncertain");
         Commit (Item, Singleton, Test_Operation_Timeout, Receipt => Rejected_Receipt, Result => Result);
         Expect (Result, Outcome_Unknown, "singleton commit entered admission while uncertain");
         if Receipt_Transaction_ID (Rejected_Receipt) /= Zero_Transaction_ID
           or else Receipt_Batch_ID (Rejected_Receipt) /= Zero_Identifier
         then
            raise Program_Error with "uncertain singleton rejection returned an admitted receipt";
         end if;
         Rollback (Singleton, Result);
         Expect (Result, Success, "uncertain singleton rejection consumed its transaction");
         Commit_Group
           (Item,
            ID (Tag + 24),
            Group,
            Test_Operation_Timeout,
            Receipts => Rejected_Receipts,
            Result   => Result);
         Expect (Result, Outcome_Unknown, "group commit entered admission while uncertain");
         for Index in Group'Range loop
            if Receipt_Transaction_ID (Rejected_Receipts (Index)) /= Zero_Transaction_ID
              or else Receipt_Batch_ID (Rejected_Receipts (Index)) /= Zero_Identifier
            then
               raise Program_Error with "uncertain group rejection returned an admitted receipt";
            end if;
            Rollback (Group (Index), Result);
            Expect (Result, Success, "uncertain group rejection consumed a transaction");
         end loop;
         Rollback (Reader, Result);
         Expect (Result, Success, "uncertain active reader could not be cleaned up");
      end;
      Begin_Transaction (Item, TX_ID (Tag + 9), Txn, Result);
      Expect (Result, Outcome_Unknown, "uncertain publication did not block the writer");
      Close (Item, Result);
      Expect (Result, Success, "uncertain database did not close cleanly");
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "uncertain database did not recover after reopen");
      Resolve (Item, Receipt, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "self-contained receipt did not resolve after reopen");
      if Testing.Receipt_Retains_Image (Receipt) then
         raise Program_Error with "conclusively resolved receipt retained its batch image";
      end if;
      if Receipt_Sequence (Receipt) /= 2 then
         raise Program_Error with "resolved receipt lost its sequence";
      end if;
      Begin_Transaction (Item, TX_ID (Tag + 25), Txn, Result);
      for Key_Byte in Byte range 16#71# .. 16#74# loop
         Get (Item, Txn, 1, To_Key ([Key_Byte]), Data, Result);
         Expect (Result, Not_Found, "uncertain rejected transaction changed recovered state");
      end loop;
      Rollback (Txn, Result);

      Begin_Transaction (Item, TX_ID (Tag + 11), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#68#]), Value_A, Result);
      Testing.Arm (Context, Before_Head_Put, Unknown_After_Entry);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Outcome_Unknown, "unaccepted HEAD ambiguity was not retained");
      Resolve (Item, Receipt, Test_Operation_Timeout, Result => Result);
      Expect (Result, Outcome_Unknown, "unreachable HEAD attempt was falsely confirmed");
      Unaccepted_Receipt := Receipt;
      if not Testing.Receipt_Retains_Image (Unaccepted_Receipt) then
         raise Program_Error with "unaccepted receipt copy lost its exact batch image";
      end if;
      Close (Item, Result);
      Expect (Result, Success, "unresolved database did not close cleanly");
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "database did not reopen after unresolved HEAD");

      Open (Other, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "second writer open failed");
      Begin_Transaction (Item, TX_ID (Tag + 6), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#65#]), Value_A, Result);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "leading writer commit failed");
      Begin_Transaction (Item, TX_ID (Tag + 12), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#69#]), Value_A, Result);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "later successor commit failed");
      Begin_Transaction (Other, TX_ID (Tag + 7), Txn, Result);
      Put (Other, Txn, 1, To_Key ([16#66#]), Value_A, Result);
      Commit (Other, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Stale_Writer, "stale generation was not fenced");
      Resolve (Item, Unaccepted_Receipt, Test_Operation_Timeout, Result => Result);
      Expect (Result, Stale_Writer, "later validated successor chain did not reject lost attempt");
      if Testing.Receipt_Retains_Image (Unaccepted_Receipt) then
         raise Program_Error with "conclusively rejected receipt retained its batch image";
      end if;

      Close (Other, Result);
      Expect (Result, Success, "stale writer close failed");
      Close (Item, Result);
      Expect (Result, Success, "fault database close failed");

      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "fault database reopen failed");
      Begin_Transaction (Item, TX_ID (Tag + 8), Txn, Result);
      Get (Item, Txn, 2, To_Key ([16#64#]), Data, Result);
      Expect (Result, Success, "resolved value was not visible after reopen");
      Rollback (Txn, Result);
      Begin_Transaction (Item, TX_ID (Tag + 10), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#70#]), Value_A, Result);
      Stop.Request;
      Commit (Item, Txn, Test_Operation_Timeout, Stop'Access, Receipt, Result);
      Expect (Result, Cancelled, "pre-admission cancellation was ignored");
      Rollback (Txn, Result);
      Expect (Result, Success, "cancelled admission consumed the transaction");
      Close (Item, Result);
   end Test_Faults;

   procedure Test_Admission_Group_And_Lifecycle (Backend : not null access Backends.Backend'Class) is
      Context      : aliased Storage_Context;
      Item         : aliased Database;
      Txn          : Transaction;
      Other_Txn    : Transaction;
      Receipt      : Commit_Receipt;
      Result       : Outcome_Code;
      Stop         : aliased Flyology.Cancellation.Token;
      --  Test namespace 80 and one-byte item fixtures keep all admission,
      --  grouping, cancellation, and lifecycle outcomes deterministic.
      Database_ID  : constant Database_Identifier := DB_ID (80);
      Item_Key     : constant Key := To_Key ([1]);
      Item_Value   : constant Value := To_Value ([2]);
      Pooled_Batch : Identifier := Zero_Identifier;

      procedure Wait_For_Queue (Minimum : Natural) is
         Depth : Natural := 0;
         Query : Outcome_Code;
      begin
         --  Test synchronization budget: 2,000 one-millisecond yields permit
         --  two seconds for the deterministic queue state before failing the
         --  campaign. This does not affect DB operation deadlines.
         for Attempt in 1 .. 2_000 loop
            Testing.Queue_Depth (Item, Depth, Query);
            Expect (Query, Success, "queue-depth query failed");
            exit when Depth >= Minimum;
            delay 0.001;
         end loop;
         if Depth < Minimum then
            raise Program_Error with "coordinator queue did not reach expected depth";
         end if;
      end Wait_For_Queue;
   begin
      declare
         --  B7 is the test-only batch domain and C3 a distinct transition
         --  domain. Counter 1 versus U64'Last proves injectivity at both ends;
         --  these tags are not persisted object-kind codes.
         First_ID     : constant Identifier := Testing.Test_Structural_ID (16#B7#, 1);
         Last_ID      : constant Identifier :=
           Testing.Test_Structural_ID (16#B7#, Interfaces.Unsigned_64'Last);
         Other_Domain : constant Identifier := Testing.Test_Structural_ID (16#C3#, 1);
      begin
         if First_ID = Last_ID
           or else First_ID = Other_Domain
           or else First_ID = Zero_Identifier
           or else Last_ID = Zero_Identifier
           or else First_ID (16) /= 1
           or else (for some Index in 9 .. 16 => Last_ID (Index) /= 16#FF#)
         then
            raise Program_Error with "structural object identity is not injective at boundaries";
         end if;
      end;
      Bind_Context (Context, Backend, "admission-group");
      Create_DB (Item, Context'Access, Database_ID, ID (81), Result);
      Expect (Result, Success, "admission database create failed");

      Begin_Transaction (Item, TX_ID (82), Txn, Result);
      Put (Item, Txn, 1, Item_Key, Item_Value, Result);
      Stop.Request;
      Commit (Item, Txn, Test_Operation_Timeout, Stop'Access, Receipt, Result);
      Expect (Result, Cancelled, "pre-admission cancellation was not classified");
      if Receipt_Transaction_ID (Receipt) /= Zero_Transaction_ID
        or else Receipt_Batch_ID (Receipt) /= Zero_Identifier
      then
         raise Program_Error with "pre-admission cancellation returned a valid receipt identity";
      end if;
      Rollback (Txn, Result);
      Expect (Result, Success, "pre-admission cancellation consumed transaction");

      Begin_Transaction (Item, TX_ID (83), Txn, Result);
      Put (Item, Txn, 1, Item_Key, Item_Value, Result);
      Commit (Item, Txn, Expired_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Timed_Out, "pre-admission timeout was not classified");
      if Receipt_Transaction_ID (Receipt) /= Zero_Transaction_ID
        or else Receipt_Batch_ID (Receipt) /= Zero_Identifier
      then
         raise Program_Error with "pre-admission timeout returned a valid receipt identity";
      end if;
      Rollback (Txn, Result);
      Expect (Result, Success, "pre-admission timeout consumed transaction");

      Begin_Transaction (Item, TX_ID (84), Txn, Result);
      Begin_Transaction (Item, TX_ID (84), Other_Txn, Result);
      Put (Item, Txn, 1, Item_Key, Item_Value, Result);
      Put (Item, Other_Txn, 2, Item_Key, Item_Value, Result);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "conflict setup commit failed");
      Commit (Item, Other_Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Conflict, "admission conflict was not rejected");
      if Receipt_Transaction_ID (Receipt) /= Zero_Transaction_ID
        or else Receipt_Batch_ID (Receipt) /= Zero_Identifier
      then
         raise Program_Error with "pre-admission conflict returned a valid receipt identity";
      end if;
      Rollback (Other_Txn, Result);
      Expect (Result, Success, "admission conflict consumed transaction");

      declare
         Transactions                                       : Transaction_Array (1 .. 2);
         Receipts                                           : Commit_Receipt_Array (1 .. 2);
         Preexisting                                        : Transaction;
         Rejected_Receipt                                   : Commit_Receipt;
         Before_Batch, Before_Head, After_Batch, After_Head : Natural;
      begin
         Begin_Transaction (Item, TX_ID (200), Preexisting, Result);
         Put (Item, Preexisting, 1, To_Key ([200]), Item_Value, Result);
         for Index in Transactions'Range loop
            Begin_Transaction (Item, TX_ID (Byte (84 + Index)), Transactions (Index), Result);
            Put
              (Item,
               Transactions (Index),
               Column_Family_ID (Index),
               To_Key ([Byte (Index)]),
               To_Value ([Byte (Index + 10)]),
               Result);
         end loop;
         Testing.Publication_Counts (Context, Before_Batch, Before_Head);
         Commit_Group
           (Item, ID (200), Transactions, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Success, "explicit pooled commit failed");
         Testing.Publication_Counts (Context, After_Batch, After_Head);
         if After_Batch /= Before_Batch + 1
           or else After_Head /= Before_Head + 1
           or else Receipt_Batch_ID (Receipts (1)) /= ID (200)
           or else Receipt_Batch_ID (Receipts (1)) /= Receipt_Batch_ID (Receipts (2))
           or else Testing.Attempted_Transition_Number (Receipts (1))
                   /= Testing.Attempted_Transition_Number (Receipts (2))
           or else Receipt_Sequence (Receipts (2)) /= Receipt_Sequence (Receipts (1)) + 1
         then
            raise Program_Error with "explicit group did not share one batch and HEAD transition";
         end if;
         Pooled_Batch := Receipt_Batch_ID (Receipts (1));
         Commit (Item, Preexisting, Test_Operation_Timeout, Receipt => Rejected_Receipt, Result => Result);
         Expect (Result, Conflict, "preexisting singleton reused a newly published group ID");
         Rollback (Preexisting, Result);
         Expect (Result, Success, "cross-kind admission rejection consumed preexisting singleton");
      end;

      declare
         Transactions : Transaction_Array (1 .. 2);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         Begin_Transaction (Item, TX_ID (87), Transactions (1), Result);
         Put (Item, Transactions (1), 2, To_Key ([87]), Item_Value, Result);
         Begin_Transaction (Item, TX_ID (87), Txn, Result);
         Put (Item, Txn, 1, To_Key ([87]), Item_Value, Result);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "post-group collision regression commit failed");
         if Receipt_Batch_ID (Receipt) = Pooled_Batch then
            raise Program_Error with "group and successor reused one structural batch identity";
         end if;
         Begin_Transaction (Item, TX_ID (88), Transactions (2), Result);
         Put (Item, Transactions (2), 2, To_Key ([88]), Item_Value, Result);
         Commit_Group
           (Item, ID (203), Transactions, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Conflict, "preexisting group member reused a newly published singleton ID");
         for Index in Transactions'Range loop
            Rollback (Transactions (Index), Result);
            Expect (Result, Success, "cross-kind group-member rejection consumed transaction");
         end loop;
      end;
      Begin_Transaction (Item, TX_ID (200), Txn, Result);
      Expect (Result, Conflict, "singleton reused a prior explicit group batch identity");
      declare
         Transactions : Transaction_Array (1 .. 1);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         Begin_Transaction (Item, TX_ID (205), Transactions (1), Result);
         Put (Item, Transactions (1), 1, To_Key ([205]), Item_Value, Result);
         Commit_Group
           (Item, ID (206), Transactions, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Invalid_State, "single-member explicit group was accepted");
         Rollback (Transactions (1), Result);
         Expect (Result, Success, "single-member group rejection consumed transaction");
      end;
      declare
         Transactions : Transaction_Array (1 .. 2);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         Begin_Transaction (Item, TX_ID (88), Transactions (1), Result);
         Put (Item, Transactions (1), 1, To_Key ([88]), Item_Value, Result);
         Begin_Transaction (Item, TX_ID (89), Transactions (2), Result);
         Put (Item, Transactions (2), 1, To_Key ([89]), Item_Value, Result);
         Commit_Group
           (Item, ID (87), Transactions, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Conflict, "explicit group reused a singleton batch identity");
         for Index in Transactions'Range loop
            Rollback (Transactions (Index), Result);
            Expect (Result, Success, "cross-kind batch-ID rejection consumed transaction");
         end loop;
      end;

      declare
         Transactions : Transaction_Array (1 .. Maximum_Group_Transactions + 1);
         Receipts     : Commit_Receipt_Array (Transactions'Range);
      begin
         for Index in Transactions'Range loop
            Begin_Transaction (Item, TX_ID (Byte (90 + Index)), Transactions (Index), Result);
            Put (Item, Transactions (Index), 1, To_Key ([Byte (Index)]), Item_Value, Result);
         end loop;
         Commit_Group
           (Item, ID (201), Transactions, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Capacity_Exceeded, "oversized explicit group was admitted");
         for Index in Transactions'Range loop
            Rollback (Transactions (Index), Result);
            Expect (Result, Success, "capacity-rejected group transaction was consumed");
         end loop;
      end;

      declare
         Transactions     : Transaction_Array (1 .. 2);
         Reuse_Candidates : Transaction_Array (1 .. 2);
         Receipts         : Commit_Receipt_Array (Transactions'Range);
         Reuse_Receipts   : Commit_Receipt_Array (Reuse_Candidates'Range);
      begin
         Begin_Transaction (Item, TX_ID (210), Reuse_Candidates (1), Result);
         Put (Item, Reuse_Candidates (1), 1, To_Key ([210]), Item_Value, Result);
         Begin_Transaction (Item, TX_ID (212), Reuse_Candidates (2), Result);
         Put (Item, Reuse_Candidates (2), 1, To_Key ([212]), Item_Value, Result);
         for Index in Transactions'Range loop
            Begin_Transaction (Item, TX_ID (Byte (209 + Index)), Transactions (Index), Result);
            Put (Item, Transactions (Index), 1, To_Key ([Byte (209 + Index)]), Item_Value, Result);
         end loop;
         Testing.Arm (Context, Before_Head_Put, Definite_Failure);
         Commit_Group
           (Item, ID (204), Transactions, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Expect (Result, Storage_Failure, "orphan group setup did not stop before HEAD");
         if Receipt_Transaction_ID (Receipts (1)) /= TX_ID (210)
           or else Receipt_Transaction_ID (Receipts (2)) /= TX_ID (211)
           or else Receipt_Batch_ID (Receipts (1)) /= ID (204)
           or else Receipt_Batch_ID (Receipts (2)) /= ID (204)
         then
            raise Program_Error with "admitted group failure lost stable receipt identities";
         end if;
         Begin_Transaction (Item, TX_ID (204), Txn, Result);
         Expect (Result, Conflict, "singleton reused an admitted orphan group identity");
         Begin_Transaction (Item, TX_ID (210), Txn, Result);
         Expect (Result, Conflict, "singleton reused an admitted orphan group member identity");
         Commit_Group
           (Item,
            ID (207),
            Reuse_Candidates,
            Test_Operation_Timeout,
            Receipts => Reuse_Receipts,
            Result   => Result);
         Expect (Result, Conflict, "different group reused an admitted orphan member identity");
         Rollback (Reuse_Candidates (1), Result);
         Expect (Result, Success, "member-reuse rejection consumed the rejected transaction");
         Commit (Item, Reuse_Candidates (2), Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "member-reuse rejection blocked an unrelated active transaction");
      end;

      Testing.Pause_Coordinator (Item, Result);
      Expect (Result, Success, "coordinator pause failed");
      declare
         task Short_Call is
            entry Finish (Call_Result : out Outcome_Code; Rollback_Result : out Outcome_Code);
         end Short_Call;
         task Long_Call is
            entry Finish (Call_Result : out Outcome_Code);
         end Long_Call;

         task body Short_Call is
            Local_Txn     : Transaction;
            Local_Receipt : Commit_Receipt;
            Local_Result  : Outcome_Code;
            Undo_Result   : Outcome_Code;
         begin
            Begin_Transaction (Item, TX_ID (110), Local_Txn, Local_Result);
            Put (Item, Local_Txn, 1, To_Key ([110]), Item_Value, Local_Result);
            Commit (Item, Local_Txn, Short_Queue_Timeout, Receipt => Local_Receipt, Result => Local_Result);
            if Receipt_Transaction_ID (Local_Receipt) /= TX_ID (110)
              or else Receipt_Batch_ID (Local_Receipt) /= ID (110)
            then
               raise Program_Error with "admitted timeout lost its stable receipt identity";
            end if;
            Rollback (Local_Txn, Undo_Result);
            accept Finish (Call_Result : out Outcome_Code; Rollback_Result : out Outcome_Code) do
               Call_Result := Local_Result;
               Rollback_Result := Undo_Result;
            end Finish;
         end Short_Call;

         task body Long_Call is
            Local_Txn     : Transaction;
            Local_Receipt : Commit_Receipt;
            Local_Result  : Outcome_Code;
         begin
            Begin_Transaction (Item, TX_ID (111), Local_Txn, Local_Result);
            Put (Item, Local_Txn, 1, To_Key ([111]), Item_Value, Local_Result);
            Commit
              (Item, Local_Txn, Test_Operation_Timeout, Receipt => Local_Receipt, Result => Local_Result);
            accept Finish (Call_Result : out Outcome_Code) do
               Call_Result := Local_Result;
            end Finish;
         end Long_Call;

         Short_Result, Short_Rollback, Long_Result : Outcome_Code;
      begin
         Wait_For_Queue (2);
         delay Short_Queue_Expiry_Hold;
         Testing.Resume_Coordinator (Item, Result);
         Expect (Result, Success, "coordinator resume failed");
         Short_Call.Finish (Short_Result, Short_Rollback);
         Long_Call.Finish (Long_Result);
         Expect (Short_Result, Timed_Out, "admitted expired transaction did not time out");
         Expect (Short_Rollback, Invalid_State, "admitted timeout did not consume transaction");
         Expect (Long_Result, Success, "short deadline contaminated unrelated commit");
      end;

      Testing.Pause_Coordinator (Item, Result);
      Expect (Result, Success, "post-admission cancellation pause failed");
      declare
         Late_Stop : aliased Flyology.Cancellation.Token;
         task Cancel_Call is
            entry Finish (Call_Result : out Outcome_Code; Rollback_Result : out Outcome_Code);
         end Cancel_Call;

         task body Cancel_Call is
            Local_Txn      : Transaction;
            Local_Receipt  : Commit_Receipt;
            Local_Result   : Outcome_Code;
            Rollback_Value : Outcome_Code;
         begin
            Begin_Transaction (Item, TX_ID (114), Local_Txn, Local_Result);
            Put (Item, Local_Txn, 1, To_Key ([114]), Item_Value, Local_Result);
            Commit (Item, Local_Txn, Test_Operation_Timeout, Late_Stop'Access, Local_Receipt, Local_Result);
            Rollback (Local_Txn, Rollback_Value);
            accept Finish (Call_Result : out Outcome_Code; Rollback_Result : out Outcome_Code) do
               Call_Result := Local_Result;
               Rollback_Result := Rollback_Value;
            end Finish;
         end Cancel_Call;

         Call_Result, Rollback_Result : Outcome_Code;
      begin
         Wait_For_Queue (1);
         Late_Stop.Request;
         Testing.Resume_Coordinator (Item, Result);
         Expect (Result, Success, "post-admission cancellation resume failed");
         Cancel_Call.Finish (Call_Result, Rollback_Result);
         Expect (Call_Result, Success, "post-admission cancellation changed terminal classification");
         Expect (Rollback_Result, Invalid_State, "post-admission cancellation did not consume transaction");
      end;

      Testing.Pause_Coordinator (Item, Result);
      Expect (Result, Success, "queue saturation pause failed");
      declare
         task Full_Group is
            entry Finish (Call_Result : out Outcome_Code);
         end Full_Group;

         task body Full_Group is
            Transactions : Transaction_Array (1 .. Maximum_Group_Transactions);
            Receipts     : Commit_Receipt_Array (Transactions'Range);
            Local_Result : Outcome_Code;
         begin
            for Index in Transactions'Range loop
               Begin_Transaction (Item, TX_ID (Byte (120 + Index)), Transactions (Index), Local_Result);
               Put (Item, Transactions (Index), 1, To_Key ([Byte (120 + Index)]), Item_Value, Local_Result);
            end loop;
            Commit_Group
              (Item,
               ID (202),
               Transactions,
               Test_Operation_Timeout,
               Receipts => Receipts,
               Result   => Local_Result);
            accept Finish (Call_Result : out Outcome_Code) do
               Call_Result := Local_Result;
            end Finish;
         end Full_Group;

         Group_Result : Outcome_Code;
      begin
         Wait_For_Queue (Maximum_Group_Transactions);
         Begin_Transaction (Item, TX_ID (130), Txn, Result);
         Put (Item, Txn, 1, To_Key ([130]), Item_Value, Result);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Capacity_Exceeded, "full completion-slot queue admitted one more request");
         if Receipt_Transaction_ID (Receipt) /= Zero_Transaction_ID
           or else Receipt_Batch_ID (Receipt) /= Zero_Identifier
         then
            raise Program_Error with "pre-admission capacity rejection returned a valid receipt";
         end if;
         Rollback (Txn, Result);
         Expect (Result, Success, "queue-capacity rejection consumed transaction");
         Testing.Resume_Coordinator (Item, Result);
         Expect (Result, Success, "queue saturation resume failed");
         Full_Group.Finish (Group_Result);
         Expect (Group_Result, Success, "eight-slot boundary group failed");
      end;

      Testing.Pause_Coordinator (Item, Result);
      Expect (Result, Success, "close-race pause failed");
      declare
         task Commit_During_Close is
            entry Finish (Call_Result : out Outcome_Code);
         end Commit_During_Close;

         task body Commit_During_Close is
            Local_Txn     : Transaction;
            Local_Receipt : Commit_Receipt;
            Local_Result  : Outcome_Code;
         begin
            Begin_Transaction (Item, TX_ID (131), Local_Txn, Local_Result);
            Put (Item, Local_Txn, 1, To_Key ([131]), Item_Value, Local_Result);
            Commit
              (Item, Local_Txn, Test_Operation_Timeout, Receipt => Local_Receipt, Result => Local_Result);
            if Receipt_Transaction_ID (Local_Receipt) /= TX_ID (131)
              or else Receipt_Batch_ID (Local_Receipt) /= ID (131)
            then
               raise Program_Error with "admitted close classification lost its receipt identity";
            end if;
            accept Finish (Call_Result : out Outcome_Code) do
               Call_Result := Local_Result;
            end Finish;
         end Commit_During_Close;

         Call_Result : Outcome_Code;
      begin
         Wait_For_Queue (1);
         Close (Item, Result);
         Expect (Result, Success, "close/admission race did not join");
         Commit_During_Close.Finish (Call_Result);
         Expect (Call_Result, Storage_Failure, "close did not classify admitted queued work");
         declare
            Closed_Value : Sequence_Number;
         begin
            Highest_Visible (Item, Closed_Value, Result);
            Expect (Result, Invalid_State, "highest-visible raced through closed lifecycle");
         end;
         Begin_Transaction (Item, TX_ID (132), Txn, Result);
         Expect (Result, Invalid_State, "begin raced through closed lifecycle");
         Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "database did not reopen after close/admission race");
      end;

      declare
         Reader        : Transaction;
         Buffered      : Transaction_Array (1 .. 2);
         Read_Data     : Value;
         Group_Receipt : Commit_Receipt_Array (Buffered'Range);
      begin
         Begin_Transaction (Item, TX_ID (115), Reader, Result);
         Expect (Result, Success, "active reader setup failed");
         for Index in Buffered'Range loop
            Begin_Transaction (Item, TX_ID (Byte (115 + Index)), Buffered (Index), Result);
            Put (Item, Buffered (Index), 1, To_Key ([Byte (115 + Index)]), Item_Value, Result);
         end loop;

         Testing.Fail_Next_Install (Item, Result);
         Expect (Result, Success, "local-install fault setup failed");
         Begin_Transaction (Item, TX_ID (112), Txn, Result);
         Put (Item, Txn, 1, To_Key ([112]), Item_Value, Result);
         Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "confirmed durable HEAD was downgraded by local install failure");

         Get (Item, Reader, 1, Item_Key, Read_Data, Result);
         Expect (Result, Stale_Writer, "active reader observed stale state after local install failure");
         Get (Item, Buffered (1), 1, To_Key ([116]), Read_Data, Result);
         Expect (Result, Stale_Writer, "buffered write bypassed the fenced read path");
         Put (Item, Buffered (1), 1, To_Key ([118]), Item_Value, Result);
         Expect (Result, Stale_Writer, "active transaction buffered a Put while fenced");
         Delete (Item, Buffered (1), 1, To_Key ([116]), Result);
         Expect (Result, Stale_Writer, "active transaction buffered a Delete while fenced");
         Commit_Group
           (Item, ID (119), Buffered, Test_Operation_Timeout, Receipts => Group_Receipt, Result => Result);
         Expect (Result, Stale_Writer, "active group entered publication while fenced");
         for Index in Buffered'Range loop
            Rollback (Buffered (Index), Result);
            Expect (Result, Success, "fenced group rejection consumed a transaction");
         end loop;
         Rollback (Reader, Result);
         Expect (Result, Success, "fenced active reader could not be cleaned up");
         Begin_Transaction (Item, TX_ID (113), Txn, Result);
         Expect (Result, Stale_Writer, "local install failure did not fence reuse");
      end;
      Close (Item, Result);
      Expect (Result, Success, "fenced database close failed");
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "fenced database did not recover");
      declare
         Recovered : Value;
      begin
         Begin_Transaction (Item, TX_ID (120), Txn, Result);
         Get (Item, Txn, 1, To_Key ([112]), Recovered, Result);
         Expect (Result, Success, "reopen did not recover the durably published value");
         Rollback (Txn, Result);
      end;
      Close (Item, Result);
      Expect (Result, Success, "admission database close failed");
   end Test_Admission_Group_And_Lifecycle;

   procedure Test_Resolve_Drains_Queued (Backend : not null access Backends.Backend'Class) is
      Context                            : aliased Storage_Context;
      Item                               : aliased Database;
      Ambiguous_Receipt, Drained_Receipt : Commit_Receipt;
      Result                             : Outcome_Code;
      Before_Batch, Before_Head          : Natural;
      After_Batch, After_Head            : Natural;
      --  Deterministic namespace 170 identifies only this accepted-resolution
      --  queue-drain campaign; following IDs encode scenario roles, not policy.
      Database_ID                        : constant Database_Identifier := DB_ID (170);

      procedure Wait_For_Queue (Minimum : Natural) is
         Depth : Natural := 0;
         Query : Outcome_Code;
      begin
         --  Test synchronization budget: 2,000 one-millisecond yields permit
         --  two seconds for the deterministic queue state before failing the
         --  campaign. This does not affect DB operation deadlines.
         for Attempt in 1 .. 2_000 loop
            Testing.Queue_Depth (Item, Depth, Query);
            Expect (Query, Success, "resolve-drain queue-depth query failed");
            exit when Depth >= Minimum;
            delay 0.001;
         end loop;
         if Depth < Minimum then
            raise Program_Error with "resolve-drain queue did not reach expected depth";
         end if;
      end Wait_For_Queue;
   begin
      Bind_Context (Context, Backend, "resolve-drains-queued");
      Create_DB (Item, Context'Access, Database_ID, ID (171), Result);
      Expect (Result, Success, "resolve-drain database create failed");
      Testing.Publication_Counts (Context, Before_Batch, Before_Head);
      Testing.Pause_Coordinator (Item, Result);
      Expect (Result, Success, "resolve-drain coordinator pause failed");
      declare
         task Ambiguous_Call is
            entry Start;
            entry Finish (Call_Result : out Outcome_Code);
         end Ambiguous_Call;

         task Drained_Call is
            entry Start;
            entry Finish (Call_Result, Rollback_Result : out Outcome_Code);
         end Drained_Call;

         task body Ambiguous_Call is
            Txn          : Transaction;
            Local_Result : Outcome_Code;
         begin
            accept Start;
            Begin_Transaction (Item, TX_ID (172), Txn, Local_Result);
            Put (Item, Txn, 1, To_Key ([172]), To_Value ([1]), Local_Result);
            Commit (Item, Txn, Test_Operation_Timeout, Receipt => Ambiguous_Receipt, Result => Local_Result);
            accept Finish (Call_Result : out Outcome_Code) do
               Call_Result := Local_Result;
            end Finish;
         end Ambiguous_Call;

         task body Drained_Call is
            Txn            : Transaction;
            Local_Result   : Outcome_Code;
            Local_Rollback : Outcome_Code;
         begin
            accept Start;
            Begin_Transaction (Item, TX_ID (173), Txn, Local_Result);
            Put (Item, Txn, 1, To_Key ([173]), To_Value ([2]), Local_Result);
            Commit (Item, Txn, Test_Operation_Timeout, Receipt => Drained_Receipt, Result => Local_Result);
            Rollback (Txn, Local_Rollback);
            accept Finish (Call_Result, Rollback_Result : out Outcome_Code) do
               Call_Result := Local_Result;
               Rollback_Result := Local_Rollback;
            end Finish;
         end Drained_Call;

         Ambiguous_Result, Drained_Result, Rollback_Result : Outcome_Code;
         Probe                                             : Transaction;
      begin
         Ambiguous_Call.Start;
         Wait_For_Queue (1);
         Drained_Call.Start;
         Wait_For_Queue (2);
         Testing.Arm (Context, After_Head_Put, Unknown_After_Entry);
         Testing.Resume_Coordinator (Item, Result);
         Expect (Result, Success, "resolve-drain coordinator resume failed");
         Ambiguous_Call.Finish (Ambiguous_Result);
         Expect (Ambiguous_Result, Outcome_Unknown, "resolve-drain HEAD ambiguity was not retained");
         Begin_Transaction (Item, TX_ID (173), Probe, Result);
         Expect (Result, Outcome_Unknown, "unresolved engine admitted a queued identity replay");

         Resolve (Item, Ambiguous_Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "resolve deadlocked or rejected the accepted HEAD transition");
         Drained_Call.Finish (Drained_Result, Rollback_Result);
         Expect (Drained_Result, Storage_Failure, "resolution did not classify queued work definitely");
         Expect (Rollback_Result, Invalid_State, "resolution-drained transaction was not consumed");
         if Receipt_Transaction_ID (Drained_Receipt) /= TX_ID (173)
           or else Receipt_Batch_ID (Drained_Receipt) /= ID (173)
           or else Receipt_Outcome (Drained_Receipt) /= Storage_Failure
         then
            raise Program_Error with "resolution drain lost the queued receipt identity";
         end if;
      end;
      Testing.Publication_Counts (Context, After_Batch, After_Head);
      if After_Batch /= Before_Batch + 1 or else After_Head /= Before_Head + 1 then
         raise Program_Error with "resolution-drained work reached object publication";
      end if;
      if Visible (Item) /= 1 then
         raise Program_Error with "resolved accepted HEAD did not install exactly one transaction";
      end if;
      declare
         Reader : Transaction;
         Data   : Value;
      begin
         Begin_Transaction (Item, TX_ID (174), Reader, Result);
         Expect (Result, Success, "resolve-drain verification transaction failed");
         Get (Item, Reader, 1, To_Key ([172]), Data, Result);
         Expect (Result, Success, "resolved ambiguous value was not visible");
         if Data /= To_Value ([1]) then
            raise Program_Error with "resolved ambiguous value changed";
         end if;
         Get (Item, Reader, 1, To_Key ([173]), Data, Result);
         Expect (Result, Not_Found, "resolution-drained queued value became visible");
         Rollback (Reader, Result);
      end;
      --  The drained ID remains a local reservation only while the old uncertain
      --  engine exists.  After replacement or total local loss, never reusing it
      --  remains the caller's obligation because no immutable batch records it.
      Close (Item, Result);
      Expect (Result, Success, "resolve-drain database close failed");
   end Test_Resolve_Drains_Queued;

   procedure Test_Unaccepted_Resolve_Drains_Queued (Backend : not null access Backends.Backend'Class) is
      Context                          : aliased Storage_Context;
      Item                             : aliased Database;
      Rival                            : Database;
      Ambiguous_Receipt, Rival_Receipt : Commit_Receipt;
      Drained_Receipts                 : Commit_Receipt_Array (1 .. 2);
      Result                           : Outcome_Code;
      Before_Batch, Before_Head        : Natural;
      After_Batch, After_Head          : Natural;
      --  Deterministic namespace 175 identifies only the unaccepted-resolution
      --  peer campaign; following IDs encode scenario roles, not policy.
      Database_ID                      : constant Database_Identifier := DB_ID (175);

      procedure Wait_For_Queue (Minimum : Natural) is
         Depth : Natural := 0;
         Query : Outcome_Code;
      begin
         --  Test synchronization budget: 2,000 one-millisecond yields permit
         --  two seconds for the deterministic queue state before failing the
         --  campaign. This does not affect DB operation deadlines.
         for Attempt in 1 .. 2_000 loop
            Testing.Queue_Depth (Item, Depth, Query);
            Expect (Query, Success, "unaccepted-drain queue-depth query failed");
            exit when Depth >= Minimum;
            delay 0.001;
         end loop;
         if Depth < Minimum then
            raise Program_Error with "unaccepted-drain queue did not reach expected depth";
         end if;
      end Wait_For_Queue;
   begin
      Bind_Context (Context, Backend, "unaccepted-resolve-drains-queued");
      Create_DB (Item, Context'Access, Database_ID, ID (176), Result);
      Expect (Result, Success, "unaccepted-drain database create failed");
      Open (Rival, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "unaccepted-drain rival open failed");
      Testing.Publication_Counts (Context, Before_Batch, Before_Head);
      Testing.Pause_Coordinator (Item, Result);
      Expect (Result, Success, "unaccepted-drain coordinator pause failed");
      declare
         task Ambiguous_Call is
            entry Start;
            entry Finish (Call_Result : out Outcome_Code);
         end Ambiguous_Call;

         task Drained_Call is
            entry Start;
            entry Finish (Call_Result, Rollback_Result : out Outcome_Code);
         end Drained_Call;

         task body Ambiguous_Call is
            Txn          : Transaction;
            Local_Result : Outcome_Code;
         begin
            accept Start;
            Begin_Transaction (Item, TX_ID (177), Txn, Local_Result);
            Put (Item, Txn, 1, To_Key ([177]), To_Value ([1]), Local_Result);
            Commit (Item, Txn, Test_Operation_Timeout, Receipt => Ambiguous_Receipt, Result => Local_Result);
            accept Finish (Call_Result : out Outcome_Code) do
               Call_Result := Local_Result;
            end Finish;
         end Ambiguous_Call;

         task body Drained_Call is
            Transactions   : Transaction_Array (1 .. 2);
            Local_Result   : Outcome_Code;
            Local_Rollback : Outcome_Code;
         begin
            accept Start;
            for Index in Transactions'Range loop
               Begin_Transaction (Item, TX_ID (Byte (177 + Index)), Transactions (Index), Local_Result);
               Put
                 (Item,
                  Transactions (Index),
                  1,
                  To_Key ([Byte (177 + Index)]),
                  To_Value ([Byte (1 + Index)]),
                  Local_Result);
            end loop;
            Commit_Group
              (Item,
               ID (181),
               Transactions,
               Test_Operation_Timeout,
               Receipts => Drained_Receipts,
               Result   => Local_Result);
            Local_Rollback := Invalid_State;
            for Index in Transactions'Range loop
               declare
                  Member_Rollback : Outcome_Code;
               begin
                  Rollback (Transactions (Index), Member_Rollback);
                  if Member_Rollback /= Invalid_State then
                     Local_Rollback := Member_Rollback;
                  end if;
               end;
            end loop;
            accept Finish (Call_Result, Rollback_Result : out Outcome_Code) do
               Call_Result := Local_Result;
               Rollback_Result := Local_Rollback;
            end Finish;
         end Drained_Call;

         Ambiguous_Result, Drained_Result, Rollback_Result : Outcome_Code;
      begin
         Ambiguous_Call.Start;
         Wait_For_Queue (1);
         Drained_Call.Start;
         Wait_For_Queue (3);
         Testing.Arm (Context, Before_Head_Put, Unknown_After_Entry);
         Testing.Resume_Coordinator (Item, Result);
         Expect (Result, Success, "unaccepted-drain coordinator resume failed");
         Ambiguous_Call.Finish (Ambiguous_Result);
         Expect (Ambiguous_Result, Outcome_Unknown, "unaccepted HEAD ambiguity was not retained");

         Resolve (Item, Ambiguous_Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Outcome_Unknown, "unaccepted resolve was falsely made conclusive");
         Drained_Call.Finish (Drained_Result, Rollback_Result);
         Expect (Drained_Result, Storage_Failure, "unresolved resolve did not drain the queued group");
         Expect (Rollback_Result, Invalid_State, "unresolved-drained group transactions were not consumed");
         for Index in Drained_Receipts'Range loop
            if Receipt_Transaction_ID (Drained_Receipts (Index)) /= TX_ID (Byte (177 + Index))
              or else Receipt_Batch_ID (Drained_Receipts (Index)) /= ID (181)
              or else Receipt_Outcome (Drained_Receipts (Index)) /= Storage_Failure
            then
               raise Program_Error with "unresolved resolution drain lost a group receipt identity";
            end if;
         end loop;

         declare
            Rival_Txn : Transaction;
         begin
            Begin_Transaction (Rival, TX_ID (180), Rival_Txn, Result);
            Put (Rival, Rival_Txn, 1, To_Key ([180]), To_Value ([4]), Result);
            Commit (Rival, Rival_Txn, Test_Operation_Timeout, Receipt => Rival_Receipt, Result => Result);
            Expect (Result, Success, "unaccepted-drain rival successor commit failed");
         end;
         Resolve (Item, Ambiguous_Receipt, Test_Operation_Timeout, Result => Result);
         Expect (Result, Stale_Writer, "validated rival successor did not reject the lost attempt");
      end;
      Testing.Publication_Counts (Context, After_Batch, After_Head);
      if After_Batch /= Before_Batch + 2 or else After_Head /= Before_Head + 1 then
         raise Program_Error with "rejected resolution-drained group reached publication";
      end if;
      --  Neither orphan identity is discoverable after complete local-state loss;
      --  the caller's never-reuse obligation therefore remains authoritative.
      Close (Item, Result);
      Expect (Result, Success, "unaccepted-drain database close failed");
      Close (Rival, Result);
      Expect (Result, Success, "unaccepted-drain rival close failed");
   end Test_Unaccepted_Resolve_Drains_Queued;

   procedure Test_Shared_Context_Synchronization (Backend : not null access Backends.Backend'Class) is
      Context                                            : aliased Storage_Context;
      First                                              : aliased Database;
      Second                                             : aliased Database;
      Result                                             : Outcome_Code;
      Before_Batch, Before_Head, After_Batch, After_Head : Natural;
      --  Namespace 140 and the two-party start gate are fixed concurrency-test
      --  dimensions: exactly two writers race for one injected fault.
      Database_ID                                        : constant Database_Identifier := DB_ID (140);

      protected Start_Gate is
         procedure Ready;
         entry Go;
      private
         Ready_Count : Natural range 0 .. 2 := 0;
      end Start_Gate;

      protected body Start_Gate is
         procedure Ready is
         begin
            Ready_Count := Ready_Count + 1;
         end Ready;

         entry Go when Ready_Count = 2 is
         begin
            null;
         end Go;
      end Start_Gate;

      task type Commit_Call
        (Target   : not null access Database;
         Identity : Byte)
      is
         entry Finish (Call_Result : out Outcome_Code);
      end Commit_Call;

      task body Commit_Call is
         Txn     : Transaction;
         Receipt : Commit_Receipt;
         Outcome : Outcome_Code;
      begin
         Begin_Transaction (Target.all, TX_ID (Identity), Txn, Outcome);
         if Outcome = Success then
            Put (Target.all, Txn, 1, To_Key ([Identity]), To_Value ([Identity]), Outcome);
         end if;
         Start_Gate.Ready;
         Start_Gate.Go;
         if Outcome = Success then
            Commit (Target.all, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Outcome);
         end if;
         accept Finish (Call_Result : out Outcome_Code) do
            Call_Result := Outcome;
         end Finish;
      end Commit_Call;
   begin
      Bind_Context (Context, Backend, "shared-context");
      Create_DB (First, Context'Access, Database_ID, ID (141), Result);
      Expect (Result, Success, "shared-context database create failed");
      Open (Second, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "shared-context second handle open failed");
      Testing.Publication_Counts (Context, Before_Batch, Before_Head);
      Testing.Arm (Context, Before_Batch_Put, Definite_Failure);
      declare
         First_Call                  : Commit_Call (First'Access, 142);
         Second_Call                 : Commit_Call (Second'Access, 143);
         First_Result, Second_Result : Outcome_Code;
      begin
         First_Call.Finish (First_Result);
         Second_Call.Finish (Second_Result);
         if not ((First_Result = Success and then Second_Result = Storage_Failure)
                 or else (First_Result = Storage_Failure and then Second_Result = Success))
         then
            raise Program_Error with "shared-context fault schedule was not consumed exactly once";
         end if;
      end;
      Testing.Publication_Counts (Context, After_Batch, After_Head);
      if After_Batch /= Before_Batch + 1 or else After_Head /= Before_Head + 1 then
         raise Program_Error with "shared-context publication counters lost a concurrent update";
      end if;
      Close (Second, Result);
      Expect (Result, Success, "shared-context second handle close failed");
      Close (First, Result);
      Expect (Result, Success, "shared-context first handle close failed");
   end Test_Shared_Context_Synchronization;

   procedure Test_Resolve_Lifecycle (Backend : not null access Backends.Backend'Class) is
      Context           : aliased Storage_Context;
      Item              : aliased Database;
      Reader            : Transaction;
      Candidate         : Transaction;
      Ambiguous         : Transaction;
      Rejected          : Transaction;
      Receipt           : Commit_Receipt;
      Candidate_Receipt : Commit_Receipt;
      Result            : Outcome_Code;
      Close_Result      : Outcome_Code;
      Highest_Result    : Outcome_Code;
      Begin_Result      : Outcome_Code;
      Get_Result        : Outcome_Code;
      Commit_Result     : Outcome_Code;
      Data              : Value;
      Highest           : Sequence_Number;
      Waiting           : Boolean := False;
      --  Namespace 150 isolates the close/read/commit-versus-resolve lifecycle
      --  race and has no persisted allocation significance.
      Database_ID       : constant Database_Identifier := DB_ID (150);
   begin
      Bind_Context (Context, Backend, "resolve-lifecycle");
      Create_DB (Item, Context'Access, Database_ID, ID (151), Result);
      Expect (Result, Success, "resolve-lifecycle database create failed");
      Begin_Transaction (Item, TX_ID (152), Reader, Result);
      Expect (Result, Success, "resolve-lifecycle reader begin failed");
      Begin_Transaction (Item, TX_ID (153), Candidate, Result);
      Expect (Result, Success, "resolve-lifecycle candidate begin failed");
      Put (Item, Candidate, 1, To_Key ([153]), To_Value ([1]), Result);
      Expect (Result, Success, "resolve-lifecycle candidate put failed");
      Begin_Transaction (Item, TX_ID (154), Ambiguous, Result);
      Put (Item, Ambiguous, 1, To_Key ([154]), To_Value ([2]), Result);
      Testing.Arm (Context, Before_Head_Put, Unknown_After_Entry);
      Commit (Item, Ambiguous, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Outcome_Unknown, "resolve-lifecycle ambiguity was not retained");

      Testing.Pause_Gets (Context);
      declare
         protected Resolution_Box is
            procedure Set (Value : Outcome_Code);
            function Done return Boolean;
            function Value return Outcome_Code;
         private
            Ready  : Boolean := False;
            Stored : Outcome_Code := Invalid_State;
         end Resolution_Box;

         protected body Resolution_Box is
            procedure Set (Value : Outcome_Code) is
            begin
               Stored := Value;
               Ready := True;
            end Set;

            function Done return Boolean
            is (Ready);

            function Value return Outcome_Code
            is (Stored);
         end Resolution_Box;

         task type Resolver_Task is
            --  The harness deliberately uses Flyology's native-task class;
            --  eight MiB matches the test runner's native Ada task stack
            --  qualification and has no bearing on DB task creation policy.
            pragma Task_Info (Flyology.Native_Task);
            pragma Storage_Size (8 * 1024 * 1024);
         end Resolver_Task;

         task body Resolver_Task is
            Local_Result : Outcome_Code;
         begin
            Resolve (Item, Receipt, Test_Operation_Timeout, Result => Local_Result);
            Resolution_Box.Set (Local_Result);
         exception
            when others =>
               Resolution_Box.Set (Storage_Failure);
         end Resolver_Task;

         Resolver : Resolver_Task;

         Resolve_Result : Outcome_Code;
         --  Two seconds bounds only the deterministic test barrier wait; the
         --  Resolve call retains its separately supplied operation deadline.
         Wait_Deadline  : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0);
      begin
         loop
            Waiting := Testing.Get_Waiting (Context);
            exit when Waiting or else Ada.Real_Time.Clock >= Wait_Deadline;
            delay Test_Poll_Yield;
         end loop;
         if not Waiting then
            Testing.Resume_Gets (Context);
            if Resolution_Box.Done then
               Resolve_Result := Resolution_Box.Value;
            else
               abort Resolver;
               Resolve_Result := Storage_Failure;
            end if;
            Close (Item, Close_Result);
            raise Program_Error
              with
                "resolve did not reach the deterministic storage barrier: "
                & Outcome_Code'Image (Resolve_Result);
         end if;

         Close (Item, Close_Result);
         Highest_Visible (Item, Highest, Highest_Result);
         Begin_Transaction (Item, TX_ID (155), Rejected, Begin_Result);
         Get (Item, Reader, 1, To_Key ([1]), Data, Get_Result);
         Commit
           (Item, Candidate, Test_Operation_Timeout, Receipt => Candidate_Receipt, Result => Commit_Result);
         Testing.Resume_Gets (Context);
         declare
            --  The same two-second harness budget prevents a failed resume from
            --  hanging the runner; it does not change resolution semantics.
            Finish_Deadline : constant Ada.Real_Time.Time :=
              Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (2.0);
         begin
            loop
               exit when Resolution_Box.Done or else Ada.Real_Time.Clock >= Finish_Deadline;
               delay Test_Poll_Yield;
            end loop;
            if not Resolution_Box.Done then
               abort Resolver;
               raise Program_Error with "resolve did not finish after storage resume";
            end if;
         end;
         Resolve_Result := Resolution_Box.Value;

         Expect (Close_Result, Invalid_State, "close entered during exclusive resolution");
         Expect (Highest_Result, Invalid_State, "highest-visible entered during resolution");
         Expect (Begin_Result, Invalid_State, "begin entered during resolution");
         Expect (Get_Result, Invalid_State, "get entered during resolution");
         Expect (Commit_Result, Invalid_State, "commit entered during resolution");
         Expect (Resolve_Result, Outcome_Unknown, "paused resolution changed classification");
      end;

      Rollback (Reader, Result);
      Expect (Result, Success, "resolution race consumed reader transaction");
      Rollback (Candidate, Result);
      Expect (Result, Success, "resolution race consumed rejected commit transaction");
      Close (Item, Result);
      Expect (Result, Success, "resolve-lifecycle database close failed");
   end Test_Resolve_Lifecycle;

   procedure Test_Cap_Boundaries (Backend : not null access Backends.Backend'Class) is
      Context     : aliased Storage_Context;
      Item        : Database;
      Txn         : Transaction;
      Receipt     : Commit_Receipt;
      Result      : Outcome_Code;
      Data        : Value;
      --  Namespace 180 isolates the exact/one-over capacity campaign. All
      --  operative ceilings come from Default_Limits persisted by Create_DB.
      Database_ID : constant Database_Identifier := DB_ID (180);

      function Indexed_Key (Index : Natural) return Key
      is (To_Key ([Byte ((Index / 256) mod 256), Byte (Index mod 256)]));

      procedure Fill_Exact_Transaction
        (DB : in out Database; Target : in out Transaction; Identity : Natural; Seed : Natural)
      is
         Key_Bytes   : Byte_Array (1 .. Maximum_Key_Bytes);
         Value_Bytes : Byte_Array (1 .. Maximum_Value_Bytes);
      begin
         --  Exact 4,096-byte transaction: twelve (64+256)-byte mutations plus
         --  one (64+192)-byte mutation. The formula derives from the persisted
         --  Default_Limits payload cap and reference fixture widths.
         Begin_Transaction (DB, Numbered_TX_ID (Identity), Target, Result);
         Expect (Result, Success, "exact-byte transaction begin failed");
         for Mutation in 1 .. 13 loop
            for Index in Key_Bytes'Range loop
               Key_Bytes (Index) := Byte ((Seed + Mutation + Index) mod 256);
            end loop;
            if Mutation <= 12 then
               for Index in Value_Bytes'Range loop
                  Value_Bytes (Index) := Byte ((Seed + Mutation * 3 + Index) mod 256);
               end loop;
               Put (DB, Target, 1, To_Key (Key_Bytes), To_Value (Value_Bytes), Result);
            else
               Put
                 (DB,
                  Target,
                  1,
                  To_Key (Key_Bytes),
                  To_Value (Value_Bytes (1 .. Maximum_Value_Bytes - 64)),
                  Result);
            end if;
            Expect (Result, Success, "exact-byte mutation failed");
         end loop;
      end Fill_Exact_Transaction;
   begin
      Bind_Context (Context, Backend, "cap-history");
      Create_DB (Item, Context'Access, Database_ID, ID (181), Result);
      Expect (Result, Success, "history-cap database create failed");
      --  Default_Limits authorizes 64 retained batches of eight transactions,
      --  yielding the exact 512 seen-ID boundary; batch 65 is one over.
      for Batch in 1 .. 64 loop
         declare
            Transactions : Transaction_Array (1 .. Maximum_Group_Transactions);
            Receipts     : Commit_Receipt_Array (Transactions'Range);
         begin
            for Member in Transactions'Range loop
               Begin_Transaction
                 (Item, Numbered_TX_ID (10_000 + (Batch - 1) * 8 + Member), Transactions (Member), Result);
               Delete (Item, Transactions (Member), 1, Indexed_Key (1), Result);
            end loop;
            Commit_Group
              (Item,
               Numbered_ID (20_000 + Batch),
               Transactions,
               Test_Operation_Timeout,
               Receipts => Receipts,
               Result   => Result);
            Expect (Result, Success, "history/seen boundary group failed");
         end;
      end loop;
      if Visible (Item) /= 512 then
         raise Program_Error with "512-transaction seen boundary was not reached";
      end if;
      Begin_Transaction (Item, Numbered_TX_ID (30_000), Txn, Result);
      Delete (Item, Txn, 1, Indexed_Key (2), Result);
      Commit (Item, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
      Expect (Result, Capacity_Exceeded, "65th history batch was admitted");
      Rollback (Txn, Result);
      Expect (Result, Success, "history-cap rejection consumed transaction");
      Close (Item, Result);
      Open (Item, Context'Access, Database_ID, Test_Operation_Timeout, Result => Result);
      Expect (Result, Success, "64-batch/512-ID history did not reopen");
      Begin_Transaction (Item, Numbered_TX_ID (10_001), Txn, Result);
      Expect (Result, Conflict, "recovered seen-ID boundary lost first transaction");
      Begin_Transaction (Item, Numbered_TX_ID (20_001), Txn, Result);
      Expect (Result, Conflict, "singleton reused recovered group batch identity");
      Close (Item, Result);

      declare
         Reservation_Context : aliased Storage_Context;
         Reservation_DB      : Database;
      begin
         Bind_Context (Reservation_Context, Backend, "cap-reservations");
         Create_DB (Reservation_DB, Reservation_Context'Access, DB_ID (186), ID (187), Result);
         Expect (Result, Success, "reservation-cap database create failed");
         --  Each failed eight-member group reserves nine identities (eight
         --  transactions plus group/batch). 64 attempts fill 576 slots, so the
         --  next singleton is the 577th exact one-over reservation.
         for Attempt in 1 .. Maximum_History_Batches loop
            declare
               Transactions : Transaction_Array (1 .. Maximum_Group_Transactions);
               Receipts     : Commit_Receipt_Array (Transactions'Range);
            begin
               for Member in Transactions'Range loop
                  Begin_Transaction
                    (Reservation_DB,
                     Numbered_TX_ID (40_000 + (Attempt - 1) * Maximum_Group_Transactions + Member),
                     Transactions (Member),
                     Result);
                  Delete (Reservation_DB, Transactions (Member), 1, Indexed_Key (1), Result);
               end loop;
               Testing.Arm (Reservation_Context, Before_Head_Put, Definite_Failure);
               Commit_Group
                 (Reservation_DB,
                  Numbered_ID (41_000 + Attempt),
                  Transactions,
                  Test_Operation_Timeout,
                  Receipts => Receipts,
                  Result   => Result);
               Expect (Result, Storage_Failure, "admitted reservation-cap group did not fail");
            end;
         end loop;
         Begin_Transaction (Reservation_DB, Numbered_TX_ID (50_000), Txn, Result);
         Expect (Result, Success, "reservation-cap one-over transaction did not begin");
         Delete (Reservation_DB, Txn, 1, Indexed_Key (2), Result);
         Commit (Reservation_DB, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Capacity_Exceeded, "577th shared identity reservation was admitted");
         if Receipt_Transaction_ID (Receipt) /= Zero_Transaction_ID
           or else Receipt_Batch_ID (Receipt) /= Zero_Identifier
         then
            raise Program_Error with "reservation-cap rejection returned a valid receipt";
         end if;
         Rollback (Txn, Result);
         Expect (Result, Success, "reservation-cap rejection consumed the transaction");
         Close (Reservation_DB, Result);
         Expect (Result, Success, "reservation-cap database close failed");
         Open
           (Reservation_DB,
            Reservation_Context'Access,
            DB_ID (186),
            Test_Operation_Timeout,
            Result => Result);
         Expect (Result, Success, "empty reachable history did not reopen after orphan attempts");
         if Visible (Reservation_DB) /= 0 then
            raise Program_Error with "orphan reservation attempts became visible after reopen";
         end if;
         Close (Reservation_DB, Result);
      end;

      declare
         State_Context : aliased Storage_Context;
         State_DB      : Database;
      begin
         Bind_Context (State_Context, Backend, "cap-state");
         Create_DB (State_DB, State_Context'Access, DB_ID (182), ID (183), Result);
         Expect (Result, Success, "state-cap database create failed");
         --  Four batches of 64 unique keys fill the persisted 256-entry live
         --  state exactly; key 257 is the one-over publication guard.
         for Batch in 1 .. 4 loop
            Begin_Transaction (State_DB, Numbered_TX_ID (31_000 + Batch), Txn, Result);
            for Slot in 1 .. 64 loop
               Put (State_DB, Txn, 1, Indexed_Key ((Batch - 1) * 64 + Slot), To_Value ([]), Result);
            end loop;
            Commit (State_DB, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
            Expect (Result, Success, "256-entry boundary commit failed");
         end loop;
         Begin_Transaction (State_DB, Numbered_TX_ID (31_005), Txn, Result);
         Put (State_DB, Txn, 1, Indexed_Key (257), To_Value ([]), Result);
         Commit (State_DB, Txn, Test_Operation_Timeout, Receipt => Receipt, Result => Result);
         Expect (Result, Capacity_Exceeded, "257th state entry was admitted");
         Rollback (Txn, Result);
         Expect (Result, Invalid_State, "admitted state-cap rejection did not consume transaction");
         Close (State_DB, Result);
         Open (State_DB, State_Context'Access, DB_ID (182), Test_Operation_Timeout, Result => Result);
         Expect (Result, Success, "256-entry state did not reopen");
         Begin_Transaction (State_DB, Numbered_TX_ID (31_006), Txn, Result);
         Get (State_DB, Txn, 1, Indexed_Key (256), Data, Result);
         Expect (Result, Success, "recovered 256th entry was absent");
         Rollback (Txn, Result);
         Close (State_DB, Result);
      end;

      declare
         Byte_Context : aliased Storage_Context;
         Byte_DB      : Database;
      begin
         Bind_Context (Byte_Context, Backend, "cap-bytes");
         Create_DB (Byte_DB, Byte_Context'Access, DB_ID (184), ID (185), Result);
         Expect (Result, Success, "byte-cap database create failed");
         declare
            --  Four exact 4,096-byte transactions fill the persisted 16 KiB
            --  batch budget; the following five-member case adds one byte.
            Transactions : Transaction_Array (1 .. 4);
            Receipts     : Commit_Receipt_Array (Transactions'Range);
         begin
            for Index in Transactions'Range loop
               Fill_Exact_Transaction (Byte_DB, Transactions (Index), 32_000 + Index, Index * 20);
            end loop;
            Commit_Group
              (Byte_DB,
               Numbered_ID (32_100),
               Transactions,
               Test_Operation_Timeout,
               Receipts => Receipts,
               Result   => Result);
            Expect (Result, Success, "exact 16-KiB group was rejected");
         end;
         declare
            Transactions : Transaction_Array (1 .. 5);
            Receipts     : Commit_Receipt_Array (Transactions'Range);
         begin
            for Index in 1 .. 4 loop
               Fill_Exact_Transaction (Byte_DB, Transactions (Index), 32_200 + Index, Index * 30);
            end loop;
            Begin_Transaction (Byte_DB, Numbered_TX_ID (32_205), Transactions (5), Result);
            Put (Byte_DB, Transactions (5), 1, Indexed_Key (999), To_Value ([1]), Result);
            Commit_Group
              (Byte_DB,
               Numbered_ID (32_300),
               Transactions,
               Test_Operation_Timeout,
               Receipts => Receipts,
               Result   => Result);
            Expect (Result, Capacity_Exceeded, "16-KiB-plus-one group was admitted");
            --  Queue-byte capacity is checked before admission; persisted live-state
            --  projection is checked after admission but before object publication.
            for Index in Transactions'Range loop
               Rollback (Transactions (Index), Result);
               Expect (Result, Success, "pre-admission byte-cap rejection consumed transaction");
            end loop;
         end;
         Close (Byte_DB, Result);
      end;
   end Test_Cap_Boundaries;

   procedure Run is
      Status                   : OS.Status;
      Before_Images_Allocated  : Interfaces.Unsigned_64;
      Before_Images_Released   : Interfaces.Unsigned_64;
      Before_Arenas_Allocated  : Interfaces.Unsigned_64;
      Before_Arenas_Released   : Interfaces.Unsigned_64;
      Before_Transaction_Bytes : Interfaces.Unsigned_64;
      Before_Source_Bytes      : Interfaces.Unsigned_64;
      Before_Sink_Bytes        : Interfaces.Unsigned_64;
      After_Images_Allocated   : Interfaces.Unsigned_64;
      After_Images_Released    : Interfaces.Unsigned_64;
      After_Arenas_Allocated   : Interfaces.Unsigned_64;
      After_Arenas_Released    : Interfaces.Unsigned_64;
      After_Transaction_Bytes  : Interfaces.Unsigned_64;
      After_Source_Bytes       : Interfaces.Unsigned_64;
      After_Sink_Bytes         : Interfaces.Unsigned_64;
   begin
      Test_Runtime_Codec;
      Testing.Image_Statistics
        (Before_Images_Allocated,
         Before_Images_Released,
         Before_Arenas_Allocated,
         Before_Arenas_Released,
         Before_Transaction_Bytes,
         Before_Source_Bytes,
         Before_Sink_Bytes);
      declare
         --  Memory-backend test capacity: four buckets, 512 objects, and eight
         --  million bytes cover the complete deterministic engine corpus while
         --  retaining explicit backend backpressure.
         Store : aliased Memory.Store (4, 512, 8_000_000);
      begin
         Store.Create_Bucket (Bucket, null, Ada.Real_Time.Time_Last, Status);
         if Status /= OS.Success then
            raise Program_Error with "memory bucket create failed";
         end if;
         declare
            Unbound         : aliased Storage_Context;
            Invalid         : Storage_Context;
            Boundary        : Storage_Context;
            Overlong        : Storage_Context;
            Item            : Database;
            Result          : Outcome_Code;
            Raised          : Boolean := False;
            --  With the longest DB suffix, 981 prefix bytes exactly reach the
            --  object-store key limit and 982 is one over. These are derived
            --  key-path boundary fixtures, not naming recommendations.
            Maximum_Prefix  : constant String (1 .. 981) := [others => 'a'];
            Too_Long_Prefix : constant String (1 .. 982) := [others => 'a'];
         begin
            Create_DB (Item, Unbound'Access, DB_ID (1), ID (2), Result);
            Expect (Result, Invalid_State, "unbound storage was accepted");
            begin
               Bind_Context (Invalid, Store'Access, "bad//prefix");
            exception
               when Program_Error =>
                  Raised := True;
            end;
            if not Raised then
               raise Program_Error with "noncanonical storage prefix was accepted";
            end if;
            Bind_Context (Boundary, Store'Access, Maximum_Prefix);
            Raised := False;
            begin
               Bind_Context (Overlong, Store'Access, Too_Long_Prefix);
            exception
               when Program_Error =>
                  Raised := True;
            end;
            if not Raised then
               raise Program_Error with "982-byte manifest-key prefix was accepted";
            end if;
         end;
         Test_CRUD_And_Recovery (Store'Access, "memory-basic", 10);
         Test_Runtime_Sized_Value (Store'Access, "memory-runtime-sized", 11);
         Test_Large_Production_Profile (Store'Access, "memory-large-profile", 12);
         Test_Dynamic_Mutation_Descriptors (Store'Access, "memory-dynamic-mutations", 13);
         Test_Allocation_Failures (Store'Access);
         Test_Manifest_And_Family_API (Store'Access);
         Test_Create_Publication (Store'Access);
         Test_Lower_Live_Budgets (Store'Access);
         Test_Recovery_Format_Edges (Store'Access);
         Test_Faults (Store'Access, "memory-faults", 40);
         Test_Admission_Group_And_Lifecycle (Store'Access);
         Test_Resolve_Drains_Queued (Store'Access);
         Test_Unaccepted_Resolve_Drains_Queued (Store'Access);
         Test_Shared_Context_Synchronization (Store'Access);
         Test_Resolve_Lifecycle (Store'Access);
         Test_Cap_Boundaries (Store'Access);
      end;

      declare
         --  Disposable files-backend campaign root under the runner's obj tree;
         --  changing it affects only retained local test artifacts.
         Root : constant String :=
           Ada.Directories.Compose
             (Ada.Directories.Compose (Ada.Directories.Current_Directory, "obj"), "files-engine");
      begin
         if Ada.Directories.Exists (Root) then
            Ada.Directories.Delete_Tree (Root);
         end if;
         declare
            --  Eight million bytes matches the memory campaign's object extent
            --  and Process_Crash_Atomic is intentionally the crash-test (not
            --  power-loss durability) policy.
            Store : aliased Files.Store :=
              Files.Open (Root, Maximum_Object_Size => 8_000_000, Commit => Files.Process_Crash_Atomic);
         begin
            Store.Create_Bucket (Bucket, null, Ada.Real_Time.Time_Last, Status);
            if Status /= OS.Success then
               raise Program_Error with "files bucket create failed";
            end if;
            Test_CRUD_And_Recovery (Store'Access, "files-basic", 20);
            Test_Runtime_Sized_Value (Store'Access, "files-runtime-sized", 21);
            Test_Large_Production_Profile (Store'Access, "files-large-profile", 22);
            Test_Dynamic_Mutation_Descriptors (Store'Access, "files-dynamic-mutations", 23);
            Test_Faults (Store'Access, "files-faults", 140);
         end;
         Ada.Directories.Delete_Tree (Root);
      end;

      Testing.Image_Statistics
        (After_Images_Allocated,
         After_Images_Released,
         After_Arenas_Allocated,
         After_Arenas_Released,
         After_Transaction_Bytes,
         After_Source_Bytes,
         After_Sink_Bytes);
      if After_Images_Allocated - Before_Images_Allocated /= After_Images_Released - Before_Images_Released
      then
         raise Program_Error
           with
             "shared batch image owner leaked across the engine suite: allocated"
             & Interfaces.Unsigned_64'Image (After_Images_Allocated - Before_Images_Allocated)
             & ", released"
             & Interfaces.Unsigned_64'Image (After_Images_Released - Before_Images_Released);
      elsif After_Arenas_Allocated - Before_Arenas_Allocated /= After_Arenas_Released - Before_Arenas_Released
      then
         raise Program_Error
           with
             "transaction arena leaked across the engine suite: allocated"
             & Interfaces.Unsigned_64'Image (After_Arenas_Allocated - Before_Arenas_Allocated)
             & ", released"
             & Interfaces.Unsigned_64'Image (After_Arenas_Released - Before_Arenas_Released);
      elsif After_Transaction_Bytes = Before_Transaction_Bytes then
         raise Program_Error with "caller-to-transaction ownership copy was not observed";
      elsif After_Source_Bytes = Before_Source_Bytes then
         raise Program_Error with "borrowed storage source did not stream an owned image";
      elsif After_Sink_Bytes = Before_Sink_Bytes then
         raise Program_Error with "owned recovery sink did not receive an image";
      end if;
   end Run;

end Flyology.DB.Engine_Tests;
