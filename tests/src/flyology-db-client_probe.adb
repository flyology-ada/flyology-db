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
   Family                 : Column_Family;
   Receipt                : Create_Receipt;
   Commit_Info            : Commit_Receipt;
   Flush_Info             : Flush_Receipt;
   Data                   : Flyology.Bytes.Unbounded_Bytes;
   Result                 : Outcome_Code;
   Close_Result           : Outcome_Code;
   Bucket_Result          : Buckets.Create_Outcome;

   --  The one-family remote fixture deliberately exercises unequal 20-byte
   --  key and 400-byte value authority. Three manifest-history slots admit
   --  exactly root, additive checkpoint, and replacement checkpoint in this
   --  small create/commit/reopen corpus; these are not API defaults.
   Limits                   : constant Database_Limits :=
     (Maximum_Column_Families           => 1,
      Maximum_Manifest_History          => 3,
      Maximum_Batch_History             => 4,
      Maximum_Transactions_Per_Batch    => 1,
      Maximum_Mutations_Per_Transaction => 4,
      Maximum_Mutations_Per_Batch       => 4,
      Maximum_Live_Entries              => 4,
      Maximum_Transaction_Payload_Bytes => 1_024,
      Maximum_Batch_Payload_Bytes       => 2_048,
      Maximum_Live_State_Bytes          => 4_096,
      Maximum_Total_L0_Runs             => 1,
      Maximum_Checkpoint_Identities     => 8,
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
         Maximum_L0_Runs      => 1)];
   --  Stable one-byte fixture identities assign 1 to the database, 2/3 to the
   --  root manifest/transition, 4 to the committed transaction, 5 to the
   --  read-only probe, 6/7/8 to the additive run/checkpoint/HEAD transition,
   --  and 9/10/11 to its complete replacement. They isolate object roles in
   --  this fresh bucket and are not ID-generation policy or persisted tags.
   Probe_Database_ID        : constant Database_Identifier := Database_Identifier (Numbered_ID (1));
   Root_Manifest_ID         : constant Identifier := Numbered_ID (2);
   Root_Transition_ID       : constant Identifier := Numbered_ID (3);
   Transaction_ID           : constant Transaction_Identifier := Transaction_Identifier (Numbered_ID (4));
   Reader_ID                : constant Transaction_Identifier := Transaction_Identifier (Numbered_ID (5));
   Checkpoint_Run_ID        : constant Identifier := Numbered_ID (6);
   Checkpoint_Manifest_ID   : constant Identifier := Numbered_ID (7);
   Checkpoint_Transition_ID : constant Identifier := Numbered_ID (8);
   Compaction_Run_ID        : constant Identifier := Numbered_ID (9);
   Compaction_Manifest_ID   : constant Identifier := Numbered_ID (10);
   Compaction_Transition_ID : constant Identifier := Numbered_ID (11);
   --  Arbitrary nonzero fixture metadata proves the moved token, rather than
   --  only a same-pool replacement token, returns through typed Finish.
   Flush_Token_Tag          : constant Interfaces.Unsigned_64 := 16#F105#;
   Checkpoint_Runs          : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Checkpoint_Run_ID)];
   Compaction_Runs          : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Compaction_Run_ID)];
   Key_Data                 : constant Byte_Array := Bytes ("client-key");
   Value_Data               : constant Byte_Array := Bytes ("client-value");
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
   Flyology.Buffers.Release (Flush_Buffer);
   Close (Created, Close_Result);
   Expect (Close_Result, Success, "client-backed close failed");

   Open (Reopened, Context'Access, Probe_Database_ID, Test_Operation_Timeout, Result => Result);
   Expect (Result, Success, "cacheless client-backed reopen failed");
   Begin_Transaction (Reopened, Reader_ID, Reader, Result);
   Expect (Result, Success, "client-backed reader begin failed");
   Open_Column_Family (Reopened, 1, Family, Result);
   Expect (Result, Success, "reopened family lookup failed");
   Get (Reopened, Reader, Family, Key_Data, Data, Result);
   Expect (Result, Success, "reopened client-backed read failed");
   if not Same (Data, Value_Data) then
      raise Program_Error with "client-backed recovery returned the wrong bytes";
   end if;
   Rollback (Reader, Result);
   Expect (Result, Success, "client-backed reader rollback failed");
   Close (Reopened, Close_Result);
   Expect (Close_Result, Success, "reopened client-backed close failed");
   Ada.Text_IO.Put_Line ("Flyology.DB client-backed create/commit/Flush/compaction/reopen passed");
exception
   when others =>
      Close (Created, Close_Result);
      Close (Reopened, Close_Result);
      raise;
end Flyology.DB.Client_Probe;
