with Ada.Command_Line;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.Buffers;
with Flyology.Bytes;
with Flyology.DB.Object_Storage;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Timers;
with Flyology.Object_Storage.Client.Buckets;
with Flyology.Object_Storage.Client.Low_Level;
with Flyology.Operations;
with Interfaces;

procedure Flyology.DB.Client_Probe is
   package Binding renames Flyology.DB.Object_Storage;
   package Buckets renames Flyology.Object_Storage.Client.Buckets;
   package HTTP renames Flyology.HTTP;
   package HTTP_Client renames Flyology.HTTP.Client;
   package Low_Level renames Flyology.Object_Storage.Client.Low_Level;
   package Timers renames Flyology.IO.Timers;

   use type Buckets.Create_Outcome_Kind;
   use type Ada.Streams.Stream_Element_Array;
   use type Byte;
   use type Interfaces.Unsigned_64;

   procedure Expect (Actual, Expected : Outcome_Code; Context : String) is
   begin
      if Actual /= Expected then
         raise Program_Error with Context & ": " & Outcome_Code'Image (Actual);
      end if;
   end Expect;

   function Numbered_ID (Value : Byte) return Identifier is
      Result : Identifier := [others => 0];
   begin
      Result (Result'Last) := Value;
      return Result;
   end Numbered_ID;

   function Bytes (Value : String) return Byte_Array is
      Result : Byte_Array (1 .. Value'Length);
   begin
      for Offset in Natural range 0 .. Value'Length - 1 loop
         Result (Offset + 1) := Byte (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Same (Left : Flyology.Bytes.Unbounded_Bytes; Right : Byte_Array) return Boolean is
   begin
      if Flyology.Bytes.Length (Left) /= Right'Length then
         return False;
      end if;
      for Offset in Natural range 0 .. Right'Length - 1 loop
         if Byte (Flyology.Bytes.Element (Left, Offset + 1)) /= Right (Right'First + Offset) then
            return False;
         end if;
      end loop;
      return True;
   end Same;

   function Same
     (Left  : Flyology.Buffers.Unique_Buffer;
      Right : Ada.Streams.Stream_Element_Array) return Boolean
   is
      Matches : Boolean := False;

      procedure Compare (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Matches := Data = Right;
      end Compare;
   begin
      Flyology.Buffers.With_Readable_Data (Left, Compare'Access);
      return Matches;
   end Same;

   function Required_Argument (Index : Positive) return String is
   begin
      if Ada.Command_Line.Argument_Count /= 4 then
         raise Program_Error with "usage: flyology-db-client-probe ENDPOINT BUCKET ACCESS_KEY SECRET_KEY";
      end if;
      return Ada.Command_Line.Argument (Index);
   end Required_Argument;

   Endpoint               : constant String := Required_Argument (1);
   Bucket                 : constant String := Required_Argument (2);
   Access_Key             : constant String := Required_Argument (3);
   Secret_Key             : constant String := Required_Argument (4);
   Origin                 : constant HTTP.Origin := HTTP.Parse_Origin (Endpoint);
   --  Ten seconds is the local authenticated black-box stability budget for
   --  each serial operation. It is not a DB default, retry budget, or
   --  persisted workload policy.
   Test_Operation_Timeout : constant Duration := 10.0;
   --  Four concurrent HTTP leases cover this serial black-box probe while
   --  matching the pinned client's already-qualified default geometry. This
   --  is test capacity, not a DB pool or connection default.
   Client                 : aliased HTTP_Client.Client (Capacity => 4);
   Identity               : aliased Low_Level.Credentials :=
     Low_Level.Make_Credentials (Access_Key, Secret_Key);
   Context                : aliased Storage_Context;
   Created                : aliased Database;
   Reopened               : Database;
   Txn                    : Transaction;
   Reader                 : Transaction;
   Family, Audit_Family, Metadata_Family : Column_Family;
   Receipt                : Create_Receipt;
   Family_Info            : Column_Family_Receipt;
   Commit_Info            : Commit_Receipt;
   Flush_Info             : Flush_Receipt;
   Data                   : Flyology.Bytes.Unbounded_Bytes;
   Result                 : Outcome_Code;
   Close_Result           : Outcome_Code;
   Bucket_Result          : Buckets.Create_Outcome;

   --  The remote fixture starts with one family, then appends two independently
   --  bounded families after its first checkpoint. Eight manifest-history slots
   --  admit exactly root, first checkpoint, two registry appends, replacement,
   --  second and third additive checkpoints, and the three-run merge successor.
   --  These are persisted fixture authority, not API defaults.
   Limits                   : constant Database_Limits :=
     (Maximum_Column_Families           => 3,
      Maximum_Manifest_History          => 8,
      Maximum_Batch_History             => 4,
      Maximum_Transactions_Per_Batch    => 1,
      Maximum_Mutations_Per_Transaction => 4,
      Maximum_Mutations_Per_Batch       => 4,
      Maximum_Live_Entries              => 4,
      Maximum_Transaction_Payload_Bytes => 1_024,
      Maximum_Batch_Payload_Bytes       => 2_048,
      Maximum_Live_State_Bytes          => 4_096,
      Maximum_Total_L0_Runs             => 4,
      --  Sixteen exact identity slots cover the five fixture publications
      --  and their retained run/transaction authority; this is test corpus
      --  geometry, not a DB or production default.
      Maximum_Checkpoint_Identities     => 16,
      --  Maintained serializable remote-fixture counts, not DB defaults.
      Maximum_Point_Reads_Per_Transaction => 8,
      Maximum_Scan_Ranges_Per_Transaction => 4);
   Families                 : constant Column_Family_Configuration_Array :=
     [Configure_Column_Family
        (1,
         Bytes ("primary"),
         Max_Key_Bytes        => 20,
         Max_Value_Bytes      => 400,
         Memtable_Max_Bytes   => 1_680,
         Memtable_Max_Entries => 4,
         Maximum_L0_Runs      => 3)];
   --  The appended family supplies a distinct exact byte/value and memtable/L0
   --  policy. It is caller authority persisted by Add_Column_Family, not a
   --  value derived from the initial family or selected by the DB.
   Appended_Family          : constant Column_Family_Configuration :=
     Configure_Column_Family
       (2,
        Bytes ("audit"),
        Max_Key_Bytes        => 12,
        Max_Value_Bytes      => 64,
        Memtable_Max_Bytes   => 256,
        Memtable_Max_Entries => 2,
        Maximum_L0_Runs      => 1);
   --  The second appended family supplies another exact caller policy and
   --  remains empty to prove registry preservation does not invent an SST.
   Metadata_Family_Config   : constant Column_Family_Configuration :=
     Configure_Column_Family
       (3,
        Bytes ("metadata"),
        Max_Key_Bytes        => 16,
        Max_Value_Bytes      => 96,
        Memtable_Max_Bytes   => 384,
        Memtable_Max_Entries => 3,
        Maximum_L0_Runs      => 1);
   --  Stable one-byte fixture identities assign 1 to the database, 2/3 to the
   --  root manifest/transition, 4 to the committed transaction, 5 to the
   --  read-only probe, 6/7/8 to the additive run/checkpoint/HEAD transition,
   --  9/10 and 11/12 to the two appended-family manifest/transitions, 13/14/15
   --  to the complete replacement, 16 to the later cross-family transaction,
   --  17/18/19/20 to its two runs/checkpoint/transition, 21 to a third
   --  transaction, 22/23/24 to its family-1 run/checkpoint/transition, and
   --  25/26/27 to the selected three-run merge. IDs 28 through 32 are unused
   --  run-map placeholders for unchanged/empty families; they never name attempted objects. These
   --  values isolate fixture roles and are not ID-generation policy or tags.
   Probe_Database_ID        : constant Database_Identifier := Database_Identifier (Numbered_ID (1));
   Root_Manifest_ID         : constant Identifier := Numbered_ID (2);
   Root_Transition_ID       : constant Identifier := Numbered_ID (3);
   Transaction_ID           : constant Transaction_Identifier := Transaction_Identifier (Numbered_ID (4));
   Reader_ID                : constant Transaction_Identifier := Transaction_Identifier (Numbered_ID (5));
   Checkpoint_Run_ID        : constant Identifier := Numbered_ID (6);
   Checkpoint_Manifest_ID   : constant Identifier := Numbered_ID (7);
   Checkpoint_Transition_ID : constant Identifier := Numbered_ID (8);
   Family_Manifest_ID       : constant Identifier := Numbered_ID (9);
   Family_Transition_ID     : constant Identifier := Numbered_ID (10);
   Metadata_Manifest_ID     : constant Identifier := Numbered_ID (11);
   Metadata_Transition_ID   : constant Identifier := Numbered_ID (12);
   Compaction_Run_ID        : constant Identifier := Numbered_ID (13);
   Compaction_Manifest_ID   : constant Identifier := Numbered_ID (14);
   Compaction_Transition_ID : constant Identifier := Numbered_ID (15);
   Later_Transaction_ID     : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (16));
   Later_Run_ID             : constant Identifier := Numbered_ID (17);
   Audit_Run_ID             : constant Identifier := Numbered_ID (18);
   Later_Manifest_ID        : constant Identifier := Numbered_ID (19);
   Later_Transition_ID      : constant Identifier := Numbered_ID (20);
   Third_Transaction_ID     : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (21));
   Third_Run_ID             : constant Identifier := Numbered_ID (22);
   Third_Manifest_ID        : constant Identifier := Numbered_ID (23);
   Third_Transition_ID      : constant Identifier := Numbered_ID (24);
   Merged_Run_ID            : constant Identifier := Numbered_ID (25);
   Merged_Manifest_ID       : constant Identifier := Numbered_ID (26);
   Merged_Transition_ID     : constant Identifier := Numbered_ID (27);
   Empty_Later_Metadata_Run_ID : constant Identifier := Numbered_ID (28);
   Unchanged_Third_Audit_Run_ID : constant Identifier := Numbered_ID (29);
   Unchanged_Third_Metadata_Run_ID : constant Identifier := Numbered_ID (30);
   Empty_Compaction_Audit_Run_ID : constant Identifier := Numbered_ID (31);
   Empty_Compaction_Metadata_Run_ID : constant Identifier := Numbered_ID (32);
   --  Arbitrary nonzero fixture metadata proves the moved token, rather than
   --  only a same-pool replacement token, returns through typed Finish.
   Flush_Token_Tag          : constant Interfaces.Unsigned_64 := 16#F105#;
   Checkpoint_Runs          : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Checkpoint_Run_ID)];
   Compaction_Runs          : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Compaction_Run_ID),
      Configure_Checkpoint_Run (2, Empty_Compaction_Audit_Run_ID),
      Configure_Checkpoint_Run (3, Empty_Compaction_Metadata_Run_ID)];
   Later_Runs               : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Later_Run_ID),
      Configure_Checkpoint_Run (2, Audit_Run_ID),
      Configure_Checkpoint_Run (3, Empty_Later_Metadata_Run_ID)];
   Third_Runs               : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Third_Run_ID),
      Configure_Checkpoint_Run (2, Unchanged_Third_Audit_Run_ID),
      Configure_Checkpoint_Run (3, Unchanged_Third_Metadata_Run_ID)];
   Key_Data                 : constant Byte_Array := Bytes ("client-key");
   Value_Data               : constant Byte_Array := Bytes ("client-value");
   Later_Value_Data         : constant Byte_Array := Bytes ("client-value-later");
   Third_Value_Data         : constant Byte_Array := Bytes ("client-value-third");
   Audit_Key_Data           : constant Byte_Array := Bytes ("event-1");
   Audit_Value_Data         : constant Byte_Array := Bytes ("remote-append");
   --  One visible DB parent, one Object Storage child, its HTTP exchange, and
   --  its single transport child are the exact owner-stack slot geometry of
   --  this serial probe. It is test capacity, not a DB completion-set default.
   Composable_Set            : aliased Flyology.Operations.Completion_Set (4);
   --  The fixture selects its persisted live-state byte budget as the scratch
   --  block capacity and one token as serial operation geometry. Production
   --  callers select capacity from their own persisted family/database limits.
   Flush_Pool                : aliased Flyology.Buffers.Pool
     (Block_Size => Positive (Limits.Maximum_Live_State_Bytes), Capacity => 1);
   Flush_Buffer              : Flyology.Buffers.Unique_Buffer (Flush_Pool'Access);
   Restored_Buffer           : Flyology.Buffers.Unique_Buffer (Flush_Pool'Access);
   Flush_Work                : Flush_Operation
     (Composable_Set'Access,
      Created'Access,
      Context'Access,
      Client'Access,
      Flush_Pool'Access,
      null);
begin
   HTTP_Client.Configure (Client, Origin);
   Bucket_Result :=
     Buckets.Create
       (Client,
        Origin,
        Bucket,
        Identity,
        Region  => "us-east-1",
        Style   => Low_Level.Path_Style,
        Timeout => Test_Operation_Timeout);
   if Bucket_Result.Kind /= Buckets.Creation_Completed then
      raise Program_Error with "client probe could not create its fresh bucket";
   end if;

   --  Region/style/media selections are exact black-box fixture inputs. Empty
   --  owner and request-payer omit those optional headers; checksum mode is
   --  disabled because DB object envelopes supply the integrity assertion.
   Binding.Bind_Client
     (Context,
      Client'Access,
      Origin,
      Identity'Access,
      Bucket,
      "database",
      "us-east-1",
      Low_Level.Path_Style,
      "application/octet-stream",
      "",
      "",
      False);

   Create
     (Created,
      Context'Access,
      Probe_Database_ID,
      Root_Manifest_ID,
      Root_Transition_ID,
      Limits,
      Families,
      Test_Operation_Timeout,
      Receipt => Receipt,
      Result  => Result);
   Expect (Result, Success, "client-backed create failed");

   Begin_Transaction (Created, Transaction_ID, Txn, Result);
   Expect (Result, Success, "client-backed transaction begin failed");
   Open_Column_Family (Created, 1, Family, Result);
   Expect (Result, Success, "client-backed family open failed");
   Put (Created, Txn, Family, Key_Data, Value_Data, Result);
   Expect (Result, Success, "client-backed put failed");
   Commit (Created, Txn, Test_Operation_Timeout, Receipt => Commit_Info, Result => Result);
   Expect (Result, Success, "client-backed commit failed");

   --  Completion-slot rejection is required to precede token movement. The
   --  timer occupies the sole test slot; the three marker bytes and stable tag
   --  make byte/tag/length rollback observable without provider entry.
   declare
      Rollback_Set    : aliased Flyology.Operations.Completion_Set (1);
      Rollback_Pool   : aliased Flyology.Buffers.Pool (Block_Size => 3, Capacity => 1);
      Rollback_Buffer : Flyology.Buffers.Unique_Buffer (Rollback_Pool'Access);
      Rollback_Work   : Flush_Operation
        (Rollback_Set'Access,
         Created'Access,
         Context'Access,
         Client'Access,
         Rollback_Pool'Access,
         null);
      Busy            : Timers.Timer_Operation :=
        Timers.Sleep_For (Rollback_Set'Access, Test_Operation_Timeout);
      Marker          : constant Ada.Streams.Stream_Element_Array := [16#A5#, 16#5A#, 16#C3#];
      --  Arbitrary nonzero fixture tag used only to prove that Start rollback
      --  preserves buffer metadata as well as payload bytes and length.
      Marker_Tag      : constant Interfaces.Unsigned_64 := 16#C0DE#;
      Rejected        : Boolean := False;
   begin
      Flyology.Buffers.Acquire (Rollback_Buffer);
      Flyology.Buffers.Copy_From (Rollback_Buffer, Marker);
      Flyology.Buffers.Set_Tag (Rollback_Buffer, Marker_Tag);
      begin
         Start_Flush
           (Rollback_Work,
            Checkpoint_Runs,
            Checkpoint_Manifest_ID,
            Checkpoint_Transition_ID,
            Rollback_Buffer,
            Test_Operation_Timeout);
      exception
         when Flyology.Operations.Capacity_Error =>
            Rejected := True;
      end;
      if not Rejected
        or else not Flyology.Buffers.Has_Buffer (Rollback_Buffer)
        or else Flyology.Buffers.Length (Rollback_Buffer) /= Marker'Length
        or else Flyology.Buffers.Tag (Rollback_Buffer) /= Marker_Tag
        or else not Same (Rollback_Buffer, Marker)
      then
         raise Program_Error with "composable Flush Start did not roll back its exact token";
      end if;
      Flyology.Operations.Cancel (Busy);
      Flyology.Operations.Wait_All (Rollback_Set);
      begin
         Timers.Finish (Busy);
      exception
         when Flyology.Operations.Operation_Cancelled =>
            null;
      end;
      Flyology.Operations.Release (Busy);
      Flyology.Buffers.Release (Rollback_Buffer);
   end;

   --  The caller deliberately supplies a one-byte block, smaller than every
   --  valid encoded checkpoint object. Capacity rejection must be terminal,
   --  definite, token-restoring, and publication-free so the same identities
   --  remain safe for the following adequately sized attempt.
   declare
      Tiny_Pool     : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
      Tiny_Buffer   : Flyology.Buffers.Unique_Buffer (Tiny_Pool'Access);
      Tiny_Work     : Flush_Operation
        (Composable_Set'Access,
         Created'Access,
         Context'Access,
         Client'Access,
         Tiny_Pool'Access,
         null);
      Tiny_Receipt  : Flush_Receipt;
   begin
      Flyology.Buffers.Acquire (Tiny_Buffer);
      Start_Flush
        (Tiny_Work,
         Checkpoint_Runs,
         Checkpoint_Manifest_ID,
         Checkpoint_Transition_ID,
         Tiny_Buffer,
         Test_Operation_Timeout);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Tiny_Work, Tiny_Receipt, Result, Tiny_Buffer);
      Expect (Result, Capacity_Exceeded, "undersized composable Flush scratch was not rejected");
      if not Flyology.Buffers.Has_Buffer (Tiny_Buffer) then
         raise Program_Error with "undersized composable Flush published or lost its token";
      end if;
      Flyology.Operations.Release (Tiny_Work);
      Flyology.Buffers.Release (Tiny_Buffer);
   end;

   --  A valid plan driven through a one-slot set can reserve only the DB
   --  parent, not its first Object Storage child. That provider Start is
   --  definitely pre-admission and must surface as typed DB backpressure.
   declare
      Child_Set     : aliased Flyology.Operations.Completion_Set (1);
      Child_Pool    : aliased Flyology.Buffers.Pool
        (Block_Size => Positive (Limits.Maximum_Live_State_Bytes), Capacity => 1);
      Child_Buffer  : Flyology.Buffers.Unique_Buffer (Child_Pool'Access);
      Child_Work    : Flush_Operation
        (Child_Set'Access,
         Created'Access,
         Context'Access,
         Client'Access,
         Child_Pool'Access,
         null);
      Child_Receipt : Flush_Receipt;
   begin
      Flyology.Buffers.Acquire (Child_Buffer);
      Start_Flush
        (Child_Work,
         Checkpoint_Runs,
         Checkpoint_Manifest_ID,
         Checkpoint_Transition_ID,
         Child_Buffer,
         Test_Operation_Timeout);
      Flyology.Operations.Wait_All (Child_Set);
      Finish (Child_Work, Child_Receipt, Result, Child_Buffer);
      Expect (Result, Capacity_Exceeded, "nested composable Flush slot exhaustion was ambiguous");
      if not Flyology.Buffers.Has_Buffer (Child_Buffer) then
         raise Program_Error with "nested composable Flush slot exhaustion lost its token";
      end if;
      Flyology.Operations.Release (Child_Work);
      Flyology.Buffers.Release (Child_Buffer);
   end;

   --  Scope abandonment is the safety-net authority. An invalid run map
   --  terminalizes without provider entry; abandoning it must discard the
   --  result and return the operation-owned token before its pool finalizes.
   declare
      Abandon_Set  : aliased Flyology.Operations.Completion_Set (1);
      Abandon_Pool : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
   begin
      declare
         Abandon_Buffer : Flyology.Buffers.Unique_Buffer (Abandon_Pool'Access);
         Abandon_Work   : Flush_Operation
           (Abandon_Set'Access,
            Created'Access,
            Context'Access,
            Client'Access,
            Abandon_Pool'Access,
            null);
      begin
         Flyology.Buffers.Acquire (Abandon_Buffer);
         Start_Flush
           (Abandon_Work,
            Checkpoint_Runs,
            Zero_Identifier,
            Checkpoint_Transition_ID,
            Abandon_Buffer,
            Test_Operation_Timeout);
         Flyology.Operations.Wait_All (Abandon_Set);
         if Flyology.Buffers.Has_Buffer (Abandon_Buffer) then
            raise Program_Error with "abandoned composable Flush never acquired token ownership";
         end if;
      end;
      declare
         Snapshot : constant Flyology.Buffers.Pool_Snapshot := Flyology.Buffers.Current (Abandon_Pool);
      begin
         if Snapshot.Available /= 1 or else Snapshot.Outstanding /= 0 then
            raise Program_Error with "abandoned composable Flush did not release its token";
         end if;
      end;
   end;

   Flyology.Buffers.Acquire (Flush_Buffer);
   --  The operation may overwrite payload bytes and length, but ownership
   --  transfer must retain this exact caller metadata tag through Finish.
   Flyology.Buffers.Set_Tag (Flush_Buffer, Flush_Token_Tag);

   --  The synchronous client form is a literal owner-driven wait over the
   --  same Flush_Operation used below. A provider rejection before the first
   --  run request is definitely outside publication and permits an explicit
   --  caller retry with the same immutable identities.
   Context.Test_Control.Arm (Before_Run_Put, Definite_Failure, 1);
   Flush
     (Created,
      Checkpoint_Runs,
      Checkpoint_Manifest_ID,
      Checkpoint_Transition_ID,
      Test_Operation_Timeout,
      Receipt => Flush_Info,
      Result  => Result);
   Expect (Result, Storage_Failure, "pre-run synchronous Flush failure was ambiguous");

   --  The second attempt publishes/reconciles the immutable run and manifest,
   --  then fails definitely before HEAD admission. Reusing the exact IDs is
   --  safe because no visible transition was attempted.
   Context.Test_Control.Arm (Before_Head_Put, Definite_Failure, 1);
   Start_Flush
     (Flush_Work,
      Checkpoint_Runs,
      Checkpoint_Manifest_ID,
      Checkpoint_Transition_ID,
      Flush_Buffer,
      Test_Operation_Timeout);
   Flyology.Operations.Wait_All (Composable_Set);
   Finish (Flush_Work, Flush_Info, Result, Restored_Buffer);
   Expect (Result, Storage_Failure, "pre-HEAD composable Flush failure was ambiguous");
   if Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
     or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "pre-HEAD composable Flush did not restore its exact token";
   end if;

   --  Lose the next run response after provider entry. The synchronous owner
   --  must not replay under another identity: its Flush_Operation performs one
   --  exact whole-Get, accepts only identical bytes, and continues the original
   --  checkpoint attempt. Its private token does not disturb the tagged token
   --  restored by the caller-composable failure above.
   Context.Test_Control.Arm (After_Run_Put, Unknown_After_Entry, 1);
   Flush
     (Created,
      Checkpoint_Runs,
      Checkpoint_Manifest_ID,
      Checkpoint_Transition_ID,
      Test_Operation_Timeout,
      Receipt => Flush_Info,
      Result  => Result);
   Expect (Result, Success, "client-backed synchronous Flush failed");
   if Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
     or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "synchronous Flush disturbed the caller-composable token";
   end if;
   if Flush_Receipt_Manifest_ID (Flush_Info) /= Checkpoint_Manifest_ID
     or else Flush_Receipt_Transition_ID (Flush_Info) /= Checkpoint_Transition_ID
     or else Flush_Receipt_Replay_Boundary (Flush_Info) /= Receipt_Sequence (Commit_Info)
   then
      raise Program_Error with "client-backed Flush receipt lost exact authority";
   end if;

   --  Family-registry publication must include the appended name/header in its
   --  caller-selected scratch requirement. A one-byte token is rejected before
   --  provider entry, restored exactly, and leaves the identities reusable.
   declare
      Tiny_Pool    : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
      Tiny_Buffer  : Flyology.Buffers.Unique_Buffer (Tiny_Pool'Access);
      Tiny_Work    : Flush_Operation
        (Composable_Set'Access,
         Created'Access,
         Context'Access,
         Client'Access,
         Tiny_Pool'Access,
         null);
      Tiny_Family  : Column_Family_Receipt;
   begin
      Flyology.Buffers.Acquire (Tiny_Buffer);
      Add_Column_Family
        (Appended_Family,
         Family_Manifest_ID,
         Family_Transition_ID,
         Tiny_Buffer,
         Test_Operation_Timeout,
         Tiny_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Tiny_Work, Tiny_Family, Result, Tiny_Buffer);
      Expect (Result, Capacity_Exceeded, "undersized family append scratch was not rejected");
      if not Flyology.Buffers.Has_Buffer (Tiny_Buffer) then
         raise Program_Error with "undersized family append lost its exact token";
      end if;
      Flyology.Operations.Release (Tiny_Work);
      Flyology.Buffers.Release (Tiny_Buffer);
   end;

   --  A duplicate-family rejection is prepublication and consumes the typed
   --  terminal result while restoring the exact token. The same established
   --  operation and identities therefore remain reusable for the valid append.
   Add_Column_Family
     (Families (1),
      Family_Manifest_ID,
      Family_Transition_ID,
      Restored_Buffer,
      Test_Operation_Timeout,
      Flush_Work);
   Flyology.Operations.Wait_All (Composable_Set);
   declare
      Wrong_Finish_Rejected : Boolean := False;
   begin
      begin
         Finish (Flush_Work, Flush_Info, Result, Flush_Buffer);
      exception
         when Program_Error =>
            Wrong_Finish_Rejected := True;
      end;
      if not Wrong_Finish_Rejected
        or else Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Operations.Is_Terminal (Flush_Work)
      then
         raise Program_Error with "wrong family-append Finish consumed terminal ownership";
      end if;
   end;
   Finish (Flush_Work, Family_Info, Result, Flush_Buffer);
   Expect (Result, Already_Exists, "composable duplicate family was not rejected definitely");
   if Flyology.Buffers.Has_Buffer (Restored_Buffer)
     or else not Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else Flyology.Buffers.Tag (Flush_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "rejected family append did not restore its exact token";
   end if;

   --  Lose the registry HEAD response after possible admission. Typed Finish
   --  must preserve the exact receipt and token; later resolution performs a
   --  generation-bound cacheless read without replay or replacement identity.
   Context.Test_Control.Arm (After_Head_Put, Unknown_After_Entry, 1);
   Add_Column_Family
     (Appended_Family,
      Family_Manifest_ID,
      Family_Transition_ID,
      Flush_Buffer,
      Test_Operation_Timeout,
      Flush_Work);
   Flyology.Operations.Wait_All (Composable_Set);
   Finish (Flush_Work, Family_Info, Result, Restored_Buffer);
   Expect (Result, Outcome_Unknown, "client-backed family append lost HEAD uncertainty");
   if Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
     or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
     or else Column_Family_Receipt_Family_ID (Family_Info) /= Appended_Family.ID
     or else Column_Family_Receipt_Manifest_ID (Family_Info) /= Family_Manifest_ID
     or else Column_Family_Receipt_Transition_ID (Family_Info) /= Family_Transition_ID
   then
      raise Program_Error with "composable family append lost exact token or receipt authority";
   end if;
   Resolve_Add_Column_Family
     (Created, Family_Info, Test_Operation_Timeout, Result => Result);
   Expect (Result, Success, "client-backed family append reconciliation failed");
   Open_Column_Family (Created, Appended_Family.ID, Audit_Family, Result);
   Expect (Result, Success, "client-backed appended family open failed");

   --  The blocking client overload is a literal wait over the consumed
   --  operation above. A second successful append proves that wrapper reaches
   --  the same provider publication and activation path without inventing an
   --  SST for the deliberately empty family.
   Add_Column_Family
     (Created,
      Metadata_Family_Config,
      Metadata_Manifest_ID,
      Metadata_Transition_ID,
      Test_Operation_Timeout,
      Receipt => Family_Info,
      Result  => Result);
   Expect (Result, Success, "blocking client family append failed");
   if Column_Family_Receipt_Family_ID (Family_Info) /= Metadata_Family_Config.ID
     or else Column_Family_Receipt_Manifest_ID (Family_Info) /= Metadata_Manifest_ID
     or else Column_Family_Receipt_Transition_ID (Family_Info) /= Metadata_Transition_ID
   then
      raise Program_Error with "blocking family append receipt lost exact authority";
   end if;
   Open_Column_Family (Created, Metadata_Family_Config.ID, Metadata_Family, Result);
   Expect (Result, Success, "blocking appended family open failed");

   --  The private replacement constructor selects only the already-frozen
   --  complete-run algorithm. It reuses the public operation owner stack,
   --  exact token move, typed Finish, certainty mapping, and one deadline;
   --  it grants no public trigger or automatic compaction policy. Losing the
   --  run response after entry requires exact same-identity whole-Get
   --  reconciliation before the original operation can continue.
   Context.Test_Control.Arm (After_Run_Put, Unknown_After_Entry, 1);
   Start_Test_Compaction
     (Flush_Work,
      Compaction_Runs,
      Compaction_Manifest_ID,
      Compaction_Transition_ID,
      Restored_Buffer,
      Test_Operation_Timeout);
   if Flyology.Buffers.Has_Buffer (Restored_Buffer) then
      raise Program_Error with "composable compaction did not move its exact token";
   end if;
   Flyology.Operations.Wait_All (Composable_Set);
   Finish (Flush_Work, Flush_Info, Result, Flush_Buffer);
   Expect (Result, Success, "client-backed composable compaction failed");
   if Flyology.Buffers.Has_Buffer (Restored_Buffer)
     or else not Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else Flyology.Buffers.Tag (Flush_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "composable compaction Finish did not restore its exact token";
   end if;
   if not Flush_Info.Replaces_Current_Runs
     or else Flush_Receipt_Manifest_ID (Flush_Info) /= Compaction_Manifest_ID
     or else Flush_Receipt_Transition_ID (Flush_Info) /= Compaction_Transition_ID
   then
      raise Program_Error with "client-backed compaction receipt lost replacement authority";
   end if;

   --  The next commit writes both families; its family-1 value and a final
   --  family-1 commit become the second and third selected runs. The private
   --  exact-three wrapper must drive every selected-run HEAD/range/whole read
   --  and publication through the same owner-stack Flush operation; no helper
   --  task or blocking client adapter is involved.
   Begin_Transaction (Created, Later_Transaction_ID, Txn, Result);
   Expect (Result, Success, "later client-backed transaction begin failed");
   Put (Created, Txn, Family, Key_Data, Later_Value_Data, Result);
   Expect (Result, Success, "later client-backed put failed");
   Put (Created, Txn, Audit_Family, Audit_Key_Data, Audit_Value_Data, Result);
   Expect (Result, Success, "appended-family remote put failed");
   Commit (Created, Txn, Test_Operation_Timeout, Receipt => Commit_Info, Result => Result);
   Expect (Result, Success, "later client-backed commit failed");
   Flush
     (Created,
      Later_Runs,
      Later_Manifest_ID,
      Later_Transition_ID,
      Test_Operation_Timeout,
      Receipt => Flush_Info,
      Result  => Result);
   Expect (Result, Success, "later client-backed additive Flush failed");

   Begin_Transaction (Created, Third_Transaction_ID, Txn, Result);
   Expect (Result, Success, "third client-backed transaction begin failed");
   Put (Created, Txn, Family, Key_Data, Third_Value_Data, Result);
   Expect (Result, Success, "third client-backed put failed");
   Commit (Created, Txn, Test_Operation_Timeout, Receipt => Commit_Info, Result => Result);
   Expect (Result, Success, "third client-backed commit failed");
   Flush
     (Created,
      Third_Runs,
      Third_Manifest_ID,
      Third_Transition_ID,
      Test_Operation_Timeout,
      Receipt => Flush_Info,
      Result  => Result);
   Expect (Result, Success, "third client-backed additive Flush failed");

   --  A definite selected-read failure precedes publication, restores all
   --  operation ownership, and leaves the exact identities reusable. The
   --  immediate retry is explicit test authority, not an automatic DB retry.
   Context.Test_Control.Arm (Before_Get, Definite_Failure, 1);
   Publish_Test_Three_Run_Merge
     (Created,
      Compaction_Run_ID,
      Later_Run_ID,
      Third_Run_ID,
      Merged_Run_ID,
      Merged_Manifest_ID,
      Merged_Transition_ID,
      Flush_Info,
      Result);
   Expect (Result, Storage_Failure, "pre-read three-run merge failure was ambiguous");
   --  Losing the output PUT response after possible admission is reconciled
   --  by an exact same-generation whole Get inside the original operation.
   --  The caller does not replay the merge or select a new identity.
   Context.Test_Control.Arm (After_Run_Put, Unknown_After_Entry, 1);
   Publish_Test_Three_Run_Merge
     (Created,
      Compaction_Run_ID,
      Later_Run_ID,
      Third_Run_ID,
      Merged_Run_ID,
      Merged_Manifest_ID,
      Merged_Transition_ID,
      Flush_Info,
      Result);
   Expect (Result, Success, "client-backed owner-driven three-run merge failed");
   if Flush_Receipt_Run_Total (Flush_Info) /= 1
     or else Flush_Receipt_Run (Flush_Info, 1) /= Configure_Checkpoint_Run (1, Merged_Run_ID)
     or else Flush_Receipt_Manifest_ID (Flush_Info) /= Merged_Manifest_ID
     or else Flush_Receipt_Transition_ID (Flush_Info) /= Merged_Transition_ID
   then
      raise Program_Error with "client-backed three-run merge receipt lost exact authority";
   end if;
   Flyology.Buffers.Release (Flush_Buffer);
   Close (Created, Close_Result);
   Expect (Close_Result, Success, "client-backed close failed");

   Open (Reopened, Context'Access, Probe_Database_ID, Test_Operation_Timeout, Result => Result);
   Expect (Result, Success, "cacheless client-backed reopen failed");
   Begin_Transaction (Reopened, Reader_ID, Reader, Result);
   Expect (Result, Success, "client-backed reader begin failed");
   Open_Column_Family (Reopened, 1, Family, Result);
   Expect (Result, Success, "reopened family lookup failed");
   Open_Column_Family (Reopened, Appended_Family.ID, Audit_Family, Result);
   Expect (Result, Success, "reopened appended family lookup failed");
   Open_Column_Family (Reopened, Metadata_Family_Config.ID, Metadata_Family, Result);
   Expect (Result, Success, "reopened blocking-appended family lookup failed");
   Get (Reopened, Reader, Family, Key_Data, Data, Result);
   Expect (Result, Success, "reopened client-backed read failed");
   if not Same (Data, Third_Value_Data) then
      raise Program_Error with "client-backed recovery returned the wrong bytes";
   end if;
   Get (Reopened, Reader, Audit_Family, Audit_Key_Data, Data, Result);
   Expect (Result, Success, "reopened appended-family read failed");
   if not Same (Data, Audit_Value_Data) then
      raise Program_Error with "client-backed appended family returned the wrong bytes";
   end if;
   Get (Reopened, Reader, Metadata_Family, Audit_Key_Data, Data, Result);
   Expect (Result, Not_Found, "empty blocking-appended family invented a value");
   Rollback (Reader, Result);
   Expect (Result, Success, "client-backed reader rollback failed");
   Close (Reopened, Close_Result);
   Expect (Close_Result, Success, "reopened client-backed close failed");
   Ada.Text_IO.Put_Line
     ("Flyology.DB client-backed create/appends/commit/Flush/compaction/reopen passed");
exception
   when others =>
      Close (Created, Close_Result);
      Close (Reopened, Close_Result);
      raise;
end Flyology.DB.Client_Probe;
