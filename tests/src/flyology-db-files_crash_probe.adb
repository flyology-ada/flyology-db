with Ada.Command_Line;
with Ada.Real_Time;
with Flyology.DB.Object_Storage;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Files;
with GNAT.OS_Lib;

procedure Flyology.DB.Files_Crash_Probe is
   package OS renames Flyology.Object_Storage;
   package Files renames Flyology.Object_Storage.Backends.Files;

   use type OS.Status;

   Bucket : constant String := "flyology-db-crash";
   Prefix : constant String := "group";

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

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

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
         Result       : Flyology.DB.Outcome_Code;
      begin
         Flyology.DB.Object_Storage.Bind (Context, Store'Access, Bucket, Prefix);
         Flyology.DB.Create (Item, Context'Access, DB_ID (1), ID (2), 10.0, Result => Result);
         Require (Result = Flyology.DB.Success, "crash database create failed");
         for Index in Transactions'Range loop
            Flyology.DB.Begin_Transaction
              (Item, TX_ID (Flyology.DB.Byte (10 + Index)), Transactions (Index), Result);
            Flyology.DB.Put
              (Item,
               Transactions (Index),
               Flyology.DB.Column_Family_ID (Index),
               Flyology.DB.To_Key ([Flyology.DB.Byte (Index)]),
               Flyology.DB.To_Value ([Flyology.DB.Byte (Index + 20)]),
               Result);
         end loop;
         Flyology.DB.Commit_Group (Item, ID (30), Transactions, 10.0, Receipts => Receipts, Result => Result);
         Require (Result = Flyology.DB.Success, "crash group commit failed");
         GNAT.OS_Lib.OS_Exit (137);
      end;
   elsif Ada.Command_Line.Argument (1) = "verify" then
      declare
         Context : aliased Flyology.DB.Storage_Context;
         Item    : Flyology.DB.Database;
         Txn     : Flyology.DB.Transaction;
         Value   : Flyology.DB.Value;
         Result  : Flyology.DB.Outcome_Code;
      begin
         Flyology.DB.Object_Storage.Bind (Context, Store'Access, Bucket, Prefix);
         Flyology.DB.Open (Item, Context'Access, DB_ID (1), 10.0, Result => Result);
         Require (Result = Flyology.DB.Success, "crash recovery open failed");
         Flyology.DB.Begin_Transaction (Item, TX_ID (40), Txn, Result);
         for Index in 1 .. 2 loop
            Flyology.DB.Get
              (Item,
               Txn,
               Flyology.DB.Column_Family_ID (Index),
               Flyology.DB.To_Key ([Flyology.DB.Byte (Index)]),
               Value,
               Result);
            Require
              (Result = Flyology.DB.Success
               and then Value = Flyology.DB.To_Value ([Flyology.DB.Byte (Index + 20)]),
               "crash recovery exposed a partial group");
         end loop;
         Flyology.DB.Rollback (Txn, Result);
         Flyology.DB.Close (Item, Result);
         Require (Result = Flyology.DB.Success, "crash recovery close failed");
      end;
   else
      raise Program_Error with "unknown crash-probe action";
   end if;
end Flyology.DB.Files_Crash_Probe;
