with Ada.Command_Line;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology.Buffers;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.DB.Object_Storage;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.Object_Storage.Client.Buckets;
with Flyology.Object_Storage.Client.Low_Level;
with Flyology.Operations;
with Interfaces;
with Refresh_Proxy_Testing;

procedure Flyology.DB.Client_Probe is
   package Binding renames Flyology.DB.Object_Storage;
   package Buckets renames Flyology.Object_Storage.Client.Buckets;
   package HTTP renames Flyology.HTTP;
   package HTTP_Client renames Flyology.HTTP.Client;
   package Low_Level renames Flyology.Object_Storage.Client.Low_Level;
   package Sockets renames Flyology.IO.Sockets;
   package Timers renames Flyology.IO.Timers;

   use type Buckets.Create_Outcome_Kind;
   use type Ada.Streams.Stream_Element_Array;
   use type Byte;
   use type Interfaces.Unsigned_32;
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
     (Left : Flyology.Buffers.Unique_Buffer; Right : Ada.Streams.Stream_Element_Array) return Boolean
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
      if Ada.Command_Line.Argument_Count not in 4 .. 5 then
         raise Program_Error
           with "usage: flyology-db-client-probe ENDPOINT BUCKET ACCESS_KEY SECRET_KEY [UPSTREAM_PORT]";
      end if;
      return Ada.Command_Line.Argument (Index);
   end Required_Argument;

   function Decimal (Value : Sockets.Port) return String
   is (Ada.Strings.Fixed.Trim (Sockets.Port'Image (Value), Ada.Strings.Both));

   function Proxy_Upstream_Port return Sockets.Port is
   begin
      if Ada.Command_Line.Argument_Count = 5 then
         return Sockets.Port'Value (Ada.Command_Line.Argument (5));
      else
         return Sockets.Any_Port;
      end if;
   end Proxy_Upstream_Port;

   Endpoint                              : constant String := Required_Argument (1);
   Bucket                                : constant String := Required_Argument (2);
   Access_Key                            : constant String := Required_Argument (3);
   Secret_Key                            : constant String := Required_Argument (4);
   Proxy_Enabled                         : constant Boolean := Ada.Command_Line.Argument_Count = 5;
   Upstream_Port                         : constant Sockets.Port := Proxy_Upstream_Port;
   Origin                                : HTTP.Origin := HTTP.Parse_Origin (Endpoint);
   --  Ten seconds is the local authenticated black-box stability budget for
   --  each serial operation. It is not a DB default, retry budget, or
   --  persisted workload policy.
   Test_Operation_Timeout                : constant Duration := 10.0;
   --  Two seconds is the focused local blocked-child deadline oracle. The
   --  proxy confirms the selected request is blocked before the deadline is
   --  observed, so this is test timing rather than a DB or provider default.
   Blocked_Deadline_Timeout              : constant Duration := 2.0;
   --  Four concurrent HTTP leases cover this serial black-box probe while
   --  matching the pinned client's already-qualified default geometry. This
   --  is test capacity, not a DB pool or connection default.
   Client                                : aliased HTTP_Client.Client (Capacity => 4);
   Identity                              : aliased Low_Level.Credentials :=
     Low_Level.Make_Credentials (Access_Key, Secret_Key);
   Context                               : aliased Storage_Context;
   Created                               : aliased Database;
   Replica                               : aliased Database;
   Reopened                              : aliased Database;
   Txn                                   : Transaction;
   Reader                                : Transaction;
   Family, Audit_Family, Metadata_Family : Column_Family;
   Receipt                               : Create_Receipt;
   Family_Info                           : Column_Family_Receipt;
   Commit_Info                           : Commit_Receipt;
   First_Sequence                        : Sequence_Number := 0;
   Later_Sequence                        : Sequence_Number := 0;
   Third_Sequence                        : Sequence_Number := 0;
   Flush_Info                            : Flush_Receipt;
   Action                                : L0_Checkpoint_Action;
   Requirement                           : L0_Checkpoint_Requirement;
   Data                                  : Flyology.Bytes.Unbounded_Bytes;
   Result                                : Outcome_Code;
   Close_Result                          : Outcome_Code;
   Bucket_Result                         : Buckets.Create_Outcome;

   --  The remote fixture starts with one family, then appends two independently
   --  bounded families after its first checkpoint. Nine manifest-history slots
   --  admit exactly root, first checkpoint, two registry appends, two complete
   --  replacements, second and third additive checkpoints, and one adjacent merge.
   --  These are persisted fixture authority, not API defaults.
   Limits                       : constant Database_Limits :=
     (Maximum_Column_Families             => 3,
      Maximum_Manifest_History            => 9,
      Maximum_Batch_History               => 4,
      Maximum_Transactions_Per_Batch      => 1,
      Maximum_Mutations_Per_Transaction   => 4,
      Maximum_Mutations_Per_Batch         => 4,
      Maximum_Live_Entries                => 4,
      Maximum_Transaction_Payload_Bytes   => 1_024,
      Maximum_Batch_Payload_Bytes         => 2_048,
      Maximum_Live_State_Bytes            => 4_096,
      Maximum_Total_L0_Runs               => 4,
      --  Twenty slots extend the prior sixteen-role fixture with the final
      --  compaction's two output, manifest, and transition identities. This
      --  is exact corpus geometry, not a DB or production default.
      Maximum_Checkpoint_Identities       => 20,
      --  Maintained serializable remote-fixture counts, not DB defaults.
      Maximum_Point_Reads_Per_Transaction => 8,
      Maximum_Scan_Ranges_Per_Transaction => 4);
   Families                     : constant Column_Family_Configuration_Array :=
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
   Appended_Family              : constant Column_Family_Configuration :=
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
   Metadata_Family_Config       : constant Column_Family_Configuration :=
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
   --  17/32/19/20 to its two runs/checkpoint/transition, 21 to a third
   --  transaction, 22/23/24 to its family-1 run/checkpoint/transition, and
   --  25/26/27 to the selected adjacent merge, and 28/29/30/31 to the final
   --  two-run complete replacement and its manifest/transition. ID 33 is a
   --  legacy full-map entry for an empty family; it never names an attempted
   --  object. These values isolate fixture roles and are not ID-generation
   --  policy or tags.
   Probe_Database_ID            : constant Database_Identifier := Database_Identifier (Numbered_ID (1));
   Root_Manifest_ID             : constant Identifier := Numbered_ID (2);
   Root_Transition_ID           : constant Identifier := Numbered_ID (3);
   Transaction_ID               : constant Transaction_Identifier := Transaction_Identifier (Numbered_ID (4));
   Reader_ID                    : constant Transaction_Identifier := Transaction_Identifier (Numbered_ID (5));
   Checkpoint_Run_ID            : constant Identifier := Numbered_ID (6);
   Checkpoint_Manifest_ID       : constant Identifier := Numbered_ID (7);
   Checkpoint_Transition_ID     : constant Identifier := Numbered_ID (8);
   Family_Manifest_ID           : constant Identifier := Numbered_ID (9);
   Family_Transition_ID         : constant Identifier := Numbered_ID (10);
   Metadata_Manifest_ID         : constant Identifier := Numbered_ID (11);
   Metadata_Transition_ID       : constant Identifier := Numbered_ID (12);
   Compaction_Run_ID            : constant Identifier := Numbered_ID (13);
   Compaction_Manifest_ID       : constant Identifier := Numbered_ID (14);
   Compaction_Transition_ID     : constant Identifier := Numbered_ID (15);
   Later_Transaction_ID         : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (16));
   Later_Run_ID                 : constant Identifier := Numbered_ID (17);
   --  The audit run deliberately reuses a value previously supplied for an
   --  empty family in the legacy full compaction map. Successful publication
   --  proves that ignored no-work entries do not reserve identities.
   Audit_Run_ID                 : constant Identifier := Numbered_ID (32);
   Later_Manifest_ID            : constant Identifier := Numbered_ID (19);
   Later_Transition_ID          : constant Identifier := Numbered_ID (20);
   Third_Transaction_ID         : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (21));
   Third_Run_ID                 : constant Identifier := Numbered_ID (22);
   Third_Manifest_ID            : constant Identifier := Numbered_ID (23);
   Third_Transition_ID          : constant Identifier := Numbered_ID (24);
   Merged_Run_ID                : constant Identifier := Numbered_ID (25);
   Merged_Manifest_ID           : constant Identifier := Numbered_ID (26);
   Merged_Transition_ID         : constant Identifier := Numbered_ID (27);
   Final_Primary_Run_ID         : constant Identifier := Numbered_ID (28);
   Final_Audit_Run_ID           : constant Identifier := Numbered_ID (29);
   Final_Manifest_ID            : constant Identifier := Numbered_ID (30);
   Final_Transition_ID          : constant Identifier := Numbered_ID (31);
   --  This compatibility-fixture identity is ignored because family 3 is
   --  empty at the first complete replacement. It is not a production
   --  placeholder convention or allocation policy.
   Legacy_Empty_Metadata_Run_ID : constant Identifier := Numbered_ID (33);
   --  IDs 38 and 39 identify the fixture's read-only transactions immediately
   --  before and after its one caller-triggered replica refresh. They are
   --  transaction-test geometry, not replica cadence or identity policy.
   Replica_Initial_Reader_ID    : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (38));
   Replica_Refreshed_Reader_ID  : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (39));
   --  IDs 40 through 44 are the suffix-backed Get, checkpoint-backed Get,
   --  authenticated scan reader, storage-backed multi-page, and whole-scan
   --  overflow fixtures. They are stable test identities, not allocation or
   --  transaction-ID generation policy.
   Suffix_Get_Reader_ID         : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (40));
   Checkpoint_Get_Reader_ID     : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (41));
   Scan_Reader_ID               : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (42));
   Storage_Page_Reader_ID       : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (43));
   Whole_Overflow_Reader_ID     : constant Transaction_Identifier :=
     Transaction_Identifier (Numbered_ID (44));
   --  IDs 45 through 47 form one conflicting root publication fixture. The
   --  provider admits its immutable manifest but the existing HEAD names the
   --  real database, proving typed Already_Exists normalization and restart.
   Conflicting_Database_ID      : constant Database_Identifier :=
     Database_Identifier (Numbered_ID (45));
   Conflicting_Manifest_ID      : constant Identifier := Numbered_ID (46);
   Conflicting_Transition_ID    : constant Identifier := Numbered_ID (47);
   --  Arbitrary nonzero fixture metadata proves the moved token, rather than
   --  only a same-pool replacement token, returns through typed Finish.
   Flush_Token_Tag              : constant Interfaces.Unsigned_64 := 16#F105#;
   Checkpoint_Runs              : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Checkpoint_Run_ID)];
   --  A legacy full-family map remains accepted. The empty-family entries are
   --  retained in the receipt but neither published nor identity-reserved.
   Compaction_Runs              : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Compaction_Run_ID),
      Configure_Checkpoint_Run (2, Audit_Run_ID),
      Configure_Checkpoint_Run (3, Legacy_Empty_Metadata_Run_ID)];
   Later_Runs                   : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Later_Run_ID), Configure_Checkpoint_Run (2, Audit_Run_ID)];
   Third_Runs                   : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Third_Run_ID)];
   Final_Compaction_Runs        : constant Checkpoint_Run_Identity_Array :=
     [Configure_Checkpoint_Run (1, Final_Primary_Run_ID), Configure_Checkpoint_Run (2, Final_Audit_Run_ID)];
   Key_Data                     : constant Byte_Array := Bytes ("client-key");
   Value_Data                   : constant Byte_Array := Bytes ("client-value");
   Later_Value_Data             : constant Byte_Array := Bytes ("client-value-later");
   Third_Value_Data             : constant Byte_Array := Bytes ("client-value-third");
   --  This auxiliary value is written in the second primary-family run and
   --  tombstoned in the third. It is exact regression-fixture geometry for
   --  authenticated multi-run scan suppression, not an application key or
   --  public ordering policy.
   Tombstone_Key_Data           : constant Byte_Array := Bytes ("gone");
   Tombstone_Value_Data         : constant Byte_Array := Bytes ("obsolete");
   Audit_Key_Data               : constant Byte_Array := Bytes ("event-1");
   Audit_Value_Data             : constant Byte_Array := Bytes ("remote-append");
   --  Reusable Flush, Refresh, and Open retain three DB operation slots. The
   --  active Object Storage operation, its HTTP exchange, and HTTP's transport
   --  child add three more. This is exact dependency-qualified test geometry,
   --  not a DB completion-set or connection-pool default.
   Composable_Set               : aliased Flyology.Operations.Completion_Set (6);
   --  The multi-run fixture adds one DB selector parent above the qualified
   --  five-slot one-run/Objects/HTTP/H1/transport stack. Six is therefore the
   --  exact observed owner-stack depth, not a production completion default.
   Lazy_Checkpoint_Set          : aliased Flyology.Operations.Completion_Set (6);
   --  The fixture selects its persisted live-state byte budget as the scratch
   --  block capacity and one token as serial operation geometry. Production
   --  callers select capacity from their own persisted family/database limits.
   Flush_Pool                   :
     aliased Flyology.Buffers.Pool (Block_Size => Positive (Limits.Maximum_Live_State_Bytes), Capacity => 1);
   Flush_Buffer                 : Flyology.Buffers.Unique_Buffer (Flush_Pool'Access);
   Restored_Buffer              : Flyology.Buffers.Unique_Buffer (Flush_Pool'Access);
   --  The lazy-read fixture derives its one-token scratch capacity from the
   --  persisted live-state byte budget, exactly as the serial flush fixture.
   Lazy_Pool                    :
     aliased Flyology.Buffers.Pool (Block_Size => Positive (Limits.Maximum_Live_State_Bytes), Capacity => 1);
   Lazy_Buffer                  : Flyology.Buffers.Unique_Buffer (Lazy_Pool'Access);
   Lazy_Restored_Buffer         : Flyology.Buffers.Unique_Buffer (Lazy_Pool'Access);
   --  Arbitrary nonzero test metadata proves typed Finish restores the moved
   --  token, rather than silently substituting another same-pool token.
   Lazy_Token_Tag               : constant Interfaces.Unsigned_64 := 16#1A2E#;
   Flush_Work                   :
     Flush_Operation
       (Composable_Set'Access, Created'Access, Context'Access, Client'Access, Flush_Pool'Access, null);
   Refresh_Work                 :
     Refresh_Operation
       (Composable_Set'Access, Replica'Access, Context'Access, Client'Access, Flush_Pool'Access, null);
   Open_Work                    :
     Open_Operation
       (Composable_Set'Access, Reopened'Access, Context'Access, Client'Access, Flush_Pool'Access, null);
   Lazy_Work                    :
     Lazy_SST_Read_Operation
       (Composable_Set'Access, Context'Access, Client'Access, Lazy_Pool'Access, null);
   Lazy_Checkpoint_Work         :
     Lazy_Checkpoint_Read_Operation
       (Lazy_Checkpoint_Set'Access, Context'Access, Client'Access, Lazy_Pool'Access, null);

   procedure Test_Public_Get
     (Transaction_ID : Transaction_Identifier;
      Expected_Value : Byte_Array;
      Checkpoint_Backed : Boolean)
   is
      --  The public Get parent adds one slot above the established six-slot
      --  private checkpoint selector stack. This is exact fixture geometry,
      --  not a production completion-set default.
      Read_Set       : aliased Flyology.Operations.Completion_Set (7);
      Read_Pool      : aliased Flyology.Buffers.Pool
        (Block_Size => Positive (Limits.Maximum_Live_State_Bytes), Capacity => 1);
      Read_Buffer    : Flyology.Buffers.Unique_Buffer (Read_Pool'Access);
      Restored       : Flyology.Buffers.Unique_Buffer (Read_Pool'Access);
      Read_Txn       : aliased Transaction;
      Stop           : aliased Flyology.Cancellation.Token;
      Read_Work      : Get_Operation
        (Read_Set'Access, Created'Access, Read_Txn'Access, Read_Pool'Access, null);
      Cancelled_Work : Get_Operation
        (Read_Set'Access, Created'Access, Read_Txn'Access, Read_Pool'Access, Stop'Access);
      Read_Data      : Flyology.Bytes.Unbounded_Bytes;
      Local_Key      : constant Byte_Array := Bytes ("local-key");
      Local_Value    : constant Byte_Array := Bytes ("local-value");
      --  Arbitrary nonzero metadata proves the exact moved token returns from
      --  both composable and synchronous waits.
      Read_Tag       : constant Interfaces.Unsigned_64 := 16#6E71#;
      --  Exact zero is the already-expired deadline fixture. It selects no
      --  production timeout default or scheduling interval.
      Expired_Timeout : constant Duration := 0.0;

      procedure Expect_Allocation_Rejection
        (Point   : Internal_Allocation_Fault_Point;
         Context : String)
      is
      begin
         Set_Test_Allocation_Fault (Point);
         Get
           (Family,
            Key_Data,
            Read_Buffer,
            Test_Operation_Timeout,
            Read_Work);
         Flyology.Operations.Wait_All (Read_Set);
         Finish (Read_Work, Read_Data, Result, Restored);
         Expect (Result, Capacity_Exceeded, Context);
         if Flyology.Bytes.Length (Read_Data) /= 0
           or else Read_Txn.Owner.Arena.Point_Read_Count /= 0
           or else not Flyology.Buffers.Has_Buffer (Restored)
           or else Flyology.Buffers.Tag (Restored) /= Read_Tag
         then
            raise Program_Error with Context & " lost failure or token authority";
         end if;
         Flyology.Buffers.Move (Restored, Read_Buffer);
      end Expect_Allocation_Rejection;
   begin
      Begin_Transaction
        (Created, Transaction_ID, Serializable, Read_Txn, Result);
      Expect (Result, Success, "public Get reader begin failed");

      --  A busy one-slot set rejects before token movement. Exact bytes,
      --  length, and tag prove that Get also rolls back its retained database
      --  lease and operation state without consuming caller ownership.
      declare
         Marker          : constant Ada.Streams.Stream_Element_Array := [16#A5#, 16#5A#, 16#C3#];
         Rollback_Set    : aliased Flyology.Operations.Completion_Set (1);
         Rollback_Pool   : aliased Flyology.Buffers.Pool
           (Block_Size => Positive (Marker'Length), Capacity => 1);
         Rollback_Buffer : Flyology.Buffers.Unique_Buffer (Rollback_Pool'Access);
         Rollback_Work   : Get_Operation
           (Rollback_Set'Access,
            Created'Access,
            Read_Txn'Access,
            Rollback_Pool'Access,
            null);
         Busy            : Timers.Timer_Operation :=
           Timers.Sleep_For (Rollback_Set'Access, Test_Operation_Timeout);
         Rejected        : Boolean := False;
      begin
         Flyology.Buffers.Acquire (Rollback_Buffer);
         Flyology.Buffers.Copy_From (Rollback_Buffer, Marker);
         Flyology.Buffers.Set_Tag (Rollback_Buffer, Read_Tag);
         begin
            Get
              (Family,
               Key_Data,
               Rollback_Buffer,
               Test_Operation_Timeout,
               Rollback_Work);
         exception
            when Flyology.Operations.Capacity_Error =>
               Rejected := True;
         end;
         if not Rejected
           or else not Flyology.Buffers.Has_Buffer (Rollback_Buffer)
           or else Flyology.Buffers.Length (Rollback_Buffer) /= Marker'Length
           or else Flyology.Buffers.Tag (Rollback_Buffer) /= Read_Tag
           or else not Same (Rollback_Buffer, Marker)
         then
            raise Program_Error with "public Get Start did not roll back its exact token";
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

      Flyology.Buffers.Acquire (Read_Buffer);
      Flyology.Buffers.Set_Tag (Read_Buffer, Read_Tag);
      Expect_Allocation_Rejection
        (Get_Operation_State_Allocation,
         "public Get state allocation failure was not typed");
      if Checkpoint_Backed then
         Expect_Allocation_Rejection
           (Get_Run_Descriptor_Allocation,
            "public Get run allocation failure was not typed");
         Expect_Allocation_Rejection
           (Get_Child_Operation_Allocation,
            "public Get child allocation failure was not typed");
      end if;

      Stop.Request;
      Get
        (Family,
         Key_Data,
         Read_Buffer,
         Test_Operation_Timeout,
         Cancelled_Work);
      Flyology.Operations.Wait_All (Read_Set);
      Finish (Cancelled_Work, Read_Data, Result, Restored);
      Expect (Result, Cancelled, "public Get ignored pre-start cancellation");
      if Flyology.Bytes.Length (Read_Data) /= 0
        or else Read_Txn.Owner.Arena.Point_Read_Count /= 0
        or else Flyology.Buffers.Tag (Restored) /= Read_Tag
      then
         raise Program_Error with "public Get cancellation published data or lost token authority";
      end if;
      Flyology.Buffers.Move (Restored, Read_Buffer);

      Get
        (Family,
         Key_Data,
         Read_Buffer,
         Expired_Timeout,
         Read_Work);
      Flyology.Operations.Wait_All (Read_Set);
      Finish (Read_Work, Read_Data, Result, Restored);
      Expect (Result, Timed_Out, "public Get ignored an expired deadline");
      if Flyology.Bytes.Length (Read_Data) /= 0
        or else Read_Txn.Owner.Arena.Point_Read_Count /= 0
        or else Flyology.Buffers.Tag (Restored) /= Read_Tag
      then
         raise Program_Error with "public Get timeout published data or lost token authority";
      end if;
      Flyology.Buffers.Move (Restored, Read_Buffer);

      Get
        (Family,
         Key_Data,
         Read_Buffer,
         Test_Operation_Timeout,
         Read_Work);
      if Flyology.Buffers.Has_Buffer (Read_Buffer) then
         raise Program_Error with "public composable Get did not move its scratch token";
      end if;
      Flyology.Operations.Wait_All (Read_Set);
      Finish (Read_Work, Read_Data, Result, Restored);
      Expect (Result, Success, "public composable Get failed");
      if not Same (Read_Data, Expected_Value)
        or else not Flyology.Buffers.Has_Buffer (Restored)
        or else Flyology.Buffers.Tag (Restored) /= Read_Tag
        or else Read_Txn.Owner.Arena.Point_Read_Count /= 1
      then
         raise Program_Error with "public composable Get lost value, observation, or token authority";
      end if;

      Put (Created, Read_Txn, Family, Local_Key, Local_Value, Result);
      Expect (Result, Success, "public Get local fixture Put failed");
      Get
        (Family,
         Local_Key,
         Restored,
         Test_Operation_Timeout,
         Read_Work);
      Flyology.Operations.Wait_All (Read_Set);
      Finish (Read_Work, Read_Data, Result, Read_Buffer);
      Expect (Result, Success, "public Get did not select its transaction-local value");
      if not Same (Read_Data, Local_Value)
        or else Read_Txn.Owner.Arena.Point_Read_Count /= 1
        or else Flyology.Buffers.Tag (Read_Buffer) /= Read_Tag
      then
         raise Program_Error with "public Get treated its own mutation as an external observation";
      end if;

      Get
        (Created,
         Read_Txn,
         Family,
         Bytes ("missing-key"),
         Read_Buffer,
         Test_Operation_Timeout,
         null,
         Read_Data,
         Result);
      Expect (Result, Not_Found, "public synchronous Get absence failed");
      if Flyology.Bytes.Length (Read_Data) /= 0
        or else Read_Txn.Owner.Arena.Point_Read_Count /= 2
        or else not Flyology.Buffers.Has_Buffer (Read_Buffer)
        or else Flyology.Buffers.Tag (Read_Buffer) /= Read_Tag
      then
         raise Program_Error with "public synchronous Get lost absence observation or token authority";
      end if;
      Flyology.Operations.Release (Read_Work);
      Flyology.Operations.Release (Cancelled_Work);
      Rollback (Read_Txn, Result);
      Expect (Result, Success, "public Get reader rollback failed");
      Flyology.Buffers.Release (Read_Buffer);
   exception
      when others =>
         Flyology.Buffers.Release (Read_Buffer);
         Flyology.Buffers.Release (Restored);
         raise;
   end Test_Public_Get;

   procedure Test_Public_Scan is
      --  The DB scan parent plus its next-entry provider/HTTP/transport stack
      --  uses six exact fixture slots. This is scheduling geometry, not a DB
      --  page, queue, or persisted capacity. One frozen SST-v2 header is also
      --  the exact scratch size: every header/index/frame range in this
      --  two-entry fixture fits, while no complete SST object does. This proves
      --  the authenticated scan no longer depends on whole-run retention.
      --  128 is the persisted SST-v2 header length frozen beside
      --  Flyology.DB.LSM_Runtime_Formats.SST_V2_Header_Length; changing that
      --  format authority requires this negative whole-object oracle to move
      --  with it.
      Scan_Scratch_Bytes : constant Positive := 128;
      Scan_Set       : aliased Flyology.Operations.Completion_Set (6);
      Scan_Pool      :
        aliased Flyology.Buffers.Pool
                  (Block_Size => Scan_Scratch_Bytes, Capacity => 1);
      Scan_Buffer    : Flyology.Buffers.Unique_Buffer (Scan_Pool'Access);
      Restored       : Flyology.Buffers.Unique_Buffer (Scan_Pool'Access);
      Scan_Txn       : aliased Transaction;
      Stop           : aliased Flyology.Cancellation.Token;
      Cursor         : Scan_Cursor;
      Rows           : Scan_Result;
      Work           :
        Scan_Operation (Scan_Set'Access, Created'Access, Scan_Txn'Access, Scan_Pool'Access, null);
      Cancelled_Work :
        Scan_Operation (Scan_Set'Access, Created'Access, Scan_Txn'Access, Scan_Pool'Access, Stop'Access);
      Item_Key       : Flyology.Bytes.Unbounded_Bytes;
      Item_Value     : Flyology.Bytes.Unbounded_Bytes;
      Done           : Boolean;
      --  Arbitrary nonzero metadata proves exact token restoration through an
      --  arbitrary vacant same-pool handle.
      Scan_Tag       : constant Interfaces.Unsigned_64 := 16#5CA4#;
      --  This local row sorts after the persisted client-key fixture and
      --  forces an exact two-page merge. The bytes are test geometry, not a
      --  product key, page size, or ordering policy.
      Paged_Key      : constant Byte_Array := Bytes ("local-page-key");
      Paged_Value    : constant Byte_Array := Bytes ("local-page-value");
      --  Four local rows plus the one persisted row exceed the fixture's exact
      --  four-row live-state authority. They exercise failure atomicity rather
      --  than define a production key pattern or result-size policy.
      Overflow_Key_1 : constant Byte_Array := Bytes ("whole-overflow-a");
      Overflow_Key_2 : constant Byte_Array := Bytes ("whole-overflow-b");
      Overflow_Key_3 : constant Byte_Array := Bytes ("whole-overflow-c");
      Overflow_Key_4 : constant Byte_Array := Bytes ("whole-overflow-d");

      procedure Expect_Allocation_Rejection (Point : Internal_Allocation_Fault_Point; Context : String) is
      begin
         Set_Test_Allocation_Fault (Point);
         Start_Scan (Family, False, Bytes (""), False, Bytes (""), Scan_Buffer, Test_Operation_Timeout, Work);
         Flyology.Operations.Wait_All (Scan_Set);
         Finish (Work, Cursor, Result, Restored);
         Expect (Result, Capacity_Exceeded, Context);
         if not Flyology.Buffers.Has_Buffer (Restored) or else Flyology.Buffers.Tag (Restored) /= Scan_Tag
         then
            raise Program_Error with Context & " lost exact token authority";
         end if;
         Flyology.Buffers.Move (Restored, Scan_Buffer);
      end Expect_Allocation_Rejection;
   begin
      Begin_Transaction (Created, Scan_Reader_ID, Scan_Txn, Result);
      Expect (Result, Success, "authenticated scan reader begin failed");

      --  A busy one-slot set rejects before token movement. Exact bytes,
      --  length, and tag prove complete operation-state and lease rollback.
      declare
         Marker          : constant Ada.Streams.Stream_Element_Array := [16#5C#, 16#A4#, 16#7E#];
         Rollback_Set    : aliased Flyology.Operations.Completion_Set (1);
         Rollback_Pool   :
           aliased Flyology.Buffers.Pool (Block_Size => Positive (Marker'Length), Capacity => 1);
         Rollback_Buffer : Flyology.Buffers.Unique_Buffer (Rollback_Pool'Access);
         Rollback_Work   :
           Scan_Operation (Rollback_Set'Access, Created'Access, Scan_Txn'Access, Rollback_Pool'Access, null);
         Busy            : Timers.Timer_Operation :=
           Timers.Sleep_For (Rollback_Set'Access, Test_Operation_Timeout);
         Rejected        : Boolean := False;
      begin
         Flyology.Buffers.Acquire (Rollback_Buffer);
         Flyology.Buffers.Copy_From (Rollback_Buffer, Marker);
         Flyology.Buffers.Set_Tag (Rollback_Buffer, Scan_Tag);
         begin
            Start_Scan
              (Family,
               False,
               Bytes (""),
               False,
               Bytes (""),
               Rollback_Buffer,
               Test_Operation_Timeout,
               Rollback_Work);
         exception
            when Flyology.Operations.Capacity_Error =>
               Rejected := True;
         end;
         if not Rejected
           or else not Flyology.Buffers.Has_Buffer (Rollback_Buffer)
           or else Flyology.Buffers.Length (Rollback_Buffer) /= Marker'Length
           or else Flyology.Buffers.Tag (Rollback_Buffer) /= Scan_Tag
           or else not Same (Rollback_Buffer, Marker)
         then
            raise Program_Error with "authenticated scan Start did not roll back its exact token";
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

      Flyology.Buffers.Acquire (Scan_Buffer);
      Flyology.Buffers.Set_Tag (Scan_Buffer, Scan_Tag);
      Expect_Allocation_Rejection
        (Scan_Operation_State_Allocation, "authenticated scan state allocation failure was not typed");
      Expect_Allocation_Rejection
        (Get_Run_Descriptor_Allocation, "authenticated scan run-descriptor allocation failure was not typed");
      Expect_Allocation_Rejection
        (Scan_Run_Array_Allocation, "authenticated scan run-array allocation failure was not typed");
      Expect_Allocation_Rejection
        (Scan_Run_Entry_Allocation, "authenticated scan selected-entry allocation failure was not typed");
      Expect_Allocation_Rejection
        (Scan_Child_Operation_Allocation, "authenticated scan child allocation failure was not typed");

      Stop.Request;
      Start_Scan
        (Family, False, Bytes (""), False, Bytes (""), Scan_Buffer, Test_Operation_Timeout, Cancelled_Work);
      Flyology.Operations.Wait_All (Scan_Set);
      Finish (Cancelled_Work, Cursor, Result, Restored);
      Expect (Result, Cancelled, "authenticated scan ignored pre-start cancellation");
      if not Flyology.Buffers.Has_Buffer (Restored) or else Flyology.Buffers.Tag (Restored) /= Scan_Tag then
         raise Program_Error with "cancelled authenticated scan lost token authority";
      end if;
      Flyology.Buffers.Move (Restored, Scan_Buffer);

      --  A terminal timeout cannot replace an already valid cursor. The
      --  subsequent local page proves exact prior position preservation.
      Start_Scan (Created, Scan_Txn, Family, False, Bytes (""), False, Bytes (""), Cursor, Result);
      Expect (Result, Success, "prior scan cursor initialization failed");
      Start_Scan (Family, False, Bytes (""), False, Bytes (""), Scan_Buffer, 0.0, Work);
      if Flyology.Buffers.Has_Buffer (Scan_Buffer) then
         raise Program_Error with "authenticated scan did not move its scratch token";
      end if;
      Flyology.Operations.Wait_All (Scan_Set);
      Finish (Work, Cursor, Result, Restored);
      Expect (Result, Timed_Out, "authenticated scan ignored expired deadline");
      if not Flyology.Buffers.Has_Buffer (Restored) or else Flyology.Buffers.Tag (Restored) /= Scan_Tag then
         raise Program_Error with "failed authenticated scan lost token authority";
      end if;
      Next_Scan_Page (Created, Scan_Txn, Cursor, 1, Limits.Maximum_Live_State_Bytes, Rows, Done, Result);
      Expect (Result, Success, "failed authenticated scan replaced prior cursor");
      if Scan_Row_Count (Rows) /= 1 or else not Done then
         raise Program_Error with "prior scan cursor returned the wrong page";
      end if;

      --  Restart the consumed operation and publish a fresh authenticated
      --  cursor only through typed Finish.
      Start_Scan (Family, False, Bytes (""), False, Bytes (""), Restored, Test_Operation_Timeout, Work);
      Flyology.Operations.Wait_All (Scan_Set);
      Finish (Work, Cursor, Result, Scan_Buffer);
      Expect (Result, Success, "composable authenticated scan initialization failed");
      if not Flyology.Buffers.Has_Buffer (Scan_Buffer) or else Flyology.Buffers.Tag (Scan_Buffer) /= Scan_Tag
      then
         raise Program_Error with "authenticated scan Finish lost the exact token";
      end if;
      Next_Scan_Page (Created, Scan_Txn, Cursor, 1, Limits.Maximum_Live_State_Bytes, Rows, Done, Result);
      Expect (Result, Success, "authenticated scan page failed");
      if Scan_Row_Count (Rows) /= 1 or else not Done then
         raise Program_Error with "authenticated scan did not suppress its newer tombstone";
      end if;
      Read_Scan_Row (Rows, 1, Item_Key, Item_Value, Result);
      Expect (Result, Success, "authenticated scan row read failed");
      if not Same (Item_Key, Key_Data) or else not Same (Item_Value, Third_Value_Data) then
         raise Program_Error with "authenticated scan returned the wrong fixed-snapshot bytes";
      end if;

      --  The blocking overload is a literal wait over the same operation and
      --  replaces the completed cursor with a fresh position.
      Start_Scan
        (Created,
         Scan_Txn,
         Family,
         False,
         Bytes (""),
         False,
         Bytes (""),
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Cursor,
         Result);
      Expect (Result, Success, "blocking authenticated scan initialization failed");
      Next_Scan_Page (Created, Scan_Txn, Cursor, 1, Limits.Maximum_Live_State_Bytes, Rows, Done, Result);
      Expect (Result, Success, "blocking authenticated scan page failed");
      if Scan_Row_Count (Rows) /= 1 or else not Done then
         raise Program_Error with "blocking authenticated scan returned the wrong page";
      end if;

      --  The limited end-to-end storage-backed path publishes only exact run
      --  descriptors at initialization and performs authenticated next-entry
      --  reads while advancing each page. The old storage-free page overload
      --  must reject that cursor rather than silently omitting checkpoint
      --  rows. A first-row capacity failure preserves both cursor and Rows;
      --  the subsequent composable page succeeds from the same position and
      --  restores the exact scratch token.
      Start_Storage_Backed_Scan
        (Created,
         Scan_Txn,
         Family,
         False,
         Bytes (""),
         False,
         Bytes (""),
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Cursor,
         Result);
      Expect (Result, Success, "storage-backed scan initialization failed");
      Next_Scan_Page
        (Created,
         Scan_Txn,
         Cursor,
         1,
         Limits.Maximum_Live_State_Bytes,
         Rows,
         Done,
         Result);
      Expect (Result, Invalid_State, "storage-backed cursor entered the storage-free page path");
      Next_Scan_Page
        (Created,
         Scan_Txn,
         Cursor,
         0,
         0,
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Rows,
         Done,
         Result);
      Expect (Result, Capacity_Exceeded, "storage-backed first-row capacity was not atomic");
      if Done
        or else Scan_Row_Count (Rows) /= 1
        or else not Flyology.Buffers.Has_Buffer (Scan_Buffer)
        or else Flyology.Buffers.Tag (Scan_Buffer) /= Scan_Tag
      then
         raise Program_Error with "failed storage-backed page changed cursor, rows, or token authority";
      end if;
      Set_Test_Allocation_Fault (Scan_Cursor_State_Allocation);
      Next_Scan_Page
        (Created,
         Scan_Txn,
         Cursor,
         1,
         Limits.Maximum_Live_State_Bytes,
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Rows,
         Done,
         Result);
      Expect (Result, Capacity_Exceeded, "storage-backed page clone allocation failure was not typed");
      if Done
        or else Scan_Row_Count (Rows) /= 1
        or else not Flyology.Buffers.Has_Buffer (Scan_Buffer)
        or else Flyology.Buffers.Tag (Scan_Buffer) /= Scan_Tag
      then
         raise Program_Error with "failed storage-backed clone changed cursor, rows, or token authority";
      end if;
      Next_Scan_Page
        (Cursor,
         1,
         Limits.Maximum_Live_State_Bytes,
         Scan_Buffer,
         Test_Operation_Timeout,
         Cancelled_Work);
      Flyology.Operations.Wait_All (Scan_Set);
      Finish (Cancelled_Work, Cursor, Rows, Done, Result, Restored);
      Expect (Result, Cancelled, "storage-backed page ignored cancellation");
      if Done
        or else Scan_Row_Count (Rows) /= 1
        or else not Flyology.Buffers.Has_Buffer (Restored)
        or else Flyology.Buffers.Tag (Restored) /= Scan_Tag
      then
         raise Program_Error with "cancelled storage-backed page changed cursor, rows, or token authority";
      end if;
      Flyology.Buffers.Move (Restored, Scan_Buffer);
      Next_Scan_Page
        (Cursor,
         1,
         Limits.Maximum_Live_State_Bytes,
         Scan_Buffer,
         Test_Operation_Timeout,
         Work);
      Flyology.Operations.Wait_All (Scan_Set);
      Finish (Work, Cursor, Rows, Done, Result, Restored);
      Expect (Result, Success, "composable storage-backed page failed");
      if Scan_Row_Count (Rows) /= 1
        or else not Done
        or else not Flyology.Buffers.Has_Buffer (Restored)
        or else Flyology.Buffers.Tag (Restored) /= Scan_Tag
      then
         raise Program_Error with "storage-backed page returned the wrong row or token";
      end if;
      Read_Scan_Row (Rows, 1, Item_Key, Item_Value, Result);
      Expect (Result, Success, "storage-backed page row read failed");
      if not Same (Item_Key, Key_Data) or else not Same (Item_Value, Third_Value_Data) then
         raise Program_Error with "storage-backed page returned the wrong fixed-snapshot bytes";
      end if;
      Flyology.Buffers.Move (Restored, Scan_Buffer);

      --  The whole-result overload waits on that same authenticated cursor
      --  initializer and then requests one complete page under persisted live
      --  limits; it does not rebuild visibility through the local checkpoint.
      --  Arming the compatibility initializer's selected-run array allocation
      --  proves the whole call instead takes the descriptor-backed path. The
      --  fault remains armed on success and is cleared explicitly afterward.
      Set_Test_Allocation_Fault (Scan_Run_Array_Allocation);
      Scan
        (Created,
         Scan_Txn,
         Family,
         False,
         Bytes (""),
         False,
         Bytes (""),
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Rows,
         Result);
      Set_Test_Allocation_Fault (No_Allocation_Fault);
      Expect (Result, Success, "whole authenticated scan failed");
      if Scan_Row_Count (Rows) /= 1 then
         raise Program_Error with "whole authenticated scan returned the wrong row count";
      end if;
      Read_Scan_Row (Rows, 1, Item_Key, Item_Value, Result);
      Expect (Result, Success, "whole authenticated scan row read failed");
      if not Same (Item_Key, Key_Data) or else not Same (Item_Value, Third_Value_Data) then
         raise Program_Error with "whole authenticated scan returned the wrong fixed-snapshot bytes";
      end if;

      --  Initialization failure preserves both the exact caller token and the
      --  prior complete result instead of publishing an empty or partial set.
      Scan
        (Created,
         Scan_Txn,
         Family,
         False,
         Bytes (""),
         False,
         Bytes (""),
         Scan_Buffer,
         0.0,
         null,
         Rows,
         Result);
      Expect (Result, Timed_Out, "whole authenticated scan ignored expired deadline");
      if not Flyology.Buffers.Has_Buffer (Scan_Buffer)
        or else Flyology.Buffers.Tag (Scan_Buffer) /= Scan_Tag
        or else Scan_Row_Count (Rows) /= 1
      then
         raise Program_Error with "failed whole authenticated scan lost result or token authority";
      end if;
      Read_Scan_Row (Rows, 1, Item_Key, Item_Value, Result);
      Expect (Result, Success, "preserved whole authenticated scan row read failed");
      if not Same (Item_Key, Key_Data) or else not Same (Item_Value, Third_Value_Data) then
         raise Program_Error with "failed whole authenticated scan changed prior row bytes";
      end if;

      Rollback (Scan_Txn, Result);
      Expect (Result, Success, "authenticated scan reader rollback failed");
      Begin_Transaction (Created, Storage_Page_Reader_ID, Scan_Txn, Result);
      Expect (Result, Success, "storage-backed multi-page reader begin failed");
      Put (Created, Scan_Txn, Family, Paged_Key, Paged_Value, Result);
      Expect (Result, Success, "storage-backed multi-page local Put failed");
      Start_Storage_Backed_Scan
        (Created,
         Scan_Txn,
         Family,
         False,
         Bytes (""),
         False,
         Bytes (""),
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Cursor,
         Result);
      Expect (Result, Success, "storage-backed multi-page initialization failed");
      Next_Scan_Page
        (Created,
         Scan_Txn,
         Cursor,
         1,
         Limits.Maximum_Live_State_Bytes,
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Rows,
         Done,
         Result);
      Expect (Result, Success, "storage-backed first merged page failed");
      if Done or else Scan_Row_Count (Rows) /= 1 then
         raise Program_Error with "storage-backed first merged page completed early";
      end if;
      Read_Scan_Row (Rows, 1, Item_Key, Item_Value, Result);
      Expect (Result, Success, "storage-backed first merged row read failed");
      if not Same (Item_Key, Key_Data) or else not Same (Item_Value, Third_Value_Data) then
         raise Program_Error with "storage-backed first merged page returned the wrong row";
      end if;
      Next_Scan_Page
        (Created,
         Scan_Txn,
         Cursor,
         1,
         Limits.Maximum_Live_State_Bytes,
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Rows,
         Done,
         Result);
      Expect (Result, Success, "storage-backed second merged page failed");
      if not Done or else Scan_Row_Count (Rows) /= 1 then
         raise Program_Error with "storage-backed second merged page did not complete exactly";
      end if;
      Read_Scan_Row (Rows, 1, Item_Key, Item_Value, Result);
      Expect (Result, Success, "storage-backed second merged row read failed");
      if not Same (Item_Key, Paged_Key) or else not Same (Item_Value, Paged_Value) then
         raise Program_Error with "storage-backed second merged page returned the wrong row";
      end if;
      Flyology.Operations.Release (Work);
      Flyology.Operations.Release (Cancelled_Work);
      Rollback (Scan_Txn, Result);
      Expect (Result, Success, "storage-backed multi-page reader rollback failed");

      --  A whole scan that exceeds persisted live-state authority must reject
      --  before the private page driver publishes its bounded prefix or
      --  retains a serializable predicate. The prior successful row and exact
      --  buffer token remain caller-owned on failure.
      Begin_Transaction
        (Created, Whole_Overflow_Reader_ID, Serializable, Scan_Txn, Result);
      Expect (Result, Success, "whole-scan overflow reader begin failed");
      Put (Created, Scan_Txn, Family, Overflow_Key_1, Paged_Value, Result);
      Expect (Result, Success, "whole-scan overflow first Put failed");
      Put (Created, Scan_Txn, Family, Overflow_Key_2, Paged_Value, Result);
      Expect (Result, Success, "whole-scan overflow second Put failed");
      Put (Created, Scan_Txn, Family, Overflow_Key_3, Paged_Value, Result);
      Expect (Result, Success, "whole-scan overflow third Put failed");
      Put (Created, Scan_Txn, Family, Overflow_Key_4, Paged_Value, Result);
      Expect (Result, Success, "whole-scan overflow fourth Put failed");
      Scan
        (Created,
         Scan_Txn,
         Family,
         False,
         Bytes (""),
         False,
         Bytes (""),
         Scan_Buffer,
         Test_Operation_Timeout,
         null,
         Rows,
         Result);
      Expect (Result, Capacity_Exceeded, "whole-scan overflow published a bounded prefix");
      if Scan_Txn.Owner.Arena.Scan_Range_Count /= 0
        or else not Flyology.Buffers.Has_Buffer (Scan_Buffer)
        or else Flyology.Buffers.Tag (Scan_Buffer) /= Scan_Tag
        or else Scan_Row_Count (Rows) /= 1
      then
         raise Program_Error with "whole-scan overflow changed predicate, rows, or token authority";
      end if;
      Read_Scan_Row (Rows, 1, Item_Key, Item_Value, Result);
      Expect (Result, Success, "whole-scan overflow changed prior row readability");
      if not Same (Item_Key, Paged_Key) or else not Same (Item_Value, Paged_Value) then
         raise Program_Error with "whole-scan overflow changed prior row bytes";
      end if;
      Rollback (Scan_Txn, Result);
      Expect (Result, Success, "whole-scan overflow reader rollback failed");
      Flyology.Buffers.Release (Scan_Buffer);
   exception
      when others =>
         Flyology.Buffers.Release (Scan_Buffer);
         Flyology.Buffers.Release (Restored);
         raise;
   end Test_Public_Scan;

   procedure Test_Lazy_SST_Read is
      Stop           : aliased Flyology.Cancellation.Token;
      Cancelled_Work :
        Lazy_SST_Read_Operation
          (Composable_Set'Access, Context'Access, Client'Access, Lazy_Pool'Access, Stop'Access);

      procedure Read_And_Expect
        (Source               : in out Flyology.Buffers.Unique_Buffer;
         Destination          : in out Flyology.Buffers.Unique_Buffer;
         Key                  : Byte_Array;
         Snapshot             : Sequence_Number;
         Expected_Disposition : Lazy_SST_Entry_Disposition;
         Expected_Sequence    : Sequence_Number;
         Expected_Value       : Byte_Array;
         Expected_Result      : Outcome_Code)
      is
         Disposition : Lazy_SST_Entry_Disposition;
         Sequence    : Sequence_Number;
         Value       : Flyology.Bytes.Unbounded_Bytes;
         Read_Result : Outcome_Code;
      begin
         Read_Lazy_SST_Entry
           (Probe_Database_ID,
            Families (Families'First),
            Checkpoint_Run_ID,
            Receipt_Sequence (Commit_Info),
            Receipt_Sequence (Commit_Info),
            1,
            Interfaces.Unsigned_64 (Key_Data'Length + Value_Data'Length),
            Snapshot,
            Key,
            Source,
            Test_Operation_Timeout,
            Lazy_Work);
         if Flyology.Buffers.Has_Buffer (Source) then
            raise Program_Error with "lazy SST read did not move its scratch token";
         end if;
         Flyology.Operations.Wait_All (Composable_Set);
         Finish_Lazy_SST_Read (Lazy_Work, Disposition, Sequence, Value, Read_Result, Destination);
         Expect (Read_Result, Expected_Result, "client-backed lazy SST read failed");
         if Disposition /= Expected_Disposition
           or else Sequence /= Expected_Sequence
           or else not Same (Value, Expected_Value)
           or else not Flyology.Buffers.Has_Buffer (Destination)
           or else Flyology.Buffers.Tag (Destination) /= Lazy_Token_Tag
         then
            raise Program_Error
              with
                "client-backed lazy SST read returned the wrong entry: disposition="
                & Lazy_SST_Entry_Disposition'Image (Disposition)
                & " sequence="
                & Sequence_Number'Image (Sequence)
                & " value_length="
                & Natural'Image (Flyology.Bytes.Length (Value))
                & " result="
                & Outcome_Code'Image (Read_Result)
                & " token="
                & Boolean'Image (Flyology.Buffers.Has_Buffer (Destination));
         end if;
      end Read_And_Expect;

      procedure Next_And_Expect
        (Source               : in out Flyology.Buffers.Unique_Buffer;
         Destination          : in out Flyology.Buffers.Unique_Buffer;
         Snapshot             : Sequence_Number;
         Has_Start            : Boolean;
         Start_Key            : Byte_Array;
         Start_Inclusive      : Boolean;
         Has_Upper            : Boolean;
         Upper_Key            : Byte_Array;
         Expected_Disposition : Lazy_SST_Entry_Disposition;
         Expected_Sequence    : Sequence_Number;
         Expected_Key         : Byte_Array;
         Expected_Value       : Byte_Array;
         Expected_Result      : Outcome_Code;
         Read_Timeout         : Duration := Test_Operation_Timeout)
      is
         Disposition : Lazy_SST_Entry_Disposition;
         Sequence    : Sequence_Number;
         Item_Key    : Flyology.Bytes.Unbounded_Bytes;
         Value       : Flyology.Bytes.Unbounded_Bytes;
         Read_Result : Outcome_Code;
      begin
         Read_Lazy_SST_Next_Entry
           (Probe_Database_ID,
            Families (Families'First),
            Checkpoint_Run_ID,
            Receipt_Sequence (Commit_Info),
            Receipt_Sequence (Commit_Info),
            1,
            Interfaces.Unsigned_64 (Key_Data'Length + Value_Data'Length),
            Snapshot,
            Has_Start,
            Start_Key,
            Start_Inclusive,
            Has_Upper,
            Upper_Key,
            Source,
            Read_Timeout,
            Lazy_Work);
         if Flyology.Buffers.Has_Buffer (Source) then
            raise Program_Error with "lazy SST next-entry read did not move its scratch token";
         end if;
         Flyology.Operations.Wait_All (Composable_Set);
         Finish_Lazy_SST_Next_Entry
           (Lazy_Work, Disposition, Sequence, Item_Key, Value, Read_Result, Destination);
         Expect (Read_Result, Expected_Result, "client-backed lazy SST next-entry read failed");
         if Disposition /= Expected_Disposition
           or else Sequence /= Expected_Sequence
           or else not Same (Item_Key, Expected_Key)
           or else not Same (Value, Expected_Value)
           or else not Flyology.Buffers.Has_Buffer (Destination)
           or else Flyology.Buffers.Tag (Destination) /= Lazy_Token_Tag
         then
            raise Program_Error with "client-backed lazy SST next-entry read returned the wrong result";
         end if;
      end Next_And_Expect;
   begin
      Flyology.Buffers.Acquire (Lazy_Buffer);
      Flyology.Buffers.Set_Tag (Lazy_Buffer, Lazy_Token_Tag);
      Read_And_Expect
        (Lazy_Buffer,
         Lazy_Restored_Buffer,
         Key_Data,
         Receipt_Sequence (Commit_Info),
         Lazy_Value_Found,
         Receipt_Sequence (Commit_Info),
         Value_Data,
         Success);
      Read_And_Expect
        (Lazy_Restored_Buffer,
         Lazy_Buffer,
         Bytes ("z"),
         Receipt_Sequence (Commit_Info),
         Lazy_Key_Absent,
         0,
         Bytes (""),
         Not_Found);
      Next_And_Expect
        (Lazy_Buffer,
         Lazy_Restored_Buffer,
         Receipt_Sequence (Commit_Info),
         False,
         Bytes ("ignored"),
         False,
         False,
         Bytes ("ignored"),
         Lazy_Value_Found,
         Receipt_Sequence (Commit_Info),
         Key_Data,
         Value_Data,
         Success);
      Next_And_Expect
        (Lazy_Restored_Buffer,
         Lazy_Buffer,
         Receipt_Sequence (Commit_Info),
         True,
         Key_Data,
         True,
         False,
         Bytes ("ignored"),
         Lazy_Value_Found,
         Receipt_Sequence (Commit_Info),
         Key_Data,
         Value_Data,
         Success);
      Next_And_Expect
        (Lazy_Buffer,
         Lazy_Restored_Buffer,
         Receipt_Sequence (Commit_Info),
         True,
         Key_Data,
         False,
         False,
         Bytes ("ignored"),
         Lazy_Key_Absent,
         0,
         Bytes (""),
         Bytes (""),
         Not_Found);
      Next_And_Expect
        (Lazy_Restored_Buffer,
         Lazy_Buffer,
         Receipt_Sequence (Commit_Info),
         False,
         Bytes ("ignored"),
         False,
         True,
         Key_Data,
         Lazy_Key_Absent,
         0,
         Bytes (""),
         Bytes (""),
         Not_Found);
      Next_And_Expect
        (Lazy_Buffer,
         Lazy_Restored_Buffer,
         Receipt_Sequence (Commit_Info) - 1,
         False,
         Bytes ("ignored"),
         False,
         False,
         Bytes ("ignored"),
         Lazy_Key_Absent,
         0,
         Bytes (""),
         Bytes (""),
         Not_Found);
      Next_And_Expect
        (Lazy_Restored_Buffer,
         Lazy_Buffer,
         Receipt_Sequence (Commit_Info),
         True,
         Key_Data,
         True,
         True,
         Key_Data,
         Lazy_Read_Failed,
         0,
         Bytes (""),
         Bytes (""),
         Invalid_State);
      Next_And_Expect
        (Lazy_Buffer,
         Lazy_Restored_Buffer,
         Receipt_Sequence (Commit_Info),
         False,
         Bytes ("ignored"),
         False,
         False,
         Bytes ("ignored"),
         Lazy_Read_Failed,
         0,
         Bytes (""),
         Bytes (""),
         Timed_Out,
         0.0);
      Next_And_Expect
        (Lazy_Restored_Buffer,
         Lazy_Buffer,
         Receipt_Sequence (Commit_Info),
         False,
         Bytes ("ignored"),
         False,
         False,
         Bytes ("ignored"),
         Lazy_Value_Found,
         Receipt_Sequence (Commit_Info),
         Key_Data,
         Value_Data,
         Success);
      Stop.Request;
      declare
         Disposition : Lazy_SST_Entry_Disposition;
         Sequence    : Sequence_Number;
         Item_Key    : Flyology.Bytes.Unbounded_Bytes;
         Value       : Flyology.Bytes.Unbounded_Bytes;
         Read_Result : Outcome_Code;
      begin
         Read_Lazy_SST_Next_Entry
           (Probe_Database_ID,
            Families (Families'First),
            Checkpoint_Run_ID,
            Receipt_Sequence (Commit_Info),
            Receipt_Sequence (Commit_Info),
            1,
            Interfaces.Unsigned_64 (Key_Data'Length + Value_Data'Length),
            Receipt_Sequence (Commit_Info),
            False,
            Bytes ("ignored"),
            False,
            False,
            Bytes ("ignored"),
            Lazy_Buffer,
            Test_Operation_Timeout,
            Cancelled_Work);
         Flyology.Operations.Wait_All (Composable_Set);
         Finish_Lazy_SST_Next_Entry
           (Cancelled_Work, Disposition, Sequence, Item_Key, Value, Read_Result, Lazy_Restored_Buffer);
         if Read_Result /= Cancelled
           or else Disposition /= Lazy_Read_Failed
           or else Sequence /= 0
           or else Flyology.Bytes.Length (Item_Key) /= 0
           or else Flyology.Bytes.Length (Value) /= 0
           or else not Flyology.Buffers.Has_Buffer (Lazy_Restored_Buffer)
           or else Flyology.Buffers.Tag (Lazy_Restored_Buffer) /= Lazy_Token_Tag
         then
            raise Program_Error with "lazy SST next-entry cancellation published data or lost its token";
         end if;
      end;
      --  Reusable operations retain their idle set slot after Finish. This
      --  focused fixture is done, so return that slot before later DB parents
      --  exercise the same bounded completion set.
      Flyology.Operations.Release (Lazy_Work);
      Flyology.Operations.Release (Cancelled_Work);
      Flyology.Buffers.Release (Lazy_Restored_Buffer);
   exception
      when others =>
         Flyology.Buffers.Release (Lazy_Buffer);
         Flyology.Buffers.Release (Lazy_Restored_Buffer);
         raise;
   end Test_Lazy_SST_Read;

   procedure Test_Lazy_Checkpoint_Read is
      Runs : constant Lazy_SST_Run_Array :=
        [(Run_ID                => Compaction_Run_ID,
          Lowest_Sequence       => First_Sequence,
          Highest_Sequence      => First_Sequence,
          Entry_Total           => 1,
          Logical_Payload_Bytes => Interfaces.Unsigned_64 (Key_Data'Length + Value_Data'Length)),
         (Run_ID                => Later_Run_ID,
          Lowest_Sequence       => Later_Sequence,
          Highest_Sequence      => Later_Sequence,
          Entry_Total           => 2,
          Logical_Payload_Bytes =>
            Interfaces.Unsigned_64
              (Key_Data'Length
               + Later_Value_Data'Length
               + Tombstone_Key_Data'Length
               + Tombstone_Value_Data'Length)),
         (Run_ID                => Third_Run_ID,
          Lowest_Sequence       => Third_Sequence,
          Highest_Sequence      => Third_Sequence,
          Entry_Total           => 2,
          Logical_Payload_Bytes =>
            Interfaces.Unsigned_64
              (Key_Data'Length + Third_Value_Data'Length + Tombstone_Key_Data'Length))];
      Invalid_Runs : constant Lazy_SST_Run_Array := [Runs (2), Runs (1)];

      procedure Read_And_Expect
        (Source               : in out Flyology.Buffers.Unique_Buffer;
         Destination          : in out Flyology.Buffers.Unique_Buffer;
         Key                  : Byte_Array;
         Snapshot             : Sequence_Number;
         Expected_Disposition : Lazy_SST_Entry_Disposition;
         Expected_Sequence    : Sequence_Number;
         Expected_Value       : Byte_Array;
         Expected_Result      : Outcome_Code)
      is
         Disposition : Lazy_SST_Entry_Disposition;
         Sequence    : Sequence_Number;
         Value       : Flyology.Bytes.Unbounded_Bytes;
         Read_Result : Outcome_Code;
      begin
         Read_Lazy_Checkpoint_Entry
           (Probe_Database_ID,
            Families (Families'First),
            Runs,
            Snapshot,
            Key,
            Source,
            Test_Operation_Timeout,
            Lazy_Checkpoint_Work);
         if Flyology.Buffers.Has_Buffer (Source) then
            raise Program_Error with "lazy checkpoint read did not move its scratch token";
         end if;
         Flyology.Operations.Wait_All (Lazy_Checkpoint_Set);
         Finish_Lazy_Checkpoint_Read
           (Lazy_Checkpoint_Work,
            Disposition,
            Sequence,
            Value,
            Read_Result,
            Destination);
         Expect (Read_Result, Expected_Result, "client-backed lazy checkpoint read failed");
         if Disposition /= Expected_Disposition
           or else Sequence /= Expected_Sequence
           or else not Same (Value, Expected_Value)
           or else not Flyology.Buffers.Has_Buffer (Destination)
           or else Flyology.Buffers.Tag (Destination) /= Lazy_Token_Tag
         then
            raise Program_Error
              with
                "lazy checkpoint read returned the wrong entry: disposition="
                & Lazy_SST_Entry_Disposition'Image (Disposition)
                & " sequence="
                & Sequence_Number'Image (Sequence)
                & " value_length="
                & Natural'Image (Flyology.Bytes.Length (Value))
                & " result="
                & Outcome_Code'Image (Read_Result);
         end if;
      end Read_And_Expect;
   begin
      Flyology.Buffers.Acquire (Lazy_Buffer);
      Flyology.Buffers.Set_Tag (Lazy_Buffer, Lazy_Token_Tag);
      declare
         Disposition : Lazy_SST_Entry_Disposition;
         Sequence    : Sequence_Number;
         Value       : Flyology.Bytes.Unbounded_Bytes;
         Read_Result : Outcome_Code;
      begin
         Read_Lazy_Checkpoint_Entry
           (Probe_Database_ID,
            Families (Families'First),
            Invalid_Runs,
            Later_Sequence,
            Key_Data,
            Lazy_Buffer,
            Test_Operation_Timeout,
            Lazy_Checkpoint_Work);
         Flyology.Operations.Wait_All (Lazy_Checkpoint_Set);
         Finish_Lazy_Checkpoint_Read
           (Lazy_Checkpoint_Work,
            Disposition,
            Sequence,
            Value,
            Read_Result,
            Lazy_Restored_Buffer);
         if Read_Result /= Invalid_State
           or else Disposition /= Lazy_Read_Failed
           or else Sequence /= 0
           or else Flyology.Bytes.Length (Value) /= 0
           or else not Flyology.Buffers.Has_Buffer (Lazy_Restored_Buffer)
           or else Flyology.Buffers.Tag (Lazy_Restored_Buffer) /= Lazy_Token_Tag
         then
            raise Program_Error with "lazy checkpoint read admitted an invalid run order";
         end if;
      end;
      Read_And_Expect
        (Lazy_Restored_Buffer,
         Lazy_Buffer,
         Key_Data,
         Third_Sequence,
         Lazy_Value_Found,
         Third_Sequence,
         Third_Value_Data,
         Success);
      Read_And_Expect
        (Lazy_Buffer,
         Lazy_Restored_Buffer,
         Key_Data,
         Later_Sequence,
         Lazy_Value_Found,
         Later_Sequence,
         Later_Value_Data,
         Success);
      Read_And_Expect
        (Lazy_Restored_Buffer,
         Lazy_Buffer,
         Key_Data,
         First_Sequence,
         Lazy_Value_Found,
         First_Sequence,
         Value_Data,
         Success);
      Read_And_Expect
        (Lazy_Buffer,
         Lazy_Restored_Buffer,
         Bytes ("z"),
         Third_Sequence,
         Lazy_Key_Absent,
         0,
         Bytes (""),
         Not_Found);
      --  Convert only the oldest immutable fixture run to the frozen v1 wire
      --  format. The selector must authenticate it whole at the same manifest
      --  descriptor while newer v2 runs retain their lazy range path.
      Convert_Test_Run_To_V1
        (Context, Compaction_Run_ID, Test_Operation_Timeout, Result);
      Expect (Result, Success, "client-backed v1 fallback fixture conversion failed");
      Read_And_Expect
        (Lazy_Restored_Buffer,
         Lazy_Buffer,
         Key_Data,
         First_Sequence,
         Lazy_Value_Found,
         First_Sequence,
         Value_Data,
         Success);
      Read_And_Expect
        (Lazy_Buffer,
         Lazy_Restored_Buffer,
         Bytes ("z"),
         First_Sequence,
         Lazy_Key_Absent,
         0,
         Bytes (""),
         Not_Found);
      declare
         V1_Work     :
           Lazy_SST_Read_Operation
             (Composable_Set'Access, Context'Access, Client'Access, Lazy_Pool'Access, null);
         Disposition : Lazy_SST_Entry_Disposition;
         Sequence    : Sequence_Number;
         Item_Key    : Flyology.Bytes.Unbounded_Bytes;
         Value       : Flyology.Bytes.Unbounded_Bytes;
         Read_Result : Outcome_Code;
      begin
         Read_Lazy_SST_Next_Entry
           (Probe_Database_ID,
            Families (Families'First),
            Compaction_Run_ID,
            First_Sequence,
            First_Sequence,
            1,
            Interfaces.Unsigned_64 (Key_Data'Length + Value_Data'Length),
            First_Sequence,
            False,
            Bytes ("ignored"),
            False,
            False,
            Bytes ("ignored"),
            Lazy_Restored_Buffer,
            Test_Operation_Timeout,
            V1_Work);
         Flyology.Operations.Wait_All (Composable_Set);
         Finish_Lazy_SST_Next_Entry
           (V1_Work, Disposition, Sequence, Item_Key, Value, Read_Result, Lazy_Buffer);
         if Read_Result /= Success
           or else Disposition /= Lazy_Value_Found
           or else Sequence /= First_Sequence
           or else not Same (Item_Key, Key_Data)
           or else not Same (Value, Value_Data)
           or else not Flyology.Buffers.Has_Buffer (Lazy_Buffer)
           or else Flyology.Buffers.Tag (Lazy_Buffer) /= Lazy_Token_Tag
         then
            raise Program_Error with "frozen v1 lazy next-entry fallback returned the wrong result";
         end if;
         Flyology.Operations.Release (V1_Work);
      end;
      Flyology.Operations.Release (Lazy_Checkpoint_Work);
      Flyology.Buffers.Release (Lazy_Buffer);
   exception
      when others =>
         Flyology.Buffers.Release (Lazy_Buffer);
         Flyology.Buffers.Release (Lazy_Restored_Buffer);
         raise;
   end Test_Lazy_Checkpoint_Read;
begin
   if Proxy_Enabled then
      declare
         Proxy_Port : Sockets.Port;
      begin
         Refresh_Proxy_Testing.Start (Upstream_Port, Test_Operation_Timeout, Proxy_Port);
         Origin := HTTP.Parse_Origin ("http://127.0.0.1:" & Decimal (Proxy_Port));
      end;
   end if;
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

   Flyology.Buffers.Acquire (Flush_Buffer);
   Flyology.Buffers.Set_Tag (Flush_Buffer, Flush_Token_Tag);

   --  Pre-request cancellation still follows Start/move/drain/typed Finish.
   --  The succeeding create on the same handle proves lifecycle rollback to
   --  Closed; exact tag restoration proves ownership, not pool substitution.
   declare
      Stop        : aliased Flyology.Cancellation.Token;
      Cancel_Work : Create_Operation
        (Composable_Set'Access,
         Created'Access,
         Context'Access,
         Client'Access,
         Flush_Pool'Access,
         Stop'Access);
   begin
      Stop.Request;
      Create
        (Probe_Database_ID,
         Root_Manifest_ID,
         Root_Transition_ID,
         Limits,
         Families,
         Flush_Buffer,
         Test_Operation_Timeout,
         Cancel_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Cancel_Work, Receipt, Result, Restored_Buffer);
      Flyology.Operations.Release (Cancel_Work);
      Expect (Result, Cancelled, "pre-requested composable create cancellation was lost");
      if Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "cancelled composable create did not restore its exact token";
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);
   end;

   --  A definite failure before HEAD provider entry leaves the immutable root
   --  confirmed and the attempted transition unadmitted. The same identities
   --  may therefore be resumed safely; the following lost-response attempt
   --  proves that no replacement identity or hidden replay is introduced.
   Context.Test_Control.Arm (Before_Head_Put, Definite_Failure, 1);
   Create
     (Created,
      Context'Access,
      Probe_Database_ID,
      Root_Manifest_ID,
      Root_Transition_ID,
      Limits,
      Families,
      Flush_Buffer,
      Test_Operation_Timeout,
      Receipt => Receipt,
      Result  => Result);
   Expect (Result, Storage_Failure, "definite pre-HEAD composable create failure was weakened");
   if Create_Receipt_Manifest_ID (Receipt) /= Root_Manifest_ID
     or else Create_Receipt_Transition_ID (Receipt) /= Zero_Identifier
     or else not Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else Flyology.Buffers.Tag (Flush_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "definite pre-HEAD create lost resumable receipt or exact token";
   end if;

   --  The client-bound synchronous form is a literal wait over the same
   --  operation. An already-expired caller deadline must restore both owned
   --  inputs without admitting the pending HEAD or changing its identity.
   Resolve_Create
     (Created,
      Context'Access,
      Receipt,
      Flush_Buffer,
      0.0,
      Result => Result);
   Expect (Result, Timed_Out, "buffer-owned create resolution ignored its absolute deadline");
   if Create_Receipt_Manifest_ID (Receipt) /= Root_Manifest_ID
     or else Create_Receipt_Transition_ID (Receipt) /= Zero_Identifier
     or else not Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else Flyology.Buffers.Tag (Flush_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "timed-out create resolution lost receipt authority or exact token";
   end if;

   --  Resolve owns the exact receipt and token through typed Finish. Its first
   --  use authenticates the already-confirmed immutable manifest, admits only
   --  the exact pending HEAD, then loses that response. Local recovery
   --  allocation failure cannot weaken possible admission or replay the PUT.
   declare
      Resolve_Work         : Create_Operation
        (Composable_Set'Access,
         Created'Access,
         Context'Access,
         Client'Access,
         Flush_Pool'Access,
         null);
      Batch_Puts_Before    : Natural;
      Manifest_Puts_Before : Natural;
      Head_Puts_Before     : Natural;
      Batch_Puts_After     : Natural;
      Manifest_Puts_After  : Natural;
      Head_Puts_After      : Natural;
   begin
      Context.Test_Control.Publication_Counts
        (Batch_Puts_Before, Manifest_Puts_Before, Head_Puts_Before);
      Context.Test_Control.Arm (After_Head_Put, Unknown_After_Entry, 1);
      Set_Test_Allocation_Fault (Recovery_Driver_State_Allocation);
      Resolve_Create (Receipt, Flush_Buffer, Test_Operation_Timeout, Resolve_Work);
      if Create_Receipt_Manifest_ID (Receipt) /= Zero_Identifier
        or else Flyology.Buffers.Has_Buffer (Flush_Buffer)
      then
         raise Program_Error with "composable create resolution retained caller ownership";
      end if;
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Resolve_Work, Receipt, Result, Restored_Buffer);
      Flyology.Operations.Release (Resolve_Work);
      Expect (Result, Outcome_Unknown, "ambiguous resolution was weakened by recovery capacity");
      if Create_Receipt_Manifest_ID (Receipt) /= Root_Manifest_ID
        or else Create_Receipt_Transition_ID (Receipt) /= Root_Transition_ID
        or else Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "ambiguous resolution lost receipt authority or exact token";
      end if;
      Context.Test_Control.Publication_Counts
        (Batch_Puts_After, Manifest_Puts_After, Head_Puts_After);
      if Batch_Puts_After /= Batch_Puts_Before
        or else Manifest_Puts_After /= Manifest_Puts_Before
        or else Head_Puts_After /= Head_Puts_Before + 1
      then
         raise Program_Error
           with
             "create resolution mutation counts changed: before="
             & Natural'Image (Batch_Puts_Before)
             & "/"
             & Natural'Image (Manifest_Puts_Before)
             & "/"
             & Natural'Image (Head_Puts_Before)
             & " after="
             & Natural'Image (Batch_Puts_After)
             & "/"
             & Natural'Image (Manifest_Puts_After)
             & "/"
             & Natural'Image (Head_Puts_After);
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);

      --  Restarting the consumed operation with the unknown receipt is
      --  strictly read-only: manifest authentication and shared recovery find
      --  the already-published HEAD and install the exact root.
      Resolve_Create (Receipt, Flush_Buffer, Test_Operation_Timeout, Resolve_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Resolve_Work, Receipt, Result, Restored_Buffer);
      Flyology.Operations.Release (Resolve_Work);
      Expect (Result, Success, "client-backed composable create resolution failed");
      if Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "restarted create resolution lost its exact token";
      end if;
      Context.Test_Control.Publication_Counts
        (Batch_Puts_After, Manifest_Puts_After, Head_Puts_After);
      if Batch_Puts_After /= Batch_Puts_Before
        or else Manifest_Puts_After /= Manifest_Puts_Before
        or else Head_Puts_After /= Head_Puts_Before + 1
      then
         raise Program_Error with "unknown create resolution replayed a mutation";
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);

      --  A conclusive receipt has no remaining activation opportunity. The
      --  provider-owned path retains the established direct resolver result,
      --  restores both owners, and performs no read or mutation.
      Resolve_Create (Receipt, Flush_Buffer, Test_Operation_Timeout, Resolve_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Resolve_Work, Receipt, Result, Restored_Buffer);
      Flyology.Operations.Release (Resolve_Work);
      Expect (Result, Local_Activation_Failed, "confirmed create resolution changed normalization");
      if Create_Receipt_Manifest_ID (Receipt) /= Root_Manifest_ID
        or else Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "confirmed create resolution lost receipt or exact token";
      end if;
      Context.Test_Control.Publication_Counts
        (Batch_Puts_After, Manifest_Puts_After, Head_Puts_After);
      if Batch_Puts_After /= Batch_Puts_Before
        or else Manifest_Puts_After /= Manifest_Puts_Before
        or else Head_Puts_After /= Head_Puts_Before + 1
      then
         raise Program_Error with "confirmed create resolution touched the provider";
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);
   end;

   --  Reusing the exact root against an existing HEAD exercises immutable
   --  comparison followed by the nested owner-driven recovery traversal. A
   --  matching complete root opens a second handle without replaying either
   --  conditional mutation or weakening publication certainty.
   declare
      Existing      : aliased Database;
      Existing_Work : Create_Operation
        (Composable_Set'Access,
         Existing'Access,
         Context'Access,
         Client'Access,
         Flush_Pool'Access,
         null);
   begin
      --  Failure before the nested recovery owner exists must leave the open
      --  admission with Create, whose terminal cleanup returns the lifecycle
      --  to Closed. Reusing the same operation immediately is the oracle.
      Set_Test_Allocation_Fault (Recovery_Driver_State_Allocation);
      Create
        (Probe_Database_ID,
         Root_Manifest_ID,
         Root_Transition_ID,
         Limits,
         Families,
         Flush_Buffer,
         Test_Operation_Timeout,
         Existing_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Existing_Work, Receipt, Result, Restored_Buffer);
      Flyology.Operations.Release (Existing_Work);
      Expect (Result, Capacity_Exceeded, "nested create recovery allocation failure was weakened");
      if Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "nested recovery allocation failure lost its exact token";
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);

      Create
        (Probe_Database_ID,
         Root_Manifest_ID,
         Root_Transition_ID,
         Limits,
         Families,
         Flush_Buffer,
         Test_Operation_Timeout,
         Existing_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Existing_Work, Receipt, Result, Restored_Buffer);
      Flyology.Operations.Release (Existing_Work);
      Expect (Result, Success, "existing-root composable create reconciliation failed");
      if Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "reconciled composable create lost its exact token";
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);
      Close (Existing, Close_Result);
      Expect (Close_Result, Success, "reconciled composable create close failed");
   end;

   --  A complete existing graph under a different database identity is a
   --  conclusive collision, not corrupt data or unknown admission. Reusing
   --  the consumed operation for the matching root then proves lifecycle and
   --  operation ownership were both returned exactly.
   declare
      Collision      : aliased Database;
      Collision_Work : Create_Operation
        (Composable_Set'Access,
         Collision'Access,
         Context'Access,
         Client'Access,
         Flush_Pool'Access,
         null);
   begin
      Create
        (Conflicting_Database_ID,
         Conflicting_Manifest_ID,
         Conflicting_Transition_ID,
         Limits,
         Families,
         Flush_Buffer,
         Test_Operation_Timeout,
         Collision_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Collision_Work, Receipt, Result, Restored_Buffer);
      Flyology.Operations.Release (Collision_Work);
      Expect (Result, Already_Exists, "different-root composable create was not a typed collision");
      if Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "colliding composable create lost its exact token";
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);

      Create
        (Probe_Database_ID,
         Root_Manifest_ID,
         Root_Transition_ID,
         Limits,
         Families,
         Flush_Buffer,
         Test_Operation_Timeout,
         Collision_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Collision_Work, Receipt, Result, Restored_Buffer);
      Flyology.Operations.Release (Collision_Work);
      Expect (Result, Success, "composable create did not restart after a typed collision");
      if Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "restarted composable create lost its exact token";
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);
      Close (Collision, Close_Result);
      Expect (Close_Result, Success, "restarted composable create close failed");
   end;
   Observe_L0_Checkpoint_Requirement (Created, Requirement, Result);
   Expect (Result, Success, "client-backed initial checkpoint query failed");
   if Checkpoint_Requirement_Action (Requirement) /= No_L0_Checkpoint_Work
     or else Checkpoint_Requirement_Family_Total (Requirement) /= 0
   then
      raise Program_Error with "client-backed fresh database reported checkpoint work";
   end if;

   Begin_Transaction (Created, Transaction_ID, Txn, Result);
   Expect (Result, Success, "client-backed transaction begin failed");
   Open_Column_Family (Created, 1, Family, Result);
   Expect (Result, Success, "client-backed family open failed");
   Put (Created, Txn, Family, Key_Data, Value_Data, Result);
   Expect (Result, Success, "client-backed put failed");
   Commit (Created, Txn, Test_Operation_Timeout, Receipt => Commit_Info, Result => Result);
   Expect (Result, Success, "client-backed commit failed");
   First_Sequence := Receipt_Sequence (Commit_Info);
   --  Before the first checkpoint, the public state machine resolves the
   --  committed suffix without starting Object Storage I/O.
   Test_Public_Get (Suffix_Get_Reader_ID, Value_Data, False);
   Observe_L0_Checkpoint_Requirement (Created, Requirement, Result);
   Expect (Result, Success, "client-backed dirty checkpoint query failed");
   if Checkpoint_Requirement_Action (Requirement) /= Additive_Flush_Required
     or else Checkpoint_Requirement_Family_Total (Requirement) /= 1
     or else Checkpoint_Requirement_Family (Requirement, 1) /= 1
   then
      raise Program_Error with "client-backed initial commit did not require additive Flush";
   end if;

   --  Completion-slot rejection is required to precede token movement. The
   --  timer occupies the sole test slot; the three marker bytes and stable tag
   --  make byte/tag/length rollback observable without provider entry.
   declare
      Rollback_Set    : aliased Flyology.Operations.Completion_Set (1);
      Rollback_Pool   : aliased Flyology.Buffers.Pool (Block_Size => 3, Capacity => 1);
      Rollback_Buffer : Flyology.Buffers.Unique_Buffer (Rollback_Pool'Access);
      Rollback_Work   :
        Flush_Operation
          (Rollback_Set'Access, Created'Access, Context'Access, Client'Access, Rollback_Pool'Access, null);
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
      Tiny_Pool    : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
      Tiny_Buffer  : Flyology.Buffers.Unique_Buffer (Tiny_Pool'Access);
      Tiny_Work    :
        Flush_Operation
          (Composable_Set'Access, Created'Access, Context'Access, Client'Access, Tiny_Pool'Access, null);
      Tiny_Receipt : Flush_Receipt;
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
      Child_Pool    :
        aliased Flyology.Buffers.Pool
                  (Block_Size => Positive (Limits.Maximum_Live_State_Bytes), Capacity => 1);
      Child_Buffer  : Flyology.Buffers.Unique_Buffer (Child_Pool'Access);
      Child_Work    :
        Flush_Operation
          (Child_Set'Access, Created'Access, Context'Access, Client'Access, Child_Pool'Access, null);
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
         Abandon_Work   :
           Flush_Operation
             (Abandon_Set'Access, Created'Access, Context'Access, Client'Access, Abandon_Pool'Access, null);
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

   --  Publication and reconciliation may overwrite payload bytes and length,
   --  but every owner-driven operation retains the exact caller metadata tag.

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
   Required_L0_Checkpoint_Action (Created, Action, Result);
   Expect (Result, Success, "client-backed clean checkpoint query failed");
   if Action /= No_L0_Checkpoint_Work then
      raise Program_Error with "client-backed successful Flush left checkpoint work";
   end if;
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

   --  The actual checkpoint just published an SST-v2 run. Read its exact
   --  generation through Head, header, index, and one selected frame without
   --  retaining the whole object; then reuse the same operation for absence.
   Test_Lazy_SST_Read;

   --  Capture one caller-designated read-only handle at the first checkpoint.
   --  It remains deliberately stale while the writer appends families, Flushes,
   --  and compacts; the final public refresh must install the complete newer
   --  graph without polling, retrying, or replaying a mutation.
   Open
     (Replica,
      Context'Access,
      Probe_Database_ID,
      Restored_Buffer,
      Test_Operation_Timeout,
      Result => Result);
   Expect (Result, Success, "client-backed replica open failed");
   if not Flyology.Buffers.Has_Buffer (Restored_Buffer)
     or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "synchronous owner-driven open did not restore its exact token";
   end if;

   --  Family-registry publication must include the appended name/header in its
   --  caller-selected scratch requirement. A one-byte token is rejected before
   --  provider entry, restored exactly, and leaves the identities reusable.
   declare
      Tiny_Pool   : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
      Tiny_Buffer : Flyology.Buffers.Unique_Buffer (Tiny_Pool'Access);
      Tiny_Work   :
        Flush_Operation
          (Composable_Set'Access, Created'Access, Context'Access, Client'Access, Tiny_Pool'Access, null);
      Tiny_Family : Column_Family_Receipt;
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
   Resolve_Add_Column_Family (Created, Family_Info, Test_Operation_Timeout, Result => Result);
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

   --  Public Start_Compaction selects only the already-frozen complete-run
   --  algorithm. It reuses the Flush operation owner stack, exact token move,
   --  typed Finish, certainty mapping, and one deadline; it grants no
   --  automatic trigger, run-selection, or garbage-collection policy. Losing the
   --  run response after entry requires exact same-identity whole-Get
   --  reconciliation before the original operation can continue.
   Context.Test_Control.Arm (After_Run_Put, Unknown_After_Entry, 1);
   Start_Compaction
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
     or else Flush_Receipt_Run_Total (Flush_Info) /= Compaction_Runs'Length
     or else Flush_Receipt_Run (Flush_Info, 2) /= Compaction_Runs (2)
     or else Flush_Receipt_Run (Flush_Info, 3) /= Compaction_Runs (3)
   then
      raise Program_Error with "client-backed compaction receipt lost replacement authority";
   end if;

   --  The next commit writes both families; its family-1 value and a final
   --  family-1 commit become newer current runs. Public exact-three-run
   --  compaction selects all three consecutive root-family descriptors while
   --  retaining the audit-family run and later committed suffix.
   Begin_Transaction (Created, Later_Transaction_ID, Txn, Result);
   Expect (Result, Success, "later client-backed transaction begin failed");
   Put (Created, Txn, Family, Key_Data, Later_Value_Data, Result);
   Expect (Result, Success, "later client-backed put failed");
   Put (Created, Txn, Family, Tombstone_Key_Data, Tombstone_Value_Data, Result);
   Expect (Result, Success, "later client-backed tombstone fixture put failed");
   Put (Created, Txn, Audit_Family, Audit_Key_Data, Audit_Value_Data, Result);
   Expect (Result, Success, "appended-family remote put failed");
   Commit (Created, Txn, Test_Operation_Timeout, Receipt => Commit_Info, Result => Result);
   Expect (Result, Success, "later client-backed commit failed");
   Later_Sequence := Receipt_Sequence (Commit_Info);
   Observe_L0_Checkpoint_Requirement (Created, Requirement, Result);
   Expect (Result, Success, "later client-backed checkpoint query failed");
   if Checkpoint_Requirement_Action (Requirement) /= Additive_Flush_Required
     or else Checkpoint_Requirement_Family_Total (Requirement) /= 2
     or else Checkpoint_Requirement_Family (Requirement, 1) /= 1
     or else Checkpoint_Requirement_Family (Requirement, 2) /= 2
   then
      raise Program_Error with "later client-backed commit did not require additive Flush";
   end if;
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
   Delete (Created, Txn, Family, Tombstone_Key_Data, Result);
   Expect (Result, Success, "third client-backed tombstone fixture delete failed");
   Commit (Created, Txn, Test_Operation_Timeout, Receipt => Commit_Info, Result => Result);
   Expect (Result, Success, "third client-backed commit failed");
   Third_Sequence := Receipt_Sequence (Commit_Info);
   Observe_L0_Checkpoint_Requirement (Created, Requirement, Result);
   Expect (Result, Success, "third client-backed checkpoint query failed");
   if Checkpoint_Requirement_Action (Requirement) /= Additive_Flush_Required
     or else Checkpoint_Requirement_Family_Total (Requirement) /= 1
     or else Checkpoint_Requirement_Family (Requirement, 1) /= 1
   then
      raise Program_Error with "third client-backed commit did not require additive Flush";
   end if;
   Flush
     (Created,
      Third_Runs,
      Third_Manifest_ID,
      Third_Transition_ID,
      Test_Operation_Timeout,
      Receipt => Flush_Info,
      Result  => Result);
   Expect (Result, Success, "third client-backed additive Flush failed");

   --  After the third checkpoint, the same public state machine falls through
   --  to the authenticated immutable run selector.
   Test_Public_Get (Checkpoint_Get_Reader_ID, Third_Value_Data, True);
   Test_Public_Scan;

   --  The exact current manifest order is oldest to newest. The private
   --  selector traverses it newest first at one fixed snapshot, skipping
   --  future runs without I/O and falling through only on authenticated
   --  absence. It performs no retry and retains no caller descriptor borrow.
   Test_Lazy_Checkpoint_Read;

   --  A definite selected-read failure precedes publication, restores the
   --  exact token, and leaves every identity reusable. The immediate retry of
   --  the same exact three-run selection is explicit test authority, not an
   --  automatic DB retry.
   Context.Test_Control.Arm (Before_Get, Definite_Failure, 1);
   Start_Compaction
     (Flush_Work,
      Compaction_Run_ID,
      Later_Run_ID,
      Third_Run_ID,
      Merged_Run_ID,
      Merged_Manifest_ID,
      Merged_Transition_ID,
      Flush_Buffer,
      Test_Operation_Timeout);
   Flyology.Operations.Wait_All (Composable_Set);
   Finish (Flush_Work, Flush_Info, Result, Flush_Buffer);
   Expect (Result, Storage_Failure, "pre-read three-run merge failure was ambiguous");
   if not Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else Flyology.Buffers.Tag (Flush_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "pre-read three-run merge did not restore its exact token";
   end if;
   --  Losing the output PUT response after possible admission is reconciled
   --  by an exact same-generation whole Get inside the original operation.
   --  The caller does not replay the merge or select a new identity.
   Context.Test_Control.Arm (After_Run_Put, Unknown_After_Entry, 1);
   Start_Compaction
     (Flush_Work,
      Compaction_Run_ID,
      Later_Run_ID,
      Third_Run_ID,
      Merged_Run_ID,
      Merged_Manifest_ID,
      Merged_Transition_ID,
      Flush_Buffer,
      Test_Operation_Timeout);
   Flyology.Operations.Wait_All (Composable_Set);
   Finish (Flush_Work, Flush_Info, Result, Flush_Buffer);
   Expect (Result, Success, "client-backed composable three-run merge failed");
   if not Flush_Info.Merges_Adjacent_Runs
     or else not Flush_Info.Merges_Three_Runs
     or else Flush_Receipt_Run_Total (Flush_Info) /= 1
     or else Flush_Receipt_Run (Flush_Info, 1) /= Configure_Checkpoint_Run (1, Merged_Run_ID)
     or else Flush_Receipt_Manifest_ID (Flush_Info) /= Merged_Manifest_ID
     or else Flush_Receipt_Transition_ID (Flush_Info) /= Merged_Transition_ID
   then
      raise Program_Error with "client-backed three-run merge receipt lost exact authority";
   end if;

   --  The public blocking Compact is a literal wait over Start_Compaction.
   --  Losing its HEAD response remains unknown until Resolve_Flush observes
   --  the exact final replacement; neither call retries or changes identity.
   Context.Test_Control.Arm (After_Head_Put, Unknown_After_Entry, 1);
   Compact
     (Created,
      Final_Compaction_Runs,
      Final_Manifest_ID,
      Final_Transition_ID,
      Test_Operation_Timeout,
      Token   => null,
      Receipt => Flush_Info,
      Result  => Result);
   Expect (Result, Outcome_Unknown, "blocking compaction lost HEAD uncertainty");
   if not Flush_Info.Replaces_Current_Runs
     or else Flush_Receipt_Run_Total (Flush_Info) /= Final_Compaction_Runs'Length
     or else Flush_Receipt_Manifest_ID (Flush_Info) /= Final_Manifest_ID
     or else Flush_Receipt_Transition_ID (Flush_Info) /= Final_Transition_ID
   then
      raise Program_Error with "blocking compaction receipt lost exact authority";
   end if;
   Resolve_Flush (Created, Flush_Info, Test_Operation_Timeout, Result => Result);
   Expect (Result, Success, "blocking compaction exact resolution failed");

   declare
      Replica_Family : Column_Family;
   begin
      Open_Column_Family (Replica, 1, Replica_Family, Result);
      Expect (Result, Success, "stale replica family lookup failed");
      Begin_Transaction (Replica, Replica_Initial_Reader_ID, Reader, Result);
      Expect (Result, Success, "stale replica reader begin failed");
      Get (Replica, Reader, Replica_Family, Key_Data, Data, Result);
      Expect (Result, Success, "stale replica read failed");
      if not Same (Data, Value_Data) then
         raise Program_Error with "replica advanced before its caller-triggered refresh";
      end if;
      Rollback (Reader, Result);
      Expect (Result, Success, "stale replica reader rollback failed");

      --  Refresh performs its own transaction around completion-slot and
      --  lifecycle admission. A busy one-slot set must reject before moving
      --  the exact byte/tag/length token or changing replica lifecycle mode.
      declare
         Rollback_Set    : aliased Flyology.Operations.Completion_Set (1);
         Marker          : constant Ada.Streams.Stream_Element_Array := [16#A5#, 16#5A#, 16#C3#];
         Rollback_Pool   :
           aliased Flyology.Buffers.Pool (Block_Size => Positive (Marker'Length), Capacity => 1);
         Rollback_Buffer : Flyology.Buffers.Unique_Buffer (Rollback_Pool'Access);
         Rollback_Work   :
           Refresh_Operation
             (Rollback_Set'Access, Replica'Access, Context'Access, Client'Access, Rollback_Pool'Access, null);
         Busy            : Timers.Timer_Operation :=
           Timers.Sleep_For (Rollback_Set'Access, Test_Operation_Timeout);
         Rejected        : Boolean := False;
      begin
         Flyology.Buffers.Acquire (Rollback_Buffer);
         Flyology.Buffers.Copy_From (Rollback_Buffer, Marker);
         Flyology.Buffers.Set_Tag (Rollback_Buffer, Flush_Token_Tag);
         begin
            Refresh_Replica (Rollback_Buffer, Test_Operation_Timeout, Rollback_Work);
         exception
            when Flyology.Operations.Capacity_Error =>
               Rejected := True;
         end;
         if not Rejected
           or else not Flyology.Buffers.Has_Buffer (Rollback_Buffer)
           or else Flyology.Buffers.Length (Rollback_Buffer) /= Marker'Length
           or else Flyology.Buffers.Tag (Rollback_Buffer) /= Flush_Token_Tag
           or else not Same (Rollback_Buffer, Marker)
         then
            raise Program_Error with "composable refresh Start did not roll back its exact token";
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

      --  The caller-selected scratch block is the only response-capacity
      --  authority. An undersized token is rejected without partial install,
      --  and typed Finish still restores that exact token.
      declare
         Tiny_Pool   : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
         Tiny_Buffer : Flyology.Buffers.Unique_Buffer (Tiny_Pool'Access);
         Tiny_Work   :
           Refresh_Operation
             (Composable_Set'Access, Replica'Access, Context'Access, Client'Access, Tiny_Pool'Access, null);
      begin
         Flyology.Buffers.Acquire (Tiny_Buffer);
         Refresh_Replica (Tiny_Buffer, Test_Operation_Timeout, Tiny_Work);
         Flyology.Operations.Wait_All (Composable_Set);
         Finish (Tiny_Work, Result, Tiny_Buffer);
         Expect (Result, Capacity_Exceeded, "undersized composable refresh was not rejected");
         if not Flyology.Buffers.Has_Buffer (Tiny_Buffer) then
            raise Program_Error with "undersized composable refresh lost its token";
         end if;
         Flyology.Buffers.Release (Tiny_Buffer);
      end;

      --  A cancellation recorded before Start is terminal but still follows
      --  the normal move/drain/Finish path. The following successful refresh
      --  proves cancellation returned the lifecycle to Opened.
      declare
         Stop        : aliased Flyology.Cancellation.Token;
         Cancel_Work :
           Refresh_Operation
             (Composable_Set'Access,
              Replica'Access,
              Context'Access,
              Client'Access,
              Flush_Pool'Access,
              Stop'Access);
      begin
         Stop.Request;
         Refresh_Replica (Flush_Buffer, Test_Operation_Timeout, Cancel_Work);
         Flyology.Operations.Wait_All (Composable_Set);
         Finish (Cancel_Work, Result, Restored_Buffer);
         Expect (Result, Cancelled, "pre-requested composable refresh cancellation was lost");
         if Flyology.Buffers.Has_Buffer (Flush_Buffer)
           or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
           or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
         then
            raise Program_Error with "cancelled composable refresh did not restore its exact token";
         end if;
         Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);
      end;

      --  Scope abandonment is the fallback ownership authority. A terminal
      --  unconsumed refresh releases its operation-owned token to the pool;
      --  it never writes through the finalized initiating handle.
      declare
         --  Pre-requested cancellation terminalizes in the DB parent, so one
         --  slot is the exact abandonment fixture geometry.
         Abandon_Set  : aliased Flyology.Operations.Completion_Set (1);
         --  No provider body is read; one byte is the pool type's minimum and
         --  makes only token ownership observable.
         Abandon_Pool : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
         Stop         : aliased Flyology.Cancellation.Token;
      begin
         Stop.Request;
         declare
            Abandon_Buffer : Flyology.Buffers.Unique_Buffer (Abandon_Pool'Access);
            Abandon_Work   :
              Refresh_Operation
                (Abandon_Set'Access,
                 Replica'Access,
                 Context'Access,
                 Client'Access,
                 Abandon_Pool'Access,
                 Stop'Access);
         begin
            Flyology.Buffers.Acquire (Abandon_Buffer);
            Refresh_Replica (Abandon_Buffer, Test_Operation_Timeout, Abandon_Work);
            Flyology.Operations.Wait_All (Abandon_Set);
            if Flyology.Buffers.Has_Buffer (Abandon_Buffer) then
               raise Program_Error with "abandoned composable refresh never acquired token ownership";
            end if;
         end;
         declare
            Snapshot : constant Flyology.Buffers.Pool_Snapshot := Flyology.Buffers.Current (Abandon_Pool);
         begin
            if Snapshot.Available /= 1 or else Snapshot.Outstanding /= 0 then
               raise Program_Error with "abandoned composable refresh did not release its token";
            end if;
         end;
      end;

      if Proxy_Enabled then
         declare
            function Phase_Name (Phase : Refresh_Proxy_Testing.Refresh_Request_Phase) return String
            is (case Phase is
                  when Refresh_Proxy_Testing.Whole_Get_Request => "whole Get",
                  when Refresh_Proxy_Testing.Head_Request      => "HeadObject",
                  when Refresh_Proxy_Testing.Range_Get_Request => "range Get");

            procedure Check_Restored_Token (Context : String) is
            begin
               if Flyology.Buffers.Has_Buffer (Flush_Buffer)
                 or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
                 or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
               then
                  raise Program_Error with Context & " did not restore its exact token";
               end if;
               Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);
            end Check_Restored_Token;

            procedure Require_Blocked_Cancellation (Phase : Refresh_Proxy_Testing.Refresh_Request_Phase) is
               Stop : aliased Flyology.Cancellation.Token;
               Work :
                 Refresh_Operation
                   (Composable_Set'Access,
                    Replica'Access,
                    Context'Access,
                    Client'Access,
                    Flush_Pool'Access,
                    Stop'Access);

               task Cancel_When_Blocked is
                  pragma Task_Info (Flyology.Native_Task);
               end Cancel_When_Blocked;

               task body Cancel_When_Blocked is
               begin
                  Refresh_Proxy_Testing.Wait_Blocked (Phase, Test_Operation_Timeout);
                  Stop.Request;
               end Cancel_When_Blocked;
            begin
               Refresh_Proxy_Testing.Arm (Phase);
               Refresh_Replica (Flush_Buffer, Test_Operation_Timeout, Work);
               Flyology.Operations.Wait_All (Composable_Set);
               Finish (Work, Result, Restored_Buffer);
               if Result /= Cancelled then
                  Refresh_Proxy_Testing.Release_Blocked;
                  raise Program_Error
                    with
                      "blocked "
                      & Phase_Name (Phase)
                      & " cancellation completed as "
                      & Outcome_Code'Image (Result);
               end if;
               Refresh_Proxy_Testing.Wait_Blocked (Phase, Test_Operation_Timeout);
               Refresh_Proxy_Testing.Release_Blocked;
               Check_Restored_Token ("blocked " & Phase_Name (Phase) & " cancellation");
            exception
               when others =>
                  Refresh_Proxy_Testing.Release_Blocked;
                  raise;
            end Require_Blocked_Cancellation;

            procedure Require_Blocked_Deadline (Phase : Refresh_Proxy_Testing.Refresh_Request_Phase) is
               Work :
                 Refresh_Operation
                   (Composable_Set'Access,
                    Replica'Access,
                    Context'Access,
                    Client'Access,
                    Flush_Pool'Access,
                    null);
            begin
               Refresh_Proxy_Testing.Arm (Phase);
               Refresh_Replica (Flush_Buffer, Blocked_Deadline_Timeout, Work);
               Flyology.Operations.Wait_All (Composable_Set);
               Finish (Work, Result, Restored_Buffer);
               if Result /= Timed_Out then
                  Refresh_Proxy_Testing.Release_Blocked;
                  raise Program_Error
                    with
                      "blocked "
                      & Phase_Name (Phase)
                      & " deadline completed as "
                      & Outcome_Code'Image (Result);
               end if;
               Refresh_Proxy_Testing.Wait_Blocked (Phase, Test_Operation_Timeout);
               Refresh_Proxy_Testing.Release_Blocked;
               Check_Restored_Token ("blocked " & Phase_Name (Phase) & " deadline");
            exception
               when others =>
                  Refresh_Proxy_Testing.Release_Blocked;
                  raise;
            end Require_Blocked_Deadline;
         begin
            --  Each request is held after it reaches the TCP peer. Cancellation
            --  and the one absolute refresh deadline must terminate the parent,
            --  drain the exact provider child, restore the moved token, and
            --  leave the stale replica open without installing partial state.
            for Phase in Refresh_Proxy_Testing.Refresh_Request_Phase loop
               Require_Blocked_Cancellation (Phase);
               Require_Blocked_Deadline (Phase);
            end loop;

            Open_Column_Family (Replica, 1, Replica_Family, Result);
            Expect (Result, Success, "cancelled refresh family lookup failed");
            Begin_Transaction (Replica, Replica_Initial_Reader_ID, Reader, Result);
            Expect (Result, Success, "cancelled refresh reader begin failed");
            Get (Replica, Reader, Replica_Family, Key_Data, Data, Result);
            Expect (Result, Success, "cancelled refresh stale read failed");
            if not Same (Data, Value_Data) then
               raise Program_Error with "cancelled refresh installed partial remote state";
            end if;
            Rollback (Reader, Result);
            Expect (Result, Success, "cancelled refresh reader rollback failed");
         end;
      end if;

      --  The caller-composable path moves the exact tagged scratch token and
      --  restores it through an arbitrary vacant same-pool handle. Its first
      --  run installs the newer graph; restarting the consumed operation then
      --  observes the same authoritative head as a monotonic no-op.
      Refresh_Replica (Flush_Buffer, Test_Operation_Timeout, Refresh_Work);
      if Flyology.Buffers.Has_Buffer (Flush_Buffer) then
         raise Program_Error with "composable refresh did not acquire its scratch token";
      end if;
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Refresh_Work, Result, Restored_Buffer);
      Expect (Result, Success, "client-backed composable replica refresh failed");
      if Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "composable refresh did not restore its exact token";
      end if;

      Refresh_Replica (Restored_Buffer, Test_Operation_Timeout, Refresh_Work);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Refresh_Work, Result, Flush_Buffer);
      Expect (Result, Success, "restarted composable replica refresh failed");
      if Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else Flyology.Buffers.Tag (Flush_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "restarted composable refresh lost its exact token";
      end if;
      Open_Column_Family (Replica, 1, Replica_Family, Result);
      Expect (Result, Success, "refreshed replica family lookup failed");
      Begin_Transaction (Replica, Replica_Refreshed_Reader_ID, Reader, Result);
      Expect (Result, Success, "refreshed replica reader begin failed");
      Get (Replica, Reader, Replica_Family, Key_Data, Data, Result);
      Expect (Result, Success, "refreshed replica read failed");
      if not Same (Data, Third_Value_Data) then
         raise Program_Error with "replica refresh installed the wrong authoritative bytes";
      end if;
      Rollback (Reader, Result);
      Expect (Result, Success, "refreshed replica reader rollback failed");
   end;

   Close (Created, Close_Result);
   Expect (Close_Result, Success, "client-backed close failed");
   Close (Replica, Close_Result);
   Expect (Close_Result, Success, "client-backed replica close failed");

   --  Cancellation recorded before Start still follows the move/drain/Finish
   --  path. The later successful open on the same Database proves cancellation
   --  returned its lifecycle to Closed without installing a partial engine.
   declare
      Stop        : aliased Flyology.Cancellation.Token;
      Cancel_Open : Open_Operation
        (Composable_Set'Access,
         Reopened'Access,
         Context'Access,
         Client'Access,
         Flush_Pool'Access,
         Stop'Access);
   begin
      Stop.Request;
      Open (Probe_Database_ID, Flush_Buffer, Test_Operation_Timeout, Cancel_Open);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Cancel_Open, Result, Restored_Buffer);
      Flyology.Operations.Release (Cancel_Open);
      Expect (Result, Cancelled, "pre-requested composable open cancellation was lost");
      if Flyology.Buffers.Has_Buffer (Flush_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
        or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
      then
         raise Program_Error with "cancelled composable open did not restore its exact token";
      end if;
      Flyology.Buffers.Move (Restored_Buffer, Flush_Buffer);
   end;

   --  Scope abandonment is the fallback ownership authority. A terminal
   --  unconsumed open returns its operation-owned token to the pool and leaves
   --  the database Closed for the later successful open.
   declare
      Abandon_Set  : aliased Flyology.Operations.Completion_Set (1);
      Abandon_Pool : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
      Stop         : aliased Flyology.Cancellation.Token;
   begin
      Stop.Request;
      declare
         Abandon_Buffer : Flyology.Buffers.Unique_Buffer (Abandon_Pool'Access);
         Abandon_Open   : Open_Operation
           (Abandon_Set'Access,
            Reopened'Access,
            Context'Access,
            Client'Access,
            Abandon_Pool'Access,
            Stop'Access);
      begin
         Flyology.Buffers.Acquire (Abandon_Buffer);
         Open (Probe_Database_ID, Abandon_Buffer, Test_Operation_Timeout, Abandon_Open);
         Flyology.Operations.Wait_All (Abandon_Set);
         if Flyology.Buffers.Has_Buffer (Abandon_Buffer) then
            raise Program_Error with "abandoned composable open did not retain its token";
         end if;
      end;
      declare
         Snapshot : constant Flyology.Buffers.Pool_Snapshot := Flyology.Buffers.Current (Abandon_Pool);
      begin
         if Snapshot.Available /= 1 or else Snapshot.Outstanding /= 0 then
            raise Program_Error with "abandoned composable open did not release its token";
         end if;
      end;
   end;

   --  A caller token smaller than the first recovery object fails as bounded
   --  backpressure, restores its exact token, and aborts lifecycle admission.
   --  The following full-capacity restart on the same Database proves the
   --  failed operation left no partial engine or stuck Opening state.
   declare
      Tiny_Pool     : aliased Flyology.Buffers.Pool (Block_Size => 1, Capacity => 1);
      Tiny_Buffer   : Flyology.Buffers.Unique_Buffer (Tiny_Pool'Access);
      Tiny_Restored : Flyology.Buffers.Unique_Buffer (Tiny_Pool'Access);
      Tiny_Tag      : constant Interfaces.Unsigned_64 := 16#0E3A#;
      Tiny_Open     : Open_Operation
        (Composable_Set'Access,
         Reopened'Access,
         Context'Access,
         Client'Access,
         Tiny_Pool'Access,
         null);
   begin
      Flyology.Buffers.Acquire (Tiny_Buffer);
      Flyology.Buffers.Set_Tag (Tiny_Buffer, Tiny_Tag);
      Open (Probe_Database_ID, Tiny_Buffer, Test_Operation_Timeout, Tiny_Open);
      Flyology.Operations.Wait_All (Composable_Set);
      Finish (Tiny_Open, Result, Tiny_Restored);
      Flyology.Operations.Release (Tiny_Open);
      Expect (Result, Capacity_Exceeded, "undersized composable open was not rejected");
      if Flyology.Buffers.Has_Buffer (Tiny_Buffer)
        or else not Flyology.Buffers.Has_Buffer (Tiny_Restored)
        or else Flyology.Buffers.Tag (Tiny_Restored) /= Tiny_Tag
      then
         raise Program_Error with "undersized composable open lost its exact token";
      end if;
      Flyology.Buffers.Release (Tiny_Restored);
   end;

   Open (Probe_Database_ID, Flush_Buffer, Test_Operation_Timeout, Open_Work);
   if Flyology.Buffers.Has_Buffer (Flush_Buffer) then
      raise Program_Error with "composable open did not acquire its scratch token";
   end if;
   Flyology.Operations.Wait_All (Composable_Set);
   Finish (Open_Work, Result, Restored_Buffer);
   Flyology.Operations.Release (Open_Work);
   Expect (Result, Success, "cacheless client-backed reopen failed");
   if Flyology.Buffers.Has_Buffer (Flush_Buffer)
     or else not Flyology.Buffers.Has_Buffer (Restored_Buffer)
     or else Flyology.Buffers.Tag (Restored_Buffer) /= Flush_Token_Tag
   then
      raise Program_Error with "composable open did not restore its exact token";
   end if;
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
   Flyology.Buffers.Release (Restored_Buffer);
   Refresh_Proxy_Testing.Stop;
   Ada.Text_IO.Put_Line ("Flyology.DB client-backed create/commit/Flush/compaction/refresh/reopen passed");
exception
   when others =>
      begin
         Refresh_Proxy_Testing.Release_Blocked;
         Refresh_Proxy_Testing.Stop;
      exception
         when others =>
            null;
      end;
      Close (Created, Close_Result);
      Close (Replica, Close_Result);
      Close (Reopened, Close_Result);
      raise;
end Flyology.DB.Client_Probe;
