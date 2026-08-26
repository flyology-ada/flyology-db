with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.DB;
with Flyology.DB.Object_Storage;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Files;

procedure Flyology_DB_Limited_E2E is
   package DB renames Flyology.DB;
   package Binding renames Flyology.DB.Object_Storage;
   package Files renames Flyology.Object_Storage.Backends.Files;
   package OS renames Flyology.Object_Storage;

   use type DB.Byte;
   use type DB.Checkpoint_Run_Identity;
   use type DB.Column_Family_ID;
   use type DB.Identifier;
   use type DB.L0_Checkpoint_Action;
   use type DB.Outcome_Code;
   use type DB.Sequence_Number;
   use type OS.Status;
   use type Ada.Real_Time.Time;

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Expect (Actual, Expected : DB.Outcome_Code; Context : String) is
   begin
      if Actual /= Expected then
         raise Program_Error with Context & ": " & DB.Outcome_Code'Image (Actual);
      end if;
   end Expect;

   procedure Expect_Checkpoint_Requirement
     (Item     : in out DB.Database;
      Expected : DB.L0_Checkpoint_Action;
      Families : Natural;
      Context  : String)
   is
      Requirement : DB.L0_Checkpoint_Requirement;
      Result      : DB.Outcome_Code;
   begin
      DB.Observe_L0_Checkpoint_Requirement (Item, Requirement, Result);
      Expect (Result, DB.Success, Context & " query failed");
      if DB.Checkpoint_Requirement_Action (Requirement) /= Expected
        or else DB.Checkpoint_Requirement_Family_Total (Requirement) /= Families
      then
         raise Program_Error with
           Context & ": " & DB.L0_Checkpoint_Action'Image (DB.Checkpoint_Requirement_Action (Requirement));
      end if;
      for Index in Positive range 1 .. Families loop
         Require
           (DB.Checkpoint_Requirement_Family (Requirement, Index) = DB.Column_Family_ID (Index),
            Context & " family projection differs from registry order");
      end loop;
   end Expect_Checkpoint_Requirement;

   function Root_Argument return String is
   begin
      if Ada.Command_Line.Argument_Count /= 1 then
         raise Program_Error with "usage: flyology_db_limited_e2e FILES_ROOT";
      end if;
      return Ada.Command_Line.Argument (1);
   end Root_Argument;

   function Bytes (Value : String) return DB.Byte_Array is
      Result : DB.Byte_Array (1 .. Value'Length);
   begin
      for Offset in Natural range 0 .. Value'Length - 1 loop
         Result (Offset + 1) := DB.Byte (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Same (Left : Flyology.Bytes.Unbounded_Bytes; Right : DB.Byte_Array) return Boolean is
   begin
      if Flyology.Bytes.Length (Left) /= Right'Length then
         return False;
      end if;
      for Offset in Natural range 0 .. Right'Length - 1 loop
         if DB.Byte (Flyology.Bytes.Element (Left, Offset + 1)) /= Right (Right'First + Offset) then
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

   --  This files-backend request ceiling exceeds every object admitted by the
   --  fixture's persisted 4-KiB live-state bound. It is showcase geometry, not
   --  a DB or provider default.
   Maximum_Object_Size : constant OS.Byte_Count := 65_536;

   --  Names isolate the temporary showcase namespace. They are not DB object
   --  naming defaults and are discarded with the runner-owned temporary root.
   Bucket            : constant String := "flyology-db-limited-e2e";
   Prefix            : constant String := "database";
   --  Ten seconds bounds each local synchronous operation in this executable.
   --  It is fixture stability geometry, not a library timeout or retry budget.
   Operation_Timeout : constant Duration := 10.0;

   --  The persisted limits admit exactly this one-family root, one appended
   --  family, three additive Flush checkpoints, one adjacent compaction, and
   --  one complete replacement. Nine identity slots cover the fixture's six
   --  singleton and three group/batch identities exactly. These are explicit
   --  database creation authority, never implicit product defaults.
   Limits   : constant DB.Database_Limits :=
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
      Maximum_Total_L0_Runs               => 4,
      Maximum_Checkpoint_Identities       => 9,
      Maximum_Point_Reads_Per_Transaction => 8,
      Maximum_Scan_Ranges_Per_Transaction => 2);
   --  The root family admits the fixture's short account bytes, four live
   --  rows, and one run from each explicit Flush. These are exact persisted
   --  fixture limits, not database-wide hard-coded policy.
   Initial_Families : constant DB.Column_Family_Configuration_Array :=
     [DB.Configure_Column_Family
        (1,
         Bytes ("accounts"),
         Max_Key_Bytes        => 32,
         Max_Value_Bytes      => 64,
         Memtable_Max_Bytes   => 1_024,
         Memtable_Max_Entries => 4,
         Maximum_L0_Runs      => 2)];
   --  The appended family independently supplies its exact name and bounds;
   --  Add_Column_Family derives no default from the root family.
   Audit_Family : constant DB.Column_Family_Configuration :=
     DB.Configure_Column_Family
       (2,
        Bytes ("audit"),
        Max_Key_Bytes        => 48,
        Max_Value_Bytes      => 96,
        Memtable_Max_Bytes   => 1_024,
        Memtable_Max_Entries => 4,
        Maximum_L0_Runs      => 2);

   --  Stable one-byte-tail identities make every application transaction,
   --  immutable run, manifest, and HEAD transition visibly distinct in this
   --  fresh namespace. They are deterministic fixture identities, not an ID
   --  allocation algorithm or persisted tag convention.
   First_Run_ID  : constant DB.Identifier := Numbered_ID (6);
   Second_Run_ID : constant DB.Identifier := Numbered_ID (16);
   First_Runs  : constant DB.Checkpoint_Run_Identity_Array :=
     [DB.Configure_Checkpoint_Run (1, First_Run_ID)];
   Second_Runs : constant DB.Checkpoint_Run_Identity_Array :=
     [DB.Configure_Checkpoint_Run (1, Second_Run_ID),
      DB.Configure_Checkpoint_Run (2, Numbered_ID (17))];
   --  IDs 20 through 22 are the caller-owned adjacent-compaction output,
   --  immutable successor, and HEAD transition. They extend the fixture's
   --  stable identity sequence; they are not an allocator or product policy.
   Merged_Run_ID        : constant DB.Identifier := Numbered_ID (20);
   Merged_Manifest_ID   : constant DB.Identifier := Numbered_ID (21);
   Merged_Transition_ID : constant DB.Identifier := Numbered_ID (22);
   --  IDs 25 through 33 carry two explicit post-merge transactions, the
   --  intervening sparse Flush, and the exact two-family replacement. They
   --  extend fixture identity geometry and do not define allocation policy.
   Third_Run_ID          : constant DB.Identifier := Numbered_ID (26);
   Third_Runs            : constant DB.Checkpoint_Run_Identity_Array :=
     [DB.Configure_Checkpoint_Run (1, Third_Run_ID)];
   Final_Runs            : constant DB.Checkpoint_Run_Identity_Array :=
     [DB.Configure_Checkpoint_Run (1, Numbered_ID (30)),
      DB.Configure_Checkpoint_Run (2, Numbered_ID (31))];

   procedure Verify_Recovered_State (Item : in out DB.Database; Reader_ID : DB.Transaction_Identifier) is
      Reader           : DB.Transaction;
      Accounts_View    : DB.Column_Family;
      Audit_View       : DB.Column_Family;
      Data             : Flyology.Bytes.Unbounded_Bytes;
      Rows             : DB.Scan_Result;
      Row_Key          : Flyology.Bytes.Unbounded_Bytes;
      Row_Value        : Flyology.Bytes.Unbounded_Bytes;
      Visible          : DB.Sequence_Number;
      Local_Result     : DB.Outcome_Code;
      --  The endpoint bytes are ignored because both flags below are false;
      --  this neutral placeholder does not encode a key bound or policy.
      Ignored_Endpoint : constant DB.Byte_Array := [0];
   begin
      DB.Begin_Transaction (Item, Reader_ID, DB.Snapshot, Reader, Local_Result);
      Expect (Local_Result, DB.Success, "reader begin failed");
      DB.Open_Column_Family (Item, 1, Accounts_View, Local_Result);
      Expect (Local_Result, DB.Success, "accounts lookup by ID failed");
      DB.Open_Column_Family (Item, Bytes ("audit"), Audit_View, Local_Result);
      Expect (Local_Result, DB.Success, "audit lookup by name failed");

      DB.Get (Item, Reader, Accounts_View, Bytes ("alice"), Data, Local_Result);
      Expect (Local_Result, DB.Not_Found, "deleted account became visible");
      DB.Get (Item, Reader, Accounts_View, Bytes ("bob"), Data, Local_Result);
      Expect (Local_Result, DB.Success, "surviving account read failed");
      Require (Same (Data, Bytes ("300")), "surviving account has wrong bytes");

      DB.Scan
        (Item, Reader, Accounts_View, False, Ignored_Endpoint, False, Ignored_Endpoint, Rows, Local_Result);
      Expect (Local_Result, DB.Success, "accounts scan failed");
      Require (DB.Scan_Row_Count (Rows) = 1, "accounts scan row count is not one");
      DB.Read_Scan_Row (Rows, 1, Row_Key, Row_Value, Local_Result);
      Expect (Local_Result, DB.Success, "accounts scan row read failed");
      Require
        (Same (Row_Key, Bytes ("bob")) and then Same (Row_Value, Bytes ("300")),
         "accounts scan returned wrong bytes");

      DB.Scan
        (Item, Reader, Audit_View, False, Ignored_Endpoint, False, Ignored_Endpoint, Rows, Local_Result);
      Expect (Local_Result, DB.Success, "audit scan failed");
      Require (DB.Scan_Row_Count (Rows) = 2, "audit scan row count is not two");
      DB.Read_Scan_Row (Rows, 1, Row_Key, Row_Value, Local_Result);
      Expect (Local_Result, DB.Success, "first audit row read failed");
      Require
        (Same (Row_Key, Bytes ("event-1")) and then Same (Row_Value, Bytes ("created")),
         "first audit row is not canonical");
      DB.Read_Scan_Row (Rows, 2, Row_Key, Row_Value, Local_Result);
      Expect (Local_Result, DB.Success, "second audit row read failed");
      Require
        (Same (Row_Key, Bytes ("event-2")) and then Same (Row_Value, Bytes ("updated")),
         "second audit row is not canonical");

      DB.Highest_Visible (Item, Visible, Local_Result);
      Expect (Local_Result, DB.Success, "highest-visible query failed");
      --  Two initial singletons, a two-member group, one delete, and three
      --  later singletons assign the canonical eight committed sequences.
      Require (Visible = 8, "highest-visible sequence is not eight");
      DB.Rollback (Reader, Local_Result);
      Expect (Local_Result, DB.Success, "reader rollback failed");
   exception
      when others =>
         DB.Rollback (Reader, Local_Result);
         raise;
   end Verify_Recovered_State;

   procedure Seed_And_Close is
      --  This provider handle and binding are deliberately phase-local. Their
      --  finalization before Reopen witnesses complete process-local DB and
      --  provider-adapter state loss while retaining only durable files.
      Store          : aliased Files.Store :=
        Files.Open (Root, Maximum_Object_Size => Maximum_Object_Size, Commit => Files.Power_Loss_Durable);
      Context        : aliased DB.Storage_Context;
      Created        : DB.Database;
      Txn            : DB.Transaction;
      Group          : DB.Transaction_Array (1 .. 2);
      Group_Receipts : DB.Commit_Receipt_Array (Group'Range);
      Accounts       : DB.Column_Family;
      Audit          : DB.Column_Family;
      Create_Info    : DB.Create_Receipt;
      Commit_Info    : DB.Commit_Receipt;
      Flush_Info     : DB.Flush_Receipt;
      Family_Info    : DB.Column_Family_Receipt;
      Result         : DB.Outcome_Code;
      Close_Result   : DB.Outcome_Code;
   begin
      Binding.Bind (Context, Store'Access, Bucket, Prefix);

      DB.Create
        (Created,
         Context'Access,
         Database_ID (1),
         Numbered_ID (2),
         Numbered_ID (3),
         Limits,
         Initial_Families,
         Operation_Timeout,
         Receipt => Create_Info,
         Result  => Result);
      Expect (Result, DB.Success, "database create failed");
      Expect_Checkpoint_Requirement
        (Created, DB.No_L0_Checkpoint_Work, 0, "fresh database checkpoint action");
      DB.Open_Column_Family (Created, 1, Accounts, Result);
      Expect (Result, DB.Success, "accounts open failed");
      DB.Begin_Transaction (Created, Transaction_ID (4), DB.Snapshot, Txn, Result);
      Expect (Result, DB.Success, "first transaction begin failed");
      DB.Put (Created, Txn, Accounts, Bytes ("alice"), Bytes ("100"), Result);
      Expect (Result, DB.Success, "first put failed");
      DB.Commit (Created, Txn, Operation_Timeout, Receipt => Commit_Info, Result => Result);
      Expect (Result, DB.Success, "first commit failed");

      DB.Begin_Transaction (Created, Transaction_ID (5), DB.Snapshot, Txn, Result);
      Expect (Result, DB.Success, "second transaction begin failed");
      DB.Put (Created, Txn, Accounts, Bytes ("bob"), Bytes ("200"), Result);
      Expect (Result, DB.Success, "second put failed");
      DB.Commit (Created, Txn, Operation_Timeout, Receipt => Commit_Info, Result => Result);
      Expect (Result, DB.Success, "second commit failed");

      Expect_Checkpoint_Requirement
        (Created, DB.Additive_Flush_Required, 1, "first checkpoint action");
      DB.Flush
        (Created,
         First_Runs,
         Numbered_ID (7),
         Numbered_ID (8),
         Operation_Timeout,
         Receipt => Flush_Info,
         Result  => Result);
      Expect (Result, DB.Success, "first Flush failed");
      Require (DB.Flush_Receipt_Run_Total (Flush_Info) = 1, "first Flush did not publish the root family");
      Expect_Checkpoint_Requirement
        (Created, DB.No_L0_Checkpoint_Work, 0, "first checkpoint completion");

      DB.Add_Column_Family
        (Created,
         Audit_Family,
         Numbered_ID (9),
         Numbered_ID (10),
         Operation_Timeout,
         Receipt => Family_Info,
         Result  => Result);
      Expect (Result, DB.Success, "audit family append failed");
      Require
        (DB.Column_Family_Receipt_Family_ID (Family_Info) = 2
         and then DB.Column_Family_Receipt_Manifest_ID (Family_Info) = Numbered_ID (9)
         and then DB.Column_Family_Receipt_Transition_ID (Family_Info) = Numbered_ID (10),
         "family append receipt lost its stable identities");
      DB.Open_Column_Family (Created, Bytes ("audit"), Audit, Result);
      Expect (Result, DB.Success, "appended audit family open failed");

      DB.Begin_Transaction (Created, Transaction_ID (11), DB.Snapshot, Group (1), Result);
      Expect (Result, DB.Success, "first group member begin failed");
      DB.Put (Created, Group (1), Accounts, Bytes ("bob"), Bytes ("225"), Result);
      Expect (Result, DB.Success, "first group member put failed");
      DB.Begin_Transaction (Created, Transaction_ID (12), DB.Snapshot, Group (2), Result);
      Expect (Result, DB.Success, "second group member begin failed");
      DB.Put (Created, Group (2), Audit, Bytes ("event-1"), Bytes ("created"), Result);
      Expect (Result, DB.Success, "second group member put failed");
      DB.Commit_Group
        (Created, Numbered_ID (13), Group, Operation_Timeout, Receipts => Group_Receipts, Result => Result);
      Expect (Result, DB.Success, "atomic group commit failed");

      DB.Begin_Transaction (Created, Transaction_ID (14), DB.Snapshot, Txn, Result);
      Expect (Result, DB.Success, "delete transaction begin failed");
      DB.Delete (Created, Txn, Accounts, Bytes ("alice"), Result);
      Expect (Result, DB.Success, "delete failed");
      DB.Commit (Created, Txn, Operation_Timeout, Receipt => Commit_Info, Result => Result);
      Expect (Result, DB.Success, "delete commit failed");

      DB.Begin_Transaction (Created, Transaction_ID (15), DB.Snapshot, Txn, Result);
      Expect (Result, DB.Success, "suffix transaction begin failed");
      DB.Put (Created, Txn, Accounts, Bytes ("bob"), Bytes ("250"), Result);
      Expect (Result, DB.Success, "suffix account update failed");
      DB.Put (Created, Txn, Audit, Bytes ("event-2"), Bytes ("updated"), Result);
      Expect (Result, DB.Success, "suffix audit append failed");
      DB.Commit (Created, Txn, Operation_Timeout, Receipt => Commit_Info, Result => Result);
      Expect (Result, DB.Success, "suffix commit failed");

      Expect_Checkpoint_Requirement
        (Created, DB.Additive_Flush_Required, 2, "suffix checkpoint action");
      DB.Flush
        (Created,
         Second_Runs,
         Numbered_ID (18),
         Numbered_ID (19),
         Operation_Timeout,
         Receipt => Flush_Info,
         Result  => Result);
      Expect (Result, DB.Success, "suffix Flush failed");
      Require (DB.Flush_Receipt_Run_Total (Flush_Info) = 2, "suffix Flush did not publish both families");
      Expect_Checkpoint_Requirement
        (Created, DB.No_L0_Checkpoint_Work, 0, "suffix checkpoint completion");

      DB.Compact
        (Created,
         First_Run_ID,
         Second_Run_ID,
         Merged_Run_ID,
         Merged_Manifest_ID,
         Merged_Transition_ID,
         Operation_Timeout,
         Token   => null,
         Receipt => Flush_Info,
         Result  => Result);
      Expect (Result, DB.Success, "adjacent compaction failed");
      Require
        (DB.Flush_Receipt_Run_Total (Flush_Info) = 1
         and then DB.Flush_Receipt_Run (Flush_Info, 1) =
           DB.Configure_Checkpoint_Run (1, Merged_Run_ID)
         and then DB.Flush_Receipt_Manifest_ID (Flush_Info) = Merged_Manifest_ID
         and then DB.Flush_Receipt_Transition_ID (Flush_Info) = Merged_Transition_ID,
         "adjacent compaction receipt lost exact authority");

      DB.Begin_Transaction (Created, Transaction_ID (25), DB.Snapshot, Txn, Result);
      Expect (Result, DB.Success, "post-merge transaction begin failed");
      DB.Put (Created, Txn, Accounts, Bytes ("bob"), Bytes ("275"), Result);
      Expect (Result, DB.Success, "post-merge account update failed");
      DB.Commit (Created, Txn, Operation_Timeout, Receipt => Commit_Info, Result => Result);
      Expect (Result, DB.Success, "post-merge commit failed");
      Expect_Checkpoint_Requirement
        (Created, DB.Additive_Flush_Required, 1, "post-merge checkpoint action");
      DB.Flush
        (Created,
         Third_Runs,
         Numbered_ID (27),
         Numbered_ID (28),
         Operation_Timeout,
         Receipt => Flush_Info,
         Result  => Result);
      Expect (Result, DB.Success, "post-merge sparse Flush failed");
      Require
        (DB.Flush_Receipt_Run_Total (Flush_Info) = Third_Runs'Length,
         "post-merge Flush did not retain its sparse family map");
      Expect_Checkpoint_Requirement
        (Created, DB.No_L0_Checkpoint_Work, 0, "post-merge checkpoint completion");

      DB.Begin_Transaction (Created, Transaction_ID (29), DB.Snapshot, Txn, Result);
      Expect (Result, DB.Success, "capacity-edge transaction begin failed");
      DB.Put (Created, Txn, Accounts, Bytes ("bob"), Bytes ("300"), Result);
      Expect (Result, DB.Success, "capacity-edge account update failed");
      DB.Commit (Created, Txn, Operation_Timeout, Receipt => Commit_Info, Result => Result);
      Expect (Result, DB.Success, "capacity-edge commit failed");
      Expect_Checkpoint_Requirement
        (Created, DB.Complete_Compaction_Required, 2, "complete checkpoint action");
      DB.Compact
        (Created,
         Final_Runs,
         Numbered_ID (32),
         Numbered_ID (33),
         Operation_Timeout,
         Token   => null,
         Receipt => Flush_Info,
         Result  => Result);
      Expect (Result, DB.Success, "complete replacement failed");
      Require
        (DB.Flush_Receipt_Run_Total (Flush_Info) = Final_Runs'Length
         and then DB.Flush_Receipt_Run (Flush_Info, 1) = Final_Runs (1)
         and then DB.Flush_Receipt_Run (Flush_Info, 2) = Final_Runs (2)
         and then DB.Flush_Receipt_Manifest_ID (Flush_Info) = Numbered_ID (32)
         and then DB.Flush_Receipt_Transition_ID (Flush_Info) = Numbered_ID (33),
         "complete replacement receipt lost exact authority");
      Expect_Checkpoint_Requirement
        (Created, DB.No_L0_Checkpoint_Work, 0, "complete checkpoint completion");

      Verify_Recovered_State (Created, Transaction_ID (34));
      DB.Close (Created, Close_Result);
      Expect (Close_Result, DB.Success, "created database close failed");
   exception
      when others =>
         DB.Close (Created, Close_Result);
         raise;
   end Seed_And_Close;

   procedure Reopen_And_Verify is
      --  Reconstruct both the provider handle and DB binding after Seed's
      --  entire owner stack has finalized. The shared root path is the sole
      --  durable authority crossing this scope boundary.
      Store        : aliased Files.Store :=
        Files.Open (Root, Maximum_Object_Size => Maximum_Object_Size, Commit => Files.Power_Loss_Durable);
      Context      : aliased DB.Storage_Context;
      Reopened     : DB.Database;
      Result       : DB.Outcome_Code;
      Close_Result : DB.Outcome_Code;
   begin
      Binding.Bind (Context, Store'Access, Bucket, Prefix);
      DB.Open (Reopened, Context'Access, Database_ID (1), Operation_Timeout, Result => Result);
      Expect (Result, DB.Success, "authoritative reopen failed");
      Verify_Recovered_State (Reopened, Transaction_ID (35));
      DB.Close (Reopened, Close_Result);
      Expect (Close_Result, DB.Success, "reopened database close failed");
   exception
      when others =>
         DB.Close (Reopened, Close_Result);
         raise;
   end Reopen_And_Verify;

begin
   declare
      --  Bucket setup has its own provider lifetime too; no live provider
      --  object crosses into either database phase.
      Store           : Files.Store :=
        Files.Open (Root, Maximum_Object_Size => Maximum_Object_Size, Commit => Files.Power_Loss_Durable);
      Provider_Result : OS.Status;
   begin
      Store.Create_Bucket
        (Bucket, null, Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Operation_Timeout), Provider_Result);
      Require (Provider_Result = OS.Success, "files bucket creation failed");
   end;

   Seed_And_Close;
   Reopen_And_Verify;

   Ada.Text_IO.Put_Line ("Flyology.DB limited end-to-end profile: OK");
end Flyology_DB_Limited_E2E;
