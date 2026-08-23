with Ada.Directories;
with Ada.Real_Time;
with Interfaces;
with Flyology.Cancellation;
with Flyology.DB.Object_Storage;
with Flyology.DB.Testing;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends;
with Flyology.Object_Storage.Backends.Files;
with Flyology.Object_Storage.Backends.Memory;

package body Flyology.DB.Engine_Tests is

   package Binding renames Flyology.DB.Object_Storage;
   package Testing renames Flyology.DB.Testing;
   package OS renames Flyology.Object_Storage;
   package Backends renames Flyology.Object_Storage.Backends;
   package Files renames Flyology.Object_Storage.Backends.Files;
   package Memory renames Flyology.Object_Storage.Backends.Memory;

   use type Byte;
   use type Interfaces.Unsigned_64;
   use type OS.Status;

   Bucket : constant String := "flyology-db-tests";

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
      Key_A        : constant Key := To_Key ([16#00#, 16#FF#]);
      Empty_Key    : constant Key := To_Key ([]);
      Value_One    : constant Value := To_Value ([16#01#, 16#02#]);
      Value_Two    : constant Value := To_Value ([16#80#]);
      Empty_Value  : constant Value := To_Value ([]);
      Database_ID  : constant Database_Identifier := DB_ID (Tag);
   begin
      Bind_Context (Context, Backend, Prefix);
      Create (Item, Context'Access, Database_ID, ID (Tag + 1), 10.0, Result => Result);
      Expect (Result, Success, "create failed");
      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
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
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
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
               Commit (Item, Local_Txn, 10.0, Receipt => Local_Receipt, Result => Local_Result);
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
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "delete commit failed");
      Close (Item, Result);
      Expect (Result, Success, "first close failed");

      Bind_Context (Lost_Context, Backend, Prefix);
      Open (Reopened, Lost_Context'Access, Database_ID, 10.0, Result => Result);
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
      Key_A              : constant Key := To_Key ([16#61#]);
      Value_A            : constant Value := To_Value ([16#62#]);
      Database_ID        : constant Database_Identifier := DB_ID (Tag);
   begin
      Bind_Context (Context, Backend, Prefix);
      Testing.Arm (Context, After_Head_Put, Unknown_After_Entry);
      Testing.Arm (Context, Before_Get, Definite_Failure);
      Create (Item, Context'Access, Database_ID, ID (Tag + 1), 10.0, Result => Result);
      Expect (Result, Outcome_Unknown, "lost create response was falsely classified without a read");
      Create (Retry, Context'Access, Database_ID, ID (Tag + 1), 10.0, Result => Result);
      Expect (Result, Success, "identical create retry was not idempotent");
      Close (Retry, Result);
      Expect (Result, Success, "identical create retry did not close");
      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
      Expect (Result, Success, "database did not open after identical create retry");
      Create (Rival, Context'Access, Database_ID, ID (Tag + 13), 10.0, Result => Result);
      Expect (Result, Already_Exists, "different creator was mistaken for own lost response");

      Begin_Transaction (Item, TX_ID (Tag + 2), Txn, Result);
      Put (Item, Txn, 1, Key_A, Value_A, Result);
      Testing.Arm (Context, Before_Batch_Put, Definite_Failure);
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
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
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "unknown batch put was not byte-reconciled before HEAD");

      Begin_Transaction (Item, TX_ID (Tag + 4), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#63#]), Value_A, Result);
      Testing.Arm (Context, Before_Head_Put, Definite_Failure);
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
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
         Commit_Group (Item, ID (Tag + 4), Transactions, 10.0, Receipts => Receipts, Result => Result);
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
      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
      Expect (Result, Success, "orphan replay setup did not reopen");
      Begin_Transaction (Item, TX_ID (Tag + 4), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#63#]), Value_A, Result);
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Conflict, "orphan batch was replayed after local reservation loss");
      Rollback (Txn, Result);
      Expect (Result, Invalid_State, "admitted orphan replay did not consume transaction");
      Close (Item, Result);
      Expect (Result, Success, "orphan replay fence did not close");
      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
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
         Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
         Expect (Result, Outcome_Unknown, "lost HEAD response was not ambiguous");
         if Receipt_Outcome (Receipt) /= Outcome_Unknown then
            raise Program_Error with "ambiguous receipt lost its outcome";
         end if;

         Get (Item, Reader, 1, Key_A, Data, Result);
         Expect (Result, Outcome_Unknown, "active reader bypassed uncertain writer state");
         Get (Item, Group (1), 1, To_Key ([16#72#]), Data, Result);
         Expect (Result, Outcome_Unknown, "buffered own write bypassed uncertain writer state");
         Put (Item, Group (1), 1, To_Key ([16#74#]), Value_A, Result);
         Expect (Result, Outcome_Unknown, "active transaction buffered Put while uncertain");
         Delete (Item, Group (1), 1, To_Key ([16#72#]), Result);
         Expect (Result, Outcome_Unknown, "active transaction buffered Delete while uncertain");
         Commit
           (Item, Singleton, 10.0, Receipt => Rejected_Receipt, Result => Result);
         Expect (Result, Outcome_Unknown, "singleton commit entered admission while uncertain");
         if Receipt_Transaction_ID (Rejected_Receipt) /= Zero_Transaction_ID
           or else Receipt_Batch_ID (Rejected_Receipt) /= Zero_Identifier
         then
            raise Program_Error with "uncertain singleton rejection returned an admitted receipt";
         end if;
         Rollback (Singleton, Result);
         Expect (Result, Success, "uncertain singleton rejection consumed its transaction");
         Commit_Group
           (Item, ID (Tag + 24), Group, 10.0, Receipts => Rejected_Receipts, Result => Result);
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
      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
      Expect (Result, Success, "uncertain database did not recover after reopen");
      Resolve (Item, Receipt, 10.0, Result => Result);
      Expect (Result, Success, "self-contained receipt did not resolve after reopen");
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
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Outcome_Unknown, "unaccepted HEAD ambiguity was not retained");
      Resolve (Item, Receipt, 10.0, Result => Result);
      Expect (Result, Outcome_Unknown, "unreachable HEAD attempt was falsely confirmed");
      Unaccepted_Receipt := Receipt;
      Close (Item, Result);
      Expect (Result, Success, "unresolved database did not close cleanly");
      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
      Expect (Result, Success, "database did not reopen after unresolved HEAD");

      Open (Other, Context'Access, Database_ID, 10.0, Result => Result);
      Expect (Result, Success, "second writer open failed");
      Begin_Transaction (Item, TX_ID (Tag + 6), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#65#]), Value_A, Result);
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "leading writer commit failed");
      Begin_Transaction (Item, TX_ID (Tag + 12), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#69#]), Value_A, Result);
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "later successor commit failed");
      Begin_Transaction (Other, TX_ID (Tag + 7), Txn, Result);
      Put (Other, Txn, 1, To_Key ([16#66#]), Value_A, Result);
      Commit (Other, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Stale_Writer, "stale generation was not fenced");
      Resolve (Item, Unaccepted_Receipt, 10.0, Result => Result);
      Expect (Result, Stale_Writer, "later validated successor chain did not reject lost attempt");

      Close (Other, Result);
      Expect (Result, Success, "stale writer close failed");
      Close (Item, Result);
      Expect (Result, Success, "fault database close failed");

      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
      Expect (Result, Success, "fault database reopen failed");
      Begin_Transaction (Item, TX_ID (Tag + 8), Txn, Result);
      Get (Item, Txn, 2, To_Key ([16#64#]), Data, Result);
      Expect (Result, Success, "resolved value was not visible after reopen");
      Rollback (Txn, Result);
      Begin_Transaction (Item, TX_ID (Tag + 10), Txn, Result);
      Put (Item, Txn, 1, To_Key ([16#70#]), Value_A, Result);
      Stop.Request;
      Commit (Item, Txn, 10.0, Stop'Access, Receipt, Result);
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
      Database_ID  : constant Database_Identifier := DB_ID (80);
      Item_Key     : constant Key := To_Key ([1]);
      Item_Value   : constant Value := To_Value ([2]);
      Pooled_Batch : Identifier := Zero_Identifier;

      procedure Wait_For_Queue (Minimum : Natural) is
         Depth : Natural := 0;
         Query : Outcome_Code;
      begin
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
      Create (Item, Context'Access, Database_ID, ID (81), 10.0, Result => Result);
      Expect (Result, Success, "admission database create failed");

      Begin_Transaction (Item, TX_ID (82), Txn, Result);
      Put (Item, Txn, 1, Item_Key, Item_Value, Result);
      Stop.Request;
      Commit (Item, Txn, 10.0, Stop'Access, Receipt, Result);
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
      Commit (Item, Txn, 0.0, Receipt => Receipt, Result => Result);
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
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Success, "conflict setup commit failed");
      Commit (Item, Other_Txn, 10.0, Receipt => Receipt, Result => Result);
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
         Commit_Group (Item, ID (200), Transactions, 10.0, Receipts => Receipts, Result => Result);
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
         Commit (Item, Preexisting, 10.0, Receipt => Rejected_Receipt, Result => Result);
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
         Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "post-group collision regression commit failed");
         if Receipt_Batch_ID (Receipt) = Pooled_Batch then
            raise Program_Error with "group and successor reused one structural batch identity";
         end if;
         Begin_Transaction (Item, TX_ID (88), Transactions (2), Result);
         Put (Item, Transactions (2), 2, To_Key ([88]), Item_Value, Result);
         Commit_Group (Item, ID (203), Transactions, 10.0, Receipts => Receipts, Result => Result);
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
         Commit_Group (Item, ID (206), Transactions, 10.0, Receipts => Receipts, Result => Result);
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
         Commit_Group (Item, ID (87), Transactions, 10.0, Receipts => Receipts, Result => Result);
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
         Commit_Group (Item, ID (201), Transactions, 10.0, Receipts => Receipts, Result => Result);
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
         Commit_Group (Item, ID (204), Transactions, 10.0, Receipts => Receipts, Result => Result);
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
         Commit_Group (Item, ID (207), Reuse_Candidates, 10.0, Receipts => Reuse_Receipts, Result => Result);
         Expect (Result, Conflict, "different group reused an admitted orphan member identity");
         Rollback (Reuse_Candidates (1), Result);
         Expect (Result, Success, "member-reuse rejection consumed the rejected transaction");
         Commit (Item, Reuse_Candidates (2), 10.0, Receipt => Receipt, Result => Result);
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
            Commit (Item, Local_Txn, 0.05, Receipt => Local_Receipt, Result => Local_Result);
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
            Commit (Item, Local_Txn, 10.0, Receipt => Local_Receipt, Result => Local_Result);
            accept Finish (Call_Result : out Outcome_Code) do
               Call_Result := Local_Result;
            end Finish;
         end Long_Call;

         Short_Result, Short_Rollback, Long_Result : Outcome_Code;
      begin
         Wait_For_Queue (2);
         delay 0.10;
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
            Commit (Item, Local_Txn, 10.0, Late_Stop'Access, Local_Receipt, Local_Result);
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
            Commit_Group (Item, ID (202), Transactions, 10.0, Receipts => Receipts, Result => Local_Result);
            accept Finish (Call_Result : out Outcome_Code) do
               Call_Result := Local_Result;
            end Finish;
         end Full_Group;

         Group_Result : Outcome_Code;
      begin
         Wait_For_Queue (Maximum_Group_Transactions);
         Begin_Transaction (Item, TX_ID (130), Txn, Result);
         Put (Item, Txn, 1, To_Key ([130]), Item_Value, Result);
         Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
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
            Commit (Item, Local_Txn, 10.0, Receipt => Local_Receipt, Result => Local_Result);
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
         Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
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
         Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
         Expect (Result, Success, "confirmed durable HEAD was downgraded by local install failure");

         Get (Item, Reader, 1, Item_Key, Read_Data, Result);
         Expect (Result, Stale_Writer, "active reader observed stale state after local install failure");
         Get (Item, Buffered (1), 1, To_Key ([116]), Read_Data, Result);
         Expect (Result, Stale_Writer, "buffered write bypassed the fenced read path");
         Put (Item, Buffered (1), 1, To_Key ([118]), Item_Value, Result);
         Expect (Result, Stale_Writer, "active transaction buffered a Put while fenced");
         Delete (Item, Buffered (1), 1, To_Key ([116]), Result);
         Expect (Result, Stale_Writer, "active transaction buffered a Delete while fenced");
         Commit_Group (Item, ID (119), Buffered, 10.0, Receipts => Group_Receipt, Result => Result);
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
      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
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

   procedure Test_Shared_Context_Synchronization (Backend : not null access Backends.Backend'Class) is
      Context                                            : aliased Storage_Context;
      First                                              : aliased Database;
      Second                                             : aliased Database;
      Result                                             : Outcome_Code;
      Before_Batch, Before_Head, After_Batch, After_Head : Natural;
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
            Commit (Target.all, Txn, 10.0, Receipt => Receipt, Result => Outcome);
         end if;
         accept Finish (Call_Result : out Outcome_Code) do
            Call_Result := Outcome;
         end Finish;
      end Commit_Call;
   begin
      Bind_Context (Context, Backend, "shared-context");
      Create (First, Context'Access, Database_ID, ID (141), 10.0, Result => Result);
      Expect (Result, Success, "shared-context database create failed");
      Open (Second, Context'Access, Database_ID, 10.0, Result => Result);
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
      Database_ID       : constant Database_Identifier := DB_ID (150);
   begin
      Bind_Context (Context, Backend, "resolve-lifecycle");
      Create (Item, Context'Access, Database_ID, ID (151), 10.0, Result => Result);
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
      Commit (Item, Ambiguous, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Outcome_Unknown, "resolve-lifecycle ambiguity was not retained");

      Testing.Pause_Gets (Context);
      declare
         task Resolver is
            entry Finish (Call_Result : out Outcome_Code);
         end Resolver;

         task body Resolver is
            Local_Result : Outcome_Code;
         begin
            Resolve (Item, Receipt, 10.0, Result => Local_Result);
            accept Finish (Call_Result : out Outcome_Code) do
               Call_Result := Local_Result;
            end Finish;
         end Resolver;

         Resolve_Result : Outcome_Code;
      begin
         for Attempt in 1 .. 2_000 loop
            Waiting := Testing.Get_Waiting (Context);
            exit when Waiting;
            delay 0.001;
         end loop;
         if not Waiting then
            Testing.Resume_Gets (Context);
            raise Program_Error with "resolve did not reach the deterministic storage barrier";
         end if;

         Close (Item, Close_Result);
         Highest_Visible (Item, Highest, Highest_Result);
         Begin_Transaction (Item, TX_ID (155), Rejected, Begin_Result);
         Get (Item, Reader, 1, To_Key ([1]), Data, Get_Result);
         Commit (Item, Candidate, 10.0, Receipt => Candidate_Receipt, Result => Commit_Result);
         Testing.Resume_Gets (Context);
         Resolver.Finish (Resolve_Result);

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
      Database_ID : constant Database_Identifier := DB_ID (180);

      function Indexed_Key (Index : Natural) return Key
      is (To_Key ([Byte ((Index / 256) mod 256), Byte (Index mod 256)]));

      procedure Fill_Exact_Transaction
        (DB : in out Database; Target : in out Transaction; Identity : Natural; Seed : Natural)
      is
         Key_Bytes   : Byte_Array (1 .. Maximum_Key_Bytes);
         Value_Bytes : Byte_Array (1 .. Maximum_Value_Bytes);
      begin
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
      Create (Item, Context'Access, Database_ID, ID (181), 10.0, Result => Result);
      Expect (Result, Success, "history-cap database create failed");
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
               10.0,
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
      Commit (Item, Txn, 10.0, Receipt => Receipt, Result => Result);
      Expect (Result, Capacity_Exceeded, "65th history batch was admitted");
      Rollback (Txn, Result);
      Expect (Result, Success, "history-cap rejection consumed transaction");
      Close (Item, Result);
      Open (Item, Context'Access, Database_ID, 10.0, Result => Result);
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
         Create (Reservation_DB, Reservation_Context'Access, DB_ID (186), ID (187), 10.0, Result => Result);
         Expect (Result, Success, "reservation-cap database create failed");
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
                  10.0,
                  Receipts => Receipts,
                  Result   => Result);
               Expect (Result, Storage_Failure, "admitted reservation-cap group did not fail");
            end;
         end loop;
         Begin_Transaction (Reservation_DB, Numbered_TX_ID (50_000), Txn, Result);
         Expect (Result, Success, "reservation-cap one-over transaction did not begin");
         Delete (Reservation_DB, Txn, 1, Indexed_Key (2), Result);
         Commit (Reservation_DB, Txn, 10.0, Receipt => Receipt, Result => Result);
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
         Open (Reservation_DB, Reservation_Context'Access, DB_ID (186), 10.0, Result => Result);
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
         Create (State_DB, State_Context'Access, DB_ID (182), ID (183), 10.0, Result => Result);
         Expect (Result, Success, "state-cap database create failed");
         for Batch in 1 .. 4 loop
            Begin_Transaction (State_DB, Numbered_TX_ID (31_000 + Batch), Txn, Result);
            for Slot in 1 .. 64 loop
               Put (State_DB, Txn, 1, Indexed_Key ((Batch - 1) * 64 + Slot), To_Value ([]), Result);
            end loop;
            Commit (State_DB, Txn, 10.0, Receipt => Receipt, Result => Result);
            Expect (Result, Success, "256-entry boundary commit failed");
         end loop;
         Begin_Transaction (State_DB, Numbered_TX_ID (31_005), Txn, Result);
         Put (State_DB, Txn, 1, Indexed_Key (257), To_Value ([]), Result);
         Commit (State_DB, Txn, 10.0, Receipt => Receipt, Result => Result);
         Expect (Result, Capacity_Exceeded, "257th state entry was admitted");
         Rollback (Txn, Result);
         Expect (Result, Success, "state-cap rejection consumed transaction");
         Close (State_DB, Result);
         Open (State_DB, State_Context'Access, DB_ID (182), 10.0, Result => Result);
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
         Create (Byte_DB, Byte_Context'Access, DB_ID (184), ID (185), 10.0, Result => Result);
         Expect (Result, Success, "byte-cap database create failed");
         declare
            Transactions : Transaction_Array (1 .. 4);
            Receipts     : Commit_Receipt_Array (Transactions'Range);
         begin
            for Index in Transactions'Range loop
               Fill_Exact_Transaction (Byte_DB, Transactions (Index), 32_000 + Index, Index * 20);
            end loop;
            Commit_Group
              (Byte_DB, Numbered_ID (32_100), Transactions, 10.0, Receipts => Receipts, Result => Result);
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
              (Byte_DB, Numbered_ID (32_300), Transactions, 10.0, Receipts => Receipts, Result => Result);
            Expect (Result, Capacity_Exceeded, "16-KiB-plus-one group was admitted");
            for Index in Transactions'Range loop
               Rollback (Transactions (Index), Result);
               Expect (Result, Success, "byte-cap rejection consumed transaction");
            end loop;
         end;
         Close (Byte_DB, Result);
      end;
   end Test_Cap_Boundaries;

   procedure Run is
      Status : OS.Status;
   begin
      declare
         Store : aliased Memory.Store (4, 512, 1_000_000);
      begin
         Store.Create_Bucket (Bucket, null, Ada.Real_Time.Time_Last, Status);
         if Status /= OS.Success then
            raise Program_Error with "memory bucket create failed";
         end if;
         declare
            Unbound : aliased Storage_Context;
            Invalid : Storage_Context;
            Item    : Database;
            Result  : Outcome_Code;
            Raised  : Boolean := False;
         begin
            Create (Item, Unbound'Access, DB_ID (1), ID (2), 1.0, Result => Result);
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
         end;
         Test_CRUD_And_Recovery (Store'Access, "memory-basic", 10);
         Test_Faults (Store'Access, "memory-faults", 40);
         Test_Admission_Group_And_Lifecycle (Store'Access);
         Test_Shared_Context_Synchronization (Store'Access);
         Test_Resolve_Lifecycle (Store'Access);
         Test_Cap_Boundaries (Store'Access);
      end;

      declare
         Root : constant String :=
           Ada.Directories.Compose
             (Ada.Directories.Compose (Ada.Directories.Current_Directory, "obj"), "files-engine");
      begin
         if Ada.Directories.Exists (Root) then
            Ada.Directories.Delete_Tree (Root);
         end if;
         declare
            Store : aliased Files.Store :=
              Files.Open (Root, Maximum_Object_Size => 100_000, Commit => Files.Process_Crash_Atomic);
         begin
            Store.Create_Bucket (Bucket, null, Ada.Real_Time.Time_Last, Status);
            if Status /= OS.Success then
               raise Program_Error with "files bucket create failed";
            end if;
            Test_CRUD_And_Recovery (Store'Access, "files-basic", 20);
            Test_Faults (Store'Access, "files-faults", 140);
         end;
         Ada.Directories.Delete_Tree (Root);
      end;
   end Run;

end Flyology.DB.Engine_Tests;
