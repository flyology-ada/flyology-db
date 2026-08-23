with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Flyology.Bytes;
with Flyology.DB.Object_Storage;
with Flyology.DB.Testing;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Files;
with GNAT.OS_Lib;

procedure Flyology.DB.Files_Crash_Probe is
   package OS renames Flyology.Object_Storage;
   package Files renames Flyology.Object_Storage.Backends.Files;
   package Testing renames Flyology.DB.Testing;

   use type OS.Status;
   use type Ada.Streams.Stream_Element;

   --  Dedicated test namespace keeps destructive crash/reopen artifacts apart
   --  from other suites; changing either component changes the filesystem
   --  fixture location only, not production object naming policy.
   Bucket : constant String := "flyology-db-crash";
   Prefix : constant String := "group";

   --  Ten seconds is a crash-runner stability budget for local object I/O; it
   --  is not a DB API default, retry policy, or persisted workload deadline.
   Test_Operation_Timeout : constant Duration := 10.0;

   function ID (Last : Flyology.DB.Byte) return Flyology.DB.Identifier is
      Result : Flyology.DB.Identifier := [others => 0];
   begin
      Result (Result'Last) := Last;
      return Result;
   end ID;

   function DB_ID (Last : Flyology.DB.Byte) return Flyology.DB.Database_Identifier
   is (Flyology.DB.Database_Identifier (ID (Last)));

   function TX_ID (Last : Flyology.DB.Byte) return Flyology.DB.Transaction_Identifier
   is (Flyology.DB.Transaction_Identifier (ID (Last)));

   --  Crash-probe persisted policy admits the exact two-transaction campaign
   --  and bounded recovery history. These are explicit test inputs, not DB
   --  defaults; the families below retain reference-sized 64/256 payloads.
   Limits   : constant Flyology.DB.Database_Limits :=
     (Maximum_Column_Families           => 2,
      Maximum_Manifest_History          => 64,
      Maximum_Batch_History             => 64,
      Maximum_Transactions_Per_Batch    => 8,
      Maximum_Mutations_Per_Transaction => 64,
      Maximum_Mutations_Per_Batch       => 64,
      Maximum_Live_Entries              => 256,
      Maximum_Transaction_Payload_Bytes => 4_096,
      Maximum_Batch_Payload_Bytes       => 16_384,
      Maximum_Live_State_Bytes          => 81_920);
   Families : constant Flyology.DB.Column_Family_Configuration_Array :=
     [Flyology.DB.Configure_Column_Family (1, [1], 64, 256),
      Flyology.DB.Configure_Column_Family (2, [2], 64, 256)];

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   --  The caller-selected disposable campaign root is the sole filesystem
   --  authority. The 100,000-byte object ceiling only bounds this test backend
   --  and must remain above every crash fixture object.
   Root   : constant String := Ada.Command_Line.Argument (2);
   Store  : aliased Files.Store :=
     Files.Open (Root, Maximum_Object_Size => 100_000, Commit => Files.Process_Crash_Atomic);
   Status : OS.Status;
begin
   Require (Ada.Command_Line.Argument_Count = 2, "expected action and root");
   if Ada.Command_Line.Argument (1) = "crash" then
      Store.Create_Bucket (Bucket, null, Ada.Real_Time.Time_Last, Status);
      Require (Status = OS.Success, "crash bucket create failed");
      declare
         Context      : aliased Flyology.DB.Storage_Context;
         Item         : Flyology.DB.Database;
         Transactions : Flyology.DB.Transaction_Array (1 .. 2);
         Receipts     : Flyology.DB.Commit_Receipt_Array (Transactions'Range);
         Create_Info  : Flyology.DB.Create_Receipt;
         Result       : Flyology.DB.Outcome_Code;
      begin
         Flyology.DB.Object_Storage.Bind (Context, Store'Access, Bucket, Prefix);
         Flyology.DB.Create
           (Item,
            Context'Access,
            DB_ID (1),
            ID (3),
            ID (2),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Require (Result = Flyology.DB.Success, "crash database create failed");
         for Index in Transactions'Range loop
            declare
               Family : Flyology.DB.Column_Family;
            begin
               Flyology.DB.Begin_Transaction
                 (Item, TX_ID (Flyology.DB.Byte (10 + Index)), Transactions (Index), Result);
               Flyology.DB.Open_Column_Family (Item, Flyology.DB.Column_Family_ID (Index), Family, Result);
               Flyology.DB.Put
                 (Item,
                  Transactions (Index),
                  Family,
                  [Flyology.DB.Byte (Index)],
                  [Flyology.DB.Byte (Index + 20)],
                  Result);
            end;
         end loop;
         Flyology.DB.Commit_Group
           (Item, ID (30), Transactions, Test_Operation_Timeout, Receipts => Receipts, Result => Result);
         Require (Result = Flyology.DB.Success, "crash group commit failed");
         GNAT.OS_Lib.OS_Exit (137);
      end;
   elsif Ada.Command_Line.Argument (1) = "verify" then
      declare
         Context : aliased Flyology.DB.Storage_Context;
         Item    : Flyology.DB.Database;
         Txn     : Flyology.DB.Transaction;
         Value   : Flyology.Bytes.Unbounded_Bytes;
         Result  : Flyology.DB.Outcome_Code;
      begin
         Flyology.DB.Object_Storage.Bind (Context, Store'Access, Bucket, Prefix);
         Flyology.DB.Open (Item, Context'Access, DB_ID (1), Test_Operation_Timeout, Result => Result);
         Require (Result = Flyology.DB.Success, "crash recovery open failed");
         Flyology.DB.Begin_Transaction (Item, TX_ID (40), Txn, Result);
         for Index in 1 .. 2 loop
            declare
               Family : Flyology.DB.Column_Family;
            begin
               Flyology.DB.Open_Column_Family (Item, Flyology.DB.Column_Family_ID (Index), Family, Result);
               Flyology.DB.Get (Item, Txn, Family, [Flyology.DB.Byte (Index)], Value, Result);
               Require
                 (Result = Flyology.DB.Success
                  and then Flyology.Bytes.Length (Value) = 1
                  and then Flyology.Bytes.Element (Value, 1) = Ada.Streams.Stream_Element (Index + 20),
                  "crash recovery exposed a partial group");
            end;
         end loop;
         Flyology.DB.Rollback (Txn, Result);
         Flyology.DB.Close (Item, Result);
         Require (Result = Flyology.DB.Success, "crash recovery close failed");
      end;
   elsif Ada.Command_Line.Argument (1) = "manifest-orphan-crash" then
      Store.Create_Bucket (Bucket, null, Ada.Real_Time.Time_Last, Status);
      Require (Status = OS.Success, "manifest-orphan bucket create failed");
      declare
         Context     : aliased Flyology.DB.Storage_Context;
         Item        : Flyology.DB.Database;
         Create_Info : Flyology.DB.Create_Receipt;
         Result      : Flyology.DB.Outcome_Code;
      begin
         Flyology.DB.Object_Storage.Bind (Context, Store'Access, Bucket, "manifest-orphan");
         Testing.Arm (Context, Before_Head_Put, Definite_Failure);
         Flyology.DB.Create
           (Item,
            Context'Access,
            DB_ID (50),
            ID (51),
            ID (52),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Require (Result = Flyology.DB.Storage_Failure, "manifest orphan reached HEAD");
         GNAT.OS_Lib.OS_Exit (137);
      end;
   elsif Ada.Command_Line.Argument (1) = "manifest-orphan-verify" then
      declare
         Context     : aliased Flyology.DB.Storage_Context;
         Item        : Flyology.DB.Database;
         Create_Info : Flyology.DB.Create_Receipt;
         Result      : Flyology.DB.Outcome_Code;
      begin
         Flyology.DB.Object_Storage.Bind (Context, Store'Access, Bucket, "manifest-orphan");
         Flyology.DB.Open (Item, Context'Access, DB_ID (50), Test_Operation_Timeout, Result => Result);
         Require (Result = Flyology.DB.Not_Found, "orphan manifest became crash-visible");
         Flyology.DB.Create
           (Item,
            Context'Access,
            DB_ID (50),
            ID (51),
            ID (52),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Require (Result = Flyology.DB.Success, "exact orphan manifest retry did not publish HEAD");
         Flyology.DB.Close (Item, Result);
         Require (Result = Flyology.DB.Success, "orphan retry close failed");
      end;
   elsif Ada.Command_Line.Argument (1) = "manifest-head-crash" then
      Store.Create_Bucket (Bucket, null, Ada.Real_Time.Time_Last, Status);
      Require (Status = OS.Success, "manifest-head bucket create failed");
      declare
         Context     : aliased Flyology.DB.Storage_Context;
         Item        : Flyology.DB.Database;
         Create_Info : Flyology.DB.Create_Receipt;
         Result      : Flyology.DB.Outcome_Code;
      begin
         Flyology.DB.Object_Storage.Bind (Context, Store'Access, Bucket, "manifest-head");
         Testing.Arm (Context, Before_Local_Activation, Definite_Failure);
         Flyology.DB.Create
           (Item,
            Context'Access,
            DB_ID (53),
            ID (54),
            ID (55),
            Limits,
            Families,
            Test_Operation_Timeout,
            Receipt => Create_Info,
            Result  => Result);
         Require
           (Result = Flyology.DB.Local_Activation_Failed, "durable HEAD lost activation classification");
         GNAT.OS_Lib.OS_Exit (137);
      end;
   elsif Ada.Command_Line.Argument (1) = "manifest-head-verify" then
      declare
         Context : aliased Flyology.DB.Storage_Context;
         Item    : Flyology.DB.Database;
         Result  : Flyology.DB.Outcome_Code;
      begin
         Flyology.DB.Object_Storage.Bind (Context, Store'Access, Bucket, "manifest-head");
         Flyology.DB.Open (Item, Context'Access, DB_ID (53), Test_Operation_Timeout, Result => Result);
         Require (Result = Flyology.DB.Success, "durable HEAD did not recover after process loss");
         Flyology.DB.Close (Item, Result);
         Require (Result = Flyology.DB.Success, "durable HEAD recovery close failed");
      end;
   else
      raise Program_Error with "unknown crash-probe action";
   end if;
end Flyology.DB.Files_Crash_Probe;
