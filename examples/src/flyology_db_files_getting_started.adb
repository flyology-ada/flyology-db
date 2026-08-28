with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.DB;
with Flyology.DB.Object_Storage;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Files;

procedure Flyology_DB_Files_Getting_Started is
   package DB renames Flyology.DB;
   package Binding renames Flyology.DB.Object_Storage;
   package Files renames Flyology.Object_Storage.Backends.Files;
   package OS renames Flyology.Object_Storage;

   use type Ada.Real_Time.Time;
   use type DB.Byte;
   use type DB.Checkpoint_Run_Identity;
   use type DB.Column_Family_ID;
   use type DB.Identifier;
   use type DB.Outcome_Code;
   use type DB.Sequence_Number;
   use type DB.Transaction_Identifier;
   use type OS.Status;

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Expect (Actual, Expected : DB.Outcome_Code; Context : String) is
   begin
      if Actual /= Expected then
         raise Program_Error
           with Context & ": " & DB.Outcome_Code'Image (Actual);
      end if;
   end Expect;

   function Root_Argument return String is
   begin
      if Ada.Command_Line.Argument_Count /= 1 then
         raise Program_Error
           with
             "usage: flyology_db_files_getting_started /absolute/fresh/files-root";
      end if;
      return Ada.Command_Line.Argument (1);
   end Root_Argument;

   function Bytes (Value : String) return DB.Byte_Array is
      Result : DB.Byte_Array (1 .. Value'Length);
   begin
      for Offset in Value'Range loop
         Result (Offset - Value'First + 1) :=
           DB.Byte (Character'Pos (Value (Offset)));
      end loop;
      return Result;
   end Bytes;

   function Same
     (Left : Flyology.Bytes.Unbounded_Bytes; Right : DB.Byte_Array)
      return Boolean is
   begin
      if Flyology.Bytes.Length (Left) /= Right'Length then
         return False;
      end if;
      for Offset in Right'Range loop
         if DB.Byte (Flyology.Bytes.Element (Left, Offset - Right'First + 1))
           /= Right (Offset)
         then
            return False;
         end if;
      end loop;
      return True;
   end Same;

   function Numbered_ID (Value : DB.Byte) return DB.Identifier is
      Result : DB.Identifier := [others => 0];
   begin
      Result (Result'Last) := Value;
      return Result;
   end Numbered_ID;

   function Database_ID (Value : DB.Byte) return DB.Database_Identifier
   is (DB.Database_Identifier (Numbered_ID (Value)));

   function Transaction_ID (Value : DB.Byte) return DB.Transaction_Identifier
   is (DB.Transaction_Identifier (Numbered_ID (Value)));

   Root : constant String := Root_Argument;

   --  This walkthrough makes each operational choice explicit. The values
   --  below size only one fresh demonstration and are not library defaults or
   --  recommendations for another workload.
   Maximum_Object_Size : constant OS.Byte_Count := 65_536;
   Timeout             : constant Duration := 10.0;
   Bucket              : constant String := "flyology-db-getting-started";
   Prefix              : constant String := "database";

   Limits : constant DB.Database_Limits :=
     (Maximum_Column_Families             => 2,
      Maximum_Manifest_History            => 7,
      Maximum_Batch_History               => 4,
      Maximum_Transactions_Per_Batch      => 2,
      Maximum_Mutations_Per_Transaction   => 2,
      Maximum_Mutations_Per_Batch         => 2,
      Maximum_Live_Entries                => 4,
      Maximum_Transaction_Payload_Bytes   => 256,
      Maximum_Batch_Payload_Bytes         => 512,
      Maximum_Live_State_Bytes            => 4_096,
      Maximum_Total_L0_Runs               => 3,
      Maximum_Checkpoint_Identities       => 9,
      Maximum_Point_Reads_Per_Transaction => 4,
      Maximum_Scan_Ranges_Per_Transaction => 1);

   Families : constant DB.Column_Family_Configuration_Array :=
     [DB.Configure_Column_Family
        (ID                   => 1,
         Name                 => Bytes ("records"),
         Max_Key_Bytes        => 32,
         Max_Value_Bytes      => 64,
         Memtable_Max_Bytes   => 1_024,
         Memtable_Max_Entries => 4,
         Maximum_L0_Runs      => 2)];

   Audit_Family_Configuration : constant DB.Column_Family_Configuration :=
     DB.Configure_Column_Family
       (ID                   => 2,
        Name                 => Bytes ("audit"),
        Max_Key_Bytes        => 32,
        Max_Value_Bytes      => 64,
        Memtable_Max_Bytes   => 1_024,
        Memtable_Max_Entries => 4,
        Maximum_L0_Runs      => 1);

   --  These compact identities are distinct within this single fresh-root
   --  demonstration. They are not an allocator, reusable IDs, or production
   --  identity policy. A real application must durably allocate never-reused
   --  identities in each applicable namespace.
   Demo_Database_ID           : constant DB.Database_Identifier :=
     Database_ID (1);
   Create_Manifest_ID         : constant DB.Identifier := Numbered_ID (2);
   Create_Transition_ID       : constant DB.Identifier := Numbered_ID (3);
   Checkpoint_Transaction_ID  : constant DB.Transaction_Identifier :=
     Transaction_ID (4);
   First_Read_ID              : constant DB.Transaction_Identifier :=
     Transaction_ID (5);
   Checkpoint_Run_ID          : constant DB.Identifier := Numbered_ID (6);
   First_Flush_Manifest_ID    : constant DB.Identifier := Numbered_ID (7);
   First_Flush_Transition_ID  : constant DB.Identifier := Numbered_ID (8);
   Suffix_Transaction_ID      : constant DB.Transaction_Identifier :=
     Transaction_ID (9);
   Reopened_Read_ID           : constant DB.Transaction_Identifier :=
     Transaction_ID (10);
   Family_Manifest_ID         : constant DB.Identifier := Numbered_ID (11);
   Family_Transition_ID       : constant DB.Identifier := Numbered_ID (12);
   Audit_Transaction_ID       : constant DB.Transaction_Identifier :=
     Transaction_ID (13);
   Extended_Read_ID           : constant DB.Transaction_Identifier :=
     Transaction_ID (14);
   Suffix_Run_ID              : constant DB.Identifier := Numbered_ID (15);
   Audit_Run_ID               : constant DB.Identifier := Numbered_ID (16);
   Second_Flush_Manifest_ID   : constant DB.Identifier := Numbered_ID (17);
   Second_Flush_Transition_ID : constant DB.Identifier := Numbered_ID (18);
   Final_Read_ID              : constant DB.Transaction_Identifier :=
     Transaction_ID (19);

   Initial_Runs  : constant DB.Checkpoint_Run_Identity_Array :=
     [DB.Configure_Checkpoint_Run (1, Checkpoint_Run_ID)];
   Extended_Runs : constant DB.Checkpoint_Run_Identity_Array :=
     [DB.Configure_Checkpoint_Run (1, Suffix_Run_ID),
      DB.Configure_Checkpoint_Run (2, Audit_Run_ID)];

   Checkpoint_Key   : constant DB.Byte_Array := Bytes ("hello");
   Checkpoint_Value : constant DB.Byte_Array := Bytes ("Flyology.DB");
   Suffix_Key       : constant DB.Byte_Array := Bytes ("after-checkpoint");
   Suffix_Value     : constant DB.Byte_Array := Bytes ("live suffix");
   Audit_Key        : constant DB.Byte_Array := Bytes ("event");
   Audit_Value      : constant DB.Byte_Array := Bytes ("family appended");

   procedure Read_And_Require
     (Item        : in out DB.Database;
      Reader_ID   : DB.Transaction_Identifier;
      With_Suffix : Boolean;
      With_Audit  : Boolean;
      Context     : String)
   is
      Reader : DB.Transaction;
      Family : DB.Column_Family;
      Data   : Flyology.Bytes.Unbounded_Bytes;
      Result : DB.Outcome_Code;
   begin
      DB.Begin_Transaction (Item, Reader_ID, DB.Snapshot, Reader, Result);
      Expect (Result, DB.Success, Context & " reader begin failed");
      DB.Open_Column_Family (Item, 1, Family, Result);
      Expect (Result, DB.Success, Context & " records family open failed");
      DB.Get (Item, Reader, Family, Checkpoint_Key, Data, Result);
      Expect (Result, DB.Success, Context & " checkpoint get failed");
      Require
        (Same (Data, Checkpoint_Value),
         Context & " checkpoint value bytes differ");
      if With_Suffix then
         DB.Get (Item, Reader, Family, Suffix_Key, Data, Result);
         Expect (Result, DB.Success, Context & " suffix get failed");
         Require
           (Same (Data, Suffix_Value), Context & " suffix value bytes differ");
      end if;
      if With_Audit then
         DB.Open_Column_Family (Item, 2, Family, Result);
         Expect (Result, DB.Success, Context & " audit family open failed");
         DB.Get (Item, Reader, Family, Audit_Key, Data, Result);
         Expect (Result, DB.Success, Context & " audit get failed");
         Require
           (Same (Data, Audit_Value), Context & " audit value bytes differ");
      end if;
      DB.Rollback (Reader, Result);
      Expect (Result, DB.Success, Context & " reader rollback failed");
   exception
      when others =>
         DB.Rollback (Reader, Result);
         raise;
   end Read_And_Require;

   procedure Require_Two_Family_Registry
     (Item : in out DB.Database; Context : String)
   is
      Configuration : DB.Database_Configuration_Snapshot :=
        (Registry_Revision => 0, Family_Count => 0, Limits => Limits);
      Registry      : DB.Column_Family_Configuration_Array (1 .. 2) :=
        [Families (1), Audit_Family_Configuration];
      Family        : DB.Column_Family;
      Result        : DB.Outcome_Code;
   begin
      DB.Read_Configuration (Item, Configuration, Registry, Result);
      Expect (Result, DB.Success, Context & " registry read failed");
      Require
        (Natural (Configuration.Family_Count) = 2
         and then DB.Column_Family_Configuration_ID (Registry (1)) = 1
         and then DB.Column_Family_Configuration_ID (Registry (2)) = 2,
         Context & " registry identity/order differs");
      DB.Open_Column_Family (Item, Bytes ("audit"), Family, Result);
      Expect
        (Result, DB.Success, Context & " audit family name lookup failed");
   end Require_Two_Family_Registry;

   procedure Seed_Checkpoint_And_Suffix_Then_Close is
      Store       : aliased Files.Store :=
        Files.Open
          (Root,
           Maximum_Object_Size => Maximum_Object_Size,
           Commit              => Files.Power_Loss_Durable);
      Storage     : aliased DB.Storage_Context;
      Item        : DB.Database;
      Writer      : DB.Transaction;
      Create_Info : DB.Create_Receipt;
      Commit_Info : DB.Commit_Receipt;
      Flush_Info  : DB.Flush_Receipt;
      Result      : DB.Outcome_Code;
      Cleanup     : DB.Outcome_Code;
   begin
      Binding.Bind (Storage, Store'Access, Bucket, Prefix);
      DB.Create
        (Item,
         Storage'Access,
         Demo_Database_ID,
         Create_Manifest_ID,
         Create_Transition_ID,
         Limits,
         Families,
         Timeout,
         Receipt => Create_Info,
         Result  => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve_Create
           (Item, Storage'Access, Create_Info, Timeout, Result => Result);
      end if;
      Expect
        (Result, DB.Success, "database create did not resolve conclusively");
      Require
        (DB.Create_Receipt_Outcome (Create_Info) = DB.Success
         and then DB.Create_Receipt_Manifest_ID (Create_Info)
                  = Create_Manifest_ID
         and then DB.Create_Receipt_Transition_ID (Create_Info)
                  = Create_Transition_ID,
         "create receipt lost its exact publication identities");

      DB.Begin_Transaction
        (Item, Checkpoint_Transaction_ID, DB.Snapshot, Writer, Result);
      Expect (Result, DB.Success, "writer begin failed");
      declare
         Family : DB.Column_Family;
      begin
         DB.Open_Column_Family (Item, 1, Family, Result);
         Expect (Result, DB.Success, "family open failed");
         DB.Put
           (Item, Writer, Family, Checkpoint_Key, Checkpoint_Value, Result);
         Expect (Result, DB.Success, "put failed");
      end;
      DB.Commit
        (Item, Writer, Timeout, Receipt => Commit_Info, Result => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve (Item, Commit_Info, Timeout, Result => Result);
      end if;
      Expect (Result, DB.Success, "commit did not resolve conclusively");
      Require
        (DB.Receipt_Outcome (Commit_Info) = DB.Success
         and then DB.Receipt_Transaction_ID (Commit_Info)
                  = Checkpoint_Transaction_ID
         and then DB.Receipt_Batch_ID (Commit_Info)
                  = DB.Identifier (Checkpoint_Transaction_ID)
         and then DB.Receipt_Sequence (Commit_Info) = 1,
         "commit receipt lost its exact transaction authority");

      Read_And_Require
        (Item, First_Read_ID, False, False, "before first Flush");
      DB.Flush
        (Item,
         Initial_Runs,
         First_Flush_Manifest_ID,
         First_Flush_Transition_ID,
         Timeout,
         Receipt => Flush_Info,
         Result  => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve_Flush (Item, Flush_Info, Timeout, Result => Result);
      end if;
      Expect (Result, DB.Success, "Flush did not resolve conclusively");
      Require
        (DB.Flush_Receipt_Outcome (Flush_Info) = DB.Success
         and then DB.Flush_Receipt_Manifest_ID (Flush_Info)
                  = First_Flush_Manifest_ID
         and then DB.Flush_Receipt_Transition_ID (Flush_Info)
                  = First_Flush_Transition_ID
         and then DB.Flush_Receipt_Replay_Boundary (Flush_Info) = 1
         and then DB.Flush_Receipt_Run_Total (Flush_Info) = 1
         and then DB.Flush_Receipt_Run (Flush_Info, 1) = Initial_Runs (1),
         "first Flush receipt lost its exact checkpoint authority");

      DB.Begin_Transaction
        (Item, Suffix_Transaction_ID, DB.Snapshot, Writer, Result);
      Expect (Result, DB.Success, "suffix writer begin failed");
      declare
         Family : DB.Column_Family;
      begin
         DB.Open_Column_Family (Item, 1, Family, Result);
         Expect (Result, DB.Success, "suffix family open failed");
         DB.Put (Item, Writer, Family, Suffix_Key, Suffix_Value, Result);
         Expect (Result, DB.Success, "suffix put failed");
      end;
      DB.Commit
        (Item, Writer, Timeout, Receipt => Commit_Info, Result => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve (Item, Commit_Info, Timeout, Result => Result);
      end if;
      Expect
        (Result, DB.Success, "suffix commit did not resolve conclusively");
      Require
        (DB.Receipt_Outcome (Commit_Info) = DB.Success
         and then DB.Receipt_Transaction_ID (Commit_Info)
                  = Suffix_Transaction_ID
         and then DB.Receipt_Batch_ID (Commit_Info)
                  = DB.Identifier (Suffix_Transaction_ID)
         and then DB.Receipt_Sequence (Commit_Info) = 2,
         "suffix receipt lost its exact transaction authority");

      DB.Close (Item, Result);
      Expect (Result, DB.Success, "database close failed");
   exception
      when others =>
         DB.Rollback (Writer, Cleanup);
         DB.Close (Item, Cleanup);
         raise;
   end Seed_Checkpoint_And_Suffix_Then_Close;

   procedure Reopen_Extend_Flush_And_Close is
      Store       : aliased Files.Store :=
        Files.Open
          (Root,
           Maximum_Object_Size => Maximum_Object_Size,
           Commit              => Files.Power_Loss_Durable);
      Storage     : aliased DB.Storage_Context;
      Item        : DB.Database;
      Writer      : DB.Transaction;
      Family_Info : DB.Column_Family_Receipt;
      Commit_Info : DB.Commit_Receipt;
      Flush_Info  : DB.Flush_Receipt;
      Result      : DB.Outcome_Code;
      Cleanup     : DB.Outcome_Code;
   begin
      Binding.Bind (Storage, Store'Access, Bucket, Prefix);
      DB.Open
        (Item, Storage'Access, Demo_Database_ID, Timeout, Result => Result);
      Expect (Result, DB.Success, "database reopen failed");
      Read_And_Require
        (Item, Reopened_Read_ID, True, False, "after suffix reopen");

      DB.Add_Column_Family
        (Item,
         Audit_Family_Configuration,
         Family_Manifest_ID,
         Family_Transition_ID,
         Timeout,
         Receipt => Family_Info,
         Result  => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve_Add_Column_Family
           (Item, Family_Info, Timeout, Result => Result);
      end if;
      Expect
        (Result, DB.Success, "family append did not resolve conclusively");
      Require
        (DB.Column_Family_Receipt_Outcome (Family_Info) = DB.Success
         and then DB.Column_Family_Receipt_Family_ID (Family_Info) = 2
         and then DB.Column_Family_Receipt_Manifest_ID (Family_Info)
                  = Family_Manifest_ID
         and then DB.Column_Family_Receipt_Transition_ID (Family_Info)
                  = Family_Transition_ID,
         "family receipt lost its exact publication identities");
      Require_Two_Family_Registry (Item, "after family append");

      DB.Begin_Transaction
        (Item, Audit_Transaction_ID, DB.Snapshot, Writer, Result);
      Expect (Result, DB.Success, "audit writer begin failed");
      declare
         Family : DB.Column_Family;
      begin
         DB.Open_Column_Family (Item, 2, Family, Result);
         Expect (Result, DB.Success, "fresh audit family handle open failed");
         DB.Put (Item, Writer, Family, Audit_Key, Audit_Value, Result);
         Expect (Result, DB.Success, "audit put failed");
      end;
      DB.Commit
        (Item, Writer, Timeout, Receipt => Commit_Info, Result => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve (Item, Commit_Info, Timeout, Result => Result);
      end if;
      Expect (Result, DB.Success, "audit commit did not resolve conclusively");
      Require
        (DB.Receipt_Outcome (Commit_Info) = DB.Success
         and then DB.Receipt_Transaction_ID (Commit_Info)
                  = Audit_Transaction_ID
         and then DB.Receipt_Batch_ID (Commit_Info)
                  = DB.Identifier (Audit_Transaction_ID)
         and then DB.Receipt_Sequence (Commit_Info) = 3,
         "audit commit receipt lost its exact transaction authority");

      Read_And_Require
        (Item, Extended_Read_ID, True, True, "before two-family Flush");
      DB.Flush
        (Item,
         Extended_Runs,
         Second_Flush_Manifest_ID,
         Second_Flush_Transition_ID,
         Timeout,
         Receipt => Flush_Info,
         Result  => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve_Flush (Item, Flush_Info, Timeout, Result => Result);
      end if;
      Expect
        (Result, DB.Success, "two-family Flush did not resolve conclusively");
      Require
        (DB.Flush_Receipt_Outcome (Flush_Info) = DB.Success
         and then DB.Flush_Receipt_Manifest_ID (Flush_Info)
                  = Second_Flush_Manifest_ID
         and then DB.Flush_Receipt_Transition_ID (Flush_Info)
                  = Second_Flush_Transition_ID
         and then DB.Flush_Receipt_Replay_Boundary (Flush_Info) = 3
         and then DB.Flush_Receipt_Run_Total (Flush_Info) = 2
         and then DB.Flush_Receipt_Run (Flush_Info, 1) = Extended_Runs (1)
         and then DB.Flush_Receipt_Run (Flush_Info, 2) = Extended_Runs (2),
         "two-family Flush receipt lost its exact checkpoint authority");

      DB.Close (Item, Result);
      Expect (Result, DB.Success, "extended database close failed");
   exception
      when others =>
         DB.Rollback (Writer, Cleanup);
         DB.Close (Item, Cleanup);
         raise;
   end Reopen_Extend_Flush_And_Close;

   procedure Final_Reopen_And_Verify is
      Store   : aliased Files.Store :=
        Files.Open
          (Root,
           Maximum_Object_Size => Maximum_Object_Size,
           Commit              => Files.Power_Loss_Durable);
      Storage : aliased DB.Storage_Context;
      Item    : DB.Database;
      Result  : DB.Outcome_Code;
   begin
      Binding.Bind (Storage, Store'Access, Bucket, Prefix);
      DB.Open
        (Item, Storage'Access, Demo_Database_ID, Timeout, Result => Result);
      Expect (Result, DB.Success, "final database reopen failed");
      Require_Two_Family_Registry (Item, "after final reopen");
      Read_And_Require (Item, Final_Read_ID, True, True, "after final reopen");
      DB.Close (Item, Result);
      Expect (Result, DB.Success, "final reopened database close failed");
   exception
      when others =>
         DB.Close (Item, Result);
         raise;
   end Final_Reopen_And_Verify;

begin
   declare
      Store  : Files.Store :=
        Files.Open
          (Root,
           Maximum_Object_Size => Maximum_Object_Size,
           Commit              => Files.Power_Loss_Durable);
      Status : OS.Status;
   begin
      Store.Create_Bucket
        (Bucket,
         null,
         Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout),
         Status);
      Require (Status = OS.Success, "Files bucket creation failed");
   end;

   Seed_Checkpoint_And_Suffix_Then_Close;
   Reopen_Extend_Flush_And_Close;
   Final_Reopen_And_Verify;

   Ada.Text_IO.Put_Line
     ("Flyology.DB Files retained-checkpoint live-suffix family reopen: OK");
   Ada.Text_IO.Put_Line ("Flyology.DB Files getting started: OK");
   Ada.Text_IO.Put_Line ("Retained Files root: " & Root);
end Flyology_DB_Files_Getting_Started;
