with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Flyology.Bytes;
with Flyology.DB.Batch_Formats;
with Flyology.DB.Checkpoint_Policy;
with Flyology.DB.Commit_Authority_Formats;
with Flyology.DB.Object_Storage;
with Flyology.DB.Testing;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Memory;
with Flyology.Operations;
with Flyology_TLA.Codecs;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;
with Interfaces;

procedure Flyology.DB.TLA_Conformance is

   use Ada.Strings.Unbounded;
   use type Checkpoint_Policy.Selection;
   use type Byte;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;

   package Policy renames Flyology.DB.Checkpoint_Policy;
   package Codecs renames Flyology_TLA.Codecs;

   --  These are private checked-trace fixture bounds, not DB limits or harness defaults.
   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 16_384,
      Maximum_Steps        => 4,
      Maximum_JSON_Depth   => 16,
      Maximum_Object_Names => 256,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 4_096,
      Maximum_Value_Bytes  => 8_192);

   type Checkpoint_Adapter is new Flyology_TLA.Replay.Adapter with record
      Buggy : Boolean := False;
   end record;

   overriding
   procedure Reset
     (Self                : in out Checkpoint_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self                  : in out Checkpoint_Adapter;
      Command               : Flyology_TLA.Replay.Replay_Command;
      Observed_Outcome_JSON : out Unbounded_String;
      Observed_State_JSON   : out Unbounded_String;
      Outcome               : out Flyology_TLA.Replay.Adapter_Outcome);

   function Member (Source : String; Name : String) return String
   is (Codecs.Object_Member (Source, Name, Limits));

   function Integer_Member (Source : String; Name : String) return Interfaces.Unsigned_32
   is (Interfaces.Unsigned_32 (Codecs.Decode_Integer (Member (Source, Name))));

   function Boolean_Member (Source : String; Name : String) return Boolean
   is (Codecs.Decode_Boolean (Member (Source, Name)));

   function Selection_Image (Item : Policy.Selection) return String
   is (case Item is
         when Policy.No_Work                  => "NoWork",
         when Policy.Additive_Flush           => "Additive",
         when Policy.Complete_Compaction      => "Complete",
         when Policy.No_Admissible_Checkpoint => "NoAdmissible",
         when Policy.Invalid_Authority        => "InvalidAuthority");

   function Observation_Image
     (Selection : Policy.Selection; Selected_1 : Boolean; Selected_2 : Boolean) return String is
   begin
      return
        "{""selection"":"
        & Codecs.Encode_String (Selection_Image (Selection))
        & ",""selected_f1"":"
        & Codecs.Encode_Boolean (Selected_1)
        & ",""selected_f2"":"
        & Codecs.Encode_Boolean (Selected_2)
        & "}";
   end Observation_Image;

   function State_Image
     (Selection : Policy.Selection; Selected_1 : Boolean; Selected_2 : Boolean) return String is
   begin
      return
        "{""phase"":"
        & Codecs.Encode_String ("Observed")
        & ",""action"":"
        & Codecs.Encode_String (Selection_Image (Selection))
        & ",""selected_f1"":"
        & Codecs.Encode_Boolean (Selected_1)
        & ",""selected_f2"":"
        & Codecs.Encode_Boolean (Selected_2)
        & "}";
   end State_Image;

   procedure Reset
     (Self                : in out Checkpoint_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Self);
   begin
      Observed_State_JSON :=
        To_Unbounded_String
          ("{""phase"":""Ready"",""action"":""Unobserved"",""selected_f1"":false,"
           & """selected_f2"":false}");
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   procedure Apply
     (Self                  : in out Checkpoint_Adapter;
      Command               : Flyology_TLA.Replay.Replay_Command;
      Observed_Outcome_JSON : out Unbounded_String;
      Observed_State_JSON   : out Unbounded_String;
      Outcome               : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      Source       : constant String := To_String (Command.Input_JSON);
      Current      : Policy.Run_Count_Array (1 .. 2);
      Maximum      : Policy.Run_Count_Array (1 .. 2);
      Changed      : Policy.Family_Flag_Array (1 .. 2);
      Nonempty     : Policy.Family_Flag_Array (1 .. 2);
      Decision     : Policy.Selection;
      Selected_1   : Boolean := False;
      Selected_2   : Boolean := False;
      Action       : constant String := To_String (Command.Action);
      Model_Source : constant String := To_String (Command.Model_Source);
   begin
      if Command.Index /= 1
        or else To_String (Command.Role) /= "checkpoint-selection"
        or else Action /= Model_Source
        or else Action
                not in "L0CheckpointNoWorkWitness!ObserveNoWork"
                     | "L0CheckpointAdditiveWitness!ObserveAdditive"
                     | "L0CheckpointSelectionWitness!ObserveComplete"
                     | "L0CheckpointNoAdmissibleWitness!ObserveNoAdmissible"
      then
         raise Codecs.Codec_Error with "unsupported checkpoint-selection trace command";
      elsif Codecs.Object_Size (Source, Limits) /= 10 then
         raise Codecs.Codec_Error with "unexpected checkpoint-selection input shape";
      end if;

      Current := [1 => Integer_Member (Source, "current_f1"), 2 => Integer_Member (Source, "current_f2")];
      Maximum := [1 => Integer_Member (Source, "maximum_f1"), 2 => Integer_Member (Source, "maximum_f2")];
      Changed := [1 => Boolean_Member (Source, "changed_f1"), 2 => Boolean_Member (Source, "changed_f2")];
      Nonempty := [1 => Boolean_Member (Source, "nonempty_f1"), 2 => Boolean_Member (Source, "nonempty_f2")];
      Decision :=
        Policy.Decide
          (Current,
           Maximum,
           Changed,
           Nonempty,
           Boolean_Member (Source, "dirty"),
           Integer_Member (Source, "total_maximum"));

      if Decision = Policy.Invalid_Authority then
         raise Codecs.Codec_Error with "model supplied invalid checkpoint authority";
      elsif Self.Buggy and then Decision = Policy.Complete_Compaction then
         Decision := Policy.Additive_Flush;
      end if;

      if Decision = Policy.Additive_Flush then
         Selected_1 := Changed (1);
         Selected_2 := Changed (2);
      elsif Decision = Policy.Complete_Compaction then
         Selected_1 := Nonempty (1);
         Selected_2 := Nonempty (2);
      end if;

      Observed_Outcome_JSON := To_Unbounded_String (Observation_Image (Decision, Selected_1, Selected_2));
      Observed_State_JSON := To_Unbounded_String (State_Image (Decision, Selected_1, Selected_2));
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : Codecs.Codec_Error | Constraint_Error =>
         Observed_Outcome_JSON := Null_Unbounded_String;
         Observed_State_JSON := Null_Unbounded_String;
         Outcome :=
           (Succeeded => False, Detail => To_Unbounded_String (Ada.Exceptions.Exception_Message (Error)));
   end Apply;

   package Memory renames Flyology.Object_Storage.Backends.Memory;
   package Authority_Formats renames Flyology.DB.Commit_Authority_Formats;
   package Binding renames Flyology.DB.Object_Storage;
   package Batches renames Flyology.DB.Batch_Formats;
   package Heads renames Authority_Formats.Heads;
   use type Authority_Formats.Decode_Status;
   use type Batches.Decode_Status;
   use type Batches.Mutation_Kind;
   use type Heads.Identifier;
   use type Heads.Commit_Sequence;

   --  A two-member, one-byte-key/value replay fixture. Eight provider object
   --  slots and 64 KiB allow the root, rewritten profile, batch, and replacement
   --  HEAD with provider coexistence headroom. These are private test budgets.
   subtype Replay_Store is Memory.Store (1, 8, 65_536);
   type Store_Access is access Replay_Store;
   procedure Free_Store is new Ada.Unchecked_Deallocation (Replay_Store, Store_Access);
   subtype Replay_Member is Positive range 1 .. 2;
   subtype Authority_Buffer is Byte_Array (1 .. 4_096);
   type Authority_Array is array (Replay_Member) of Authority_Buffer;
   type Length_Array is array (Replay_Member) of Natural;
   type Presence_Array is array (Replay_Member) of Boolean;

   type Runtime_Session is limited record
      Context         : aliased Storage_Context;
      Item            : aliased Database;
      Receipts        : Commit_Receipt_Array (Replay_Member);
      Present         : Presence_Array := [others => False];
      Opened          : Boolean := False;
      Baseline_Batch  : Natural := 0;
      Baseline_Run    : Natural := 0;
      Baseline_Manifest : Natural := 0;
      Baseline_Head   : Natural := 0;
   end record;
   type Session_Access is access Runtime_Session;
   procedure Free_Session is new Ada.Unchecked_Deallocation (Runtime_Session, Session_Access);

   type Aggregate_Adapter is new Flyology_TLA.Replay.Adapter with record
      Buggy            : Boolean := False;
      Backend          : Store_Access := null;
      Session          : Session_Access := null;
      Authorities      : Authority_Array := [others => [others => 0]];
      Lengths          : Length_Array := [others => 0];
      Step             : Natural := 0;
      Reopened         : Boolean := False;
      Forgotten        : Boolean := False;
      Verified_Sequence : Sequence_Number := 0;
      Recovered        : Length_Array := [others => 0];
      Retired_Batch    : Natural := 0;
      Retired_Run      : Natural := 0;
      Retired_Manifest : Natural := 0;
      Retired_Head     : Natural := 0;
      Resolution_Writes : Natural := 0;
   end record;

   overriding
   procedure Reset
     (Self                : in out Aggregate_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self                  : in out Aggregate_Adapter;
      Command               : Flyology_TLA.Replay.Replay_Command;
      Observed_Outcome_JSON : out Unbounded_String;
      Observed_State_JSON   : out Unbounded_String;
      Outcome               : out Flyology_TLA.Replay.Adapter_Outcome);

   --  The transaction, key/value, width, and ordinal fixture values are checked
   --  against HarnessInput for every command. Creation budgets and namespace
   --  are fixed adapter fixtures, never public API policy.
   Replay_Bucket : constant String := "aggregate-authority-replay";
   Replay_Prefix : constant String := "authority";
   Replay_Timeout : constant Duration := 10.0;
   Replay_Limits : constant Database_Limits :=
     (Maximum_Column_Families             => 1,
      Maximum_Manifest_History            => 2,
      Maximum_Batch_History               => 2,
      Maximum_Transactions_Per_Batch      => 2,
      Maximum_Mutations_Per_Transaction   => 1,
      Maximum_Mutations_Per_Batch         => 2,
      Maximum_Live_Entries                => 2,
      Maximum_Transaction_Payload_Bytes   => 2,
      Maximum_Batch_Payload_Bytes         => 4,
      Maximum_Live_State_Bytes            => 4,
      Maximum_Total_L0_Runs               => 1,
      Maximum_Checkpoint_Identities       => 6,
      Maximum_Point_Reads_Per_Transaction => 2,
      Maximum_Scan_Ranges_Per_Transaction => 1);

   function Fixture_ID (Value : Natural) return Identifier is
      Result : Identifier := [others => 0];
   begin
      Result (Result'Last - 1) := Byte ((Value / 256) mod 256);
      Result (Result'Last) := Byte (Value mod 256);
      return Result;
   end Fixture_ID;

   function Head_ID (Value : Natural) return Heads.Identifier is
      Result : Heads.Identifier := [others => 0];
   begin
      Result (Result'Last - 1) := Byte ((Value / 256) mod 256);
      Result (Result'Last) := Byte (Value mod 256);
      return Result;
   end Head_ID;

   function Aggregate_Batch_ID return Identifier is
      Result : Identifier := [others => 0];
   begin
      --  Exact current private C5 domain and big-endian ordinal 1,000,000.
      Result (1) := 16#C5#;
      Result (14 .. 16) := [16#0F#, 16#42#, 16#40#];
      return Result;
   end Aggregate_Batch_ID;

   procedure Require_Success (Result : Outcome_Code; Detail : String) is
   begin
      if Result /= Success then
         raise Program_Error with Detail & ": " & Outcome_Code'Image (Result);
      end if;
   end Require_Success;

   procedure Publication_Totals
     (Self : in out Aggregate_Adapter; Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts : out Natural)
   is
      Current_Batch, Current_Run, Current_Manifest, Current_Head : Natural := 0;
   begin
      Batch_Puts := Self.Retired_Batch;
      Run_Puts := Self.Retired_Run;
      Manifest_Puts := Self.Retired_Manifest;
      Head_Puts := Self.Retired_Head;
      if Self.Session /= null then
         Testing.Publication_Counts
           (Self.Session.Context, Current_Batch, Current_Run, Current_Manifest, Current_Head);
         Batch_Puts := Batch_Puts + Current_Batch - Self.Session.Baseline_Batch;
         Run_Puts := Run_Puts + Current_Run - Self.Session.Baseline_Run;
         Manifest_Puts := Manifest_Puts + Current_Manifest - Self.Session.Baseline_Manifest;
         Head_Puts := Head_Puts + Current_Head - Self.Session.Baseline_Head;
      end if;
   end Publication_Totals;

   procedure Retire_Session (Self : in out Aggregate_Adapter) is
      Result : Outcome_Code;
      Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts : Natural;
   begin
      if Self.Session /= null then
         if Self.Session.Opened then
            Close (Self.Session.Item, Result);
            Require_Success (Result, "aggregate replay close");
            Self.Session.Opened := False;
         end if;
         Publication_Totals (Self, Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts);
         Self.Retired_Batch := Batch_Puts;
         Self.Retired_Run := Run_Puts;
         Self.Retired_Manifest := Manifest_Puts;
         Self.Retired_Head := Head_Puts;
         Free_Session (Self.Session);
      end if;
   end Retire_Session;

   procedure Dispose (Self : in out Aggregate_Adapter) is
   begin
      Retire_Session (Self);
      Free_Store (Self.Backend);
   end Dispose;

   procedure Check_Receipt (Self : Aggregate_Adapter; Index : Replay_Member) is
   begin
      if not Self.Session.Present (Index)
        or else Receipt_Transaction_ID (Self.Session.Receipts (Index))
                  /= Transaction_Identifier (Fixture_ID (61_000 + Index))
        or else Receipt_Sequence (Self.Session.Receipts (Index)) /= Sequence_Number (Index)
        or else Receipt_Batch_ID (Self.Session.Receipts (Index)) /= Aggregate_Batch_ID
      then
         raise Program_Error with "aggregate replay changed receipt/member/batch identity";
      end if;
   end Check_Receipt;

   function Receipt_Image (Self : Aggregate_Adapter; Index : Replay_Member) return String is
   begin
      if Self.Session = null or else not Self.Session.Present (Index) then
         return "Invalid_State";
      end if;
      Check_Receipt (Self, Index);
      case Receipt_Outcome (Self.Session.Receipts (Index)) is
         when Outcome_Unknown => return "Outcome_Unknown";
         when Success => return "Success";
         when others => raise Program_Error with "aggregate replay unexpected receipt outcome";
      end case;
   end Receipt_Image;

   function Number_Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   type Authority_Observation is record
      Valid : Boolean := False;
      Batch_Start : Positive := 1;
      Batch_Length : Natural := 0;
   end record;

   function Observe_Authority (Self : Aggregate_Adapter; Index : Replay_Member) return Authority_Observation
   is
      Metadata : Authority_Formats.Authority_Metadata;
      Envelope_Result : Authority_Formats.Decode_Status;
      Batch : Batches.Commit_Batch;
      Batch_Result : Batches.Decode_Status;
      Observation : Authority_Observation;
   begin
      if Self.Lengths (Index) = 0 then
         return Observation;
      end if;
      Authority_Formats.Decode
        (Self.Authorities (Index) (1 .. Self.Lengths (Index)), Head_ID (91),
         Metadata, Observation.Batch_Start, Observation.Batch_Length, Envelope_Result);
      if Envelope_Result /= Authority_Formats.Decoded
        or else Metadata.Format_Version /= Authority_Formats.Aggregate_Authority_Format_Version
        or else Metadata.Transaction_ID /= Head_ID (61_000 + Index)
        or else Metadata.Assigned_Sequence /= Heads.Commit_Sequence (Index)
        or else Metadata.Batch_ID /= Heads.Identifier (Aggregate_Batch_ID)
      then
         return Observation;
      end if;
      Batches.Decode_Latest_Batch
         (Batches.Formats.Byte_Array
           (Self.Authorities (Index)
              (Observation.Batch_Start .. Observation.Batch_Start + Observation.Batch_Length - 1)),
         Head_ID (91), Metadata.Attempted_Head,
         (Transactions => 2, Mutations => 2, Key_Bytes => 1, Value_Bytes => 1,
          Payload_Bytes => 2 * Batches.Transaction_Frame_Header_Length
            + 2 * (Batches.Mutation_Frame_Header_Length + 1 + 1)),
         Batch, Batch_Result);
      if Batch_Result /= Batches.Decoded
        or else Batch.Format_Version /= Batches.Batch_Format_Version
        or else Batch.Transaction_Total /= 2 or else Batch.Mutation_Total /= 2
        or else Batch.First_Sequence /= 1 or else Batch.Last_Sequence /= 2
        or else Batch.Batch_ID /= Heads.Identifier (Aggregate_Batch_ID)
      then
         return Observation;
      end if;
      for Member_Index in Replay_Member loop
         if Batch.Transactions (Member_Index).Transaction_ID
               /= Head_ID (61_000 + Member_Index)
           or else Batch.Transactions (Member_Index).Sequence /= Heads.Commit_Sequence (Member_Index)
           or else Batch.Transactions (Member_Index).First_Mutation /= Member_Index
           or else Batch.Transactions (Member_Index).Mutations /= 1
           or else Batch.Mutations (Member_Index).Column_Family /= 1
           or else Batch.Mutations (Member_Index).Operation /= Batches.Put
           or else Batch.Mutations (Member_Index).Key_Size /= 1
           or else Batch.Mutations (Member_Index).Value_Size /= 1
           or else Batch.Mutations (Member_Index).Key (1) /= Byte (Member_Index)
           or else Batch.Mutations (Member_Index).Value (1) /= Byte (Member_Index)
         then
            return Observation;
         end if;
      end loop;
      Observation.Valid := True;
      return Observation;
   end Observe_Authority;

   function Receipt_Record_Image (Self : Aggregate_Adapter; Index : Replay_Member) return String is
      Result : constant String := Receipt_Image (Self, Index);
      Present : constant Boolean := Result /= "Invalid_State";
   begin
      return "{""result"":" & Codecs.Encode_String (Result)
        & ",""transaction"":" & Number_Image ((if Present then 61_000 + Index else 0))
        & ",""sequence"":" & Number_Image ((if Present then Index else 0))
        & ",""batch"":" & Number_Image ((if Present then 1_000_000 else 0)) & "}";
   end Receipt_Record_Image;

   function Aggregate_State_Image (Self : in out Aggregate_Adapter) return String is
      Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts : Natural;
      First : constant Authority_Observation := Observe_Authority (Self, 1);
      Second : constant Authority_Observation := Observe_Authority (Self, 2);
      Shared_Image : constant Boolean := First.Valid and then Second.Valid
        and then Self.Authorities (1) (First.Batch_Start .. First.Batch_Start + First.Batch_Length - 1)
          = Self.Authorities (2) (Second.Batch_Start .. Second.Batch_Start + Second.Batch_Length - 1);
   begin
      Publication_Totals (Self, Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts);
      return
        "{""online"":" & Codecs.Encode_Boolean (Self.Session /= null and then Self.Session.Opened)
        & ",""forgotten"":" & Codecs.Encode_Boolean (Self.Forgotten)
        & ",""reopened"":" & Codecs.Encode_Boolean (Self.Reopened)
        & ",""receipts"":[" & Receipt_Record_Image (Self, 1) & "," & Receipt_Record_Image (Self, 2) & "]"
        & ",""exported"":[" & Codecs.Encode_Boolean (Self.Lengths (1) /= 0)
        & "," & Codecs.Encode_Boolean (Self.Lengths (2) /= 0) & "]"
        & ",""full_authority"":[" & Codecs.Encode_Boolean (First.Valid)
        & "," & Codecs.Encode_Boolean (Second.Valid) & "]"
        & ",""shared_image"":" & Codecs.Encode_Boolean (Shared_Image)
        & ",""recovered"":[" & Number_Image (Self.Recovered (1))
        & "," & Number_Image (Self.Recovered (2)) & "]"
        & ",""highest"":" & Number_Image (Natural (Self.Verified_Sequence))
        & ",""batch_puts"":" & Number_Image (Batch_Puts)
        & ",""run_puts"":" & Number_Image (Run_Puts)
        & ",""manifest_puts"":" & Number_Image (Manifest_Puts)
        & ",""head_puts"":" & Number_Image (Head_Puts)
        & ",""resolution_writes"":" & Number_Image (Self.Resolution_Writes) & "}";
   end Aggregate_State_Image;

   procedure Verify_Recovered_Values (Self : in out Aggregate_Adapter) is
      Reader : Transaction;
      Family : Column_Family;
      Value : Flyology.Bytes.Unbounded_Bytes;
      Result : Outcome_Code;
      use type Ada.Streams.Stream_Element_Array;
   begin
      Highest_Visible (Self.Session.Item, Self.Verified_Sequence, Result);
      Require_Success (Result, "aggregate replay recovered sequence");
      if Self.Verified_Sequence /= 2 then
         raise Program_Error with "aggregate replay recovered wrong sequence";
      end if;
      Open_Column_Family (Self.Session.Item, 1, Family, Result);
      Require_Success (Result, "aggregate replay recovered family");
      Begin_Transaction (Self.Session.Item, Transaction_Identifier (Fixture_ID (104)), Reader, Result);
      Require_Success (Result, "aggregate replay reader");
      for Index in Replay_Member loop
         Get (Self.Session.Item, Reader, Family, [Byte (Index)], Value, Result);
         Require_Success (Result, "aggregate replay recovered value");
         if Flyology.Bytes.To_Array (Value) /= [Ada.Streams.Stream_Element (Index)] then
            raise Program_Error with "aggregate replay recovered different value";
         end if;
         Self.Recovered (Index) := Natural (Flyology.Bytes.Element (Value, 1));
      end loop;
      Rollback (Reader, Result);
      Require_Success (Result, "aggregate replay reader rollback");
   exception
      when others =>
         Rollback (Reader, Result);
         raise;
   end Verify_Recovered_Values;

   procedure Reset
     (Self                : in out Aggregate_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      Result : Outcome_Code;
      Storage_Result : Flyology.Object_Storage.Status;
      Receipt : Create_Receipt;
      use type Flyology.Object_Storage.Status;
   begin
      Dispose (Self);
      Self.Step := 0;
      Self.Reopened := False;
      Self.Forgotten := False;
      Self.Verified_Sequence := 0;
      Self.Recovered := [others => 0];
      Self.Lengths := [others => 0];
      Self.Authorities := [others => [others => 0]];
      Self.Retired_Batch := 0;
      Self.Retired_Run := 0;
      Self.Retired_Manifest := 0;
      Self.Retired_Head := 0;
      Self.Resolution_Writes := 0;
      Self.Backend := new Replay_Store;
      Self.Backend.Create_Bucket (Replay_Bucket, null, Ada.Real_Time.Time_Last, Storage_Result);
      if Storage_Result /= Flyology.Object_Storage.Success then
         raise Program_Error with "aggregate replay bucket create";
      end if;
      Self.Session := new Runtime_Session;
      Binding.Bind (Self.Session.Context, Self.Backend, Replay_Bucket, Replay_Prefix);
      Create
        (Self.Session.Item, Self.Session.Context'Access, Database_Identifier (Fixture_ID (91)),
         Fixture_ID (92), Fixture_ID (93), Replay_Limits,
         [Configure_Column_Family (1, [97], 1, 1, 4, 2, 1)], Replay_Timeout,
         Receipt => Receipt, Result => Result);
      Require_Success (Result, "aggregate replay root create");
      Self.Session.Opened := True;
      Close (Self.Session.Item, Result);
      Require_Success (Result, "aggregate replay profile close");
      Self.Session.Opened := False;
      Testing.Rewrite_Manifest_Profile
        (Self.Session.Context, Fixture_ID (92), Database_Identifier (Fixture_ID (91)),
         Result, Aggregate_Profile => True);
      Require_Success (Result, "aggregate replay profile fixture");
      Open
        (Self.Session.Item, Self.Session.Context'Access, Database_Identifier (Fixture_ID (91)),
         Replay_Timeout, Result => Result);
      Require_Success (Result, "aggregate replay profile open");
      Self.Session.Opened := True;
      Testing.Configure_Aggregate_Cohort (Self.Session.Item, 2, 1_000_000, Result);
      Require_Success (Result, "aggregate replay cohort configure");
      Testing.Publication_Counts
        (Self.Session.Context, Self.Session.Baseline_Batch, Self.Session.Baseline_Run,
         Self.Session.Baseline_Manifest, Self.Session.Baseline_Head);
      Highest_Visible (Self.Session.Item, Self.Verified_Sequence, Result);
      Require_Success (Result, "aggregate replay initial sequence");
      Observed_State_JSON := To_Unbounded_String (Aggregate_State_Image (Self));
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : others =>
         Observed_State_JSON := Null_Unbounded_String;
         Outcome :=
           (Succeeded => False, Detail => To_Unbounded_String (Ada.Exceptions.Exception_Message (Error)));
   end Reset;

   procedure Commit_Unknown_Cohort (Self : in out Aggregate_Adapter) is
      Set : aliased Flyology.Operations.Completion_Set (2);
      First : Commit_Operation (Set'Access, Self.Session.Item'Access, null);
      Second : Commit_Operation (Set'Access, Self.Session.Item'Access, null);
      Txns : Transaction_Array (Replay_Member);
      Family : Column_Family;
      Result : Outcome_Code;
      First_Result, Second_Result : Outcome_Code;
   begin
      Open_Column_Family (Self.Session.Item, 1, Family, Result);
      Require_Success (Result, "aggregate replay initial family");
      for Index in Replay_Member loop
         Begin_Transaction
           (Self.Session.Item, Transaction_Identifier (Fixture_ID (61_000 + Index)),
            Txns (Index), Result);
         Require_Success (Result, "aggregate replay singleton begin");
         Put (Self.Session.Item, Txns (Index), Family, [Byte (Index)], [Byte (Index)], Result);
         Require_Success (Result, "aggregate replay singleton put");
      end loop;
      Testing.Arm (Self.Session.Context, After_Head_Put, Unknown_After_Entry);
      Commit (Txns (1), Duration'Last, First);
      Commit (Txns (2), Duration'Last, Second);
      Flyology.Operations.Wait_All (Set);
      Finish (First, Self.Session.Receipts (1), First_Result);
      Finish (Second, Self.Session.Receipts (2), Second_Result);
      Flyology.Operations.Release (First);
      Flyology.Operations.Release (Second);
      Self.Session.Present := [others => True];
      if First_Result /= Outcome_Unknown or else Second_Result /= Outcome_Unknown then
         raise Program_Error with "aggregate replay did not retain both unknown receipts";
      end if;
      Check_Receipt (Self, 1);
      Check_Receipt (Self, 2);
   exception
      when others =>
         --  Closing drains admitted work even if the second call did not enter;
         --  scoped operations then finalize before their completion set.
         if Self.Session.Opened then
            Close (Self.Session.Item, Result);
            Self.Session.Opened := False;
         end if;
         for Txn of Txns loop
            Rollback (Txn, Result);
         end loop;
         raise;
   end Commit_Unknown_Cohort;

   procedure Apply
     (Self                  : in out Aggregate_Adapter;
      Command               : Flyology_TLA.Replay.Replay_Command;
      Observed_Outcome_JSON : out Unbounded_String;
      Observed_State_JSON   : out Unbounded_String;
      Outcome               : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      Source : constant String := To_String (Command.Input_JSON);
      Action : constant String := To_String (Command.Action);
      Module_Prefix : constant String := "AggregateCommitCoalescingAuthorityReplay!";
      Result : Outcome_Code := Success;
      Index : Replay_Member;
      Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts : Natural;
      Before_Batch, Before_Run, Before_Manifest, Before_Head : Natural;
      Expected_Member : constant Natural :=
        (case Command.Index is
           when 2 | 3 => Command.Index - 1,
           when 6 | 7 => Command.Index - 5,
           when 8 => 1,
           when others => 0);
   begin
      if Command.Index /= Self.Step + 1
        or else To_String (Command.Role) /= "aggregate-authority-recovery"
        or else Action /= To_String (Command.Model_Source)
        or else Codecs.Object_Size (Source, Limits) /= 9
        or else Integer_Member (Source, "transaction_1") /= 61_001
        or else Integer_Member (Source, "transaction_2") /= 61_002
        or else Integer_Member (Source, "key_1") /= 1
        or else Integer_Member (Source, "key_2") /= 2
        or else Integer_Member (Source, "value_1") /= 1
        or else Integer_Member (Source, "value_2") /= 2
        or else Integer_Member (Source, "width") /= 2
        or else Integer_Member (Source, "first_batch_ordinal") /= 1_000_000
        or else Integer_Member (Source, "member") /= Interfaces.Unsigned_32 (Expected_Member)
      then
         raise Codecs.Codec_Error with "unsupported aggregate authority trace command or fixture";
      end if;
      case Command.Index is
         when 1 =>
            if Action /= Module_Prefix & "CommitUnknown" then
               raise Codecs.Codec_Error with "expected aggregate CommitUnknown";
            end if;
            Commit_Unknown_Cohort (Self);
            Result := Outcome_Unknown;
         when 2 | 3 =>
            Index := Command.Index - 1;
            if Action /= Module_Prefix & "ExportAuthority" then
               raise Codecs.Codec_Error with "expected aggregate member export";
            end if;
            Export_Commit_Resolution_Authority
              (Self.Session.Receipts (Index), Self.Authorities (Index), Self.Lengths (Index), Result);
            Require_Success (Result, "aggregate replay authority export");
            if Self.Lengths (Index) /= Commit_Resolution_Authority_Length (Self.Session.Receipts (Index))
              or else not Observe_Authority (Self, Index).Valid
            then
               raise Program_Error with "aggregate replay authority did not decode both exact members";
            end if;
         when 4 =>
            if Action /= Module_Prefix & "CloseAndForget" then
               raise Codecs.Codec_Error with "expected aggregate CloseAndForget";
            end if;
            Retire_Session (Self);
            Self.Forgotten := Self.Session = null;
         when 5 =>
            if Action /= Module_Prefix & "ReopenFromHead" then
               raise Codecs.Codec_Error with "expected aggregate ReopenFromHead";
            end if;
            Self.Session := new Runtime_Session;
            Binding.Bind (Self.Session.Context, Self.Backend, Replay_Bucket, Replay_Prefix);
            Open
              (Self.Session.Item, Self.Session.Context'Access, Database_Identifier (Fixture_ID (91)),
               Replay_Timeout, Result => Result);
            Require_Success (Result, "aggregate replay fresh session open");
            Self.Session.Opened := True;
            Self.Reopened := True;
            Verify_Recovered_Values (Self);
         when 6 | 7 =>
            Index := Command.Index - 5;
            if Action /= Module_Prefix & "ImportAuthority" then
               raise Codecs.Codec_Error with "expected aggregate member import";
            end if;
            Import_Commit_Resolution_Authority
              (Self.Session.Item, Self.Authorities (Index) (1 .. Self.Lengths (Index)),
               Self.Session.Receipts (Index), Result);
            Require_Success (Result, "aggregate replay authority import");
            Self.Session.Present (Index) := True;
            Check_Receipt (Self, Index);
         when 8 =>
            if Action /= Module_Prefix & "ResolveMember" then
               raise Codecs.Codec_Error with "expected aggregate ResolveMember";
            end if;
            Index := (if Self.Buggy then 2 else 1);
            Publication_Totals (Self, Before_Batch, Before_Run, Before_Manifest, Before_Head);
            Resolve (Self.Session.Item, Self.Session.Receipts (Index), Replay_Timeout, Result => Result);
            Require_Success (Result, "aggregate replay member resolution");
            Publication_Totals (Self, Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts);
            Self.Resolution_Writes := Batch_Puts - Before_Batch + Run_Puts - Before_Run
              + Manifest_Puts - Before_Manifest + Head_Puts - Before_Head;
            Verify_Recovered_Values (Self);
         when others =>
            raise Codecs.Codec_Error with "aggregate authority trace exceeds eight API steps";
      end case;
      Publication_Totals (Self, Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts);
      if Batch_Puts /= 1 or else Run_Puts /= 0 or else Manifest_Puts /= 0 or else Head_Puts /= 1 then
         raise Program_Error with "aggregate replay changed one-batch/one-HEAD publication geometry";
      end if;
      Self.Step := Command.Index;
      Observed_Outcome_JSON := To_Unbounded_String
        ("{""result"":" & Codecs.Encode_String
          ((if Result = Outcome_Unknown then "Outcome_Unknown" else "Success")) & "}");
      Observed_State_JSON := To_Unbounded_String (Aggregate_State_Image (Self));
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : others =>
         Observed_Outcome_JSON := Null_Unbounded_String;
         Observed_State_JSON := Null_Unbounded_String;
         Outcome :=
           (Succeeded => False, Detail => To_Unbounded_String (Ada.Exceptions.Exception_Message (Error)));
   end Apply;

   Flags : Flyology_TLA.Command_Line.Application_Flag_Array :=
     [1 =>
        Flyology_TLA.Command_Line.Flag
          ("--buggy", "misclassify complete compaction to test divergence reporting"),
      2 => Flyology_TLA.Command_Line.Flag
        ("--aggregate-authority", "replay real aggregate Commit authority recovery")];

begin
   declare
      Config : Flyology_TLA.Command_Line.Configuration := Flyology_TLA.Command_Line.Parse (Limits, Flags);
   begin
      if Flyology_TLA.Command_Line.Help_Requested (Config) then
         Flyology_TLA.Command_Line.Put_Help (Flags);
         return;
      end if;

      declare
         Trace   : constant Flyology_TLA.Traces.Trace := Flyology_TLA.Command_Line.Load (Config);
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         if Flyology_TLA.Command_Line.Is_Set (Flags (2)) then
            declare
               Adapter : Aggregate_Adapter;
            begin
               Adapter.Buggy := Flyology_TLA.Command_Line.Is_Set (Flags (1));
               Flyology_TLA.Replay.Run (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
               Dispose (Adapter);
            exception
               when others =>
                  Dispose (Adapter);
                  raise;
            end;
         else
            declare
               Adapter : Checkpoint_Adapter;
            begin
               Adapter.Buggy := Flyology_TLA.Command_Line.Is_Set (Flags (1));
               Flyology_TLA.Replay.Run (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
            end;
         end if;
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end;
exception
   when Error : Flyology_TLA.Command_Line.Usage_Error =>
      Flyology_TLA.Command_Line.Fail (Ada.Exceptions.Exception_Message (Error), Flags, Show_Help => True);
   when Error : Flyology_TLA.Traces.Trace_Error =>
      Flyology_TLA.Command_Line.Fail ("cannot load trace: " & Ada.Exceptions.Exception_Message (Error));
end Flyology.DB.TLA_Conformance;
