with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Streams;
with Ada.Unchecked_Deallocation;
with Flyology.Operations.Drivers;
with Flyology.DB.Batch_Formats;
with Flyology.DB.Checkpoint_Policy;
with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Flyology.DB.LSM_Runtime_Formats;
with Flyology.DB.Manifest_Formats;
with Flyology.Object_Storage;
with Flyology.Object_Storage.S3.SigV4;
with GNAT.SHA256;

package body Flyology.DB is

   package OS renames Flyology.Object_Storage;
   package Backends renames Flyology.Object_Storage.Backends;
   package Client_Common renames Flyology.Object_Storage.Client;
   package Client_Low_Level renames Flyology.Object_Storage.Client.Low_Level;
   package Client_Objects renames Flyology.Object_Storage.Client.Objects;
   package Batches renames Flyology.DB.Batch_Formats;
   package Checkpoints renames Flyology.DB.Checkpoint_Policy;
   package Heads renames Flyology.DB.Head_Policy;
   package LSM_Runtime renames Flyology.DB.LSM_Runtime_Formats;
   package Manifests renames Flyology.DB.Manifest_Formats;
   package UStrings renames Ada.Strings.Unbounded;

   use type Ada.Real_Time.Time;
   use type Ada.Exceptions.Exception_Id;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element;
   use type Interfaces.C.int;
   use type Byte;
   use type Batches.Encode_Status;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Formats.Byte_Array;
   use type Client_Low_Level.Get_Object_Head_Outcome_Kind;
   use type Client_Low_Level.Head_Bucket_Outcome_Kind;
   use type Client_Low_Level.Head_Object_Outcome_Kind;
   use type Client_Low_Level.Put_Object_Outcome_Kind;
   use type Client_Objects.Conditional_Put_Result_Kind;
   use type Client_Common.Failure_Reason;
   use type Client_Objects.Head_Result_Kind;
   use type Client_Common.Publication_Disposition;
   use type Client_Objects.Range_Get_Result_Kind;
   use type Client_Objects.Whole_Get_Result_Kind;
   use type Flyology.DB.Formats.Decode_Status;
   use type Heads.Identifier;
   use type Manifests.Decode_Status;
   use type Manifests.Encode_Status;
   use type Manifests.Family_Name_Bytes;
   use type Manifests.Manifest;
   use type LSM_Runtime.Allocation_Status;
   use type LSM_Runtime.Checkpoint_Manifest_Access;
   use type LSM_Runtime.Decode_Status;
   use type LSM_Runtime.Encode_Status;
   use type LSM_Runtime.Image_Access;
   use type LSM_Runtime.SST_Access;
   use type LSM_Runtime.SST_V2_Frame_Access;
   use type LSM_Runtime.SST_V2_Index_Access;
   use type OS.Byte_Range_Kind;
   use type OS.Range_Resolution_Kind;
   use type OS.Status;
   use type Flyology.Operations.Driver_Event;

   function Group_Mutation_Total_Fits_Wire (Value : Natural) return Boolean
   is (Natural'Size <= Interfaces.Unsigned_32'Size
       or else Interfaces.Unsigned_64 (Value) <= Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last));

   --  Persisted object-key namespace authority. HEAD is the sole mutable
   --  metadata key; immutable batch/manifest/run IDs are lower-hex suffixes
   --  below these prefixes. Renaming any path makes existing databases
   --  unreachable.
   Head_Key_Suffix     : constant String := "meta/HEAD";
   Commit_Key_Prefix   : constant String := "commits/";
   Manifest_Key_Prefix : constant String := "manifests/";
   Run_Key_Prefix      : constant String := "runs/";

   --  Operational batch-v1 codec widths copied from the normative persisted
   --  table: object header 156, trailer 4, transaction prefix 32, mutation
   --  prefix 14. Divergence from the reference codec is wire-incompatible.
   Batch_Header_Length             : constant := 156;
   Batch_Trailer_Length            : constant := 4;
   Transaction_Frame_Header_Length : constant := 32;
   Mutation_Frame_Header_Length    : constant := 14;
   --  Frozen operational batch-v1 version/kind and mutation tags. Naming them
   --  keeps the dynamic codec visibly tied to the persisted table; changing a
   --  value is wire-incompatible and requires a new format version.
   Batch_Format_Version_Code       : constant Interfaces.Unsigned_16 := 1;
   Batch_Object_Kind_Code          : constant Byte := 2;
   Put_Operation_Code              : constant Byte := 1;
   Delete_Operation_Code           : constant Byte := 2;

   type Stored_Object_Kind is (Batch_Object, Manifest_Object, Run_Object, Head_Object);

   procedure Free_Shared_Image is new Ada.Unchecked_Deallocation (Shared_Image_Record, Shared_Image_Access);
   procedure Free_Owned_Mutations is new
     Ada.Unchecked_Deallocation (Owned_Mutation_Array, Owned_Mutation_Array_Access);
   procedure Free_Owned_Point_Read is new
     Ada.Unchecked_Deallocation (Owned_Point_Read, Owned_Point_Read_Access);
   procedure Free_Owned_Scan_Range is new
     Ada.Unchecked_Deallocation (Owned_Scan_Range, Owned_Scan_Range_Access);
   procedure Free_Scan_Rows is new
     Ada.Unchecked_Deallocation (Scan_Row_Descriptor_Array, Scan_Row_Descriptor_Array_Access);
   procedure Free_Scan_Result_State is new
     Ada.Unchecked_Deallocation (Scan_Result_State, Scan_Result_State_Access);
   procedure Free_Scan_Cursor_Bytes is new
     Ada.Unchecked_Deallocation (Byte_Array, Scan_Cursor_Byte_Array_Access);
   procedure Free_Physical_Scan_Entries is new
     Ada.Unchecked_Deallocation (Physical_Scan_Entry_Array, Physical_Scan_Entry_Array_Access);
   procedure Free_Physical_Scan_Sources is new
     Ada.Unchecked_Deallocation (Physical_Scan_Source_Array, Physical_Scan_Source_Array_Access);
   procedure Free_Scan_Cursor_State is new
     Ada.Unchecked_Deallocation (Scan_Cursor_State, Scan_Cursor_State_Access);
   procedure Free_L0_Checkpoint_Families is new
     Ada.Unchecked_Deallocation (L0_Checkpoint_Family_Array, L0_Checkpoint_Family_Array_Access);
   procedure Free_Transaction_Arena is new
     Ada.Unchecked_Deallocation (Transaction_Arena, Transaction_Arena_Access);

   protected Image_Accounting is
      procedure Record_Allocation;
      procedure Record_Release;
      procedure Record_Arena_Allocation;
      procedure Record_Arena_Release;
      procedure Record_Transaction_Copy (Bytes : Natural);
      procedure Record_Source_Bytes (Bytes : Natural);
      procedure Record_Sink_Bytes (Bytes : Natural);
      procedure Snapshot
        (Allocated, Released, Arenas_Allocated, Arenas_Released, Transaction_Bytes, Source_Bytes, Sink_Bytes :
           out Interfaces.Unsigned_64);
   private
      Allocations       : Interfaces.Unsigned_64 := 0;
      Releases          : Interfaces.Unsigned_64 := 0;
      Arena_Allocations : Interfaces.Unsigned_64 := 0;
      Arena_Releases    : Interfaces.Unsigned_64 := 0;
      Transaction_Copy  : Interfaces.Unsigned_64 := 0;
      Source_Copy       : Interfaces.Unsigned_64 := 0;
      Sink_Copy         : Interfaces.Unsigned_64 := 0;
   end Image_Accounting;

   protected Allocation_Faults is
      procedure Arm (Point : Internal_Allocation_Fault_Point);
      procedure Check (Point : Internal_Allocation_Fault_Point);
   private
      Armed : Internal_Allocation_Fault_Point := No_Allocation_Fault;
   end Allocation_Faults;

   protected body Allocation_Faults is
      procedure Arm (Point : Internal_Allocation_Fault_Point) is
      begin
         Armed := Point;
      end Arm;

      procedure Check (Point : Internal_Allocation_Fault_Point) is
      begin
         if Armed = Point then
            Armed := No_Allocation_Fault;
            raise Storage_Error with "injected allocation failure";
         end if;
      end Check;
   end Allocation_Faults;

   procedure Set_Test_Allocation_Fault (Point : Internal_Allocation_Fault_Point) is
   begin
      Allocation_Faults.Arm (Point);
   end Set_Test_Allocation_Fault;

   protected body Image_Accounting is
      procedure Add (Value : in out Interfaces.Unsigned_64; Amount : Natural) is
      begin
         if Interfaces.Unsigned_64 (Amount) > Interfaces.Unsigned_64'Last - Value then
            Value := Interfaces.Unsigned_64'Last;
         else
            Value := Value + Interfaces.Unsigned_64 (Amount);
         end if;
      end Add;

      procedure Record_Allocation is
      begin
         Add (Allocations, 1);
      end Record_Allocation;

      procedure Record_Release is
      begin
         Add (Releases, 1);
      end Record_Release;

      procedure Record_Arena_Allocation is
      begin
         Add (Arena_Allocations, 1);
      end Record_Arena_Allocation;

      procedure Record_Arena_Release is
      begin
         Add (Arena_Releases, 1);
      end Record_Arena_Release;

      procedure Record_Transaction_Copy (Bytes : Natural) is
      begin
         Add (Transaction_Copy, Bytes);
      end Record_Transaction_Copy;

      procedure Record_Source_Bytes (Bytes : Natural) is
      begin
         Add (Source_Copy, Bytes);
      end Record_Source_Bytes;

      procedure Record_Sink_Bytes (Bytes : Natural) is
      begin
         Add (Sink_Copy, Bytes);
      end Record_Sink_Bytes;

      procedure Snapshot
        (Allocated, Released, Arenas_Allocated, Arenas_Released, Transaction_Bytes, Source_Bytes, Sink_Bytes :
           out Interfaces.Unsigned_64) is
      begin
         Allocated := Allocations;
         Released := Releases;
         Arenas_Allocated := Arena_Allocations;
         Arenas_Released := Arena_Releases;
         Transaction_Bytes := Transaction_Copy;
         Source_Bytes := Source_Copy;
         Sink_Bytes := Sink_Copy;
      end Snapshot;
   end Image_Accounting;

   function Allocate_Shared_Image return Shared_Image_Access is
      Result : constant Shared_Image_Access := new Shared_Image_Record;
   begin
      Image_Accounting.Record_Allocation;
      return Result;
   end Allocate_Shared_Image;

   procedure Destroy_Shared_Image (Image : in out Shared_Image_Access) is
   begin
      if Image /= null then
         Image_Accounting.Record_Release;
         Free_Shared_Image (Image);
      end if;
   end Destroy_Shared_Image;

   procedure Release_Arena (Arena : in out Transaction_Arena_Access) is
      Point : Owned_Point_Read_Access;
      Scan  : Owned_Scan_Range_Access;
   begin
      if Arena /= null then
         while Arena.Point_Reads /= null loop
            Point := Arena.Point_Reads;
            Arena.Point_Reads := Point.Next;
            Point.Next := null;
            Free_Owned_Point_Read (Point);
         end loop;
         while Arena.Scan_Ranges /= null loop
            Scan := Arena.Scan_Ranges;
            Arena.Scan_Ranges := Scan.Next;
            Scan.Next := null;
            Free_Owned_Scan_Range (Scan);
         end loop;
         Free_Owned_Mutations (Arena.Mutations);
         Image_Accounting.Record_Arena_Release;
         Free_Transaction_Arena (Arena);
      end if;
   end Release_Arena;

   overriding
   procedure Finalize (Item : in out Transaction_Arena_Owner) is
   begin
      Release_Arena (Item.Arena);
   end Finalize;

   procedure Release_Scan_Result (State : in out Scan_Result_State_Access) is
   begin
      if State /= null then
         Free_Scan_Rows (State.Rows);
         Free_Scan_Result_State (State);
      end if;
   end Release_Scan_Result;

   overriding
   procedure Finalize (Item : in out Scan_Result_Owner) is
   begin
      Release_Scan_Result (Item.State);
   end Finalize;

   procedure Release_Scan_Cursor (State : in out Scan_Cursor_State_Access) is
   begin
      if State /= null then
         Free_Scan_Cursor_Bytes (State.Lower);
         Free_Scan_Cursor_Bytes (State.Upper);
         Free_Scan_Cursor_Bytes (State.Last_Key);
         Free_Physical_Scan_Entries (State.Entries);
         Free_Physical_Scan_Sources (State.Sources);
         Free_Scan_Cursor_State (State);
      end if;
   end Release_Scan_Cursor;

   overriding
   procedure Finalize (Item : in out Scan_Cursor_Owner) is
   begin
      Release_Scan_Cursor (Item.State);
   end Finalize;

   overriding
   procedure Finalize (Item : in out L0_Checkpoint_Requirement_State) is
   begin
      Free_L0_Checkpoint_Families (Item.Families);
   end Finalize;

   protected body Shared_Image_References is
      procedure Retain is
      begin
         if Count = Positive'Last then
            raise Program_Error with "shared image reference count exhausted";
         end if;
         Count := Count + 1;
      end Retain;

      procedure Release (Last : out Boolean) is
      begin
         Last := Count = 1;
         if not Last then
            Count := Count - 1;
         end if;
      end Release;
   end Shared_Image_References;

   overriding
   procedure Adjust (Item : in out Shared_Image_Lease) is
   begin
      if Item.Image /= null then
         Item.Image.References.Retain;
      end if;
   end Adjust;

   overriding
   procedure Finalize (Item : in out Shared_Image_Lease) is
      Released : Shared_Image_Access := Item.Image;
      Last     : Boolean := False;
   begin
      Item.Image := null;
      if Released /= null then
         Released.References.Release (Last);
         if Last then
            Destroy_Shared_Image (Released);
         end if;
      end if;
   end Finalize;

   procedure Release_Image (Image : in out Shared_Image_Access);

   protected Incarnation_Source is
      procedure Allocate (Value : out Engine_Incarnation; Result : out Outcome_Code);
   private
      Last : Engine_Incarnation := No_Incarnation;
   end Incarnation_Source;

   protected body Incarnation_Source is
      procedure Allocate (Value : out Engine_Incarnation; Result : out Outcome_Code) is
      begin
         Value := No_Incarnation;
         if Last = Engine_Incarnation'Last then
            Result := Capacity_Exceeded;
         else
            Last := Last + 1;
            Value := Last;
            Result := Success;
         end if;
      end Allocate;
   end Incarnation_Source;

   type Read_Outcome is
     (Object_Read,
      Object_Missing,
      Read_Precondition_Failed,
      Read_Cancelled,
      Read_Timed_Out,
      Read_Capacity_Exceeded,
      Read_Failed,
      Read_Corrupt);
   type Put_Outcome is
     (Object_Published,
      Put_Precondition_Failed,
      Put_Cancelled,
      Put_Timed_Out,
      Put_Definite_Failure,
      Put_Outcome_Unknown);

   --  Transitional small-object representation for HEAD/manifest fixtures.
   --  Commit objects use Shared_Image and the runtime-sized path below.
   type Small_Metadata_Buffer is array (Small_Metadata_Index) of Byte;

   --  Derived maximum empty manifest-v3 root extent: the frozen 228-byte
   --  header, 64 family frames with their maximum 255-byte names, and the
   --  four-byte trailer. It is a compatibility assertion against the existing
   --  small-object transport boundary, not a database allocation default.
   Maximum_Empty_Root_Checkpoint_Bytes : constant Natural :=
     LSM_Runtime.LSM.Checkpoint_Manifest_Header_Length
     + Maximum_Initial_Column_Families
       * (LSM_Runtime.LSM.Checkpoint_Family_Header_Length + Maximum_Column_Family_Name_Bytes)
     + LSM_Runtime.LSM.Object_Trailer_Length;
   pragma
     Compile_Time_Error
       (Maximum_Empty_Root_Checkpoint_Bytes > Maximum_Small_Metadata_Image_Bytes,
        "manifest-v3 root exceeds the small-metadata transport boundary");

   --  Frozen common-envelope U16 version field offsets shared by persisted
   --  object formats. Moving either byte is wire-incompatible; naming them
   --  here keeps version dispatch and test observation on the same authority.
   Common_Version_High_Offset : constant Natural := 8;
   Common_Version_Low_Offset  : constant Natural := 9;

   type Buffer_Source is new Backends.Byte_Source with record
      Image  : Shared_Image_Access := null;
      Cursor : Natural := 0;
   end record;

   overriding
   function Declared_Length (Item : Buffer_Source) return Backends.Source_Length;

   overriding
   procedure Read
     (Item     : in out Buffer_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time);

   type Buffer_Sink is new Backends.Byte_Sink with record
      Data           : Flyology.Bytes.Unbounded_Bytes;
      Object_Length  : Natural := 0;
      First          : Natural := 0;
      Length         : Natural := 0;
      Written        : Natural := 0;
      Begun          : Boolean := False;
      Partial        : Boolean := False;
      Overflowed     : Boolean := False;
      Maximum_Length : Natural := Natural'Last;
      Generation     : Generation_Value;
   end record;

   overriding
   procedure Begin_Object
     (Item           : in out Buffer_Sink;
      Info           : OS.Object_Information;
      First          : OS.Byte_Count;
      Content_Length : OS.Byte_Count;
      Partial        : Boolean;
      Token          : access Flyology.Cancellation.Token;
      Deadline       : Ada.Real_Time.Time);

   overriding
   procedure Write
     (Item     : in out Buffer_Sink;
      Data     : Ada.Streams.Stream_Element_Array;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time);

   function Is_Zero (Item : Identifier) return Boolean
   is (Item = Zero_Identifier);

   function Is_Zero (Item : Database_Identifier) return Boolean
   is (Item = Zero_Database_ID);

   function Is_Zero (Item : Transaction_Identifier) return Boolean
   is (Item = Zero_Transaction_ID);

   function To_Head_ID (Item : Identifier) return Heads.Identifier
   is (Heads.Identifier (Item));

   function To_Head_ID (Item : Database_Identifier) return Heads.Identifier
   is (Heads.Identifier (Identifier (Item)));

   function To_Identifier (Item : Heads.Identifier) return Identifier
   is (Identifier (Item));

   function To_Database_ID (Item : Heads.Identifier) return Database_Identifier
   is (Database_Identifier (Identifier (Item)));

   function Same_Configuration (Left, Right : Column_Family_Configuration) return Boolean
   is (Left = Right);

   function To_Manifest_Configuration
     (Item : Column_Family_Configuration) return Manifests.Column_Family_Configuration
   is
      Result : Manifests.Column_Family_Configuration;
   begin
      Result.ID := Interfaces.Unsigned_32 (Item.ID);
      Result.Name_Length := Item.Name_Length;
      Result.Max_Key_Bytes := Item.Max_Key_Bytes;
      Result.Max_Value_Bytes := Item.Max_Value_Bytes;
      for Index in Item.Name'Range loop
         Result.Name (Index) := Item.Name (Index);
      end loop;
      return Result;
   end To_Manifest_Configuration;

   function From_Manifest_Configuration
     (Item : Manifests.Column_Family_Configuration) return Column_Family_Configuration
   is
      Result : Column_Family_Configuration;
   begin
      Result.ID := Column_Family_ID (Item.ID);
      Result.Name_Length := Item.Name_Length;
      Result.Max_Key_Bytes := Item.Max_Key_Bytes;
      Result.Max_Value_Bytes := Item.Max_Value_Bytes;
      --  Manifest-v1/base frames do not carry LSM policy. A v2 decoder fills
      --  these fields from its adjacent family extension before activation.
      Result.Memtable_Max_Bytes := 0;
      Result.Memtable_Max_Entries := 0;
      Result.Maximum_L0_Runs := 0;
      for Index in Item.Name'Range loop
         Result.Name (Index) := Item.Name (Index);
      end loop;
      return Result;
   end From_Manifest_Configuration;

   function To_Manifest_Limits (Item : Database_Limits) return Manifests.Database_Limits
   is ((Maximum_Column_Families           => Item.Maximum_Column_Families,
        Maximum_Manifest_History          => Item.Maximum_Manifest_History,
        Maximum_Batch_History             => Item.Maximum_Batch_History,
        Maximum_Transactions_Per_Batch    => Item.Maximum_Transactions_Per_Batch,
        Maximum_Mutations_Per_Transaction => Item.Maximum_Mutations_Per_Transaction,
        Maximum_Mutations_Per_Batch       => Item.Maximum_Mutations_Per_Batch,
        Maximum_Live_Entries              => Item.Maximum_Live_Entries,
        Maximum_Transaction_Payload_Bytes => Item.Maximum_Transaction_Payload_Bytes,
        Maximum_Batch_Payload_Bytes       => Item.Maximum_Batch_Payload_Bytes,
        Maximum_Live_State_Bytes          => Item.Maximum_Live_State_Bytes));

   function To_Public_Limits (Item : Manifests.Database_Limits) return Database_Limits
   is ((Maximum_Column_Families           => Item.Maximum_Column_Families,
        Maximum_Manifest_History          => Item.Maximum_Manifest_History,
        Maximum_Batch_History             => Item.Maximum_Batch_History,
        Maximum_Transactions_Per_Batch    => Item.Maximum_Transactions_Per_Batch,
        Maximum_Mutations_Per_Transaction => Item.Maximum_Mutations_Per_Transaction,
        Maximum_Mutations_Per_Batch       => Item.Maximum_Mutations_Per_Batch,
        Maximum_Live_Entries              => Item.Maximum_Live_Entries,
        Maximum_Transaction_Payload_Bytes => Item.Maximum_Transaction_Payload_Bytes,
        Maximum_Batch_Payload_Bytes       => Item.Maximum_Batch_Payload_Bytes,
        Maximum_Live_State_Bytes          => Item.Maximum_Live_State_Bytes,
        --  These zeroes mean the manifest-v1 base has no LSM extension; they
        --  are never substituted for v2/v3 persisted allocation authority.
        Maximum_Total_L0_Runs             => 0,
        Maximum_Checkpoint_Identities     => 0,
        Maximum_Point_Reads_Per_Transaction => 0,
        Maximum_Scan_Ranges_Per_Transaction => 0));

   function Maximum_Runtime_Batch_Length (Limits : Manifests.Database_Limits) return Natural is
      --  Derived exact maximum framing from the persisted transaction/mutation
      --  counts and frozen batch-v1 widths. Persisted payload bytes are added
      --  below with checked arithmetic; no replacement ceiling is introduced.
      Framing : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Batch_Header_Length + Batch_Trailer_Length)
        + Interfaces.Unsigned_64 (Limits.Maximum_Transactions_Per_Batch) * Transaction_Frame_Header_Length
        + Interfaces.Unsigned_64 (Limits.Maximum_Mutations_Per_Batch) * Mutation_Frame_Header_Length;
   begin
      if Limits.Maximum_Batch_Payload_Bytes > Interfaces.Unsigned_64'Last - Framing
        or else Limits.Maximum_Batch_Payload_Bytes + Framing > Interfaces.Unsigned_64 (Natural'Last)
      then
         return Natural'Last;
      else
         return Natural (Limits.Maximum_Batch_Payload_Bytes + Framing);
      end if;
   end Maximum_Runtime_Batch_Length;

   function To_Head (Item : Head_Snapshot) return Heads.Head_State
   is ((Database_ID            => To_Head_ID (Item.Database_ID),
        Version                => Heads.Format_Version (Item.Version),
        Epoch                  => Heads.Writer_Epoch (Item.Epoch),
        Highest_Visible        => Heads.Commit_Sequence (Item.Highest),
        Latest_Batch           => To_Head_ID (Item.Latest_Batch),
        Latest_Manifest        => To_Head_ID (Item.Latest_Manifest),
        Transition_ID          => To_Head_ID (Item.Transition_ID),
        Predecessor_Transition => To_Head_ID (Item.Predecessor_Transition),
        Transition_Number      => Heads.Transition_Ordinal (Item.Transition_Number)));

   function From_Head (Item : Heads.Head_State) return Head_Snapshot
   is ((Database_ID            => To_Database_ID (Item.Database_ID),
        Version                => Interfaces.Unsigned_16 (Item.Version),
        Epoch                  => Interfaces.Unsigned_64 (Item.Epoch),
        Highest                => Sequence_Number (Item.Highest_Visible),
        Latest_Batch           => To_Identifier (Item.Latest_Batch),
        Latest_Manifest        => To_Identifier (Item.Latest_Manifest),
        Transition_ID          => To_Identifier (Item.Transition_ID),
        Predecessor_Transition => To_Identifier (Item.Predecessor_Transition),
        Transition_Number      => Interfaces.Unsigned_64 (Item.Transition_Number)));

   function Same_Head (Left, Right : Head_Snapshot) return Boolean
   is (Left = Right);

   function Deadline_After (Timeout : Duration) return Ada.Real_Time.Time is
   begin
      if Timeout <= 0.0 then
         return Ada.Real_Time.Clock;
      else
         return Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout);
      end if;
   exception
      when Constraint_Error =>
         return Ada.Real_Time.Time_Last;
   end Deadline_After;

   function Remaining_Time (Deadline : Ada.Real_Time.Time) return Duration is
      Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if Deadline = Ada.Real_Time.Time_Last then
         return Duration'Last;
      elsif Deadline <= Now then
         return 0.0;
      else
         return Ada.Real_Time.To_Duration (Deadline - Now);
      end if;
   exception
      when Constraint_Error =>
         return Duration'Last;
   end Remaining_Time;

   procedure Set_Generation (Target : out Generation_Value; Value : String) is
   begin
      Target := (others => <>);
      if Value'Length <= Maximum_Generation_Bytes then
         Target.Length := Value'Length;
         if Value'Length > 0 then
            Target.Data (1 .. Value'Length) := Value;
         end if;
      end if;
   end Set_Generation;

   function Generation_String (Item : Generation_Value) return String
   is (if Item.Length = 0 then "" else Item.Data (1 .. Item.Length));

   --  HTTP/S3 returns a strong entity tag with exactly one surrounding quote
   --  pair. DB generation storage retains only its nonempty opaque contents,
   --  bounded by Maximum_Generation_Bytes; relaxing this parser would change
   --  which provider generations may authorize conditional publication.
   function Quoted_Generation (Item : Generation_Value) return String
   is ('"' & Generation_String (Item) & '"');

   procedure Set_Quoted_Generation
     (Target : out Generation_Value;
      Value  : String;
      Valid  : out Boolean)
   is
   begin
      Valid :=
        Value'Length >= 2
        and then Value (Value'First) = '"'
        and then Value (Value'Last) = '"'
        and then Value'Length - 2 <= Maximum_Generation_Bytes;
      if Valid then
         Set_Generation (Target, Value (Value'First + 1 .. Value'Last - 1));
         Valid := Target.Length > 0;
      else
         Target := (others => <>);
      end if;
   end Set_Quoted_Generation;

   function Storage_Bound (Storage : Storage_Context) return Boolean
   is (Storage.Backend /= null or else Storage.HTTP_Client /= null);

   function Full_Key (Storage : Storage_Context; Suffix : String) return String
   is (UStrings.To_String (Storage.Prefix) & "/" & Suffix);

   function Hex_Character (Value : Byte) return Character is
      --  Persisted object-key encoding uses canonical lowercase hexadecimal;
      --  changing alphabet/case changes every immutable object path.
      Hex_Digits : constant String := "0123456789abcdef";
   begin
      return Hex_Digits (Natural (Value) + 1);
   end Hex_Character;

   function Identifier_Hex (Item : Identifier) return String is
      Result : String (1 .. Identifier_Length * 2);
   begin
      for Index in Identifier_Index loop
         Result ((Index - 1) * 2 + 1) := Hex_Character (Item (Index) / 16);
         Result ((Index - 1) * 2 + 2) := Hex_Character (Item (Index) mod 16);
      end loop;
      return Result;
   end Identifier_Hex;

   function Batch_Key (Storage : Storage_Context; Batch_ID : Identifier) return String
   is (Full_Key (Storage, Commit_Key_Prefix & Identifier_Hex (Batch_ID)));

   function Manifest_Key (Storage : Storage_Context; Manifest_ID : Identifier) return String
   is (Full_Key (Storage, Manifest_Key_Prefix & Identifier_Hex (Manifest_ID)));

   function Run_Key (Storage : Storage_Context; Run_ID : Identifier) return String
   is (Full_Key (Storage, Run_Key_Prefix & Identifier_Hex (Run_ID)));

   --  Internal deterministic identifiers place the project-selected domain tag
   --  in byte 1 and a big-endian counter in the final eight bytes. They are
   --  test/coordination identities, not persisted format tags; changing this
   --  layout invalidates deterministic recovery fixtures and parity witnesses.
   function Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier is
      Result : Identifier := [others => 0];
   begin
      Result (1) := Tag;
      for Offset in Natural range 0 .. 7 loop
         Result (Identifier_Length - Offset) := Byte (Interfaces.Shift_Right (Number, Offset * 8) and 16#FF#);
      end loop;
      return Result;
   end Structural_ID;

   procedure Consume_Fault
     (Storage : in out Storage_Context; Point : Storage_Fault_Point; Mode : out Storage_Fault_Mode) is
   begin
      Storage.Test_Control.Consume (Point, Mode);
   end Consume_Fault;

   protected body Storage_Test_Control is

      procedure Arm (Point : Storage_Fault_Point; Mode : Storage_Fault_Mode; Count : Positive) is
      begin
         Fault_Modes (Point) := Mode;
         Fault_Counts (Point) := Count;
      end Arm;

      procedure Clear is
      begin
         Fault_Modes := [others => No_Fault];
         Fault_Counts := [others => 0];
      end Clear;

      procedure Consume (Point : Storage_Fault_Point; Mode : out Storage_Fault_Mode) is
      begin
         Mode := No_Fault;
         if Fault_Counts (Point) > 0 then
            Mode := Fault_Modes (Point);
            Fault_Counts (Point) := Fault_Counts (Point) - 1;
            if Fault_Counts (Point) = 0 then
               Fault_Modes (Point) := No_Fault;
            end if;
         end if;
      end Consume;

      procedure Record_Put (Is_Head, Is_Manifest, Is_Run : Boolean) is
      begin
         if Is_Head then
            if Head_Puts < Natural'Last then
               Head_Puts := Head_Puts + 1;
            end if;
         elsif Is_Manifest then
            if Manifest_Puts < Natural'Last then
               Manifest_Puts := Manifest_Puts + 1;
            end if;
         elsif Is_Run then
            if Run_Puts < Natural'Last then
               Run_Puts := Run_Puts + 1;
            end if;
         else
            if Batch_Puts < Natural'Last then
               Batch_Puts := Batch_Puts + 1;
            end if;
         end if;
      end Record_Put;

      procedure Publication_Counts
        (Batch_Total : out Natural; Manifest_Total : out Natural; Head_Total : out Natural) is
      begin
         Batch_Total := Batch_Puts;
         Manifest_Total := Manifest_Puts;
         Head_Total := Head_Puts;
      end Publication_Counts;

      procedure Publication_Counts
        (Batch_Total    : out Natural;
         Run_Total      : out Natural;
         Manifest_Total : out Natural;
         Head_Total     : out Natural) is
      begin
         Batch_Total := Batch_Puts;
         Run_Total := Run_Puts;
         Manifest_Total := Manifest_Puts;
         Head_Total := Head_Puts;
      end Publication_Counts;

      procedure Set_Get_Paused (Value : Boolean) is
      begin
         Get_Paused := Value;
      end Set_Get_Paused;

      procedure Arrive_Get is
      begin
         if Get_Paused and then Waiting_Gets < Natural'Last then
            Waiting_Gets := Waiting_Gets + 1;
         end if;
      end Arrive_Get;

      entry Await_Get when Waiting_Gets > 0 is
      begin
         null;
      end Await_Get;

      entry Continue_Get when not Get_Paused is
      begin
         if Waiting_Gets > 0 then
            Waiting_Gets := Waiting_Gets - 1;
         end if;
      end Continue_Get;

      function Get_Waiting return Boolean
      is (Waiting_Gets > 0);

   end Storage_Test_Control;

   package Storage_Port is
      procedure Bucket_Available
        (Storage  : in out Storage_Context;
         Deadline : Ada.Real_Time.Time;
         Token    : access Flyology.Cancellation.Token;
         Result   : out Outcome_Code);

      procedure Get_Whole
        (Storage        : in out Storage_Context;
         Key            : String;
         Kind           : Stored_Object_Kind;
         Deadline       : Ada.Real_Time.Time;
         Token          : access Flyology.Cancellation.Token;
         Data           : out Flyology.Bytes.Unbounded_Bytes;
         Generation     : out Generation_Value;
         Result         : out Read_Outcome;
         Maximum_Length : Natural := Natural'Last);

      procedure Get_Selected
        (Storage             : in out Storage_Context;
         Key                 : String;
         Kind                : Stored_Object_Kind;
         Requested           : OS.Byte_Range;
         Expected_Generation : Generation_Value;
         Deadline            : Ada.Real_Time.Time;
         Token               : access Flyology.Cancellation.Token;
         Data                : out Flyology.Bytes.Unbounded_Bytes;
         Object_Length       : out Natural;
         Generation          : out Generation_Value;
         Result              : out Read_Outcome;
         Maximum_Length      : Natural);

      procedure Get_Whole
        (Storage    : in out Storage_Context;
         Key        : String;
         Kind       : Stored_Object_Kind;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Data       : out Small_Metadata_Buffer;
         Length     : out Natural;
         Generation : out Generation_Value;
         Result     : out Read_Outcome);

      procedure Put_Create
        (Storage    : in out Storage_Context;
         Key        : String;
         Image      : not null Shared_Image_Access;
         Kind       : Stored_Object_Kind;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome);

      procedure Put_Create
        (Storage    : in out Storage_Context;
         Key        : String;
         Data       : Small_Metadata_Buffer;
         Length     : Natural;
         Kind       : Stored_Object_Kind;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome);

      procedure Put_Replace
        (Storage    : in out Storage_Context;
         Key        : String;
         Image      : not null Shared_Image_Access;
         Expected   : Generation_Value;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome);

      procedure Put_Replace
        (Storage    : in out Storage_Context;
         Key        : String;
         Data       : Small_Metadata_Buffer;
         Length     : Natural;
         Expected   : Generation_Value;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome);
   end Storage_Port;

   overriding
   function Declared_Length (Item : Buffer_Source) return Backends.Source_Length
   is ((Kind  => Backends.Known,
        Bytes => OS.Byte_Count (if Item.Image = null then 0 else Flyology.Bytes.Length (Item.Image.Data))));

   overriding
   procedure Read
     (Item     : in out Buffer_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time)
   is
      pragma Unreferenced (Deadline);
      Count : Natural;
   begin
      Last := Data'First - 1;
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      elsif Item.Image = null or else Item.Cursor = Flyology.Bytes.Length (Item.Image.Data) then
         Finished := True;
         return;
      end if;
      Count := Natural'Min (Data'Length, Flyology.Bytes.Length (Item.Image.Data) - Item.Cursor);
      for Offset in Natural range 0 .. Count - 1 loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Flyology.Bytes.Element (Item.Image.Data, Item.Cursor + Offset + 1);
      end loop;
      Item.Cursor := Item.Cursor + Count;
      Image_Accounting.Record_Source_Bytes (Count);
      Last := Data'First + Ada.Streams.Stream_Element_Offset (Count) - 1;
      Finished := Item.Cursor = Flyology.Bytes.Length (Item.Image.Data);
   end Read;

   overriding
   procedure Begin_Object
     (Item           : in out Buffer_Sink;
      Info           : OS.Object_Information;
      First          : OS.Byte_Count;
      Content_Length : OS.Byte_Count;
      Partial        : Boolean;
      Token          : access Flyology.Cancellation.Token;
      Deadline       : Ada.Real_Time.Time)
   is
      pragma Unreferenced (Deadline);
      Raw_Generation : constant String := UStrings.To_String (Info.Entity_Tag);
   begin
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
      Item.Begun := True;
      if Content_Length > OS.Byte_Count (Item.Maximum_Length)
        or else Info.Size > OS.Byte_Count (Natural'Last)
        or else First > OS.Byte_Count (Natural'Last)
        or else Raw_Generation'Length > Maximum_Generation_Bytes
      then
         Item.Overflowed := True;
      else
         Item.Object_Length := Natural (Info.Size);
         Item.First := Natural (First);
         Item.Length := Natural (Content_Length);
         Item.Partial := Partial;
         Allocation_Faults.Check (Storage_Sink_Allocation);
         Flyology.Bytes.Reserve_Capacity (Item.Data, Item.Length);
         Set_Generation (Item.Generation, Raw_Generation);
      end if;
   end Begin_Object;

   overriding
   procedure Write
     (Item     : in out Buffer_Sink;
      Data     : Ada.Streams.Stream_Element_Array;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time)
   is
      pragma Unreferenced (Deadline);
   begin
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      elsif Item.Overflowed then
         return;
      elsif Data'Length > Item.Length - Item.Written then
         Item.Overflowed := True;
         return;
      end if;
      Flyology.Bytes.Append (Item.Data, Data);
      Item.Written := Item.Written + Data'Length;
      Image_Accounting.Record_Sink_Bytes (Data'Length);
   end Write;

   package body Storage_Port is

      function Signing_Timestamp return String is
         Image : constant String :=
           Ada.Calendar.Formatting.Image (Ada.Calendar.Clock, Include_Time_Fraction => False, Time_Zone => 0);
      begin
         --  AWS SigV4 fixes the basic UTC form YYYYMMDDTHHMMSSZ. These
         --  projections select that wire representation from Ada's extended
         --  calendar image; they are protocol compatibility, not DB policy.
         return
           Image (Image'First .. Image'First + 3)
           & Image (Image'First + 5 .. Image'First + 6)
           & Image (Image'First + 8 .. Image'First + 9)
           & "T"
           & Image (Image'First + 11 .. Image'First + 12)
           & Image (Image'First + 14 .. Image'First + 15)
           & Image (Image'First + 17 .. Image'First + 18)
           & "Z";
      end Signing_Timestamp;

      procedure Bucket_Available
        (Storage  : in out Storage_Context;
         Deadline : Ada.Real_Time.Time;
         Token    : access Flyology.Cancellation.Token;
         Result   : out Outcome_Code)
      is
         Status : OS.Status;
      begin
         if not Storage_Bound (Storage) then
            Result := Invalid_State;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            return;
         end if;
         if Storage.HTTP_Client /= null then
            declare
               Parameters : Client_Low_Level.Head_Bucket_Parameters;
            begin
               Parameters.Expected_Bucket_Owner := Storage.Expected_Bucket_Owner;
               declare
                  Prepared : constant Client_Low_Level.Prepared_Request :=
                    Client_Low_Level.Prepare_Head_Bucket
                      (Storage.Client_Origin,
                       Storage.Client_Style,
                       UStrings.To_String (Storage.Bucket),
                       Parameters,
                       Storage.Client_Identity.all,
                       UStrings.To_String (Storage.Client_Region),
                       Signing_Timestamp);
                  Outcome  : constant Client_Low_Level.Head_Bucket_Outcome :=
                    Client_Low_Level.Execute_Head_Bucket
                      (Storage.HTTP_Client.all, Prepared, Remaining_Time (Deadline), Token);
               begin
                  if Outcome.Kind = Client_Low_Level.Bucket_Found then
                     Result := Success;
                  elsif Outcome.Status = 404 then
                     Result := Not_Found;
                  else
                     Result := Storage_Failure;
                  end if;
               end;
            end;
         else
            Storage.Backend.Head_Bucket
              (Bucket   => UStrings.To_String (Storage.Bucket),
               Token    => Token,
               Deadline => Deadline,
               Result   => Status);
            case Status is
               when OS.Success                         =>
                  Result := Success;

               when OS.Not_Found | OS.Bucket_Not_Found =>
                  Result := Not_Found;

               when others                             =>
                  Result := Storage_Failure;
            end case;
         end if;
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Result := Cancelled;
         when others =>
            if Deadline <= Ada.Real_Time.Clock then
               Result := Timed_Out;
            else
               Result := Storage_Failure;
            end if;
      end Bucket_Available;

      procedure Classify_Read_Failure (Failure : Client_Common.Failure_Reason; Result : out Read_Outcome) is
      begin
         case Failure is
            when Client_Common.Cancelled          =>
               Result := Read_Cancelled;

            when Client_Common.Timed_Out          =>
               Result := Read_Timed_Out;

            when Client_Common.Response_Too_Large =>
               Result := Read_Capacity_Exceeded;

            when others                           =>
               Result := Read_Failed;
         end case;
      end Classify_Read_Failure;

      procedure Get_Selected_Client
        (Storage             : in out Storage_Context;
         Key                 : String;
         Requested           : OS.Byte_Range;
         Expected_Generation : Generation_Value;
         Deadline            : Ada.Real_Time.Time;
         Token               : access Flyology.Cancellation.Token;
         Data                : out Flyology.Bytes.Unbounded_Bytes;
         Object_Length       : out Natural;
         Generation          : out Generation_Value;
         Result              : out Read_Outcome;
         Maximum_Length      : Natural)
      is
         Generation_Tag     : UStrings.Unbounded_String;
         --  DB durability binds reads to opaque ETag generations. An empty
         --  provider version selects that ETag from the current object;
         --  persisting provider version IDs would change the recovery format
         --  and compatibility contract.
         Current_Version_ID : constant String := "";

         procedure Copy_Result (Source : Flyology.Buffers.Unique_Buffer) is
            procedure Append (Bytes : Ada.Streams.Stream_Element_Array) is
            begin
               Flyology.Bytes.Reserve_Capacity (Data, Bytes'Length);
               Flyology.Bytes.Append (Data, Bytes);
               Image_Accounting.Record_Sink_Bytes (Bytes'Length);
            end Append;
         begin
            Flyology.Buffers.With_Readable_Data (Source, Append'Access);
         end Copy_Result;

         procedure Map_Response (Response : Client_Low_Level.Get_Object_Head_Outcome; Valid : out Boolean) is
         begin
            Valid := False;
            if Response.Kind = Client_Low_Level.Object_Opened then
               Set_Quoted_Generation (Generation, UStrings.To_String (Response.Result.Entity_Tag), Valid);
            elsif Response.Status = 404 then
               Result := Object_Missing;
            elsif Response.Status = 412 then
               Result := Read_Precondition_Failed;
            else
               Result := Read_Failed;
            end if;
         end Map_Response;
      begin
         Flyology.Bytes.Clear (Data);
         Object_Length := 0;
         Generation := (others => <>);
         if Maximum_Length = 0 then
            Result := Read_Capacity_Exceeded;
            return;
         end if;
         if Requested.Kind /= OS.Whole_Range and then Expected_Generation.Length = 0 then
            declare
               Parameters : Client_Low_Level.Head_Object_Parameters := (others => <>);
            begin
               Parameters.Expected_Bucket_Owner := Storage.Expected_Bucket_Owner;
               Parameters.Request_Payer := Storage.Client_Request_Payer;
               Parameters.Checksum_Mode := Storage.Client_Checksum_Mode;
               declare
                  Head : constant Client_Objects.Head_Result :=
                    Client_Objects.Head_Object
                      (Storage.HTTP_Client.all,
                       Storage.Client_Origin,
                       UStrings.To_String (Storage.Bucket),
                       Key,
                       Parameters,
                       Storage.Client_Identity.all,
                       UStrings.To_String (Storage.Client_Region),
                       Storage.Client_Style,
                       Remaining_Time (Deadline),
                       Token);
               begin
                  if Head.Kind = Client_Objects.Head_Exchange_Failed then
                     Classify_Read_Failure (Head.Failure, Result);
                     return;
                  elsif Head.Response.Kind = Client_Low_Level.Head_Object_Rejected then
                     Result :=
                       (if Head.Response.Status = 404
                        then Object_Missing
                        elsif Head.Response.Status = 412
                        then Read_Precondition_Failed
                        else Read_Failed);
                     return;
                  end if;
                  declare
                     Head_Generation : Generation_Value;
                     Valid           : Boolean;
                  begin
                     Set_Quoted_Generation
                       (Head_Generation, UStrings.To_String (Head.Response.Result.Entity_Tag), Valid);
                     if not Valid then
                        Result := Read_Corrupt;
                        return;
                     end if;
                     Generation_Tag := UStrings.To_Unbounded_String (Quoted_Generation (Head_Generation));
                  end;
               end;
            end;
         elsif Expected_Generation.Length > 0 then
            Generation_Tag := UStrings.To_Unbounded_String (Quoted_Generation (Expected_Generation));
         end if;

         declare
            --  One exact destination token is the entire retained-body
            --  requirement of a synchronous wait over the provider-owned Get child.
            --  Its block derives from the authenticated/caller-selected DB
            --  read bound; capacity one is operation geometry, not DB policy.
            Pool        :
              aliased Flyology.Buffers.Pool (Block_Size => Positive (Maximum_Length), Capacity => 1);
            Destination : aliased Flyology.Buffers.Unique_Buffer (Pool'Access);
            Valid       : Boolean;
         begin
            Flyology.Buffers.Acquire (Destination);
            if Requested.Kind = OS.Whole_Range then
               declare
                  Outcome : constant Client_Objects.Whole_Get_Result :=
                    Client_Objects.Get_Whole
                      (Storage.HTTP_Client.all,
                       Storage.Client_Origin,
                       UStrings.To_String (Storage.Bucket),
                       Key,
                       Destination,
                       Storage.Client_Identity.all,
                       UStrings.To_String (Generation_Tag),
                       Current_Version_ID,
                       UStrings.To_String (Storage.Client_Region),
                       Storage.Client_Style,
                       UStrings.To_String (Storage.Expected_Bucket_Owner),
                       UStrings.To_String (Storage.Client_Request_Payer),
                       Storage.Client_Checksum_Mode,
                       Remaining_Time (Deadline),
                       Token);
               begin
                  if Outcome.Kind = Client_Objects.Whole_Get_Exchange_Failed then
                     Classify_Read_Failure (Outcome.Failure, Result);
                     return;
                  end if;
                  Map_Response (Outcome.Response, Valid);
                  if not Valid then
                     if Outcome.Response.Kind = Client_Low_Level.Object_Opened then
                        Result := Read_Corrupt;
                     end if;
                     return;
                  elsif Outcome.Response.Status /= 200
                    or else not Outcome.Response.Result.Content_Length.Is_Set
                    or else Outcome.Response.Result.Content_Length.Value > OS.Byte_Count (Natural'Last)
                    or else Natural (Outcome.Response.Result.Content_Length.Value)
                            /= Flyology.Buffers.Length (Destination)
                  then
                     Result := Read_Corrupt;
                     return;
                  end if;
                  Object_Length := Natural (Outcome.Response.Result.Content_Length.Value);
               end;
            else
               declare
                  Outcome : constant Client_Objects.Range_Get_Result :=
                    Client_Objects.Get_Range
                      (Storage.HTTP_Client.all,
                       Storage.Client_Origin,
                       UStrings.To_String (Storage.Bucket),
                       Key,
                       Requested,
                       Destination,
                       Storage.Client_Identity.all,
                       UStrings.To_String (Generation_Tag),
                       Current_Version_ID,
                       UStrings.To_String (Storage.Client_Region),
                       Storage.Client_Style,
                       UStrings.To_String (Storage.Expected_Bucket_Owner),
                       UStrings.To_String (Storage.Client_Request_Payer),
                       Storage.Client_Checksum_Mode,
                       Remaining_Time (Deadline),
                       Token);
               begin
                  if Outcome.Kind = Client_Objects.Range_Get_Exchange_Failed then
                     Classify_Read_Failure (Outcome.Failure, Result);
                     return;
                  end if;
                  Map_Response (Outcome.Response, Valid);
                  if not Valid then
                     if Outcome.Response.Kind = Client_Low_Level.Object_Opened then
                        Result := Read_Corrupt;
                     end if;
                     return;
                  elsif Outcome.Response.Status /= 206
                    or else not Outcome.Has_Resolved_Range
                    or else Outcome.Resolved.Total_Length > OS.Byte_Count (Natural'Last)
                    or else Outcome.Resolved.Last < Outcome.Resolved.First
                    or else Outcome.Resolved.Last - Outcome.Resolved.First + 1
                            /= OS.Byte_Count (Flyology.Buffers.Length (Destination))
                  then
                     Result := Read_Corrupt;
                     return;
                  end if;
                  Object_Length := Natural (Outcome.Resolved.Total_Length);
               end;
            end if;
            Copy_Result (Destination);
            Result := Object_Read;
         end;
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Result := Read_Cancelled;
         when Storage_Error =>
            Flyology.Bytes.Clear (Data);
            Result := Read_Capacity_Exceeded;
         when others =>
            Flyology.Bytes.Clear (Data);
            if Deadline <= Ada.Real_Time.Clock then
               Result := Read_Timed_Out;
            else
               Result := Read_Failed;
            end if;
      end Get_Selected_Client;

      procedure Get_Selected
        (Storage             : in out Storage_Context;
         Key                 : String;
         Kind                : Stored_Object_Kind;
         Requested           : OS.Byte_Range;
         Expected_Generation : Generation_Value;
         Deadline            : Ada.Real_Time.Time;
         Token               : access Flyology.Cancellation.Token;
         Data                : out Flyology.Bytes.Unbounded_Bytes;
         Object_Length       : out Natural;
         Generation          : out Generation_Value;
         Result              : out Read_Outcome;
         Maximum_Length      : Natural)
      is
         Sink       : Buffer_Sink := (Maximum_Length => Maximum_Length, others => <>);
         Info       : OS.Object_Information;
         Status     : OS.Status;
         Fault      : Storage_Fault_Mode;
         Conditions : Backends.Read_Conditions := Backends.Default_Read_Conditions;

         function Exact_Requested_Range return Boolean is
            Resolution : constant OS.Range_Resolution :=
              OS.Resolve_Range (OS.Byte_Count (Sink.Object_Length), Requested);
         begin
            if Resolution.Kind = OS.Empty_Object_Range then
               return
                 Sink.Object_Length = 0
                 and then Sink.First = 0
                 and then Sink.Length = 0
                 and then not Sink.Partial;
            elsif Resolution.Kind /= OS.Satisfied_Range then
               return False;
            end if;
            return
              Resolution.First = OS.Byte_Count (Sink.First)
              and then Resolution.Length = OS.Byte_Count (Sink.Length)
              and then Sink.Partial = (Requested.Kind /= OS.Whole_Range);
         end Exact_Requested_Range;
      begin
         Flyology.Bytes.Clear (Data);
         Object_Length := 0;
         Generation := (others => <>);
         Storage.Test_Control.Arrive_Get;
         Storage.Test_Control.Continue_Get;
         if Kind = Manifest_Object then
            Consume_Fault (Storage, Before_Manifest_Get, Fault);
         else
            Consume_Fault (Storage, Before_Get, Fault);
         end if;
         if Fault /= No_Fault then
            Result := Read_Failed;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Read_Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Read_Timed_Out;
            return;
         end if;
         if Storage.HTTP_Client /= null then
            Get_Selected_Client
              (Storage,
               Key,
               Requested,
               Expected_Generation,
               Deadline,
               Token,
               Data,
               Object_Length,
               Generation,
               Result,
               Maximum_Length);
            return;
         elsif Storage.Backend = null then
            Result := Read_Failed;
            return;
         end if;
         if Expected_Generation.Length > 0 then
            Conditions.If_Match :=
              UStrings.To_Unbounded_String ('"' & Generation_String (Expected_Generation) & '"');
         end if;
         Storage.Backend.Get_Object
           (Bucket     => UStrings.To_String (Storage.Bucket),
            Key        => Key,
            Requested  => Requested,
            Sink       => Sink,
            Token      => Token,
            Deadline   => Deadline,
            Info       => Info,
            Result     => Status,
            Conditions => Conditions);
         case Status is
            when OS.Success                               =>
               if not Sink.Begun
                 or else Sink.Overflowed
                 or else Sink.Written /= Sink.Length
                 or else not Exact_Requested_Range
                 or else Sink.Generation.Length = 0
                 or else UStrings.To_String (Info.Entity_Tag) /= Generation_String (Sink.Generation)
               then
                  Result := Read_Corrupt;
               else
                  Flyology.Bytes.Move (Data, Sink.Data);
                  Object_Length := Sink.Object_Length;
                  Generation := Sink.Generation;
                  Result := Object_Read;
               end if;

            when OS.Not_Found | OS.Bucket_Not_Found       =>
               Result := Object_Missing;

            when OS.Precondition_Failed | OS.Not_Modified =>
               Result := Read_Precondition_Failed;

            when others                                   =>
               Result := Read_Failed;
         end case;
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Result := Read_Cancelled;
         when Storage_Error =>
            Flyology.Bytes.Clear (Data);
            Result := Read_Capacity_Exceeded;
         when others =>
            if Deadline <= Ada.Real_Time.Clock then
               Result := Read_Timed_Out;
            else
               Result := Read_Failed;
            end if;
      end Get_Selected;

      procedure Get_Whole
        (Storage        : in out Storage_Context;
         Key            : String;
         Kind           : Stored_Object_Kind;
         Deadline       : Ada.Real_Time.Time;
         Token          : access Flyology.Cancellation.Token;
         Data           : out Flyology.Bytes.Unbounded_Bytes;
         Generation     : out Generation_Value;
         Result         : out Read_Outcome;
         Maximum_Length : Natural := Natural'Last)
      is
         Ignored_Length : Natural;
      begin
         Get_Selected
           (Storage,
            Key,
            Kind,
            OS.Whole_Object,
            (others => <>),
            Deadline,
            Token,
            Data,
            Ignored_Length,
            Generation,
            Result,
            Maximum_Length);
      end Get_Whole;

      procedure Get_Whole
        (Storage    : in out Storage_Context;
         Key        : String;
         Kind       : Stored_Object_Kind;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Data       : out Small_Metadata_Buffer;
         Length     : out Natural;
         Generation : out Generation_Value;
         Result     : out Read_Outcome)
      is
         Owned : Flyology.Bytes.Unbounded_Bytes;
      begin
         Data := [others => 0];
         Length := 0;
         Get_Whole (Storage, Key, Kind, Deadline, Token, Owned, Generation, Result, Data'Length);
         if Result = Object_Read then
            if Flyology.Bytes.Length (Owned) > Data'Length then
               Result := Read_Corrupt;
            else
               Length := Flyology.Bytes.Length (Owned);
               for Index in Positive range 1 .. Length loop
                  Data (Index - 1) := Byte (Flyology.Bytes.Element (Owned, Index));
               end loop;
            end if;
         end if;
      end Get_Whole;

      procedure Put_Common_Client
        (Storage      : in out Storage_Context;
         Key          : String;
         Image        : not null Shared_Image_Access;
         Conditions   : OS.Write_Conditions;
         Before_Point : Storage_Fault_Point;
         Deadline     : Ada.Real_Time.Time;
         Token        : access Flyology.Cancellation.Token;
         Generation   : out Generation_Value;
         Result       : out Put_Outcome;
         Entered      : out Boolean)
      is
         Length : constant Natural := Flyology.Bytes.Length (Image.Data);
      begin
         Generation := (others => <>);
         Entered := False;
         if Length = 0 then
            Result := Put_Definite_Failure;
            return;
         end if;
         declare
            --  The request body owns one exact token for the duration of the
            --  synchronous wait. Its block is the already-encoded immutable
            --  object length; capacity one is derived operation geometry.
            Pool           : aliased Flyology.Buffers.Pool (Block_Size => Positive (Length), Capacity => 1);
            Payload_Buffer : Flyology.Buffers.Unique_Buffer (Pool'Access);
            Payload_Text   : String (1 .. Length);

            procedure Fill (Data : in out Ada.Streams.Stream_Element_Array; Written : in out Natural) is
            begin
               for Offset in Natural range 0 .. Length - 1 loop
                  declare
                     Value : constant Ada.Streams.Stream_Element :=
                       Flyology.Bytes.Element (Image.Data, Offset + 1);
                  begin
                     Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) := Value;
                     Payload_Text (Offset + 1) := Character'Val (Value);
                  end;
               end loop;
               Written := Length;
            end Fill;
         begin
            Flyology.Buffers.Acquire (Payload_Buffer);
            Flyology.Buffers.With_Writable_Data (Payload_Buffer, Fill'Access);
            declare
               Payload_SHA256 : constant String := Flyology.Object_Storage.S3.SigV4.SHA256_Hex (Payload_Text);
               Outcome        : Client_Objects.Conditional_Put_Result;
            begin
               --  Test accounting starts only after all local validation,
               --  allocation, and hashing have succeeded, immediately before
               --  the mutation call can acquire admission.
               Storage.Test_Control.Record_Put
                 (Is_Head     => Before_Point = Before_Head_Put,
                  Is_Manifest => Before_Point = Before_Manifest_Put,
                  Is_Run      => Before_Point = Before_Run_Put);
               Entered := True;
               if UStrings.To_String (Conditions.If_None_Match) = "*" then
                  Outcome :=
                    Client_Objects.Put_If_Absent
                      (Storage.HTTP_Client.all,
                       Storage.Client_Origin,
                       UStrings.To_String (Storage.Bucket),
                       Key,
                       Payload_Buffer,
                       Payload_SHA256,
                       Storage.Client_Identity.all,
                       UStrings.To_String (Storage.Client_Region),
                       Storage.Client_Style,
                       UStrings.To_String (Storage.Client_Content_Type),
                       UStrings.To_String (Storage.Expected_Bucket_Owner),
                       Remaining_Time (Deadline),
                       Token);
               else
                  Outcome :=
                    Client_Objects.Put_If_Matches
                      (Storage.HTTP_Client.all,
                       Storage.Client_Origin,
                       UStrings.To_String (Storage.Bucket),
                       Key,
                       UStrings.To_String (Conditions.If_Match),
                       Payload_Buffer,
                       Payload_SHA256,
                       Storage.Client_Identity.all,
                       UStrings.To_String (Storage.Client_Region),
                       Storage.Client_Style,
                       UStrings.To_String (Storage.Client_Content_Type),
                       UStrings.To_String (Storage.Expected_Bucket_Owner),
                       Remaining_Time (Deadline),
                       Token);
               end if;
               case Outcome.Disposition is
                  when Client_Common.Published                    =>
                     if Outcome.Kind /= Client_Objects.Put_Response_Available
                       or else Outcome.Response.Kind /= Client_Low_Level.Object_Put
                     then
                        Result := Put_Outcome_Unknown;
                     else
                        declare
                           Valid : Boolean;
                        begin
                           Set_Quoted_Generation
                             (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
                           Result := (if Valid then Object_Published else Put_Outcome_Unknown);
                        end;
                     end if;

                  when Client_Common.Precondition_Failed          =>
                     Result := Put_Precondition_Failed;

                  when Client_Common.Cancelled_Before_Publication =>
                     Result := Put_Cancelled;

                  when Client_Common.Definitely_Not_Published     =>
                     Result :=
                       (if Outcome.Failure = Client_Common.Cancelled
                        then Put_Cancelled
                        elsif Outcome.Failure = Client_Common.Timed_Out
                        then Put_Timed_Out
                        else Put_Definite_Failure);

                  when Client_Common.Outcome_Unknown              =>
                     Result := Put_Outcome_Unknown;
               end case;
            end;
         end;
      exception
         when Storage_Error =>
            Result := (if Entered then Put_Outcome_Unknown else Put_Definite_Failure);
         when others =>
            if Entered then
               Result := Put_Outcome_Unknown;
            elsif Token /= null and then Token.Requested then
               Result := Put_Cancelled;
            elsif Deadline <= Ada.Real_Time.Clock then
               Result := Put_Timed_Out;
            else
               Result := Put_Definite_Failure;
            end if;
      end Put_Common_Client;

      procedure Put_Common
        (Storage      : in out Storage_Context;
         Key          : String;
         Image        : not null Shared_Image_Access;
         Conditions   : OS.Write_Conditions;
         Before_Point : Storage_Fault_Point;
         After_Point  : Storage_Fault_Point;
         Deadline     : Ada.Real_Time.Time;
         Token        : access Flyology.Cancellation.Token;
         Generation   : out Generation_Value;
         Result       : out Put_Outcome)
      is
         Source   : Buffer_Source;
         Info     : OS.Object_Information;
         Status   : OS.Status;
         Fault    : Storage_Fault_Mode;
         Entered  : Boolean := False;
         Borrowed : Shared_Image_Access := Image;
         Held     : Boolean := False;
      begin
         Generation := (others => <>);
         Consume_Fault (Storage, Before_Point, Fault);
         if Fault = Definite_Failure then
            Result := Put_Definite_Failure;
            return;
         elsif Fault = Unknown_After_Entry then
            Result := Put_Outcome_Unknown;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Put_Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Put_Timed_Out;
            return;
         end if;
         Borrowed.References.Retain;
         Held := True;
         Source.Image := Borrowed;
         if Storage.HTTP_Client /= null then
            Put_Common_Client
              (Storage, Key, Image, Conditions, Before_Point, Deadline, Token, Generation, Result, Entered);
            Release_Image (Borrowed);
            Held := False;
            Consume_Fault (Storage, After_Point, Fault);
            if Fault /= No_Fault then
               Result := Put_Outcome_Unknown;
            end if;
            return;
         elsif Storage.Backend = null then
            Release_Image (Borrowed);
            Held := False;
            Result := Put_Definite_Failure;
            return;
         end if;
         Storage.Test_Control.Record_Put
           (Is_Head     => Before_Point = Before_Head_Put,
            Is_Manifest => Before_Point = Before_Manifest_Put,
            Is_Run      => Before_Point = Before_Run_Put);
         Entered := True;
         Storage.Backend.Put_Object
           (Bucket     => UStrings.To_String (Storage.Bucket),
            Key        => Key,
            Source     => Source,
            Options    => OS.Default_Put_Options,
            Token      => Token,
            Deadline   => Deadline,
            Info       => Info,
            Result     => Status,
            Conditions => Conditions);
         Release_Image (Borrowed);
         Held := False;
         Consume_Fault (Storage, After_Point, Fault);
         if Fault /= No_Fault then
            Result := Put_Outcome_Unknown;
         elsif Status = OS.Success then
            if UStrings.Length (Info.Entity_Tag) = 0
              or else UStrings.Length (Info.Entity_Tag) > Maximum_Generation_Bytes
            then
               Result := Put_Outcome_Unknown;
            else
               Set_Generation (Generation, UStrings.To_String (Info.Entity_Tag));
               Result := Object_Published;
            end if;
         elsif Status = OS.Precondition_Failed then
            Result := Put_Precondition_Failed;
         elsif Status = OS.Backend_Unavailable then
            Result := Put_Outcome_Unknown;
         else
            Result := Put_Definite_Failure;
         end if;
      exception
         when others =>
            if Held then
               Release_Image (Borrowed);
            end if;
            if Entered then
               Result := Put_Outcome_Unknown;
            elsif Token /= null and then Token.Requested then
               Result := Put_Cancelled;
            elsif Deadline <= Ada.Real_Time.Clock then
               Result := Put_Timed_Out;
            else
               Result := Put_Definite_Failure;
            end if;
      end Put_Common;

      procedure Put_Create
        (Storage    : in out Storage_Context;
         Key        : String;
         Image      : not null Shared_Image_Access;
         Kind       : Stored_Object_Kind;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome)
      is
         Conditions   : OS.Write_Conditions := OS.Default_Write_Conditions;
         --  Test-injection points are a total mapping from persisted object
         --  kind to its exact pre/post publication boundary; changing the map
         --  changes crash-certainty coverage, not production storage policy.
         Before_Point : constant Storage_Fault_Point :=
           (case Kind is
              when Head_Object     => Before_Head_Put,
              when Manifest_Object => Before_Manifest_Put,
              when Run_Object      => Before_Run_Put,
              when Batch_Object    => Before_Batch_Put);
         After_Point  : constant Storage_Fault_Point :=
           (case Kind is
              when Head_Object     => After_Head_Put,
              when Manifest_Object => After_Manifest_Put,
              when Run_Object      => After_Run_Put,
              when Batch_Object    => After_Batch_Put);
      begin
         Conditions.If_None_Match := UStrings.To_Unbounded_String ("*");
         Put_Common
           (Storage, Key, Image, Conditions, Before_Point, After_Point, Deadline, Token, Generation, Result);
      end Put_Create;

      procedure Put_Create
        (Storage    : in out Storage_Context;
         Key        : String;
         Data       : Small_Metadata_Buffer;
         Length     : Natural;
         Kind       : Stored_Object_Kind;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome)
      is
         Image : Shared_Image_Access := Allocate_Shared_Image;
      begin
         Flyology.Bytes.Reserve_Capacity (Image.Data, Length);
         for Index in Natural range 0 .. Length - 1 loop
            Flyology.Bytes.Append (Image.Data, Ada.Streams.Stream_Element (Data (Index)));
         end loop;
         Put_Create (Storage, Key, Image, Kind, Deadline, Token, Generation, Result);
         Destroy_Shared_Image (Image);
      exception
         when others =>
            Destroy_Shared_Image (Image);
            raise;
      end Put_Create;

      procedure Put_Replace
        (Storage    : in out Storage_Context;
         Key        : String;
         Image      : not null Shared_Image_Access;
         Expected   : Generation_Value;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome)
      is
         Conditions : OS.Write_Conditions := OS.Default_Write_Conditions;
      begin
         Conditions.If_Match := UStrings.To_Unbounded_String ('"' & Generation_String (Expected) & '"');
         Put_Common
           (Storage,
            Key,
            Image,
            Conditions,
            Before_Head_Put,
            After_Head_Put,
            Deadline,
            Token,
            Generation,
            Result);
      end Put_Replace;

      procedure Put_Replace
        (Storage    : in out Storage_Context;
         Key        : String;
         Data       : Small_Metadata_Buffer;
         Length     : Natural;
         Expected   : Generation_Value;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome)
      is
         Image : Shared_Image_Access := Allocate_Shared_Image;
      begin
         Flyology.Bytes.Reserve_Capacity (Image.Data, Length);
         for Index in Natural range 0 .. Length - 1 loop
            Flyology.Bytes.Append (Image.Data, Ada.Streams.Stream_Element (Data (Index)));
         end loop;
         Put_Replace (Storage, Key, Image, Expected, Deadline, Token, Generation, Result);
         Destroy_Shared_Image (Image);
      exception
         when others =>
            Destroy_Shared_Image (Image);
            raise;
      end Put_Replace;

   end Storage_Port;

   subtype Commit_Slot is Positive range 1 .. Maximum_Commit_Slots;
   subtype Group_Count is Natural range 0 .. Maximum_Commit_Slots;

   type Work_Item is record
      Transaction_ID : Transaction_Identifier := Zero_Transaction_ID;
      --  Exact Begin-time sequence moved with admitted work. Zero is both the
      --  empty-database snapshot and vacant-slot reset; the value is runtime
      --  isolation authority, not a persisted default.
      Snapshot_At    : Sequence_Number := 0;
      Arena          : Transaction_Arena_Access := null;
      Payload_Length : Interfaces.Unsigned_64 := 0;
      Deadline       : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Batch_ID       : Identifier := Zero_Identifier;
      Group_ID       : Interfaces.Unsigned_64 := 0;
      Group_Member   : Commit_Slot := Commit_Slot'First;
   end record;
   type Work_Group is array (Commit_Slot) of Work_Item;

   type Runtime_Transaction is record
      Transaction_ID : Transaction_Identifier := Zero_Transaction_ID;
      Sequence       : Sequence_Number := 0;
      First_Mutation : Natural := 0;
      Mutation_Count : Natural := 0;
   end record;
   type Runtime_Transaction_Array is array (Positive range <>) of Runtime_Transaction;
   type Runtime_Transaction_Array_Access is access Runtime_Transaction_Array;

   type Runtime_Mutation is record
      Family       : Column_Family_ID := Column_Family_ID'First;
      Operation    : Mutation_Kind := Put_Mutation;
      Key_Offset   : Natural := 0;
      Key_Length   : Natural := 0;
      Value_Offset : Natural := 0;
      Value_Length : Natural := 0;
   end record;
   type Runtime_Mutation_Array is array (Positive range <>) of Runtime_Mutation;
   type Runtime_Mutation_Array_Access is access Runtime_Mutation_Array;

   type Runtime_Batch is record
      Database_ID                   : Database_Identifier := Zero_Database_ID;
      Epoch                         : Interfaces.Unsigned_64 := 0;
      Batch_ID                      : Identifier := Zero_Identifier;
      Previous_Batch_ID             : Identifier := Zero_Identifier;
      Expected_Transition_ID        : Identifier := Zero_Identifier;
      Expected_Transition_Number    : Interfaces.Unsigned_64 := 0;
      Publication_Transition_ID     : Identifier := Zero_Identifier;
      Publication_Transition_Number : Interfaces.Unsigned_64 := 0;
      First_Sequence                : Sequence_Number := 0;
      Last_Sequence                 : Sequence_Number := 0;
      Transaction_Total             : Natural := 0;
      Mutation_Total                : Natural := 0;
      Transactions                  : Runtime_Transaction_Array_Access := null;
      Mutations                     : Runtime_Mutation_Array_Access := null;
      Image                         : Shared_Image_Access := null;
   end record;
   type Runtime_Batch_Array is array (Positive range <>) of Runtime_Batch;
   subtype History_Slot is Positive range 1 .. Maximum_History_Batches;
   type Batch_History is array (Positive range <>) of Runtime_Batch;
   type Batch_History_Access is access Batch_History;
   type Manifest_History is array (History_Slot) of Manifests.Manifest;

   procedure Free_Runtime_Transactions is new
     Ada.Unchecked_Deallocation (Runtime_Transaction_Array, Runtime_Transaction_Array_Access);
   procedure Free_Runtime_Mutations is new
     Ada.Unchecked_Deallocation (Runtime_Mutation_Array, Runtime_Mutation_Array_Access);
   procedure Free_Batch_History is new Ada.Unchecked_Deallocation (Batch_History, Batch_History_Access);

   procedure Release_Image (Image : in out Shared_Image_Access) is
      Last : Boolean := False;
   begin
      if Image /= null then
         Image.References.Release (Last);
         if Last then
            Destroy_Shared_Image (Image);
         else
            Image := null;
         end if;
      end if;
   end Release_Image;

   procedure Release_Runtime_Batch (Batch : in out Runtime_Batch; Release_Data : Boolean := True) is
   begin
      Free_Runtime_Transactions (Batch.Transactions);
      Free_Runtime_Mutations (Batch.Mutations);
      if Release_Data then
         Release_Image (Batch.Image);
      else
         Batch.Image := null;
      end if;
      Batch := (others => <>);
   end Release_Runtime_Batch;

   procedure Release_History (History : in out Batch_History_Access; Count : in out Natural);

   function Mutation_Count (Txn : Transaction) return Natural
   is (if Txn.Owner.Arena = null then 0 else Txn.Owner.Arena.Count);

   function Payload_Bytes (Txn : Transaction) return Interfaces.Unsigned_64
   is (if Txn.Owner.Arena = null then 0 else Txn.Owner.Arena.Bytes_Used);

   function Mutation_Count (Item : Work_Item) return Natural
   is (if Item.Arena = null then 0 else Item.Arena.Count);

   function Payload_Bytes (Item : Work_Item) return Interfaces.Unsigned_64
   is (Item.Payload_Length);

   type Slot_Token is record
      Index      : Commit_Slot := Commit_Slot'First;
      Generation : Interfaces.Unsigned_64 := 0;
   end record;
   type Token_Group is array (Commit_Slot) of Slot_Token;
   type Internal_Receipt is record
      Current_Outcome   : Outcome_Code := Invalid_State;
      Phase             : Receipt_Phase := No_Publication;
      Transaction_ID    : Transaction_Identifier := Zero_Transaction_ID;
      Assigned_Sequence : Sequence_Number := 0;
      Batch_ID          : Identifier := Zero_Identifier;
      Image             : Shared_Image_Access := null;
      Expected_Head     : Head_Snapshot;
      Attempted_Head    : Head_Snapshot;
   end record;
   type Receipt_Group is array (Commit_Slot) of Internal_Receipt;

   procedure Adopt_Receipt (Target : out Commit_Receipt; Source : in out Internal_Receipt) is
   begin
      Target := (others => <>);
      Target.Current_Outcome := Source.Current_Outcome;
      Target.Phase := Source.Phase;
      Target.Transaction_ID := Source.Transaction_ID;
      Target.Assigned_Sequence := Source.Assigned_Sequence;
      Target.Batch_ID := Source.Batch_ID;
      Target.Expected_Head := Source.Expected_Head;
      Target.Attempted_Head := Source.Attempted_Head;
      Target.Retained_Image.Image := Source.Image;
      Source.Image := null;
   end Adopt_Receipt;

   procedure Release_Retained_Image (Receipt : in out Commit_Receipt) is
      Image : Shared_Image_Access := Receipt.Retained_Image.Image;
   begin
      Receipt.Retained_Image.Image := null;
      Release_Image (Image);
   end Release_Retained_Image;

   procedure Release_Retained_Manifest (Receipt : in out Create_Receipt) is
      Image : Shared_Image_Access := Receipt.Retained_Manifest.Image;
   begin
      Receipt.Retained_Manifest.Image := null;
      Release_Image (Image);
   end Release_Retained_Manifest;

   procedure Release_Retained_Manifest (Receipt : in out Column_Family_Receipt) is
      Image : Shared_Image_Access := Receipt.Retained_Manifest.Image;
   begin
      Receipt.Retained_Manifest.Image := null;
      Release_Image (Image);
   end Release_Retained_Manifest;

   type Slot_State is (Free, Queued, Running, Completed);
   type Completion_Slot is record
      State      : Slot_State := Free;
      Generation : Interfaces.Unsigned_64 := 0;
      Order      : Interfaces.Unsigned_64 := 0;
      Work       : Work_Item;
      Receipt    : Internal_Receipt;
      Result     : Outcome_Code := Invalid_State;
   end record;
   type Completion_Array is array (Commit_Slot) of Completion_Slot;

   type State_Entry is record
      Family       : Column_Family_ID := Column_Family_ID'First;
      Image        : Shared_Image_Access := null;
      Key_Offset   : Natural := 0;
      Key_Length   : Natural := 0;
      Value_Offset : Natural := 0;
      Value_Length : Natural := 0;
      --  Zero is the vacant-entry sentinel. Every installed entry retains the
      --  exact nonzero last-write sequence authenticated by its runtime batch;
      --  changing it would change SST ordering and cacheless reconstruction.
      Sequence     : Sequence_Number := 0;
   end record;
   type State_Entry_Array is array (Positive range <>) of State_Entry;
   type State_Entry_Array_Access is access State_Entry_Array;
   procedure Free_State_Entries is new
     Ada.Unchecked_Deallocation (Object => State_Entry_Array, Name => State_Entry_Array_Access);

   --  Transient scan sources borrow immutable engine images while one
   --  lifecycle lease prevents close/checkpoint reclamation. Arena_Index zero
   --  selects Key_Image; a positive value selects the caller transaction's
   --  stable mutation. Selection fields are populated only after snapshot
   --  lookup outside the coordinator. No enumeration or field is persisted.
   type Scan_Source is record
      Key_Image             : Shared_Image_Access := null;
      Key_Offset            : Natural := 0;
      Key_Length            : Natural := 0;
      Arena_Index           : Natural := 0;
      --  Runtime authority ordinals derive from source order: checkpoint is
      --  one, history batch N is N + 1, and own writes are max + 1. They are
      --  never persisted; changing the order changes snapshot visibility.
      Authority             : Natural := 0;
      Version               : Sequence_Number := 0;
      Order                 : Natural := 0;
      Operation             : Mutation_Kind := Put_Mutation;
      Selected              : Boolean := False;
      Selected_Image        : Shared_Image_Access := null;
      Selected_Value_Offset : Natural := 0;
      Selected_Value_Length : Natural := 0;
      Selected_Arena_Index  : Natural := 0;
   end record;
   type Scan_Source_Array is array (Positive range <>) of Scan_Source;
   type Scan_Source_Array_Access is access Scan_Source_Array;
   procedure Free_Scan_Sources is new
     Ada.Unchecked_Deallocation (Scan_Source_Array, Scan_Source_Array_Access);
   type Snapshot_Entry_Reference is record
      --  Defaults describe an unfilled transient slot only. Populated slots
      --  borrow engine-owned immutable batch images during exclusive snapshot
      --  construction and retain exact live-entry offsets and sequence.
      Image        : Shared_Image_Access := null;
      Key_Offset   : Natural := 0;
      Key_Length   : Natural := 0;
      Value_Offset : Natural := 0;
      Value_Length : Natural := 0;
      Sequence     : Sequence_Number := 0;
      --  Frozen SST-v1/v2 operation tag. Full snapshots use Put; suffix-delta
      --  snapshots retain Delete so newer runs can mask older values.
      Operation    : Byte := Put_Operation_Code;
   end record;
   type Snapshot_Entry_Reference_Array is array (Positive range <>) of Snapshot_Entry_Reference;
   type Snapshot_Entry_Reference_Array_Access is access Snapshot_Entry_Reference_Array;
   procedure Free_Snapshot_References is new
     Ada.Unchecked_Deallocation
       (Object => Snapshot_Entry_Reference_Array,
        Name   => Snapshot_Entry_Reference_Array_Access);
   --  The fixed publication slot map mirrors the frozen 64-family registry.
   --  Each populated slot owns only the newly produced run for that family;
   --  prior immutable descriptors remain in the successor manifest.
   type Checkpoint_SST_Array is array (Manifests.Family_Slot) of LSM_Runtime.SST_Access;
   type Recovered_SST_Array is array (Positive range <>) of LSM_Runtime.SST_Access;
   type Recovered_SST_Array_Access is access Recovered_SST_Array;
   procedure Free_Recovered_SSTs is new
     Ada.Unchecked_Deallocation (Recovered_SST_Array, Recovered_SST_Array_Access);
   type Checkpoint_Image_Array is array (Positive range <>) of Shared_Image_Access;
   type Checkpoint_Image_Array_Access is access Checkpoint_Image_Array;
   procedure Free_Checkpoint_Images is new
     Ada.Unchecked_Deallocation (Checkpoint_Image_Array, Checkpoint_Image_Array_Access);
   type Checkpoint_Plan is record
      Manifest            : LSM_Runtime.Checkpoint_Manifest_Access := null;
      SSTs                : Checkpoint_SST_Array := [others => null];
      Recovered_SSTs      : Recovered_SST_Array_Access := null;
      Images              : Checkpoint_Image_Array_Access := null;
      Base                : State_Entry_Array_Access := null;
      History             : Batch_History_Access := null;
      History_Count       : Natural := 0;
      Activation_Ready    : Boolean := False;
      Expected_Generation : Generation_Value;
   end record;

   --  These are owner-stack driver states only; their enumeration positions
   --  are never persisted or exposed. Every mutation-wait phase retains the
   --  exact prepared image selected before first publication.
   type Flush_Driver_Phase is
     (Flush_Idle,
      Waiting_For_Quiescence,
      Reading_Selected_Head,
      Reading_Selected_Header,
      Reading_Selected_Whole,
      Putting_Immutable,
      Reading_Immutable,
      Putting_Head,
      Flush_Terminal);

   --  Private constructor authority only. These positions are never persisted
   --  or exposed and select no automatic compaction trigger or run policy.
   type Flush_Plan_Mode is
     (Additive_Plan,
      Complete_Replacement_Plan,
      Adjacent_Merge_Plan,
      Three_Run_Merge_Plan,
      Family_Append_Plan);

   type Prepared_Flush_Image is record
      Owner  : Shared_Image_Access := null;
      --  SigV4 fixes SHA-256 payload digests to the GNAT.SHA256 maintained
      --  hexadecimal digest subtype. The field is derived from exact encoded
      --  bytes before publication and introduces no DB checksum policy. The
      --  all-zero text is only the vacant initializer and is never selected
      --  once Owner names a publishable image.
      Digest : GNAT.SHA256.Message_Digest := [others => '0'];
   end record;
   type Prepared_Flush_Image_Array is array (Manifests.Family_Slot) of Prepared_Flush_Image;

   type Flush_Driver_State is record
      Engine              : Engine_State_Access := null;
      Plan                : Checkpoint_Plan;
      Selected_Source     : Checkpoint_Plan;
      Selected_Base       : Manifests.Manifest;
      Selected_Head       : Head_Snapshot;
      Runs                : Flush_Run_Receipt_Array := [others => (others => <>)];
      Run_Total           : Natural range 0 .. Maximum_Initial_Column_Families := 0;
      Manifest_ID         : Identifier := Zero_Identifier;
      Transition_ID       : Identifier := Zero_Identifier;
      Older_Run_ID        : Identifier := Zero_Identifier;
      Middle_Run_ID       : Identifier := Zero_Identifier;
      Newer_Run_ID        : Identifier := Zero_Identifier;
      Output_Run_ID       : Identifier := Zero_Identifier;
      Family_Configuration : Column_Family_Configuration;
      Run_Images          : Prepared_Flush_Image_Array := [others => (others => <>)];
      Manifest_Image      : Prepared_Flush_Image;
      Head_Image          : Prepared_Flush_Image;
      --  Zero is the transient "before first/after last" cursor for both the
      --  family publication scan and selected-run reader. Persisted manifest
      --  family/run indices remain one-based and never use it.
      Current_Family_Slot : Natural range 0 .. Maximum_Initial_Column_Families := 0;
      Selected_Run_Index  : Natural := 0;
      Selected_Family_Slot : Natural range 0 .. Maximum_Initial_Column_Families := 0;
      Selected_Object_Length : Natural := 0;
      Selected_Generation : Generation_Value;
      Selected_Admission  : LSM_Runtime.SST_Header_Admission := (others => <>);
      Current_Kind        : Stored_Object_Kind := Run_Object;
      Phase               : Flush_Driver_Phase := Flush_Idle;
      Precheck_Result     : Outcome_Code := Success;
      Checkpoint_Admitted : Boolean := False;
      --  Fresh-state additive mode is only a vacant initializer. Every Start
      --  assigns its explicit private constructor-selected algorithm before
      --  the driver can run.
      Mode                : Flush_Plan_Mode := Additive_Plan;
   end record;

   procedure Free_Flush_Driver_State is new
     Ada.Unchecked_Deallocation (Flush_Driver_State, Flush_Driver_State_Access);
   procedure Free_Whole_Get_Operation is new
     Ada.Unchecked_Deallocation
       (Flyology.Object_Storage.Client.Objects.Whole_Get_Operation,
        Whole_Get_Operation_Access);
   procedure Free_Range_Get_Operation is new
     Ada.Unchecked_Deallocation
       (Flyology.Object_Storage.Client.Objects.Range_Get_Operation,
        Range_Get_Operation_Access);
   procedure Free_Head_Operation is new
     Ada.Unchecked_Deallocation
       (Flyology.Object_Storage.Client.Objects.Head_Operation,
        Head_Operation_Access);
   type Seen_Transaction_Array is array (Positive range <>) of Transaction_Identifier;
   type Used_Batch_ID_Array is array (Positive range <>) of Identifier;
   type Reserved_Identity_Array is array (Positive range <>) of Identifier;

   type Family_LSM_Authority is record
      ID    : Interfaces.Unsigned_32 := 0;
      State : LSM_Runtime.Family_LSM_State := (others => <>);
   end record;
   --  This table follows the frozen manifest base's 64 family slots. It retains
   --  only registry policy, not keys, values, runs, identities, or an allocation
   --  ceiling beyond that existing persisted-format compatibility boundary.
   type Family_LSM_Authority_Array is array (Manifests.Family_Slot) of Family_LSM_Authority;
   type Engine_LSM_Authority is record
      Enabled                       : Boolean := False;
      Replay_Boundary               : Interfaces.Unsigned_64 := 0;
      Maximum_Total_L0_Runs         : Interfaces.Unsigned_32 := 0;
      Maximum_Checkpoint_Identities : Interfaces.Unsigned_32 := 0;
      Maximum_Point_Reads_Per_Transaction : Interfaces.Unsigned_32 := 0;
      Maximum_Scan_Ranges_Per_Transaction : Interfaces.Unsigned_32 := 0;
      Families                      : Family_LSM_Authority_Array := [others => (others => <>)];
   end record;

   --  Legacy manifest-v1 state carries no LSM extension. This sentinel keeps
   --  such databases readable for log-only operation without supplying any
   --  memtable, run, or identity fallback authority.
   No_LSM_Authority : constant Engine_LSM_Authority := (others => <>);

   function To_Engine_LSM_Authority (Value : LSM_Runtime.Checkpoint_Manifest) return Engine_LSM_Authority is
      Result : Engine_LSM_Authority :=
        (Enabled                       => True,
         Replay_Boundary               => Value.Replay_Boundary,
         Maximum_Total_L0_Runs         => Value.Maximum_Total_L0_Runs,
         Maximum_Checkpoint_Identities => Value.Maximum_Checkpoint_Identities,
         Maximum_Point_Reads_Per_Transaction => Value.Maximum_Point_Reads_Per_Transaction,
         Maximum_Scan_Ranges_Per_Transaction => Value.Maximum_Scan_Ranges_Per_Transaction,
         Families                      => [others => (others => <>)]);
   begin
      for Index in Value.Families'Range loop
         Result.Families (Index) := (ID => Value.Base.Families (Index).ID, State => Value.Families (Index));
      end loop;
      return Result;
   end To_Engine_LSM_Authority;

   function Same_LSM_Policy (Left, Right : Engine_LSM_Authority) return Boolean is
   begin
      if not Left.Enabled
        or else not Right.Enabled
        or else Left.Maximum_Total_L0_Runs /= Right.Maximum_Total_L0_Runs
        or else Left.Maximum_Checkpoint_Identities /= Right.Maximum_Checkpoint_Identities
        or else Left.Maximum_Point_Reads_Per_Transaction
                /= Right.Maximum_Point_Reads_Per_Transaction
        or else Left.Maximum_Scan_Ranges_Per_Transaction
                /= Right.Maximum_Scan_Ranges_Per_Transaction
      then
         return False;
      end if;
      for Index in Manifests.Family_Slot loop
         if Left.Families (Index).ID /= Right.Families (Index).ID
           or else Left.Families (Index).State.Memtable_Max_Bytes
                   /= Right.Families (Index).State.Memtable_Max_Bytes
           or else Left.Families (Index).State.Memtable_Max_Entries
                   /= Right.Families (Index).State.Memtable_Max_Entries
           or else Left.Families (Index).State.Maximum_L0_Runs /= Right.Families (Index).State.Maximum_L0_Runs
         then
            return False;
         end if;
      end loop;
      return True;
   end Same_LSM_Policy;

   function Same_Runtime_Key
     (Left_Image  : not null Shared_Image_Access;
      Left        : Runtime_Mutation;
      Right_Image : not null Shared_Image_Access;
      Right       : Runtime_Mutation) return Boolean is
   begin
      if Left.Family /= Right.Family or else Left.Key_Length /= Right.Key_Length then
         return False;
      end if;
      for Offset in Natural range 0 .. Left.Key_Length - 1 loop
         if Flyology.Bytes.Element (Left_Image.Data, Left.Key_Offset + Offset + 1)
           /= Flyology.Bytes.Element (Right_Image.Data, Right.Key_Offset + Offset + 1)
         then
            return False;
         end if;
      end loop;
      return True;
   end Same_Runtime_Key;

   function Runtime_Mutation_Sequence
     (Batch : Runtime_Batch; Mutation_Index : Positive) return Sequence_Number is
   begin
      if Batch.Transactions = null then
         return 0;
      end if;
      for Transaction of Batch.Transactions (1 .. Batch.Transaction_Total) loop
         if Mutation_Index >= Transaction.First_Mutation
           and then Mutation_Index - Transaction.First_Mutation < Transaction.Mutation_Count
         then
            return Transaction.Sequence;
         end if;
      end loop;
      return 0;
   end Runtime_Mutation_Sequence;

   protected type Coordinator
     (Entry_Capacity    : Positive;
      Seen_Capacity     : Positive;
      History_Capacity  : Positive;
      Reserved_Capacity : Positive)
   is
      procedure Initialize
        (Head       : Head_Snapshot;
         Generation : Generation_Value;
         Manifest   : Manifests.Manifest;
         --  Exact authenticated checkpoint replay boundary. History strictly
         --  after it is retained; an older transaction cannot be validated.
         History_Boundary : Sequence_Number;
         Stamp      : Engine_Incarnation);

      procedure Recover_Batch (Batch : in out Runtime_Batch; Result : out Outcome_Code);

      procedure Recover_Checkpoint
        (Plan   : Checkpoint_Plan;
         Images : Checkpoint_Image_Array_Access;
         Base   : State_Entry_Array_Access;
         Live_Count : out Natural;
         Result : out Outcome_Code);

      procedure Transaction_Available (Transaction_ID : Transaction_Identifier; Result : out Outcome_Code);

      procedure Admit
        (Txn      : in out Transaction;
         Deadline : Ada.Real_Time.Time;
         Token    : access Flyology.Cancellation.Token;
         Slot     : out Slot_Token;
         Result   : out Outcome_Code);

      procedure Admit_Group
        (Transactions : in out Transaction_Array;
         Batch_ID     : Identifier;
         Deadline     : Ada.Real_Time.Time;
         Token        : access Flyology.Cancellation.Token;
         Tokens       : out Token_Group;
         Count        : out Group_Count;
         Result       : out Outcome_Code);

      entry Take_Group
        (Items      : out Work_Group;
         Tokens     : out Token_Group;
         Count      : out Group_Count;
         Head       : out Head_Snapshot;
         Generation : out Generation_Value;
         Stop       : out Boolean);

      procedure Prepublication_Check (Items : Work_Group; Count : Group_Count; Result : out Outcome_Code);

      procedure Validate_Batch (Batch : Runtime_Batch; Result : out Outcome_Code);

      procedure Complete_Group
        (Tokens         : Token_Group;
         Receipts       : Receipt_Group;
         Count          : Group_Count;
         Result         : Outcome_Code;
         Mark_Uncertain : Boolean;
         Mark_Fenced    : Boolean);

      entry Await_Result (Commit_Slot)
        (Generation : Interfaces.Unsigned_64;
         Receipt    : out Internal_Receipt;
         Arena      : out Transaction_Arena_Access;
         Result     : out Outcome_Code);

      procedure Install_Published
        (Batch      : in out Runtime_Batch;
         Head       : Head_Snapshot;
         Generation : Generation_Value;
         Result     : out Outcome_Code);

      procedure Snapshot
        (Head         : out Head_Snapshot;
         Generation   : out Generation_Value;
         Is_Uncertain : out Boolean;
         Is_Fenced    : out Boolean);

      procedure Lookup_At
        (Family          : Column_Family_ID;
         Item_Key        : Byte_Array;
         Snapshot_At     : Sequence_Number;
         Checkpoint_Base : State_Entry_Array_Access;
         Image           : out Shared_Image_Access;
         Value_Offset    : out Natural;
         Value_Length    : out Natural;
         Matched         : out Boolean;
         Result          : out Outcome_Code);

      procedure Scan_Source_Requirements
        (Family        : Column_Family_ID;
         Snapshot_At   : Sequence_Number;
         Checkpoint_Base : State_Entry_Array_Access;
         Extra_Count   : Natural;
         Source_Count  : out Natural;
         Maximum_Rows  : out Interfaces.Unsigned_32;
         Maximum_Bytes : out Interfaces.Unsigned_64;
         Result        : out Outcome_Code);

      procedure Copy_Scan_Sources
        (Family          : Column_Family_ID;
         Snapshot_At     : Sequence_Number;
         Checkpoint_Base : State_Entry_Array_Access;
         Sources         : not null Scan_Source_Array_Access;
         Captured        : out Natural;
         Result          : out Outcome_Code);

      procedure Lookup_Sequence
        (Family   : Column_Family_ID;
         Item_Key : Byte_Array;
         Sequence : out Sequence_Number;
         Result   : out Outcome_Code);

      procedure Family_Snapshot_Requirements
        (Family        : Column_Family_ID;
         Entry_Total   : out Natural;
         Payload_Bytes : out Natural;
         Result        : out Outcome_Code);

      procedure Copy_Family_Snapshot
        (Family     : Column_Family_ID;
         References : not null Snapshot_Entry_Reference_Array_Access;
         Result     : out Outcome_Code);

      procedure Family_Delta_Snapshot
        (Family        : Column_Family_ID;
         References    : Snapshot_Entry_Reference_Array_Access;
         Entry_Total   : out Natural;
         Payload_Bytes : out Natural;
         Result        : out Outcome_Code);

      procedure Checkpoint_Metadata
        (Base : out Manifests.Manifest; Identity_Total : out Natural; Result : out Outcome_Code);

      procedure Copy_Checkpoint_Identities
        (Value : not null LSM_Runtime.Checkpoint_Manifest_Access; Result : out Outcome_Code);

      procedure Find_Family
        (ID : Column_Family_ID; Configuration : out Column_Family_Configuration; Result : out Outcome_Code);

      procedure Find_Family
        (Name : Byte_Array; Configuration : out Column_Family_Configuration; Result : out Outcome_Code);

      procedure Validate_Family
        (Family : Column_Family; Configuration : out Column_Family_Configuration; Result : out Outcome_Code);

      procedure Validate_Transaction_Bounds
        (Mutation_Count : Natural; Payload_Bytes : Interfaces.Unsigned_64; Result : out Outcome_Code);

      procedure Transaction_Limits
        (Mutation_Limit : out Interfaces.Unsigned_32; Payload_Limit : out Interfaces.Unsigned_64);

      function Current_Incarnation return Engine_Incarnation;

      procedure Fence;
      procedure Drain_Queued_For_Resolution;
      procedure Set_Paused (Value : Boolean);
      function Queue_Depth return Natural;
      procedure Fail_Next_Install;
      procedure Request_Close;
      procedure Mark_Stopped;
      function History_Length return Natural;
      procedure History_Batch_Shape
        (Index             : Positive;
         Transaction_Total : out Natural;
         Mutation_Total    : out Natural;
         Result            : out Outcome_Code);
      procedure Copy_History_Batch
        (Index  : Positive;
         Batch  : in out Runtime_Batch;
         Result : out Outcome_Code);
      procedure Take_History_Batch (Index : Positive; Batch : out Runtime_Batch);
      entry Join;
      function Highest return Sequence_Number;
   private
      Slots             : Completion_Array;
      Queue_Order       : Interfaces.Unsigned_64 := 0;
      In_Use_Count      : Natural range 0 .. Maximum_Commit_Slots := 0;
      Queued_Count      : Natural range 0 .. Maximum_Commit_Slots := 0;
      In_Flight_Bytes   : Interfaces.Unsigned_64 := 0;
      Current_Head      : Head_Snapshot;
      Head_Generation   : Generation_Value;
      Current_Manifest  : Manifests.Manifest;
      Incarnation       : Engine_Incarnation := No_Incarnation;
      Live_State_Bytes  : Interfaces.Unsigned_64 := 0;
      Entries           : State_Entry_Array (1 .. Entry_Capacity);
      --  Preallocated projection scratch keeps potentially large allocation
      --  and Storage_Error outside protected operations.  Apply_Batch writes
      --  only this scratch until every final-state limit has passed.
      Projected_Entries : State_Entry_Array (1 .. Entry_Capacity);
      Entry_Count       : Natural := 0;
      Seen              : Seen_Transaction_Array (1 .. Seen_Capacity) := [others => Zero_Transaction_ID];
      Seen_Count        : Natural := 0;
      Used_Batches      : Used_Batch_ID_Array (1 .. History_Capacity) := [others => Zero_Identifier];
      History_Count     : Natural := 0;
      --  Retain exact decoded batch descriptors lazily with their already-owned
      --  immutable images. They are the post-checkpoint write authority used
      --  for snapshot conflict checks; no theoretical key table is allocated.
      History_Batches   : Runtime_Batch_Array (1 .. History_Capacity) := [others => (others => <>)];
      Reserved          : Reserved_Identity_Array (1 .. Reserved_Capacity) := [others => Zero_Identifier];
      Reserved_Count    : Natural := 0;
      --  Zero is the authenticated root/legacy replay boundary. A nonzero
      --  boundary comes only from the persisted checkpoint authority and makes
      --  older snapshots conservatively unverifiable.
      Retained_History_Boundary : Sequence_Number := 0;
      Uncertain         : Boolean := False;
      Fenced            : Boolean := False;
      Closing           : Boolean := False;
      Stopped           : Boolean := False;
      Paused            : Boolean := False;
      Fail_Install      : Boolean := False;
   end Coordinator;

   procedure Visit_Scan_Batch
     (Batch       : Runtime_Batch;
      Family      : Column_Family_ID;
      Snapshot_At : Sequence_Number;
      Authority   : Natural;
      Sources     : Scan_Source_Array_Access;
      Captured    : in out Natural;
      Result      : out Outcome_Code)
   is
      function Valid_Slice (Offset, Length : Natural) return Boolean is
         Image_Length : constant Natural :=
           (if Batch.Image = null then 0 else Flyology.Bytes.Length (Batch.Image.Data));
      begin
         return Batch.Image /= null and then Offset <= Image_Length and then Length <= Image_Length - Offset;
      end Valid_Slice;

      procedure Add_Source
        (Mutation : Runtime_Mutation; Version : Sequence_Number; Order : Positive) is
      begin
         if Captured = Natural'Last or else (Sources /= null and then Captured = Sources'Length) then
            Result := Capacity_Exceeded;
            return;
         end if;
         Captured := Captured + 1;
         if Sources /= null then
            Sources (Captured) :=
              (Key_Image             => Batch.Image,
               Key_Offset            => Mutation.Key_Offset,
               Key_Length            => Mutation.Key_Length,
               Authority             => Authority,
               Version               => Version,
               Order                 => Order,
               Operation             => Mutation.Operation,
               Selected_Image        => Batch.Image,
               Selected_Value_Offset => Mutation.Value_Offset,
               Selected_Value_Length => Mutation.Value_Length,
               others                => <>);
         end if;
      end Add_Source;
   begin
      if Batch.Image = null
        or else Batch.Transactions = null
        or else Batch.Mutations = null
        or else Batch.Transactions'First /= 1
        or else Batch.Mutations'First /= 1
        or else Batch.Transaction_Total = 0
        or else Batch.Mutation_Total = 0
        or else Batch.Transaction_Total > Batch.Transactions'Length
        or else Batch.Mutation_Total > Batch.Mutations'Length
      then
         Result := Corrupt;
         return;
      end if;
      for Mutation_Index in Positive range 1 .. Batch.Mutation_Total loop
         declare
            Mutation : Runtime_Mutation renames Batch.Mutations (Mutation_Index);
         begin
            if not Valid_Slice (Mutation.Key_Offset, Mutation.Key_Length)
              or else
                (Mutation.Operation = Put_Mutation
                 and then not Valid_Slice (Mutation.Value_Offset, Mutation.Value_Length))
            then
               Result := Corrupt;
               return;
            end if;
         end;
      end loop;
      for Transaction_Index in Positive range 1 .. Batch.Transaction_Total loop
         declare
            Transaction : Runtime_Transaction renames Batch.Transactions (Transaction_Index);
         begin
            if Transaction.Sequence = 0
              or else Transaction.Mutation_Count = 0
              or else Transaction.First_Mutation = 0
              or else Transaction.Mutation_Count > Batch.Mutation_Total
              or else
                Transaction.First_Mutation > Batch.Mutation_Total - Transaction.Mutation_Count + 1
            then
               Result := Corrupt;
               return;
            elsif Transaction.Sequence <= Snapshot_At then
               for Mutation_Index in Positive range
                 Transaction.First_Mutation
                 .. Transaction.First_Mutation + Transaction.Mutation_Count - 1
               loop
                  if Batch.Mutations (Mutation_Index).Family = Family then
                     Add_Source
                       (Batch.Mutations (Mutation_Index), Transaction.Sequence, Mutation_Index);
                     if Result /= Success then
                        return;
                     end if;
                  end if;
               end loop;
            end if;
         end;
      end loop;
      Result := Success;
   end Visit_Scan_Batch;

   procedure Visit_Scan_Checkpoint
     (Checkpoint_Base : State_Entry_Array_Access;
      Family          : Column_Family_ID;
      Sources         : Scan_Source_Array_Access;
      Captured        : in out Natural;
      Result          : out Outcome_Code)
   is
      function Valid_Slice
        (Source : not null Shared_Image_Access; Offset, Length : Natural) return Boolean
      is
         Image_Length : constant Natural := Flyology.Bytes.Length (Source.Data);
      begin
         return Offset <= Image_Length and then Length <= Image_Length - Offset;
      end Valid_Slice;
   begin
      if Checkpoint_Base /= null then
         for Index in Checkpoint_Base'Range loop
            if Checkpoint_Base (Index).Image = null
              or else
                not Valid_Slice
                      (Checkpoint_Base (Index).Image,
                       Checkpoint_Base (Index).Key_Offset,
                       Checkpoint_Base (Index).Key_Length)
              or else
                not Valid_Slice
                      (Checkpoint_Base (Index).Image,
                       Checkpoint_Base (Index).Value_Offset,
                       Checkpoint_Base (Index).Value_Length)
            then
               Result := Corrupt;
               return;
            elsif Checkpoint_Base (Index).Family = Family then
               if Captured = Natural'Last
                 or else (Sources /= null and then Captured = Sources'Length)
               then
                  Result := Capacity_Exceeded;
                  return;
               end if;
               Captured := Captured + 1;
               if Sources /= null then
                  Sources (Captured) :=
                    (Key_Image             => Checkpoint_Base (Index).Image,
                     Key_Offset            => Checkpoint_Base (Index).Key_Offset,
                     Key_Length            => Checkpoint_Base (Index).Key_Length,
                     Authority             => 1,
                     Version               => Checkpoint_Base (Index).Sequence,
                     Order                 => Index,
                     Operation             => Put_Mutation,
                     Selected_Image        => Checkpoint_Base (Index).Image,
                     Selected_Value_Offset => Checkpoint_Base (Index).Value_Offset,
                     Selected_Value_Length => Checkpoint_Base (Index).Value_Length,
                     others                => <>);
               end if;
            end if;
         end loop;
      end if;
      Result := Success;
   end Visit_Scan_Checkpoint;

   protected body Coordinator is

      procedure Initialize
        (Head       : Head_Snapshot;
         Generation : Generation_Value;
         Manifest   : Manifests.Manifest;
         History_Boundary : Sequence_Number;
         Stamp      : Engine_Incarnation) is
      begin
         Current_Head := Head;
         Head_Generation := Generation;
         Current_Manifest := Manifest;
         Retained_History_Boundary := History_Boundary;
         Incarnation := Stamp;
      end Initialize;

      function Same_History_Key
        (Candidate : Owned_Mutation;
         Batch     : Runtime_Batch;
         Mutation  : Runtime_Mutation) return Boolean
      is
      begin
         if Batch.Image = null
           or else Candidate.Family /= Mutation.Family
           or else Candidate.Key_Length /= Mutation.Key_Length
         then
            return False;
         elsif Candidate.Key_Length = 0 then
            return True;
         end if;
         for Offset in Natural range 0 .. Candidate.Key_Length - 1 loop
            if Flyology.Bytes.Element (Candidate.Payload, Offset + 1)
              /= Flyology.Bytes.Element (Batch.Image.Data, Mutation.Key_Offset + Offset + 1)
            then
               return False;
            end if;
         end loop;
         return True;
      end Same_History_Key;

      function Same_History_Key
        (Candidate : Owned_Point_Read; Batch : Runtime_Batch; Mutation : Runtime_Mutation) return Boolean is
      begin
         if Batch.Image = null
           or else Candidate.Family /= Mutation.Family
           or else Candidate.Key_Length /= Mutation.Key_Length
         then
            return False;
         elsif Candidate.Key_Length = 0 then
            return True;
         end if;
         for Offset in Natural range 0 .. Candidate.Key_Length - 1 loop
            if Flyology.Bytes.Element (Candidate.Key, Offset + 1)
              /= Flyology.Bytes.Element (Batch.Image.Data, Mutation.Key_Offset + Offset + 1)
            then
               return False;
            end if;
         end loop;
         return True;
      end Same_History_Key;

      function History_Key_Before_Bound
        (Batch      : Runtime_Batch;
         Mutation   : Runtime_Mutation;
         Bound      : Flyology.Bytes.Unbounded_Bytes;
         Bound_Size : Natural) return Boolean
      is
         Common : constant Natural := Natural'Min (Mutation.Key_Length, Bound_Size);
      begin
         if Batch.Image = null then
            return False;
         end if;
         if Common > 0 then
            for Offset in Natural range 0 .. Common - 1 loop
               declare
                  History_Byte : constant Ada.Streams.Stream_Element :=
                    Flyology.Bytes.Element (Batch.Image.Data, Mutation.Key_Offset + Offset + 1);
                  Bound_Byte   : constant Ada.Streams.Stream_Element :=
                    Flyology.Bytes.Element (Bound, Offset + 1);
               begin
                  if History_Byte < Bound_Byte then
                     return True;
                  elsif History_Byte > Bound_Byte then
                     return False;
                  end if;
               end;
            end loop;
         end if;
         return Mutation.Key_Length < Bound_Size;
      end History_Key_Before_Bound;

      function History_Key_In_Range
        (Candidate : Owned_Scan_Range; Batch : Runtime_Batch; Mutation : Runtime_Mutation) return Boolean
      is
      begin
         return Candidate.Family = Mutation.Family
           and then
             (not Candidate.Has_Lower
              or else not History_Key_Before_Bound
                            (Batch, Mutation, Candidate.Lower, Candidate.Lower_Length))
           and then
             (not Candidate.Has_Upper
              or else History_Key_Before_Bound
                        (Batch, Mutation, Candidate.Upper, Candidate.Upper_Length));
      end History_Key_In_Range;

      function Has_Transaction_Conflict
        (Arena       : Transaction_Arena_Access;
         Snapshot_At : Sequence_Number) return Boolean
      is
         Point : Owned_Point_Read_Access;
         Scan  : Owned_Scan_Range_Access;
      begin
         if Arena = null or else Snapshot_At < Retained_History_Boundary then
            return True;
         end if;
         for History_Index in Positive range 1 .. History_Count loop
            declare
               Batch : Runtime_Batch renames History_Batches (History_Index);
            begin
               if Batch.Image = null or else Batch.Transactions = null or else Batch.Mutations = null then
                  return True;
               end if;
               for Transaction of Batch.Transactions (1 .. Batch.Transaction_Total) loop
                  if Transaction.Sequence > Snapshot_At then
                     for Mutation_Index in
                       Positive
                         range Transaction.First_Mutation
                               .. Transaction.First_Mutation + Transaction.Mutation_Count - 1
                     loop
                        for Candidate_Index in Positive range 1 .. Arena.Count loop
                           if Same_History_Key
                                (Arena.Mutations (Candidate_Index),
                                 Batch,
                                 Batch.Mutations (Mutation_Index))
                           then
                              return True;
                           end if;
                        end loop;
                        Point := Arena.Point_Reads;
                        while Point /= null loop
                           if Same_History_Key (Point.all, Batch, Batch.Mutations (Mutation_Index)) then
                              return True;
                           end if;
                           Point := Point.Next;
                        end loop;
                        Scan := Arena.Scan_Ranges;
                        while Scan /= null loop
                           if History_Key_In_Range (Scan.all, Batch, Batch.Mutations (Mutation_Index)) then
                              return True;
                           end if;
                           Scan := Scan.Next;
                        end loop;
                     end loop;
                  end if;
               end loop;
            end;
         end loop;
         return False;
      end Has_Transaction_Conflict;

      procedure Apply_Batch
        (Batch               : in out Runtime_Batch;
         Identities_Reserved : Boolean;
         Install             : Boolean;
         Result              : out Outcome_Code)
      is
         --  Preserve the admitted immutable batch identity while Batch may be
         --  moved/released during installation; this is derived ownership state.
         Batch_ID              : constant Identifier := Batch.Batch_ID;
         Additional_Identities : Natural := Batch.Transaction_Total;
         Candidate_Count       : Natural range 0 .. Entry_Capacity := 0;
         Candidate_Bytes       : Interfaces.Unsigned_64 := 0;
         Batch_Payload         : Interfaces.Unsigned_64 := 0;
         Identity_Found        : Boolean;
         --  Certainty classification derives from admission state: reserved
         --  caller work exhausts declared capacity; recovered malformed work is
         --  corruption. This is semantic policy, not an arbitrary error default.
         Policy_Failure        : constant Outcome_Code :=
           (if Identities_Reserved then Capacity_Exceeded else Corrupt);

         function Same_Bytes
           (Left_Image  : not null Shared_Image_Access;
            Left_Start  : Natural;
            Right_Image : not null Shared_Image_Access;
            Right_Start : Natural;
            Length      : Natural) return Boolean is
         begin
            for Offset in Natural range 0 .. Length - 1 loop
               if Flyology.Bytes.Element (Left_Image.Data, Left_Start + Offset + 1)
                 /= Flyology.Bytes.Element (Right_Image.Data, Right_Start + Offset + 1)
               then
                  return False;
               end if;
            end loop;
            return True;
         end Same_Bytes;

         function Same_Key (Left, Right : Runtime_Mutation) return Boolean
         is (Left.Family = Right.Family
             and then Left.Key_Length = Right.Key_Length
             and then Same_Bytes
                        (Batch.Image, Left.Key_Offset, Batch.Image, Right.Key_Offset, Left.Key_Length));

         function Matches_Entry (Mutation : Runtime_Mutation; State_Item : State_Entry) return Boolean
         is (Mutation.Family = State_Item.Family
             and then Mutation.Key_Length = State_Item.Key_Length
             and then State_Item.Image /= null
             and then Same_Bytes
                        (Batch.Image,
                         Mutation.Key_Offset,
                         State_Item.Image,
                         State_Item.Key_Offset,
                         Mutation.Key_Length));

         function Last_For_Key (Index : Positive) return Boolean is
         begin
            for Later in Positive range Index + 1 .. Batch.Mutation_Total loop
               if Same_Key (Batch.Mutations (Index), Batch.Mutations (Later)) then
                  return False;
               end if;
            end loop;
            return True;
         end Last_For_Key;

         function Existing_Key (Mutation : Runtime_Mutation) return Boolean is
         begin
            for Existing in Positive range 1 .. Entry_Count loop
               if Matches_Entry (Mutation, Entries (Existing)) then
                  return True;
               end if;
            end loop;
            return False;
         end Existing_Key;

         function Sequence_For_Mutation (Index : Positive) return Sequence_Number is
         begin
            for Transaction of Batch.Transactions (1 .. Batch.Transaction_Total) loop
               if Index >= Transaction.First_Mutation
                 and then Index - Transaction.First_Mutation < Transaction.Mutation_Count
               then
                  return Transaction.Sequence;
               end if;
            end loop;
            return 0;
         end Sequence_For_Mutation;

         procedure Add_Bytes (Amount : Interfaces.Unsigned_64; Valid : out Boolean) is
         begin
            Valid := Candidate_Bytes <= Interfaces.Unsigned_64'Last - Amount;
            if Valid then
               Candidate_Bytes := Candidate_Bytes + Amount;
            end if;
         end Add_Bytes;
      begin
         if Batch.Image = null
           or else Batch.Transactions = null
           or else Batch.Mutations = null
           or else Batch.Transaction_Total = 0
           or else Interfaces.Unsigned_64 (Batch.Transaction_Total)
                   > Interfaces.Unsigned_64 (Current_Manifest.Limits.Maximum_Transactions_Per_Batch)
           or else Interfaces.Unsigned_64 (Batch.Mutation_Total)
                   > Interfaces.Unsigned_64 (Current_Manifest.Limits.Maximum_Mutations_Per_Batch)
         then
            Result := Policy_Failure;
            return;
         elsif Batch.Transaction_Total /= 1
           or else Identifier (Batch.Transactions (1).Transaction_ID) /= Batch_ID
         then
            Additional_Identities := Additional_Identities + 1;
         end if;
         if History_Count = History_Capacity
           or else Batch.Transaction_Total > Seen_Capacity - Seen_Count
           or else (not Identities_Reserved
                    and then Additional_Identities > Reserved_Capacity - Reserved_Count)
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Existing in Positive range 1 .. History_Count loop
            if Used_Batches (Existing) = Batch_ID then
               Result := Corrupt;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. Seen_Count loop
            if Identifier (Seen (Existing)) = Batch_ID then
               Result := Corrupt;
               return;
            end if;
         end loop;
         Identity_Found := False;
         for Existing in Positive range 1 .. Reserved_Count loop
            Identity_Found := Identity_Found or else Reserved (Existing) = Batch_ID;
         end loop;
         if Identity_Found /= Identities_Reserved then
            Result := Corrupt;
            return;
         end if;

         for Transaction_Index in Positive range 1 .. Batch.Transaction_Total loop
            declare
               Transaction         : Runtime_Transaction renames Batch.Transactions (Transaction_Index);
               Transaction_Payload : Interfaces.Unsigned_64 := 0;
            begin
               if Transaction.Mutation_Count = 0
                 or else Transaction.First_Mutation = 0
                 or else Transaction.First_Mutation > Batch.Mutation_Total - Transaction.Mutation_Count + 1
                 or else Interfaces.Unsigned_64 (Transaction.Mutation_Count)
                         > Interfaces.Unsigned_64 (Current_Manifest.Limits.Maximum_Mutations_Per_Transaction)
               then
                  Result := Policy_Failure;
                  return;
               end if;
               for Mutation_Index in
                 Positive
                   range Transaction.First_Mutation
                         .. Transaction.First_Mutation + Transaction.Mutation_Count - 1
               loop
                  declare
                     Mutation : Runtime_Mutation renames Batch.Mutations (Mutation_Index);
                     --  Derived logical payload contribution from the exact
                     --  key/value lengths decoded for this mutation.
                     Amount   : constant Interfaces.Unsigned_64 :=
                       Interfaces.Unsigned_64 (Mutation.Key_Length)
                       + Interfaces.Unsigned_64 (Mutation.Value_Length);
                  begin
                     if Transaction_Payload > Interfaces.Unsigned_64'Last - Amount then
                        Result := Policy_Failure;
                        return;
                     end if;
                     Transaction_Payload := Transaction_Payload + Amount;
                  end;
               end loop;
               if Transaction_Payload > Current_Manifest.Limits.Maximum_Transaction_Payload_Bytes
                 or else Batch_Payload
                         > Current_Manifest.Limits.Maximum_Batch_Payload_Bytes - Transaction_Payload
               then
                  Result := Policy_Failure;
                  return;
               end if;
               Batch_Payload := Batch_Payload + Transaction_Payload;
               if Batch.Transaction_Total > 1 and then Identifier (Transaction.Transaction_ID) = Batch_ID then
                  Result := Corrupt;
                  return;
               end if;
               for Existing in Positive range 1 .. Seen_Count loop
                  if Seen (Existing) = Transaction.Transaction_ID then
                     Result := Corrupt;
                     return;
                  end if;
               end loop;
               for Existing in Positive range 1 .. History_Count loop
                  if Used_Batches (Existing) = Identifier (Transaction.Transaction_ID) then
                     Result := Corrupt;
                     return;
                  end if;
               end loop;
               Identity_Found := False;
               for Existing in Positive range 1 .. Reserved_Count loop
                  Identity_Found :=
                    Identity_Found or else Reserved (Existing) = Identifier (Transaction.Transaction_ID);
               end loop;
               if Identity_Found /= Identities_Reserved then
                  Result := Corrupt;
                  return;
               end if;
            end;
         end loop;

         for Mutation_Index in Positive range 1 .. Batch.Mutation_Total loop
            declare
               Mutation : Runtime_Mutation renames Batch.Mutations (Mutation_Index);
               Family   : Manifests.Column_Family_Configuration;
               Found    : Boolean := False;
            begin
               for Family_Index in Manifests.Family_Slot range 1 .. Current_Manifest.Family_Total loop
                  if Current_Manifest.Families (Family_Index).ID = Interfaces.Unsigned_32 (Mutation.Family)
                  then
                     Family := Current_Manifest.Families (Family_Index);
                     Found := True;
                     exit;
                  end if;
               end loop;
               if not Found
                 or else Interfaces.Unsigned_64 (Mutation.Key_Length) > Family.Max_Key_Bytes
                 or else Interfaces.Unsigned_64 (Mutation.Value_Length) > Family.Max_Value_Bytes
               then
                  Result := Policy_Failure;
                  return;
               end if;
            end;
         end loop;

         for Existing in Positive range 1 .. Entry_Count loop
            declare
               Last_Mutation : Natural := 0;
               Valid         : Boolean;
            begin
               for Index in Positive range 1 .. Batch.Mutation_Total loop
                  if Matches_Entry (Batch.Mutations (Index), Entries (Existing)) then
                     Last_Mutation := Index;
                  end if;
               end loop;
               if Last_Mutation = 0 then
                  Add_Bytes
                    (Interfaces.Unsigned_64 (Entries (Existing).Key_Length)
                     + Interfaces.Unsigned_64 (Entries (Existing).Value_Length),
                     Valid);
                  if not Valid then
                     Result := Policy_Failure;
                     return;
                  end if;
                  Candidate_Count := Candidate_Count + 1;
                  Projected_Entries (Candidate_Count) := Entries (Existing);
               elsif Batch.Mutations (Last_Mutation).Operation = Put_Mutation then
                  declare
                     Mutation : Runtime_Mutation renames Batch.Mutations (Last_Mutation);
                     Sequence : constant Sequence_Number := Sequence_For_Mutation (Last_Mutation);
                  begin
                     if Sequence = 0 then
                        Result := Policy_Failure;
                        return;
                     end if;
                     Add_Bytes
                       (Interfaces.Unsigned_64 (Mutation.Key_Length)
                        + Interfaces.Unsigned_64 (Mutation.Value_Length),
                        Valid);
                     if not Valid then
                        Result := Policy_Failure;
                        return;
                     end if;
                     Candidate_Count := Candidate_Count + 1;
                     Projected_Entries (Candidate_Count) :=
                       (Family       => Mutation.Family,
                        Image        => Batch.Image,
                        Key_Offset   => Mutation.Key_Offset,
                        Key_Length   => Mutation.Key_Length,
                        Value_Offset => Mutation.Value_Offset,
                        Value_Length => Mutation.Value_Length,
                        Sequence     => Sequence);
                  end;
               end if;
            end;
         end loop;

         for Index in Positive range 1 .. Batch.Mutation_Total loop
            if Last_For_Key (Index)
              and then Batch.Mutations (Index).Operation = Put_Mutation
              and then not Existing_Key (Batch.Mutations (Index))
            then
               declare
                  Mutation : Runtime_Mutation renames Batch.Mutations (Index);
                  Valid    : Boolean;
                  Sequence : constant Sequence_Number := Sequence_For_Mutation (Index);
               begin
                  if Sequence = 0 then
                     Result := Policy_Failure;
                     return;
                  elsif Candidate_Count = Entry_Capacity then
                     Result := Policy_Failure;
                     return;
                  end if;
                  Add_Bytes
                    (Interfaces.Unsigned_64 (Mutation.Key_Length)
                     + Interfaces.Unsigned_64 (Mutation.Value_Length),
                     Valid);
                  if not Valid then
                     Result := Policy_Failure;
                     return;
                  end if;
                  Candidate_Count := Candidate_Count + 1;
                  Projected_Entries (Candidate_Count) :=
                    (Family       => Mutation.Family,
                     Image        => Batch.Image,
                     Key_Offset   => Mutation.Key_Offset,
                     Key_Length   => Mutation.Key_Length,
                     Value_Offset => Mutation.Value_Offset,
                     Value_Length => Mutation.Value_Length,
                     Sequence     => Sequence);
               end;
            end if;
         end loop;
         if Interfaces.Unsigned_64 (Candidate_Count)
           > Interfaces.Unsigned_64 (Current_Manifest.Limits.Maximum_Live_Entries)
           or else Candidate_Bytes > Current_Manifest.Limits.Maximum_Live_State_Bytes
         then
            Result := Policy_Failure;
            return;
         end if;
         if Install then
            Entries := Projected_Entries;
            Entry_Count := Candidate_Count;
            Live_State_Bytes := Candidate_Bytes;
            if not Identities_Reserved and then Additional_Identities > Batch.Transaction_Total then
               Reserved_Count := Reserved_Count + 1;
               Reserved (Reserved_Count) := Batch_ID;
            end if;
            for Transaction_Index in Positive range 1 .. Batch.Transaction_Total loop
               Seen_Count := Seen_Count + 1;
               Seen (Seen_Count) := Batch.Transactions (Transaction_Index).Transaction_ID;
               if not Identities_Reserved then
                  Reserved_Count := Reserved_Count + 1;
                  Reserved (Reserved_Count) :=
                    Identifier (Batch.Transactions (Transaction_Index).Transaction_ID);
               end if;
            end loop;
            History_Count := History_Count + 1;
            Used_Batches (History_Count) := Batch_ID;
            --  Move the exact lazily allocated descriptor and image into the
            --  retained suffix. Entry views keep borrowing the same image.
            History_Batches (History_Count) := Batch;
            Batch := (others => <>);
         end if;
         Result := Success;
      end Apply_Batch;

      procedure Recover_Batch (Batch : in out Runtime_Batch; Result : out Outcome_Code) is
      begin
         Apply_Batch (Batch, False, True, Result);
      end Recover_Batch;

      procedure Recover_Checkpoint
        (Plan       : Checkpoint_Plan;
         Images     : Checkpoint_Image_Array_Access;
         Base       : State_Entry_Array_Access;
         Live_Count : out Natural;
         Result     : out Outcome_Code)
      is
         Candidate_Count : Natural range 0 .. Entry_Capacity := 0;
         Candidate_Bytes : Interfaces.Unsigned_64 := 0;

         function Valid_Slice
           (Image : not null Shared_Image_Access; Offset, Length : Natural) return Boolean
         is
            Image_Length : constant Natural := Flyology.Bytes.Length (Image.Data);
         begin
            return Offset <= Image_Length and then Length <= Image_Length - Offset;
         end Valid_Slice;

         function Same_Key
           (Left : State_Entry; Right_Image : not null Shared_Image_Access;
            Right : LSM_Runtime.SST_Entry) return Boolean
         is
         begin
            if Left.Key_Length /= Right.Key_Byte_Total then
               return False;
            end if;
            for Offset in Natural range 0 .. Left.Key_Length - 1 loop
               if Flyology.Bytes.Element (Left.Image.Data, Left.Key_Offset + Offset + 1)
                 /= Flyology.Bytes.Element (Right_Image.Data, Right.Key_Offset + Offset)
               then
                  return False;
               end if;
            end loop;
            return True;
         end Same_Key;

         function Find_Key
           (Family : Column_Family_ID; Image : not null Shared_Image_Access;
            Item : LSM_Runtime.SST_Entry) return Natural
         is
         begin
            for Index in Positive range 1 .. Candidate_Count loop
               if Projected_Entries (Index).Family = Family
                 and then Same_Key (Projected_Entries (Index), Image, Item)
               then
                  return Index;
               end if;
            end loop;
            return 0;
         end Find_Key;

         procedure Remove_At (Index : Positive; Valid : out Boolean) is
            Amount : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Projected_Entries (Index).Key_Length)
              + Interfaces.Unsigned_64 (Projected_Entries (Index).Value_Length);
         begin
            if Candidate_Bytes < Amount then
               Valid := False;
               return;
            end if;
            Candidate_Bytes := Candidate_Bytes - Amount;
            for Position in Index .. Candidate_Count - 1 loop
               Projected_Entries (Position) := Projected_Entries (Position + 1);
            end loop;
            Candidate_Count := Candidate_Count - 1;
            Valid := True;
         end Remove_At;

         procedure Add_Put
           (Family : Column_Family_ID; Image : not null Shared_Image_Access;
            Item : LSM_Runtime.SST_Entry; Valid : out Boolean)
         is
            Amount : constant Interfaces.Unsigned_64 :=
              Interfaces.Unsigned_64 (Item.Key_Byte_Total)
              + Interfaces.Unsigned_64 (Item.Value_Byte_Total);
         begin
            if Candidate_Count = Entry_Capacity
              or else Candidate_Bytes > Interfaces.Unsigned_64'Last - Amount
            then
               Valid := False;
               return;
            end if;
            Candidate_Count := Candidate_Count + 1;
            Candidate_Bytes := Candidate_Bytes + Amount;
            Projected_Entries (Candidate_Count) :=
              (Family       => Family,
               Image        => Image,
               Key_Offset   => Item.Key_Offset - 1,
               Key_Length   => Item.Key_Byte_Total,
               Value_Offset => Item.Value_Offset - 1,
               Value_Length => Item.Value_Byte_Total,
               Sequence     => Sequence_Number (Item.Sequence));
            Valid := True;
         end Add_Put;
      begin
         Live_Count := 0;
         if Plan.Manifest = null
           or else Plan.Manifest.Replay_Boundary = 0
           or else Entry_Count /= 0
           or else Seen_Count /= 0
           or else Reserved_Count /= 0
           or else History_Count /= 0
           or else Plan.Manifest.Identity_Total > Reserved_Capacity
         then
            Result := Corrupt;
            return;
         end if;
         if Plan.Activation_Ready then
            if (Base = null) /= (Images = null)
              or else (Base /= null and then Base'Length /= Images'Length)
              or else (Base /= null and then Base'Length > Entry_Capacity)
            then
               Result := Corrupt;
               return;
            end if;
            if Base /= null then
               for Index in Base'Range loop
                  declare
                     Item   : State_Entry renames Base (Index);
                     Amount : constant Interfaces.Unsigned_64 :=
                       Interfaces.Unsigned_64 (Item.Key_Length)
                       + Interfaces.Unsigned_64 (Item.Value_Length);
                  begin
                     if Item.Image = null
                       or else Images (Index) /= Item.Image
                       or else Item.Sequence = 0
                       or else Interfaces.Unsigned_64 (Item.Sequence) > Plan.Manifest.Replay_Boundary
                       or else not Valid_Slice (Item.Image, Item.Key_Offset, Item.Key_Length)
                       or else not Valid_Slice (Item.Image, Item.Value_Offset, Item.Value_Length)
                       or else Candidate_Bytes > Interfaces.Unsigned_64'Last - Amount
                     then
                        Result := Corrupt;
                        return;
                     end if;
                     Candidate_Count := Candidate_Count + 1;
                     Candidate_Bytes := Candidate_Bytes + Amount;
                     Projected_Entries (Candidate_Count) := Item;
                  end;
               end loop;
            end if;
         else
            if (Plan.Manifest.Run_Total = 0
                and then (Plan.Recovered_SSTs /= null or else Images /= null or else Base /= null))
              or else
                (Plan.Manifest.Run_Total > 0
                 and then
                   (Plan.Recovered_SSTs = null
                    or else Images = null
                    or else Base = null
                    or else Plan.Recovered_SSTs'Length /= Plan.Manifest.Run_Total
                    or else Images'Length /= Plan.Manifest.Run_Total))
            then
               Result := Corrupt;
               return;
            end if;
            for Family_Index in Plan.Manifest.Families'Range loop
               declare
                  Family : LSM_Runtime.Family_LSM_State renames Plan.Manifest.Families (Family_Index);
                  Family_ID : constant Column_Family_ID :=
                    Column_Family_ID (Plan.Manifest.Base.Families (Family_Index).ID);
               begin
                  if Family.Run_Total > 0 then
                     for Run_Index in
                       Positive range Family.First_Run .. Family.First_Run + Family.Run_Total - 1
                     loop
                        declare
                           SST   : LSM_Runtime.SST_Access renames Plan.Recovered_SSTs (Run_Index);
                           Image : Shared_Image_Access renames Images (Run_Index);
                           Valid : Boolean;

                           function Same_SST_Key
                             (Left, Right : LSM_Runtime.SST_Entry) return Boolean
                           is
                           begin
                              if Left.Key_Byte_Total /= Right.Key_Byte_Total then
                                 return False;
                              end if;
                              if Left.Key_Byte_Total > 0 then
                                 for Offset in Natural range 0 .. Left.Key_Byte_Total - 1 loop
                                    if Flyology.Bytes.Element
                                         (Image.Data, Left.Key_Offset + Offset)
                                      /= Flyology.Bytes.Element
                                           (Image.Data, Right.Key_Offset + Offset)
                                    then
                                       return False;
                                    end if;
                                 end loop;
                              end if;
                              return True;
                           end Same_SST_Key;

                           function Latest_For_Key (Index : Positive) return Boolean is
                           begin
                              return
                                Index = SST.Entries'First
                                or else not Same_SST_Key
                                              (SST.Entries (Index - 1), SST.Entries (Index));
                           end Latest_For_Key;
                        begin
                           if SST = null
                             or else Image = null
                             or else not LSM_Runtime.Descriptor_Matches
                                          (SST.all,
                                           Plan.Manifest.Base.Database_ID,
                                           Plan.Manifest.Base.Families (Family_Index).ID,
                                           Plan.Manifest.Runs (Run_Index))
                             or else Flyology.Bytes.Length (Image.Data) /= SST.Payload_Byte_Total
                           then
                              Result := Corrupt;
                              return;
                           end if;
                           for Item of SST.Entries loop
                              if Item.Sequence = 0
                                or else Item.Sequence > Plan.Manifest.Replay_Boundary
                                or else Item.Operation not in
                                  LSM_Runtime.LSM.Put_Operation | LSM_Runtime.LSM.Delete_Operation
                                or else not Valid_Slice (Image, Item.Key_Offset - 1, Item.Key_Byte_Total)
                                or else
                                  (Item.Operation = LSM_Runtime.LSM.Put_Operation
                                   and then
                                     not Valid_Slice
                                           (Image, Item.Value_Offset - 1, Item.Value_Byte_Total))
                              then
                                 Result := Corrupt;
                                 return;
                              end if;
                           end loop;

                           --  Each SST is ordered by key and descending
                           --  sequence, and a merged SST deliberately retains
                           --  older versions. Only its first entry for a key
                           --  contributes to recovered live state. Apply that
                           --  latest operation in three capacity-safe passes:
                           --  delete existing keys, replace existing puts,
                           --  then add absent puts.
                           for Item_Index in SST.Entries'Range loop
                              declare
                                 Item : LSM_Runtime.SST_Entry renames SST.Entries (Item_Index);
                              begin
                                 if Latest_For_Key (Item_Index)
                                   and then Item.Operation = LSM_Runtime.LSM.Delete_Operation
                                 then
                                    declare
                                       Existing : constant Natural := Find_Key (Family_ID, Image, Item);
                                    begin
                                       if Existing > 0 then
                                          Remove_At (Existing, Valid);
                                          if not Valid then
                                             Result := Corrupt;
                                             return;
                                          end if;
                                       end if;
                                    end;
                                 end if;
                              end;
                           end loop;
                           for Item_Index in SST.Entries'Range loop
                              declare
                                 Item : LSM_Runtime.SST_Entry renames SST.Entries (Item_Index);
                              begin
                                 if Latest_For_Key (Item_Index)
                                   and then Item.Operation = LSM_Runtime.LSM.Put_Operation
                                 then
                                    declare
                                       Existing : constant Natural := Find_Key (Family_ID, Image, Item);
                                    begin
                                       if Existing > 0 then
                                          Remove_At (Existing, Valid);
                                          if not Valid then
                                             Result := Corrupt;
                                             return;
                                          end if;
                                          Add_Put (Family_ID, Image, Item, Valid);
                                          if not Valid then
                                             Result := Corrupt;
                                             return;
                                          end if;
                                       end if;
                                    end;
                                 end if;
                              end;
                           end loop;
                           for Item_Index in SST.Entries'Range loop
                              declare
                                 Item : LSM_Runtime.SST_Entry renames SST.Entries (Item_Index);
                              begin
                                 if Latest_For_Key (Item_Index)
                                   and then Item.Operation = LSM_Runtime.LSM.Put_Operation
                                   and then Find_Key (Family_ID, Image, Item) = 0
                                 then
                                    Add_Put (Family_ID, Image, Item, Valid);
                                    if not Valid then
                                       Result := Corrupt;
                                       return;
                                    end if;
                                 end if;
                              end;
                           end loop;
                        end;
                     end loop;
                  end if;
               end;
            end loop;
            if Candidate_Count > 0 then
               if Base = null or else Candidate_Count > Base'Length then
                  Result := Corrupt;
                  return;
               end if;
               Base (1 .. Candidate_Count) := Projected_Entries (1 .. Candidate_Count);
            end if;
         end if;
         if Interfaces.Unsigned_64 (Candidate_Count)
           > Interfaces.Unsigned_64 (Current_Manifest.Limits.Maximum_Live_Entries)
           or else Candidate_Bytes > Current_Manifest.Limits.Maximum_Live_State_Bytes
         then
            Result := Corrupt;
            return;
         end if;
         Entries := Projected_Entries;
         Entry_Count := Candidate_Count;
         Live_State_Bytes := Candidate_Bytes;
         Reserved_Count := Plan.Manifest.Identity_Total;
         for Index in Positive range 1 .. Reserved_Count loop
            Reserved (Index) := To_Identifier (Plan.Manifest.Identities (Index));
         end loop;
         Live_Count := Candidate_Count;
         Result := Success;
      end Recover_Checkpoint;

      procedure Transaction_Available (Transaction_ID : Transaction_Identifier; Result : out Outcome_Code) is
      begin
         if Closing then
            Result := Invalid_State;
            return;
         elsif Fenced then
            Result := Stale_Writer;
            return;
         elsif Stopped then
            Result := Storage_Failure;
            return;
         elsif Uncertain then
            Result := Outcome_Unknown;
            return;
         end if;
         for Existing in Positive range 1 .. Seen_Count loop
            if Seen (Existing) = Transaction_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. History_Count loop
            if Used_Batches (Existing) = Identifier (Transaction_ID) then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. Reserved_Count loop
            if Reserved (Existing) = Identifier (Transaction_ID) then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Index in Commit_Slot loop
            if Slots (Index).State /= Free
              and then (Slots (Index).Work.Transaction_ID = Transaction_ID
                        or else Slots (Index).Work.Batch_ID = Identifier (Transaction_ID))
            then
               Result := Conflict;
               return;
            end if;
         end loop;
         Result := Success;
      end Transaction_Available;

      procedure Admit
        (Txn      : in out Transaction;
         Deadline : Ada.Real_Time.Time;
         Token    : access Flyology.Cancellation.Token;
         Slot     : out Slot_Token;
         Result   : out Outcome_Code)
      is
         Selected           : Commit_Slot := Commit_Slot'First;
         --  Singleton commits deliberately reuse the caller transaction ID as
         --  immutable batch identity; this enforces one nonreuse namespace.
         Candidate_Batch_ID : constant Identifier := Identifier (Txn.Transaction_ID);
      begin
         Slot := (others => <>);
         if Closing then
            Result := Invalid_State;
            return;
         elsif Fenced then
            Result := Stale_Writer;
            return;
         elsif Stopped then
            Result := Storage_Failure;
            return;
         elsif Uncertain then
            Result := Outcome_Unknown;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            return;
         elsif Current_Manifest.Limits.Maximum_Transactions_Per_Batch < 1
           or else Interfaces.Unsigned_32 (Mutation_Count (Txn))
                   > Current_Manifest.Limits.Maximum_Mutations_Per_Batch
           or else Payload_Bytes (Txn) > Current_Manifest.Limits.Maximum_Batch_Payload_Bytes
         then
            Result := Capacity_Exceeded;
            return;
         elsif In_Use_Count = Maximum_Commit_Slots
           or else Payload_Bytes (Txn) > Current_Manifest.Limits.Maximum_Batch_Payload_Bytes
           or else In_Flight_Bytes > Current_Manifest.Limits.Maximum_Batch_Payload_Bytes - Payload_Bytes (Txn)
           or else History_Count = History_Capacity
           or else Interfaces.Unsigned_32 (History_Count) = Current_Manifest.Limits.Maximum_Batch_History
           or else Seen_Count = Seen_Capacity
           or else Reserved_Count = Reserved_Capacity
         then
            Result := Capacity_Exceeded;
            return;
         elsif Has_Transaction_Conflict (Txn.Owner.Arena, Txn.Snapshot_At) then
            Result := Conflict;
            return;
         end if;
         for Existing in Positive range 1 .. Seen_Count loop
            if Seen (Existing) = Txn.Transaction_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. History_Count loop
            if Used_Batches (Existing) = Candidate_Batch_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Index in Commit_Slot loop
            if Slots (Index).State /= Free
              and then (Slots (Index).Work.Transaction_ID = Txn.Transaction_ID
                        or else Slots (Index).Work.Batch_ID = Candidate_Batch_ID)
            then
               Result := Conflict;
               return;
            elsif Slots (Index).State = Free then
               Selected := Index;
            end if;
         end loop;
         for Existing in Positive range 1 .. Reserved_Count loop
            if Reserved (Existing) = Candidate_Batch_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         if Queue_Order = Interfaces.Unsigned_64'Last
           or else Slots (Selected).Generation = Interfaces.Unsigned_64'Last
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         Reserved_Count := Reserved_Count + 1;
         Reserved (Reserved_Count) := Candidate_Batch_ID;
         Queue_Order := Queue_Order + 1;
         Slots (Selected).Generation := Slots (Selected).Generation + 1;
         Slots (Selected).Order := Queue_Order;
         Slots (Selected).Work.Transaction_ID := Txn.Transaction_ID;
         Slots (Selected).Work.Snapshot_At := Txn.Snapshot_At;
         Slots (Selected).Work.Payload_Length := Payload_Bytes (Txn);
         Slots (Selected).Work.Arena := Txn.Owner.Arena;
         Txn.Owner.Arena := null;
         Slots (Selected).Work.Deadline := Deadline;
         Slots (Selected).Work.Batch_ID := Candidate_Batch_ID;
         Slots (Selected).Work.Group_ID := Queue_Order;
         Slots (Selected).Work.Group_Member := Commit_Slot'First;
         Slots (Selected).Receipt := (others => <>);
         Slots (Selected).Receipt.Transaction_ID := Txn.Transaction_ID;
         Slots (Selected).Receipt.Batch_ID := Candidate_Batch_ID;
         Slots (Selected).Receipt.Expected_Head := Current_Head;
         Slots (Selected).State := Queued;
         In_Use_Count := In_Use_Count + 1;
         Queued_Count := Queued_Count + 1;
         In_Flight_Bytes := In_Flight_Bytes + Payload_Bytes (Slots (Selected).Work);
         Slot := (Index => Selected, Generation => Slots (Selected).Generation);
         Result := Success;
      end Admit;

      procedure Admit_Group
        (Transactions : in out Transaction_Array;
         Batch_ID     : Identifier;
         Deadline     : Ada.Real_Time.Time;
         Token        : access Flyology.Cancellation.Token;
         Tokens       : out Token_Group;
         Count        : out Group_Count;
         Result       : out Outcome_Code)
      is
         Total_Bytes     : Interfaces.Unsigned_64 := 0;
         Total_Mutations : Natural := 0;
         Selected        : Commit_Slot;
      begin
         Tokens := [others => <>];
         Count := 0;
         if Closing then
            Result := Invalid_State;
            return;
         elsif Fenced then
            Result := Stale_Writer;
            return;
         elsif Stopped then
            Result := Storage_Failure;
            return;
         elsif Uncertain then
            Result := Outcome_Unknown;
            return;
         elsif Transactions'Length < 2 then
            Result := Invalid_State;
            return;
         elsif Transactions'Length > Maximum_Group_Transactions then
            Result := Capacity_Exceeded;
            return;
         elsif Interfaces.Unsigned_32 (Transactions'Length)
           > Current_Manifest.Limits.Maximum_Transactions_Per_Batch
         then
            Result := Capacity_Exceeded;
            return;
         elsif Is_Zero (Batch_ID) then
            Result := Invalid_State;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            return;
         elsif In_Use_Count > Maximum_Commit_Slots - Transactions'Length then
            Result := Capacity_Exceeded;
            return;
         elsif History_Count = History_Capacity
           or else Interfaces.Unsigned_32 (History_Count) = Current_Manifest.Limits.Maximum_Batch_History
           or else Transactions'Length > Seen_Capacity - Seen_Count
           or else Transactions'Length + 1 > Reserved_Capacity - Reserved_Count
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Existing in Positive range 1 .. History_Count loop
            if Used_Batches (Existing) = Batch_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Index in Commit_Slot loop
            if Slots (Index).State /= Free
              and then (Slots (Index).Work.Batch_ID = Batch_ID
                        or else Identifier (Slots (Index).Work.Transaction_ID) = Batch_ID)
            then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. Reserved_Count loop
            if Reserved (Existing) = Batch_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Offset in Natural range 0 .. Transactions'Length - 1 loop
            declare
               Item : Transaction renames Transactions (Transactions'First + Offset);
            begin
               if not Item.Active or else Mutation_Count (Item) = 0 then
                  Result := Invalid_State;
                  return;
               elsif Identifier (Item.Transaction_ID) = Batch_ID then
                  Result := Conflict;
                  return;
               elsif Total_Bytes > Interfaces.Unsigned_64'Last - Payload_Bytes (Item)
                 or else Total_Mutations > Natural'Last - Mutation_Count (Item)
               then
                  Result := Capacity_Exceeded;
                  return;
               end if;
               Total_Bytes := Total_Bytes + Payload_Bytes (Item);
               Total_Mutations := Total_Mutations + Mutation_Count (Item);
               for Existing in Positive range 1 .. Seen_Count loop
                  if Seen (Existing) = Item.Transaction_ID then
                     Result := Conflict;
                     return;
                  end if;
               end loop;
               for Existing in Positive range 1 .. History_Count loop
                  if Used_Batches (Existing) = Identifier (Item.Transaction_ID) then
                     Result := Conflict;
                     return;
                  end if;
               end loop;
               for Existing in Positive range 1 .. Reserved_Count loop
                  if Reserved (Existing) = Identifier (Item.Transaction_ID) then
                     Result := Conflict;
                     return;
                  end if;
               end loop;
               for Index in Commit_Slot loop
                  if Slots (Index).State /= Free
                    and then (Slots (Index).Work.Transaction_ID = Item.Transaction_ID
                              or else Slots (Index).Work.Batch_ID = Identifier (Item.Transaction_ID))
                  then
                     Result := Conflict;
                     return;
                  end if;
               end loop;
               if Offset > 0 then
                  for Previous in Natural range 0 .. Offset - 1 loop
                     if Transactions (Transactions'First + Previous).Transaction_ID = Item.Transaction_ID then
                        Result := Conflict;
                        return;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
         if not Group_Mutation_Total_Fits_Wire (Total_Mutations)
           or else Interfaces.Unsigned_32 (Total_Mutations)
                   > Current_Manifest.Limits.Maximum_Mutations_Per_Batch
           or else Total_Bytes > Current_Manifest.Limits.Maximum_Batch_Payload_Bytes
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Offset in Natural range 0 .. Transactions'Length - 1 loop
            if Has_Transaction_Conflict
                 (Transactions (Transactions'First + Offset).Owner.Arena,
                  Transactions (Transactions'First + Offset).Snapshot_At)
            then
               Result := Conflict;
               return;
            end if;
         end loop;
         if Total_Bytes > Current_Manifest.Limits.Maximum_Batch_Payload_Bytes - In_Flight_Bytes
           or else Queue_Order = Interfaces.Unsigned_64'Last
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Index in Commit_Slot loop
            if Slots (Index).State = Free and then Slots (Index).Generation = Interfaces.Unsigned_64'Last then
               Result := Capacity_Exceeded;
               return;
            end if;
         end loop;

         Reserved_Count := Reserved_Count + 1;
         Reserved (Reserved_Count) := Batch_ID;
         for Offset in Natural range 0 .. Transactions'Length - 1 loop
            Reserved_Count := Reserved_Count + 1;
            Reserved (Reserved_Count) :=
              Identifier (Transactions (Transactions'First + Offset).Transaction_ID);
         end loop;
         Queue_Order := Queue_Order + 1;
         Count := Group_Count (Transactions'Length);
         for Offset in Natural range 0 .. Transactions'Length - 1 loop
            Selected := Commit_Slot'First;
            for Index in Commit_Slot loop
               if Slots (Index).State = Free then
                  Selected := Index;
                  exit;
               end if;
            end loop;
            declare
               Item : Transaction renames Transactions (Transactions'First + Offset);
            begin
               Slots (Selected).Generation := Slots (Selected).Generation + 1;
               Slots (Selected).Order := Queue_Order;
               Slots (Selected).Work.Transaction_ID := Item.Transaction_ID;
               Slots (Selected).Work.Snapshot_At := Item.Snapshot_At;
               Slots (Selected).Work.Payload_Length := Payload_Bytes (Item);
               Slots (Selected).Work.Arena := Item.Owner.Arena;
               Item.Owner.Arena := null;
               Slots (Selected).Work.Deadline := Deadline;
               Slots (Selected).Work.Batch_ID := Batch_ID;
               Slots (Selected).Work.Group_ID := Queue_Order;
               Slots (Selected).Work.Group_Member := Commit_Slot (Offset + 1);
               Slots (Selected).Receipt := (others => <>);
               Slots (Selected).Receipt.Transaction_ID := Item.Transaction_ID;
               Slots (Selected).Receipt.Batch_ID := Batch_ID;
               Slots (Selected).Receipt.Expected_Head := Current_Head;
               Slots (Selected).State := Queued;
               Tokens (Offset + 1) := (Index => Selected, Generation => Slots (Selected).Generation);
            end;
         end loop;
         In_Use_Count := In_Use_Count + Count;
         Queued_Count := Queued_Count + Count;
         In_Flight_Bytes := In_Flight_Bytes + Total_Bytes;
         Result := Success;
      end Admit_Group;

      entry Take_Group
        (Items      : out Work_Group;
         Tokens     : out Token_Group;
         Count      : out Group_Count;
         Head       : out Head_Snapshot;
         Generation : out Generation_Value;
         Stop       : out Boolean)
        when Closing or else Fenced or else (Queued_Count > 0 and then not Uncertain and then not Paused)
      is
         Selected       : Commit_Slot;
         Selected_Order : Interfaces.Unsigned_64;
         Selected_Group : Interfaces.Unsigned_64 := 0;
         Found          : Boolean;
      begin
         Items := [others => <>];
         Tokens := [others => <>];
         Count := 0;
         Head := Current_Head;
         Generation := Head_Generation;
         if Closing or else Fenced then
            Stop := True;
            return;
         end if;
         Stop := False;
         Selected := Commit_Slot'First;
         Selected_Order := Interfaces.Unsigned_64'Last;
         for Index in Commit_Slot loop
            if Slots (Index).State = Queued and then Slots (Index).Order < Selected_Order then
               Selected := Index;
               Selected_Order := Slots (Index).Order;
            end if;
         end loop;
         if Selected_Order = Interfaces.Unsigned_64'Last then
            return;
         end if;
         Selected_Group := Slots (Selected).Work.Group_ID;
         for Member in Commit_Slot loop
            Found := False;
            for Index in Commit_Slot loop
               if Slots (Index).State = Queued
                 and then Slots (Index).Work.Group_ID = Selected_Group
                 and then Slots (Index).Work.Group_Member = Member
               then
                  Selected := Index;
                  Found := True;
                  exit;
               end if;
            end loop;
            exit when not Found;
            Count := Count + 1;
            Items (Count).Transaction_ID := Slots (Selected).Work.Transaction_ID;
            Items (Count).Snapshot_At := Slots (Selected).Work.Snapshot_At;
            Items (Count).Arena := Slots (Selected).Work.Arena;
            Slots (Selected).Work.Arena := null;
            Items (Count).Payload_Length := Slots (Selected).Work.Payload_Length;
            Items (Count).Deadline := Slots (Selected).Work.Deadline;
            Items (Count).Batch_ID := Slots (Selected).Work.Batch_ID;
            Items (Count).Group_ID := Slots (Selected).Work.Group_ID;
            Items (Count).Group_Member := Slots (Selected).Work.Group_Member;
            Tokens (Count) := (Index => Selected, Generation => Slots (Selected).Generation);
            Slots (Selected).State := Running;
            Queued_Count := Queued_Count - 1;
         end loop;
      end Take_Group;

      procedure Prepublication_Check (Items : Work_Group; Count : Group_Count; Result : out Outcome_Code) is
      begin
         if History_Count = History_Capacity or else Count > Seen_Capacity - Seen_Count then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Left in Commit_Slot range 1 .. Count loop
            if Has_Transaction_Conflict (Items (Left).Arena, Items (Left).Snapshot_At) then
               Result := Conflict;
               return;
            end if;
            for Existing in Positive range 1 .. Seen_Count loop
               if Seen (Existing) = Items (Left).Transaction_ID then
                  Result := Conflict;
                  return;
               end if;
            end loop;
            for Right in Commit_Slot range 1 .. Left - 1 loop
               if Items (Right).Transaction_ID = Items (Left).Transaction_ID then
                  Result := Conflict;
                  return;
               end if;
            end loop;
         end loop;
         Result := Success;
      end Prepublication_Check;

      procedure Validate_Batch (Batch : Runtime_Batch; Result : out Outcome_Code) is
         Candidate : Runtime_Batch := Batch;
      begin
         Apply_Batch (Candidate, True, False, Result);
      end Validate_Batch;

      procedure Complete_Group
        (Tokens         : Token_Group;
         Receipts       : Receipt_Group;
         Count          : Group_Count;
         Result         : Outcome_Code;
         Mark_Uncertain : Boolean;
         Mark_Fenced    : Boolean) is
      begin
         for Group_Index in Commit_Slot range 1 .. Count loop
            declare
               --  Derived coordinator slot returned by admission; it is not a
               --  fixed slot choice or extra capacity limit.
               Index : constant Commit_Slot := Tokens (Group_Index).Index;
            begin
               if Slots (Index).State = Running
                 and then Slots (Index).Generation = Tokens (Group_Index).Generation
               then
                  Slots (Index).Receipt := Receipts (Group_Index);
                  Slots (Index).Result := Result;
                  Slots (Index).State := Completed;
               end if;
            end;
         end loop;
         if Mark_Uncertain and then Count > 0 then
            Uncertain := True;
         end if;
         if Mark_Fenced then
            Fenced := True;
            for Index in Commit_Slot loop
               if Slots (Index).State = Queued then
                  Slots (Index).Receipt.Current_Outcome := Stale_Writer;
                  Slots (Index).Result := Stale_Writer;
                  Slots (Index).State := Completed;
                  Queued_Count := Queued_Count - 1;
               end if;
            end loop;
         end if;
      end Complete_Group;

      entry Await_Result (for Index in Commit_Slot)
        (Generation : Interfaces.Unsigned_64;
         Receipt    : out Internal_Receipt;
         Arena      : out Transaction_Arena_Access;
         Result     : out Outcome_Code)
        when Slots (Index).State = Completed
      is
      begin
         Arena := null;
         if Slots (Index).Generation /= Generation then
            Receipt := (others => <>);
            Result := Invalid_State;
         else
            Receipt := Slots (Index).Receipt;
            Slots (Index).Receipt.Image := null;
            Arena := Slots (Index).Work.Arena;
            Slots (Index).Work.Arena := null;
            Result := Slots (Index).Result;
         end if;
         In_Use_Count := In_Use_Count - 1;
         In_Flight_Bytes := In_Flight_Bytes - Payload_Bytes (Slots (Index).Work);
         Slots (Index).State := Free;
      end Await_Result;

      procedure Install_Published
        (Batch      : in out Runtime_Batch;
         Head       : Head_Snapshot;
         Generation : Generation_Value;
         Result     : out Outcome_Code) is
      begin
         if Fail_Install then
            Fail_Install := False;
            raise Program_Error with "injected local installation failure";
         end if;
         Apply_Batch (Batch, True, True, Result);
         if Result = Success then
            Current_Head := Head;
            Head_Generation := Generation;
         end if;
      end Install_Published;

      procedure Snapshot
        (Head         : out Head_Snapshot;
         Generation   : out Generation_Value;
         Is_Uncertain : out Boolean;
         Is_Fenced    : out Boolean) is
      begin
         Head := Current_Head;
         Generation := Head_Generation;
         Is_Uncertain := Uncertain;
         Is_Fenced := Fenced;
      end Snapshot;

      procedure Lookup_At
        (Family          : Column_Family_ID;
         Item_Key        : Byte_Array;
         Snapshot_At     : Sequence_Number;
         Checkpoint_Base : State_Entry_Array_Access;
         Image           : out Shared_Image_Access;
         Value_Offset    : out Natural;
         Value_Length    : out Natural;
         Matched         : out Boolean;
         Result          : out Outcome_Code)
      is
         function Valid_Slice
           (Source : not null Shared_Image_Access; Offset, Length : Natural) return Boolean
         is
            Image_Length : constant Natural := Flyology.Bytes.Length (Source.Data);
         begin
            return Offset <= Image_Length and then Length <= Image_Length - Offset;
         end Valid_Slice;

         function Same_Key
           (Source : not null Shared_Image_Access; Offset, Length : Natural) return Boolean
         is
         begin
            if Length /= Item_Key'Length then
               return False;
            end if;
            for Key_Index in Item_Key'Range loop
               if Byte
                    (Flyology.Bytes.Element
                       (Source.Data, Offset + (Key_Index - Item_Key'First) + 1))
                 /= Item_Key (Key_Index)
               then
                  return False;
               end if;
            end loop;
            return True;
         end Same_Key;
      begin
         Image := null;
         Value_Offset := 0;
         Value_Length := 0;
         Matched := False;
         if Snapshot_At < Retained_History_Boundary then
            Result := Conflict;
            return;
         end if;
         for Batch_Index in reverse Positive range 1 .. History_Count loop
            declare
               Batch : Runtime_Batch renames History_Batches (Batch_Index);
            begin
               if Batch.Image = null
                 or else Batch.Transactions = null
                 or else Batch.Mutations = null
                 or else Batch.Transactions'First /= 1
                 or else Batch.Mutations'First /= 1
                 or else Batch.Transaction_Total > Batch.Transactions'Length
                 or else Batch.Mutation_Total > Batch.Mutations'Length
               then
                  Result := Corrupt;
                  return;
               end if;
               for Transaction_Index in reverse Positive range 1 .. Batch.Transaction_Total loop
                  declare
                     Batch_Transaction : Runtime_Transaction renames Batch.Transactions (Transaction_Index);
                  begin
                     if Batch_Transaction.Sequence <= Snapshot_At then
                        if Batch_Transaction.Mutation_Count = 0
                          or else Batch_Transaction.First_Mutation = 0
                          or else Batch_Transaction.Mutation_Count > Batch.Mutation_Total
                          or else Batch_Transaction.First_Mutation
                                  > Batch.Mutation_Total - Batch_Transaction.Mutation_Count + 1
                        then
                           Result := Corrupt;
                           return;
                        end if;
                        for Mutation_Index in reverse Positive range
                          Batch_Transaction.First_Mutation
                          .. Batch_Transaction.First_Mutation + Batch_Transaction.Mutation_Count - 1
                        loop
                           declare
                              Mutation : Runtime_Mutation renames Batch.Mutations (Mutation_Index);
                           begin
                              if not Valid_Slice (Batch.Image, Mutation.Key_Offset, Mutation.Key_Length)
                                or else
                                  (Mutation.Operation = Put_Mutation
                                   and then not Valid_Slice
                                                  (Batch.Image,
                                                   Mutation.Value_Offset,
                                                   Mutation.Value_Length))
                              then
                                 Result := Corrupt;
                                 return;
                              elsif Mutation.Family = Family
                                and then Same_Key (Batch.Image, Mutation.Key_Offset, Mutation.Key_Length)
                              then
                                 Matched := True;
                                 if Mutation.Operation = Delete_Mutation then
                                    Result := Not_Found;
                                 else
                                    Image := Batch.Image;
                                    Value_Offset := Mutation.Value_Offset;
                                    Value_Length := Mutation.Value_Length;
                                    Result := Success;
                                 end if;
                                 return;
                              end if;
                           end;
                        end loop;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         if Checkpoint_Base /= null then
            for Index in Checkpoint_Base'Range loop
               if Checkpoint_Base (Index).Image = null
                 or else not Valid_Slice
                               (Checkpoint_Base (Index).Image,
                                Checkpoint_Base (Index).Key_Offset,
                                Checkpoint_Base (Index).Key_Length)
                 or else not Valid_Slice
                               (Checkpoint_Base (Index).Image,
                                Checkpoint_Base (Index).Value_Offset,
                                Checkpoint_Base (Index).Value_Length)
               then
                  Result := Corrupt;
                  return;
               elsif Checkpoint_Base (Index).Family = Family
                 and then Checkpoint_Base (Index).Image /= null
                 and then Same_Key
                            (Checkpoint_Base (Index).Image,
                             Checkpoint_Base (Index).Key_Offset,
                             Checkpoint_Base (Index).Key_Length)
               then
                  Matched := True;
                  Image := Checkpoint_Base (Index).Image;
                  Value_Offset := Checkpoint_Base (Index).Value_Offset;
                  Value_Length := Checkpoint_Base (Index).Value_Length;
                  Result := Success;
                  return;
               end if;
            end loop;
         end if;
         Result := Not_Found;
      end Lookup_At;

      procedure Scan_Source_Requirements
        (Family          : Column_Family_ID;
         Snapshot_At     : Sequence_Number;
         Checkpoint_Base : State_Entry_Array_Access;
         Extra_Count     : Natural;
         Source_Count    : out Natural;
         Maximum_Rows    : out Interfaces.Unsigned_32;
         Maximum_Bytes   : out Interfaces.Unsigned_64;
         Result          : out Outcome_Code)
      is
      begin
         Source_Count := Extra_Count;
         Maximum_Rows := Current_Manifest.Limits.Maximum_Live_Entries;
         Maximum_Bytes := Current_Manifest.Limits.Maximum_Live_State_Bytes;
         if Snapshot_At < Retained_History_Boundary then
            Result := Conflict;
            return;
         end if;
         Visit_Scan_Checkpoint (Checkpoint_Base, Family, null, Source_Count, Result);
         if Result /= Success then
            return;
         end if;
         for Batch_Index in Positive range 1 .. History_Count loop
            Visit_Scan_Batch
              (History_Batches (Batch_Index),
               Family,
               Snapshot_At,
               Batch_Index + 1,
               null,
               Source_Count,
               Result);
            if Result /= Success then
               return;
            end if;
         end loop;
      exception
         when Storage_Error =>
            Source_Count := 0;
            Result := Capacity_Exceeded;
      end Scan_Source_Requirements;

      procedure Copy_Scan_Sources
        (Family          : Column_Family_ID;
         Snapshot_At     : Sequence_Number;
         Checkpoint_Base : State_Entry_Array_Access;
         Sources         : not null Scan_Source_Array_Access;
         Captured        : out Natural;
         Result          : out Outcome_Code)
      is
      begin
         Captured := 0;
         if Snapshot_At < Retained_History_Boundary then
            Result := Conflict;
            return;
         end if;
         Visit_Scan_Checkpoint (Checkpoint_Base, Family, Sources, Captured, Result);
         if Result /= Success then
            return;
         end if;
         for Batch_Index in Positive range 1 .. History_Count loop
            Visit_Scan_Batch
              (History_Batches (Batch_Index),
               Family,
               Snapshot_At,
               Batch_Index + 1,
               Sources,
               Captured,
               Result);
            if Result /= Success then
               return;
            end if;
         end loop;
      exception
         when Storage_Error =>
            Captured := 0;
            Result := Capacity_Exceeded;
      end Copy_Scan_Sources;

      procedure Lookup_Sequence
        (Family   : Column_Family_ID;
         Item_Key : Byte_Array;
         Sequence : out Sequence_Number;
         Result   : out Outcome_Code)
      is
         Matches : Boolean;
      begin
         Sequence := 0;
         for Index in Positive range 1 .. Entry_Count loop
            Matches :=
              Entries (Index).Family = Family
              and then Entries (Index).Image /= null
              and then Entries (Index).Key_Length = Item_Key'Length;
            if Matches then
               for Offset in Natural range 0 .. Item_Key'Length - 1 loop
                  if Byte
                       (Flyology.Bytes.Element
                          (Entries (Index).Image.Data, Entries (Index).Key_Offset + Offset + 1))
                    /= Item_Key (Item_Key'First + Offset)
                  then
                     Matches := False;
                     exit;
                  end if;
               end loop;
               if Matches then
                  Sequence := Entries (Index).Sequence;
                  Result := Success;
                  return;
               end if;
            end if;
         end loop;
         Result := Not_Found;
      end Lookup_Sequence;

      procedure Family_Snapshot_Requirements
        (Family        : Column_Family_ID;
         Entry_Total   : out Natural;
         Payload_Bytes : out Natural;
         Result        : out Outcome_Code)
      is
         Total : Interfaces.Unsigned_64 := 0;
      begin
         Entry_Total := 0;
         Payload_Bytes := 0;
         for Index in Positive range 1 .. Entry_Count loop
            if Entries (Index).Family = Family then
               if Entries (Index).Image = null
                 or else Entries (Index).Sequence = 0
                 or else Entries (Index).Sequence > Current_Head.Highest
                 or else Entries (Index).Key_Length > Natural'Last - Entries (Index).Value_Length
                 or else Total
                         > Interfaces.Unsigned_64'Last
                           - Interfaces.Unsigned_64
                               (Entries (Index).Key_Length + Entries (Index).Value_Length)
               then
                  Result := Corrupt;
                  return;
               end if;
               if Entry_Total = Natural'Last then
                  Result := Capacity_Exceeded;
                  return;
               end if;
               Entry_Total := Entry_Total + 1;
               Total :=
                 Total + Interfaces.Unsigned_64 (Entries (Index).Key_Length + Entries (Index).Value_Length);
            end if;
         end loop;
         if Total > Interfaces.Unsigned_64 (Natural'Last) then
            Result := Capacity_Exceeded;
            return;
         end if;
         Payload_Bytes := Natural (Total);
         Result := (if Entry_Total = 0 then Not_Found else Success);
      end Family_Snapshot_Requirements;

      procedure Copy_Family_Snapshot
        (Family     : Column_Family_ID;
         References : not null Snapshot_Entry_Reference_Array_Access;
         Result     : out Outcome_Code)
      is
         Next : Natural := 0;
      begin
         for Index in Positive range 1 .. Entry_Count loop
            if Entries (Index).Family = Family then
               if Next = References'Length then
                  Result := Invalid_State;
                  return;
               end if;
               Next := Next + 1;
               References (References'First + Next - 1) :=
                 (Image        => Entries (Index).Image,
                  Key_Offset   => Entries (Index).Key_Offset,
                  Key_Length   => Entries (Index).Key_Length,
                  Value_Offset => Entries (Index).Value_Offset,
                  Value_Length => Entries (Index).Value_Length,
                  Sequence     => Entries (Index).Sequence,
                  Operation    => Put_Operation_Code);
            end if;
         end loop;
         Result := (if Next = References'Length then Success else Invalid_State);
      end Copy_Family_Snapshot;

      procedure Family_Delta_Snapshot
        (Family        : Column_Family_ID;
         References    : Snapshot_Entry_Reference_Array_Access;
         Entry_Total   : out Natural;
         Payload_Bytes : out Natural;
         Result        : out Outcome_Code)
      is
         Total : Interfaces.Unsigned_64 := 0;
         Next  : Natural := 0;

         function Valid_Slice
           (Image : not null Shared_Image_Access; Offset, Length : Natural) return Boolean
         is
            Image_Length : constant Natural := Flyology.Bytes.Length (Image.Data);
         begin
            return Offset <= Image_Length and then Length <= Image_Length - Offset;
         end Valid_Slice;

         function Valid_Batch (Batch : Runtime_Batch) return Boolean is
         begin
            if Batch.Image = null
              or else Batch.Transactions = null
              or else Batch.Mutations = null
              or else Batch.Transaction_Total = 0
              or else Batch.Mutation_Total = 0
              or else Batch.Transaction_Total > Batch.Transactions'Length
              or else Batch.Mutation_Total > Batch.Mutations'Length
            then
               return False;
            end if;
            for Index in Positive range 1 .. Batch.Mutation_Total loop
               declare
                  Mutation : Runtime_Mutation renames Batch.Mutations (Index);
               begin
                  if Runtime_Mutation_Sequence (Batch, Index) = 0
                    or else not Valid_Slice (Batch.Image, Mutation.Key_Offset, Mutation.Key_Length)
                    or else Mutation.Operation not in Put_Mutation | Delete_Mutation
                    or else
                      (Mutation.Operation = Put_Mutation
                       and then not Valid_Slice
                                      (Batch.Image, Mutation.Value_Offset, Mutation.Value_Length))
                    or else (Mutation.Operation = Delete_Mutation and then Mutation.Value_Length /= 0)
                  then
                     return False;
                  end if;
               end;
            end loop;
            return True;
         end Valid_Batch;

         function Last_In_Suffix (Batch_Index, Mutation_Index : Positive) return Boolean is
            Source_Batch    : Runtime_Batch renames History_Batches (Batch_Index);
            Source_Mutation : Runtime_Mutation renames Source_Batch.Mutations (Mutation_Index);
         begin
            for Later_Mutation in Positive range Mutation_Index + 1 .. Source_Batch.Mutation_Total loop
               if Same_Runtime_Key
                    (Source_Batch.Image,
                     Source_Mutation,
                     Source_Batch.Image,
                     Source_Batch.Mutations (Later_Mutation))
               then
                  return False;
               end if;
            end loop;
            for Later_Batch_Index in Positive range Batch_Index + 1 .. History_Count loop
               declare
                  Later_Batch : Runtime_Batch renames History_Batches (Later_Batch_Index);
               begin
                  for Later_Mutation in Positive range 1 .. Later_Batch.Mutation_Total loop
                     if Same_Runtime_Key
                          (Source_Batch.Image,
                           Source_Mutation,
                           Later_Batch.Image,
                           Later_Batch.Mutations (Later_Mutation))
                     then
                        return False;
                     end if;
                  end loop;
               end;
            end loop;
            return True;
         end Last_In_Suffix;
      begin
         Entry_Total := 0;
         Payload_Bytes := 0;
         for Batch_Index in Positive range 1 .. History_Count loop
            if not Valid_Batch (History_Batches (Batch_Index)) then
               Result := Corrupt;
               return;
            end if;
         end loop;
         for Batch_Index in Positive range 1 .. History_Count loop
            declare
               Batch : Runtime_Batch renames History_Batches (Batch_Index);
            begin
               for Mutation_Index in Positive range 1 .. Batch.Mutation_Total loop
                  declare
                     Mutation : Runtime_Mutation renames Batch.Mutations (Mutation_Index);
                  begin
                     if Mutation.Family = Family and then Last_In_Suffix (Batch_Index, Mutation_Index) then
                        declare
                           Amount : Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Mutation.Key_Length);
                        begin
                           if Mutation.Operation = Put_Mutation then
                              if Amount
                                > Interfaces.Unsigned_64'Last
                                  - Interfaces.Unsigned_64 (Mutation.Value_Length)
                              then
                                 Result := Capacity_Exceeded;
                                 return;
                              end if;
                              Amount := Amount + Interfaces.Unsigned_64 (Mutation.Value_Length);
                           end if;
                           if Total > Interfaces.Unsigned_64'Last - Amount or else Next = Natural'Last then
                              Result := Capacity_Exceeded;
                              return;
                           end if;
                           Total := Total + Amount;
                           Next := Next + 1;
                           if References /= null then
                              if Next > References'Length then
                                 Result := Invalid_State;
                                 return;
                              end if;
                              References (References'First + Next - 1) :=
                                (Image        => Batch.Image,
                                 Key_Offset   => Mutation.Key_Offset,
                                 Key_Length   => Mutation.Key_Length,
                                 Value_Offset => Mutation.Value_Offset,
                                 Value_Length => Mutation.Value_Length,
                                 Sequence     => Runtime_Mutation_Sequence (Batch, Mutation_Index),
                                 Operation    =>
                                   (if Mutation.Operation = Put_Mutation
                                    then Put_Operation_Code
                                    else Delete_Operation_Code));
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end;
         end loop;
         if Total > Interfaces.Unsigned_64 (Natural'Last) then
            Result := Capacity_Exceeded;
            return;
         elsif References /= null and then Next /= References'Length then
            Result := Invalid_State;
            return;
         end if;
         Entry_Total := Next;
         Payload_Bytes := Natural (Total);
         Result := (if Next = 0 then Not_Found else Success);
      end Family_Delta_Snapshot;

      procedure Checkpoint_Metadata
        (Base : out Manifests.Manifest; Identity_Total : out Natural; Result : out Outcome_Code) is
      begin
         Base := Current_Manifest;
         Identity_Total := Reserved_Count;
         Result := Success;
      end Checkpoint_Metadata;

      procedure Copy_Checkpoint_Identities
        (Value : not null LSM_Runtime.Checkpoint_Manifest_Access; Result : out Outcome_Code) is
      begin
         if Value.Identity_Total /= Reserved_Count then
            Result := Invalid_State;
            return;
         end if;
         for Index in Positive range 1 .. Reserved_Count loop
            Value.Identities (Index) := To_Head_ID (Reserved (Index));
         end loop;
         Result := Success;
      end Copy_Checkpoint_Identities;

      procedure Find_Family
        (ID : Column_Family_ID; Configuration : out Column_Family_Configuration; Result : out Outcome_Code) is
      begin
         Configuration := (others => <>);
         for Index in Manifests.Family_Slot range 1 .. Current_Manifest.Family_Total loop
            if Current_Manifest.Families (Index).ID = Interfaces.Unsigned_32 (ID) then
               Configuration := From_Manifest_Configuration (Current_Manifest.Families (Index));
               Result := Success;
               return;
            end if;
         end loop;
         Result := Not_Found;
      end Find_Family;

      procedure Find_Family
        (Name : Byte_Array; Configuration : out Column_Family_Configuration; Result : out Outcome_Code)
      is
         Candidate : Manifests.Column_Family_Configuration;
      begin
         Configuration := (others => <>);
         if Name'Length = 0 or else Name'Length > Maximum_Column_Family_Name_Bytes then
            Result := Not_Found;
            return;
         end if;
         Candidate.Name_Length := Name'Length;
         for Offset in Natural range 0 .. Name'Length - 1 loop
            Candidate.Name (Offset + 1) := Name (Name'First + Offset);
         end loop;
         for Index in Manifests.Family_Slot range 1 .. Current_Manifest.Family_Total loop
            if Current_Manifest.Families (Index).Name_Length = Candidate.Name_Length
              and then Current_Manifest.Families (Index).Name (1 .. Candidate.Name_Length)
                       = Candidate.Name (1 .. Candidate.Name_Length)
            then
               Configuration := From_Manifest_Configuration (Current_Manifest.Families (Index));
               Result := Success;
               return;
            end if;
         end loop;
         Result := Not_Found;
      end Find_Family;

      procedure Validate_Family
        (Family : Column_Family; Configuration : out Column_Family_Configuration; Result : out Outcome_Code)
      is
      begin
         Configuration := (others => <>);
         if not Family.Valid
           or else Family.Database_ID /= Current_Head.Database_ID
           or else Family.Incarnation /= Incarnation
         then
            Result := Invalid_State;
            return;
         end if;
         Find_Family (Family.Configuration.ID, Configuration, Result);
         if Result = Success and then not Same_Configuration (Configuration, Family.Configuration) then
            Configuration := (others => <>);
            Result := Invalid_State;
         end if;
      end Validate_Family;

      procedure Validate_Transaction_Bounds
        (Mutation_Count : Natural; Payload_Bytes : Interfaces.Unsigned_64; Result : out Outcome_Code) is
      begin
         if Interfaces.Unsigned_32 (Mutation_Count)
           > Current_Manifest.Limits.Maximum_Mutations_Per_Transaction
           or else Payload_Bytes > Current_Manifest.Limits.Maximum_Transaction_Payload_Bytes
         then
            Result := Capacity_Exceeded;
         else
            Result := Success;
         end if;
      end Validate_Transaction_Bounds;

      procedure Transaction_Limits
        (Mutation_Limit : out Interfaces.Unsigned_32; Payload_Limit : out Interfaces.Unsigned_64) is
      begin
         Mutation_Limit := Current_Manifest.Limits.Maximum_Mutations_Per_Transaction;
         Payload_Limit := Current_Manifest.Limits.Maximum_Transaction_Payload_Bytes;
      end Transaction_Limits;

      function Current_Incarnation return Engine_Incarnation
      is (Incarnation);

      procedure Fence is
      begin
         Fenced := True;
         Uncertain := False;
         for Index in Commit_Slot loop
            if Slots (Index).State = Queued then
               Slots (Index).Receipt.Current_Outcome := Stale_Writer;
               Slots (Index).Result := Stale_Writer;
               Slots (Index).State := Completed;
               Queued_Count := Queued_Count - 1;
            end if;
         end loop;
      end Fence;

      procedure Drain_Queued_For_Resolution is
      begin
         for Index in Commit_Slot loop
            if Slots (Index).State = Queued then
               Slots (Index).Receipt.Current_Outcome := Storage_Failure;
               Slots (Index).Result := Storage_Failure;
               Slots (Index).State := Completed;
               Queued_Count := Queued_Count - 1;
            end if;
         end loop;
      end Drain_Queued_For_Resolution;

      procedure Set_Paused (Value : Boolean) is
      begin
         Paused := Value;
      end Set_Paused;

      function Queue_Depth return Natural
      is (Queued_Count);

      procedure Fail_Next_Install is
      begin
         Fail_Install := True;
      end Fail_Next_Install;

      procedure Request_Close is
      begin
         Closing := True;
         for Index in Commit_Slot loop
            if Slots (Index).State = Queued then
               Slots (Index).Receipt.Current_Outcome := Storage_Failure;
               Slots (Index).Result := Storage_Failure;
               Slots (Index).State := Completed;
               Queued_Count := Queued_Count - 1;
            end if;
         end loop;
      end Request_Close;

      procedure Mark_Stopped is
      begin
         for Index in Commit_Slot loop
            if Slots (Index).State in Queued | Running then
               if Slots (Index).State = Queued then
                  Queued_Count := Queued_Count - 1;
               end if;
               Slots (Index).Receipt.Current_Outcome := Storage_Failure;
               Slots (Index).Result := Storage_Failure;
               Slots (Index).State := Completed;
            end if;
         end loop;
         Stopped := True;
      end Mark_Stopped;

      function History_Length return Natural is
      begin
         return History_Count;
      end History_Length;

      procedure History_Batch_Shape
        (Index             : Positive;
         Transaction_Total : out Natural;
         Mutation_Total    : out Natural;
         Result            : out Outcome_Code)
      is
      begin
         Transaction_Total := 0;
         Mutation_Total := 0;
         if Index > History_Count
           or else History_Batches (Index).Transactions = null
           or else History_Batches (Index).Mutations = null
           or else History_Batches (Index).Image = null
           or else History_Batches (Index).Transaction_Total = 0
           or else History_Batches (Index).Mutation_Total = 0
           or else History_Batches (Index).Transactions'Length
                     /= History_Batches (Index).Transaction_Total
           or else History_Batches (Index).Mutations'Length /= History_Batches (Index).Mutation_Total
         then
            Result := Corrupt;
         else
            Transaction_Total := History_Batches (Index).Transaction_Total;
            Mutation_Total := History_Batches (Index).Mutation_Total;
            Result := Success;
         end if;
      end History_Batch_Shape;

      procedure Copy_History_Batch
        (Index  : Positive;
         Batch  : in out Runtime_Batch;
         Result : out Outcome_Code)
      is
      begin
         if Index > History_Count then
            Result := Corrupt;
            return;
         end if;
         declare
            Source : Runtime_Batch renames History_Batches (Index);
         begin
            if Source.Transactions = null
              or else Source.Mutations = null
              or else Source.Image = null
              or else Source.Transaction_Total = 0
              or else Source.Mutation_Total = 0
              or else Source.Transactions'Length /= Source.Transaction_Total
              or else Source.Mutations'Length /= Source.Mutation_Total
              or else Batch.Transactions = null
              or else Batch.Mutations = null
              or else Batch.Image /= null
              or else Batch.Transactions'Length /= Source.Transaction_Total
              or else Batch.Mutations'Length /= Source.Mutation_Total
            then
               Result := Corrupt;
               return;
            end if;
            Batch.Database_ID := Source.Database_ID;
            Batch.Epoch := Source.Epoch;
            Batch.Batch_ID := Source.Batch_ID;
            Batch.Previous_Batch_ID := Source.Previous_Batch_ID;
            Batch.Expected_Transition_ID := Source.Expected_Transition_ID;
            Batch.Expected_Transition_Number := Source.Expected_Transition_Number;
            Batch.Publication_Transition_ID := Source.Publication_Transition_ID;
            Batch.Publication_Transition_Number := Source.Publication_Transition_Number;
            Batch.First_Sequence := Source.First_Sequence;
            Batch.Last_Sequence := Source.Last_Sequence;
            Batch.Transaction_Total := Source.Transaction_Total;
            Batch.Mutation_Total := Source.Mutation_Total;
            Batch.Transactions.all := Source.Transactions.all;
            Batch.Mutations.all := Source.Mutations.all;
            Source.Image.References.Retain;
            Batch.Image := Source.Image;
            Result := Success;
         end;
      end Copy_History_Batch;

      procedure Take_History_Batch (Index : Positive; Batch : out Runtime_Batch) is
      begin
         Batch := (others => <>);
         if Index <= History_Count then
            Batch := History_Batches (Index);
            History_Batches (Index) := (others => <>);
         end if;
      end Take_History_Batch;

      entry Join when Stopped and then In_Use_Count = 0 is
      begin
         null;
      end Join;

      function Highest return Sequence_Number
      is (Current_Head.Highest);

   end Coordinator;

   task type Commit_Worker (State : not null Engine_State_Access) is
      pragma Task_Info (Flyology.Native_Task);
   end Commit_Worker;
   type Commit_Worker_Access is access Commit_Worker;

   type Engine_State
     (Entry_Capacity    : Positive;
      Seen_Capacity     : Positive;
      History_Capacity  : Positive;
      Reserved_Capacity : Positive)
   is limited record
      Storage           : access Storage_Context;
      Life              : Database_Lifecycle_Access := null;
      LSM_Authority     : Engine_LSM_Authority := No_LSM_Authority;
      Gate              : Coordinator (Entry_Capacity, Seen_Capacity, History_Capacity, Reserved_Capacity);
      Checkpoint_Images : Checkpoint_Image_Array_Access := null;
      --  Exact current manifest owns the oldest-to-newest run descriptors used
      --  to derive the next successor. It is released only with this engine.
      Checkpoint_Manifest : LSM_Runtime.Checkpoint_Manifest_Access := null;
      --  Exact checkpoint live-entry descriptors derive either from the
      --  quiescent coordinator during local activation or authenticated SST
      --  counts during cacheless recovery. They borrow Checkpoint_Images and
      --  preserve the base after newer suffix writes replace Entries.
      Checkpoint_Base   : State_Entry_Array_Access := null;
      Worker            : Commit_Worker_Access := null;
   end record;

   function Snapshot_Key_Less (Left, Right : Snapshot_Entry_Reference) return Boolean is
      Shared : constant Natural := Natural'Min (Left.Key_Length, Right.Key_Length);
   begin
      for Offset in Natural range 0 .. Shared - 1 loop
         declare
            Left_Byte  : constant Byte :=
              Byte (Flyology.Bytes.Element (Left.Image.Data, Left.Key_Offset + Offset + 1));
            Right_Byte : constant Byte :=
              Byte (Flyology.Bytes.Element (Right.Image.Data, Right.Key_Offset + Offset + 1));
         begin
            if Left_Byte < Right_Byte then
               return True;
            elsif Left_Byte > Right_Byte then
               return False;
            end if;
         end;
      end loop;
      return Left.Key_Length < Right.Key_Length;
   end Snapshot_Key_Less;

   procedure Sort_Snapshot_References (References : in out Snapshot_Entry_Reference_Array) is
   begin
      for Index in References'First + 1 .. References'Last loop
         declare
            Item   : constant Snapshot_Entry_Reference := References (Index);
            Cursor : Positive := Index;
         begin
            while Cursor > References'First and then Snapshot_Key_Less (Item, References (Cursor - 1)) loop
               References (Cursor) := References (Cursor - 1);
               Cursor := Cursor - 1;
            end loop;
            References (Cursor) := Item;
         end;
      end loop;
   end Sort_Snapshot_References;

   procedure Build_Family_SST
     (State        : not null Engine_State_Access;
      Family_ID    : Column_Family_ID;
      Run_ID       : Identifier;
      Value        : out LSM_Runtime.SST_Access;
      Result       : out Outcome_Code;
      Complete_View : Boolean := False;
      Allow_Fenced : Boolean := False)
   is
      References      : Snapshot_Entry_Reference_Array_Access := null;
      Entry_Total     : Natural;
      Payload_Bytes   : Natural;
      Head            : Head_Snapshot;
      Generation      : Generation_Value;
      Uncertain       : Boolean;
      Fenced          : Boolean;
      Authority_Found : Boolean := False;
      Authority       : LSM_Runtime.Family_LSM_State := (others => <>);
      Allocation      : LSM_Runtime.Allocation_Status;
      Payload_Cursor  : Positive := 1;
      Lowest          : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Highest         : Interfaces.Unsigned_64 := 0;
      --  The current replay boundary selects suffix-delta Flush only when the
      --  caller has not explicitly requested a complete replacement view.
      --  This is algorithm mode, not a size threshold or automatic policy.
      Delta_Mode      : constant Boolean :=
        State.LSM_Authority.Replay_Boundary /= 0 and then not Complete_View;
   begin
      Value := null;
      if Is_Zero (Run_ID) or else not State.LSM_Authority.Enabled then
         Result := Invalid_State;
         return;
      end if;
      for Family of State.LSM_Authority.Families loop
         if Family.ID = Interfaces.Unsigned_32 (Family_ID) then
            Authority := Family.State;
            Authority_Found := True;
            exit;
         end if;
      end loop;
      if not Authority_Found then
         Result := Not_Found;
         return;
      end if;

      State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced and then not Allow_Fenced then
         Result := Stale_Writer;
         return;
      end if;
      if Delta_Mode then
         State.Gate.Family_Delta_Snapshot (Family_ID, null, Entry_Total, Payload_Bytes, Result);
      else
         State.Gate.Family_Snapshot_Requirements (Family_ID, Entry_Total, Payload_Bytes, Result);
      end if;
      if Result /= Success then
         return;
      elsif Interfaces.Unsigned_64 (Entry_Total) > Interfaces.Unsigned_64 (Authority.Memtable_Max_Entries)
        or else Interfaces.Unsigned_64 (Payload_Bytes) > Authority.Memtable_Max_Bytes
        or else Authority.Maximum_L0_Runs = 0
        or else State.LSM_Authority.Maximum_Total_L0_Runs = 0
      then
         Result := Capacity_Exceeded;
         return;
      end if;

      Allocation_Faults.Check (Checkpoint_Reference_Allocation);
      References := new Snapshot_Entry_Reference_Array (1 .. Entry_Total);
      if Delta_Mode then
         declare
            Copied_Entries : Natural;
            Copied_Bytes   : Natural;
         begin
            State.Gate.Family_Delta_Snapshot
              (Family_ID, References, Copied_Entries, Copied_Bytes, Result);
            if Result = Success
              and then (Copied_Entries /= Entry_Total or else Copied_Bytes /= Payload_Bytes)
            then
               Result := Invalid_State;
            end if;
         end;
      else
         State.Gate.Copy_Family_Snapshot (Family_ID, References, Result);
      end if;
      if Result /= Success then
         Free_Snapshot_References (References);
         return;
      end if;
      Sort_Snapshot_References (References.all);
      for Index in References'First + 1 .. References'Last loop
         if not Snapshot_Key_Less (References (Index - 1), References (Index)) then
            Free_Snapshot_References (References);
            Result := Corrupt;
            return;
         end if;
      end loop;

      Allocation_Faults.Check (Checkpoint_SST_Allocation);
      LSM_Runtime.Create_SST (Entry_Total, Payload_Bytes, Value, Allocation);
      if Allocation /= LSM_Runtime.Allocated then
         Free_Snapshot_References (References);
         Result := Capacity_Exceeded;
         return;
      end if;
      Value.Database_ID := To_Head_ID (Head.Database_ID);
      Value.Run_ID := To_Head_ID (Run_ID);
      Value.Family_ID := Interfaces.Unsigned_32 (Family_ID);
      Value.Logical_Payload_Bytes := Interfaces.Unsigned_64 (Payload_Bytes);
      for Index in References'Range loop
         declare
            Reference : Snapshot_Entry_Reference renames References (Index);
            Target    : LSM_Runtime.SST_Entry renames Value.Entries (Index);
         begin
            Target.Sequence := Interfaces.Unsigned_64 (Reference.Sequence);
            Target.Operation := Reference.Operation;
            Target.Key_Offset := Payload_Cursor;
            Target.Key_Byte_Total := Reference.Key_Length;
            for Offset in Natural range 0 .. Reference.Key_Length - 1 loop
               Value.Payload (Payload_Cursor + Offset) :=
                 Formats.Byte
                   (Flyology.Bytes.Element (Reference.Image.Data, Reference.Key_Offset + Offset + 1));
            end loop;
            Payload_Cursor := Payload_Cursor + Reference.Key_Length;
            Target.Value_Offset := Payload_Cursor;
            Target.Value_Byte_Total :=
              (if Reference.Operation = Delete_Operation_Code then 0 else Reference.Value_Length);
            if Target.Value_Byte_Total > 0 then
               for Offset in Natural range 0 .. Target.Value_Byte_Total - 1 loop
                  Value.Payload (Payload_Cursor + Offset) :=
                    Formats.Byte
                      (Flyology.Bytes.Element (Reference.Image.Data, Reference.Value_Offset + Offset + 1));
               end loop;
               Payload_Cursor := Payload_Cursor + Target.Value_Byte_Total;
            end if;
            Lowest := Interfaces.Unsigned_64'Min (Lowest, Target.Sequence);
            Highest := Interfaces.Unsigned_64'Max (Highest, Target.Sequence);
         end;
      end loop;
      Value.Lowest_Sequence := Lowest;
      Value.Highest_Sequence := Highest;
      Free_Snapshot_References (References);
      if Payload_Cursor /= Payload_Bytes + 1 or else not LSM_Runtime.Structurally_Valid (Value.all) then
         LSM_Runtime.Release (Value);
         Result := Corrupt;
         return;
      end if;
      Result := Success;
   exception
      when Storage_Error =>
         Free_Snapshot_References (References);
         LSM_Runtime.Release (Value);
         Result := Capacity_Exceeded;
      when others =>
         Free_Snapshot_References (References);
         LSM_Runtime.Release (Value);
         raise;
   end Build_Family_SST;

   procedure Prepare_Live_Checkpoint_Base
     (State  : not null Engine_State_Access;
      Plan   : in out Checkpoint_Plan;
      Result : out Outcome_Code)
   is
      Entry_Total   : Natural := 0;
      Payload_Bytes : Natural;
      Family_Total  : Natural;
      References    : Snapshot_Entry_Reference_Array_Access := null;
      Next          : Natural := 0;
   begin
      if Plan.Manifest = null then
         Result := Invalid_State;
         return;
      end if;
      for Family_Index in Plan.Manifest.Families'Range loop
         State.Gate.Family_Snapshot_Requirements
           (Column_Family_ID (Plan.Manifest.Base.Families (Family_Index).ID),
            Family_Total,
            Payload_Bytes,
            Result);
         if Result = Success then
            if Family_Total > Natural'Last - Entry_Total then
               Result := Capacity_Exceeded;
               return;
            end if;
            Entry_Total := Entry_Total + Family_Total;
         elsif Result /= Not_Found then
            return;
         end if;
      end loop;
      if Interfaces.Unsigned_64 (Entry_Total)
        > Interfaces.Unsigned_64 (Plan.Manifest.Base.Limits.Maximum_Live_Entries)
      then
         Result := Corrupt;
         return;
      elsif Entry_Total = 0 then
         Plan.Activation_Ready := True;
         Result := Success;
         return;
      end if;
      Allocation_Faults.Check (Checkpoint_Reference_Allocation);
      Plan.Base := new State_Entry_Array (1 .. Entry_Total);
      Allocation_Faults.Check (Recovery_Checkpoint_Image_Allocation);
      Plan.Images := new Checkpoint_Image_Array'(1 .. Entry_Total => null);
      for Family_Index in Plan.Manifest.Families'Range loop
         State.Gate.Family_Snapshot_Requirements
           (Column_Family_ID (Plan.Manifest.Base.Families (Family_Index).ID),
            Family_Total,
            Payload_Bytes,
            Result);
         if Result = Success then
            Allocation_Faults.Check (Checkpoint_Reference_Allocation);
            References := new Snapshot_Entry_Reference_Array (1 .. Family_Total);
            State.Gate.Copy_Family_Snapshot
              (Column_Family_ID (Plan.Manifest.Base.Families (Family_Index).ID), References, Result);
            if Result /= Success then
               Free_Snapshot_References (References);
               return;
            end if;
            for Reference of References.all loop
               if Reference.Image = null
                 or else Reference.Sequence = 0
                 or else Interfaces.Unsigned_64 (Reference.Sequence) > Plan.Manifest.Replay_Boundary
               then
                  Free_Snapshot_References (References);
                  Result := Corrupt;
                  return;
               end if;
               Next := Next + 1;
               Reference.Image.References.Retain;
               Plan.Images (Next) := Reference.Image;
               Plan.Base (Next) :=
                 (Family       => Column_Family_ID (Plan.Manifest.Base.Families (Family_Index).ID),
                  Image        => Reference.Image,
                  Key_Offset   => Reference.Key_Offset,
                  Key_Length   => Reference.Key_Length,
                  Value_Offset => Reference.Value_Offset,
                  Value_Length => Reference.Value_Length,
                  Sequence     => Reference.Sequence);
            end loop;
            Free_Snapshot_References (References);
         elsif Result /= Not_Found then
            return;
         end if;
      end loop;
      if Next /= Entry_Total then
         Result := Invalid_State;
         return;
      end if;
      Plan.Activation_Ready := True;
      Result := Success;
   exception
      when Storage_Error =>
         Free_Snapshot_References (References);
         Result := Capacity_Exceeded;
      when others =>
         Free_Snapshot_References (References);
         raise;
   end Prepare_Live_Checkpoint_Base;

   procedure Release_Checkpoint_Plan (Plan : in out Checkpoint_Plan) is
   begin
      LSM_Runtime.Release (Plan.Manifest);
      for Value of Plan.SSTs loop
         LSM_Runtime.Release (Value);
      end loop;
      if Plan.Recovered_SSTs /= null then
         for Value of Plan.Recovered_SSTs.all loop
            LSM_Runtime.Release (Value);
         end loop;
         Free_Recovered_SSTs (Plan.Recovered_SSTs);
      end if;
      if Plan.Images /= null then
         for Image of Plan.Images.all loop
            Release_Image (Image);
         end loop;
         Free_Checkpoint_Images (Plan.Images);
      end if;
      Free_State_Entries (Plan.Base);
      Release_History (Plan.History, Plan.History_Count);
      Plan.Activation_Ready := False;
   end Release_Checkpoint_Plan;

   function Identity_Less (Left, Right : Heads.Identifier) return Boolean is
   begin
      for Index in Heads.Identifier_Index loop
         if Left (Index) < Right (Index) then
            return True;
         elsif Left (Index) > Right (Index) then
            return False;
         end if;
      end loop;
      return False;
   end Identity_Less;

   procedure Sort_Checkpoint_Identities (Value : in out LSM_Runtime.Checkpoint_Manifest) is
   begin
      for Index in Value.Identities'First + 1 .. Value.Identities'Last loop
         declare
            Item   : constant Heads.Identifier := Value.Identities (Index);
            Cursor : Positive := Index;
         begin
            while Cursor > Value.Identities'First and then Identity_Less (Item, Value.Identities (Cursor - 1))
            loop
               Value.Identities (Cursor) := Value.Identities (Cursor - 1);
               Cursor := Cursor - 1;
            end loop;
            Value.Identities (Cursor) := Item;
         end;
      end loop;
   end Sort_Checkpoint_Identities;

   procedure Build_Checkpoint_Plan
     (State         : not null Engine_State_Access;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Plan          : out Checkpoint_Plan;
      Result        : out Outcome_Code;
      Replace_Current_Runs : Boolean := False;
      Allow_Fenced  : Boolean := False)
   is
      Base           : Manifests.Manifest;
      Head           : Head_Snapshot;
      Generation     : Generation_Value;
      Uncertain      : Boolean;
      Fenced         : Boolean;
      Identity_Total : Natural;
      Prior          : constant LSM_Runtime.Checkpoint_Manifest_Access := State.Checkpoint_Manifest;
      Existing_Run_Total : Natural := 0;
      New_Run_Total  : Natural := 0;
      Run_Total      : Natural := 0;
      Run_Index      : Natural := 0;
      Allocation     : LSM_Runtime.Allocation_Status;
      --  This transient projection has exactly the persisted manifest family
      --  slot extent. It changes no database limit and lets map validation
      --  finish before any SST allocation.
      Required_Families : array (Manifests.Family_Slot) of Boolean := [others => False];

      function Run_For (Family_ID : Column_Family_ID) return Identifier is
      begin
         for Run of Runs loop
            if Run.Family_ID = Family_ID then
               return Run.Run_ID;
            end if;
         end loop;
         return Zero_Identifier;
      end Run_For;

      procedure Family_Requires_Run
        (Family_ID : Column_Family_ID; Required : out Boolean; Status : out Outcome_Code)
      is
         Entry_Total   : Natural;
         Payload_Bytes : Natural;
      begin
         Required := False;
         if Replace_Current_Runs or else State.LSM_Authority.Replay_Boundary = 0 then
            State.Gate.Family_Snapshot_Requirements (Family_ID, Entry_Total, Payload_Bytes, Status);
         else
            State.Gate.Family_Delta_Snapshot (Family_ID, null, Entry_Total, Payload_Bytes, Status);
         end if;
         if Status = Success then
            Required := True;
         elsif Status = Not_Found then
            Status := Success;
         end if;
      end Family_Requires_Run;
   begin
      Plan := (others => <>);
      if Is_Zero (Manifest_ID)
        or else Is_Zero (Transition_ID)
        or else Manifest_ID = Transition_ID
        or else not State.LSM_Authority.Enabled
      then
         Result := Invalid_State;
         return;
      --  A readable v2 manifest has no serializable observation authority and
      --  cannot be silently upgraded by Flush. Only an explicit future
      --  migration may select and publish the missing persisted limits.
      elsif State.LSM_Authority.Maximum_Point_Reads_Per_Transaction = 0
        or else State.LSM_Authority.Maximum_Scan_Ranges_Per_Transaction = 0
      then
         Result := Unsupported_Format;
         return;
      end if;
      State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced and then not Allow_Fenced then
         Result := Stale_Writer;
         return;
      elsif Head.Highest = 0
        or else Head.Transition_Number = Interfaces.Unsigned_64'Last
        or else Head.Latest_Manifest = Zero_Identifier
        or else Manifest_ID = Head.Latest_Manifest
        or else Transition_ID = Head.Transition_ID
      then
         Result := Invalid_State;
         return;
      end if;
      State.Gate.Checkpoint_Metadata (Base, Identity_Total, Result);
      if Result /= Success then
         return;
      elsif Base.Registry_Revision = Interfaces.Unsigned_64'Last then
         Result := Capacity_Exceeded;
         return;
      --  Root revision one and exact one-step predecessor validation make
      --  Registry_Revision the current manifest-chain depth. The persisted
      --  history limit is therefore the sole authority for another immutable
      --  successor; equality rejects before any object publication.
      elsif Base.Registry_Revision
        >= Interfaces.Unsigned_64 (Base.Limits.Maximum_Manifest_History)
      then
         Result := Capacity_Exceeded;
         return;
      elsif Interfaces.Unsigned_64 (Identity_Total)
        > Interfaces.Unsigned_64 (State.LSM_Authority.Maximum_Checkpoint_Identities)
      then
         Result := Capacity_Exceeded;
         return;
      end if;
      if State.LSM_Authority.Replay_Boundary = 0 then
         if Prior /= null then
            Result := Corrupt;
            return;
         end if;
      elsif Prior = null
        or else not LSM_Runtime.Structurally_Valid (Prior.all)
        or else Prior.Replay_Boundary /= State.LSM_Authority.Replay_Boundary
        or else Prior.Base.Manifest_ID /= To_Head_ID (Head.Latest_Manifest)
        or else Prior.Family_Total /= Natural (Base.Family_Total)
      then
         Result := Corrupt;
         return;
      else
         Existing_Run_Total := (if Replace_Current_Runs then 0 else Prior.Run_Total);
      end if;

      if Runs'Length > Natural (Base.Family_Total)
        or else (Runs'Length = 0 and then not Replace_Current_Runs)
      then
         Result := Invalid_State;
         return;
      end if;
      for Index in Runs'Range loop
         declare
            Family_Found : Boolean := False;
         begin
            for Family_Index in Manifests.Family_Slot range 1 .. Base.Family_Total loop
               if Runs (Index).Family_ID = Column_Family_ID (Base.Families (Family_Index).ID) then
                  Family_Found := True;
                  exit;
               end if;
            end loop;
            if not Family_Found
              or else Is_Zero (Runs (Index).Run_ID)
              or else Runs (Index).Run_ID = Manifest_ID
              or else Runs (Index).Run_ID = Transition_ID
            then
               Result := Invalid_State;
               return;
            end if;
            for Previous in Runs'First .. Index - 1 loop
               if Runs (Previous).Family_ID = Runs (Index).Family_ID
                 or else Runs (Previous).Run_ID = Runs (Index).Run_ID
               then
                  Result := Invalid_State;
                  return;
               end if;
            end loop;
         end;
      end loop;
      Plan.Expected_Generation := Generation;

      for Family_Index in Manifests.Family_Slot range 1 .. Base.Family_Total loop
         declare
            Family_ID : constant Column_Family_ID := Column_Family_ID (Base.Families (Family_Index).ID);
         begin
            Family_Requires_Run (Family_ID, Required_Families (Family_Index), Result);
            if Result /= Success then
               Release_Checkpoint_Plan (Plan);
               return;
            elsif Required_Families (Family_Index) and then Is_Zero (Run_For (Family_ID)) then
               Release_Checkpoint_Plan (Plan);
               Result := Invalid_State;
               return;
            end if;
         end;
      end loop;

      for Family_Index in Manifests.Family_Slot range 1 .. Base.Family_Total loop
         declare
            Family_ID : constant Column_Family_ID := Column_Family_ID (Base.Families (Family_Index).ID);
            Run_ID    : constant Identifier := Run_For (Family_ID);
         begin
            if Required_Families (Family_Index) then
               Build_Family_SST
                 (State,
                  Family_ID,
                  Run_ID,
                  Plan.SSTs (Family_Index),
                  Result,
                  Complete_View => Replace_Current_Runs,
                  Allow_Fenced  => Allow_Fenced);
               if Result = Success then
                  New_Run_Total := New_Run_Total + 1;
               else
                  if Result = Not_Found then
                     Result := Corrupt;
                  end if;
                  Release_Checkpoint_Plan (Plan);
                  return;
               end if;
            end if;
         end;
      end loop;
      if New_Run_Total > Natural'Last - Existing_Run_Total then
         Release_Checkpoint_Plan (Plan);
         Result := Capacity_Exceeded;
         return;
      end if;
      Run_Total := Existing_Run_Total + New_Run_Total;
      if Interfaces.Unsigned_64 (Run_Total)
        > Interfaces.Unsigned_64 (State.LSM_Authority.Maximum_Total_L0_Runs)
      then
         Release_Checkpoint_Plan (Plan);
         Result := Capacity_Exceeded;
         return;
      end if;

      Allocation_Faults.Check (Checkpoint_Manifest_Allocation);
      LSM_Runtime.Create_Checkpoint_Manifest
        (Natural (Base.Family_Total), Run_Total, Identity_Total, Plan.Manifest, Allocation);
      if Allocation /= LSM_Runtime.Allocated then
         Release_Checkpoint_Plan (Plan);
         Result := Capacity_Exceeded;
         return;
      end if;
      Base.Manifest_ID := To_Head_ID (Manifest_ID);
      Base.Previous_Manifest_ID := To_Head_ID (Head.Latest_Manifest);
      Base.Expected_Transition_ID := To_Head_ID (Head.Transition_ID);
      Base.Expected_Transition_Number := Head.Transition_Number;
      Base.Publication_Transition_ID := To_Head_ID (Transition_ID);
      Base.Publication_Transition_Number := Head.Transition_Number + 1;
      Base.Writer_Epoch := Head.Epoch;
      --  Manifest predecessor validation defines each successor as the next
      --  registry revision even when the family membership is unchanged.
      --  This is persisted transition-policy authority; changing it breaks
      --  predecessor compatibility and cacheless recovery validation.
      Base.Registry_Revision := Base.Registry_Revision + 1;
      Plan.Manifest.Base := Base;
      Plan.Manifest.Replay_Boundary := Interfaces.Unsigned_64 (Head.Highest);
      Plan.Manifest.Maximum_Total_L0_Runs := State.LSM_Authority.Maximum_Total_L0_Runs;
      Plan.Manifest.Maximum_Checkpoint_Identities := State.LSM_Authority.Maximum_Checkpoint_Identities;
      Plan.Manifest.Maximum_Point_Reads_Per_Transaction :=
        State.LSM_Authority.Maximum_Point_Reads_Per_Transaction;
      Plan.Manifest.Maximum_Scan_Ranges_Per_Transaction :=
        State.LSM_Authority.Maximum_Scan_Ranges_Per_Transaction;

      for Family_Index in Plan.Manifest.Families'Range loop
         declare
            Family_ID       : constant Interfaces.Unsigned_32 := Base.Families (Family_Index).ID;
            Authority_Found : Boolean := False;
            Old_First       : Natural := 0;
            Old_Total       : Natural := 0;
            Retained_Total  : Natural := 0;
            Family_Total    : Natural;
         begin
            for Family of State.LSM_Authority.Families loop
               if Family.ID = Family_ID then
                  Plan.Manifest.Families (Family_Index) := Family.State;
                  if Prior /= null then
                     Old_First := Prior.Families (Family_Index).First_Run;
                     Old_Total := Prior.Families (Family_Index).Run_Total;
                     if Family.State.First_Run /= Old_First
                       or else Family.State.Run_Total /= Old_Total
                     then
                        Release_Checkpoint_Plan (Plan);
                        Result := Corrupt;
                        return;
                     end if;
                  end if;
                  Authority_Found := True;
                  exit;
               end if;
            end loop;
            Retained_Total := (if Replace_Current_Runs then 0 else Old_Total);
            if not Authority_Found then
               Release_Checkpoint_Plan (Plan);
               Result := Corrupt;
               return;
            elsif Plan.SSTs (Family_Index) /= null
              and then
                (Retained_Total = Natural'Last
                 or else Interfaces.Unsigned_64 (Retained_Total) + 1
                           > Interfaces.Unsigned_64
                               (Plan.Manifest.Families (Family_Index).Maximum_L0_Runs))
            then
               Release_Checkpoint_Plan (Plan);
               Result := Capacity_Exceeded;
               return;
            end if;
            Family_Total := Retained_Total + (if Plan.SSTs (Family_Index) = null then 0 else 1);
            Plan.Manifest.Families (Family_Index).First_Run :=
              (if Family_Total = 0 then 0 else Run_Index + 1);
            Plan.Manifest.Families (Family_Index).Run_Total := Family_Total;
            if Retained_Total > 0 then
               for Offset in Natural range 0 .. Retained_Total - 1 loop
                  Run_Index := Run_Index + 1;
                  Plan.Manifest.Runs (Run_Index) := Prior.Runs (Old_First + Offset);
               end loop;
            end if;
            if Plan.SSTs (Family_Index) /= null then
               if Replace_Current_Runs and then Prior /= null then
                  for Existing in Prior.Runs'Range loop
                     if Prior.Runs (Existing).Run_ID = Plan.SSTs (Family_Index).Run_ID then
                        Release_Checkpoint_Plan (Plan);
                        Result := Invalid_State;
                        return;
                     end if;
                  end loop;
               end if;
               for Existing in Positive range 1 .. Run_Index loop
                  if Plan.Manifest.Runs (Existing).Run_ID = Plan.SSTs (Family_Index).Run_ID then
                     Release_Checkpoint_Plan (Plan);
                     Result := Invalid_State;
                     return;
                  end if;
               end loop;
               if not Replace_Current_Runs
                 and then Old_Total > 0
                 and then Plan.Manifest.Runs (Run_Index).Highest_Sequence
                           >= Plan.SSTs (Family_Index).Lowest_Sequence
               then
                  Release_Checkpoint_Plan (Plan);
                  Result := Corrupt;
                  return;
               end if;
               Run_Index := Run_Index + 1;
               Plan.Manifest.Runs (Run_Index) :=
                 (Run_ID                => Plan.SSTs (Family_Index).Run_ID,
                  Lowest_Sequence       => Plan.SSTs (Family_Index).Lowest_Sequence,
                  Highest_Sequence      => Plan.SSTs (Family_Index).Highest_Sequence,
                  Entry_Total           => Interfaces.Unsigned_32 (Plan.SSTs (Family_Index).Entry_Total),
                  Logical_Payload_Bytes => Plan.SSTs (Family_Index).Logical_Payload_Bytes);
            end if;
         end;
      end loop;
      State.Gate.Copy_Checkpoint_Identities (Plan.Manifest, Result);
      if Result /= Success then
         Release_Checkpoint_Plan (Plan);
         return;
      end if;
      Sort_Checkpoint_Identities (Plan.Manifest.all);
      if Run_Index /= Run_Total or else not LSM_Runtime.Structurally_Valid (Plan.Manifest.all) then
         Release_Checkpoint_Plan (Plan);
         Result := Corrupt;
         return;
      end if;
      Prepare_Live_Checkpoint_Base (State, Plan, Result);
      if Result /= Success then
         Release_Checkpoint_Plan (Plan);
         return;
      end if;
      Result := Success;
   exception
      when Storage_Error =>
         Release_Checkpoint_Plan (Plan);
         Result := Capacity_Exceeded;
      when others =>
         Release_Checkpoint_Plan (Plan);
         raise;
   end Build_Checkpoint_Plan;

   procedure Build_Column_Family_Plan
     (State              : not null Engine_State_Access;
      Configuration      : Column_Family_Configuration;
      Manifest_ID        : Identifier;
      Transition_ID      : Identifier;
      Prepare_Activation : Boolean;
      Plan               : out Checkpoint_Plan;
      Result             : out Outcome_Code)
   is
      Base           : Manifests.Manifest;
      Head           : Head_Snapshot;
      Generation     : Generation_Value;
      Uncertain      : Boolean;
      Fenced         : Boolean;
      Identity_Total : Natural;
      Prior          : constant LSM_Runtime.Checkpoint_Manifest_Access := State.Checkpoint_Manifest;
      Candidate      : constant Manifests.Column_Family_Configuration :=
        To_Manifest_Configuration (Configuration);
      Allocation     : LSM_Runtime.Allocation_Status;
   begin
      Plan := (others => <>);
      if Is_Zero (Manifest_ID)
        or else Is_Zero (Transition_ID)
        or else Manifest_ID = Transition_ID
        or else not Manifests.Valid_Configuration (Candidate)
        or else Configuration.Memtable_Max_Bytes = 0
        or else Configuration.Memtable_Max_Entries = 0
        or else Configuration.Maximum_L0_Runs = 0
      then
         Result := Invalid_State;
         return;
      elsif not State.LSM_Authority.Enabled
        or else State.LSM_Authority.Maximum_Point_Reads_Per_Transaction = 0
        or else State.LSM_Authority.Maximum_Scan_Ranges_Per_Transaction = 0
      then
         Result := Unsupported_Format;
         return;
      end if;

      State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      elsif Head.Transition_Number = Interfaces.Unsigned_64'Last
        or else Head.Latest_Manifest = Zero_Identifier
        or else Manifest_ID = Head.Latest_Manifest
        or else Transition_ID = Head.Transition_ID
      then
         Result := Invalid_State;
         return;
      end if;

      State.Gate.Checkpoint_Metadata (Base, Identity_Total, Result);
      if Result /= Success then
         return;
      --  Root revision one plus exact one-step predecessors makes this the
      --  current manifest-chain depth. The persisted history bound is the
      --  authority for one more immutable registry successor.
      elsif Base.Registry_Revision = Interfaces.Unsigned_64'Last
        or else Base.Registry_Revision
          >= Interfaces.Unsigned_64 (Base.Limits.Maximum_Manifest_History)
        or else Base.Family_Total = Manifests.Family_Count'Last
        or else Interfaces.Unsigned_32 (Base.Family_Total) >= Base.Limits.Maximum_Column_Families
      then
         Result := Capacity_Exceeded;
         return;
      elsif Prior = null then
         --  Append carries an already-published checkpoint exactly. A fresh
         --  root has no retained checkpoint plan and cannot be converted here
         --  without inventing caller-owned SST identities.
         Result := Invalid_State;
         return;
      elsif not LSM_Runtime.Structurally_Valid (Prior.all)
        or else Prior.Base /= Base
        or else Prior.Family_Total /= Natural (Base.Family_Total)
        or else Prior.Replay_Boundary /= State.LSM_Authority.Replay_Boundary
      then
         Result := Corrupt;
         return;
      elsif Prior.Identity_Total /= Identity_Total then
         --  Additional reserved identities mean commits exist after the
         --  retained checkpoint. The caller must Flush that suffix before a
         --  registry-only successor can preserve it exactly.
         Result := Invalid_State;
         return;
      end if;

      for Index in Manifests.Family_Slot range 1 .. Base.Family_Total loop
         if Candidate.ID = Base.Families (Index).ID
           or else
             (Candidate.Name_Length = Base.Families (Index).Name_Length
              and then Candidate.Name (1 .. Candidate.Name_Length)
                         = Base.Families (Index).Name (1 .. Base.Families (Index).Name_Length))
         then
            Result := Already_Exists;
            return;
         end if;
      end loop;
      if Candidate.ID <= Base.Families (Base.Family_Total).ID then
         Result := Invalid_State;
         return;
      end if;

      Allocation_Faults.Check (Checkpoint_Manifest_Allocation);
      --  The successor's only new extent is one family slot. Run and identity
      --  extents come unchanged from the authenticated retained checkpoint.
      LSM_Runtime.Create_Checkpoint_Manifest
        (Prior.Family_Total + 1,
         Prior.Run_Total,
         Prior.Identity_Total,
         Plan.Manifest,
         Allocation);
      if Allocation /= LSM_Runtime.Allocated then
         Result := Capacity_Exceeded;
         return;
      end if;

      Base.Manifest_ID := To_Head_ID (Manifest_ID);
      Base.Previous_Manifest_ID := To_Head_ID (Head.Latest_Manifest);
      Base.Expected_Transition_ID := To_Head_ID (Head.Transition_ID);
      Base.Expected_Transition_Number := Head.Transition_Number;
      Base.Publication_Transition_ID := To_Head_ID (Transition_ID);
      Base.Publication_Transition_Number := Head.Transition_Number + 1;
      Base.Writer_Epoch := Head.Epoch;
      Base.Registry_Revision := Base.Registry_Revision + 1;
      Base.Family_Total := Base.Family_Total + 1;
      Base.Families (Base.Family_Total) := Candidate;

      Plan.Manifest.Base := Base;
      Plan.Manifest.Replay_Boundary := Prior.Replay_Boundary;
      Plan.Manifest.Maximum_Total_L0_Runs := Prior.Maximum_Total_L0_Runs;
      Plan.Manifest.Maximum_Checkpoint_Identities := Prior.Maximum_Checkpoint_Identities;
      Plan.Manifest.Maximum_Point_Reads_Per_Transaction :=
        Prior.Maximum_Point_Reads_Per_Transaction;
      Plan.Manifest.Maximum_Scan_Ranges_Per_Transaction :=
        Prior.Maximum_Scan_Ranges_Per_Transaction;
      Plan.Manifest.Families (1 .. Prior.Family_Total) := Prior.Families;
      Plan.Manifest.Families (Plan.Manifest.Family_Total) :=
        (Memtable_Max_Bytes   => Configuration.Memtable_Max_Bytes,
         Memtable_Max_Entries => Configuration.Memtable_Max_Entries,
         Maximum_L0_Runs      => Configuration.Maximum_L0_Runs,
         First_Run            => 0,
         Run_Total            => 0);
      Plan.Manifest.Runs := Prior.Runs;
      Plan.Manifest.Identities := Prior.Identities;
      Plan.Expected_Generation := Generation;
      if not Manifests.Valid_Checkpoint_Chain_Predecessor (Plan.Manifest.Base, Prior.Base)
        or else not LSM_Runtime.Structurally_Valid (Plan.Manifest.all)
      then
         Release_Checkpoint_Plan (Plan);
         Result := Invalid_State;
      elsif Prepare_Activation then
         --  Direct composable activation needs the same complete current-state
         --  ownership graph as Flush. The appended family contributes no rows;
         --  all extents derive lazily from the authenticated live snapshot.
         Prepare_Live_Checkpoint_Base (State, Plan, Result);
         if Result /= Success then
            Release_Checkpoint_Plan (Plan);
         end if;
      else
         Result := Success;
      end if;
   exception
      when Storage_Error =>
         Release_Checkpoint_Plan (Plan);
         Result := Capacity_Exceeded;
      when others =>
         Release_Checkpoint_Plan (Plan);
         raise;
   end Build_Column_Family_Plan;

   protected body Database_Lifecycle is

      procedure Begin_Open (Result : out Outcome_Code) is
      begin
         if Mode /= Closed then
            Result := Invalid_State;
         else
            Mode := Opening;
            Result := Success;
         end if;
      end Begin_Open;

      procedure Complete_Open
        (State : not null Engine_State_Access; Visible : Sequence_Number; Result : out Outcome_Code) is
      begin
         if Mode /= Opening or else Current /= null then
            Result := Invalid_State;
         else
            Current := State;
            Last_Visible := Visible;
            Mode := Opened;
            Result := Success;
         end if;
      end Complete_Open;

      procedure Abort_Open is
      begin
         if Mode = Opening then
            Mode := Closed;
         end if;
      end Abort_Open;

      procedure Acquire (State : out Engine_State_Access; Result : out Outcome_Code) is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
         elsif Active_Calls = Natural'Last then
            Result := Capacity_Exceeded;
         else
            Active_Calls := Active_Calls + 1;
            State := Current;
            Result := Success;
         end if;
      end Acquire;

      procedure Release is
      begin
         if Active_Calls = 0 then
            raise Program_Error with "database lifecycle lease underflow";
         end if;
         Active_Calls := Active_Calls - 1;
         if Active_Calls = 0
           and then Mode in Resolving | Checkpointing
           and then Flyology.Wake_Sources.Descriptor (Quiescence_Wake) >= 0
           and then not Quiescence_Signalled
         then
            --  Checkpoint and refresh waiters borrow this persistent
            --  descriptor under the same protected lock. Publishing the zero
            --  count before the wake prevents a missed transition even if
            --  signalling reports an operating-system failure.
            Flyology.Wake_Sources.Signal (Quiescence_Wake);
            Quiescence_Signalled := True;
         end if;
      end Release;

      procedure Begin_Close (State : out Engine_State_Access; Result : out Outcome_Code) is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
         else
            Mode := Closing;
            State := Current;
            Result := Success;
         end if;
      end Begin_Close;

      procedure Begin_Resolve (State : out Engine_State_Access; Result : out Outcome_Code) is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
         else
            Mode := Resolving;
            State := Current;
            Result := Success;
         end if;
      end Begin_Resolve;

      procedure Begin_Composable_Resolve
        (State  : out Engine_State_Access;
         Result : out Outcome_Code)
      is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
            return;
         end if;
         if Active_Calls > 0 then
            --  Create the serialized wake before lifecycle admission so a
            --  descriptor failure leaves the open database unchanged.
            Flyology.Wake_Sources.Ensure (Quiescence_Wake);
         end if;
         Quiescence_Signalled := False;
         Mode := Resolving;
         State := Current;
         Result := Success;
      end Begin_Composable_Resolve;

      procedure Begin_Checkpoint (State : out Engine_State_Access; Result : out Outcome_Code) is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
         else
            Mode := Checkpointing;
            State := Current;
            Result := Success;
         end if;
      end Begin_Checkpoint;

      procedure Begin_Composable_Checkpoint
        (State  : out Engine_State_Access;
         Result : out Outcome_Code)
      is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
            return;
         end if;
         if Active_Calls > 0 then
            --  Creating the serialized wake before changing lifecycle mode
            --  makes any descriptor failure a pre-admission error. Once mode
            --  changes, the caller owns an exact cancellation obligation.
            Flyology.Wake_Sources.Ensure (Quiescence_Wake);
         end if;
         Quiescence_Signalled := False;
         Mode := Checkpointing;
         State := Current;
         Result := Success;
      end Begin_Composable_Checkpoint;

      procedure Promote_Composable_Checkpoint
        (Expected : not null Engine_State_Access;
         State    : out Engine_State_Access;
         Result   : out Outcome_Code)
      is
      begin
         State := null;
         if Active_Calls = 0 then
            raise Program_Error with "database lifecycle lease promotion underflow";
         elsif Mode /= Opened or else Current /= Expected then
            --  A concurrent close/resolve/checkpoint already owns the mode.
            --  Consume this exact lease so its waiter can observe quiescence.
            Active_Calls := Active_Calls - 1;
            if Active_Calls = 0
              and then Mode = Checkpointing
              and then Flyology.Wake_Sources.Descriptor (Quiescence_Wake) >= 0
              and then not Quiescence_Signalled
            then
               Flyology.Wake_Sources.Signal (Quiescence_Wake);
               Quiescence_Signalled := True;
            end if;
            Result := Invalid_State;
            return;
         end if;
         if Active_Calls > 1 then
            --  The caller's lease is atomically exchanged for checkpoint
            --  ownership. Remaining calls need the same persistent wake used
            --  by ordinary composable admission.
            Flyology.Wake_Sources.Ensure (Quiescence_Wake);
         end if;
         Active_Calls := Active_Calls - 1;
         Quiescence_Signalled := False;
         Mode := Checkpointing;
         State := Current;
         Result := Success;
      end Promote_Composable_Checkpoint;

      procedure Checkpoint_Wait_Source
        (Descriptor : out Interfaces.C.int;
         Ready_Now  : out Boolean)
      is
      begin
         if Mode /= Checkpointing or else Current = null then
            raise Program_Error with "checkpoint wait source outside checkpoint mode";
         end if;
         if Active_Calls = 0 then
            if Quiescence_Signalled then
               Flyology.Wake_Sources.Consume_All (Quiescence_Wake);
               Quiescence_Signalled := False;
            end if;
            --  Flyology.IO fixes every negative descriptor as invalid. Once
            --  readiness is already true, -1 explicitly means no borrowed
            --  wake descriptor remains for the caller to arm.
            Descriptor := -1;
            Ready_Now := True;
         else
            Flyology.Wake_Sources.Ensure (Quiescence_Wake);
            Descriptor := Flyology.Wake_Sources.Descriptor (Quiescence_Wake);
            Ready_Now := False;
         end if;
      end Checkpoint_Wait_Source;

      procedure Resolve_Wait_Source
        (Descriptor : out Interfaces.C.int;
         Ready_Now  : out Boolean)
      is
      begin
         if Mode /= Resolving or else Current = null then
            raise Program_Error with "refresh wait source outside resolving mode";
         end if;
         if Active_Calls = 0 then
            if Quiescence_Signalled then
               Flyology.Wake_Sources.Consume_All (Quiescence_Wake);
               Quiescence_Signalled := False;
            end if;
            --  Flyology.IO fixes negative descriptors as invalid. Once the
            --  lifecycle is quiescent no borrowed wake remains to arm.
            Descriptor := -1;
            Ready_Now := True;
         else
            Flyology.Wake_Sources.Ensure (Quiescence_Wake);
            Descriptor := Flyology.Wake_Sources.Descriptor (Quiescence_Wake);
            Ready_Now := False;
         end if;
      end Resolve_Wait_Source;

      entry Await_Quiescent when Mode in Closing | Resolving | Checkpointing and then Active_Calls = 0 is
      begin
         null;
      end Await_Quiescent;

      procedure Finish_Close is
      begin
         if Mode not in Closing | Resolving or else Active_Calls /= 0 then
            raise Program_Error with "invalid database close completion";
         end if;
         Current := null;
         Mode := Closed;
      end Finish_Close;

      procedure Finish_Resolve (State : not null Engine_State_Access; Visible : Sequence_Number) is
      begin
         if Mode /= Resolving or else Active_Calls /= 0 then
            raise Program_Error with "invalid database resolution completion";
         end if;
         Current := State;
         Last_Visible := Visible;
         Mode := Opened;
         Flyology.Wake_Sources.Release (Quiescence_Wake);
         Quiescence_Signalled := False;
      end Finish_Resolve;

      procedure Cancel_Resolve is
      begin
         if Mode /= Resolving or else Current = null then
            raise Program_Error with "invalid database resolution cancellation";
         end if;
         Mode := Opened;
         Flyology.Wake_Sources.Release (Quiescence_Wake);
         Quiescence_Signalled := False;
      end Cancel_Resolve;

      procedure Finish_Checkpoint is
      begin
         if Mode /= Checkpointing or else Active_Calls /= 0 or else Current = null then
            raise Program_Error with "invalid database checkpoint completion";
         end if;
         Mode := Opened;
         Flyology.Wake_Sources.Release (Quiescence_Wake);
         Quiescence_Signalled := False;
      end Finish_Checkpoint;

      procedure Finish_Checkpoint (State : not null Engine_State_Access; Visible : Sequence_Number) is
      begin
         if Mode /= Checkpointing or else Active_Calls /= 0 or else Current = null then
            raise Program_Error with "invalid database checkpoint replacement";
         end if;
         Current := State;
         Last_Visible := Visible;
         Mode := Opened;
         Flyology.Wake_Sources.Release (Quiescence_Wake);
         Quiescence_Signalled := False;
      end Finish_Checkpoint;

      procedure Cancel_Checkpoint is
      begin
         if Mode /= Checkpointing or else Current = null then
            raise Program_Error with "invalid database checkpoint cancellation";
         end if;
         Mode := Opened;
         Flyology.Wake_Sources.Release (Quiescence_Wake);
         Quiescence_Signalled := False;
      end Cancel_Checkpoint;

      procedure Set_Visible (Value : Sequence_Number) is
      begin
         --  Calls admitted before a close/resolve/checkpoint transition remain
         --  authoritative until their lifecycle lease drains. In particular,
         --  a cancelled checkpoint must reopen at their newest committed
         --  sequence rather than the value observed when waiting began.
         if Mode in Opened | Closing | Resolving | Checkpointing and then Value > Last_Visible then
            Last_Visible := Value;
         end if;
      end Set_Visible;

      function Highest (Result : out Outcome_Code) return Sequence_Number is
      begin
         if Mode /= Opened then
            Result := Invalid_State;
            return 0;
         else
            Result := Success;
            return Last_Visible;
         end if;
      end Highest;

   end Database_Lifecycle;

   type Lifecycle_Lease is new Ada.Finalization.Limited_Controlled with record
      Life  : Database_Lifecycle_Access := null;
      State : Engine_State_Access := null;
   end record;

   overriding
   procedure Finalize (Item : in out Lifecycle_Lease) is
   begin
      if Item.Life /= null then
         Item.Life.Release;
         Item.Life := null;
         Item.State := null;
      end if;
   end Finalize;

   procedure Acquire (Item : in out Database; Lease : in out Lifecycle_Lease; Result : out Outcome_Code) is
   begin
      Item.Life.Acquire (Lease.State, Result);
      if Result = Success then
         Lease.Life := Item.Life'Unchecked_Access;
      end if;
   end Acquire;

   procedure Promote_Composable_Checkpoint
     (Lease  : in out Lifecycle_Lease;
      State  : out Engine_State_Access;
      Result : out Outcome_Code)
   is
   begin
      if Lease.Life = null or else Lease.State = null then
         raise Program_Error with "composable checkpoint requires one database lifecycle lease";
      end if;
      Lease.Life.Promote_Composable_Checkpoint (Lease.State, State, Result);
      --  Every normal return consumed the lease, whether promotion won or a
      --  concurrent lifecycle transition won. An exception leaves it owned so
      --  controlled finalization performs the ordinary release.
      Lease.Life := null;
      Lease.State := null;
   end Promote_Composable_Checkpoint;

   procedure Release (Lease : in out Lifecycle_Lease) is
   begin
      if Lease.Life /= null then
         Lease.Life.Release;
         Lease.Life := null;
         Lease.State := null;
      end if;
   end Release;

   type Activation_Guard is new Ada.Finalization.Limited_Controlled with record
      Life   : Database_Lifecycle_Access := null;
      Active : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Activation_Guard) is
   begin
      if Item.Active and then Item.Life /= null then
         Item.Life.Abort_Open;
         Item.Active := False;
      end if;
   end Finalize;

   type Resolve_Guard is new Ada.Finalization.Limited_Controlled with record
      Life   : Database_Lifecycle_Access := null;
      Active : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Resolve_Guard) is
   begin
      if Item.Active and then Item.Life /= null then
         Item.Life.Cancel_Resolve;
         Item.Active := False;
      end if;
   end Finalize;

   type Checkpoint_Guard is new Ada.Finalization.Limited_Controlled with record
      Life   : Database_Lifecycle_Access := null;
      Active : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Checkpoint_Guard) is
   begin
      if Item.Active and then Item.Life /= null then
         Item.Life.Cancel_Checkpoint;
         Item.Active := False;
      end if;
   end Finalize;

   type Admission_Guard is new Ada.Finalization.Limited_Controlled with record
      State  : Engine_State_Access := null;
      Tokens : Token_Group;
      Count  : Group_Count := 0;
      Next   : Natural range 1 .. Maximum_Commit_Slots + 1 := 1;
      Active : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Admission_Guard) is
      Ignored_Receipt : Internal_Receipt;
      Ignored_Arena   : Transaction_Arena_Access;
      Ignored_Result  : Outcome_Code;
   begin
      if Item.Active then
         if Item.Next <= Item.Count then
            for Index in Commit_Slot range Item.Next .. Item.Count loop
               Item.State.Gate.Await_Result (Item.Tokens (Index).Index)
                 (Item.Tokens (Index).Generation, Ignored_Receipt, Ignored_Arena, Ignored_Result);
               Release_Image (Ignored_Receipt.Image);
               Release_Arena (Ignored_Arena);
            end loop;
         end if;
         Item.Active := False;
      end if;
   end Finalize;

   procedure Free_Worker is new
     Ada.Unchecked_Deallocation (Object => Commit_Worker, Name => Commit_Worker_Access);
   procedure Free_State is new
     Ada.Unchecked_Deallocation (Object => Engine_State, Name => Engine_State_Access);

   procedure Release_State_Images (State : not null Engine_State_Access) is
      Batch : Runtime_Batch;
   begin
      for Index in Positive range 1 .. State.Gate.History_Length loop
         State.Gate.Take_History_Batch (Index, Batch);
         Release_Runtime_Batch (Batch);
      end loop;
      Free_State_Entries (State.Checkpoint_Base);
      if State.Checkpoint_Images /= null then
         for Image of State.Checkpoint_Images.all loop
            Release_Image (Image);
         end loop;
         Free_Checkpoint_Images (State.Checkpoint_Images);
      end if;
      LSM_Runtime.Release (State.Checkpoint_Manifest);
   end Release_State_Images;

   procedure Put_U16 (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_16)
   is
   begin
      Image (Position) := Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);
      Image (Position + 1) := Byte (Value and 16#FF#);
   end Put_U16;

   procedure Put_U32 (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_32)
   is
   begin
      for Offset in Natural range 0 .. 3 loop
         Image (Position + Offset) := Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64 (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_64)
   is
   begin
      for Offset in Natural range 0 .. 7 loop
         Image (Position + Offset) := Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   procedure Put_Identifier (Image : in out Formats.Byte_Array; Position : Natural; Value : Identifier) is
   begin
      for Index in Identifier_Index loop
         Image (Position + Index - Identifier_Index'First) := Value (Index);
      end loop;
   end Put_Identifier;

   procedure Append_Array (Target : in out Flyology.Bytes.Unbounded_Bytes; Source : Formats.Byte_Array) is
   begin
      for Value of Source loop
         Flyology.Bytes.Append (Target, Ada.Streams.Stream_Element (Value));
      end loop;
   end Append_Array;

   procedure Append_U32 (Target : in out Flyology.Bytes.Unbounded_Bytes; Value : Interfaces.Unsigned_32) is
   begin
      for Offset in reverse Natural range 0 .. 3 loop
         Flyology.Bytes.Append
           (Target, Ada.Streams.Stream_Element (Interfaces.Shift_Right (Value, Offset * 8) and 16#FF#));
      end loop;
   end Append_U32;

   function CRC_32C (Data : Flyology.Bytes.Unbounded_Bytes; Count : Natural) return Interfaces.Unsigned_32 is
      --  Externally fixed reflected Castagnoli polynomial with all-ones initial
      --  state and final complement, matching the persisted-format CRC-32C.
      Polynomial : constant Interfaces.Unsigned_32 := 16#82F6_3B78#;
      Result     : Interfaces.Unsigned_32 := 16#FFFF_FFFF#;
   begin
      for Index in Positive range 1 .. Count loop
         Result := Result xor Interfaces.Unsigned_32 (Flyology.Bytes.Element (Data, Index));
         for Bit in Natural range 0 .. 7 loop
            pragma Unreferenced (Bit);
            if (Result and 1) = 1 then
               Result := Interfaces.Shift_Right (Result, 1) xor Polynomial;
            else
               Result := Interfaces.Shift_Right (Result, 1);
            end if;
         end loop;
      end loop;
      return not Result;
   end CRC_32C;

   function New_Image (Data : Formats.Byte_Array) return Shared_Image_Access is
      Result : Shared_Image_Access := Allocate_Shared_Image;
   begin
      Flyology.Bytes.Reserve_Capacity (Result.Data, Data'Length);
      Append_Array (Result.Data, Data);
      return Result;
   exception
      when others =>
         Release_Image (Result);
         raise;
   end New_Image;

   procedure Release_Checkpoint_Images (Images : in out Checkpoint_Image_Array_Access) is
   begin
      if Images /= null then
         for Image of Images.all loop
            Release_Image (Image);
         end loop;
         Free_Checkpoint_Images (Images);
      end if;
   end Release_Checkpoint_Images;

   procedure Prepare_Checkpoint_Images
     (Plan : in out Checkpoint_Plan; Result : out Outcome_Code) is
   begin
      Release_Checkpoint_Images (Plan.Images);
      if Plan.Manifest = null then
         Result := Success;
         return;
      elsif Plan.Manifest.Run_Total = 0 then
         Result := Success;
         return;
      elsif Plan.Recovered_SSTs = null
        or else Plan.Recovered_SSTs'Length /= Plan.Manifest.Run_Total
      then
         Result := Corrupt;
         return;
      end if;
      Allocation_Faults.Check (Recovery_Checkpoint_Image_Allocation);
      Plan.Images := new Checkpoint_Image_Array'(1 .. Plan.Manifest.Run_Total => null);
      for Index in Plan.Recovered_SSTs'Range loop
         if Plan.Recovered_SSTs (Index) = null then
            Result := Corrupt;
            Release_Checkpoint_Images (Plan.Images);
            return;
         else
            Allocation_Faults.Check (Recovery_Checkpoint_Image_Allocation);
            Plan.Images (Index) := New_Image (Plan.Recovered_SSTs (Index).Payload);
         end if;
      end loop;
      Result := Success;
   exception
      when Storage_Error =>
         Release_Checkpoint_Images (Plan.Images);
         Result := Capacity_Exceeded;
      when others =>
         Release_Checkpoint_Images (Plan.Images);
         raise;
   end Prepare_Checkpoint_Images;

   procedure Prepare_Checkpoint_Base
     (Plan : in out Checkpoint_Plan; Result : out Outcome_Code)
   is
      Entry_Total : Natural := 0;
   begin
      Free_State_Entries (Plan.Base);
      if Plan.Manifest = null then
         Result := Success;
         return;
      elsif Plan.Manifest.Run_Total = 0 then
         Result := Success;
         return;
      elsif Plan.Recovered_SSTs = null
        or else Plan.Recovered_SSTs'Length /= Plan.Manifest.Run_Total
      then
         Result := Corrupt;
         return;
      end if;
      for SST of Plan.Recovered_SSTs.all loop
         if SST = null then
            Result := Corrupt;
            return;
         elsif SST.Entry_Total > Natural'Last - Entry_Total then
            Result := Capacity_Exceeded;
            return;
         end if;
         Entry_Total := Entry_Total + SST.Entry_Total;
      end loop;
      --  This is merge scratch, not live-state capacity: immutable deltas may
      --  contain overwritten values and tombstones. Its exact upper extent is
      --  derived from authenticated SST entry counts; the merged result is
      --  checked separately against persisted live-entry/live-byte limits.
      if Entry_Total > 0 then
         Allocation_Faults.Check (Recovery_Snapshot_Base_Allocation);
         Plan.Base := new State_Entry_Array (1 .. Entry_Total);
      end if;
      Result := Success;
   exception
      when Storage_Error =>
         Free_State_Entries (Plan.Base);
         Result := Capacity_Exceeded;
      when others =>
         Free_State_Entries (Plan.Base);
         raise;
   end Prepare_Checkpoint_Base;

   procedure Build_Runtime_Batch
     (Items    : Work_Group;
      Count    : Group_Count;
      Expected : Head_Snapshot;
      Batch    : out Runtime_Batch;
      Result   : out Outcome_Code)
   is
      Header           : Formats.Byte_Array (0 .. Batch_Header_Length - 1) := [others => 0];
      Transaction_Head : Formats.Byte_Array (0 .. Transaction_Frame_Header_Length - 1) := [others => 0];
      Mutation_Head    : Formats.Byte_Array (0 .. Mutation_Frame_Header_Length - 1) := [others => 0];
      Mutation_Total   : Natural := 0;
      Image_Length     : Interfaces.Unsigned_64 := Batch_Header_Length + Batch_Trailer_Length;
      Next_Mutation    : Natural := 1;
      Cursor           : Natural := Batch_Header_Length;
      Publication_ID   : Identifier;
   begin
      Batch := (others => <>);
      if Count = 0
        or else Expected.Version /= Interfaces.Unsigned_16 (Heads.Current_Format)
        or else Is_Zero (Expected.Latest_Manifest)
        or else Expected.Highest > Sequence_Number'Last - Sequence_Number (Count)
        or else Expected.Transition_Number = Interfaces.Unsigned_64'Last
      then
         Result := Invalid_State;
         return;
      end if;
      for Index in Commit_Slot range 1 .. Count loop
         if Items (Index).Arena = null
           or else Mutation_Count (Items (Index)) = 0
           or else Mutation_Count (Items (Index)) > Natural'Last - Mutation_Total
           or else (Natural'Size > Interfaces.Unsigned_32'Size
                    and then (Interfaces.Unsigned_64 (Mutation_Total)
                              > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
                              or else Interfaces.Unsigned_64 (Mutation_Count (Items (Index)))
                                      > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
                                        - Interfaces.Unsigned_64 (Mutation_Total)))
         then
            Result := Invalid_State;
            return;
         end if;
         Mutation_Total := Mutation_Total + Mutation_Count (Items (Index));
         if Image_Length
           > Interfaces.Unsigned_64'Last - Interfaces.Unsigned_64 (Transaction_Frame_Header_Length)
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         Image_Length := Image_Length + Transaction_Frame_Header_Length;
         for Mutation_Index in Positive range 1 .. Mutation_Count (Items (Index)) loop
            declare
               Mutation     : Owned_Mutation renames Items (Index).Arena.Mutations (Mutation_Index);
               --  Derived exact byte extents from the caller-owned mutation;
               --  U32/wire and aggregate checks below are the only admission.
               Key_Bytes    : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Mutation.Key_Length);
               Value_Bytes  : constant Interfaces.Unsigned_64 :=
                 Interfaces.Unsigned_64 (Mutation.Value_Length);
               Frame_Length : Interfaces.Unsigned_64;
            begin
               if Key_Bytes > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
                 or else Value_Bytes > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
                 or else Key_Bytes > Interfaces.Unsigned_64'Last - Value_Bytes
                 or else Key_Bytes + Value_Bytes
                         > Interfaces.Unsigned_64'Last - Interfaces.Unsigned_64 (Mutation_Frame_Header_Length)
                 or else Interfaces.Unsigned_64 (Flyology.Bytes.Length (Mutation.Payload))
                         /= Key_Bytes + Value_Bytes
               then
                  Result := Capacity_Exceeded;
                  return;
               end if;
               Frame_Length :=
                 Interfaces.Unsigned_64 (Mutation_Frame_Header_Length) + Key_Bytes + Value_Bytes;
               if Image_Length > Interfaces.Unsigned_64'Last - Frame_Length then
                  Result := Capacity_Exceeded;
                  return;
               end if;
               Image_Length := Image_Length + Frame_Length;
            end;
         end loop;
      end loop;
      if Mutation_Total = 0 or else Image_Length > Interfaces.Unsigned_64 (Natural'Last) then
         Result := Capacity_Exceeded;
         return;
      end if;

      Allocation_Faults.Check (Batch_Descriptor_Allocation);
      Batch.Transactions := new Runtime_Transaction_Array (1 .. Count);
      Batch.Mutations := new Runtime_Mutation_Array (1 .. Mutation_Total);
      Batch.Image := Allocate_Shared_Image;
      Flyology.Bytes.Reserve_Capacity (Batch.Image.Data, Natural (Image_Length));
      Batch.Database_ID := Expected.Database_ID;
      Batch.Epoch := Expected.Epoch;
      Batch.Batch_ID := Items (1).Batch_ID;
      Batch.Previous_Batch_ID := (if Expected.Highest = 0 then Zero_Identifier else Expected.Latest_Batch);
      Batch.Expected_Transition_ID := Expected.Transition_ID;
      Batch.Expected_Transition_Number := Expected.Transition_Number;
      --  Project domain-separation tags C3/C4 generate deterministic internal
      --  transition IDs from the exact next ordinal; C4 is the collision
      --  fallback required to differ from the predecessor. They are not wire tags.
      Publication_ID := Structural_ID (16#C3#, Expected.Transition_Number + 1);
      if Publication_ID = Expected.Transition_ID then
         Publication_ID := Structural_ID (16#C4#, Expected.Transition_Number + 1);
      end if;
      Batch.Publication_Transition_ID := Publication_ID;
      Batch.Publication_Transition_Number := Expected.Transition_Number + 1;
      Batch.First_Sequence := Expected.Highest + 1;
      Batch.Last_Sequence := Expected.Highest + Sequence_Number (Count);
      Batch.Transaction_Total := Count;
      Batch.Mutation_Total := Mutation_Total;

      --  Emit the frozen operational batch-v1 map: common fields
      --  0/8/10/11/12/28/32/40; header fields 44..152; transaction and mutation
      --  prefixes 32/14 bytes. These offsets mirror persisted-formats.md.
      Header (0 .. 7) :=
        [Character'Pos ('F'),
         Character'Pos ('L'),
         Character'Pos ('Y'),
         Character'Pos ('B'),
         Character'Pos ('A'),
         Character'Pos ('T'),
         Character'Pos ('C'),
         Character'Pos ('1')];
      Put_U16 (Header, 8, Batch_Format_Version_Code);
      Header (10) := Batch_Object_Kind_Code;
      Put_Identifier (Header, 12, Identifier (Batch.Database_ID));
      Put_U32 (Header, 28, Batch_Header_Length);
      Put_U64 (Header, 32, Image_Length - Batch_Header_Length - Batch_Trailer_Length);
      Put_U64 (Header, 44, Batch.Epoch);
      Put_Identifier (Header, 52, Batch.Batch_ID);
      Put_Identifier (Header, 68, Batch.Previous_Batch_ID);
      Put_Identifier (Header, 84, Batch.Expected_Transition_ID);
      Put_U64 (Header, 100, Batch.Expected_Transition_Number);
      Put_Identifier (Header, 108, Batch.Publication_Transition_ID);
      Put_U64 (Header, 124, Batch.Publication_Transition_Number);
      Put_U64 (Header, 132, Interfaces.Unsigned_64 (Batch.First_Sequence));
      Put_U64 (Header, 140, Interfaces.Unsigned_64 (Batch.Last_Sequence));
      Put_U32 (Header, 148, Interfaces.Unsigned_32 (Count));
      Put_U32 (Header, 152, Interfaces.Unsigned_32 (Mutation_Total));
      Put_U32 (Header, 40, Formats.CRC_32C (Header));
      Append_Array (Batch.Image.Data, Header);

      for Transaction_Index in Commit_Slot range 1 .. Count loop
         declare
            Item        : Work_Item renames Items (Transaction_Index);
            Body_Length : Interfaces.Unsigned_64 := 0;
         begin
            for Mutation_Index in Positive range 1 .. Mutation_Count (Item) loop
               declare
                  Mutation    : Owned_Mutation renames Item.Arena.Mutations (Mutation_Index);
                  --  Derived exact byte extents repeated while emitting the
                  --  already-admitted frame; they introduce no new limits.
                  Key_Bytes   : constant Interfaces.Unsigned_64 :=
                    Interfaces.Unsigned_64 (Mutation.Key_Length);
                  Value_Bytes : constant Interfaces.Unsigned_64 :=
                    Interfaces.Unsigned_64 (Mutation.Value_Length);
                  Frame_Bytes : Interfaces.Unsigned_64;
               begin
                  if Key_Bytes > Interfaces.Unsigned_64'Last - Value_Bytes
                    or else Key_Bytes + Value_Bytes
                            > Interfaces.Unsigned_64'Last
                              - Interfaces.Unsigned_64 (Mutation_Frame_Header_Length)
                  then
                     Release_Runtime_Batch (Batch);
                     Result := Capacity_Exceeded;
                     return;
                  end if;
                  Frame_Bytes :=
                    Interfaces.Unsigned_64 (Mutation_Frame_Header_Length) + Key_Bytes + Value_Bytes;
                  if Body_Length > Interfaces.Unsigned_64'Last - Frame_Bytes then
                     Release_Runtime_Batch (Batch);
                     Result := Capacity_Exceeded;
                     return;
                  end if;
                  Body_Length := Body_Length + Frame_Bytes;
               end;
            end loop;
            if Body_Length > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last) then
               Release_Runtime_Batch (Batch);
               Result := Capacity_Exceeded;
               return;
            end if;
            Batch.Transactions (Transaction_Index) :=
              (Transaction_ID => Item.Transaction_ID,
               Sequence       => Expected.Highest + Sequence_Number (Transaction_Index),
               First_Mutation => Next_Mutation,
               Mutation_Count => Mutation_Count (Item));
            Transaction_Head := [others => 0];
            for Index in Identifier_Index loop
               Transaction_Head (Index - 1) := Item.Transaction_ID (Index);
            end loop;
            Put_U64
              (Transaction_Head,
               16,
               Interfaces.Unsigned_64 (Expected.Highest + Sequence_Number (Transaction_Index)));
            Put_U32 (Transaction_Head, 24, Interfaces.Unsigned_32 (Mutation_Count (Item)));
            Put_U32 (Transaction_Head, 28, Interfaces.Unsigned_32 (Body_Length));
            Append_Array (Batch.Image.Data, Transaction_Head);
            Cursor := Cursor + Transaction_Frame_Header_Length;
            for Source_Index in Positive range 1 .. Mutation_Count (Item) loop
               declare
                  Source : Owned_Mutation renames Item.Arena.Mutations (Source_Index);
                  Target : Runtime_Mutation renames Batch.Mutations (Next_Mutation);
               begin
                  Mutation_Head := [others => 0];
                  Put_U32 (Mutation_Head, 0, Interfaces.Unsigned_32 (Source.Family));
                  Mutation_Head (4) :=
                    (if Source.Operation = Put_Mutation then Put_Operation_Code else Delete_Operation_Code);
                  Put_U32 (Mutation_Head, 6, Interfaces.Unsigned_32 (Source.Key_Length));
                  Put_U32 (Mutation_Head, 10, Interfaces.Unsigned_32 (Source.Value_Length));
                  Append_Array (Batch.Image.Data, Mutation_Head);
                  Target :=
                    (Family       => Source.Family,
                     Operation    => Source.Operation,
                     Key_Offset   => Cursor + Mutation_Frame_Header_Length,
                     Key_Length   => Source.Key_Length,
                     Value_Offset => Cursor + Mutation_Frame_Header_Length + Source.Key_Length,
                     Value_Length => Source.Value_Length);
                  for Byte_Index in Positive range 1 .. Flyology.Bytes.Length (Source.Payload) loop
                     Flyology.Bytes.Append
                       (Batch.Image.Data, Flyology.Bytes.Element (Source.Payload, Byte_Index));
                  end loop;
                  Cursor := Cursor + Mutation_Frame_Header_Length + Source.Key_Length + Source.Value_Length;
                  Next_Mutation := Next_Mutation + 1;
               end;
            end loop;
         end;
      end loop;
      Append_U32 (Batch.Image.Data, CRC_32C (Batch.Image.Data, Cursor));
      if Flyology.Bytes.Length (Batch.Image.Data) /= Natural (Image_Length) then
         Release_Runtime_Batch (Batch);
         Result := Invalid_State;
      else
         Result := Success;
      end if;
   exception
      when Storage_Error =>
         Release_Runtime_Batch (Batch);
         Result := Capacity_Exceeded;
      when others =>
         Release_Runtime_Batch (Batch);
         Result := Invalid_State;
   end Build_Runtime_Batch;

   function Read_U16 (Data : Flyology.Bytes.Unbounded_Bytes; Position : Natural) return Interfaces.Unsigned_16
   is
   begin
      return
        Interfaces.Shift_Left (Interfaces.Unsigned_16 (Flyology.Bytes.Element (Data, Position + 1)), 8)
        or Interfaces.Unsigned_16 (Flyology.Bytes.Element (Data, Position + 2));
   end Read_U16;

   function Read_U32 (Data : Flyology.Bytes.Unbounded_Bytes; Position : Natural) return Interfaces.Unsigned_32
   is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      for Offset in Natural range 0 .. 3 loop
         Result :=
           Interfaces.Shift_Left (Result, 8)
           or Interfaces.Unsigned_32 (Flyology.Bytes.Element (Data, Position + Offset + 1));
      end loop;
      return Result;
   end Read_U32;

   function Read_U64 (Data : Flyology.Bytes.Unbounded_Bytes; Position : Natural) return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Offset in Natural range 0 .. 7 loop
         Result :=
           Interfaces.Shift_Left (Result, 8)
           or Interfaces.Unsigned_64 (Flyology.Bytes.Element (Data, Position + Offset + 1));
      end loop;
      return Result;
   end Read_U64;

   function Read_Identifier (Data : Flyology.Bytes.Unbounded_Bytes; Position : Natural) return Identifier is
      Result : Identifier;
   begin
      for Index in Identifier_Index loop
         Result (Index) :=
           Byte (Flyology.Bytes.Element (Data, Position + Index - Identifier_Index'First + 1));
      end loop;
      return Result;
   end Read_Identifier;

   function Same_Runtime_Key
     (Image : not null Shared_Image_Access; Left, Right : Runtime_Mutation) return Boolean is
   begin
      if Left.Family /= Right.Family or else Left.Key_Length /= Right.Key_Length then
         return False;
      end if;
      for Offset in Natural range 0 .. Left.Key_Length - 1 loop
         if Flyology.Bytes.Element (Image.Data, Left.Key_Offset + Offset + 1)
           /= Flyology.Bytes.Element (Image.Data, Right.Key_Offset + Offset + 1)
         then
            return False;
         end if;
      end loop;
      return True;
   end Same_Runtime_Key;

   procedure Decode_Runtime_Batch
     (Data              : in out Flyology.Bytes.Unbounded_Bytes;
      Expected_Database : Database_Identifier;
      Limits            : Database_Limits;
      Batch             : out Runtime_Batch;
      Result            : out Outcome_Code)
   is
      --  Exact caller image extent; all following offset arithmetic is against
      --  the frozen batch-v1 table and persisted limits, not a hidden cap.
      Length             : constant Natural := Flyology.Bytes.Length (Data);
      Header             : Formats.Byte_Array (0 .. Batch_Header_Length - 1) := [others => 0];
      Stored_Header_CRC  : Interfaces.Unsigned_32;
      Payload_Length     : Interfaces.Unsigned_64;
      Transaction_Wire   : Interfaces.Unsigned_32;
      Mutation_Wire      : Interfaces.Unsigned_32;
      Wire_Payload_Limit : Interfaces.Unsigned_64;
      Minimum_Framing    : Interfaces.Unsigned_64;
      Cursor             : Natural := Batch_Header_Length;
      Parsed_Mutations   : Natural := 0;
   begin
      Batch := (others => <>);
      --  Decode the same frozen operational batch-v1 map emitted above.
      --  Magic/version/kind/flags/database/extent and both CRCs authenticate
      --  before persisted count and byte admission.
      if Length < Batch_Header_Length + Batch_Trailer_Length then
         Result := Corrupt;
         return;
      end if;
      for Offset in Header'Range loop
         Header (Offset) := Byte (Flyology.Bytes.Element (Data, Offset + 1));
      end loop;
      Payload_Length := Read_U64 (Data, 32);
      if Payload_Length /= Interfaces.Unsigned_64 (Length - Batch_Header_Length - Batch_Trailer_Length)
        or else Header (0 .. 7)
                /= [Character'Pos ('F'),
                    Character'Pos ('L'),
                    Character'Pos ('Y'),
                    Character'Pos ('B'),
                    Character'Pos ('A'),
                    Character'Pos ('T'),
                    Character'Pos ('C'),
                    Character'Pos ('1')]
        or else Read_U16 (Data, 8) /= Batch_Format_Version_Code
        or else Header (10) /= Batch_Object_Kind_Code
        or else Header (11) /= 0
        or else Read_Identifier (Data, 12) /= Identifier (Expected_Database)
        or else Read_U32 (Data, 28) /= Batch_Header_Length
      then
         Result := Corrupt;
         return;
      end if;
      Stored_Header_CRC := Read_U32 (Data, 40);
      Header (40 .. 43) := [others => 0];
      if Stored_Header_CRC /= Formats.CRC_32C (Header)
        or else Read_U32 (Data, Length - Batch_Trailer_Length) /= CRC_32C (Data, Length - 4)
      then
         Result := Corrupt;
         return;
      end if;

      Transaction_Wire := Read_U32 (Data, 148);
      Mutation_Wire := Read_U32 (Data, 152);
      Minimum_Framing :=
        Interfaces.Unsigned_64 (Transaction_Wire)
        * Transaction_Frame_Header_Length
        + Interfaces.Unsigned_64 (Mutation_Wire) * Mutation_Frame_Header_Length;
      if Transaction_Wire > Limits.Maximum_Transactions_Per_Batch
        or else Mutation_Wire > Limits.Maximum_Mutations_Per_Batch
        or else Interfaces.Unsigned_64 (Transaction_Wire) > Interfaces.Unsigned_64 (Natural'Last)
        or else Interfaces.Unsigned_64 (Mutation_Wire) > Interfaces.Unsigned_64 (Natural'Last)
      then
         Result := Capacity_Exceeded;
         return;
      end if;
      if Transaction_Wire = 0
        or else Mutation_Wire = 0
        or else Transaction_Wire > Mutation_Wire
        or else Minimum_Framing > Payload_Length
      then
         Result := Corrupt;
         return;
      end if;
      Wire_Payload_Limit :=
        (if Limits.Maximum_Batch_Payload_Bytes > Interfaces.Unsigned_64'Last - Minimum_Framing
         then Interfaces.Unsigned_64'Last
         else Limits.Maximum_Batch_Payload_Bytes + Minimum_Framing);
      if Payload_Length > Wire_Payload_Limit then
         Result := Capacity_Exceeded;
         return;
      end if;

      Batch.Image := Allocate_Shared_Image;
      Flyology.Bytes.Move (Batch.Image.Data, Data);
      Batch.Database_ID := Expected_Database;
      Batch.Epoch := Read_U64 (Batch.Image.Data, 44);
      Batch.Batch_ID := Read_Identifier (Batch.Image.Data, 52);
      Batch.Previous_Batch_ID := Read_Identifier (Batch.Image.Data, 68);
      Batch.Expected_Transition_ID := Read_Identifier (Batch.Image.Data, 84);
      Batch.Expected_Transition_Number := Read_U64 (Batch.Image.Data, 100);
      Batch.Publication_Transition_ID := Read_Identifier (Batch.Image.Data, 108);
      Batch.Publication_Transition_Number := Read_U64 (Batch.Image.Data, 124);
      Batch.First_Sequence := Sequence_Number (Read_U64 (Batch.Image.Data, 132));
      Batch.Last_Sequence := Sequence_Number (Read_U64 (Batch.Image.Data, 140));
      Batch.Transaction_Total := Natural (Transaction_Wire);
      Batch.Mutation_Total := Natural (Mutation_Wire);
      if Batch.Epoch = 0
        or else Is_Zero (Batch.Batch_ID)
        or else (not Is_Zero (Batch.Previous_Batch_ID) and then Batch.Previous_Batch_ID = Batch.Batch_ID)
        or else Is_Zero (Batch.Expected_Transition_ID)
        or else Is_Zero (Batch.Publication_Transition_ID)
        or else Batch.Expected_Transition_ID = Batch.Publication_Transition_ID
        or else Batch.Expected_Transition_Number = 0
        or else Batch.Expected_Transition_Number = Interfaces.Unsigned_64'Last
        or else Batch.Publication_Transition_Number /= Batch.Expected_Transition_Number + 1
        or else Batch.First_Sequence = 0
        or else Batch.Last_Sequence < Batch.First_Sequence
        or else Interfaces.Unsigned_64 (Batch.Last_Sequence - Batch.First_Sequence) + 1
                /= Interfaces.Unsigned_64 (Batch.Transaction_Total)
        or else Is_Zero (Batch.Previous_Batch_ID) /= (Batch.First_Sequence = 1)
        or else Batch.Epoch > Batch.Expected_Transition_Number
        or else (if Batch.First_Sequence = 1
                 then Batch.Expected_Transition_Number /= Batch.Epoch
                 else Batch.Expected_Transition_Number <= Batch.Epoch)
      then
         Release_Runtime_Batch (Batch);
         Result := Corrupt;
         return;
      end if;
      Batch.Transactions := new Runtime_Transaction_Array (1 .. Batch.Transaction_Total);
      Batch.Mutations := new Runtime_Mutation_Array (1 .. Batch.Mutation_Total);

      for Transaction_Index in Positive range 1 .. Batch.Transaction_Total loop
         declare
            Transaction_ID : Transaction_Identifier;
            Sequence       : Sequence_Number;
            Count_Wire     : Interfaces.Unsigned_32;
            Body_Wire      : Interfaces.Unsigned_32;
            Body_End       : Natural;
            --  Derived first global mutation slot after the already-decoded
            --  prefix; it is not an additional count policy.
            First          : constant Natural := Parsed_Mutations + 1;
         begin
            if Cursor > Length - Batch_Trailer_Length - Transaction_Frame_Header_Length then
               Release_Runtime_Batch (Batch);
               Result := Corrupt;
               return;
            end if;
            Transaction_ID := Transaction_Identifier (Read_Identifier (Batch.Image.Data, Cursor));
            Sequence := Sequence_Number (Read_U64 (Batch.Image.Data, Cursor + 16));
            Count_Wire := Read_U32 (Batch.Image.Data, Cursor + 24);
            Body_Wire := Read_U32 (Batch.Image.Data, Cursor + 28);
            if Is_Zero (Transaction_ID)
              or else Sequence /= Batch.First_Sequence + Sequence_Number (Transaction_Index - 1)
              or else Count_Wire = 0
              or else Count_Wire > Limits.Maximum_Mutations_Per_Transaction
              or else Interfaces.Unsigned_64 (Count_Wire) > Interfaces.Unsigned_64 (Natural'Last)
              or else Natural (Count_Wire) > Batch.Mutation_Total - Parsed_Mutations
              or else Interfaces.Unsigned_64 (Body_Wire) > Interfaces.Unsigned_64 (Natural'Last)
              or else Natural (Body_Wire)
                      > Length - Batch_Trailer_Length - (Cursor + Transaction_Frame_Header_Length)
            then
               Release_Runtime_Batch (Batch);
               Result := Corrupt;
               return;
            end if;
            for Earlier in Positive range 1 .. Transaction_Index - 1 loop
               if Batch.Transactions (Earlier).Transaction_ID = Transaction_ID then
                  Release_Runtime_Batch (Batch);
                  Result := Corrupt;
                  return;
               end if;
            end loop;
            Cursor := Cursor + Transaction_Frame_Header_Length;
            Body_End := Cursor + Natural (Body_Wire);
            Batch.Transactions (Transaction_Index) :=
              (Transaction_ID => Transaction_ID,
               Sequence       => Sequence,
               First_Mutation => First,
               Mutation_Count => Natural (Count_Wire));
            for Local_Index in Positive range 1 .. Natural (Count_Wire) loop
               declare
                  --  Derived next global mutation slot for this transaction;
                  --  bounds come from validated persisted counts.
                  Index        : constant Positive := Parsed_Mutations + 1;
                  Family_Wire  : Interfaces.Unsigned_32;
                  Operation    : Byte;
                  Key_Wire     : Interfaces.Unsigned_32;
                  Value_Wire   : Interfaces.Unsigned_32;
                  Key_Length   : Natural;
                  Value_Length : Natural;
               begin
                  if Cursor > Body_End - Mutation_Frame_Header_Length then
                     Release_Runtime_Batch (Batch);
                     Result := Corrupt;
                     return;
                  end if;
                  Family_Wire := Read_U32 (Batch.Image.Data, Cursor);
                  Operation := Byte (Flyology.Bytes.Element (Batch.Image.Data, Cursor + 5));
                  Key_Wire := Read_U32 (Batch.Image.Data, Cursor + 6);
                  Value_Wire := Read_U32 (Batch.Image.Data, Cursor + 10);
                  if Family_Wire = 0
                    or else Operation not in Put_Operation_Code | Delete_Operation_Code
                    or else Flyology.Bytes.Element (Batch.Image.Data, Cursor + 6) /= 0
                    or else Interfaces.Unsigned_64 (Key_Wire) > Interfaces.Unsigned_64 (Natural'Last)
                    or else Interfaces.Unsigned_64 (Value_Wire) > Interfaces.Unsigned_64 (Natural'Last)
                    or else (Operation = Delete_Operation_Code and then Value_Wire /= 0)
                  then
                     Release_Runtime_Batch (Batch);
                     Result := Corrupt;
                     return;
                  end if;
                  Key_Length := Natural (Key_Wire);
                  Value_Length := Natural (Value_Wire);
                  if Key_Length > Body_End - (Cursor + Mutation_Frame_Header_Length)
                    or else Value_Length > Body_End - (Cursor + Mutation_Frame_Header_Length + Key_Length)
                  then
                     Release_Runtime_Batch (Batch);
                     Result := Corrupt;
                     return;
                  end if;
                  Batch.Mutations (Index) :=
                    (Family       => Column_Family_ID (Family_Wire),
                     Operation    =>
                       (if Operation = Put_Operation_Code then Put_Mutation else Delete_Mutation),
                     Key_Offset   => Cursor + Mutation_Frame_Header_Length,
                     Key_Length   => Key_Length,
                     Value_Offset => Cursor + Mutation_Frame_Header_Length + Key_Length,
                     Value_Length => Value_Length);
                  for Earlier in Positive range First .. Index - 1 loop
                     if Same_Runtime_Key (Batch.Image, Batch.Mutations (Earlier), Batch.Mutations (Index))
                     then
                        Release_Runtime_Batch (Batch);
                        Result := Corrupt;
                        return;
                     end if;
                  end loop;
                  Cursor := Cursor + Mutation_Frame_Header_Length + Key_Length + Value_Length;
                  Parsed_Mutations := Parsed_Mutations + 1;
               end;
            end loop;
            if Cursor /= Body_End then
               Release_Runtime_Batch (Batch);
               Result := Corrupt;
               return;
            end if;
         end;
      end loop;
      if Parsed_Mutations /= Batch.Mutation_Total or else Cursor /= Length - Batch_Trailer_Length then
         Release_Runtime_Batch (Batch);
         Result := Corrupt;
      else
         Result := Success;
      end if;
   exception
      when Storage_Error =>
         Release_Runtime_Batch (Batch);
         Result := Capacity_Exceeded;
      when others =>
         Release_Runtime_Batch (Batch);
         Result := Corrupt;
   end Decode_Runtime_Batch;

   function Runtime_Published_By (Batch : Runtime_Batch; Head : Head_Snapshot) return Boolean
   is (Batch.Image /= null
       and then Head.Database_ID = Batch.Database_ID
       and then Head.Epoch = Batch.Epoch
       and then Head.Latest_Batch = Batch.Batch_ID
       and then Head.Transition_ID = Batch.Publication_Transition_ID
       and then Head.Predecessor_Transition = Batch.Expected_Transition_ID
       and then Head.Transition_Number = Batch.Publication_Transition_Number
       and then Head.Highest = Batch.Last_Sequence);

   function Runtime_Anchored_By_Manifest_Chain
     (Batch          : Runtime_Batch;
      Head           : Head_Snapshot;
      Manifests_Seen : Manifest_History;
      Manifest_Count : Natural) return Boolean
   is
   begin
      if Batch.Image = null
        or else Manifest_Count = 0
        or else Manifest_Count > Manifests_Seen'Length
        or else Head.Database_ID /= Batch.Database_ID
        or else Head.Epoch /= Batch.Epoch
        or else Head.Latest_Batch /= Batch.Batch_ID
        or else Head.Highest /= Batch.Last_Sequence
      then
         return False;
      end if;
      for Index in Positive range 1 .. Manifest_Count loop
         if To_Database_ID (Manifests_Seen (Index).Database_ID) = Batch.Database_ID
           and then Manifests_Seen (Index).Writer_Epoch = Batch.Epoch
           and then To_Identifier (Manifests_Seen (Index).Expected_Transition_ID)
              = Batch.Publication_Transition_ID
           and then Manifests_Seen (Index).Expected_Transition_Number
                      = Batch.Publication_Transition_Number
         then
            return True;
         end if;
      end loop;
      return False;
   end Runtime_Anchored_By_Manifest_Chain;

   function Runtime_Valid_Predecessor (Current, Previous : Runtime_Batch) return Boolean is
      Gap       : Interfaces.Unsigned_64;
      Epoch_Gap : Interfaces.Unsigned_64;
   begin
      if Current.Image = null
        or else Previous.Image = null
        or else Current.First_Sequence = 1
        or else Current.Database_ID /= Previous.Database_ID
        or else Current.Previous_Batch_ID /= Previous.Batch_ID
        or else Previous.Last_Sequence = Sequence_Number'Last
        or else Current.First_Sequence /= Previous.Last_Sequence + 1
        or else Current.Epoch < Previous.Epoch
        or else Current.Expected_Transition_Number < Previous.Publication_Transition_Number
      then
         return False;
      end if;
      Gap := Current.Expected_Transition_Number - Previous.Publication_Transition_Number;
      Epoch_Gap := Current.Epoch - Previous.Epoch;
      return
        Epoch_Gap <= Gap
        and then (if Gap = 0
                  then Current.Expected_Transition_ID = Previous.Publication_Transition_ID
                  elsif Gap = 1
                  then Current.Expected_Transition_ID /= Previous.Publication_Transition_ID);
   end Runtime_Valid_Predecessor;

   procedure Copy_Head_Image (Image : Formats.Head_Image; Target : out Small_Metadata_Buffer) is
   begin
      Target := [others => 0];
      for Index in Formats.Head_Image_Index loop
         Target (Index) := Image (Index);
      end loop;
   end Copy_Head_Image;

   procedure Copy_Manifest_Image
     (Image : Formats.Byte_Array; Length : Natural; Target : out Small_Metadata_Buffer) is
   begin
      Target := [others => 0];
      if Length > 0 then
         for Index in Natural range 0 .. Length - 1 loop
            Target (Index) := Image (Index);
         end loop;
      end if;
   end Copy_Manifest_Image;

   function Exact_Bytes
     (Left         : Small_Metadata_Buffer;
      Left_Length  : Natural;
      Right        : Small_Metadata_Buffer;
      Right_Length : Natural) return Boolean is
   begin
      return
        Left_Length = Right_Length
        and then (Left_Length = 0 or else Left (0 .. Left_Length - 1) = Right (0 .. Right_Length - 1));
   end Exact_Bytes;

   function Exact_Bytes
     (Left : not null Shared_Image_Access; Right : Flyology.Bytes.Unbounded_Bytes) return Boolean
   is
      --  Comparison spans the owned image's exact runtime length; no persisted
      --  maximum or truncation policy is introduced by this derived bound.
      Length : constant Natural := Flyology.Bytes.Length (Left.Data);
   begin
      if Length /= Flyology.Bytes.Length (Right) then
         return False;
      end if;
      for Index in Positive range 1 .. Length loop
         if Flyology.Bytes.Element (Left.Data, Index) /= Flyology.Bytes.Element (Right, Index) then
            return False;
         end if;
      end loop;
      return True;
   end Exact_Bytes;

   function Head_Database_ID (Data : Small_Metadata_Buffer) return Database_Identifier is
      Result : Database_Identifier := Zero_Database_ID;
   begin
      for Index in Identifier_Index loop
         Result (Index) := Data (11 + Index);
      end loop;
      return Result;
   end Head_Database_ID;

   procedure Finish_Work
     (State          : not null Engine_State_Access;
      Tokens         : Token_Group;
      Receipts       : in out Receipt_Group;
      Count          : Group_Count;
      Result         : Outcome_Code;
      Mark_Uncertain : Boolean := False;
      Mark_Fenced    : Boolean := False) is
   begin
      for Index in Commit_Slot range 1 .. Count loop
         Receipts (Index).Current_Outcome := Result;
         if Result = Success then
            Receipts (Index).Phase := Resolved;
         elsif Mark_Uncertain then
            Receipts (Index).Phase := Head_Publication_Unknown;
         end if;
      end loop;
      State.Gate.Complete_Group (Tokens, Receipts, Count, Result, Mark_Uncertain, Mark_Fenced);
   end Finish_Work;

   procedure Process_Group
     (State           : not null Engine_State_Access;
      Items           : in out Work_Group;
      Tokens          : Token_Group;
      Count           : Group_Count;
      Head            : Head_Snapshot;
      Head_Generation : Generation_Value)
   is
      Batch                : Runtime_Batch;
      Receipts             : Receipt_Group;
      Result               : Outcome_Code;
      Put_Result           : Put_Outcome;
      Read_Result          : Read_Outcome;
      Ignored_Generation   : Generation_Value;
      Published_Generation : Generation_Value;
      Read_Data            : Flyology.Bytes.Unbounded_Bytes;
      Head_Image           : Formats.Head_Image;
      Head_Owner           : Shared_Image_Access := null;
      Deadline             : Ada.Real_Time.Time := Items (1).Deadline;
      --  The coordinator already owns cancellation classification for every
      --  admitted item, so its shared publication phase deliberately has no
      --  independent cancellation authority. Changing this would split the
      --  group's single terminal-outcome decision.
      Token                : constant access Flyology.Cancellation.Token := null;
      Attempted_Head       : Head_Snapshot;
      Head_Confirmed       : Boolean := False;

      procedure Release_Work_Arenas is
      begin
         for Index in Commit_Slot range 1 .. Count loop
            Release_Arena (Items (Index).Arena);
         end loop;
      end Release_Work_Arenas;
   begin
      Receipts := [others => <>];
      for Index in Commit_Slot range 1 .. Count loop
         Receipts (Index).Transaction_ID := Items (Index).Transaction_ID;
         Receipts (Index).Batch_ID := Items (Index).Batch_ID;
         Receipts (Index).Expected_Head := Head;
      end loop;
      for Index in Commit_Slot range 2 .. Count loop
         if Items (Index).Deadline < Deadline then
            Deadline := Items (Index).Deadline;
         end if;
      end loop;
      State.Gate.Prepublication_Check (Items, Count, Result);
      if Result /= Success then
         Release_Work_Arenas;
         Finish_Work (State, Tokens, Receipts, Count, Result);
         return;
      elsif Deadline <= Ada.Real_Time.Clock then
         Release_Work_Arenas;
         Finish_Work (State, Tokens, Receipts, Count, Timed_Out);
         return;
      end if;

      Build_Runtime_Batch (Items, Count, Head, Batch, Result);
      Release_Work_Arenas;
      if Result /= Success then
         Finish_Work (State, Tokens, Receipts, Count, Result);
         return;
      end if;
      for Index in Commit_Slot range 1 .. Count loop
         Receipts (Index).Transaction_ID := Items (Index).Transaction_ID;
         Receipts (Index).Assigned_Sequence := Head.Highest + Sequence_Number (Index);
         Receipts (Index).Batch_ID := Batch.Batch_ID;
         Receipts (Index).Expected_Head := Head;
         Receipts (Index).Attempted_Head :=
           (Database_ID            => Head.Database_ID,
            Version                => Head.Version,
            Epoch                  => Head.Epoch,
            Highest                => Batch.Last_Sequence,
            Latest_Batch           => Batch.Batch_ID,
            Latest_Manifest        => Head.Latest_Manifest,
            Transition_ID          => Batch.Publication_Transition_ID,
            Predecessor_Transition => Head.Transition_ID,
            Transition_Number      => Batch.Publication_Transition_Number);
      end loop;
      State.Gate.Validate_Batch (Batch, Result);
      if Result /= Success then
         Release_Runtime_Batch (Batch);
         Finish_Work (State, Tokens, Receipts, Count, Result);
         return;
      end if;
      Storage_Port.Put_Create
        (State.Storage.all,
         Batch_Key (State.Storage.all, Receipts (1).Batch_ID),
         Batch.Image,
         Batch_Object,
         Deadline,
         Token,
         Ignored_Generation,
         Put_Result);
      if Put_Result /= Object_Published then
         if Put_Result = Put_Outcome_Unknown then
            Storage_Port.Get_Whole
              (State.Storage.all,
               Batch_Key (State.Storage.all, Receipts (1).Batch_ID),
               Batch_Object,
               Deadline,
               Token,
               Read_Data,
               Ignored_Generation,
               Read_Result,
               Flyology.Bytes.Length (Batch.Image.Data));
            if Read_Result = Object_Read and then Exact_Bytes (Batch.Image, Read_Data) then
               null;
            else
               Release_Runtime_Batch (Batch);
               Finish_Work
                 (State,
                  Tokens,
                  Receipts,
                  Count,
                  (if Read_Result = Read_Cancelled
                   then Cancelled
                   elsif Read_Result = Read_Timed_Out
                   then Timed_Out
                   elsif Read_Result = Read_Capacity_Exceeded
                   then Capacity_Exceeded
                   else Storage_Failure));
               return;
            end if;
         elsif Put_Result = Put_Precondition_Failed then
            --  A batch identity is one-shot at the public transaction boundary.
            --  Exact bytes can continue only inside the original unknown Put;
            --  a later admission must never replay the application operation.
            Release_Runtime_Batch (Batch);
            Finish_Work (State, Tokens, Receipts, Count, Conflict, Mark_Fenced => True);
            return;
         else
            Release_Runtime_Batch (Batch);
            Finish_Work
              (State,
               Tokens,
               Receipts,
               Count,
               (if Put_Result = Put_Cancelled
                then Cancelled
                elsif Put_Result = Put_Timed_Out
                then Timed_Out
                else Storage_Failure));
            return;
         end if;
      end if;

      Attempted_Head := Receipts (1).Attempted_Head;
      Head_Image := Formats.Encode_Head (To_Head (Attempted_Head));
      Head_Owner := New_Image (Head_Image);
      Storage_Port.Put_Replace
        (State.Storage.all,
         Full_Key (State.Storage.all, Head_Key_Suffix),
         Head_Owner,
         Head_Generation,
         Deadline,
         Token,
         Published_Generation,
         Put_Result);
      Release_Image (Head_Owner);
      case Put_Result is
         when Object_Published        =>
            Head_Confirmed := True;
            State.Gate.Install_Published (Batch, Attempted_Head, Published_Generation, Result);
            Release_Runtime_Batch (Batch);
            State.Life.Set_Visible (Attempted_Head.Highest);
            if Result = Success then
               Finish_Work (State, Tokens, Receipts, Count, Success);
            else
               --  Durable publication remains successful even if the local
               --  in-memory installation fails. Fence reuse until recovery.
               Finish_Work (State, Tokens, Receipts, Count, Success, Mark_Fenced => True);
            end if;

         when Put_Precondition_Failed =>
            Release_Runtime_Batch (Batch);
            Finish_Work (State, Tokens, Receipts, Count, Stale_Writer, Mark_Fenced => True);

         when Put_Outcome_Unknown     =>
            for Index in Commit_Slot range 1 .. Count loop
               if Index > 1 then
                  Batch.Image.References.Retain;
               end if;
               Receipts (Index).Image := Batch.Image;
            end loop;
            Batch.Image := null;
            Release_Runtime_Batch (Batch);
            Finish_Work (State, Tokens, Receipts, Count, Outcome_Unknown, Mark_Uncertain => True);

         when Put_Cancelled           =>
            Release_Runtime_Batch (Batch);
            Finish_Work (State, Tokens, Receipts, Count, Cancelled);

         when Put_Timed_Out           =>
            Release_Runtime_Batch (Batch);
            Finish_Work (State, Tokens, Receipts, Count, Timed_Out);

         when Put_Definite_Failure    =>
            Release_Runtime_Batch (Batch);
            Finish_Work (State, Tokens, Receipts, Count, Storage_Failure);
      end case;
   exception
      when others =>
         Release_Work_Arenas;
         Release_Image (Head_Owner);
         Release_Runtime_Batch (Batch);
         if Head_Confirmed then
            State.Life.Set_Visible (Attempted_Head.Highest);
            Finish_Work (State, Tokens, Receipts, Count, Success, Mark_Fenced => True);
         else
            Finish_Work (State, Tokens, Receipts, Count, Storage_Failure);
         end if;
   end Process_Group;

   task body Commit_Worker is
      Items      : Work_Group;
      Tokens     : Token_Group;
      Count      : Group_Count;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Stop       : Boolean;
   begin
      loop
         State.Gate.Take_Group (Items, Tokens, Count, Head, Generation, Stop);
         exit when Stop;
         Process_Group (State, Items, Tokens, Count, Head, Generation);
      end loop;
      State.Gate.Mark_Stopped;
   exception
      when others =>
         State.Gate.Mark_Stopped;
   end Commit_Worker;

   procedure Release_History (History : in out Batch_History_Access; Count : in out Natural) is
   begin
      if History /= null then
         for Index in Positive range 1 .. Count loop
            Release_Runtime_Batch (History (Index));
         end loop;
         Free_Batch_History (History);
      end if;
      Count := 0;
   end Release_History;

   procedure Snapshot_Engine_History
     (State   : not null Engine_State_Access;
      History : out Batch_History_Access;
      Count   : out Natural;
      Result  : out Outcome_Code)
   is
      Source_Count : constant Natural := State.Gate.History_Length;
   begin
      History := null;
      Count := 0;
      if Source_Count = 0 then
         Result := Success;
         return;
      elsif Source_Count > Maximum_History_Batches then
         Result := Corrupt;
         return;
      end if;

      Allocation_Faults.Check (Recovery_History_Allocation);
      History := new Batch_History'(1 .. Source_Count => (others => <>));
      Count := Source_Count;
      for Source_Index in Positive range 1 .. Source_Count loop
         declare
            --  Allocate_Engine consumes recovery history newest-first and
            --  replays it in reverse. The live coordinator retains it
            --  oldest-first, so snapshot into the recovery order explicitly.
            Target_Index      : constant Positive := Source_Count - Source_Index + 1;
            Transaction_Total : Natural;
            Mutation_Total    : Natural;
         begin
            State.Gate.History_Batch_Shape
              (Source_Index, Transaction_Total, Mutation_Total, Result);
            if Result /= Success
              or else Transaction_Total = 0
              or else Mutation_Total = 0
            then
               Release_History (History, Count);
               Result := Corrupt;
               return;
            end if;
            Allocation_Faults.Check (Recovery_History_Allocation);
            History (Target_Index).Transactions :=
              new Runtime_Transaction_Array (1 .. Transaction_Total);
            Allocation_Faults.Check (Recovery_History_Allocation);
            History (Target_Index).Mutations := new Runtime_Mutation_Array (1 .. Mutation_Total);
            State.Gate.Copy_History_Batch (Source_Index, History (Target_Index), Result);
            if Result /= Success then
               Release_History (History, Count);
               return;
            end if;
         end;
      end loop;
      Result := Success;
   exception
      when Storage_Error =>
         Release_History (History, Count);
         Result := Capacity_Exceeded;
      when others =>
         Release_History (History, Count);
         raise;
   end Snapshot_Engine_History;

   function Valid_History_Snapshot
     (History    : Batch_History_Access;
      Count      : Natural;
      Head       : Head_Snapshot;
      Checkpoint : LSM_Runtime.Checkpoint_Manifest) return Boolean
   is
   begin
      if History = null
        or else Count = 0
        or else Count > History'Length
        or else not Runtime_Published_By (History (1), Head)
      then
         return False;
      end if;
      declare
         Oldest : Runtime_Batch renames History (Count);
      begin
         if Checkpoint.Replay_Boundary = Interfaces.Unsigned_64'Last
           or else Oldest.First_Sequence /= Sequence_Number (Checkpoint.Replay_Boundary) + 1
           or else Oldest.Expected_Transition_ID
                     /= To_Identifier (Checkpoint.Base.Publication_Transition_ID)
           or else Oldest.Expected_Transition_Number /= Checkpoint.Base.Publication_Transition_Number
         then
            return False;
         end if;
      end;
      if Count > 1 then
         for Index in Positive range 1 .. Count - 1 loop
            if not Runtime_Valid_Predecessor (History (Index), History (Index + 1)) then
               return False;
            end if;
         end loop;
      end if;
      return True;
   end Valid_History_Snapshot;

   procedure Decode_Stored_Manifest_With_Authority
     (Data              : Small_Metadata_Buffer;
      Length            : Natural;
      Expected_Database : Database_Identifier;
      Value             : out Manifests.Manifest;
      LSM_Authority     : out Engine_LSM_Authority;
      Result            : out Outcome_Code)
   is
      Status     : Manifests.Decode_Status;
      LSM_Status : LSM_Runtime.Decode_Status;
      Checkpoint : LSM_Runtime.Checkpoint_Manifest_Access := null;
   begin
      Value := Manifests.Empty_Manifest;
      LSM_Authority := No_LSM_Authority;
      if Length = 0 or else Length > Small_Metadata_Buffer'Length then
         Result := Corrupt;
         return;
      end if;
      declare
         Image : Formats.Byte_Array (0 .. Length - 1);
      begin
         for Index in Image'Range loop
            Image (Index) := Data (Index);
         end loop;
         if Length > Common_Version_Low_Offset
           and then Image (Common_Version_High_Offset) = 0
           and then Image (Common_Version_Low_Offset)
                    = Byte (LSM_Runtime.LSM.Checkpoint_Manifest_Format_Version)
         then
            LSM_Runtime.Decode_Checkpoint_Manifest
              (Image, To_Head_ID (Expected_Database), Checkpoint, LSM_Status);
            if LSM_Status = LSM_Runtime.Decoded then
               --  Create receipt activation accepts only the canonical empty
               --  current root; nonempty checkpoints enter through cacheless
               --  recovery and cannot be substituted for retained root bytes.
               if Checkpoint.Replay_Boundary /= 0
                 or else Checkpoint.Run_Total /= 0
                 or else Checkpoint.Identity_Total /= 0
               then
                  Result := Unsupported_Format;
               else
                  Value := Checkpoint.Base;
                  LSM_Authority := To_Engine_LSM_Authority (Checkpoint.all);
                  Result := Success;
               end if;
            elsif LSM_Status
                  in LSM_Runtime.Limit_Exceeded
                   | LSM_Runtime.Allocation_Failed
                   | LSM_Runtime.Runtime_Incompatible
            then
               Result := Capacity_Exceeded;
            elsif LSM_Status = LSM_Runtime.Unsupported_Version then
               Result := Unsupported_Format;
            else
               Result := Corrupt;
            end if;
            LSM_Runtime.Release (Checkpoint);
            return;
         end if;
         Manifests.Decode_Manifest
           (Image, To_Head_ID (Expected_Database), Manifests.Default_Reader_Caps, Value, Status);
      end;
      Result :=
        (if Status = Manifests.Decoded
         then Success
         elsif Status = Manifests.Limit_Exceeded
         then Capacity_Exceeded
         elsif Status = Manifests.Unsupported_Version
         then Unsupported_Format
         else Corrupt);
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Checkpoint);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Checkpoint);
         raise;
   end Decode_Stored_Manifest_With_Authority;

   procedure Decode_Stored_Manifest
     (Data              : Small_Metadata_Buffer;
      Length            : Natural;
      Expected_Database : Database_Identifier;
      Value             : out Manifests.Manifest;
      Result            : out Outcome_Code)
   is
      Ignored : Engine_LSM_Authority;
   begin
      Decode_Stored_Manifest_With_Authority (Data, Length, Expected_Database, Value, Ignored, Result);
   end Decode_Stored_Manifest;

   function Read_Failure_Outcome (Value : Read_Outcome; Missing_Is_Corrupt : Boolean) return Outcome_Code is
   begin
      case Value is
         when Object_Read                             =>
            return Success;

         when Object_Missing                          =>
            return (if Missing_Is_Corrupt then Corrupt else Not_Found);

         when Read_Cancelled                          =>
            return Cancelled;

         when Read_Timed_Out                          =>
            return Timed_Out;

         when Read_Capacity_Exceeded                  =>
            return Capacity_Exceeded;

         when Read_Precondition_Failed | Read_Corrupt =>
            return Corrupt;

         when Read_Failed                             =>
            return Storage_Failure;
      end case;
   end Read_Failure_Outcome;

   type Manifest_Read_Admission is record
      Object_Length : Natural := 0;
      Generation    : Generation_Value;
      Is_Checkpoint : Boolean := False;
      Checkpoint    : LSM_Runtime.Checkpoint_Header_Admission;
   end record;

   procedure Inspect_Leading_Manifest_Header
     (Header_Data       : Flyology.Bytes.Unbounded_Bytes;
      Object_Length     : Natural;
      Header_Generation : Generation_Value;
      Expected_Database : Database_Identifier;
      Admission         : out Manifest_Read_Admission;
      Result            : out Outcome_Code)
   is
      --  The frozen checkpoint-manifest header width is the exact first read.
      --  A v2 header is its prefix-compatible predecessor; changing this
      --  range changes the persisted-format admission boundary.
      Header_Length : constant Natural := LSM_Runtime.LSM.Checkpoint_Manifest_Header_Length;
      Decode_Status : LSM_Runtime.Decode_Status;
      Image         : LSM_Runtime.Image_Access := null;
   begin
      Admission := (others => <>);
      if Flyology.Bytes.Length (Header_Data) /= Header_Length
        or else Object_Length < Header_Length + LSM_Runtime.LSM.Object_Trailer_Length
      then
         Result := Corrupt;
         return;
      end if;

      Allocation_Faults.Check (Recovery_Manifest_Header_Allocation);
      Image := new Formats.Byte_Array'(0 .. Header_Length - 1 => 0);
      for Index in Natural range 0 .. Header_Length - 1 loop
         Image (Index) := Byte (Flyology.Bytes.Element (Header_Data, Index + 1));
      end loop;
      Admission.Object_Length := Object_Length;
      Admission.Generation := Header_Generation;
      Admission.Is_Checkpoint :=
        Image (Common_Version_High_Offset) = 0
        and then Image (Common_Version_Low_Offset)
                   in Byte (LSM_Runtime.LSM.Previous_Checkpoint_Manifest_Format_Version)
                      | Byte (LSM_Runtime.LSM.Checkpoint_Manifest_Format_Version);
      if Admission.Is_Checkpoint then
         LSM_Runtime.Inspect_Checkpoint_Manifest_Header
           (Image.all,
            To_Head_ID (Expected_Database),
            Interfaces.Unsigned_64 (Object_Length),
            Admission.Checkpoint,
            Decode_Status);
         LSM_Runtime.Release (Image);
         if Decode_Status = LSM_Runtime.Decoded then
            Admission.Object_Length := Admission.Checkpoint.Object_Length;
         end if;
         Result :=
           (if Decode_Status = LSM_Runtime.Decoded
            then Success
            elsif Decode_Status
                  in LSM_Runtime.Limit_Exceeded
                   | LSM_Runtime.Allocation_Failed
                   | LSM_Runtime.Runtime_Incompatible
            then Capacity_Exceeded
            elsif Decode_Status = LSM_Runtime.Unsupported_Version
            then Unsupported_Format
            else Corrupt);
      else
         LSM_Runtime.Release (Image);
         Result :=
           (if Object_Length <= Small_Metadata_Buffer'Length then Success else Capacity_Exceeded);
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Image);
         raise;
   end Inspect_Leading_Manifest_Header;

   procedure Decode_Leading_Manifest_Body
     (Whole_Data        : Flyology.Bytes.Unbounded_Bytes;
      Whole_Length      : Natural;
      Whole_Generation  : Generation_Value;
      Expected_Database : Database_Identifier;
      Admission         : Manifest_Read_Admission;
      Value             : out Manifests.Manifest;
      LSM_Authority     : out Engine_LSM_Authority;
      Checkpoint        : out LSM_Runtime.Checkpoint_Manifest_Access;
      Result            : out Outcome_Code)
   is
      Decode_Status   : LSM_Runtime.Decode_Status;
      Manifest_Status : Manifests.Decode_Status;
      Image           : LSM_Runtime.Image_Access := null;
   begin
      Value := Manifests.Empty_Manifest;
      LSM_Authority := No_LSM_Authority;
      Checkpoint := null;
      if Whole_Length /= Admission.Object_Length
        or else Flyology.Bytes.Length (Whole_Data) /= Admission.Object_Length
        or else Whole_Generation /= Admission.Generation
      then
         Result := Corrupt;
         return;
      end if;

      Allocation_Faults.Check (Recovery_Manifest_Image_Allocation);
      Image := new Formats.Byte_Array'(0 .. Admission.Object_Length - 1 => 0);
      for Index in Natural range 0 .. Admission.Object_Length - 1 loop
         Image (Index) := Byte (Flyology.Bytes.Element (Whole_Data, Index + 1));
      end loop;
      if Admission.Is_Checkpoint then
         LSM_Runtime.Decode_Checkpoint_Manifest
           (Image.all, To_Head_ID (Expected_Database), Checkpoint, Decode_Status);
         LSM_Runtime.Release (Image);
         if Decode_Status = LSM_Runtime.Decoded then
            Value := Checkpoint.Base;
            LSM_Authority := To_Engine_LSM_Authority (Checkpoint.all);
            Result := Success;
         elsif Decode_Status
               in LSM_Runtime.Limit_Exceeded
                | LSM_Runtime.Allocation_Failed
                | LSM_Runtime.Runtime_Incompatible
         then
            LSM_Runtime.Release (Checkpoint);
            Result := Capacity_Exceeded;
         elsif Decode_Status = LSM_Runtime.Unsupported_Version then
            LSM_Runtime.Release (Checkpoint);
            Result := Unsupported_Format;
         else
            LSM_Runtime.Release (Checkpoint);
            Result := Corrupt;
         end if;
      else
         Manifests.Decode_Manifest
           (Image.all, To_Head_ID (Expected_Database), Manifests.Default_Reader_Caps, Value, Manifest_Status);
         LSM_Runtime.Release (Image);
         Result :=
           (if Manifest_Status = Manifests.Decoded
            then Success
            elsif Manifest_Status = Manifests.Limit_Exceeded
            then Capacity_Exceeded
            elsif Manifest_Status = Manifests.Unsupported_Version
            then Unsupported_Format
            else Corrupt);
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         LSM_Runtime.Release (Checkpoint);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Image);
         LSM_Runtime.Release (Checkpoint);
         raise;
   end Decode_Leading_Manifest_Body;

   type SST_Read_Admission is record
      Object_Length : Natural := 0;
      Generation    : Generation_Value;
      Header        : LSM_Runtime.SST_Header_Admission;
   end record;

   --  The longest frozen compatible header is SST-v2's 128-byte prefix. A
   --  single bounded range discriminates v1/v2 before allocation. A short v1
   --  object may end after its 96-byte header, one 20-byte entry header, and
   --  4-byte object trailer, so the observed prefix may be shorter than v2.
   Compatible_SST_Header_Length : constant Positive := LSM_Runtime.SST_V2_Header_Length;
   Minimum_Compatible_SST_Length : constant Positive :=
     LSM_Runtime.LSM.SST_Header_Length
     + LSM_Runtime.LSM.SST_Entry_Header_Length
     + LSM_Runtime.LSM.Object_Trailer_Length;

   procedure Inspect_Compatible_SST_Header
     (Header              : Formats.Byte_Array;
      Expected_Database   : Heads.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : LSM_Runtime.Run_Descriptor;
      Object_Length       : Interfaces.Unsigned_64;
      Admission           : out LSM_Runtime.SST_Header_Admission;
      Status              : out LSM_Runtime.Decode_Status)
   is
   begin
      Admission := LSM_Runtime.Empty_SST_Header_Admission;
      if Header'Length < LSM_Runtime.LSM.SST_Header_Length
        or else Header'Length > Compatible_SST_Header_Length
      then
         Status := LSM_Runtime.Invalid_Length;
      elsif Header (Header'First + Common_Version_High_Offset) /= 0 then
         Status := LSM_Runtime.Unsupported_Version;
      elsif Header (Header'First + Common_Version_Low_Offset)
        = Byte (LSM_Runtime.LSM.SST_Format_Version)
      then
         LSM_Runtime.Inspect_SST_Header
           (Header
              (Header'First
               .. Header'First + LSM_Runtime.LSM.SST_Header_Length - 1),
            Expected_Database,
            Expected_Family,
            Expected_Descriptor,
            Object_Length,
            Admission,
            Status);
      elsif Header (Header'First + Common_Version_Low_Offset)
        = Byte (LSM_Runtime.SST_V2_Format_Version)
      then
         if Header'Length /= Compatible_SST_Header_Length then
            Status := LSM_Runtime.Invalid_Length;
         else
            LSM_Runtime.Inspect_SST_V2_Header
              (Header,
               Expected_Database,
               Expected_Family,
               Expected_Descriptor,
               Object_Length,
               Admission,
               Status);
         end if;
      else
         Status := LSM_Runtime.Unsupported_Version;
      end if;
   end Inspect_Compatible_SST_Header;

   procedure Inspect_Recovery_SST_Header
     (Header_Data       : Flyology.Bytes.Unbounded_Bytes;
      Object_Length     : Natural;
      Header_Generation : Generation_Value;
      Manifest          : not null LSM_Runtime.Checkpoint_Manifest_Access;
      Family_Index      : Positive;
      Descriptor        : LSM_Runtime.Run_Descriptor;
      Admission         : out SST_Read_Admission;
      Result            : out Outcome_Code)
   is
      Decode_Status : LSM_Runtime.Decode_Status;
      Image         : LSM_Runtime.Image_Access := null;
      Header_Length : constant Natural := Flyology.Bytes.Length (Header_Data);
   begin
      Admission := (others => <>);
      if Family_Index not in Manifest.Families'Range
        or else Header_Length < LSM_Runtime.LSM.SST_Header_Length
        or else Header_Length > Compatible_SST_Header_Length
        or else Object_Length < Minimum_Compatible_SST_Length
      then
         Result := Corrupt;
         return;
      end if;

      Allocation_Faults.Check (Recovery_SST_Header_Allocation);
      Image := new Formats.Byte_Array'(0 .. Header_Length - 1 => 0);
      for Index in Natural range 0 .. Header_Length - 1 loop
         Image (Index) := Byte (Flyology.Bytes.Element (Header_Data, Index + 1));
      end loop;
      Admission.Object_Length := Object_Length;
      Admission.Generation := Header_Generation;
      Inspect_Compatible_SST_Header
        (Image.all,
         Manifest.Base.Database_ID,
         Manifest.Base.Families (Family_Index).ID,
         Descriptor,
         Interfaces.Unsigned_64 (Object_Length),
         Admission.Header,
         Decode_Status);
      LSM_Runtime.Release (Image);
      if Decode_Status = LSM_Runtime.Decoded then
         Admission.Object_Length := Admission.Header.Object_Length;
      end if;
      Result :=
        (if Decode_Status = LSM_Runtime.Decoded
         then Success
         elsif Decode_Status
               in LSM_Runtime.Limit_Exceeded
                | LSM_Runtime.Allocation_Failed
                | LSM_Runtime.Runtime_Incompatible
         then Capacity_Exceeded
         elsif Decode_Status = LSM_Runtime.Unsupported_Version
         then Unsupported_Format
         else Corrupt);
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Image);
         raise;
   end Inspect_Recovery_SST_Header;

   procedure Decode_Compatible_SST
     (Image               : Formats.Byte_Array;
      Expected_Database   : Heads.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : LSM_Runtime.Run_Descriptor;
      Maximum_Key_Bytes   : Interfaces.Unsigned_64;
      Maximum_Value_Bytes : Interfaces.Unsigned_64;
      Admission           : LSM_Runtime.SST_Header_Admission;
      Value               : out LSM_Runtime.SST_Access;
      Status              : out LSM_Runtime.Decode_Status)
   is
   begin
      if Admission.Format_Version = LSM_Runtime.LSM.SST_Format_Version then
         LSM_Runtime.Decode_SST
           (Image,
            Expected_Database,
            Expected_Family,
            Expected_Descriptor,
            Maximum_Key_Bytes,
            Maximum_Value_Bytes,
            Value,
            Status);
      elsif Admission.Format_Version = LSM_Runtime.SST_V2_Format_Version then
         LSM_Runtime.Decode_SST_V2
           (Image,
            Expected_Database,
            Expected_Family,
            Expected_Descriptor,
            Maximum_Key_Bytes,
            Maximum_Value_Bytes,
            Value,
            Status);
      else
         Value := null;
         Status := LSM_Runtime.Unsupported_Version;
      end if;
   end Decode_Compatible_SST;

   procedure Decode_Recovery_SST_Body
     (Whole_Data       : Flyology.Bytes.Unbounded_Bytes;
      Whole_Length     : Natural;
      Whole_Generation : Generation_Value;
      Manifest         : not null LSM_Runtime.Checkpoint_Manifest_Access;
      Family_Index     : Positive;
      Descriptor       : LSM_Runtime.Run_Descriptor;
      Admission        : SST_Read_Admission;
      Value            : out LSM_Runtime.SST_Access;
      Result           : out Outcome_Code)
   is
      Decode_Status : LSM_Runtime.Decode_Status;
      Image         : LSM_Runtime.Image_Access := null;
   begin
      Value := null;
      if Family_Index not in Manifest.Families'Range
        or else Whole_Length /= Admission.Object_Length
        or else Flyology.Bytes.Length (Whole_Data) /= Admission.Object_Length
        or else Whole_Generation /= Admission.Generation
      then
         Result := Corrupt;
         return;
      end if;

      Allocation_Faults.Check (Recovery_SST_Image_Allocation);
      Image := new Formats.Byte_Array'(0 .. Admission.Object_Length - 1 => 0);
      for Index in Natural range 0 .. Admission.Object_Length - 1 loop
         Image (Index) := Byte (Flyology.Bytes.Element (Whole_Data, Index + 1));
      end loop;
      Decode_Compatible_SST
        (Image.all,
         Manifest.Base.Database_ID,
         Manifest.Base.Families (Family_Index).ID,
         Descriptor,
         Manifest.Base.Families (Family_Index).Max_Key_Bytes,
         Manifest.Base.Families (Family_Index).Max_Value_Bytes,
         Admission.Header,
         Value,
         Decode_Status);
      LSM_Runtime.Release (Image);
      Result :=
        (if Decode_Status = LSM_Runtime.Decoded
         then Success
         elsif Decode_Status
               in LSM_Runtime.Limit_Exceeded
                | LSM_Runtime.Allocation_Failed
                | LSM_Runtime.Runtime_Incompatible
         then Capacity_Exceeded
         elsif Decode_Status = LSM_Runtime.Unsupported_Version
         then Unsupported_Format
         else Corrupt);
      if Result /= Success then
         LSM_Runtime.Release (Value);
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         LSM_Runtime.Release (Value);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Image);
         LSM_Runtime.Release (Value);
         raise;
   end Decode_Recovery_SST_Body;

   procedure Read_Checkpoint_SSTs
     (Storage  : in out Storage_Context;
      Deadline : Ada.Real_Time.Time;
      Token    : access Flyology.Cancellation.Token;
      Plan     : in out Checkpoint_Plan;
      Result   : out Outcome_Code)
   is
      --  One longest-compatible prefix discriminates SST-v1/v2 and binds
      --  exact descriptor/allocation authority before whole-object retention.
      Header_Length : constant Natural := Compatible_SST_Header_Length;
   begin
      if Plan.Manifest = null then
         Result := Invalid_State;
         return;
      elsif Plan.Manifest.Run_Total > 0 then
         Allocation_Faults.Check (Recovery_SST_Image_Allocation);
         Plan.Recovered_SSTs := new Recovered_SST_Array'(1 .. Plan.Manifest.Run_Total => null);
      end if;
      for Family_Index in Plan.Manifest.Families'Range loop
         declare
            Family : LSM_Runtime.Family_LSM_State renames Plan.Manifest.Families (Family_Index);
         begin
            if Family.Run_Total > 0 then
               for Run_Index in Family.First_Run .. Family.First_Run + Family.Run_Total - 1 loop
                  declare
                     Descriptor        : LSM_Runtime.Run_Descriptor renames
                       Plan.Manifest.Runs (Run_Index);
                     Header_Data       : Flyology.Bytes.Unbounded_Bytes;
                     Whole_Data        : Flyology.Bytes.Unbounded_Bytes;
                     Object_Length     : Natural;
                     Whole_Length      : Natural;
                     Header_Generation : Generation_Value;
                     Whole_Generation  : Generation_Value;
                     Read_Result       : Read_Outcome;
                     Admission         : SST_Read_Admission;
                  begin
                     Storage_Port.Get_Selected
                       (Storage,
                        Run_Key (Storage, To_Identifier (Descriptor.Run_ID)),
                        Run_Object,
                        (Kind  => OS.Bounded_Range,
                         First => 0,
                         Last  => OS.Byte_Count (Header_Length - 1),
                         Count => 0),
                        (others => <>),
                        Deadline,
                        Token,
                        Header_Data,
                        Object_Length,
                        Header_Generation,
                        Read_Result,
                        Header_Length);
                     if Read_Result /= Object_Read then
                        Result := Read_Failure_Outcome (Read_Result, Missing_Is_Corrupt => True);
                        return;
                     end if;
                     Inspect_Recovery_SST_Header
                       (Header_Data,
                        Object_Length,
                        Header_Generation,
                        Plan.Manifest,
                        Family_Index,
                        Descriptor,
                        Admission,
                        Result);
                     if Result /= Success then
                        return;
                     end if;
                     Storage_Port.Get_Selected
                       (Storage,
                        Run_Key (Storage, To_Identifier (Descriptor.Run_ID)),
                        Run_Object,
                        OS.Whole_Object,
                        Admission.Generation,
                        Deadline,
                        Token,
                        Whole_Data,
                        Whole_Length,
                        Whole_Generation,
                        Read_Result,
                        Admission.Object_Length);
                     if Read_Result /= Object_Read then
                        Result := Read_Failure_Outcome (Read_Result, Missing_Is_Corrupt => True);
                        return;
                     end if;
                     Decode_Recovery_SST_Body
                       (Whole_Data,
                        Whole_Length,
                        Whole_Generation,
                        Plan.Manifest,
                        Family_Index,
                        Descriptor,
                        Admission,
                        Plan.Recovered_SSTs (Run_Index),
                        Result);
                     if Result /= Success then
                        return;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
      Result := Success;
   exception
      when Storage_Error =>
         Result := Capacity_Exceeded;
   end Read_Checkpoint_SSTs;

   procedure Prepare_Selected_Merge_Source
     (State          : not null Engine_State_Access;
      Older_Run_ID   : Identifier;
      Middle_Run_ID  : Identifier;
      Newer_Run_ID   : Identifier;
      Output_Run_ID  : Identifier;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Base           : out Manifests.Manifest;
      Head           : out Head_Snapshot;
      Current        : out Checkpoint_Plan;
      Result         : out Outcome_Code;
      Allow_Fenced   : Boolean := False)
   is
      Generation     : Generation_Value;
      Uncertain      : Boolean;
      Fenced         : Boolean;
      Identity_Total : Natural;
      Prior          : constant LSM_Runtime.Checkpoint_Manifest_Access := State.Checkpoint_Manifest;
      Allocation     : LSM_Runtime.Allocation_Status;
   begin
      --  This phase is effect-free. It freezes the exact current manifest,
      --  HEAD, and generation before any selected-run I/O so a blocking or
      --  owner-driven loader can populate the same plan without duplicating
      --  admission or successor policy.
      Current := (others => <>);
      if Is_Zero (Older_Run_ID)
        or else Is_Zero (Newer_Run_ID)
        or else Is_Zero (Output_Run_ID)
        or else Is_Zero (Manifest_ID)
        or else Is_Zero (Transition_ID)
        or else Older_Run_ID = Newer_Run_ID
        or else
          (not Is_Zero (Middle_Run_ID)
           and then
             (Middle_Run_ID = Older_Run_ID
              or else Middle_Run_ID = Newer_Run_ID
              or else Output_Run_ID = Middle_Run_ID))
        or else Output_Run_ID = Older_Run_ID
        or else Output_Run_ID = Newer_Run_ID
        or else Output_Run_ID = Manifest_ID
        or else Output_Run_ID = Transition_ID
        or else Manifest_ID = Transition_ID
        or else not State.LSM_Authority.Enabled
      then
         Result := Invalid_State;
         return;
      elsif State.LSM_Authority.Maximum_Point_Reads_Per_Transaction = 0
        or else State.LSM_Authority.Maximum_Scan_Ranges_Per_Transaction = 0
      then
         Result := Unsupported_Format;
         return;
      end if;

      State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced and then not Allow_Fenced then
         Result := Stale_Writer;
         return;
      elsif Head.Highest = 0
        or else Head.Transition_Number = Interfaces.Unsigned_64'Last
        or else Head.Latest_Manifest = Zero_Identifier
        or else Manifest_ID = Head.Latest_Manifest
        or else Transition_ID = Head.Transition_ID
      then
         Result := Invalid_State;
         return;
      end if;

      State.Gate.Checkpoint_Metadata (Base, Identity_Total, Result);
      if Result /= Success then
         return;
      elsif Base.Registry_Revision = Interfaces.Unsigned_64'Last
        or else Base.Registry_Revision
          >= Interfaces.Unsigned_64 (Base.Limits.Maximum_Manifest_History)
        or else Interfaces.Unsigned_64 (Identity_Total)
          > Interfaces.Unsigned_64 (State.LSM_Authority.Maximum_Checkpoint_Identities)
      then
         Result := Capacity_Exceeded;
         return;
      elsif Prior = null
        or else Prior.Run_Total < (if Is_Zero (Middle_Run_ID) then 2 else 3)
      then
         Result := Invalid_State;
         return;
      elsif not LSM_Runtime.Structurally_Valid (Prior.all)
        or else Prior.Replay_Boundary /= State.LSM_Authority.Replay_Boundary
        or else Prior.Base.Manifest_ID /= To_Head_ID (Head.Latest_Manifest)
        or else Prior.Family_Total /= Natural (Base.Family_Total)
      then
         Result := Corrupt;
         return;
      end if;

      Base.Manifest_ID := To_Head_ID (Manifest_ID);
      Base.Previous_Manifest_ID := To_Head_ID (Head.Latest_Manifest);
      Base.Expected_Transition_ID := To_Head_ID (Head.Transition_ID);
      Base.Expected_Transition_Number := Head.Transition_Number;
      Base.Publication_Transition_ID := To_Head_ID (Transition_ID);
      Base.Publication_Transition_Number := Head.Transition_Number + 1;
      Base.Writer_Epoch := Head.Epoch;
      --  Exact one-step manifest predecessor policy requires every partial
      --  merge to advance the persisted registry revision by one. Changing
      --  this formula breaks cacheless chain validation.
      Base.Registry_Revision := Base.Registry_Revision + 1;
      if not Manifests.Valid_Checkpoint_Predecessor (Base, Prior.Base) then
         Result := Corrupt;
         return;
      end if;

      --  The current authenticated manifest is copied at its exact persisted
      --  extents solely to own the SSTs read below. No library-selected run,
      --  identity, key, value, or byte ceiling participates in this plan.
      Allocation_Faults.Check (Checkpoint_Manifest_Allocation);
      LSM_Runtime.Create_Checkpoint_Manifest
        (Prior.Family_Total,
         Prior.Run_Total,
         Prior.Identity_Total,
         Current.Manifest,
         Allocation);
      if Allocation /= LSM_Runtime.Allocated then
         Result := Capacity_Exceeded;
         return;
      end if;
      Current.Manifest.Base := Prior.Base;
      Current.Manifest.Replay_Boundary := Prior.Replay_Boundary;
      Current.Manifest.Maximum_Total_L0_Runs := Prior.Maximum_Total_L0_Runs;
      Current.Manifest.Maximum_Checkpoint_Identities := Prior.Maximum_Checkpoint_Identities;
      Current.Manifest.Maximum_Point_Reads_Per_Transaction :=
        Prior.Maximum_Point_Reads_Per_Transaction;
      Current.Manifest.Maximum_Scan_Ranges_Per_Transaction :=
        Prior.Maximum_Scan_Ranges_Per_Transaction;
      Current.Manifest.Families := Prior.Families;
      Current.Manifest.Runs := Prior.Runs;
      Current.Manifest.Identities := Prior.Identities;
      Current.Expected_Generation := Generation;
      Result := Success;
   exception
      when Storage_Error =>
         Release_Checkpoint_Plan (Current);
         Result := Capacity_Exceeded;
      when others =>
         Release_Checkpoint_Plan (Current);
         raise;
   end Prepare_Selected_Merge_Source;

   procedure Complete_Selected_Merge_Plan
     (State          : not null Engine_State_Access;
      Older_Run_ID   : Identifier;
      Middle_Run_ID  : Identifier;
      Newer_Run_ID   : Identifier;
      Output_Run_ID  : Identifier;
      Base           : Manifests.Manifest;
      Head           : Head_Snapshot;
      Current        : in out Checkpoint_Plan;
      Plan           : out Checkpoint_Plan;
      Result         : out Outcome_Code)
   is
      Older_Index  : Natural := 0;
      Middle_Index : Natural := 0;
      Newer_Index  : Natural := 0;
      Family_Index : Natural := 0;
      Merged       : LSM_Runtime.SST_Access := null;
      Successor    : LSM_Runtime.Checkpoint_Manifest_Access := null;
      Merge_Result : LSM_Runtime.Merge_Status;

      procedure Clone_SST
        (Source : LSM_Runtime.SST;
         Target : out LSM_Runtime.SST_Access;
         Status : out Outcome_Code)
      is
         Clone_Status : LSM_Runtime.Allocation_Status;
      begin
         Target := null;
         Allocation_Faults.Check (Recovery_SST_Image_Allocation);
         LSM_Runtime.Create_SST
           (Source.Entry_Total, Source.Payload_Byte_Total, Target, Clone_Status);
         if Clone_Status = LSM_Runtime.Allocated then
            Target.all := Source;
            Status := Success;
         else
            Status := Capacity_Exceeded;
         end if;
      end Clone_SST;
   begin
      --  Current is consumed on every return. The completion phase trusts no
      --  loader-specific state: every retained SST must still match its exact
      --  authenticated descriptor before the merge successor is constructed.
      Plan := (others => <>);
      if Current.Manifest = null
        or else Current.Recovered_SSTs = null
        or else Current.Manifest.Run_Total /= Current.Recovered_SSTs'Length
      then
         Release_Checkpoint_Plan (Current);
         Result := Invalid_State;
         return;
      end if;
      for Family_Index in Current.Manifest.Families'Range loop
         declare
            Family : LSM_Runtime.Family_LSM_State renames
              Current.Manifest.Families (Family_Index);
         begin
            if Family.Run_Total > 0 then
               for Run_Index in Family.First_Run .. Family.First_Run + Family.Run_Total - 1 loop
                  if Current.Recovered_SSTs (Run_Index) = null
                    or else
                      not LSM_Runtime.Descriptor_Matches
                        (Current.Recovered_SSTs (Run_Index).all,
                         Current.Manifest.Base.Database_ID,
                         Current.Manifest.Base.Families (Family_Index).ID,
                         Current.Manifest.Runs (Run_Index))
                  then
                     Release_Checkpoint_Plan (Current);
                     Result := Corrupt;
                     return;
                  end if;
               end loop;
            end if;
         end;
      end loop;
      for Index in Current.Manifest.Runs'Range loop
         if To_Identifier (Current.Manifest.Runs (Index).Run_ID) = Older_Run_ID then
            Older_Index := Index;
         elsif To_Identifier (Current.Manifest.Runs (Index).Run_ID) = Middle_Run_ID then
            Middle_Index := Index;
         elsif To_Identifier (Current.Manifest.Runs (Index).Run_ID) = Newer_Run_ID then
            Newer_Index := Index;
         end if;
      end loop;
      if Older_Index = 0
        or else Newer_Index = 0
        or else (not Is_Zero (Middle_Run_ID) and then Middle_Index = 0)
      then
         Release_Checkpoint_Plan (Current);
         Result := Invalid_State;
         return;
      end if;

      if Is_Zero (Middle_Run_ID) then
         LSM_Runtime.Build_Adjacent_Merge_Successor
           (Current.Manifest.all,
            Base,
            Current.Recovered_SSTs (Older_Index).all,
            Current.Recovered_SSTs (Newer_Index).all,
            To_Head_ID (Output_Run_ID),
            Merged,
            Successor,
            Merge_Result);
      else
         LSM_Runtime.Build_Three_Run_Merge_Successor
           (Current.Manifest.all,
            Base,
            Current.Recovered_SSTs (Older_Index).all,
            Current.Recovered_SSTs (Middle_Index).all,
            Current.Recovered_SSTs (Newer_Index).all,
            To_Head_ID (Output_Run_ID),
            Merged,
            Successor,
            Merge_Result);
      end if;
      if not LSM_Runtime."=" (Merge_Result, LSM_Runtime.Merge_Completed) then
         Release_Checkpoint_Plan (Current);
         Result :=
           (if LSM_Runtime."=" (Merge_Result, LSM_Runtime.Merge_Invalid_Input)
            then Invalid_State
            else Capacity_Exceeded);
         return;
      end if;

      for Index in Successor.Families'Range loop
         if Successor.Base.Families (Index).ID = Merged.Family_ID then
            Family_Index := Index;
            exit;
         end if;
      end loop;
      if Family_Index = 0 then
         LSM_Runtime.Release (Merged);
         LSM_Runtime.Release (Successor);
         Release_Checkpoint_Plan (Current);
         Result := Corrupt;
         return;
      end if;
      Plan.Manifest := Successor;
      Successor := null;
      Plan.SSTs (Manifests.Family_Slot (Family_Index)) := Merged;
      Merged := null;
      Plan.Expected_Generation := Current.Expected_Generation;

      --  Local activation must be rebuilt from exactly the successor's runs,
      --  not the live coordinator view: the latter may also include a
      --  post-checkpoint batch suffix. Retained predecessor runs move from the
      --  authenticated current plan; the one new merged run is cloned at its
      --  exact derived extent so publication and activation have independent
      --  ownership. Allocate_Engine replays the separately snapshotted suffix.
      if Plan.Manifest.Run_Total > 0 then
         Allocation_Faults.Check (Recovery_SST_Image_Allocation);
         Plan.Recovered_SSTs :=
           new Recovered_SST_Array'(1 .. Plan.Manifest.Run_Total => null);
      end if;
      for Successor_Index in Plan.Manifest.Runs'Range loop
         if To_Identifier (Plan.Manifest.Runs (Successor_Index).Run_ID) = Output_Run_ID then
            Clone_SST
              (Plan.SSTs (Manifests.Family_Slot (Family_Index)).all,
               Plan.Recovered_SSTs (Successor_Index),
               Result);
         else
            Result := Corrupt;
            for Current_Index in Current.Manifest.Runs'Range loop
               if Current.Manifest.Runs (Current_Index).Run_ID = Plan.Manifest.Runs (Successor_Index).Run_ID
               then
                  Plan.Recovered_SSTs (Successor_Index) := Current.Recovered_SSTs (Current_Index);
                  Current.Recovered_SSTs (Current_Index) := null;
                  Result := Success;
                  exit;
               end if;
            end loop;
         end if;
         if Result /= Success then
            Release_Checkpoint_Plan (Current);
            Release_Checkpoint_Plan (Plan);
            return;
         end if;
      end loop;
      Prepare_Checkpoint_Images (Plan, Result);
      if Result = Success then
         Prepare_Checkpoint_Base (Plan, Result);
      end if;
      if Result = Success
        and then Plan.Manifest.Replay_Boundary < Interfaces.Unsigned_64 (Head.Highest)
      then
         Snapshot_Engine_History (State, Plan.History, Plan.History_Count, Result);
         if Result = Success
           and then
             (Plan.History_Count = 0
              or else
                not Valid_History_Snapshot
                  (Plan.History, Plan.History_Count, Head, Current.Manifest.all))
         then
            Result := Corrupt;
         end if;
      end if;
      Release_Checkpoint_Plan (Current);
      if Result /= Success then
         Release_Checkpoint_Plan (Plan);
         return;
      end if;
      Result := Success;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Merged);
         LSM_Runtime.Release (Successor);
         Release_Checkpoint_Plan (Current);
         Release_Checkpoint_Plan (Plan);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Merged);
         LSM_Runtime.Release (Successor);
         Release_Checkpoint_Plan (Current);
         Release_Checkpoint_Plan (Plan);
         raise;
   end Complete_Selected_Merge_Plan;

   procedure Build_Selected_Merge_Plan
     (State          : not null Engine_State_Access;
      Older_Run_ID   : Identifier;
      Middle_Run_ID  : Identifier;
      Newer_Run_ID   : Identifier;
      Output_Run_ID  : Identifier;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Deadline       : Ada.Real_Time.Time;
      Token          : access Flyology.Cancellation.Token;
      Plan           : out Checkpoint_Plan;
      Result         : out Outcome_Code;
      Allow_Fenced   : Boolean := False)
   is
      Base    : Manifests.Manifest;
      Head    : Head_Snapshot;
      Current : Checkpoint_Plan;
   begin
      Plan := (others => <>);
      Prepare_Selected_Merge_Source
        (State,
         Older_Run_ID,
         Middle_Run_ID,
         Newer_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Base,
         Head,
         Current,
         Result,
         Allow_Fenced);
      if Result /= Success then
         return;
      end if;
      Read_Checkpoint_SSTs (State.Storage.all, Deadline, Token, Current, Result);
      if Result /= Success then
         Release_Checkpoint_Plan (Current);
         return;
      end if;
      Complete_Selected_Merge_Plan
        (State,
         Older_Run_ID,
         Middle_Run_ID,
         Newer_Run_ID,
         Output_Run_ID,
         Base,
         Head,
         Current,
         Plan,
         Result);
   exception
      when others =>
         Release_Checkpoint_Plan (Current);
         Release_Checkpoint_Plan (Plan);
         raise;
   end Build_Selected_Merge_Plan;

   procedure Decode_Stored_Batch
     (Data              : in out Flyology.Bytes.Unbounded_Bytes;
      Expected_Database : Database_Identifier;
      Limits            : Database_Limits;
      Latest            : Boolean;
      Head              : Head_Snapshot;
      Batch             : out Runtime_Batch;
      Result            : out Outcome_Code) is
   begin
      Decode_Runtime_Batch (Data, Expected_Database, Limits, Batch, Result);
      if Result = Success and then Latest and then not Runtime_Published_By (Batch, Head) then
         Release_Runtime_Batch (Batch);
         Result := Corrupt;
      end if;
   end Decode_Stored_Batch;

   procedure Decode_Recovery_Head
     (Data        : Small_Metadata_Buffer;
      Length      : Natural;
      Database_ID : Database_Identifier;
      Head        : out Head_Snapshot;
      Result      : out Outcome_Code)
   is
      Image         : Formats.Head_Image;
      Value         : Heads.Head_State;
      Decode_Result : Formats.Decode_Status;
   begin
      Head := (others => <>);
      if Length /= Formats.Head_Image_Length then
         Result := Corrupt;
         return;
      end if;
      for Index in Formats.Head_Image_Index loop
         Image (Index) := Data (Index);
      end loop;
      Formats.Decode_Head (Image, To_Head_ID (Database_ID), Value, Decode_Result);
      if Decode_Result /= Formats.Decoded then
         Result :=
           (if Decode_Result = Formats.Unsupported_Version then Unsupported_Format else Corrupt);
         return;
      end if;
      Head := From_Head (Value);
      if Head.Version = Interfaces.Unsigned_16 (Heads.Legacy_Format) then
         Result := Unsupported_Format;
      elsif Head.Version /= Interfaces.Unsigned_16 (Heads.Current_Format)
        or else Is_Zero (Head.Latest_Manifest)
      then
         Result := Corrupt;
      else
         Result := Success;
      end if;
   end Decode_Recovery_Head;

   procedure Decode_Recovery_Batch_Response
     (Data              : in out Flyology.Bytes.Unbounded_Bytes;
      Read_Result       : Read_Outcome;
      Expected_Database : Database_Identifier;
      Limits            : Database_Limits;
      Head              : Head_Snapshot;
      Batch             : out Runtime_Batch;
      Result            : out Outcome_Code) is
   begin
      Batch := (others => <>);
      if Read_Result /= Object_Read then
         Result :=
           (if Read_Result = Read_Cancelled
            then Cancelled
            elsif Read_Result = Read_Timed_Out
            then Timed_Out
            elsif Read_Result = Read_Capacity_Exceeded
            then Capacity_Exceeded
            elsif Read_Result in Object_Missing | Read_Corrupt
            then Corrupt
            else Storage_Failure);
         return;
      end if;
      Decode_Stored_Batch (Data, Expected_Database, Limits, False, Head, Batch, Result);
   end Decode_Recovery_Batch_Response;

   type Recovery_Request_Kind is
     (Recovery_Head_Request,
      Recovery_Manifest_Header_Request,
      Recovery_Manifest_Body_Request,
      Recovery_SST_Header_Request,
      Recovery_SST_Body_Request,
      Recovery_Batch_Request,
      Recovery_No_Request);

   type Recovery_Request is record
      Kind                : Recovery_Request_Kind := Recovery_No_Request;
      Object_ID           : Identifier := Zero_Identifier;
      Requested           : OS.Byte_Range := OS.Whole_Object;
      Expected_Generation : Generation_Value;
      Maximum             : Natural := 0;
   end record;

   type Recovery_Traversal_Phase is
     (Recovery_Needs_Head,
      Recovery_Needs_Manifest_Header,
      Recovery_Needs_Manifest_Body,
      Recovery_Needs_SST_Header,
      Recovery_Needs_SST_Body,
      Recovery_Needs_Batch,
      Recovery_Completed,
      Recovery_Failed);

   type Checkpoint_Manifest_Flag_Array is array (History_Slot) of Boolean;
   type Checkpoint_Replay_Boundary_Array is array (History_Slot) of Interfaces.Unsigned_64;

   type Recovery_Traversal is record
      Database_ID       : Database_Identifier := Zero_Database_ID;
      Sought_Manifest   : Identifier := Zero_Identifier;
      Found_Sought      : Boolean := False;
      Phase             : Recovery_Traversal_Phase := Recovery_Needs_Head;
      Terminal_Result   : Outcome_Code := Invalid_State;
      Head              : Head_Snapshot;
      Generation        : Generation_Value;
      Manifest          : Manifests.Manifest;
      Root              : Manifests.Manifest;
      LSM_Authority     : Engine_LSM_Authority;
      Checkpoint        : Checkpoint_Plan;
      History           : Batch_History_Access := null;
      Count             : Natural := 0;
      Manifests_Seen    : Manifest_History := [others => Manifests.Empty_Manifest];
      --  These runtime witnesses record which retained fixed bases were
      --  authenticated as complete checkpoint manifests. Their positions are
      --  private traversal state and are never persisted.
      Checkpoint_Manifests : Checkpoint_Manifest_Flag_Array := [others => False];
      Checkpoint_Replay_Boundaries : Checkpoint_Replay_Boundary_Array := [others => 0];
      Manifest_Count      : Natural := 0;
      Current_Manifest_ID : Identifier := Zero_Identifier;
      Manifest_Admission  : Manifest_Read_Admission;
      Replay_Boundary     : Sequence_Number := 0;
      SST_Run_Index       : Natural := 0;
      SST_Family_Index    : Natural := 0;
      SST_Admission       : SST_Read_Admission;
      Current_Batch_ID    : Identifier := Zero_Identifier;
   end record;

   --  Owner-stack scheduling phases only. Positions are never persisted or
   --  exposed. A header request uses HeadObject followed by one generation-
   --  bound range child; all other requests use one bounded whole-Get child.
   type Refresh_Driver_Phase is
     (Refresh_Idle,
      Refresh_Waiting_For_Quiescence,
      Refresh_Reading_Header_Head,
      Refresh_Reading_Header_Range,
      Refresh_Reading_Whole,
      Refresh_Terminal);

   type Refresh_Driver_State is record
      Engine                : Engine_State_Access := null;
      Current_Head          : Head_Snapshot;
      Current_Generation    : Generation_Value;
      Traversal             : Recovery_Traversal;
      Request               : Recovery_Request;
      Current_Object_Length : Natural := 0;
      Request_Generation    : Generation_Value;
      Phase                 : Refresh_Driver_Phase := Refresh_Idle;
      Precheck_Result       : Outcome_Code := Success;
      Resolve_Admitted      : Boolean := False;
   end record;

   procedure Free_Refresh_Driver_State is new
     Ada.Unchecked_Deallocation (Refresh_Driver_State, Refresh_Driver_State_Access);

   type Lazy_SST_Read_Phase is
     (Lazy_Read_Idle,
      Lazy_Read_Head,
      Lazy_Read_Header,
      Lazy_Read_Whole,
      Lazy_Read_Index,
      Lazy_Read_Frame,
      Lazy_Read_Terminal);

   type Lazy_SST_Read_State is record
      Database_ID           : Database_Identifier := Zero_Database_ID;
      Family                : Column_Family_Configuration;
      Descriptor            : LSM_Runtime.Run_Descriptor;
      Snapshot_At           : Sequence_Number := 0;
      Item_Key              : Flyology.Bytes.Unbounded_Bytes;
      Generation            : Generation_Value;
      Object_Length         : Natural := 0;
      Admission             : LSM_Runtime.SST_Header_Admission;
      Index                 : LSM_Runtime.SST_V2_Index_Access := null;
      Requested             : OS.Byte_Range;
      Requested_Bytes       : Natural := 0;
      Selected_Position     : Natural := 0;
      Purpose           : Lazy_SST_Read_Purpose := Lazy_Point_Entry;
      Phase                 : Lazy_SST_Read_Phase := Lazy_Read_Idle;
      Precheck_Result       : Outcome_Code := Success;
   end record;

   procedure Free_Lazy_SST_Read_State is new
     Ada.Unchecked_Deallocation (Lazy_SST_Read_State, Lazy_SST_Read_State_Access);

   type Lazy_SST_Table_Holder is record
      Table : LSM_Runtime.SST_Access := null;
   end record;
   procedure Free_Lazy_SST_Table_Holder is new
     Ada.Unchecked_Deallocation (Lazy_SST_Table_Holder, Lazy_SST_Table_Holder_Access);

   type Lazy_SST_Run_Array_Access is access Lazy_SST_Run_Array;

   procedure Free_Lazy_SST_Run_Array is new
     Ada.Unchecked_Deallocation (Lazy_SST_Run_Array, Lazy_SST_Run_Array_Access);

   type Lazy_Checkpoint_Read_Phase is
     (Lazy_Checkpoint_Idle, Lazy_Checkpoint_Reading, Lazy_Checkpoint_Terminal);

   type Lazy_Checkpoint_Read_State is record
      Database_ID     : Database_Identifier := Zero_Database_ID;
      Family          : Column_Family_Configuration;
      Runs            : Lazy_SST_Run_Array_Access := null;
      Current_Index   : Natural := 0;
      Snapshot_At     : Sequence_Number := 0;
      Item_Key        : Flyology.Bytes.Unbounded_Bytes;
      Phase           : Lazy_Checkpoint_Read_Phase := Lazy_Checkpoint_Idle;
      Precheck_Result : Outcome_Code := Success;
   end record;

   procedure Free_Lazy_Checkpoint_Read_State is new
     Ada.Unchecked_Deallocation
       (Lazy_Checkpoint_Read_State, Lazy_Checkpoint_Read_State_Access);

   type Get_Driver_Phase is (Get_Idle, Get_Reading_Checkpoint, Get_Terminal);

   type Get_Driver_State is record
      Database_ID      : Database_Identifier := Zero_Database_ID;
      Incarnation      : Engine_Incarnation := No_Incarnation;
      Transaction_ID   : Transaction_Identifier := Zero_Transaction_ID;
      Snapshot_At      : Sequence_Number := 0;
      Mutation_Version : Interfaces.Unsigned_64 := 0;
      Transaction_Captured : Boolean := False;
      Family           : Column_Family_Configuration;
      Runs             : Lazy_SST_Run_Array_Access := null;
      Item_Key         : Flyology.Bytes.Unbounded_Bytes;
      Phase            : Get_Driver_Phase := Get_Idle;
      Precheck_Result  : Outcome_Code := Success;
      Local_Result     : Outcome_Code := Invalid_State;
      Has_Local_Result : Boolean := False;
      Needs_Observation : Boolean := False;
   end record;

   procedure Free_Get_Driver_State is new
     Ada.Unchecked_Deallocation (Get_Driver_State, Get_Driver_State_Access);

   type Scan_Loaded_Run is record
      Table : LSM_Runtime.SST_Access := null;
      Image : Shared_Image_Access := null;
   end record;
   type Scan_Loaded_Run_Array is array (Positive range <>) of Scan_Loaded_Run;
   type Scan_Loaded_Run_Array_Access is access Scan_Loaded_Run_Array;
   procedure Free_Scan_Loaded_Run_Array is new
     Ada.Unchecked_Deallocation (Scan_Loaded_Run_Array, Scan_Loaded_Run_Array_Access);

   type Scan_Driver_Phase is (Scan_Idle, Scan_Reading_Run, Scan_Terminal);

   type Scan_Driver_State is record
      Database_ID          : Database_Identifier := Zero_Database_ID;
      Incarnation          : Engine_Incarnation := No_Incarnation;
      Transaction_ID       : Transaction_Identifier := Zero_Transaction_ID;
      Snapshot_At          : Sequence_Number := 0;
      Mutation_Version     : Interfaces.Unsigned_64 := 0;
      Transaction_Captured : Boolean := False;
      Family               : Column_Family_Configuration;
      Runs                 : Lazy_SST_Run_Array_Access := null;
      Loaded               : Scan_Loaded_Run_Array_Access := null;
      Current_Run          : Natural := 0;
      Has_Lower            : Boolean := False;
      Lower                : Scan_Cursor_Byte_Array_Access := null;
      Has_Upper            : Boolean := False;
      Upper                : Scan_Cursor_Byte_Array_Access := null;
      Phase                : Scan_Driver_Phase := Scan_Idle;
      Precheck_Result      : Outcome_Code := Success;
   end record;

   procedure Free_Scan_Driver_State is new
     Ada.Unchecked_Deallocation (Scan_Driver_State, Scan_Driver_State_Access);

   procedure Free_Lazy_Checkpoint_Read_Operation is new
     Ada.Unchecked_Deallocation
       (Lazy_Checkpoint_Read_Operation, Lazy_Checkpoint_Read_Operation_Access);

   procedure Free_Lazy_SST_Read_Operation is new
     Ada.Unchecked_Deallocation (Lazy_SST_Read_Operation, Lazy_SST_Read_Operation_Access);

   procedure Fail_Recovery (State : in out Recovery_Traversal; Result : Outcome_Code) is
   begin
      State.Terminal_Result := Result;
      State.Phase := Recovery_Failed;
   end Fail_Recovery;

   procedure Complete_Recovery (State : in out Recovery_Traversal) is
   begin
      State.Terminal_Result := Success;
      State.Phase := Recovery_Completed;
   end Complete_Recovery;

   procedure Release_Recovery (State : in out Recovery_Traversal) is
   begin
      Release_History (State.History, State.Count);
      Release_Checkpoint_Plan (State.Checkpoint);
      State.Phase := Recovery_Failed;
   end Release_Recovery;

   function Starts_After_Checkpoint
     (State : Recovery_Traversal;
      Batch : Runtime_Batch) return Boolean
   is
   begin
      for Index in Positive range 1 .. State.Manifest_Count loop
         if State.Checkpoint_Manifests (Index)
           and then State.Checkpoint_Replay_Boundaries (Index)
                      = Interfaces.Unsigned_64 (State.Replay_Boundary)
           and then To_Database_ID (State.Manifests_Seen (Index).Database_ID) = Batch.Database_ID
           and then State.Manifests_Seen (Index).Writer_Epoch = Batch.Epoch
           and then To_Identifier (State.Manifests_Seen (Index).Publication_Transition_ID)
                      = Batch.Expected_Transition_ID
           and then State.Manifests_Seen (Index).Publication_Transition_Number
                      = Batch.Expected_Transition_Number
         then
            return True;
         end if;
      end loop;
      return False;
   end Starts_After_Checkpoint;

   procedure Start_Recovery
     (State           : out Recovery_Traversal;
      Database_ID     : Database_Identifier;
      Sought_Manifest : Identifier) is
   begin
      State :=
        (Database_ID     => Database_ID,
         Sought_Manifest => Sought_Manifest,
         others          => <>);
   end Start_Recovery;

   procedure Next_Recovery_Request
     (State   : Recovery_Traversal;
      Request : out Recovery_Request)
   is
   begin
      Request := (others => <>);
      case State.Phase is
         when Recovery_Needs_Head =>
            Request.Kind := Recovery_Head_Request;
            Request.Maximum := Formats.Head_Image_Length;

         when Recovery_Needs_Manifest_Header =>
            Request.Kind := Recovery_Manifest_Header_Request;
            Request.Object_ID := State.Current_Manifest_ID;
            Request.Maximum := LSM_Runtime.LSM.Checkpoint_Manifest_Header_Length;
            Request.Requested :=
              (Kind  => OS.Bounded_Range,
               First => 0,
               Last  => OS.Byte_Count (Request.Maximum - 1),
               Count => 0);

         when Recovery_Needs_Manifest_Body =>
            Request.Kind := Recovery_Manifest_Body_Request;
            Request.Object_ID := State.Current_Manifest_ID;
            Request.Expected_Generation := State.Manifest_Admission.Generation;
            Request.Maximum := State.Manifest_Admission.Object_Length;

         when Recovery_Needs_SST_Header =>
            Request.Kind := Recovery_SST_Header_Request;
            Request.Object_ID :=
              To_Identifier (State.Checkpoint.Manifest.Runs (State.SST_Run_Index).Run_ID);
            Request.Maximum := Compatible_SST_Header_Length;
            Request.Requested :=
              (Kind  => OS.Bounded_Range,
               First => 0,
               Last  => OS.Byte_Count (Request.Maximum - 1),
               Count => 0);

         when Recovery_Needs_SST_Body =>
            Request.Kind := Recovery_SST_Body_Request;
            Request.Object_ID :=
              To_Identifier (State.Checkpoint.Manifest.Runs (State.SST_Run_Index).Run_ID);
            Request.Expected_Generation := State.SST_Admission.Generation;
            Request.Maximum := State.SST_Admission.Object_Length;

         when Recovery_Needs_Batch =>
            Request.Kind := Recovery_Batch_Request;
            Request.Object_ID := State.Current_Batch_ID;
            Request.Maximum := Maximum_Runtime_Batch_Length (State.Manifest.Limits);

         when Recovery_Completed | Recovery_Failed =>
            null;
      end case;
   end Next_Recovery_Request;

   procedure Start_Next_Recovery_Batch (State : in out Recovery_Traversal) is
   begin
      if State.Count = Maximum_History_Batches
        or else Interfaces.Unsigned_32 (State.Count) = State.Manifest.Limits.Maximum_Batch_History
      then
         Fail_Recovery (State, Corrupt);
      else
         State.Phase := Recovery_Needs_Batch;
      end if;
   end Start_Next_Recovery_Batch;

   procedure Begin_Recovery_Batches (State : in out Recovery_Traversal) is
      --  Persisted batch-history authority determines the lazy recovery
      --  descriptor allocation; zero/unrepresentable values fail closed.
      Capacity : constant Interfaces.Unsigned_32 := State.Manifest.Limits.Maximum_Batch_History;
   begin
      if State.Head.Highest = State.Replay_Boundary then
         Complete_Recovery (State);
         return;
      elsif State.Head.Highest < State.Replay_Boundary then
         Fail_Recovery (State, Corrupt);
         return;
      elsif Capacity = 0
        or else Interfaces.Unsigned_64 (Capacity) > Interfaces.Unsigned_64 (Positive'Last)
      then
         Fail_Recovery (State, Capacity_Exceeded);
         return;
      end if;
      Allocation_Faults.Check (Recovery_History_Allocation);
      State.History := new Batch_History (1 .. Positive (Capacity));
      State.Current_Batch_ID := State.Head.Latest_Batch;
      Start_Next_Recovery_Batch (State);
   exception
      when Storage_Error =>
         State.History := null;
         Fail_Recovery (State, Capacity_Exceeded);
   end Begin_Recovery_Batches;

   procedure Start_Next_Recovery_SST (State : in out Recovery_Traversal) is
   begin
      if State.Checkpoint.Manifest = null then
         Fail_Recovery (State, Invalid_State);
         return;
      elsif State.SST_Run_Index >= State.Checkpoint.Manifest.Run_Total then
         Begin_Recovery_Batches (State);
         return;
      end if;
      State.SST_Run_Index := State.SST_Run_Index + 1;
      State.SST_Family_Index := 0;
      for Family_Index in State.Checkpoint.Manifest.Families'Range loop
         declare
            Family : LSM_Runtime.Family_LSM_State renames
              State.Checkpoint.Manifest.Families (Family_Index);
         begin
            if Family.Run_Total > 0
              and then State.SST_Run_Index
                         in Family.First_Run .. Family.First_Run + Family.Run_Total - 1
            then
               State.SST_Family_Index := Family_Index;
               exit;
            end if;
         end;
      end loop;
      if State.SST_Family_Index = 0 then
         Fail_Recovery (State, Corrupt);
      else
         State.SST_Admission := (others => <>);
         State.Phase := Recovery_Needs_SST_Header;
      end if;
   end Start_Next_Recovery_SST;

   procedure Consume_Recovery_Head
     (State       : in out Recovery_Traversal;
      Data        : Small_Metadata_Buffer;
      Length      : Natural;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome)
   is
      Result : Outcome_Code;
   begin
      if Read_Result /= Object_Read then
         Result :=
           (if Read_Result = Object_Missing
            then Not_Found
            elsif Read_Result = Read_Cancelled
            then Cancelled
            elsif Read_Result = Read_Timed_Out
            then Timed_Out
            elsif Read_Result = Read_Capacity_Exceeded
            then Capacity_Exceeded
            elsif Read_Result = Read_Corrupt
            then Corrupt
            else Storage_Failure);
         Fail_Recovery (State, Result);
         return;
      end if;
      Decode_Recovery_Head (Data, Length, State.Database_ID, State.Head, Result);
      if Result /= Success then
         Fail_Recovery (State, Result);
         return;
      end if;
      State.Generation := Generation;
      State.Current_Manifest_ID := State.Head.Latest_Manifest;
      State.Manifest_Count := 1;
      State.Phase := Recovery_Needs_Manifest_Header;
   end Consume_Recovery_Head;

   procedure Consume_Recovery_Manifest_Header
     (State       : in out Recovery_Traversal;
      Data        : Flyology.Bytes.Unbounded_Bytes;
      Length      : Natural;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome)
   is
      Result : Outcome_Code;
   begin
      if Read_Result /= Object_Read then
         Fail_Recovery (State, Read_Failure_Outcome (Read_Result, Missing_Is_Corrupt => True));
         return;
      end if;
      Inspect_Leading_Manifest_Header
        (Data,
         Length,
         Generation,
         State.Database_ID,
         State.Manifest_Admission,
         Result);
      if Result = Success then
         State.Phase := Recovery_Needs_Manifest_Body;
      else
         Fail_Recovery (State, Result);
      end if;
   end Consume_Recovery_Manifest_Header;

   procedure Consume_Recovery_Manifest_Body
     (State       : in out Recovery_Traversal;
      Data        : Flyology.Bytes.Unbounded_Bytes;
      Length      : Natural;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome)
   is
      Decoded_Manifest   : Manifests.Manifest;
      Decoded_Authority  : Engine_LSM_Authority;
      Decoded_Checkpoint : LSM_Runtime.Checkpoint_Manifest_Access := null;
      Result             : Outcome_Code;
   begin
      if Read_Result /= Object_Read then
         Fail_Recovery (State, Read_Failure_Outcome (Read_Result, Missing_Is_Corrupt => True));
         return;
      end if;
      Decode_Leading_Manifest_Body
        (Data,
         Length,
         Generation,
         State.Database_ID,
         State.Manifest_Admission,
         Decoded_Manifest,
         Decoded_Authority,
         Decoded_Checkpoint,
         Result);
      if Result /= Success then
         Fail_Recovery (State, Result);
         return;
      end if;
      State.Manifests_Seen (State.Manifest_Count) := Decoded_Manifest;
      State.Checkpoint_Manifests (State.Manifest_Count) := Decoded_Checkpoint /= null;
      if Decoded_Checkpoint /= null then
         State.Checkpoint_Replay_Boundaries (State.Manifest_Count) := Decoded_Checkpoint.Replay_Boundary;
      end if;
      if State.Manifest_Count = 1 then
         State.LSM_Authority := Decoded_Authority;
         State.Checkpoint.Manifest := Decoded_Checkpoint;
         Decoded_Checkpoint := null;
      end if;
      LSM_Runtime.Release (Decoded_Checkpoint);

      if To_Identifier (Decoded_Manifest.Manifest_ID) /= State.Current_Manifest_ID then
         Fail_Recovery (State, Corrupt);
         return;
      elsif not Is_Zero (State.Sought_Manifest)
        and then State.Current_Manifest_ID = State.Sought_Manifest
      then
         State.Found_Sought := True;
      end if;
      if State.Manifest_Count = 1
        and then not Manifests.Referenced_By (Decoded_Manifest, To_Head (State.Head))
      then
         Fail_Recovery (State, Corrupt);
         return;
      elsif State.Manifest_Count > 1
        and then (if State.Checkpoint_Manifests (State.Manifest_Count - 1)
                  then
                    not Manifests.Valid_Checkpoint_Chain_Predecessor
                          (State.Manifests_Seen (State.Manifest_Count - 1), Decoded_Manifest)
                  else
                    not Manifests.Valid_Predecessor
                          (State.Manifests_Seen (State.Manifest_Count - 1), Decoded_Manifest))
      then
         Fail_Recovery (State, Corrupt);
         return;
      elsif not Manifests.Is_Root (Decoded_Manifest) then
         if State.Manifest_Count = Maximum_History_Batches then
            Result :=
              (if State.Manifests_Seen (1).Limits.Maximum_Manifest_History <= Maximum_History_Batches
               then Corrupt
               else Capacity_Exceeded);
            Fail_Recovery (State, Result);
            return;
         elsif Interfaces.Unsigned_32 (State.Manifest_Count)
                 = State.Manifests_Seen (1).Limits.Maximum_Manifest_History
         then
            Fail_Recovery (State, Corrupt);
            return;
         end if;
         State.Current_Manifest_ID := To_Identifier (Decoded_Manifest.Previous_Manifest_ID);
         State.Manifest_Count := State.Manifest_Count + 1;
         State.Manifest_Admission := (others => <>);
         State.Phase := Recovery_Needs_Manifest_Header;
         return;
      end if;

      State.Root := Decoded_Manifest;
      State.Manifest := State.Manifests_Seen (1);
      if not Manifests.Runtime_Compatible (State.Manifest) then
         Fail_Recovery (State, Capacity_Exceeded);
         return;
      elsif State.Checkpoint.Manifest /= null
        and then not Manifests.Is_Root (State.Checkpoint.Manifest.Base)
      then
         if State.Checkpoint.Manifest.Replay_Boundary = 0
           or else State.Checkpoint.Manifest.Replay_Boundary > Interfaces.Unsigned_64 (State.Head.Highest)
         then
            Fail_Recovery (State, Corrupt);
            return;
         end if;
         State.Replay_Boundary := Sequence_Number (State.Checkpoint.Manifest.Replay_Boundary);
         if State.Checkpoint.Manifest.Run_Total > 0 then
            Allocation_Faults.Check (Recovery_SST_Image_Allocation);
            State.Checkpoint.Recovered_SSTs :=
              new Recovered_SST_Array'(1 .. State.Checkpoint.Manifest.Run_Total => null);
         end if;
         State.SST_Run_Index := 0;
         Start_Next_Recovery_SST (State);
      else
         if State.Checkpoint.Manifest /= null then
            LSM_Runtime.Release (State.Checkpoint.Manifest);
         end if;
         Begin_Recovery_Batches (State);
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Decoded_Checkpoint);
         Fail_Recovery (State, Capacity_Exceeded);
      when others =>
         LSM_Runtime.Release (Decoded_Checkpoint);
         raise;
   end Consume_Recovery_Manifest_Body;

   procedure Consume_Recovery_SST_Header
     (State       : in out Recovery_Traversal;
      Data        : Flyology.Bytes.Unbounded_Bytes;
      Length      : Natural;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome)
   is
      Result : Outcome_Code;
   begin
      if Read_Result /= Object_Read then
         Fail_Recovery (State, Read_Failure_Outcome (Read_Result, Missing_Is_Corrupt => True));
         return;
      end if;
      Inspect_Recovery_SST_Header
        (Data,
         Length,
         Generation,
         State.Checkpoint.Manifest,
         State.SST_Family_Index,
         State.Checkpoint.Manifest.Runs (State.SST_Run_Index),
         State.SST_Admission,
         Result);
      if Result = Success then
         State.Phase := Recovery_Needs_SST_Body;
      else
         Fail_Recovery (State, Result);
      end if;
   end Consume_Recovery_SST_Header;

   procedure Consume_Recovery_SST_Body
     (State       : in out Recovery_Traversal;
      Data        : Flyology.Bytes.Unbounded_Bytes;
      Length      : Natural;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome)
   is
      Result : Outcome_Code;
   begin
      if Read_Result /= Object_Read then
         Fail_Recovery (State, Read_Failure_Outcome (Read_Result, Missing_Is_Corrupt => True));
         return;
      end if;
      Decode_Recovery_SST_Body
        (Data,
         Length,
         Generation,
         State.Checkpoint.Manifest,
         State.SST_Family_Index,
         State.Checkpoint.Manifest.Runs (State.SST_Run_Index),
         State.SST_Admission,
         State.Checkpoint.Recovered_SSTs (State.SST_Run_Index),
         Result);
      if Result = Success then
         Start_Next_Recovery_SST (State);
      else
         Fail_Recovery (State, Result);
      end if;
   end Consume_Recovery_SST_Body;

   procedure Consume_Recovery_Batch
     (State       : in out Recovery_Traversal;
      Data        : in out Flyology.Bytes.Unbounded_Bytes;
      Read_Result : Read_Outcome)
   is
      Batch_Result : Outcome_Code;
   begin
      if Read_Result /= Object_Read then
         declare
            Ignored_Batch : Runtime_Batch;
         begin
            Decode_Recovery_Batch_Response
              (Data,
               Read_Result,
               State.Database_ID,
               To_Public_Limits (State.Manifest.Limits),
               State.Head,
               Ignored_Batch,
               Batch_Result);
         end;
         Fail_Recovery (State, Batch_Result);
         return;
      end if;
      State.Count := State.Count + 1;
      Decode_Recovery_Batch_Response
        (Data,
         Read_Result,
         State.Database_ID,
         To_Public_Limits (State.Manifest.Limits),
         State.Head,
         State.History (State.Count),
         Batch_Result);
      if Batch_Result /= Success then
         Fail_Recovery (State, Batch_Result);
         return;
      elsif State.Count = 1
        and then not Runtime_Published_By (State.History (State.Count), State.Head)
        and then
          not Runtime_Anchored_By_Manifest_Chain
                (State.History (State.Count), State.Head, State.Manifests_Seen, State.Manifest_Count)
      then
         Fail_Recovery (State, Corrupt);
         return;
      elsif State.History (State.Count).Batch_ID /= State.Current_Batch_ID then
         Fail_Recovery (State, Corrupt);
         return;
      elsif State.Count > 1
        and then not Runtime_Valid_Predecessor
                       (State.History (State.Count - 1), State.History (State.Count))
      then
         Fail_Recovery (State, Corrupt);
         return;
      elsif State.Replay_Boundary = 0 then
         if State.History (State.Count).First_Sequence = 1
           and then Is_Zero (State.History (State.Count).Previous_Batch_ID)
         then
            Complete_Recovery (State);
            return;
         end if;
      elsif State.History (State.Count).First_Sequence = State.Replay_Boundary + 1 then
         if not Starts_After_Checkpoint (State, State.History (State.Count)) then
            Fail_Recovery (State, Corrupt);
         else
            Complete_Recovery (State);
         end if;
         return;
      elsif State.History (State.Count).First_Sequence <= State.Replay_Boundary then
         Fail_Recovery (State, Corrupt);
         return;
      end if;
      State.Current_Batch_ID := State.History (State.Count).Previous_Batch_ID;
      Start_Next_Recovery_Batch (State);
   end Consume_Recovery_Batch;

   procedure Finish_Recovery
     (State         : in out Recovery_Traversal;
      Head          : out Head_Snapshot;
      Generation    : out Generation_Value;
      Manifest      : out Manifests.Manifest;
      Root          : out Manifests.Manifest;
      LSM_Authority : out Engine_LSM_Authority;
      Checkpoint    : out Checkpoint_Plan;
      History       : out Batch_History_Access;
      Count         : out Natural;
      Result        : out Outcome_Code)
   is
   begin
      Result := State.Terminal_Result;
      if State.Phase = Recovery_Completed then
         Head := State.Head;
         Generation := State.Generation;
         Manifest := State.Manifest;
         Root := State.Root;
         LSM_Authority := State.LSM_Authority;
         Checkpoint := State.Checkpoint;
         State.Checkpoint := (others => <>);
         History := State.History;
         Count := State.Count;
         State.History := null;
         State.Count := 0;
      else
         Head := (others => <>);
         Generation := (others => <>);
         Manifest := Manifests.Empty_Manifest;
         Root := Manifests.Empty_Manifest;
         LSM_Authority := No_LSM_Authority;
         Checkpoint := (others => <>);
         History := null;
         Count := 0;
         Release_Recovery (State);
      end if;
   end Finish_Recovery;

   procedure Read_Recovery
     (Storage         : in out Storage_Context;
      Database_ID     : Database_Identifier;
      Deadline        : Ada.Real_Time.Time;
      Token           : access Flyology.Cancellation.Token;
      Head            : out Head_Snapshot;
      Generation      : out Generation_Value;
      Manifest        : out Manifests.Manifest;
      Root            : out Manifests.Manifest;
      LSM_Authority   : out Engine_LSM_Authority;
      Checkpoint      : out Checkpoint_Plan;
      History         : out Batch_History_Access;
      Count           : out Natural;
      Result          : out Outcome_Code;
      Sought_Manifest : Identifier := Zero_Identifier;
      Sought_Found    : access Boolean := null)
   is
      State      : Recovery_Traversal;
      Request    : Recovery_Request;
      Small_Data : Small_Metadata_Buffer;
      Data       : Flyology.Bytes.Unbounded_Bytes;
      Length     : Natural;
      Generation_Value_Read : Generation_Value;
      Read_Result : Read_Outcome;
   begin
      if Sought_Found /= null then
         Sought_Found.all := False;
      end if;
      Start_Recovery (State, Database_ID, Sought_Manifest);
      loop
         Next_Recovery_Request (State, Request);
         case Request.Kind is
            when Recovery_Head_Request =>
               Storage_Port.Get_Whole
                 (Storage,
                  Full_Key (Storage, Head_Key_Suffix),
                  Head_Object,
                  Deadline,
                  Token,
                  Small_Data,
                  Length,
                  Generation_Value_Read,
                  Read_Result);
               Consume_Recovery_Head
                 (State, Small_Data, Length, Generation_Value_Read, Read_Result);

            when Recovery_Manifest_Header_Request =>
               Storage_Port.Get_Selected
                 (Storage,
                  Manifest_Key (Storage, Request.Object_ID),
                  Manifest_Object,
                  Request.Requested,
                  (others => <>),
                  Deadline,
                  Token,
                  Data,
                  Length,
                  Generation_Value_Read,
                  Read_Result,
                  Request.Maximum);
               Consume_Recovery_Manifest_Header
                 (State, Data, Length, Generation_Value_Read, Read_Result);

            when Recovery_Manifest_Body_Request =>
               Storage_Port.Get_Selected
                 (Storage,
                  Manifest_Key (Storage, Request.Object_ID),
                  Manifest_Object,
                  Request.Requested,
                  Request.Expected_Generation,
                  Deadline,
                  Token,
                  Data,
                  Length,
                  Generation_Value_Read,
                  Read_Result,
                  Request.Maximum);
               Consume_Recovery_Manifest_Body
                 (State, Data, Length, Generation_Value_Read, Read_Result);

            when Recovery_SST_Header_Request =>
               Storage_Port.Get_Selected
                 (Storage,
                  Run_Key (Storage, Request.Object_ID),
                  Run_Object,
                  Request.Requested,
                  (others => <>),
                  Deadline,
                  Token,
                  Data,
                  Length,
                  Generation_Value_Read,
                  Read_Result,
                  Request.Maximum);
               Consume_Recovery_SST_Header
                 (State, Data, Length, Generation_Value_Read, Read_Result);

            when Recovery_SST_Body_Request =>
               Storage_Port.Get_Selected
                 (Storage,
                  Run_Key (Storage, Request.Object_ID),
                  Run_Object,
                  Request.Requested,
                  Request.Expected_Generation,
                  Deadline,
                  Token,
                  Data,
                  Length,
                  Generation_Value_Read,
                  Read_Result,
                  Request.Maximum);
               Consume_Recovery_SST_Body
                 (State, Data, Length, Generation_Value_Read, Read_Result);

            when Recovery_Batch_Request =>
               Storage_Port.Get_Whole
                 (Storage,
                  Batch_Key (Storage, Request.Object_ID),
                  Batch_Object,
                  Deadline,
                  Token,
                  Data,
                  Generation_Value_Read,
                  Read_Result,
                  Request.Maximum);
               Consume_Recovery_Batch (State, Data, Read_Result);

            when Recovery_No_Request =>
               exit;
         end case;
      end loop;
      if Sought_Found /= null then
         Sought_Found.all := State.Found_Sought;
      end if;
      Finish_Recovery
        (State,
         Head,
         Generation,
         Manifest,
         Root,
         LSM_Authority,
         Checkpoint,
         History,
         Count,
         Result);
   exception
      when others =>
         if Sought_Found /= null then
            Sought_Found.all := State.Found_Sought;
         end if;
         Release_Recovery (State);
         raise;
   end Read_Recovery;

   procedure Reconcile_Create_Head
     (Storage         : in out Storage_Context;
      Expected_Root   : Manifests.Manifest;
      Expected_LSM    : Engine_LSM_Authority;
      Observed_Data   : Small_Metadata_Buffer;
      Observed_Length : Natural;
      Deadline        : Ada.Real_Time.Time;
      Token           : access Flyology.Cancellation.Token;
      Head            : out Head_Snapshot;
      Generation      : out Generation_Value;
      Manifest        : out Manifests.Manifest;
      LSM_Authority   : out Engine_LSM_Authority;
      Checkpoint      : out Checkpoint_Plan;
      History         : out Batch_History_Access;
      Count           : out Natural;
      Result          : out Outcome_Code)
   is
      Observed_Database : Database_Identifier := Zero_Database_ID;
      Root              : Manifests.Manifest;
      Read_Result       : Outcome_Code;
   begin
      Head := (others => <>);
      Generation := (others => <>);
      Manifest := Manifests.Empty_Manifest;
      LSM_Authority := No_LSM_Authority;
      Checkpoint := (others => <>);
      History := null;
      Count := 0;
      if Observed_Length /= Formats.Head_Image_Length then
         Result := Corrupt;
         return;
      end if;
      Observed_Database := Head_Database_ID (Observed_Data);
      if Is_Zero (Observed_Database) then
         Result := Corrupt;
         return;
      end if;
      Read_Recovery
        (Storage,
         Observed_Database,
         Deadline,
         Token,
         Head,
         Generation,
         Manifest,
         Root,
         LSM_Authority,
         Checkpoint,
         History,
         Count,
         Read_Result);
      if Read_Result = Success then
         if Observed_Database = To_Database_ID (Expected_Root.Database_ID)
           and then Root = Expected_Root
           and then Same_LSM_Policy (LSM_Authority, Expected_LSM)
         then
            Result := Success;
         else
            Release_History (History, Count);
            Release_Checkpoint_Plan (Checkpoint);
            Result := Already_Exists;
         end if;
      elsif Read_Result = Unsupported_Format then
         Result :=
           (if Observed_Data (8) = 0 and then Observed_Data (9) = Byte (Formats.Legacy_Head_Format_Version)
            then Already_Exists
            else Unsupported_Format);
      elsif Read_Result = Corrupt then
         Result := Corrupt;
      elsif Read_Result = Capacity_Exceeded then
         Result := Capacity_Exceeded;
      else
         Result := Outcome_Unknown;
      end if;
   end Reconcile_Create_Head;

   procedure Allocate_Engine
     (Life          : not null Database_Lifecycle_Access;
      Storage       : not null access Storage_Context;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Manifest      : Manifests.Manifest;
      LSM_Authority : Engine_LSM_Authority;
      Checkpoint    : in out Checkpoint_Plan;
      Incarnation   : Engine_Incarnation;
      History       : in out Batch_History_Access;
      Count         : in out Natural;
      State         : out Engine_State_Access;
      Result        : out Outcome_Code)
   is
      --  All allocation dimensions below come directly from the authenticated
      --  persisted manifest. Seen = history * transactions. A manifest-v2/v3
      --  engine reserves its explicit checkpoint-identity ceiling; legacy v1
      --  retains history * (transactions + one batch/group ID). Every formula
      --  uses checked arithmetic before allocation.
      Entry_Capacity_U64    : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Manifest.Limits.Maximum_Live_Entries);
      History_Capacity_U64  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Manifest.Limits.Maximum_Batch_History);
      Transaction_Cap_U64   : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Manifest.Limits.Maximum_Transactions_Per_Batch);
      Seen_Capacity_U64     : Interfaces.Unsigned_64 := 0;
      Reserved_Capacity_U64 : Interfaces.Unsigned_64 := 0;
      Entry_Capacity        : Positive;
      History_Capacity      : Positive;
      Seen_Capacity         : Positive;
      Reserved_Capacity     : Positive;
      Checkpoint_Live_Count : Natural := 0;
      Trimmed_Base          : State_Entry_Array_Access := null;
   begin
      State := null;
      if Entry_Capacity_U64 = 0
        or else History_Capacity_U64 = 0
        or else Transaction_Cap_U64 = 0
        or else History_Capacity_U64 > Interfaces.Unsigned_64'Last / Transaction_Cap_U64
      then
         Result := Capacity_Exceeded;
         Release_History (History, Count);
         Release_Checkpoint_Plan (Checkpoint);
         return;
      end if;
      Seen_Capacity_U64 := History_Capacity_U64 * Transaction_Cap_U64;
      if LSM_Authority.Enabled then
         Reserved_Capacity_U64 := Interfaces.Unsigned_64 (LSM_Authority.Maximum_Checkpoint_Identities);
      else
         if Transaction_Cap_U64 = Interfaces.Unsigned_64'Last
           or else History_Capacity_U64 > Interfaces.Unsigned_64'Last / (Transaction_Cap_U64 + 1)
         then
            Result := Capacity_Exceeded;
            Release_History (History, Count);
            Release_Checkpoint_Plan (Checkpoint);
            return;
         end if;
         Reserved_Capacity_U64 := History_Capacity_U64 * (Transaction_Cap_U64 + 1);
      end if;
      if Entry_Capacity_U64 > Interfaces.Unsigned_64 (Positive'Last)
        or else History_Capacity_U64 > Interfaces.Unsigned_64 (Positive'Last)
        or else Seen_Capacity_U64 = 0
        or else Seen_Capacity_U64 > Interfaces.Unsigned_64 (Positive'Last)
        or else Reserved_Capacity_U64 = 0
        or else Reserved_Capacity_U64 > Interfaces.Unsigned_64 (Positive'Last)
      then
         Result := Capacity_Exceeded;
         Release_History (History, Count);
         Release_Checkpoint_Plan (Checkpoint);
         return;
      end if;
      Entry_Capacity := Positive (Entry_Capacity_U64);
      History_Capacity := Positive (History_Capacity_U64);
      Seen_Capacity := Positive (Seen_Capacity_U64);
      Reserved_Capacity := Positive (Reserved_Capacity_U64);
      if Checkpoint.Manifest /= null and then not Checkpoint.Activation_Ready then
         Prepare_Checkpoint_Images (Checkpoint, Result);
         if Result /= Success then
            Release_History (History, Count);
            Release_Checkpoint_Plan (Checkpoint);
            return;
         end if;
         Prepare_Checkpoint_Base (Checkpoint, Result);
         if Result /= Success then
            Release_History (History, Count);
            Release_Checkpoint_Plan (Checkpoint);
            return;
         end if;
      end if;
      Allocation_Faults.Check (Engine_State_Allocation);
      Allocation_Faults.Check (Identity_Table_Allocation);
      Allocation_Faults.Check (Projection_Scratch_Allocation);
      State :=
        new Engine_State
              (Entry_Capacity => Entry_Capacity,
               Seen_Capacity => Seen_Capacity,
               History_Capacity => History_Capacity,
               Reserved_Capacity => Reserved_Capacity);
      --  Database retains this caller-owned context only until Close/Finalize.
      State.Storage := Storage.all'Unchecked_Access;
      State.Life := Life;
      State.LSM_Authority := LSM_Authority;
      --  A manifest-v2/v3 checkpoint supplies its authenticated replay boundary;
      --  root and legacy manifests have no compacted-history boundary, so zero
      --  preserves their full retained suffix authority.
      State.Gate.Initialize
        (Head,
         Generation,
         Manifest,
         (if LSM_Authority.Enabled then Sequence_Number (LSM_Authority.Replay_Boundary) else 0),
         Incarnation);
      if Checkpoint.Manifest /= null then
         State.Gate.Recover_Checkpoint
           (Checkpoint,
            Checkpoint.Images,
            Checkpoint.Base,
            Checkpoint_Live_Count,
            Result);
         if Result /= Success then
            Release_History (History, Count);
            Release_Checkpoint_Plan (Checkpoint);
            Release_State_Images (State);
            Free_State (State);
            State := null;
            return;
         end if;
         --  Cacheless recovery allocates merge scratch from the authenticated
         --  sum of all run entries, including overwritten values and
         --  tombstones. Retain only the exact merged live base after the
         --  protected merge has established its final extent.
         if Checkpoint_Live_Count = 0 then
            Free_State_Entries (Checkpoint.Base);
         elsif Checkpoint.Base = null then
            Release_History (History, Count);
            Release_Checkpoint_Plan (Checkpoint);
            Release_State_Images (State);
            Free_State (State);
            State := null;
            Result := Corrupt;
            return;
         elsif Checkpoint.Base'Length /= Checkpoint_Live_Count then
            Allocation_Faults.Check (Recovery_Snapshot_Base_Allocation);
            Trimmed_Base := new State_Entry_Array (1 .. Checkpoint_Live_Count);
            Trimmed_Base.all := Checkpoint.Base (1 .. Checkpoint_Live_Count);
            Free_State_Entries (Checkpoint.Base);
            Checkpoint.Base := Trimmed_Base;
            Trimmed_Base := null;
         end if;
         State.Checkpoint_Images := Checkpoint.Images;
         Checkpoint.Images := null;
         State.Checkpoint_Base := Checkpoint.Base;
         Checkpoint.Base := null;
         State.Checkpoint_Manifest := Checkpoint.Manifest;
         Checkpoint.Manifest := null;
      end if;
      Release_Checkpoint_Plan (Checkpoint);
      for Index in reverse Positive range 1 .. Count loop
         State.Gate.Recover_Batch (History (Index), Result);
         if Result /= Success then
            Release_History (History, Count);
            Release_State_Images (State);
            Free_State (State);
            State := null;
            return;
         end if;
         Release_Runtime_Batch (History (Index), Release_Data => False);
      end loop;
      Free_Batch_History (History);
      Count := 0;
      State.Worker := new Commit_Worker (State);
      Result := Success;
   exception
      when Storage_Error =>
         if State /= null then
            if State.Worker /= null then
               State.Gate.Request_Close;
               State.Gate.Join;
               Free_Worker (State.Worker);
            end if;
            Release_State_Images (State);
            Free_State (State);
         end if;
         Release_History (History, Count);
         Free_State_Entries (Trimmed_Base);
         Release_Checkpoint_Plan (Checkpoint);
         State := null;
         Result := Capacity_Exceeded;
      when others =>
         if State /= null then
            if State.Worker /= null then
               State.Gate.Request_Close;
               State.Gate.Join;
               Free_Worker (State.Worker);
            end if;
            Release_State_Images (State);
            Free_State (State);
         end if;
         Release_History (History, Count);
         Free_State_Entries (Trimmed_Base);
         Release_Checkpoint_Plan (Checkpoint);
         State := null;
         Result := Storage_Failure;
   end Allocate_Engine;

   procedure Start_Engine
     (Item          : in out Database;
      Storage       : not null access Storage_Context;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Manifest      : Manifests.Manifest;
      LSM_Authority : Engine_LSM_Authority;
      Checkpoint    : in out Checkpoint_Plan;
      Incarnation   : Engine_Incarnation;
      History       : in out Batch_History_Access;
      Count         : in out Natural;
      Result        : out Outcome_Code)
   is
      State : Engine_State_Access;
   begin
      Allocate_Engine
        (Item.Life'Unchecked_Access,
         Storage,
         Head,
         Generation,
         Manifest,
         LSM_Authority,
         Checkpoint,
         Incarnation,
         History,
         Count,
         State,
         Result);
      if Result = Success then
         Item.Life.Complete_Open (State, Head.Highest, Result);
         if Result /= Success then
            State.Gate.Request_Close;
            State.Gate.Join;
            Free_Worker (State.Worker);
            Release_State_Images (State);
            Free_State (State);
         end if;
      end if;
   end Start_Engine;

   function Configure_Column_Family
     (ID                   : Column_Family_ID;
      Name                 : Byte_Array;
      Max_Key_Bytes        : Interfaces.Unsigned_64;
      Max_Value_Bytes      : Interfaces.Unsigned_64;
      Memtable_Max_Bytes   : Interfaces.Unsigned_64;
      Memtable_Max_Entries : Interfaces.Unsigned_32;
      Maximum_L0_Runs      : Interfaces.Unsigned_32) return Column_Family_Configuration
   is
      Candidate : Manifests.Column_Family_Configuration;
   begin
      if Name'Length = 0 or else Name'Length > Maximum_Column_Family_Name_Bytes then
         raise Constraint_Error with "column-family name length is invalid";
      end if;
      Candidate.ID := Interfaces.Unsigned_32 (ID);
      Candidate.Name_Length := Name'Length;
      Candidate.Max_Key_Bytes := Max_Key_Bytes;
      Candidate.Max_Value_Bytes := Max_Value_Bytes;
      for Offset in Natural range 0 .. Name'Length - 1 loop
         Candidate.Name (Offset + 1) := Name (Name'First + Offset);
      end loop;
      if not Manifests.Valid_Configuration (Candidate) then
         raise Constraint_Error with "column-family configuration is invalid";
      end if;
      declare
         Result : Column_Family_Configuration := From_Manifest_Configuration (Candidate);
      begin
         if Memtable_Max_Bytes = 0 or else Memtable_Max_Entries = 0 or else Maximum_L0_Runs = 0 then
            raise Constraint_Error with "column-family LSM limits are invalid";
         end if;
         Result.Memtable_Max_Bytes := Memtable_Max_Bytes;
         Result.Memtable_Max_Entries := Memtable_Max_Entries;
         Result.Maximum_L0_Runs := Maximum_L0_Runs;
         return Result;
      end;
   end Configure_Column_Family;

   function Configure_Checkpoint_Run
     (Family_ID : Column_Family_ID; Run_ID : Identifier) return Checkpoint_Run_Identity is
   begin
      if Is_Zero (Run_ID) then
         raise Constraint_Error with "checkpoint run identity must be nonzero";
      end if;
      return (Family_ID => Family_ID, Run_ID => Run_ID);
   end Configure_Checkpoint_Run;

   procedure Build_Root_Manifest
     (Database_ID           : Database_Identifier;
      Manifest_ID           : Identifier;
      Initial_Transition_ID : Identifier;
      Limits                : Database_Limits;
      Initial_Families      : Column_Family_Configuration_Array;
      Value                 : out Manifests.Manifest;
      Result                : out Outcome_Code)
   is
      Candidate : Manifests.Manifest;
      Moved     : Manifests.Column_Family_Configuration;
      Position  : Positive;
   begin
      Value := Manifests.Empty_Manifest;
      if Is_Zero (Database_ID)
        or else Is_Zero (Manifest_ID)
        or else Is_Zero (Initial_Transition_ID)
        or else Initial_Families'Length = 0
        or else Initial_Families'Length > Maximum_Initial_Column_Families
      then
         Result := Invalid_State;
         return;
      end if;
      Candidate.Database_ID := To_Head_ID (Database_ID);
      Candidate.Manifest_ID := To_Head_ID (Manifest_ID);
      Candidate.Publication_Transition_ID := To_Head_ID (Initial_Transition_ID);
      --  A root manifest starts all three persisted monotonic domains at one:
      --  transition 1 publishes it, writer epoch 1 owns it, and registry
      --  revision 1 names the initial family registry. Recovery and stale-writer
      --  fencing depend on these canonical roots and cannot reinterpret them.
      Candidate.Publication_Transition_Number := 1;
      Candidate.Writer_Epoch := 1;
      Candidate.Registry_Revision := 1;
      Candidate.Family_Total := Initial_Families'Length;
      Candidate.Limits := To_Manifest_Limits (Limits);
      for Offset in Natural range 0 .. Initial_Families'Length - 1 loop
         Candidate.Families (Offset + 1) :=
           To_Manifest_Configuration (Initial_Families (Initial_Families'First + Offset));
      end loop;
      for Index in Manifests.Family_Slot range 2 .. Candidate.Family_Total loop
         Moved := Candidate.Families (Index);
         Position := Index;
         while Position > 1 and then Candidate.Families (Position - 1).ID > Moved.ID loop
            Candidate.Families (Position) := Candidate.Families (Position - 1);
            Position := Position - 1;
         end loop;
         Candidate.Families (Position) := Moved;
      end loop;
      if not Manifests.Structurally_Valid (Candidate) then
         Result := Invalid_State;
      elsif not Manifests.Runtime_Compatible (Candidate) then
         Result := Capacity_Exceeded;
      else
         Value := Candidate;
         Result := Success;
      end if;
   end Build_Root_Manifest;

   procedure Build_Root_Checkpoint
     (Database_ID           : Database_Identifier;
      Manifest_ID           : Identifier;
      Initial_Transition_ID : Identifier;
      Limits                : Database_Limits;
      Initial_Families      : Column_Family_Configuration_Array;
      Value                 : out LSM_Runtime.Checkpoint_Manifest_Access;
      Result                : out Outcome_Code)
   is
      Base       : Manifests.Manifest;
      Allocation : LSM_Runtime.Allocation_Status;
   begin
      Value := null;
      Build_Root_Manifest
        (Database_ID, Manifest_ID, Initial_Transition_ID, Limits, Initial_Families, Base, Result);
      if Result /= Success then
         return;
      elsif Limits.Maximum_Total_L0_Runs = 0
        or else Limits.Maximum_Checkpoint_Identities = 0
        or else Limits.Maximum_Point_Reads_Per_Transaction = 0
        or else Limits.Maximum_Scan_Ranges_Per_Transaction = 0
      then
         Result := Invalid_State;
         return;
      end if;
      Allocation_Faults.Check (Root_Checkpoint_State_Allocation);
      LSM_Runtime.Create_Checkpoint_Manifest (Natural (Base.Family_Total), 0, 0, Value, Allocation);
      if Allocation /= LSM_Runtime.Allocated then
         Result := (if Allocation = LSM_Runtime.Allocation_Failed then Capacity_Exceeded else Invalid_State);
         return;
      end if;
      Value.Base := Base;
      Value.Maximum_Total_L0_Runs := Limits.Maximum_Total_L0_Runs;
      Value.Maximum_Checkpoint_Identities := Limits.Maximum_Checkpoint_Identities;
      Value.Maximum_Point_Reads_Per_Transaction := Limits.Maximum_Point_Reads_Per_Transaction;
      Value.Maximum_Scan_Ranges_Per_Transaction := Limits.Maximum_Scan_Ranges_Per_Transaction;
      for Family_Index in Value.Families'Range loop
         declare
            Found : Boolean := False;
         begin
            for Source_Index in Initial_Families'Range loop
               if Interfaces.Unsigned_32 (Initial_Families (Source_Index).ID)
                 = Base.Families (Family_Index).ID
               then
                  Value.Families (Family_Index) :=
                    (Memtable_Max_Bytes   => Initial_Families (Source_Index).Memtable_Max_Bytes,
                     Memtable_Max_Entries => Initial_Families (Source_Index).Memtable_Max_Entries,
                     Maximum_L0_Runs      => Initial_Families (Source_Index).Maximum_L0_Runs,
                     First_Run            => 0,
                     Run_Total            => 0);
                  Found := True;
                  exit;
               end if;
            end loop;
            if not Found then
               LSM_Runtime.Release (Value);
               Result := Invalid_State;
               return;
            end if;
         end;
      end loop;
      if not LSM_Runtime.Structurally_Valid (Value.all) then
         LSM_Runtime.Release (Value);
         Result := Invalid_State;
      else
         Result := Success;
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Value);
         Result := Capacity_Exceeded;
   end Build_Root_Checkpoint;

   procedure Create
     (Item                  : in out Database;
      Storage               : not null access Storage_Context;
      Database_ID           : Database_Identifier;
      Manifest_ID           : Identifier;
      Initial_Transition_ID : Identifier;
      Limits                : Database_Limits;
      Initial_Families      : Column_Family_Configuration_Array;
      Timeout               : Duration;
      Token                 : access Flyology.Cancellation.Token := null;
      Receipt               : out Create_Receipt;
      Result                : out Outcome_Code)
   is
      --  The operation's sole absolute monotonic deadline is derived from the
      --  caller-supplied Timeout; there is no hidden default or retry budget.
      Deadline              : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Head                  : Head_Snapshot;
      Head_Image            : Formats.Head_Image;
      Head_Data             : Small_Metadata_Buffer;
      Manifest_Value        : Manifests.Manifest;
      LSM_Authority         : Engine_LSM_Authority := No_LSM_Authority;
      Checkpoint_Value      : LSM_Runtime.Checkpoint_Manifest_Access := null;
      Manifest_Image        : LSM_Runtime.Image_Access := null;
      Manifest_Length       : Natural := 0;
      Encode_Result         : LSM_Runtime.Encode_Status;
      Manifest_Data         : Small_Metadata_Buffer;
      Read_Data             : Small_Metadata_Buffer;
      Length                : Natural;
      Generation            : Generation_Value;
      Read_Generation       : Generation_Value;
      Put_Result            : Put_Outcome;
      Read_Result           : Read_Outcome;
      History               : Batch_History_Access := null;
      History_Count         : Natural := 0;
      Activation_Checkpoint : Checkpoint_Plan;
      Bucket_Result         : Outcome_Code;
      Stamp                 : Engine_Incarnation;
      Activation_Fault      : Storage_Fault_Mode;
      Guard                 : Activation_Guard;
      pragma Unreferenced (Guard);

      procedure Finish_Activation
        (Activated_Head       : Head_Snapshot;
         Activated_Generation : Generation_Value;
         Activated_Manifest   : Manifests.Manifest;
         Activated_LSM        : Engine_LSM_Authority;
         Activated_Checkpoint : in out Checkpoint_Plan;
         Activated_History    : in out Batch_History_Access;
         Activated_Count      : in out Natural) is
      begin
         Receipt.Phase := Head_Confirmed;
         Receipt.Current_Outcome := Success;
         Release_Retained_Manifest (Receipt);
         Consume_Fault (Storage.all, Before_Local_Activation, Activation_Fault);
         if Activation_Fault /= No_Fault then
            Release_History (Activated_History, Activated_Count);
            Release_Checkpoint_Plan (Activated_Checkpoint);
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
            return;
         end if;
         Incarnation_Source.Allocate (Stamp, Result);
         if Result = Success then
            Start_Engine
              (Item,
               Storage,
               Activated_Head,
               Activated_Generation,
               Activated_Manifest,
               Activated_LSM,
               Activated_Checkpoint,
               Stamp,
               Activated_History,
               Activated_Count,
               Result);
         else
            Release_History (Activated_History, Activated_Count);
            Release_Checkpoint_Plan (Activated_Checkpoint);
         end if;
         if Result = Success then
            Guard.Active := False;
         else
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
         end if;
      end Finish_Activation;

      procedure Attempt_Head is
      begin
         if Token /= null and then Token.Requested then
            Result := Cancelled;
            Receipt.Current_Outcome := Result;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            Receipt.Current_Outcome := Result;
            return;
         end if;
         Storage_Port.Put_Create
           (Storage.all,
            Full_Key (Storage.all, Head_Key_Suffix),
            Head_Data,
            Formats.Head_Image_Length,
            Head_Object,
            Deadline,
            Token,
            Generation,
            Put_Result);
         if Put_Result = Object_Published then
            Finish_Activation
              (Head,
               Generation,
               Manifest_Value,
               LSM_Authority,
               Activation_Checkpoint,
               History,
               History_Count);
         elsif Put_Result in Put_Outcome_Unknown | Put_Precondition_Failed then
            if Put_Result = Put_Outcome_Unknown then
               Receipt.Phase := Head_Publication_Unknown;
            end if;
            Storage_Port.Get_Whole
              (Storage.all,
               Full_Key (Storage.all, Head_Key_Suffix),
               Head_Object,
               Deadline,
               Token,
               Read_Data,
               Length,
               Read_Generation,
               Read_Result);
            if Read_Result = Object_Read
              and then Exact_Bytes (Head_Data, Formats.Head_Image_Length, Read_Data, Length)
            then
               Generation := Read_Generation;
               Finish_Activation
                 (Head,
                  Read_Generation,
                  Manifest_Value,
                  LSM_Authority,
                  Activation_Checkpoint,
                  History,
                  History_Count);
            elsif Read_Result = Object_Read then
               declare
                  Observed_Head       : Head_Snapshot;
                  Observed_Manifest   : Manifests.Manifest;
                  Observed_LSM        : Engine_LSM_Authority;
                  Observed_Checkpoint : Checkpoint_Plan;
                  Observed_History    : Batch_History_Access;
                  Observed_Count      : Natural;
               begin
                  Reconcile_Create_Head
                    (Storage.all,
                     Manifest_Value,
                     LSM_Authority,
                     Read_Data,
                     Length,
                     Deadline,
                     Token,
                     Observed_Head,
                     Read_Generation,
                     Observed_Manifest,
                     Observed_LSM,
                     Observed_Checkpoint,
                     Observed_History,
                     Observed_Count,
                     Result);
                  if Result = Success then
                     Finish_Activation
                       (Observed_Head,
                        Read_Generation,
                        Observed_Manifest,
                        Observed_LSM,
                        Observed_Checkpoint,
                        Observed_History,
                        Observed_Count);
                  else
                     Receipt.Current_Outcome := Result;
                  end if;
               end;
            elsif Put_Result = Put_Precondition_Failed then
               Result := Outcome_Unknown;
               Receipt.Current_Outcome := Result;
            else
               Result := Outcome_Unknown;
               Receipt.Current_Outcome := Result;
            end if;
         elsif Put_Result = Put_Cancelled then
            Result := Cancelled;
            Receipt.Current_Outcome := Result;
         elsif Put_Result = Put_Timed_Out then
            Result := Timed_Out;
            Receipt.Current_Outcome := Result;
         else
            Result := Storage_Failure;
            Receipt.Current_Outcome := Result;
         end if;
      end Attempt_Head;
   begin
      Receipt := (others => <>);
      Build_Root_Checkpoint
        (Database_ID, Manifest_ID, Initial_Transition_ID, Limits, Initial_Families, Checkpoint_Value, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Manifest_Value := Checkpoint_Value.Base;
      LSM_Authority := To_Engine_LSM_Authority (Checkpoint_Value.all);
      begin
         Allocation_Faults.Check (Root_Checkpoint_Image_Allocation);
         LSM_Runtime.Encode_Checkpoint_Manifest (Checkpoint_Value.all, Manifest_Image, Encode_Result);
      exception
         when Storage_Error =>
            LSM_Runtime.Release (Checkpoint_Value);
            Result := Capacity_Exceeded;
            Receipt.Current_Outcome := Result;
            return;
      end;
      if Manifest_Image /= null then
         Manifest_Length := Manifest_Image.all'Length;
      end if;
      LSM_Runtime.Release (Checkpoint_Value);
      if Encode_Result = LSM_Runtime.Allocation_Failed or else Encode_Result = LSM_Runtime.Length_Overflow
      then
         LSM_Runtime.Release (Manifest_Image);
         Result := Capacity_Exceeded;
         Receipt.Current_Outcome := Result;
         return;
      elsif Encode_Result /= LSM_Runtime.Encoded
        or else Manifest_Image = null
        or else not Storage_Bound (Storage.all)
        or else not OS.Valid_Object_Key (Manifest_Key (Storage.all, Manifest_ID))
        or else not OS.Valid_Object_Key (Full_Key (Storage.all, Head_Key_Suffix))
      then
         LSM_Runtime.Release (Manifest_Image);
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      elsif Manifest_Length > Manifest_Data'Length then
         --  The frozen small-metadata buffer is the current transport boundary.
         --  A valid caller-selected root that outgrows it is a typed capacity
         --  failure before object publication, never malformed database state.
         LSM_Runtime.Release (Manifest_Image);
         Result := Capacity_Exceeded;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Copy_Manifest_Image (Manifest_Image.all, Manifest_Length, Manifest_Data);
      begin
         Allocation_Faults.Check (Root_Manifest_Retention_Allocation);
         Receipt.Retained_Manifest.Image := New_Image (Manifest_Image.all);
      exception
         when Storage_Error =>
            LSM_Runtime.Release (Manifest_Image);
            Result := Capacity_Exceeded;
            Receipt.Current_Outcome := Result;
            return;
      end;
      LSM_Runtime.Release (Manifest_Image);
      Receipt.Database_ID := Database_ID;
      Receipt.Manifest_ID := Manifest_ID;
      Head :=
        (Database_ID            => Database_ID,
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => Manifest_ID,
         Transition_ID          => Initial_Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Receipt.Attempted_Head := Head;
      Head_Image := Formats.Encode_Head (To_Head (Head));
      Copy_Head_Image (Head_Image, Head_Data);
      Item.Life.Begin_Open (Result);
      if Result /= Success then
         Release_Retained_Manifest (Receipt);
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Storage_Port.Bucket_Available (Storage.all, Deadline, Token, Bucket_Result);
      if Bucket_Result /= Success then
         Release_Retained_Manifest (Receipt);
         Result := Bucket_Result;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Storage_Port.Put_Create
        (Storage.all,
         Manifest_Key (Storage.all, Manifest_ID),
         Manifest_Data,
         Manifest_Length,
         Manifest_Object,
         Deadline,
         Token,
         Generation,
         Put_Result);
      if Put_Result = Object_Published then
         Receipt.Phase := Manifest_Confirmed;
         Attempt_Head;
      elsif Put_Result in Put_Outcome_Unknown | Put_Precondition_Failed then
         Storage_Port.Get_Whole
           (Storage.all,
            Manifest_Key (Storage.all, Manifest_ID),
            Manifest_Object,
            Deadline,
            Token,
            Read_Data,
            Length,
            Read_Generation,
            Read_Result);
         if Read_Result = Object_Read and then Exact_Bytes (Manifest_Data, Manifest_Length, Read_Data, Length)
         then
            Receipt.Phase := Manifest_Confirmed;
            Attempt_Head;
         elsif Read_Result = Object_Read then
            Release_Retained_Manifest (Receipt);
            Result := Already_Exists;
            Receipt.Current_Outcome := Result;
         else
            Result := Outcome_Unknown;
            Receipt.Current_Outcome := Result;
         end if;
      elsif Put_Result = Put_Cancelled then
         Release_Retained_Manifest (Receipt);
         Result := Cancelled;
         Receipt.Current_Outcome := Result;
      elsif Put_Result = Put_Timed_Out then
         Release_Retained_Manifest (Receipt);
         Result := Timed_Out;
         Receipt.Current_Outcome := Result;
      else
         Release_Retained_Manifest (Receipt);
         Result := Storage_Failure;
         Receipt.Current_Outcome := Result;
      end if;
   exception
      when others =>
         LSM_Runtime.Release (Checkpoint_Value);
         LSM_Runtime.Release (Manifest_Image);
         Release_Checkpoint_Plan (Activation_Checkpoint);
         Result :=
           (if Receipt.Phase = Head_Confirmed
            then Local_Activation_Failed
            elsif Receipt.Phase = Head_Publication_Unknown
            then Outcome_Unknown
            else Storage_Failure);
         Receipt.Current_Outcome := Result;
         if Receipt.Phase = No_Create_Publication and then Result /= Outcome_Unknown then
            Release_Retained_Manifest (Receipt);
         end if;
   end Create;

   procedure Resolve_Create
     (Item    : in out Database;
      Storage : not null access Storage_Context;
      Receipt : in out Create_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code)
   is
      --  The operation's sole absolute monotonic deadline is derived from the
      --  caller-supplied Timeout; there is no hidden default or retry budget.
      Deadline              : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Manifest_Value        : Manifests.Manifest;
      LSM_Authority         : Engine_LSM_Authority := No_LSM_Authority;
      Decode_Result         : Outcome_Code;
      Manifest_Data         : Small_Metadata_Buffer := [others => 0];
      Manifest_Length       : Natural := 0;
      Head_Image            : Formats.Head_Image;
      Head_Data             : Small_Metadata_Buffer;
      Read_Data             : Small_Metadata_Buffer;
      Length                : Natural;
      Generation            : Generation_Value;
      Put_Result            : Put_Outcome;
      Read_Result           : Read_Outcome;
      Bucket_Result         : Outcome_Code;
      History               : Batch_History_Access := null;
      History_Count         : Natural := 0;
      Activation_Checkpoint : Checkpoint_Plan;
      Stamp                 : Engine_Incarnation;
      Activation_Fault      : Storage_Fault_Mode;
      Guard                 : Activation_Guard;
      pragma Unreferenced (Guard);

      procedure Activate
        (Activated_Head       : Head_Snapshot;
         Activated_Generation : Generation_Value;
         Activated_Manifest   : Manifests.Manifest;
         Activated_LSM        : Engine_LSM_Authority;
         Activated_Checkpoint : in out Checkpoint_Plan;
         Activated_History    : in out Batch_History_Access;
         Activated_Count      : in out Natural) is
      begin
         Receipt.Phase := Head_Confirmed;
         Receipt.Current_Outcome := Success;
         Release_Retained_Manifest (Receipt);
         Consume_Fault (Storage.all, Before_Local_Activation, Activation_Fault);
         if Activation_Fault /= No_Fault then
            Release_History (Activated_History, Activated_Count);
            Release_Checkpoint_Plan (Activated_Checkpoint);
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
            return;
         end if;
         Incarnation_Source.Allocate (Stamp, Result);
         if Result = Success then
            Start_Engine
              (Item,
               Storage,
               Activated_Head,
               Activated_Generation,
               Activated_Manifest,
               Activated_LSM,
               Activated_Checkpoint,
               Stamp,
               Activated_History,
               Activated_Count,
               Result);
         else
            Release_History (Activated_History, Activated_Count);
            Release_Checkpoint_Plan (Activated_Checkpoint);
         end if;
         if Result = Success then
            Guard.Active := False;
         else
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
         end if;
      end Activate;
   begin
      if Receipt.Retained_Manifest.Image /= null then
         Manifest_Length := Flyology.Bytes.Length (Receipt.Retained_Manifest.Image.Data);
      end if;
      if Manifest_Length > 0 and then Manifest_Length <= Manifest_Data'Length then
         for Index in Natural range 0 .. Manifest_Length - 1 loop
            Manifest_Data (Index) :=
              Byte (Flyology.Bytes.Element (Receipt.Retained_Manifest.Image.Data, Index + 1));
         end loop;
      end if;
      if Receipt.Phase = Head_Confirmed then
         Result := Local_Activation_Failed;
         Receipt.Current_Outcome := Result;
         return;
      elsif Receipt.Database_ID = Zero_Database_ID
        or else Is_Zero (Receipt.Manifest_ID)
        or else Manifest_Length = 0
        or else Manifest_Length > Manifest_Data'Length
        or else not Storage_Bound (Storage.all)
      then
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Decode_Stored_Manifest_With_Authority
        (Manifest_Data, Manifest_Length, Receipt.Database_ID, Manifest_Value, LSM_Authority, Decode_Result);
      if Decode_Result /= Success
        or else To_Identifier (Manifest_Value.Manifest_ID) /= Receipt.Manifest_ID
        or else not Manifests.Valid_Root_Publication (To_Head (Receipt.Attempted_Head), Manifest_Value)
        or else not OS.Valid_Object_Key (Manifest_Key (Storage.all, Receipt.Manifest_ID))
        or else not OS.Valid_Object_Key (Full_Key (Storage.all, Head_Key_Suffix))
      then
         Release_Retained_Manifest (Receipt);
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Head_Image := Formats.Encode_Head (To_Head (Receipt.Attempted_Head));
      Copy_Head_Image (Head_Image, Head_Data);
      Item.Life.Begin_Open (Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Storage_Port.Bucket_Available (Storage.all, Deadline, Token, Bucket_Result);
      if Bucket_Result /= Success then
         Result := Bucket_Result;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Storage_Port.Get_Whole
        (Storage.all,
         Manifest_Key (Storage.all, Receipt.Manifest_ID),
         Manifest_Object,
         Deadline,
         Token,
         Read_Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result = Object_Read and then Exact_Bytes (Manifest_Data, Manifest_Length, Read_Data, Length)
      then
         if Receipt.Phase = No_Create_Publication then
            Receipt.Phase := Manifest_Confirmed;
         end if;
      elsif Read_Result = Object_Read then
         Result := (if Receipt.Phase = No_Create_Publication then Already_Exists else Corrupt);
         Release_Retained_Manifest (Receipt);
         Receipt.Current_Outcome := Result;
         return;
      elsif Read_Result = Object_Missing then
         Result := (if Receipt.Phase = No_Create_Publication then Storage_Failure else Corrupt);
         if Result = Corrupt then
            Release_Retained_Manifest (Receipt);
         end if;
         Receipt.Current_Outcome := Result;
         return;
      else
         Result :=
           (if Receipt.Phase = Head_Publication_Unknown
            then Outcome_Unknown
            elsif Read_Result = Read_Cancelled
            then Cancelled
            elsif Read_Result = Read_Timed_Out
            then Timed_Out
            elsif Read_Result = Read_Capacity_Exceeded
            then Capacity_Exceeded
            else Outcome_Unknown);
         Receipt.Current_Outcome := Result;
         return;
      end if;
      if Receipt.Phase = Manifest_Confirmed then
         if Token /= null and then Token.Requested then
            Result := Cancelled;
            Receipt.Current_Outcome := Result;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            Receipt.Current_Outcome := Result;
            return;
         end if;
         Storage_Port.Put_Create
           (Storage.all,
            Full_Key (Storage.all, Head_Key_Suffix),
            Head_Data,
            Formats.Head_Image_Length,
            Head_Object,
            Deadline,
            Token,
            Generation,
            Put_Result);
         if Put_Result = Object_Published then
            Activate
              (Receipt.Attempted_Head,
               Generation,
               Manifest_Value,
               LSM_Authority,
               Activation_Checkpoint,
               History,
               History_Count);
            return;
         elsif Put_Result = Put_Outcome_Unknown then
            Receipt.Phase := Head_Publication_Unknown;
         elsif Put_Result = Put_Precondition_Failed then
            null;
         elsif Put_Result = Put_Cancelled then
            Result := Cancelled;
            Receipt.Current_Outcome := Result;
            return;
         elsif Put_Result = Put_Timed_Out then
            Result := Timed_Out;
            Receipt.Current_Outcome := Result;
            return;
         else
            Result := Storage_Failure;
            Receipt.Current_Outcome := Result;
            return;
         end if;
      end if;
      Storage_Port.Get_Whole
        (Storage.all,
         Full_Key (Storage.all, Head_Key_Suffix),
         Head_Object,
         Deadline,
         Token,
         Read_Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result = Object_Read
        and then Exact_Bytes (Head_Data, Formats.Head_Image_Length, Read_Data, Length)
      then
         Activate
           (Receipt.Attempted_Head,
            Generation,
            Manifest_Value,
            LSM_Authority,
            Activation_Checkpoint,
            History,
            History_Count);
      elsif Read_Result = Object_Read then
         declare
            Observed_Head       : Head_Snapshot;
            Observed_Manifest   : Manifests.Manifest;
            Observed_LSM        : Engine_LSM_Authority;
            Observed_Checkpoint : Checkpoint_Plan;
            Observed_History    : Batch_History_Access;
            Observed_Count      : Natural;
         begin
            Reconcile_Create_Head
              (Storage.all,
               Manifest_Value,
               LSM_Authority,
               Read_Data,
               Length,
               Deadline,
               Token,
               Observed_Head,
               Generation,
               Observed_Manifest,
               Observed_LSM,
               Observed_Checkpoint,
               Observed_History,
               Observed_Count,
               Result);
            if Result = Success then
               Activate
                 (Observed_Head,
                  Generation,
                  Observed_Manifest,
                  Observed_LSM,
                  Observed_Checkpoint,
                  Observed_History,
                  Observed_Count);
            else
               Receipt.Current_Outcome := Result;
            end if;
         end;
      else
         Result := Outcome_Unknown;
         Receipt.Current_Outcome := Result;
      end if;
   exception
      when others =>
         Release_Checkpoint_Plan (Activation_Checkpoint);
         Result :=
           (if Receipt.Phase = Head_Confirmed
            then Local_Activation_Failed
            elsif Receipt.Phase = Head_Publication_Unknown
            then Outcome_Unknown
            else Storage_Failure);
         Receipt.Current_Outcome := Result;
   end Resolve_Create;

   function Create_Receipt_Outcome (Item : Create_Receipt) return Outcome_Code
   is (Item.Current_Outcome);

   function Create_Receipt_Manifest_ID (Item : Create_Receipt) return Identifier
   is (Item.Manifest_ID);

   function Create_Receipt_Transition_ID (Item : Create_Receipt) return Identifier
   is (if Item.Phase in Head_Publication_Unknown | Head_Confirmed
       then Item.Attempted_Head.Transition_ID
       else Zero_Identifier);

   procedure Open
     (Item        : in out Database;
      Storage     : not null access Storage_Context;
      Database_ID : Database_Identifier;
      Timeout     : Duration;
      Token       : access Flyology.Cancellation.Token := null;
      Result      : out Outcome_Code)
   is
      --  The operation's sole absolute monotonic deadline is derived from the
      --  caller-supplied Timeout; there is no hidden default or retry budget.
      Deadline      : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Manifest      : Manifests.Manifest;
      Root          : Manifests.Manifest;
      LSM_Authority : Engine_LSM_Authority;
      Checkpoint    : Checkpoint_Plan;
      History       : Batch_History_Access := null;
      History_Count : Natural;
      Bucket_Result : Outcome_Code;
      Stamp         : Engine_Incarnation;
      Guard         : Activation_Guard;
      pragma Unreferenced (Guard);
   begin
      if not Storage_Bound (Storage.all) or else Is_Zero (Database_ID) then
         Result := Invalid_State;
         return;
      end if;
      Item.Life.Begin_Open (Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Storage_Port.Bucket_Available (Storage.all, Deadline, Token, Bucket_Result);
      if Bucket_Result /= Success then
         Result := Bucket_Result;
         return;
      end if;
      Read_Recovery
        (Storage.all,
         Database_ID,
         Deadline,
         Token,
         Head,
         Generation,
         Manifest,
         Root,
         LSM_Authority,
         Checkpoint,
         History,
         History_Count,
         Result);
      if Result = Success then
         Incarnation_Source.Allocate (Stamp, Result);
      end if;
      if Result = Success then
         Start_Engine
           (Item,
            Storage,
            Head,
            Generation,
            Manifest,
            LSM_Authority,
            Checkpoint,
            Stamp,
            History,
            History_Count,
            Result);
      end if;
      if Result = Success then
         Guard.Active := False;
      else
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
      end if;
   exception
      when others =>
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Result := Storage_Failure;
   end Open;

   procedure Reset_Transaction (Txn : out Transaction) is
   begin
      Release_Arena (Txn.Owner.Arena);
      Txn.Active := False;
      Txn.Database_ID := Zero_Database_ID;
      Txn.Incarnation := No_Incarnation;
      Txn.Transaction_ID := Zero_Transaction_ID;
      Txn.Snapshot_At := 0;
      Txn.Isolation := Snapshot;
      Txn.Point_Read_Limit := 0;
      Txn.Scan_Range_Limit := 0;
   end Reset_Transaction;

   procedure Close (Item : in out Database; Result : out Outcome_Code) is
      State : Engine_State_Access;
   begin
      Item.Life.Begin_Close (State, Result);
      if Result /= Success then
         return;
      end if;
      State.Gate.Request_Close;
      Item.Life.Await_Quiescent;
      State.Gate.Join;
      Free_Worker (State.Worker);
      Release_State_Images (State);
      Free_State (State);
      Item.Life.Finish_Close;
      Result := Success;
   end Close;

   procedure Begin_Transaction
     (Item           : in out Database;
      Transaction_ID : Transaction_Identifier;
      Txn            : out Transaction;
      Result         : out Outcome_Code)
   is
   begin
      Begin_Transaction (Item, Transaction_ID, Snapshot, Txn, Result);
   end Begin_Transaction;

   procedure Begin_Transaction
     (Item           : in out Database;
      Transaction_ID : Transaction_Identifier;
      Isolation      : Isolation_Level;
      Txn            : out Transaction;
      Result         : out Outcome_Code)
   is
      Lease            : Lifecycle_Lease;
      Head             : Head_Snapshot;
      Generation       : Generation_Value;
      Uncertain        : Boolean;
      Fenced           : Boolean;
      Mutation_Limit   : Interfaces.Unsigned_32;
      Payload_Limit    : Interfaces.Unsigned_64;
      Point_Read_Limit : Interfaces.Unsigned_32;
      Scan_Range_Limit : Interfaces.Unsigned_32;
      Mutations        : Owned_Mutation_Array_Access := null;
   begin
      Reset_Transaction (Txn);
      if Is_Zero (Transaction_ID) then
         Result := Invalid_State;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Transaction_Available (Transaction_ID, Result);
      if Result = Success then
         Lease.State.Gate.Transaction_Limits (Mutation_Limit, Payload_Limit);
         Point_Read_Limit := Lease.State.LSM_Authority.Maximum_Point_Reads_Per_Transaction;
         Scan_Range_Limit := Lease.State.LSM_Authority.Maximum_Scan_Ranges_Per_Transaction;
         if Isolation = Serializable and then (Point_Read_Limit = 0 or else Scan_Range_Limit = 0) then
            Result := Unsupported_Format;
            return;
         elsif Mutation_Limit = 0
           or else Interfaces.Unsigned_64 (Mutation_Limit) > Interfaces.Unsigned_64 (Natural'Last)
           or else Payload_Limit = 0
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
         Allocation_Faults.Check (Transaction_Arena_Allocation);
         Mutations := new Owned_Mutation_Array (1 .. Natural (Mutation_Limit));
         Txn.Owner.Arena :=
           new Transaction_Arena'
             (Mutations => Mutations,
              Count => 0,
              Bytes_Used => 0,
              others => <>);
         Mutations := null;
         Image_Accounting.Record_Arena_Allocation;
         Txn.Active := True;
         Txn.Database_ID := Head.Database_ID;
         Txn.Incarnation := Lease.State.Gate.Current_Incarnation;
         Txn.Transaction_ID := Transaction_ID;
         Txn.Snapshot_At := Head.Highest;
         Txn.Isolation := Isolation;
         Txn.Point_Read_Limit := Point_Read_Limit;
         Txn.Scan_Range_Limit := Scan_Range_Limit;
      end if;
   exception
      when Storage_Error =>
         Free_Owned_Mutations (Mutations);
         Reset_Transaction (Txn);
         Result := Capacity_Exceeded;
   end Begin_Transaction;

   procedure Open_Column_Family
     (Item : in out Database; ID : Column_Family_ID; Family : out Column_Family; Result : out Outcome_Code)
   is
      Lease         : Lifecycle_Lease;
      Configuration : Column_Family_Configuration;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
   begin
      Family := (others => <>);
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
      elsif Fenced then
         Result := Stale_Writer;
      else
         Lease.State.Gate.Find_Family (ID, Configuration, Result);
         if Result = Success then
            Family :=
              (Valid         => True,
               Database_ID   => Head.Database_ID,
               Incarnation   => Lease.State.Gate.Current_Incarnation,
               Configuration => Configuration);
         end if;
      end if;
   end Open_Column_Family;

   procedure Open_Column_Family
     (Item : in out Database; Name : Byte_Array; Family : out Column_Family; Result : out Outcome_Code)
   is
      Lease         : Lifecycle_Lease;
      Configuration : Column_Family_Configuration;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
   begin
      Family := (others => <>);
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
      elsif Fenced then
         Result := Stale_Writer;
      else
         Lease.State.Gate.Find_Family (Name, Configuration, Result);
         if Result = Success then
            Family :=
              (Valid         => True,
               Database_ID   => Head.Database_ID,
               Incarnation   => Lease.State.Gate.Current_Incarnation,
               Configuration => Configuration);
         end if;
      end if;
   end Open_Column_Family;

   function Same_Owned_Key (Mutation : Owned_Mutation; Item_Key : Byte_Array) return Boolean is
   begin
      if Mutation.Key_Length /= Item_Key'Length then
         return False;
      end if;
      for Offset in Natural range 0 .. Item_Key'Length - 1 loop
         if Byte (Flyology.Bytes.Element (Mutation.Payload, Offset + 1)) /= Item_Key (Item_Key'First + Offset)
         then
            return False;
         end if;
      end loop;
      return True;
   end Same_Owned_Key;

   function Same_Owned_Key (Point : Owned_Point_Read; Item_Key : Byte_Array) return Boolean is
   begin
      if Point.Key_Length /= Item_Key'Length then
         return False;
      end if;
      for Offset in Natural range 0 .. Item_Key'Length - 1 loop
         if Byte (Flyology.Bytes.Element (Point.Key, Offset + 1)) /= Item_Key (Item_Key'First + Offset) then
            return False;
         end if;
      end loop;
      return True;
   end Same_Owned_Key;

   --  Runtime ordering result for exact arbitrary-byte keys. It is neither a
   --  persisted encoding nor an enumeration-position contract; bytewise
   --  lexicographic ordering is the normalized scan-predicate authority.
   type Byte_Order is (Before, Same, After);

   function Compare_Bytes (Left, Right : Byte_Array) return Byte_Order is
      Common : constant Natural := Natural'Min (Left'Length, Right'Length);
   begin
      if Common > 0 then
         for Offset in Natural range 0 .. Common - 1 loop
            if Left (Left'First + Offset) < Right (Right'First + Offset) then
               return Before;
            elsif Left (Left'First + Offset) > Right (Right'First + Offset) then
               return After;
            end if;
         end loop;
      end if;
      if Left'Length < Right'Length then
         return Before;
      elsif Left'Length > Right'Length then
         return After;
      else
         return Same;
      end if;
   end Compare_Bytes;

   function Same_Endpoint
     (Stored : Flyology.Bytes.Unbounded_Bytes; Stored_Length : Natural; Value : Byte_Array) return Boolean
   is
   begin
      if Stored_Length /= Value'Length then
         return False;
      end if;
      if Stored_Length > 0 then
         for Offset in Natural range 0 .. Stored_Length - 1 loop
            if Byte (Flyology.Bytes.Element (Stored, Offset + 1)) /= Value (Value'First + Offset) then
               return False;
            end if;
         end loop;
      end if;
      return True;
   end Same_Endpoint;

   function Compare_Stored_To_Bytes
     (Stored : Flyology.Bytes.Unbounded_Bytes; Stored_Length : Natural; Value : Byte_Array) return Byte_Order
   is
      Common : constant Natural := Natural'Min (Stored_Length, Value'Length);
   begin
      if Common > 0 then
         for Offset in Natural range 0 .. Common - 1 loop
            if Byte (Flyology.Bytes.Element (Stored, Offset + 1)) < Value (Value'First + Offset) then
               return Before;
            elsif Byte (Flyology.Bytes.Element (Stored, Offset + 1)) > Value (Value'First + Offset) then
               return After;
            end if;
         end loop;
      end if;
      if Stored_Length < Value'Length then
         return Before;
      elsif Stored_Length > Value'Length then
         return After;
      else
         return Same;
      end if;
   end Compare_Stored_To_Bytes;

   function Compare_Stored_Endpoints
     (Left         : Flyology.Bytes.Unbounded_Bytes;
      Left_Length  : Natural;
      Right        : Flyology.Bytes.Unbounded_Bytes;
      Right_Length : Natural) return Byte_Order
   is
      Common : constant Natural := Natural'Min (Left_Length, Right_Length);
   begin
      if Common > 0 then
         for Offset in Natural range 0 .. Common - 1 loop
            if Flyology.Bytes.Element (Left, Offset + 1) < Flyology.Bytes.Element (Right, Offset + 1) then
               return Before;
            elsif Flyology.Bytes.Element (Left, Offset + 1) > Flyology.Bytes.Element (Right, Offset + 1) then
               return After;
            end if;
         end loop;
      end if;
      if Left_Length < Right_Length then
         return Before;
      elsif Left_Length > Right_Length then
         return After;
      else
         return Same;
      end if;
   end Compare_Stored_Endpoints;

   procedure Record_Point_Read
     (Txn : in out Transaction; Family : Column_Family_ID; Item_Key : Byte_Array; Result : out Outcome_Code)
   is
      Existing  : Owned_Point_Read_Access := Txn.Owner.Arena.Point_Reads;
      Candidate : Owned_Point_Read_Access := null;
   begin
      while Existing /= null loop
         if Existing.Family = Family and then Same_Owned_Key (Existing.all, Item_Key) then
            Result := Success;
            return;
         end if;
         Existing := Existing.Next;
      end loop;
      if Txn.Owner.Arena.Point_Read_Count >= Txn.Point_Read_Limit then
         Result := Capacity_Exceeded;
         return;
      end if;

      Allocation_Faults.Check (Point_Read_Node_Allocation);
      Candidate := new Owned_Point_Read;
      Allocation_Faults.Check (Point_Read_Key_Allocation);
      Flyology.Bytes.Reserve_Capacity (Candidate.Key, Item_Key'Length);
      for Value of Item_Key loop
         Flyology.Bytes.Append (Candidate.Key, Ada.Streams.Stream_Element (Value));
      end loop;
      Candidate.Family := Family;
      Candidate.Key_Length := Item_Key'Length;
      Candidate.Next := Txn.Owner.Arena.Point_Reads;
      Txn.Owner.Arena.Point_Reads := Candidate;
      Candidate := null;
      Txn.Owner.Arena.Point_Read_Count := Txn.Owner.Arena.Point_Read_Count + 1;
      Image_Accounting.Record_Transaction_Copy (Item_Key'Length);
      Result := Success;
   exception
      when Storage_Error =>
         Free_Owned_Point_Read (Candidate);
         Result := Capacity_Exceeded;
   end Record_Point_Read;

   procedure Record_Scan_Range
     (Txn       : in out Transaction;
      Family    : Column_Family_ID;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array;
      Result    : out Outcome_Code)
   is
      Existing        : Owned_Scan_Range_Access;
      Previous        : Owned_Scan_Range_Access;
      Following       : Owned_Scan_Range_Access;
      Candidate       : Owned_Scan_Range_Access := null;
      Lower_Source    : Owned_Scan_Range_Access := null;
      Upper_Source    : Owned_Scan_Range_Access := null;
      Only_Merged     : Owned_Scan_Range_Access := null;
      Final_Has_Lower : Boolean := Has_Lower;
      Final_Has_Upper : Boolean := Has_Upper;
      Lower_Is_Input  : Boolean := Has_Lower;
      Upper_Is_Input  : Boolean := Has_Upper;
      Expanded        : Boolean;
      Merged_Count    : Interfaces.Unsigned_32 := 0;
      Remaining_Count : Interfaces.Unsigned_32;
      Copied_Lower    : Natural := 0;
      Copied_Upper    : Natural := 0;

      function Stored_Before_Final_Lower
        (Stored : Flyology.Bytes.Unbounded_Bytes; Stored_Length : Natural) return Boolean
      is
      begin
         if Lower_Is_Input then
            return Compare_Stored_To_Bytes (Stored, Stored_Length, Lower) = Before;
         else
            return Compare_Stored_Endpoints
              (Stored, Stored_Length, Lower_Source.Lower, Lower_Source.Lower_Length)
              = Before;
         end if;
      end Stored_Before_Final_Lower;

      function Final_Upper_Before_Stored
        (Stored : Flyology.Bytes.Unbounded_Bytes; Stored_Length : Natural) return Boolean
      is
      begin
         if Upper_Is_Input then
            return Compare_Stored_To_Bytes (Stored, Stored_Length, Upper) = After;
         else
            return Compare_Stored_Endpoints
              (Upper_Source.Upper, Upper_Source.Upper_Length, Stored, Stored_Length)
              = Before;
         end if;
      end Final_Upper_Before_Stored;

      function Connected_To_Final (Item : Owned_Scan_Range) return Boolean is
      begin
         return Item.Family = Family
           and then
             (not Item.Has_Upper
              or else not Final_Has_Lower
              or else not Stored_Before_Final_Lower (Item.Upper, Item.Upper_Length))
           and then
             (not Final_Has_Upper
              or else not Item.Has_Lower
              or else not Final_Upper_Before_Stored (Item.Lower, Item.Lower_Length));
      end Connected_To_Final;

      function Same_As_Final (Item : Owned_Scan_Range) return Boolean is
      begin
         return Item.Family = Family
           and then Item.Has_Lower = Final_Has_Lower
           and then Item.Has_Upper = Final_Has_Upper
           and then
             (not Final_Has_Lower
              or else
                (if Lower_Is_Input
                 then Same_Endpoint (Item.Lower, Item.Lower_Length, Lower)
                 else Compare_Stored_Endpoints
                        (Item.Lower,
                         Item.Lower_Length,
                         Lower_Source.Lower,
                         Lower_Source.Lower_Length)
                      = Same))
           and then
             (not Final_Has_Upper
              or else
                (if Upper_Is_Input
                 then Same_Endpoint (Item.Upper, Item.Upper_Length, Upper)
                 else Compare_Stored_Endpoints
                        (Item.Upper,
                         Item.Upper_Length,
                         Upper_Source.Upper,
                         Upper_Source.Upper_Length)
                      = Same));
      end Same_As_Final;
   begin
      loop
         Expanded := False;
         Existing := Txn.Owner.Arena.Scan_Ranges;
         while Existing /= null loop
            if Connected_To_Final (Existing.all) then
               if Final_Has_Lower and then not Existing.Has_Lower then
                  Final_Has_Lower := False;
                  Lower_Is_Input := False;
                  Lower_Source := Existing;
                  Expanded := True;
               elsif Final_Has_Lower
                 and then Existing.Has_Lower
                 and then Stored_Before_Final_Lower (Existing.Lower, Existing.Lower_Length)
               then
                  Lower_Is_Input := False;
                  Lower_Source := Existing;
                  Expanded := True;
               end if;
               if Final_Has_Upper and then not Existing.Has_Upper then
                  Final_Has_Upper := False;
                  Upper_Is_Input := False;
                  Upper_Source := Existing;
                  Expanded := True;
               elsif Final_Has_Upper
                 and then Existing.Has_Upper
                 and then Final_Upper_Before_Stored (Existing.Upper, Existing.Upper_Length)
               then
                  Upper_Is_Input := False;
                  Upper_Source := Existing;
                  Expanded := True;
               end if;
            end if;
            Existing := Existing.Next;
         end loop;
         exit when not Expanded;
      end loop;

      Existing := Txn.Owner.Arena.Scan_Ranges;
      while Existing /= null loop
         if Connected_To_Final (Existing.all) then
            Merged_Count := Merged_Count + 1;
            Only_Merged := Existing;
         end if;
         Existing := Existing.Next;
      end loop;

      if Merged_Count = 1 and then Same_As_Final (Only_Merged.all) then
         Result := Success;
         return;
      elsif Merged_Count > Txn.Owner.Arena.Scan_Range_Count then
         Result := Capacity_Exceeded;
         return;
      end if;
      Remaining_Count := Txn.Owner.Arena.Scan_Range_Count - Merged_Count;
      if Remaining_Count >= Txn.Scan_Range_Limit then
         Result := Capacity_Exceeded;
         return;
      end if;

      begin
         Allocation_Faults.Check (Scan_Range_Node_Allocation);
         Candidate := new Owned_Scan_Range;
         if Final_Has_Lower then
            Allocation_Faults.Check (Scan_Range_Lower_Allocation);
            if Lower_Is_Input then
               Flyology.Bytes.Reserve_Capacity (Candidate.Lower, Lower'Length);
               for Value of Lower loop
                  Flyology.Bytes.Append (Candidate.Lower, Ada.Streams.Stream_Element (Value));
               end loop;
               Candidate.Lower_Length := Lower'Length;
            else
               Flyology.Bytes.Reserve_Capacity (Candidate.Lower, Lower_Source.Lower_Length);
               for Offset in Positive range 1 .. Lower_Source.Lower_Length loop
                  Flyology.Bytes.Append
                    (Candidate.Lower, Flyology.Bytes.Element (Lower_Source.Lower, Offset));
               end loop;
               Candidate.Lower_Length := Lower_Source.Lower_Length;
            end if;
         end if;
         if Final_Has_Upper then
            Allocation_Faults.Check (Scan_Range_Upper_Allocation);
            if Upper_Is_Input then
               Flyology.Bytes.Reserve_Capacity (Candidate.Upper, Upper'Length);
               for Value of Upper loop
                  Flyology.Bytes.Append (Candidate.Upper, Ada.Streams.Stream_Element (Value));
               end loop;
               Candidate.Upper_Length := Upper'Length;
            else
               Flyology.Bytes.Reserve_Capacity (Candidate.Upper, Upper_Source.Upper_Length);
               for Offset in Positive range 1 .. Upper_Source.Upper_Length loop
                  Flyology.Bytes.Append
                    (Candidate.Upper, Flyology.Bytes.Element (Upper_Source.Upper, Offset));
               end loop;
               Candidate.Upper_Length := Upper_Source.Upper_Length;
            end if;
         end if;
      exception
         when Storage_Error =>
            Free_Owned_Scan_Range (Candidate);
            Result := Capacity_Exceeded;
            return;
      end;
      Candidate.Family := Family;
      Candidate.Has_Lower := Final_Has_Lower;
      Candidate.Has_Upper := Final_Has_Upper;
      if Final_Has_Lower then
         Copied_Lower := Candidate.Lower_Length;
         Lower_Is_Input := False;
         Lower_Source := Candidate;
      end if;
      if Final_Has_Upper then
         Copied_Upper := Candidate.Upper_Length;
         Upper_Is_Input := False;
         Upper_Source := Candidate;
      end if;

      Previous := null;
      Existing := Txn.Owner.Arena.Scan_Ranges;
      while Existing /= null loop
         Following := Existing.Next;
         if Connected_To_Final (Existing.all) then
            if Previous = null then
               Txn.Owner.Arena.Scan_Ranges := Following;
            else
               Previous.Next := Following;
            end if;
            Existing.Next := null;
            Free_Owned_Scan_Range (Existing);
         else
            Previous := Existing;
         end if;
         Existing := Following;
      end loop;
      Candidate.Next := Txn.Owner.Arena.Scan_Ranges;
      Txn.Owner.Arena.Scan_Ranges := Candidate;
      Candidate := null;
      Txn.Owner.Arena.Scan_Range_Count := Remaining_Count + 1;
      if Final_Has_Lower then
         Image_Accounting.Record_Transaction_Copy (Copied_Lower);
      end if;
      if Final_Has_Upper then
         Image_Accounting.Record_Transaction_Copy (Copied_Upper);
      end if;
      Result := Success;
   end Record_Scan_Range;

   procedure Store_Mutation
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
      Item_Key  : Byte_Array;
      Data      : Byte_Array;
      Operation : Mutation_Kind;
      Result    : out Outcome_Code)
   is
      Lease         : Lifecycle_Lease;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      Existing      : Natural := 0;
      Old_Bytes     : Interfaces.Unsigned_64 := 0;
      New_Bytes     : Interfaces.Unsigned_64;
      Candidate     : Flyology.Bytes.Unbounded_Bytes;
      Configuration : Column_Family_Configuration;
   begin
      if not Txn.Active or else Txn.Owner.Arena = null then
         Result := Invalid_State;
         return;
      elsif (Natural'Size > Interfaces.Unsigned_32'Size
             and then (Interfaces.Unsigned_64 (Item_Key'Length)
                       > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
                       or else (Operation = Put_Mutation
                                and then Interfaces.Unsigned_64 (Data'Length)
                                         > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last))))
        or else Item_Key'Length > Natural'Last - Data'Length
      then
         Result := Capacity_Exceeded;
         return;
      end if;
      New_Bytes :=
        Interfaces.Unsigned_64 (Item_Key'Length + (if Operation = Put_Mutation then Data'Length else 0));
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID or else Txn.Incarnation /= Lease.State.Gate.Current_Incarnation
      then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      Lease.State.Gate.Validate_Family (Family, Configuration, Result);
      if Result /= Success then
         return;
      elsif Interfaces.Unsigned_64 (Item_Key'Length) > Configuration.Max_Key_Bytes
        or else (Operation = Put_Mutation
                 and then Interfaces.Unsigned_64 (Data'Length) > Configuration.Max_Value_Bytes)
      then
         Result := Capacity_Exceeded;
         return;
      end if;
      for Index in Positive range 1 .. Txn.Owner.Arena.Count loop
         if Txn.Owner.Arena.Mutations (Index).Family = Family.Configuration.ID
           and then Same_Owned_Key (Txn.Owner.Arena.Mutations (Index), Item_Key)
         then
            Existing := Index;
            Old_Bytes :=
              Interfaces.Unsigned_64
                (Txn.Owner.Arena.Mutations (Index).Key_Length
                 + Txn.Owner.Arena.Mutations (Index).Value_Length);
            exit;
         end if;
      end loop;
      if Existing = 0 and then Txn.Owner.Arena.Count = Txn.Owner.Arena.Mutations'Length then
         Result := Capacity_Exceeded;
         return;
      elsif Txn.Owner.Arena.Bytes_Used < Old_Bytes
        or else New_Bytes > Interfaces.Unsigned_64'Last - (Txn.Owner.Arena.Bytes_Used - Old_Bytes)
      then
         Result := Capacity_Exceeded;
         return;
      end if;
      Lease.State.Gate.Validate_Transaction_Bounds
        (Txn.Owner.Arena.Count + (if Existing = 0 then 1 else 0),
         Txn.Owner.Arena.Bytes_Used - Old_Bytes + New_Bytes,
         Result);
      if Result /= Success then
         return;
      elsif Txn.Owner.Arena.Mutation_Version = Interfaces.Unsigned_64'Last then
         Result := Capacity_Exceeded;
         return;
      end if;

      Allocation_Faults.Check (Transaction_Payload_Allocation);
      Flyology.Bytes.Reserve_Capacity (Candidate, Natural (New_Bytes));
      for Value of Item_Key loop
         Flyology.Bytes.Append (Candidate, Ada.Streams.Stream_Element (Value));
      end loop;
      if Operation = Put_Mutation then
         for Value of Data loop
            Flyology.Bytes.Append (Candidate, Ada.Streams.Stream_Element (Value));
         end loop;
      end if;
      if Existing = 0 then
         Txn.Owner.Arena.Count := Txn.Owner.Arena.Count + 1;
         Existing := Txn.Owner.Arena.Count;
      end if;
      declare
         Mutation : Owned_Mutation renames Txn.Owner.Arena.Mutations (Existing);
      begin
         Mutation.Family := Family.Configuration.ID;
         Mutation.Operation := Operation;
         Mutation.Key_Length := Item_Key'Length;
         Mutation.Value_Length := (if Operation = Put_Mutation then Data'Length else 0);
         Flyology.Bytes.Move (Mutation.Payload, Candidate);
      end;
      Txn.Owner.Arena.Bytes_Used := Txn.Owner.Arena.Bytes_Used - Old_Bytes + New_Bytes;
      Txn.Owner.Arena.Mutation_Version := Txn.Owner.Arena.Mutation_Version + 1;
      Image_Accounting.Record_Transaction_Copy (Natural (New_Bytes));
      Result := Success;
   exception
      when Storage_Error =>
         Result := Capacity_Exceeded;
   end Store_Mutation;

   procedure Get
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Byte_Array;
      Data     : out Flyology.Bytes.Unbounded_Bytes;
      Result   : out Outcome_Code)
   is
      Lease         : Lifecycle_Lease;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      Configuration : Column_Family_Configuration;
      Image         : Shared_Image_Access;
      Value_Offset  : Natural;
      Value_Length  : Natural;
      Matched       : Boolean;
   begin
      Flyology.Bytes.Clear (Data);
      if not Txn.Active or else Txn.Owner.Arena = null then
         Result := Invalid_State;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID or else Txn.Incarnation /= Lease.State.Gate.Current_Incarnation
      then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      Lease.State.Gate.Validate_Family (Family, Configuration, Result);
      if Result /= Success then
         return;
      elsif Interfaces.Unsigned_64 (Item_Key'Length) > Configuration.Max_Key_Bytes then
         Result := Capacity_Exceeded;
         return;
      end if;
      for Index in reverse Positive range 1 .. Txn.Owner.Arena.Count loop
         declare
            Mutation : Owned_Mutation renames Txn.Owner.Arena.Mutations (Index);
         begin
            if Mutation.Family = Family.Configuration.ID and then Same_Owned_Key (Mutation, Item_Key) then
               if Mutation.Operation = Delete_Mutation then
                  Result := Not_Found;
               else
                  Flyology.Bytes.Reserve_Capacity (Data, Mutation.Value_Length);
                  for Offset in Positive range 1 .. Mutation.Value_Length loop
                     Flyology.Bytes.Append
                       (Data, Flyology.Bytes.Element (Mutation.Payload, Mutation.Key_Length + Offset));
                  end loop;
                  Result := Success;
               end if;
               return;
            end if;
         end;
      end loop;
      Lease.State.Gate.Lookup_At
        (Family.Configuration.ID,
         Item_Key,
         Txn.Snapshot_At,
         Lease.State.Checkpoint_Base,
         Image,
         Value_Offset,
         Value_Length,
         Matched,
         Result);
      if Result = Success then
         Flyology.Bytes.Reserve_Capacity (Data, Value_Length);
         for Offset in Positive range 1 .. Value_Length loop
            Flyology.Bytes.Append (Data, Flyology.Bytes.Element (Image.Data, Value_Offset + Offset));
         end loop;
      end if;
      if Txn.Isolation = Serializable and then Result in Success | Not_Found then
         declare
            Read_Result        : constant Outcome_Code := Result;
            Observation_Result : Outcome_Code;
         begin
            Record_Point_Read (Txn, Family.Configuration.ID, Item_Key, Observation_Result);
            if Observation_Result = Success then
               Result := Read_Result;
            else
               Flyology.Bytes.Clear (Data);
               Result := Observation_Result;
            end if;
         end;
      end if;
   exception
      when Storage_Error =>
         Flyology.Bytes.Clear (Data);
         Result := Capacity_Exceeded;
   end Get;

   procedure Observe_Range
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array;
      Result    : out Outcome_Code)
   is
      Lease         : Lifecycle_Lease;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      Configuration : Column_Family_Configuration;
   begin
      if not Txn.Active or else Txn.Owner.Arena = null then
         Result := Invalid_State;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID or else Txn.Incarnation /= Lease.State.Gate.Current_Incarnation
      then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      Lease.State.Gate.Validate_Family (Family, Configuration, Result);
      if Result /= Success then
         return;
      elsif (Has_Lower and then Interfaces.Unsigned_64 (Lower'Length) > Configuration.Max_Key_Bytes)
        or else (Has_Upper and then Interfaces.Unsigned_64 (Upper'Length) > Configuration.Max_Key_Bytes)
      then
         Result := Capacity_Exceeded;
         return;
      elsif Has_Lower and then Has_Upper and then Compare_Bytes (Lower, Upper) /= Before then
         Result := Invalid_State;
         return;
      elsif Txn.Isolation = Snapshot then
         Result := Success;
         return;
      end if;
      Record_Scan_Range
        (Txn, Family.Configuration.ID, Has_Lower, Lower, Has_Upper, Upper, Result);
   exception
      when Storage_Error =>
         Result := Capacity_Exceeded;
   end Observe_Range;

   procedure Build_Scan_Cursor
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array;
      Loaded       : Scan_Loaded_Run_Array_Access;
      Pinned_State : Engine_State_Access;
      Cursor    : in out Scan_Cursor;
      Result    : out Outcome_Code)
   is
      Lease         : Lifecycle_Lease;
      State         : Engine_State_Access := Pinned_State;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      Configuration : Column_Family_Configuration;
      Candidate     : Scan_Cursor_State_Access := null;

      procedure Build_Physical_Snapshot is
         Captured          : Natural := 0;
         Raw_Count         : Natural := 0;
         Own_Count         : Natural := 0;
         External_Count         : Natural := 0;
         Entry_Total       : Natural := 0;
         Source_Total      : Natural := 0;
         Raw               : Scan_Source_Array_Access := null;
         Maximum_Rows      : Interfaces.Unsigned_32 := 0;
         Maximum_Bytes     : Interfaces.Unsigned_64 := 0;
         Maximum_Authority : Natural := 0;
         Own_Authority     : Natural := 0;

         function Key_Byte (Source : Scan_Source; Offset : Natural) return Byte is
         begin
            if Source.Arena_Index = 0 then
               return Byte (Flyology.Bytes.Element (Source.Key_Image.Data, Source.Key_Offset + Offset + 1));
            else
               return
                 Byte
                   (Flyology.Bytes.Element
                      (Txn.Owner.Arena.Mutations (Source.Arena_Index).Payload, Offset + 1));
            end if;
         end Key_Byte;

         function Same_Key (Left, Right : Scan_Source) return Boolean is
         begin
            if Left.Key_Length /= Right.Key_Length then
               return False;
            end if;
            if Left.Key_Length > 0 then
               for Offset in Natural range 0 .. Left.Key_Length - 1 loop
                  if Key_Byte (Left, Offset) /= Key_Byte (Right, Offset) then
                     return False;
                  end if;
               end loop;
            end if;
            return True;
         end Same_Key;

         function Key_Less (Left, Right : Scan_Source) return Boolean is
            Common : constant Natural := Natural'Min (Left.Key_Length, Right.Key_Length);
         begin
            if Common > 0 then
               for Offset in Natural range 0 .. Common - 1 loop
                  if Key_Byte (Left, Offset) < Key_Byte (Right, Offset) then
                     return True;
                  elsif Key_Byte (Left, Offset) > Key_Byte (Right, Offset) then
                     return False;
                  end if;
               end loop;
            end if;
            return Left.Key_Length < Right.Key_Length;
         end Key_Less;

         function Before_Bound (Source : Scan_Source; Bound : Byte_Array) return Boolean is
            Common : constant Natural := Natural'Min (Source.Key_Length, Bound'Length);
         begin
            if Common > 0 then
               for Offset in Natural range 0 .. Common - 1 loop
                  if Key_Byte (Source, Offset) < Bound (Bound'First + Offset) then
                     return True;
                  elsif Key_Byte (Source, Offset) > Bound (Bound'First + Offset) then
                     return False;
                  end if;
               end loop;
            end if;
            return Source.Key_Length < Bound'Length;
         end Before_Bound;

         function In_Range (Source : Scan_Source) return Boolean
         is ((not Has_Lower or else not Before_Bound (Source, Lower))
             and then (not Has_Upper or else Before_Bound (Source, Upper)));

         function Comes_Before (Left, Right : Scan_Source) return Boolean is
         begin
            if Left.Authority /= Right.Authority then
               return Left.Authority < Right.Authority;
            elsif Key_Less (Left, Right) then
               return True;
            elsif Key_Less (Left => Right, Right => Left) then
               return False;
            elsif Left.Version /= Right.Version then
               return Left.Version < Right.Version;
            else
               return Left.Order < Right.Order;
            end if;
         end Comes_Before;

         function Last_For_Key (Index : Positive) return Boolean
         is (Index = Raw'Last
             or else Raw (Index).Authority /= Raw (Index + 1).Authority
             or else not Same_Key (Raw (Index), Raw (Index + 1)));

         procedure Release_Raw is
         begin
            Free_Scan_Sources (Raw);
         end Release_Raw;
      begin
         if Loaded /= null then
            for Run of Loaded.all loop
               if Run.Table = null or else Run.Image = null then
                  Result := Corrupt;
                  return;
               end if;
               for SST_Item of Run.Table.Entries loop
                  if SST_Item.Sequence <= Interfaces.Unsigned_64 (Txn.Snapshot_At) then
                     if External_Count = Natural'Last then
                        Result := Capacity_Exceeded;
                        return;
                     end if;
                     External_Count := External_Count + 1;
                  end if;
               end loop;
            end loop;
         end if;
         for Index in Positive range 1 .. Txn.Owner.Arena.Count loop
            if Txn.Owner.Arena.Mutations (Index).Family = Configuration.ID then
               if Own_Count = Natural'Last then
                  Result := Capacity_Exceeded;
                  return;
               end if;
               Own_Count := Own_Count + 1;
            end if;
         end loop;
         if Own_Count > Natural'Last - External_Count then
            Result := Capacity_Exceeded;
            return;
         end if;
         State.Gate.Scan_Source_Requirements
           (Configuration.ID,
            Txn.Snapshot_At,
            (if Loaded = null then State.Checkpoint_Base else null),
            Own_Count + External_Count,
            Raw_Count,
            Maximum_Rows,
            Maximum_Bytes,
            Result);
         if Result /= Success then
            return;
         end if;
         Candidate.Maximum_Rows := Maximum_Rows;
         Candidate.Maximum_Bytes := Maximum_Bytes;
         if Raw_Count = 0 then
            Result := Success;
            return;
         end if;
         Allocation_Faults.Check (Scan_Source_Allocation);
         Raw := new Scan_Source_Array (1 .. Raw_Count);
         State.Gate.Copy_Scan_Sources
           (Configuration.ID,
            Txn.Snapshot_At,
            (if Loaded = null then State.Checkpoint_Base else null),
            Raw,
            Captured,
            Result);
         if Result /= Success then
            Release_Raw;
            return;
         end if;
         if Loaded /= null then
            for Index in Positive range 1 .. Captured loop
               if Raw (Index).Authority > Natural'Last - Loaded'Length then
                  Release_Raw;
                  Result := Capacity_Exceeded;
                  return;
               end if;
               Raw (Index).Authority := Raw (Index).Authority + Loaded'Length;
            end loop;
            for Run_Index in Loaded'Range loop
               declare
                  Run       : Scan_Loaded_Run renames Loaded (Run_Index);
                  Authority : constant Natural := Run_Index - Loaded'First + 1;
               begin
                  for Entry_Index in Run.Table.Entries'Range loop
                     declare
                        SST_Item : LSM_Runtime.SST_Entry renames Run.Table.Entries (Entry_Index);
                     begin
                        if SST_Item.Sequence <= Interfaces.Unsigned_64 (Txn.Snapshot_At) then
                           if Captured = Raw'Length
                             or else SST_Item.Sequence = 0
                             or else SST_Item.Key_Offset = 0
                             or else SST_Item.Operation
                                     not in LSM_Runtime.LSM.Put_Operation | LSM_Runtime.LSM.Delete_Operation
                             or else (SST_Item.Operation = LSM_Runtime.LSM.Put_Operation
                                      and then SST_Item.Value_Offset = 0)
                           then
                              Release_Raw;
                              Result := Corrupt;
                              return;
                           end if;
                           Captured := Captured + 1;
                           Raw (Captured) :=
                             (Key_Image             => Run.Image,
                              Key_Offset            => SST_Item.Key_Offset - 1,
                              Key_Length            => SST_Item.Key_Byte_Total,
                              Authority             => Authority,
                              Version               => Sequence_Number (SST_Item.Sequence),
                              Order                 => Entry_Index,
                              Operation             =>
                                (if SST_Item.Operation = LSM_Runtime.LSM.Put_Operation
                                 then Put_Mutation
                                 else Delete_Mutation),
                              Selected_Image        => Run.Image,
                              Selected_Value_Offset =>
                                (if SST_Item.Operation = LSM_Runtime.LSM.Put_Operation
                                 then SST_Item.Value_Offset - 1
                                 else 0),
                              Selected_Value_Length =>
                                (if SST_Item.Operation = LSM_Runtime.LSM.Put_Operation
                                 then SST_Item.Value_Byte_Total
                                 else 0),
                              others                => <>);
                        end if;
                     end;
                  end loop;
               end;
            end loop;
         end if;
         for Index in Positive range 1 .. Captured loop
            Maximum_Authority := Natural'Max (Maximum_Authority, Raw (Index).Authority);
         end loop;
         if Own_Count > 0 then
            if Maximum_Authority = Natural'Last then
               Release_Raw;
               Result := Capacity_Exceeded;
               return;
            end if;
            Own_Authority := Maximum_Authority + 1;
            for Mutation_Index in Positive range 1 .. Txn.Owner.Arena.Count loop
               if Txn.Owner.Arena.Mutations (Mutation_Index).Family = Configuration.ID then
                  if Captured = Raw'Length then
                     Release_Raw;
                     Result := Capacity_Exceeded;
                     return;
                  end if;
                  Captured := Captured + 1;
                  Raw (Captured) :=
                    (Key_Length            => Txn.Owner.Arena.Mutations (Mutation_Index).Key_Length,
                     Arena_Index           => Mutation_Index,
                     Authority             => Own_Authority,
                     Version               => Txn.Snapshot_At,
                     Order                 => Mutation_Index,
                     Operation             => Txn.Owner.Arena.Mutations (Mutation_Index).Operation,
                     Selected_Value_Length => Txn.Owner.Arena.Mutations (Mutation_Index).Value_Length,
                     others                => <>);
               end if;
            end loop;
         end if;
         if Captured /= Raw_Count then
            Release_Raw;
            Result := Corrupt;
            return;
         end if;
         for Index in Positive range Raw'First + 1 .. Raw'Last loop
            declare
               Value    : constant Scan_Source := Raw (Index);
               Position : Positive := Index;
            begin
               while Position > Raw'First and then Comes_Before (Value, Raw (Position - 1)) loop
                  Raw (Position) := Raw (Position - 1);
                  Position := Position - 1;
               end loop;
               Raw (Position) := Value;
            end;
         end loop;
         declare
            Prior_Kept_Authority : Natural := 0;
         begin
            for Index in Raw'Range loop
               if In_Range (Raw (Index)) and then Last_For_Key (Index) then
                  if Entry_Total = Natural'Last then
                     Release_Raw;
                     Result := Capacity_Exceeded;
                     return;
                  end if;
                  Entry_Total := Entry_Total + 1;
                  if Raw (Index).Authority /= Prior_Kept_Authority then
                     Source_Total := Source_Total + 1;
                     Prior_Kept_Authority := Raw (Index).Authority;
                  end if;
               end if;
            end loop;
         end;
         if Entry_Total = 0 then
            Release_Raw;
            Result := Success;
            return;
         end if;
         Allocation_Faults.Check (Scan_Cursor_Entry_Allocation);
         Candidate.Entries := new Physical_Scan_Entry_Array (1 .. Entry_Total);
         Allocation_Faults.Check (Scan_Cursor_Source_Allocation);
         Candidate.Sources := new Physical_Scan_Source_Array (1 .. Source_Total);
         declare
            Entry_Index     : Natural := 0;
            Source_Index    : Natural := 0;
            Prior_Authority : Natural := 0;
         begin
            for Index in Raw'Range loop
               if In_Range (Raw (Index)) and then Last_For_Key (Index) then
                  Entry_Index := Entry_Index + 1;
                  if Source_Index = 0 or else Raw (Index).Authority /= Prior_Authority then
                     if Source_Index > 0 then
                        Candidate.Sources (Source_Index).Last := Entry_Index - 1;
                     end if;
                     Source_Index := Source_Index + 1;
                     Candidate.Sources (Source_Index).First := Entry_Index;
                     Candidate.Sources (Source_Index).Position := Entry_Index;
                     Candidate.Sources (Source_Index).Candidate_Position := Entry_Index;
                     Candidate.Sources (Source_Index).Build_Position := Entry_Index;
                     Prior_Authority := Raw (Index).Authority;
                  end if;
                  Candidate.Entries (Entry_Index).Key_Length := Raw (Index).Key_Length;
                  Candidate.Entries (Entry_Index).Value_Length := Raw (Index).Selected_Value_Length;
                  Candidate.Entries (Entry_Index).Operation := Raw (Index).Operation;
                  if Raw (Index).Arena_Index = 0 then
                     Raw (Index).Key_Image.References.Retain;
                     Candidate.Entries (Entry_Index).Image.Image := Raw (Index).Key_Image;
                     Candidate.Entries (Entry_Index).Key_Offset := Raw (Index).Key_Offset;
                     Candidate.Entries (Entry_Index).Value_Offset := Raw (Index).Selected_Value_Offset;
                  else
                     declare
                        Mutation : Owned_Mutation renames Txn.Owner.Arena.Mutations (Raw (Index).Arena_Index);
                     begin
                        if Mutation.Key_Length > Natural'Last - Mutation.Value_Length then
                           Release_Raw;
                           Result := Capacity_Exceeded;
                           return;
                        end if;
                        Allocation_Faults.Check (Scan_Cursor_Owned_Bytes_Allocation);
                        Flyology.Bytes.Reserve_Capacity
                          (Candidate.Entries (Entry_Index).Owned,
                           Mutation.Key_Length + Mutation.Value_Length);
                        for Offset in Positive range 1 .. Mutation.Key_Length + Mutation.Value_Length loop
                           Flyology.Bytes.Append
                             (Candidate.Entries (Entry_Index).Owned,
                              Flyology.Bytes.Element (Mutation.Payload, Offset));
                        end loop;
                        Candidate.Entries (Entry_Index).Value_Offset := Mutation.Key_Length;
                     end;
                  end if;
               end if;
            end loop;
            Candidate.Sources (Source_Index).Last := Entry_Index;
         end;
         Release_Raw;
         Result := Success;
      exception
         when Storage_Error =>
            Release_Raw;
            Result := Capacity_Exceeded;
         when others =>
            Release_Raw;
            raise;
      end Build_Physical_Snapshot;
   begin
      if not Txn.Active or else Txn.Owner.Arena = null then
         Result := Invalid_State;
         return;
      end if;
      if State = null then
         Acquire (Item, Lease, Result);
         if Result /= Success then
            return;
         end if;
         State := Lease.State;
      end if;
      State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID or else Txn.Incarnation /= State.Gate.Current_Incarnation
      then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      State.Gate.Validate_Family (Family, Configuration, Result);
      if Result /= Success then
         return;
      elsif (Has_Lower and then Interfaces.Unsigned_64 (Lower'Length) > Configuration.Max_Key_Bytes)
        or else (Has_Upper and then Interfaces.Unsigned_64 (Upper'Length) > Configuration.Max_Key_Bytes)
      then
         Result := Capacity_Exceeded;
         return;
      elsif Has_Lower and then Has_Upper and then Compare_Bytes (Lower, Upper) /= Before then
         Result := Invalid_State;
         return;
      end if;

      Allocation_Faults.Check (Scan_Cursor_State_Allocation);
      Candidate := new Scan_Cursor_State;
      if Has_Lower then
         Allocation_Faults.Check (Scan_Cursor_Lower_Allocation);
         Candidate.Lower := new Byte_Array'(Lower);
      end if;
      if Has_Upper then
         Allocation_Faults.Check (Scan_Cursor_Upper_Allocation);
         Candidate.Upper := new Byte_Array'(Upper);
      end if;
      Candidate.Active := True;
      Candidate.Database_ID := Txn.Database_ID;
      Candidate.Incarnation := Txn.Incarnation;
      Candidate.Transaction_ID := Txn.Transaction_ID;
      Candidate.Snapshot_At := Txn.Snapshot_At;
      Candidate.Mutation_Version := Txn.Owner.Arena.Mutation_Version;
      Candidate.Family := Configuration;
      Candidate.Has_Lower := Has_Lower;
      Candidate.Has_Upper := Has_Upper;
      Build_Physical_Snapshot;
      if Result /= Success then
         Release_Scan_Cursor (Candidate);
         return;
      end if;
      declare
         Previous : constant Scan_Cursor_State_Access := Cursor.Owner.State;
      begin
         Cursor.Owner.State := Candidate;
         Candidate := Previous;
      end;
      Release_Scan_Cursor (Candidate);
      Result := Success;
   exception
      when Storage_Error =>
         Release_Scan_Cursor (Candidate);
         Result := Capacity_Exceeded;
      when others =>
         Release_Scan_Cursor (Candidate);
         raise;
   end Build_Scan_Cursor;

   procedure Start_Scan
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array;
      Cursor    : in out Scan_Cursor;
      Result    : out Outcome_Code) is
   begin
      Build_Scan_Cursor (Item, Txn, Family, Has_Lower, Lower, Has_Upper, Upper, null, null, Cursor, Result);
   end Start_Scan;

   procedure Materialize_Physical_Scan_Page
     (Item             : in out Database;
      Txn              : in out Transaction;
      State            : not null Scan_Cursor_State_Access;
      Maximum_Rows     : Interfaces.Unsigned_32;
      Maximum_Bytes    : Interfaces.Unsigned_64;
      Require_Complete : Boolean;
      Rows             : in out Scan_Result;
      Done             : out Boolean;
      Result           : out Outcome_Code);

   procedure Continue_Scan_Page
     (Item             : in out Database;
      Txn              : in out Transaction;
      Cursor           : in out Scan_Cursor;
      Maximum_Rows     : Interfaces.Unsigned_32;
      Maximum_Bytes    : Interfaces.Unsigned_64;
      Require_Complete : Boolean;
      Rows             : in out Scan_Result;
      Done             : out Boolean;
      Result           : out Outcome_Code);

   procedure Scan
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array;
      Rows      : in out Scan_Result;
      Result    : out Outcome_Code)
   is
      Cursor : Scan_Cursor;
      Done   : Boolean;
   begin
      Start_Scan
        (Item, Txn, Family, Has_Lower, Lower, Has_Upper, Upper, Cursor, Result);
      if Result /= Success then
         return;
      end if;
      declare
         State : constant Scan_Cursor_State_Access := Cursor.Owner.State;
      begin
         if State = null then
            Result := Corrupt;
            return;
         end if;
         Continue_Scan_Page
           (Item,
            Txn,
            Cursor,
            State.Maximum_Rows,
            State.Maximum_Bytes,
            Require_Complete => True,
            Rows             => Rows,
            Done             => Done,
            Result           => Result);
      end;
   end Scan;

   procedure Materialize_Physical_Scan_Page
     (Item             : in out Database;
      Txn              : in out Transaction;
      State            : not null Scan_Cursor_State_Access;
      Maximum_Rows     : Interfaces.Unsigned_32;
      Maximum_Bytes    : Interfaces.Unsigned_64;
      Require_Complete : Boolean;
      Rows             : in out Scan_Result;
      Done             : out Boolean;
      Result           : out Outcome_Code)
   is
      type Position_View is (Candidate_View, Build_View);

      Lease          : Lifecycle_Lease;
      Head           : Head_Snapshot;
      Generation     : Generation_Value;
      Uncertain      : Boolean;
      Fenced         : Boolean;
      Configuration  : Column_Family_Configuration;
      Family         : Column_Family;
      Selected_Count : Natural := 0;
      Selected_Bytes : Interfaces.Unsigned_64 := 0;
      More_Rows      : Boolean := False;
      Candidate      : Scan_Result_State_Access := null;
      Candidate_Last : Scan_Cursor_Byte_Array_Access := null;
      Row_Limit      : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32'Min (Maximum_Rows, State.Maximum_Rows);
      Byte_Limit     : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64'Min (Maximum_Bytes, State.Maximum_Bytes);

      function Position_Of (Source : Physical_Scan_Source; View : Position_View) return Natural
      is (if View = Candidate_View then Source.Candidate_Position else Source.Build_Position);

      function Key_Byte (Value : Physical_Scan_Entry; Offset : Natural) return Byte is
      begin
         if Value.Image.Image /= null then
            return Byte (Flyology.Bytes.Element (Value.Image.Image.Data, Value.Key_Offset + Offset + 1));
         else
            return Byte (Flyology.Bytes.Element (Value.Owned, Value.Key_Offset + Offset + 1));
         end if;
      end Key_Byte;

      function Value_Byte (Value : Physical_Scan_Entry; Offset : Natural) return Ada.Streams.Stream_Element is
      begin
         if Value.Image.Image /= null then
            return Flyology.Bytes.Element (Value.Image.Image.Data, Value.Value_Offset + Offset + 1);
         else
            return Flyology.Bytes.Element (Value.Owned, Value.Value_Offset + Offset + 1);
         end if;
      end Value_Byte;

      function Same_Key (Left, Right : Physical_Scan_Entry) return Boolean is
      begin
         if Left.Key_Length /= Right.Key_Length then
            return False;
         end if;
         if Left.Key_Length > 0 then
            for Offset in Natural range 0 .. Left.Key_Length - 1 loop
               if Key_Byte (Left, Offset) /= Key_Byte (Right, Offset) then
                  return False;
               end if;
            end loop;
         end if;
         return True;
      end Same_Key;

      function Key_Less (Left, Right : Physical_Scan_Entry) return Boolean is
         Common : constant Natural := Natural'Min (Left.Key_Length, Right.Key_Length);
      begin
         if Common > 0 then
            for Offset in Natural range 0 .. Common - 1 loop
               if Key_Byte (Left, Offset) < Key_Byte (Right, Offset) then
                  return True;
               elsif Key_Byte (Left, Offset) > Key_Byte (Right, Offset) then
                  return False;
               end if;
            end loop;
         end if;
         return Left.Key_Length < Right.Key_Length;
      end Key_Less;

      procedure Reset_Working_Positions is
      begin
         if State.Sources /= null then
            for Source of State.Sources.all loop
               Source.Candidate_Position := Source.Position;
               Source.Build_Position := Source.Position;
            end loop;
         end if;
      end Reset_Working_Positions;

      function Positions_Match return Boolean is
      begin
         if State.Sources /= null then
            for Source of State.Sources.all loop
               if Source.Build_Position /= Source.Candidate_Position then
                  return False;
               end if;
            end loop;
         end if;
         return True;
      end Positions_Match;

      function Lowest_Source (View : Position_View) return Natural is
         Lowest : Natural := 0;
      begin
         if State.Sources /= null then
            for Index in State.Sources'Range loop
               if Position_Of (State.Sources (Index), View) /= 0
                 and then (Lowest = 0
                           or else Key_Less
                                     (State.Entries (Position_Of (State.Sources (Index), View)),
                                      State.Entries (Position_Of (State.Sources (Lowest), View))))
               then
                  Lowest := Index;
               end if;
            end loop;
         end if;
         return Lowest;
      end Lowest_Source;

      function Winning_Source (Lowest : Positive; View : Position_View) return Positive is
         Winner : Positive := Lowest;
      begin
         for Index in State.Sources'Range loop
            if Position_Of (State.Sources (Index), View) /= 0
              and then Same_Key
                         (State.Entries (Position_Of (State.Sources (Lowest), View)),
                          State.Entries (Position_Of (State.Sources (Index), View)))
            then
               Winner := Index;
            end if;
         end loop;
         return Winner;
      end Winning_Source;

      procedure Advance_Matching (Lowest : Positive; View : Position_View) is
         Lowest_Entry : Physical_Scan_Entry renames
           State.Entries (Position_Of (State.Sources (Lowest), View));
      begin
         for Index in State.Sources'Range loop
            declare
               Position : constant Natural := Position_Of (State.Sources (Index), View);
            begin
               if Position /= 0 and then Same_Key (Lowest_Entry, State.Entries (Position)) then
                  if View = Candidate_View then
                     State.Sources (Index).Candidate_Position :=
                       (if Position = State.Sources (Index).Last then 0 else Position + 1);
                  else
                     State.Sources (Index).Build_Position :=
                       (if Position = State.Sources (Index).Last then 0 else Position + 1);
                  end if;
               end if;
            end;
         end loop;
      end Advance_Matching;

      procedure Release_Work is
      begin
         Reset_Working_Positions;
         Release_Scan_Result (Candidate);
         Free_Scan_Cursor_Bytes (Candidate_Last);
      end Release_Work;

      procedure Retain_Predicate is
         Empty_Key : constant Byte_Array (1 .. 0) := [];
      begin
         if Txn.Isolation /= Serializable or else State.Predicate_Recorded then
            Result := Success;
         elsif State.Has_Lower then
            if State.Has_Upper then
               Record_Scan_Range (Txn, State.Family.ID, True, State.Lower.all, True, State.Upper.all, Result);
            else
               Record_Scan_Range (Txn, State.Family.ID, True, State.Lower.all, False, Empty_Key, Result);
            end if;
         elsif State.Has_Upper then
            Record_Scan_Range (Txn, State.Family.ID, False, Empty_Key, True, State.Upper.all, Result);
         else
            Record_Scan_Range (Txn, State.Family.ID, False, Empty_Key, False, Empty_Key, Result);
         end if;
      end Retain_Predicate;
   begin
      Done := False;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID or else Txn.Incarnation /= Lease.State.Gate.Current_Incarnation
      then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      Family :=
        (Valid         => True,
         Database_ID   => State.Database_ID,
         Incarnation   => State.Incarnation,
         Configuration => State.Family);
      Lease.State.Gate.Validate_Family (Family, Configuration, Result);
      if Result /= Success or else Configuration /= State.Family then
         if Result = Success then
            Result := Invalid_State;
         end if;
         return;
      end if;
      Reset_Working_Positions;
      loop
         declare
            Lowest : constant Natural := Lowest_Source (Candidate_View);
         begin
            if Lowest = 0 then
               exit;
            end if;
            declare
               Winner : constant Positive := Winning_Source (Positive (Lowest), Candidate_View);
               Value  : Physical_Scan_Entry renames State.Entries (State.Sources (Winner).Candidate_Position);
               Amount : Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Value.Key_Length);
            begin
               if Value.Operation = Delete_Mutation then
                  Advance_Matching (Positive (Lowest), Candidate_View);
               else
                  if Interfaces.Unsigned_64 (Value.Value_Length) > Interfaces.Unsigned_64'Last - Amount then
                     Release_Work;
                     Result := Capacity_Exceeded;
                     return;
                  end if;
                  Amount := Amount + Interfaces.Unsigned_64 (Value.Value_Length);
                  if Interfaces.Unsigned_64 (Selected_Count) >= Interfaces.Unsigned_64 (Row_Limit)
                    or else Amount > Byte_Limit
                    or else Selected_Bytes > Byte_Limit - Amount
                  then
                     if Selected_Count = 0 then
                        Release_Work;
                        Result := Capacity_Exceeded;
                        return;
                     end if;
                     More_Rows := True;
                     exit;
                  end if;
                  Advance_Matching (Positive (Lowest), Candidate_View);
                  Selected_Count := Selected_Count + 1;
                  Selected_Bytes := Selected_Bytes + Amount;
               end if;
            end;
         end;
      end loop;
      if Selected_Count > 0 then
         if Selected_Bytes > Interfaces.Unsigned_64 (Natural'Last) then
            Release_Work;
            Result := Capacity_Exceeded;
            return;
         end if;
         Allocation_Faults.Check (Scan_Result_State_Allocation);
         Candidate := new Scan_Result_State;
         Allocation_Faults.Check (Scan_Result_Rows_Allocation);
         Candidate.Rows := new Scan_Row_Descriptor_Array (1 .. Selected_Count);
         Candidate.Count := Selected_Count;
         Allocation_Faults.Check (Scan_Result_Payload_Allocation);
         Flyology.Bytes.Reserve_Capacity (Candidate.Payload, Natural (Selected_Bytes));
         declare
            Row : Natural := 0;
         begin
            while not Positions_Match loop
               declare
                  Lowest : constant Positive := Positive (Lowest_Source (Build_View));
                  Winner : constant Positive := Winning_Source (Lowest, Build_View);
                  Value  : Physical_Scan_Entry renames State.Entries (State.Sources (Winner).Build_Position);
               begin
                  if Value.Operation = Put_Mutation then
                     Row := Row + 1;
                     Candidate.Rows (Row).Key_Offset := Flyology.Bytes.Length (Candidate.Payload);
                     Candidate.Rows (Row).Key_Length := Value.Key_Length;
                     for Offset in Positive range 1 .. Value.Key_Length loop
                        Flyology.Bytes.Append
                          (Candidate.Payload, Ada.Streams.Stream_Element (Key_Byte (Value, Offset - 1)));
                     end loop;
                     Candidate.Rows (Row).Value_Offset := Flyology.Bytes.Length (Candidate.Payload);
                     Candidate.Rows (Row).Value_Length := Value.Value_Length;
                     for Offset in Positive range 1 .. Value.Value_Length loop
                        Flyology.Bytes.Append (Candidate.Payload, Value_Byte (Value, Offset - 1));
                     end loop;
                  end if;
                  Advance_Matching (Lowest, Build_View);
               end;
            end loop;
            if Row /= Selected_Count then
               Release_Work;
               Result := Corrupt;
               return;
            end if;
         end;
         if not Require_Complete then
            declare
               Last_Row : Scan_Row_Descriptor renames Candidate.Rows (Candidate.Count);
            begin
               Allocation_Faults.Check (Scan_Cursor_Last_Key_Allocation);
               Candidate_Last := new Byte_Array (1 .. Last_Row.Key_Length);
               for Offset in Positive range 1 .. Last_Row.Key_Length loop
                  Candidate_Last (Offset) :=
                    Byte (Flyology.Bytes.Element (Candidate.Payload, Last_Row.Key_Offset + Offset));
               end loop;
            end;
         end if;
      end if;
      if Require_Complete and then More_Rows then
         Release_Work;
         Result := Capacity_Exceeded;
         return;
      end if;
      Retain_Predicate;
      if Result /= Success then
         Release_Work;
         return;
      end if;
      declare
         Previous : constant Scan_Result_State_Access := Rows.Owner.State;
      begin
         Rows.Owner.State := Candidate;
         Candidate := Previous;
      end;
      if State.Sources /= null then
         for Source of State.Sources.all loop
            Source.Position := Source.Candidate_Position;
            Source.Build_Position := Source.Position;
         end loop;
      end if;
      if Selected_Count > 0 and then not Require_Complete then
         declare
            Previous : constant Scan_Cursor_Byte_Array_Access := State.Last_Key;
         begin
            State.Last_Key := Candidate_Last;
            Candidate_Last := Previous;
         end;
         State.Has_Last := True;
      end if;
      if Txn.Isolation = Serializable then
         State.Predicate_Recorded := True;
      end if;
      State.Done := not More_Rows;
      Done := State.Done;
      Release_Scan_Result (Candidate);
      Free_Scan_Cursor_Bytes (Candidate_Last);
      Result := Success;
   exception
      when Storage_Error =>
         Release_Work;
         Result := Capacity_Exceeded;
      when others =>
         Release_Work;
         raise;
   end Materialize_Physical_Scan_Page;

   procedure Continue_Scan_Page
     (Item             : in out Database;
      Txn              : in out Transaction;
      Cursor           : in out Scan_Cursor;
      Maximum_Rows     : Interfaces.Unsigned_32;
      Maximum_Bytes    : Interfaces.Unsigned_64;
      Require_Complete : Boolean;
      Rows             : in out Scan_Result;
      Done             : out Boolean;
      Result           : out Outcome_Code)
   is
      State : constant Scan_Cursor_State_Access := Cursor.Owner.State;
   begin
      Done := False;
      if State = null
        or else not State.Active
        or else State.Done
        or else (State.Has_Lower and then State.Lower = null)
        or else (State.Has_Upper and then State.Upper = null)
        or else (State.Has_Last and then State.Last_Key = null)
        or else ((State.Entries = null) /= (State.Sources = null))
        or else not Txn.Active
        or else Txn.Owner.Arena = null
        or else Txn.Database_ID /= State.Database_ID
        or else Txn.Incarnation /= State.Incarnation
        or else Txn.Transaction_ID /= State.Transaction_ID
        or else Txn.Snapshot_At /= State.Snapshot_At
        or else Txn.Owner.Arena.Mutation_Version /= State.Mutation_Version
      then
         Result := Invalid_State;
         return;
      end if;
      Materialize_Physical_Scan_Page
        (Item,
         Txn,
         State,
         Maximum_Rows,
         Maximum_Bytes,
         Require_Complete => Require_Complete,
         Rows             => Rows,
         Done             => Done,
         Result           => Result);
   end Continue_Scan_Page;

   procedure Next_Scan_Page
     (Item          : in out Database;
      Txn           : in out Transaction;
      Cursor        : in out Scan_Cursor;
      Maximum_Rows  : Interfaces.Unsigned_32;
      Maximum_Bytes : Interfaces.Unsigned_64;
      Rows          : in out Scan_Result;
      Done          : out Boolean;
      Result        : out Outcome_Code)
   is
   begin
      Continue_Scan_Page
        (Item,
         Txn,
         Cursor,
         Maximum_Rows,
         Maximum_Bytes,
         Require_Complete => False,
         Rows             => Rows,
         Done             => Done,
         Result           => Result);
   end Next_Scan_Page;

   function Scan_Row_Count (Item : Scan_Result) return Natural
   is (if Item.Owner.State = null then 0 else Item.Owner.State.Count);

   procedure Read_Scan_Row
     (Item     : Scan_Result;
      Position : Positive;
      Item_Key : out Flyology.Bytes.Unbounded_Bytes;
      Data     : out Flyology.Bytes.Unbounded_Bytes;
      Result   : out Outcome_Code) is
   begin
      Flyology.Bytes.Clear (Item_Key);
      Flyology.Bytes.Clear (Data);
      if Item.Owner.State = null
        or else Position > Item.Owner.State.Count
        or else Item.Owner.State.Rows = null
      then
         Result := Invalid_State;
         return;
      end if;
      declare
         Row          : Scan_Row_Descriptor renames Item.Owner.State.Rows (Position);
         Payload_Size : constant Natural := Flyology.Bytes.Length (Item.Owner.State.Payload);
      begin
         if Row.Key_Offset > Payload_Size
           or else Row.Key_Length > Payload_Size - Row.Key_Offset
           or else Row.Value_Offset > Payload_Size
           or else Row.Value_Length > Payload_Size - Row.Value_Offset
         then
            Result := Invalid_State;
            return;
         end if;
         Flyology.Bytes.Reserve_Capacity (Item_Key, Row.Key_Length);
         for Offset in Positive range 1 .. Row.Key_Length loop
            Flyology.Bytes.Append
              (Item_Key, Flyology.Bytes.Element (Item.Owner.State.Payload, Row.Key_Offset + Offset));
         end loop;
         Flyology.Bytes.Reserve_Capacity (Data, Row.Value_Length);
         for Offset in Positive range 1 .. Row.Value_Length loop
            Flyology.Bytes.Append
              (Data, Flyology.Bytes.Element (Item.Owner.State.Payload, Row.Value_Offset + Offset));
         end loop;
      end;
      Result := Success;
   exception
      when Storage_Error =>
         Flyology.Bytes.Clear (Item_Key);
         Flyology.Bytes.Clear (Data);
         Result := Capacity_Exceeded;
   end Read_Scan_Row;

   procedure Put
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Byte_Array;
      Data     : Byte_Array;
      Result   : out Outcome_Code) is
   begin
      Store_Mutation (Item, Txn, Family, Item_Key, Data, Put_Mutation, Result);
   end Put;

   procedure Delete
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Byte_Array;
      Result   : out Outcome_Code) is
   begin
      Store_Mutation (Item, Txn, Family, Item_Key, [1 .. 0 => 0], Delete_Mutation, Result);
   end Delete;

   procedure Rollback (Txn : in out Transaction; Result : out Outcome_Code) is
   begin
      if not Txn.Active then
         Result := Invalid_State;
      else
         Reset_Transaction (Txn);
         Result := Success;
      end if;
   end Rollback;

   procedure Commit
     (Item    : in out Database;
      Txn     : in out Transaction;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Receipt : out Commit_Receipt;
      Result  : out Outcome_Code)
   is
      --  The operation's sole absolute monotonic deadline is derived from the
      --  caller-supplied Timeout; there is no hidden default or retry budget.
      Deadline       : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Lease          : Lifecycle_Lease;
      Admission      : Admission_Guard;
      Head           : Head_Snapshot;
      Generation     : Generation_Value;
      Uncertain      : Boolean;
      Fenced         : Boolean;
      Internal       : Internal_Receipt;
      Released_Arena : Transaction_Arena_Access;
   begin
      Receipt := (others => <>);
      if not Txn.Active or else Mutation_Count (Txn) = 0 then
         Result := Invalid_State;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID or else Txn.Incarnation /= Lease.State.Gate.Current_Incarnation
      then
         Result := Invalid_State;
         return;
      end if;
      Lease.State.Gate.Admit (Txn, Deadline, Token, Admission.Tokens (1), Result);
      if Result = Success then
         Admission.State := Lease.State;
         Admission.Count := 1;
         Admission.Active := True;
         Reset_Transaction (Txn);
         Lease.State.Gate.Await_Result (Admission.Tokens (1).Index)
           (Admission.Tokens (1).Generation, Internal, Released_Arena, Result);
         Release_Arena (Released_Arena);
         Adopt_Receipt (Receipt, Internal);
         Admission.Active := False;
      end if;
   end Commit;

   procedure Commit_Group
     (Item         : in out Database;
      Group_ID     : Identifier;
      Transactions : in out Transaction_Array;
      Timeout      : Duration;
      Token        : access Flyology.Cancellation.Token := null;
      Receipts     : out Commit_Receipt_Array;
      Result       : out Outcome_Code)
   is
      --  The operation's sole absolute monotonic deadline is derived from the
      --  caller-supplied Timeout; there is no hidden default or retry budget.
      Deadline       : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Lease          : Lifecycle_Lease;
      Admission      : Admission_Guard;
      Head           : Head_Snapshot;
      Generation     : Generation_Value;
      Uncertain      : Boolean;
      Fenced         : Boolean;
      Member_Result  : Outcome_Code := Invalid_State;
      Internal       : Internal_Receipt;
      Released_Arena : Transaction_Arena_Access;
   begin
      Receipts := [others => <>];
      if Transactions'Length /= Receipts'Length or else Transactions'Length < 2 then
         Result := Invalid_State;
         return;
      elsif Transactions'Length > Maximum_Group_Transactions then
         Result := Capacity_Exceeded;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      for Offset in Natural range 0 .. Transactions'Length - 1 loop
         if not Transactions (Transactions'First + Offset).Active
           or else Mutation_Count (Transactions (Transactions'First + Offset)) = 0
           or else Transactions (Transactions'First + Offset).Database_ID /= Head.Database_ID
           or else Transactions (Transactions'First + Offset).Incarnation
                   /= Lease.State.Gate.Current_Incarnation
         then
            Result := Invalid_State;
            return;
         end if;
      end loop;
      Lease.State.Gate.Admit_Group
        (Transactions, Group_ID, Deadline, Token, Admission.Tokens, Admission.Count, Result);
      if Result /= Success then
         return;
      end if;
      Admission.State := Lease.State;
      Admission.Active := True;
      for Offset in Natural range 0 .. Transactions'Length - 1 loop
         Reset_Transaction (Transactions (Transactions'First + Offset));
      end loop;
      for Index in Commit_Slot range 1 .. Admission.Count loop
         Lease.State.Gate.Await_Result (Admission.Tokens (Index).Index)
           (Admission.Tokens (Index).Generation, Internal, Released_Arena, Member_Result);
         Release_Arena (Released_Arena);
         Adopt_Receipt (Receipts (Receipts'First + Natural (Index) - 1), Internal);
         Admission.Next := Natural (Index) + 1;
         if Index = 1 then
            Result := Member_Result;
         elsif Member_Result /= Result then
            Result := Storage_Failure;
         end if;
      end loop;
   end Commit_Group;

   type Receipt_Resolution is (Receipt_Committed, Receipt_Rejected, Receipt_Unresolved);

   procedure Reconcile_Receipt
     (Storage       : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Receipt       : Commit_Receipt;
      Deadline      : Ada.Real_Time.Time;
      Token         : access Flyology.Cancellation.Token;
      Observed      : out Head_Snapshot;
      Generation    : out Generation_Value;
      Manifest      : out Manifests.Manifest;
      LSM_Authority : out Engine_LSM_Authority;
      Checkpoint    : out Checkpoint_Plan;
      History       : out Batch_History_Access;
      Count         : out Natural;
      Resolution    : out Receipt_Resolution;
      Result        : out Outcome_Code)
   is
      Exact : Boolean := False;
      Root  : Manifests.Manifest;
   begin
      Resolution := Receipt_Unresolved;
      Read_Recovery
        (Storage,
         Database_ID,
         Deadline,
         Token,
         Observed,
         Generation,
         Manifest,
         Root,
         LSM_Authority,
         Checkpoint,
         History,
         Count,
         Result);
      if Result /= Success then
         return;
      end if;
      for Index in Positive range 1 .. Count loop
         if History (Index).Batch_ID = Receipt.Batch_ID then
            Exact :=
              Receipt.Retained_Image.Image /= null
              and then History (Index).Image /= null
              and then Exact_Bytes (Receipt.Retained_Image.Image, History (Index).Image.Data);
            if Exact then
               Resolution := Receipt_Committed;
            else
               --  A mismatched immutable object cannot be installed.  No caller
               --  receives this history on the corrupt result.
               Release_History (History, Count);
               Release_Checkpoint_Plan (Checkpoint);
               Result := Corrupt;
            end if;
            return;
         end if;
      end loop;
      if Same_Head (Observed, Receipt.Attempted_Head) then
         --  The exact attempted HEAD must name the receipt's immutable batch.
         --  Its absence from the validated replay suffix is corruption, not a
         --  license to reactivate an engine with an empty recovered prefix.
         Release_History (History, Count);
         Release_Checkpoint_Plan (Checkpoint);
         Result := Corrupt;
         return;
      end if;
      if Observed.Transition_Number >= Receipt.Attempted_Head.Transition_Number then
         Resolution := Receipt_Rejected;
      end if;
      --  Only the committed return above transfers recovery-history ownership
      --  to Resolve.  Rejected and still-unresolved observations do not.
      if Resolution /= Receipt_Committed then
         Release_History (History, Count);
         Release_Checkpoint_Plan (Checkpoint);
      end if;
   end Reconcile_Receipt;

   procedure Resolve
     (Item    : in out Database;
      Receipt : in out Commit_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code)
   is
      --  The operation's sole absolute monotonic deadline is derived from the
      --  caller-supplied Timeout; there is no hidden default or retry budget.
      Deadline      : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Observed      : Head_Snapshot;
      Read_Result   : Outcome_Code;
      Storage       : access Storage_Context;
      Database_ID   : Database_Identifier;
      Current_Head  : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      State         : Engine_State_Access;
      New_State     : Engine_State_Access;
      History       : Batch_History_Access := null;
      History_Count : Natural;
      Manifest      : Manifests.Manifest;
      LSM_Authority : Engine_LSM_Authority;
      Checkpoint    : Checkpoint_Plan;
      Stamp         : Engine_Incarnation;
      Resolution    : Receipt_Resolution;
      Guard         : Resolve_Guard;
      pragma Unreferenced (Guard);
   begin
      if Receipt.Phase /= Head_Publication_Unknown then
         Result := Invalid_State;
         return;
      end if;
      Item.Life.Begin_Resolve (State, Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      State.Gate.Drain_Queued_For_Resolution;
      Item.Life.Await_Quiescent;
      State.Gate.Snapshot (Current_Head, Generation, Uncertain, Fenced);
      if Current_Head.Database_ID /= Receipt.Expected_Head.Database_ID then
         Result := Invalid_State;
         return;
      end if;
      Storage := State.Storage;
      Database_ID := Receipt.Expected_Head.Database_ID;
      Reconcile_Receipt
        (Storage.all,
         Database_ID,
         Receipt,
         Deadline,
         Token,
         Observed,
         Generation,
         Manifest,
         LSM_Authority,
         Checkpoint,
         History,
         History_Count,
         Resolution,
         Read_Result);
      if Read_Result /= Success then
         Result := Read_Result;
         return;
      elsif Resolution = Receipt_Committed then
         Incarnation_Source.Allocate (Stamp, Result);
         if Result /= Success then
            Release_History (History, History_Count);
            Release_Checkpoint_Plan (Checkpoint);
            return;
         end if;
         Allocate_Engine
           (Item.Life'Unchecked_Access,
            Storage,
            Observed,
            Generation,
            Manifest,
            LSM_Authority,
            Checkpoint,
            Stamp,
            History,
            History_Count,
            New_State,
            Result);
         if Result /= Success then
            return;
         end if;
         State.Gate.Request_Close;
         State.Gate.Join;
         Free_Worker (State.Worker);
         Release_State_Images (State);
         Free_State (State);
         Item.Life.Finish_Resolve (New_State, Observed.Highest);
         Guard.Active := False;
         Release_Retained_Image (Receipt);
         Receipt.Current_Outcome := Success;
         Receipt.Phase := Resolved;
         Result := Success;
      elsif Resolution = Receipt_Rejected then
         State.Gate.Fence;
         Item.Life.Cancel_Resolve;
         Guard.Active := False;
         Release_Retained_Image (Receipt);
         Receipt.Current_Outcome := Stale_Writer;
         Receipt.Phase := Resolved;
         Result := Stale_Writer;
      else
         Result := Outcome_Unknown;
      end if;
   end Resolve;

   function Head_Pair_Less (Left, Right : Head_Snapshot) return Boolean
   is (Left.Transition_Number < Right.Transition_Number
       or else
         (Left.Transition_Number = Right.Transition_Number and then Left.Epoch < Right.Epoch));

   procedure Stop_Replaced_Engine (State : in out Engine_State_Access);

   procedure Refresh_Replica
     (Item    : in out Database;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code)
   is
      --  One caller-selected monotonic deadline covers capture, complete
      --  recovery, allocation, and installation. The public one-shot call adds
      --  no polling cadence, retry budget, or refresh timeout default.
      Deadline           : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      State              : Engine_State_Access;
      New_State          : Engine_State_Access := null;
      Storage            : access Storage_Context;
      Current_Head       : Head_Snapshot;
      Observed_Head      : Head_Snapshot;
      Current_Generation : Generation_Value;
      Observed_Generation : Generation_Value;
      Uncertain          : Boolean;
      Fenced             : Boolean;
      Manifest           : Manifests.Manifest;
      Root               : Manifests.Manifest;
      LSM_Authority      : Engine_LSM_Authority;
      Checkpoint         : Checkpoint_Plan;
      History            : Batch_History_Access := null;
      History_Count      : Natural := 0;
      Stamp              : Engine_Incarnation;
      Guard              : Resolve_Guard;
      pragma Unreferenced (Guard);
   begin
      Item.Life.Begin_Resolve (State, Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      State.Gate.Drain_Queued_For_Resolution;
      Item.Life.Await_Quiescent;
      State.Gate.Snapshot (Current_Head, Current_Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         --  Refresh is read-only catch-up, never implicit writer promotion.
         Result := Stale_Writer;
         return;
      end if;
      Storage := State.Storage;
      Read_Recovery
        (Storage.all,
         Current_Head.Database_ID,
         Deadline,
         Token,
         Observed_Head,
         Observed_Generation,
         Manifest,
         Root,
         LSM_Authority,
         Checkpoint,
         History,
         History_Count,
         Result);
      if Result /= Success then
         return;
      elsif Observed_Head.Database_ID /= Current_Head.Database_ID then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Result := Corrupt;
         return;
      elsif Observed_Head.Transition_Number = Current_Head.Transition_Number
        and then Observed_Head.Epoch = Current_Head.Epoch
      then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         if Same_Head (Observed_Head, Current_Head) then
            Item.Life.Cancel_Resolve;
            Guard.Active := False;
            Result := Success;
         else
            Result := Corrupt;
         end if;
         return;
      elsif not Head_Pair_Less (Current_Head, Observed_Head) then
         --  A stale provider observation cannot roll the local high-water pair
         --  back. Its fully validated but older graph is simply discarded.
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Item.Life.Cancel_Resolve;
         Guard.Active := False;
         Result := Success;
         return;
      end if;

      Incarnation_Source.Allocate (Stamp, Result);
      if Result /= Success then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         return;
      end if;
      Allocate_Engine
        (Item.Life'Unchecked_Access,
         Storage,
         Observed_Head,
         Observed_Generation,
         Manifest,
         LSM_Authority,
         Checkpoint,
         Stamp,
         History,
         History_Count,
         New_State,
         Result);
      if Result /= Success then
         return;
      end if;
      Stop_Replaced_Engine (State);
      Item.Life.Finish_Resolve (New_State, Observed_Head.Highest);
      Guard.Active := False;
      Result := Success;
   end Refresh_Replica;

   function Refresh_Read_Failure
     (Failure : Client_Common.Failure_Reason) return Read_Outcome
   is
   begin
      return
        (case Failure is
           when Client_Common.Cancelled          => Read_Cancelled,
           when Client_Common.Timed_Out          => Read_Timed_Out,
           when Client_Common.Response_Too_Large => Read_Capacity_Exceeded,
           when others                           => Read_Failed);
   end Refresh_Read_Failure;

   function Refresh_Read_Rejection
     (Status : Flyology.HTTP.Status_Code) return Read_Outcome
   is
   begin
      --  S3 Get/Head binds missing objects to HTTP 404 and failed If-Match to
      --  HTTP 412. These wire statuses preserve the existing Storage_Port
      --  normalization and therefore recovery compatibility.
      return
        (if Status = 404
         then Object_Missing
         elsif Status = 412
         then Read_Precondition_Failed
         else Read_Failed);
   end Refresh_Read_Rejection;

   function Refresh_Request_Key
     (Item    : Refresh_Operation;
      Request : Recovery_Request) return String
   is
   begin
      case Request.Kind is
         when Recovery_Head_Request =>
            return Full_Key (Item.Storage.all, Head_Key_Suffix);
         when Recovery_Manifest_Header_Request | Recovery_Manifest_Body_Request =>
            return Manifest_Key (Item.Storage.all, Request.Object_ID);
         when Recovery_SST_Header_Request | Recovery_SST_Body_Request =>
            return Run_Key (Item.Storage.all, Request.Object_ID);
         when Recovery_Batch_Request =>
            return Batch_Key (Item.Storage.all, Request.Object_ID);
         when Recovery_No_Request =>
            raise Program_Error with "terminal refresh request has no object key";
      end case;
   end Refresh_Request_Key;

   procedure Copy_Refresh_Payload
     (Source : Flyology.Buffers.Unique_Buffer;
      Data   : out Flyology.Bytes.Unbounded_Bytes)
   is
      procedure Copy (Bytes : Ada.Streams.Stream_Element_Array) is
      begin
         Flyology.Bytes.Reserve_Capacity (Data, Bytes'Length);
         Flyology.Bytes.Append (Data, Bytes);
         Image_Accounting.Record_Sink_Bytes (Bytes'Length);
      end Copy;
   begin
      Flyology.Bytes.Clear (Data);
      Flyology.Buffers.With_Readable_Data (Source, Copy'Access);
   end Copy_Refresh_Payload;

   procedure Copy_Refresh_Head
     (Source : Flyology.Buffers.Unique_Buffer;
      Data   : out Small_Metadata_Buffer;
      Length : out Natural;
      Valid  : out Boolean)
   is
      procedure Copy (Bytes : Ada.Streams.Stream_Element_Array) is
      begin
         if Bytes'Length > Data'Length then
            return;
         end if;
         if Bytes'Length > 0 then
            for Offset in Natural range 0 .. Bytes'Length - 1 loop
               Data (Offset) :=
                 Byte (Bytes (Bytes'First + Ada.Streams.Stream_Element_Offset (Offset)));
            end loop;
         end if;
         Valid := True;
      end Copy;
   begin
      Data := [others => 0];
      Length := Flyology.Buffers.Length (Source);
      Valid := False;
      Flyology.Buffers.With_Readable_Data (Source, Copy'Access);
   end Copy_Refresh_Head;

   procedure Release_Refresh_Driver (Item : in out Refresh_Operation) is
   begin
      if Item.Driver_State /= null then
         if Item.Driver_State.Resolve_Admitted then
            Item.Driver_State.Resolve_Admitted := False;
            Item.Item.Life.Cancel_Resolve;
         end if;
         Release_Recovery (Item.Driver_State.Traversal);
         Free_Refresh_Driver_State (Item.Driver_State);
      end if;
   end Release_Refresh_Driver;

   procedure Complete_Composable_Refresh
     (Item   : in out Refresh_Operation;
      Result : Outcome_Code;
      Kind   : Flyology.Operations.Terminal_Outcome := Flyology.Operations.Succeeded)
   is
   begin
      if Item.Driver_State /= null then
         if Item.Driver_State.Resolve_Admitted then
            Item.Driver_State.Resolve_Admitted := False;
            Item.Item.Life.Cancel_Resolve;
         end if;
         Release_Recovery (Item.Driver_State.Traversal);
         Item.Driver_State.Phase := Refresh_Terminal;
      end if;
      Item.Final_Result := Result;
      Item.Has_Final_Result := True;
      Flyology.Operations.Drivers.Complete (Item, Kind);
   end Complete_Composable_Refresh;

   procedure Fail_Composable_Refresh
     (Item  : in out Refresh_Operation;
      Error : Ada.Exceptions.Exception_Occurrence)
   is
   begin
      if Ada.Exceptions.Exception_Identity (Error) = Storage_Error'Identity then
         --  Allocation during request preparation or response ownership is
         --  safe backpressure. It must not escape as an unclassified provider
         --  exception or install a partial recovery graph.
         Complete_Composable_Refresh (Item, Capacity_Exceeded);
         return;
      end if;
      Item.Has_Saved_Error := True;
      Ada.Exceptions.Save_Occurrence (Item.Saved_Error, Error);
      Complete_Composable_Refresh
        (Item, Storage_Failure, Flyology.Operations.Failed);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         end if;
   end Fail_Composable_Refresh;

   procedure Advance_Composable_Refresh (Item : in out Refresh_Operation);

   procedure Consume_Refresh_Header
     (Item        : in out Refresh_Operation;
      Data        : Flyology.Bytes.Unbounded_Bytes;
      Object_Size : Natural;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome)
   is
   begin
      case Item.Driver_State.Request.Kind is
         when Recovery_Manifest_Header_Request =>
            Consume_Recovery_Manifest_Header
              (Item.Driver_State.Traversal,
               Data,
               Object_Size,
               Generation,
               Read_Result);
         when Recovery_SST_Header_Request =>
            Consume_Recovery_SST_Header
              (Item.Driver_State.Traversal,
               Data,
               Object_Size,
               Generation,
               Read_Result);
         when others =>
            raise Program_Error with "non-header refresh request consumed as a header";
      end case;
      Advance_Composable_Refresh (Item);
   end Consume_Refresh_Header;

   procedure Consume_Refresh_Whole
     (Item        : in out Refresh_Operation;
      Data        : in out Flyology.Bytes.Unbounded_Bytes;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome)
   is
      Head_Data   : Small_Metadata_Buffer;
      Head_Length : Natural := 0;
      Head_Valid  : Boolean := False;
   begin
      case Item.Driver_State.Request.Kind is
         when Recovery_Head_Request =>
            if Read_Result = Object_Read then
               Copy_Refresh_Head (Item.Payload, Head_Data, Head_Length, Head_Valid);
            else
               Head_Data := [others => 0];
            end if;
            Consume_Recovery_Head
              (Item.Driver_State.Traversal,
               Head_Data,
               Head_Length,
               Generation,
               (if Read_Result = Object_Read and then not Head_Valid
                then Read_Capacity_Exceeded
                else Read_Result));

         when Recovery_Manifest_Body_Request =>
            Consume_Recovery_Manifest_Body
              (Item.Driver_State.Traversal,
               Data,
               Flyology.Bytes.Length (Data),
               Generation,
               Read_Result);

         when Recovery_SST_Body_Request =>
            Consume_Recovery_SST_Body
              (Item.Driver_State.Traversal,
               Data,
               Flyology.Bytes.Length (Data),
               Generation,
               Read_Result);

         when Recovery_Batch_Request =>
            Consume_Recovery_Batch
              (Item.Driver_State.Traversal, Data, Read_Result);

         when others =>
            raise Program_Error with "non-whole refresh request consumed as whole";
      end case;
      Advance_Composable_Refresh (Item);
   end Consume_Refresh_Whole;

   procedure Consume_Refresh_Whole_Failure
     (Item        : in out Refresh_Operation;
      Read_Result : Read_Outcome)
   is
      Data : Flyology.Bytes.Unbounded_Bytes;
   begin
      Consume_Refresh_Whole (Item, Data, (others => <>), Read_Result);
   end Consume_Refresh_Whole_Failure;

   procedure Complete_Refresh_Install (Item : in out Refresh_Operation) is
      State               : Refresh_Driver_State renames Item.Driver_State.all;
      Observed_Head       : Head_Snapshot;
      Observed_Generation : Generation_Value;
      Manifest            : Manifests.Manifest;
      Root                : Manifests.Manifest;
      LSM_Authority       : Engine_LSM_Authority;
      Checkpoint          : Checkpoint_Plan;
      History             : Batch_History_Access := null;
      History_Count       : Natural := 0;
      New_State           : Engine_State_Access := null;
      Installed           : Boolean := False;
      Stamp               : Engine_Incarnation;
      Result              : Outcome_Code;
   begin
      Finish_Recovery
        (State.Traversal,
         Observed_Head,
         Observed_Generation,
         Manifest,
         Root,
         LSM_Authority,
         Checkpoint,
         History,
         History_Count,
         Result);
      if Result /= Success then
         Complete_Composable_Refresh (Item, Result);
         return;
      elsif Observed_Head.Database_ID /= State.Current_Head.Database_ID then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Complete_Composable_Refresh (Item, Corrupt);
         return;
      elsif Observed_Head.Transition_Number = State.Current_Head.Transition_Number
        and then Observed_Head.Epoch = State.Current_Head.Epoch
      then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         if Same_Head (Observed_Head, State.Current_Head) then
            Complete_Composable_Refresh (Item, Success);
         else
            Complete_Composable_Refresh (Item, Corrupt);
         end if;
         return;
      elsif not Head_Pair_Less (State.Current_Head, Observed_Head) then
         --  A complete older provider snapshot is a successful no-op. It can
         --  never roll the installed high-water pair back.
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Complete_Composable_Refresh (Item, Success);
         return;
      end if;

      Incarnation_Source.Allocate (Stamp, Result);
      if Result /= Success then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Complete_Composable_Refresh (Item, Result);
         return;
      end if;
      Allocate_Engine
        --  Refresh_Operation's public Item discriminant must outlive terminal
        --  Finish or abandonment. A successfully installed engine remains
        --  owned by that same Database lifecycle after this operation ends.
        (Item.Item.Life'Unchecked_Access,
         Item.Storage,
         Observed_Head,
         Observed_Generation,
         Manifest,
         LSM_Authority,
         Checkpoint,
         Stamp,
         History,
         History_Count,
         New_State,
         Result);
      if Result /= Success then
         Complete_Composable_Refresh (Item, Result);
         return;
      end if;
      Stop_Replaced_Engine (State.Engine);
      Item.Item.Life.Finish_Resolve (New_State, Observed_Head.Highest);
      Installed := True;
      State.Resolve_Admitted := False;
      Complete_Composable_Refresh (Item, Success);
   exception
      when Storage_Error =>
         if New_State /= null and then not Installed then
            Stop_Replaced_Engine (New_State);
         end if;
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Complete_Composable_Refresh (Item, Capacity_Exceeded);
      when Error : others =>
         if New_State /= null and then not Installed then
            Stop_Replaced_Engine (New_State);
         end if;
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Fail_Composable_Refresh (Item, Error);
   end Complete_Refresh_Install;

   procedure Start_Refresh_Header_Range (Item : in out Refresh_Operation) is
      State : Refresh_Driver_State renames Item.Driver_State.all;
   begin
      if State.Request.Maximum = 0
        or else State.Request.Maximum > Flyology.Buffers.Buffer_Capacity (Item.Payload)
      then
         Consume_Refresh_Header
           (Item, Flyology.Bytes.Empty, 0, (others => <>), Read_Capacity_Exceeded);
         return;
      end if;
      Client_Objects.Get_Range
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Refresh_Request_Key (Item, State.Request),
         State.Request.Requested,
         Item.Payload'Unchecked_Access,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         Quoted_Generation (State.Request_Generation),
         Region                => UStrings.To_String (Item.Storage.Client_Region),
         Style                 => Item.Storage.Client_Style,
         Expected_Bucket_Owner => UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
         Request_Payer         => UStrings.To_String (Item.Storage.Client_Request_Payer),
         Checksum_Mode         => Item.Storage.Client_Checksum_Mode,
         Token                 => Item.Cancellation,
         Operation             => Item.Range_Child.all);
      State.Phase := Refresh_Reading_Header_Range;
      Flyology.Operations.Continue_After (Item, Item.Range_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Consume_Refresh_Header
           (Item, Flyology.Bytes.Empty, 0, (others => <>), Read_Capacity_Exceeded);
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Start_Refresh_Header_Range;

   procedure Complete_Refresh_Header_Head (Item : in out Refresh_Operation) is
      State      : Refresh_Driver_State renames Item.Driver_State.all;
      Outcome    : Client_Objects.Head_Result;
      Read_Result : Read_Outcome := Read_Failed;
      Valid      : Boolean := False;
   begin
      begin
         Client_Objects.Finish (Item.Head_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Head_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Head_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Head_Child.all)
            then
               Flyology.Operations.Release (Item.Head_Child.all);
            end if;
            Fail_Composable_Refresh (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Head_Child.all);
      if Outcome.Kind = Client_Objects.Head_Exchange_Failed then
         Read_Result := Refresh_Read_Failure (Outcome.Failure);
      elsif Outcome.Response.Kind = Client_Low_Level.Head_Object_Rejected then
         Read_Result := Refresh_Read_Rejection (Outcome.Response.Status);
      --  HeadObject's modeled success is HTTP 200. Any other complete shape
      --  is corrupt provider evidence and cannot authenticate a range read.
      elsif Outcome.Response.Status /= 200
        or else Outcome.Response.Result.Content_Length > OS.Byte_Count (Natural'Last)
      then
         Read_Result := Read_Corrupt;
      else
         Set_Quoted_Generation
           (State.Request_Generation,
            UStrings.To_String (Outcome.Response.Result.Entity_Tag),
            Valid);
         if Valid then
            State.Current_Object_Length := Natural (Outcome.Response.Result.Content_Length);
            Start_Refresh_Header_Range (Item);
            return;
         end if;
         Read_Result := Read_Corrupt;
      end if;
      Consume_Refresh_Header
        (Item, Flyology.Bytes.Empty, 0, (others => <>), Read_Result);
   exception
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Complete_Refresh_Header_Head;

   procedure Complete_Refresh_Header_Range (Item : in out Refresh_Operation) is
      State       : Refresh_Driver_State renames Item.Driver_State.all;
      Outcome     : Client_Objects.Range_Get_Result;
      Data        : Flyology.Bytes.Unbounded_Bytes;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome := Read_Failed;
      Valid       : Boolean := False;
   begin
      begin
         Client_Objects.Finish (Item.Range_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Range_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Range_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Range_Child.all)
            then
               Flyology.Operations.Release (Item.Range_Child.all);
            end if;
            Fail_Composable_Refresh (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Range_Child.all);
      if Outcome.Kind = Client_Objects.Range_Get_Exchange_Failed then
         Read_Result := Refresh_Read_Failure (Outcome.Failure);
      elsif Outcome.Response.Kind = Client_Low_Level.Get_Object_Rejected then
         Read_Result := Refresh_Read_Rejection (Outcome.Response.Status);
      else
         Set_Quoted_Generation
           (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
         --  A bounded S3 range response is HTTP 206 with an exact
         --  Content-Range. These wire checks bind the header bytes and total
         --  object length to the preceding HeadObject generation.
         if not Valid
           or else Generation /= State.Request_Generation
           or else Outcome.Response.Status /= 206
           or else not Outcome.Has_Resolved_Range
           or else Outcome.Resolved.First /= State.Request.Requested.First
           or else Outcome.Resolved.Last /= State.Request.Requested.Last
           or else Outcome.Resolved.Total_Length /= OS.Byte_Count (State.Current_Object_Length)
           or else Flyology.Buffers.Length (Item.Payload) /= State.Request.Maximum
         then
            Read_Result := Read_Corrupt;
         else
            begin
               Copy_Refresh_Payload (Item.Payload, Data);
               Read_Result := Object_Read;
            exception
               when Storage_Error =>
                  Read_Result := Read_Capacity_Exceeded;
            end;
         end if;
      end if;
      Consume_Refresh_Header
        (Item,
         Data,
         (if Read_Result = Object_Read then State.Current_Object_Length else 0),
         Generation,
         Read_Result);
   exception
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Complete_Refresh_Header_Range;

   procedure Complete_Refresh_Whole (Item : in out Refresh_Operation) is
      State       : Refresh_Driver_State renames Item.Driver_State.all;
      Outcome     : Client_Objects.Whole_Get_Result;
      Data        : Flyology.Bytes.Unbounded_Bytes;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome := Read_Failed;
      Valid       : Boolean := False;
   begin
      begin
         Client_Objects.Finish (Item.Read_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Read_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Read_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Read_Child.all)
            then
               Flyology.Operations.Release (Item.Read_Child.all);
            end if;
            Fail_Composable_Refresh (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Read_Child.all);
      if Outcome.Kind = Client_Objects.Whole_Get_Exchange_Failed then
         Read_Result := Refresh_Read_Failure (Outcome.Failure);
      elsif Outcome.Response.Kind = Client_Low_Level.Get_Object_Rejected then
         Read_Result := Refresh_Read_Rejection (Outcome.Response.Status);
      else
         Set_Quoted_Generation
           (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
         --  Whole GetObject success is HTTP 200. Exact Content-Length and the
         --  optional authenticated ETag are recovery framing authority, not a
         --  transport optimization.
         if not Valid
           or else Outcome.Response.Status /= 200
           or else not Outcome.Response.Result.Content_Length.Is_Set
           or else Outcome.Response.Result.Content_Length.Value > OS.Byte_Count (Natural'Last)
           or else Natural (Outcome.Response.Result.Content_Length.Value) > State.Request.Maximum
           or else Natural (Outcome.Response.Result.Content_Length.Value)
                     /= Flyology.Buffers.Length (Item.Payload)
           or else
             (State.Request.Expected_Generation.Length > 0
              and then Generation /= State.Request.Expected_Generation)
         then
            Read_Result :=
              (if Outcome.Response.Result.Content_Length.Is_Set
                 and then Outcome.Response.Result.Content_Length.Value <= OS.Byte_Count (Natural'Last)
                 and then Natural (Outcome.Response.Result.Content_Length.Value) > State.Request.Maximum
               then Read_Capacity_Exceeded
               else Read_Corrupt);
         else
            begin
               Copy_Refresh_Payload (Item.Payload, Data);
               Read_Result := Object_Read;
            exception
               when Storage_Error =>
                  Read_Result := Read_Capacity_Exceeded;
            end;
         end if;
      end if;
      Consume_Refresh_Whole (Item, Data, Generation, Read_Result);
   exception
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Complete_Refresh_Whole;

   procedure Start_Refresh_Whole (Item : in out Refresh_Operation) is
      State : Refresh_Driver_State renames Item.Driver_State.all;
   begin
      if State.Request.Maximum = 0
        or else State.Request.Maximum > Flyology.Buffers.Buffer_Capacity (Item.Payload)
      then
         Consume_Refresh_Whole_Failure (Item, Read_Capacity_Exceeded);
         return;
      end if;
      Client_Objects.Get_Whole
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Refresh_Request_Key (Item, State.Request),
         Item.Payload'Unchecked_Access,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         --  The controller's first HEAD-object read is intentionally
         --  unconditional. Later immutable body requests carry the exact
         --  generation authenticated by their preceding header range.
         Expected_Entity_Tag   =>
           (if State.Request.Expected_Generation.Length = 0
            then ""
            else Quoted_Generation (State.Request.Expected_Generation)),
         Region                => UStrings.To_String (Item.Storage.Client_Region),
         Style                 => Item.Storage.Client_Style,
         Expected_Bucket_Owner => UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
         Request_Payer         => UStrings.To_String (Item.Storage.Client_Request_Payer),
         Checksum_Mode         => Item.Storage.Client_Checksum_Mode,
         Token                 => Item.Cancellation,
         Operation             => Item.Read_Child.all);
      State.Phase := Refresh_Reading_Whole;
      Flyology.Operations.Continue_After (Item, Item.Read_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Consume_Refresh_Whole_Failure (Item, Read_Capacity_Exceeded);
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Start_Refresh_Whole;

   procedure Start_Refresh_Header_Head (Item : in out Refresh_Operation) is
      State      : Refresh_Driver_State renames Item.Driver_State.all;
      Parameters : Client_Low_Level.Head_Object_Parameters := (others => <>);
   begin
      if State.Request.Maximum = 0
        or else State.Request.Maximum > Flyology.Buffers.Buffer_Capacity (Item.Payload)
      then
         Consume_Refresh_Header
           (Item, Flyology.Bytes.Empty, 0, (others => <>), Read_Capacity_Exceeded);
         return;
      end if;
      State.Current_Object_Length := 0;
      State.Request_Generation := (others => <>);
      Parameters.Expected_Bucket_Owner := Item.Storage.Expected_Bucket_Owner;
      Parameters.Request_Payer := Item.Storage.Client_Request_Payer;
      Parameters.Checksum_Mode := Item.Storage.Client_Checksum_Mode;
      Client_Objects.Head_Object
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Refresh_Request_Key (Item, State.Request),
         Parameters,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         UStrings.To_String (Item.Storage.Client_Region),
         Item.Storage.Client_Style,
         Item.Cancellation,
         Item.Head_Child.all);
      State.Phase := Refresh_Reading_Header_Head;
      Flyology.Operations.Continue_After (Item, Item.Head_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Consume_Refresh_Header
           (Item, Flyology.Bytes.Empty, 0, (others => <>), Read_Capacity_Exceeded);
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Start_Refresh_Header_Head;

   procedure Advance_Composable_Refresh (Item : in out Refresh_Operation) is
      State : Refresh_Driver_State renames Item.Driver_State.all;
      Fault : Storage_Fault_Mode;
   begin
      Next_Recovery_Request (State.Traversal, State.Request);
      if State.Request.Kind = Recovery_No_Request then
         Complete_Refresh_Install (Item);
         return;
      elsif Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Refresh (Item, Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Refresh (Item, Timed_Out);
         return;
      end if;
      Consume_Fault
        (Item.Storage.all,
         (if State.Request.Kind
               in Recovery_Manifest_Header_Request | Recovery_Manifest_Body_Request
          then Before_Manifest_Get
          else Before_Get),
         Fault);
      if Fault /= No_Fault then
         if State.Request.Kind
           in Recovery_Manifest_Header_Request | Recovery_SST_Header_Request
         then
            Consume_Refresh_Header
              (Item, Flyology.Bytes.Empty, 0, (others => <>), Read_Failed);
         else
            Consume_Refresh_Whole_Failure (Item, Read_Failed);
         end if;
      elsif State.Request.Kind
        in Recovery_Manifest_Header_Request | Recovery_SST_Header_Request
      then
         Start_Refresh_Header_Head (Item);
      else
         Start_Refresh_Whole (Item);
      end if;
   exception
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Advance_Composable_Refresh;

   procedure Prepare_Composable_Refresh (Item : in out Refresh_Operation) is
      State     : Refresh_Driver_State renames Item.Driver_State.all;
      Uncertain : Boolean;
      Fenced    : Boolean;
   begin
      State.Engine.Gate.Snapshot
        (State.Current_Head, State.Current_Generation, Uncertain, Fenced);
      if Uncertain then
         Complete_Composable_Refresh (Item, Outcome_Unknown);
      elsif Fenced then
         Complete_Composable_Refresh (Item, Stale_Writer);
      else
         Start_Recovery
           (State.Traversal, State.Current_Head.Database_ID, Zero_Identifier);
         Advance_Composable_Refresh (Item);
      end if;
   exception
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Prepare_Composable_Refresh;

   procedure Await_Composable_Refresh_Quiescence
     (Item : in out Refresh_Operation)
   is
      Descriptor        : Interfaces.C.int;
      --  Flyology.IO fixes negative descriptors as invalid; this initializer
      --  is overwritten only when the optional cancellation source is live.
      Cancellation_FD   : Interfaces.C.int := -1;
      Ready_Now         : Boolean;
      Already_Cancelled : Boolean := False;
      --  Exactly two owner-stack sources can be live here: lifecycle
      --  quiescence and the optional cancellation token. The absolute
      --  deadline is armed in the same visible operation slot.
      Sources           : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 2);
      Count             : Natural := 0;
   begin
      if Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Refresh (Item, Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Refresh (Item, Timed_Out);
         return;
      end if;
      Item.Item.Life.Resolve_Wait_Source (Descriptor, Ready_Now);
      if Ready_Now then
         Prepare_Composable_Refresh (Item);
         return;
      end if;
      Count := Count + 1;
      Sources (Count) := (Descriptor => Descriptor, For_Write => False);
      if Item.Cancellation /= null then
         Item.Cancellation.Wait_Source (Cancellation_FD, Already_Cancelled);
         if Already_Cancelled then
            Complete_Composable_Refresh (Item, Cancelled);
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => Cancellation_FD, For_Write => False);
      end if;
      Flyology.Operations.Drivers.Arm_Readiness (Item, Sources (1 .. Count));
      Flyology.Operations.Drivers.Arm_Deadline (Item, Remaining_Time (Item.Deadline));
      Item.Driver_State.Phase := Refresh_Waiting_For_Quiescence;
   exception
      when Error : others =>
         Fail_Composable_Refresh (Item, Error);
   end Await_Composable_Refresh_Quiescence;

   overriding procedure Drive
     (Item : in out Refresh_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      if Event in Flyology.Operations.Start_Operation | Flyology.Operations.Source_Ready then
         Await_Composable_Refresh_Quiescence (Item);
      elsif Event = Flyology.Operations.Deadline_Reached
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Refresh_Waiting_For_Quiescence
      then
         Complete_Composable_Refresh (Item, Timed_Out);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Refresh_Reading_Header_Head
        and then Item.Head_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Head_Child.all)
      then
         Complete_Refresh_Header_Head (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Refresh_Reading_Header_Range
        and then Item.Range_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Range_Child.all)
      then
         Complete_Refresh_Header_Range (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Refresh_Reading_Whole
        and then Item.Read_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Read_Child.all)
      then
         Complete_Refresh_Whole (Item);
      else
         raise Program_Error with "invalid composable refresh driver event";
      end if;
   exception
      when Error : others =>
         if Flyology.Operations.Is_Active (Item) then
            Fail_Composable_Refresh (Item, Error);
         end if;
   end Drive;

   overriding procedure Request_Cancellation (Item : in out Refresh_Operation) is
   begin
      if Item.Head_Child /= null and then Flyology.Operations.Is_Active (Item.Head_Child.all) then
         Flyology.Operations.Cancel (Item.Head_Child.all);
      elsif Item.Head_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Head_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Refresh_Reading_Header_Head
      then
         Complete_Refresh_Header_Head (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Item.Range_Child /= null and then Flyology.Operations.Is_Active (Item.Range_Child.all) then
         Flyology.Operations.Cancel (Item.Range_Child.all);
      elsif Item.Range_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Range_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Refresh_Reading_Header_Range
      then
         Complete_Refresh_Header_Range (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Item.Read_Child /= null and then Flyology.Operations.Is_Active (Item.Read_Child.all) then
         Flyology.Operations.Cancel (Item.Read_Child.all);
      elsif Item.Read_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Read_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Refresh_Reading_Whole
      then
         Complete_Refresh_Whole (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Flyology.Operations.Is_Active (Item) then
         Complete_Composable_Refresh
           (Item, Cancelled, Flyology.Operations.Cancelled);
      end if;
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            begin
               Complete_Composable_Refresh
                 (Item, Storage_Failure, Flyology.Operations.Failed);
            exception
               when others =>
                  null;
            end;
         end if;
   end Request_Cancellation;

   procedure Refresh_Replica
     (Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Refresh_Operation)
   is
      Result  : Outcome_Code;
      Moved   : Boolean := False;
      Started : Boolean := False;
   begin
      if Operation.Storage.HTTP_Client /= Operation.HTTP
        or else Operation.Storage.Client_Identity = null
      then
         raise Program_Error with "refresh operation does not match client-bound storage";
      elsif Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "refresh payload belongs to a different pool";
      elsif Flyology.Buffers.Has_Buffer (Operation.Payload)
        or else Operation.Driver_State /= null
        or else Operation.Read_Child /= null
        or else Operation.Range_Child /= null
        or else Operation.Head_Child /= null
      then
         raise Program_Error with "refresh operation retains unconsumed ownership";
      end if;

      Operation.Deadline := Deadline_After (Timeout);
      Operation.HTTP_Deadline :=
        (if Operation.Deadline = Ada.Real_Time.Time_Last
         then Flyology.HTTP.Client.No_Deadline
         else Flyology.HTTP.Client.Deadline_After (Remaining_Time (Operation.Deadline)));
      Operation.Final_Result := Invalid_State;
      Operation.Has_Final_Result := False;
      Operation.Has_Saved_Error := False;
      begin
         --  One lazily allocated owner record carries the persisted-limit-
         --  derived traversal and partial graph. It introduces no DB ceiling.
         Operation.Driver_State := new Refresh_Driver_State;
      exception
         when Storage_Error =>
            null;
      end;
      if Operation.Driver_State /= null then
         begin
            --  These access values borrow only operation discriminant owners
            --  and its inline scratch handle. The public contract keeps them
            --  alive through terminal drain, and Finish/finalization frees
            --  every child before any such borrow may end.
            Operation.Read_Child :=
              new Client_Objects.Whole_Get_Operation
                (Operation.Set.all'Unchecked_Access,
                 Operation.HTTP.all'Unchecked_Access,
                 Operation.Payload'Unchecked_Access,
                 (if Operation.Cancellation = null
                  then null
                  else Operation.Cancellation.all'Unchecked_Access));
            Operation.Range_Child :=
              new Client_Objects.Range_Get_Operation
                (Operation.Set.all'Unchecked_Access,
                 Operation.HTTP.all'Unchecked_Access,
                 Operation.Payload'Unchecked_Access,
                 (if Operation.Cancellation = null
                  then null
                  else Operation.Cancellation.all'Unchecked_Access));
            Operation.Head_Child :=
              new Client_Objects.Head_Operation
                (Operation.Set.all'Unchecked_Access,
                 Operation.HTTP.all'Unchecked_Access,
                 (if Operation.Cancellation = null
                  then null
                  else Operation.Cancellation.all'Unchecked_Access));
         exception
            when Storage_Error =>
               Operation.Driver_State.Precheck_Result := Capacity_Exceeded;
         end;
      end if;

      Flyology.Operations.Drivers.Start (Operation);
      Started := True;
      if Operation.Driver_State /= null
        and then Operation.Driver_State.Precheck_Result = Success
      then
         Operation.Item.Life.Begin_Composable_Resolve
           (Operation.Driver_State.Engine, Result);
         if Result = Success
           and then Operation.Driver_State.Engine.Storage /= Operation.Storage
         then
            Operation.Item.Life.Cancel_Resolve;
            raise Program_Error with "refresh storage does not own the open database";
         elsif Result = Success then
            Operation.Driver_State.Resolve_Admitted := True;
            Operation.Driver_State.Engine.Gate.Drain_Queued_For_Resolution;
         else
            Operation.Driver_State.Precheck_Result := Result;
         end if;
      end if;
      Flyology.Buffers.Move (Payload_Buffer, Operation.Payload);
      Moved := True;
      if Operation.Driver_State = null then
         Operation.Final_Result := Capacity_Exceeded;
         Operation.Has_Final_Result := True;
         Flyology.Operations.Drivers.Complete
           (Operation, Flyology.Operations.Succeeded);
      elsif Operation.Driver_State.Precheck_Result /= Success then
         Complete_Composable_Refresh
           (Operation, Operation.Driver_State.Precheck_Result);
      else
         Flyology.Operations.Drive
           (Flyology.Operations.Operation'Class (Operation),
            Flyology.Operations.Start_Operation);
      end if;
   exception
      when others =>
         if Moved and then Flyology.Buffers.Has_Buffer (Operation.Payload) then
            Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
         end if;
         if Operation.Driver_State /= null
           and then Operation.Driver_State.Resolve_Admitted
         then
            Operation.Driver_State.Resolve_Admitted := False;
            Operation.Item.Life.Cancel_Resolve;
         end if;
         Release_Refresh_Driver (Operation);
         if Operation.Read_Child /= null then
            Free_Whole_Get_Operation (Operation.Read_Child);
         end if;
         if Operation.Range_Child /= null then
            Free_Range_Get_Operation (Operation.Range_Child);
         end if;
         if Operation.Head_Child /= null then
            Free_Head_Operation (Operation.Head_Child);
         end if;
         if Started and then Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Refresh_Replica;

   procedure Finish
     (Operation      : in out Refresh_Operation;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
   is
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "refresh Finish requires the original buffer pool";
      end if;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
      Release_Refresh_Driver (Operation);
      if Operation.Read_Child /= null then
         Free_Whole_Get_Operation (Operation.Read_Child);
      end if;
      if Operation.Range_Child /= null then
         Free_Range_Get_Operation (Operation.Range_Child);
      end if;
      if Operation.Head_Child /= null then
         Free_Head_Operation (Operation.Head_Child);
      end if;
      if Operation.Has_Saved_Error then
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity (Operation.Saved_Error),
            Ada.Exceptions.Exception_Message (Operation.Saved_Error));
      elsif not Operation.Has_Final_Result then
         raise Program_Error with "composable refresh has no terminal result";
      end if;
      Result := Operation.Final_Result;
   end Finish;

   overriding procedure Finalize (Item : in out Refresh_Operation) is
   begin
      begin
         Flyology.Operations.Finalize (Flyology.Operations.Operation (Item));
      exception
         when others =>
            null;
      end;
      Release_Refresh_Driver (Item);
      if Item.Read_Child /= null then
         Free_Whole_Get_Operation (Item.Read_Child);
      end if;
      if Item.Range_Child /= null then
         Free_Range_Get_Operation (Item.Range_Child);
      end if;
      if Item.Head_Child /= null then
         Free_Head_Operation (Item.Head_Child);
      end if;
      Flyology.Buffers.Release (Item.Payload);
   end Finalize;

   function Receipt_Outcome (Item : Commit_Receipt) return Outcome_Code
   is (Item.Current_Outcome);

   function Receipt_Transaction_ID (Item : Commit_Receipt) return Transaction_Identifier
   is (Item.Transaction_ID);

   function Receipt_Sequence (Item : Commit_Receipt) return Sequence_Number
   is (Item.Assigned_Sequence);

   function Receipt_Batch_ID (Item : Commit_Receipt) return Identifier
   is (Item.Batch_ID);

   procedure Activate_Flush_Plan
     (Item       : in out Database;
      Old_State  : in out Engine_State_Access;
      Plan       : in out Checkpoint_Plan;
      Generation : Generation_Value;
      Receipt    : in out Flush_Receipt;
      Guard      : in out Checkpoint_Guard;
      Result     : out Outcome_Code);

   procedure Initialize_Column_Family_Receipt
     (State          : not null Engine_State_Access;
      Configuration  : Column_Family_Configuration;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Plan           : Checkpoint_Plan;
      Receipt        : out Column_Family_Receipt;
      Result         : out Outcome_Code);

   procedure Release_Flush_State (Value : in out Flush_Driver_State_Access) is
   begin
      if Value /= null then
         for Image of Value.Run_Images loop
            Release_Image (Image.Owner);
         end loop;
         Release_Image (Value.Manifest_Image.Owner);
         Release_Image (Value.Head_Image.Owner);
         Release_Checkpoint_Plan (Value.Plan);
         Release_Checkpoint_Plan (Value.Selected_Source);
         Free_Flush_Driver_State (Value);
      end if;
   end Release_Flush_State;

   function Is_Family_Append (Item : Flush_Operation) return Boolean
   is (Item.Driver_State /= null and then Item.Driver_State.Mode = Family_Append_Plan);

   function Current_Attempted_Head (Item : Flush_Operation) return Head_Snapshot
   is (if Is_Family_Append (Item)
       then Item.Final_Family_Receipt.Attempted_Head
       else Item.Final_Receipt.Attempted_Head);

   function Current_Expected_Generation (Item : Flush_Operation) return Generation_Value
   is (if Is_Family_Append (Item)
       then Item.Final_Family_Receipt.Expected_Generation
       else Item.Final_Receipt.Expected_Generation);

   function Digest_Image (Image : not null Shared_Image_Access) return GNAT.SHA256.Message_Digest is
      Data : constant Ada.Streams.Stream_Element_Array := Flyology.Bytes.To_Array (Image.Data);
   begin
      return GNAT.SHA256.Digest (Data);
   end Digest_Image;

   procedure Adopt_Encoded_Image
     (Encoded : in out LSM_Runtime.Image_Access;
      Target  : in out Prepared_Flush_Image)
   is
   begin
      Target.Owner := New_Image (Encoded.all);
      LSM_Runtime.Release (Encoded);
      Target.Digest := Digest_Image (Target.Owner);
   exception
      when others =>
         LSM_Runtime.Release (Encoded);
         Release_Image (Target.Owner);
         raise;
   end Adopt_Encoded_Image;

   procedure Initialize_Flush_Receipt
     (State         : not null Engine_State_Access;
      Plan          : Checkpoint_Plan;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code;
      Replace_Current_Runs : Boolean := False;
      Merge_Older_Run_ID   : Identifier := Zero_Identifier;
      Merge_Middle_Run_ID  : Identifier := Zero_Identifier;
      Merge_Newer_Run_ID   : Identifier := Zero_Identifier)
   is
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Uncertain  : Boolean;
      Fenced     : Boolean;
   begin
      Receipt := (others => <>);
      State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain
        or else Fenced
        or else Generation /= Plan.Expected_Generation
        or else Runs'Length > Maximum_Initial_Column_Families
      then
         Result := (if Uncertain then Outcome_Unknown elsif Fenced then Stale_Writer else Invalid_State);
         return;
      end if;
      Receipt.Replaces_Current_Runs := Replace_Current_Runs;
      Receipt.Merges_Adjacent_Runs := not Is_Zero (Merge_Older_Run_ID);
      Receipt.Merges_Three_Runs := not Is_Zero (Merge_Middle_Run_ID);
      Receipt.Older_Run_ID := Merge_Older_Run_ID;
      Receipt.Middle_Run_ID := Merge_Middle_Run_ID;
      Receipt.Newer_Run_ID := Merge_Newer_Run_ID;
      Receipt.Run_Total := Runs'Length;
      for Offset in Natural range 0 .. Runs'Length - 1 loop
         Receipt.Runs (Offset + 1) := Runs (Runs'First + Offset);
      end loop;
      Receipt.Database_ID := Head.Database_ID;
      Receipt.Incarnation := State.Gate.Current_Incarnation;
      Receipt.Manifest_ID := Manifest_ID;
      Receipt.Replay_Boundary := Sequence_Number (Plan.Manifest.Replay_Boundary);
      Receipt.Expected_Generation := Generation;
      Receipt.Expected_Head := Head;
      Receipt.Attempted_Head :=
        (Database_ID            => Head.Database_ID,
         Version                => Head.Version,
         Epoch                  => Head.Epoch,
         Highest                => Head.Highest,
         Latest_Batch           => Head.Latest_Batch,
         Latest_Manifest        => Manifest_ID,
         Transition_ID          => Transition_ID,
         Predecessor_Transition => Head.Transition_ID,
         Transition_Number      => Head.Transition_Number + 1);
      Result := Success;
   end Initialize_Flush_Receipt;

   procedure Prepare_Flush_Images
     (Item   : in out Flush_Operation;
      State  : in out Flush_Driver_State;
      Result : out Outcome_Code)
   is
      Encoded       : LSM_Runtime.Image_Access := null;
      Encode_Result : LSM_Runtime.Encode_Status;
      Maximum       : Natural := 0;
   begin
      for Index in State.Plan.SSTs'Range loop
         if State.Plan.SSTs (Index) /= null then
            --  Newly published runs use frozen SST-v2 so point reads can
            --  authenticate the index and selected frame independently.
            --  Recovery retains SST-v1 decoding for existing databases.
            LSM_Runtime.Encode_SST_V2
              (State.Plan.SSTs (Index).all, Encoded, Encode_Result);
            if Encode_Result /= LSM_Runtime.Encoded then
               Result := Corrupt;
               return;
            end if;
            Adopt_Encoded_Image (Encoded, State.Run_Images (Index));
            Maximum := Natural'Max (Maximum, Flyology.Bytes.Length (State.Run_Images (Index).Owner.Data));
         end if;
      end loop;

      LSM_Runtime.Encode_Checkpoint_Manifest (State.Plan.Manifest.all, Encoded, Encode_Result);
      if Encode_Result /= LSM_Runtime.Encoded then
         Result := Corrupt;
         return;
      end if;
      Adopt_Encoded_Image (Encoded, State.Manifest_Image);
      Maximum := Natural'Max (Maximum, Flyology.Bytes.Length (State.Manifest_Image.Owner.Data));

      State.Head_Image.Owner := New_Image (Formats.Encode_Head (To_Head (Current_Attempted_Head (Item))));
      State.Head_Image.Digest := Digest_Image (State.Head_Image.Owner);
      Maximum := Natural'Max (Maximum, Flyology.Bytes.Length (State.Head_Image.Owner.Data));
      if Maximum = 0 or else Maximum > Flyology.Buffers.Buffer_Capacity (Item.Payload) then
         Result := Capacity_Exceeded;
      else
         Result := Success;
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Encoded);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Encoded);
         raise;
   end Prepare_Flush_Images;

   procedure Load_Payload
     (Item  : in out Flyology.Buffers.Unique_Buffer;
      Image : not null Shared_Image_Access)
   is
      Length : constant Natural := Flyology.Bytes.Length (Image.Data);

      procedure Copy
        (Data    : in out Ada.Streams.Stream_Element_Array;
         Written : in out Natural)
      is
      begin
         for Offset in Natural range 0 .. Length - 1 loop
            Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
              Flyology.Bytes.Element (Image.Data, Offset + 1);
         end loop;
         Written := Length;
      end Copy;
   begin
      Flyology.Buffers.With_Writable_Data (Item, Copy'Access);
   end Load_Payload;

   function Payload_Matches
     (Item  : Flyology.Buffers.Unique_Buffer;
      Image : not null Shared_Image_Access) return Boolean
   is
      Matches : Boolean := False;

      procedure Compare (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Matches := Data'Length = Flyology.Bytes.Length (Image.Data);
         if Matches and then Data'Length > 0 then
            for Offset in Natural range 0 .. Natural (Data'Length) - 1 loop
               if Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) /=
                 Flyology.Bytes.Element (Image.Data, Offset + 1)
               then
                  Matches := False;
                  exit;
               end if;
            end loop;
         end if;
      end Compare;
   begin
      Flyology.Buffers.With_Readable_Data (Item, Compare'Access);
      return Matches;
   end Payload_Matches;

   function Current_Flush_Image
     (State : Flush_Driver_State) return Shared_Image_Access
   is
   begin
      case State.Current_Kind is
         when Run_Object =>
            if State.Current_Family_Slot = 0 then
               return null;
            end if;
            return State.Run_Images (Manifests.Family_Slot (State.Current_Family_Slot)).Owner;
         when Manifest_Object =>
            return State.Manifest_Image.Owner;
         when Head_Object =>
            return State.Head_Image.Owner;
         when Batch_Object =>
            return null;
      end case;
   end Current_Flush_Image;

   function Current_Flush_Digest
     (State : Flush_Driver_State) return GNAT.SHA256.Message_Digest
   is
   begin
      case State.Current_Kind is
         when Run_Object =>
            return State.Run_Images (Manifests.Family_Slot (State.Current_Family_Slot)).Digest;
         when Manifest_Object =>
            return State.Manifest_Image.Digest;
         when Head_Object =>
            return State.Head_Image.Digest;
         when Batch_Object =>
            raise Program_Error with "batch selected by Flush driver";
      end case;
   end Current_Flush_Digest;

   function Current_Flush_Key (Item : Flush_Operation) return String is
      State : Flush_Driver_State renames Item.Driver_State.all;
   begin
      case State.Current_Kind is
         when Run_Object =>
            return Run_Key
              (Item.Storage.all,
               To_Identifier
                 (State.Plan.SSTs (Manifests.Family_Slot (State.Current_Family_Slot)).Run_ID));
         when Manifest_Object =>
            return Manifest_Key (Item.Storage.all, State.Manifest_ID);
         when Head_Object =>
            return Full_Key (Item.Storage.all, Head_Key_Suffix);
         when Batch_Object =>
            raise Program_Error with "batch selected by Flush driver";
      end case;
   end Current_Flush_Key;

   function Flush_Fault_Point
     (Kind : Stored_Object_Kind;
      After_Entry : Boolean) return Storage_Fault_Point
   is
   begin
      --  Test-injection authority mirrors Storage_Port exactly: each object
      --  kind has one pre-entry and one post-entry certainty boundary.
      return
        (case Kind is
           when Run_Object      => (if After_Entry then After_Run_Put else Before_Run_Put),
           when Manifest_Object => (if After_Entry then After_Manifest_Put else Before_Manifest_Put),
           when Head_Object     => (if After_Entry then After_Head_Put else Before_Head_Put),
           when Batch_Object    => (if After_Entry then After_Batch_Put else Before_Batch_Put));
   end Flush_Fault_Point;

   procedure Complete_Composable_Flush
     (Item    : in out Flush_Operation;
      Result  : Outcome_Code;
      Outcome : Flyology.Operations.Terminal_Outcome := Flyology.Operations.Succeeded)
   is
   begin
      if Item.Driver_State /= null then
         if Item.Driver_State.Checkpoint_Admitted then
            --  Every terminal path reaching this helper is a rollback of the
            --  lifecycle admission. Successful durable activation consumes
            --  the admission itself through Finish_Checkpoint (New_State).
            --  Cancel_Checkpoint intentionally remains valid while earlier DB
            --  calls are active, which makes quiescence-wait cancellation safe.
            Item.Driver_State.Checkpoint_Admitted := False;
            Item.Item.Life.Cancel_Checkpoint;
         end if;
         Item.Driver_State.Phase := Flush_Terminal;
      end if;
      Item.Final_Result := Result;
      if Is_Family_Append (Item) then
         Item.Final_Family_Receipt.Current_Outcome := Result;
         if Item.Final_Family_Receipt.Phase = No_Family_Publication
           and then Result /= Outcome_Unknown
         then
            Release_Retained_Manifest (Item.Final_Family_Receipt);
         end if;
      else
         Item.Final_Receipt.Current_Outcome := Result;
      end if;
      Item.Has_Final_Result := True;
      Release_Flush_State (Item.Driver_State);
      Flyology.Operations.Drivers.Complete (Item, Outcome);
   end Complete_Composable_Flush;

   procedure Fail_Composable_Flush
     (Item  : in out Flush_Operation;
      Error : Ada.Exceptions.Exception_Occurrence)
   is
      Result : Outcome_Code := Storage_Failure;
   begin
      if Is_Family_Append (Item)
        and then Item.Final_Family_Receipt.Phase in Family_Manifest_Unknown | Family_Head_Unknown
      then
         if Item.Driver_State.Engine /= null then
            Item.Driver_State.Engine.Gate.Fence;
         end if;
         Result := Outcome_Unknown;
      elsif Is_Family_Append (Item)
        and then Item.Final_Family_Receipt.Phase = Family_Head_Confirmed
      then
         if Item.Driver_State.Engine /= null then
            Item.Driver_State.Engine.Gate.Fence;
         end if;
         Result := Local_Activation_Failed;
      elsif Item.Final_Receipt.Phase in Objects_Unknown | Flush_Head_Unknown then
         if Item.Driver_State /= null and then Item.Driver_State.Engine /= null then
            Item.Driver_State.Engine.Gate.Fence;
         end if;
         Result := Outcome_Unknown;
      elsif Item.Final_Receipt.Phase = Flush_Head_Confirmed then
         if Item.Driver_State /= null and then Item.Driver_State.Engine /= null then
            Item.Driver_State.Engine.Gate.Fence;
         end if;
         Result := Local_Activation_Failed;
      else
         Ada.Exceptions.Save_Occurrence (Item.Saved_Error, Error);
         Item.Has_Saved_Error := True;
      end if;
      Complete_Composable_Flush
        (Item,
         Result,
         (if Item.Has_Saved_Error then Flyology.Operations.Failed else Flyology.Operations.Succeeded));
   end Fail_Composable_Flush;

   procedure Finish_Composable_Phase
     (Item   : in out Flush_Operation;
      Result : Outcome_Code)
   is
   begin
      if Is_Family_Append (Item)
        and then Item.Final_Family_Receipt.Phase in Family_Manifest_Unknown | Family_Head_Unknown
        and then Result /= Outcome_Unknown
      then
         Item.Final_Family_Receipt.Phase := Family_Resolved;
         Release_Retained_Manifest (Item.Final_Family_Receipt);
      elsif Item.Final_Receipt.Phase in Objects_Unknown | Flush_Head_Unknown
        and then Result /= Outcome_Unknown
      then
         Item.Final_Receipt.Phase := Flush_Resolved;
      end if;
      Complete_Composable_Flush (Item, Result);
   end Finish_Composable_Phase;

   procedure Start_Next_Immutable (Item : in out Flush_Operation);
   procedure Start_Head_Publication (Item : in out Flush_Operation);
   procedure Start_Immutable_Read (Item : in out Flush_Operation);

   procedure Start_Current_Put (Item : in out Flush_Operation) is
      State : Flush_Driver_State renames Item.Driver_State.all;
      Image : constant Shared_Image_Access := Current_Flush_Image (State);
      Fault : Storage_Fault_Mode;
   begin
      if Image = null then
         raise Program_Error with "Flush driver selected a vacant image";
      end if;
      --  From this certainty boundary onward, an injected post-entry loss or
      --  a completed child without a conclusive response must remain unknown.
      if Is_Family_Append (Item) then
         Item.Final_Family_Receipt.Phase :=
           (if State.Current_Kind = Head_Object then Family_Head_Unknown else Family_Manifest_Unknown);
         if State.Current_Kind = Head_Object then
            Item.Final_Family_Receipt.Head_Entered := True;
         end if;
      else
         Item.Final_Receipt.Phase :=
           (if State.Current_Kind = Head_Object then Flush_Head_Unknown else Objects_Unknown);
      end if;
      Consume_Fault
        (Item.Storage.all, Flush_Fault_Point (State.Current_Kind, After_Entry => False), Fault);
      if Fault = Definite_Failure then
         Finish_Composable_Phase (Item, Storage_Failure);
         return;
      elsif Fault = Unknown_After_Entry then
         State.Engine.Gate.Fence;
         Finish_Composable_Phase (Item, Outcome_Unknown);
         return;
      elsif Item.Cancellation /= null and then Item.Cancellation.Requested then
         Finish_Composable_Phase (Item, Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Finish_Composable_Phase (Item, Timed_Out);
         return;
      end if;

      Load_Payload (Item.Payload, Image);
      Item.Storage.Test_Control.Record_Put
        (Is_Head     => State.Current_Kind = Head_Object,
         Is_Manifest => State.Current_Kind = Manifest_Object,
         Is_Run      => State.Current_Kind = Run_Object);
      if State.Current_Kind = Head_Object then
         Client_Objects.Put_If_Matches
           (Item.HTTP,
            Item.Storage.Client_Origin,
            UStrings.To_String (Item.Storage.Bucket),
            Current_Flush_Key (Item),
            Quoted_Generation (Current_Expected_Generation (Item)),
            Item.Payload,
            String (Current_Flush_Digest (State)),
            Item.Storage.Client_Identity.all,
            Item.HTTP_Deadline,
            UStrings.To_String (Item.Storage.Client_Region),
            Item.Storage.Client_Style,
            UStrings.To_String (Item.Storage.Client_Content_Type),
            UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
            Item.Cancellation,
            Item.Put_Child);
      else
         Client_Objects.Put_If_Absent
           (Item.HTTP,
            Item.Storage.Client_Origin,
            UStrings.To_String (Item.Storage.Bucket),
            Current_Flush_Key (Item),
            Item.Payload,
            String (Current_Flush_Digest (State)),
            Item.Storage.Client_Identity.all,
            Item.HTTP_Deadline,
            UStrings.To_String (Item.Storage.Client_Region),
            Item.Storage.Client_Style,
            UStrings.To_String (Item.Storage.Client_Content_Type),
            UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
            Item.Cancellation,
            Item.Put_Child);
      end if;
      State.Phase := (if State.Current_Kind = Head_Object then Putting_Head else Putting_Immutable);
      Flyology.Operations.Continue_After (Item, Item.Put_Child);
   exception
      when Flyology.Operations.Capacity_Error =>
         if Flyology.Buffers.Has_Buffer (Item.Payload) then
            --  Conditional-PUT Start restores exact ownership on every
            --  initiating exception. Slot exhaustion is therefore definite
            --  caller-selected backpressure, not publication ambiguity.
            if Is_Family_Append (Item) then
               Item.Final_Family_Receipt.Phase := Family_Resolved;
               Release_Retained_Manifest (Item.Final_Family_Receipt);
            else
               Item.Final_Receipt.Phase := Flush_Resolved;
            end if;
            Complete_Composable_Flush (Item, Capacity_Exceeded);
         else
            raise Program_Error with "conditional PUT lost its token on capacity rejection";
         end if;
      when Error : others =>
         if Flyology.Buffers.Has_Buffer (Item.Payload) then
            --  The child did not admit a request. Preserve programming or
            --  provider exceptions for typed Finish after restoring ownership.
            if Is_Family_Append (Item) then
               Item.Final_Family_Receipt.Phase := Family_Resolved;
               Release_Retained_Manifest (Item.Final_Family_Receipt);
            else
               Item.Final_Receipt.Phase := Flush_Resolved;
            end if;
         end if;
         Fail_Composable_Flush (Item, Error);
   end Start_Current_Put;

   procedure Start_Next_Immutable (Item : in out Flush_Operation) is
      State : Flush_Driver_State renames Item.Driver_State.all;
   begin
      for Index in Natural range State.Current_Family_Slot + 1 .. Natural (Manifests.Family_Slot'Last) loop
         if State.Run_Images (Manifests.Family_Slot (Index)).Owner /= null then
            State.Current_Family_Slot := Index;
            State.Current_Kind := Run_Object;
            Start_Current_Put (Item);
            return;
         end if;
      end loop;
      State.Current_Family_Slot := 0;
      State.Current_Kind := Manifest_Object;
      Start_Current_Put (Item);
   end Start_Next_Immutable;

   procedure Start_Head_Publication (Item : in out Flush_Operation) is
   begin
      Item.Driver_State.Current_Kind := Head_Object;
      Start_Current_Put (Item);
   end Start_Head_Publication;

   procedure Start_Immutable_Read (Item : in out Flush_Operation) is
      State : Flush_Driver_State renames Item.Driver_State.all;
      Fault : Storage_Fault_Mode;
   begin
      Consume_Fault (Item.Storage.all, Before_Get, Fault);
      if Fault /= No_Fault
        or else (Item.Cancellation /= null and then Item.Cancellation.Requested)
        or else Item.Deadline <= Ada.Real_Time.Clock
      then
         State.Engine.Gate.Fence;
         Finish_Composable_Phase (Item, Outcome_Unknown);
         return;
      elsif Item.Read_Child = null then
         raise Program_Error with "Flush reconciliation child was not prepared";
      end if;
      Client_Objects.Get_Whole
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Current_Flush_Key (Item),
         Item.Payload'Unchecked_Access,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         Region                => UStrings.To_String (Item.Storage.Client_Region),
         Style                 => Item.Storage.Client_Style,
         Expected_Bucket_Owner => UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
         Request_Payer         => UStrings.To_String (Item.Storage.Client_Request_Payer),
         Checksum_Mode         => Item.Storage.Client_Checksum_Mode,
         Token                 => Item.Cancellation,
         Operation             => Item.Read_Child.all);
      State.Phase := Reading_Immutable;
      Flyology.Operations.Continue_After (Item, Item.Read_Child.all);
   exception
      when others =>
         State.Engine.Gate.Fence;
         Finish_Composable_Phase (Item, Outcome_Unknown);
   end Start_Immutable_Read;

   procedure Advance_After_Immutable (Item : in out Flush_Operation) is
   begin
      if Item.Driver_State.Current_Kind = Run_Object then
         Start_Next_Immutable (Item);
      elsif Item.Driver_State.Current_Kind = Manifest_Object then
         Start_Head_Publication (Item);
      else
         raise Program_Error with "non-immutable object advanced by Flush driver";
      end if;
   end Advance_After_Immutable;

   procedure Complete_Immutable_Read (Item : in out Flush_Operation) is
      Outcome : Client_Objects.Whole_Get_Result;
      Image   : constant Shared_Image_Access := Current_Flush_Image (Item.Driver_State.all);
      Exact   : Boolean := False;
   begin
      begin
         Client_Objects.Finish (Item.Read_Child.all, Outcome);
      exception
         when others =>
            if Flyology.Operations.Id (Item.Read_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Read_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Read_Child.all)
            then
               Flyology.Operations.Release (Item.Read_Child.all);
            end if;
            Item.Driver_State.Engine.Gate.Fence;
            Finish_Composable_Phase (Item, Outcome_Unknown);
            return;
      end;
      Flyology.Operations.Release (Item.Read_Child.all);
      if Outcome.Kind = Client_Objects.Whole_Get_Response_Available
        and then Outcome.Response.Kind = Client_Low_Level.Object_Opened
      then
         --  S3 GetObject whole-response compatibility: a successful complete
         --  body is status 200 and its modeled Content-Length must equal the
         --  exact restored buffer length before byte comparison is conclusive.
         Exact :=
           Outcome.Response.Status = 200
           and then Outcome.Response.Result.Content_Length.Is_Set
           and then Outcome.Response.Result.Content_Length.Value =
             OS.Byte_Count (Flyology.Buffers.Length (Item.Payload))
           and then Payload_Matches (Item.Payload, Image);
         if Exact then
            Advance_After_Immutable (Item);
         elsif Outcome.Response.Status = 200
           and then Outcome.Response.Result.Content_Length.Is_Set
           and then Outcome.Response.Result.Content_Length.Value =
             OS.Byte_Count (Flyology.Buffers.Length (Item.Payload))
         then
            Finish_Composable_Phase (Item, Conflict);
         else
            Item.Driver_State.Engine.Gate.Fence;
            Finish_Composable_Phase (Item, Outcome_Unknown);
         end if;
      else
         Item.Driver_State.Engine.Gate.Fence;
         Finish_Composable_Phase (Item, Outcome_Unknown);
      end if;
   end Complete_Immutable_Read;

   procedure Activate_Composable_Family
     (Item       : in out Flush_Operation;
      Generation : Generation_Value;
      Result     : out Outcome_Code)
   is
      Guard : Checkpoint_Guard;
      Core  : Flush_Receipt :=
        (Current_Outcome     => Success,
         Phase               => Flush_Head_Unknown,
         Database_ID         => Item.Final_Family_Receipt.Database_ID,
         Incarnation         => Item.Final_Family_Receipt.Incarnation,
         Manifest_ID         => Item.Final_Family_Receipt.Manifest_ID,
         Replay_Boundary     => Sequence_Number (Item.Driver_State.Plan.Manifest.Replay_Boundary),
         Expected_Generation => Item.Final_Family_Receipt.Expected_Generation,
         Expected_Head       => Item.Final_Family_Receipt.Expected_Head,
         Attempted_Head      => Item.Final_Family_Receipt.Attempted_Head,
         others              => <>);
   begin
      Item.Final_Family_Receipt.Phase := Family_Head_Confirmed;
      Guard.Life := Item.Item.Life'Unchecked_Access;
      Guard.Active := True;
      Activate_Flush_Plan
        (Item.Item.all,
         Item.Driver_State.Engine,
         Item.Driver_State.Plan,
         Generation,
         Core,
         Guard,
         Result);
      Item.Driver_State.Checkpoint_Admitted := Guard.Active;
      if Guard.Active then
         Item.Final_Family_Receipt.Current_Outcome := Local_Activation_Failed;
         Result := Local_Activation_Failed;
      else
         Item.Driver_State.Engine := null;
         Item.Final_Family_Receipt.Phase := Family_Resolved;
         Item.Final_Family_Receipt.Current_Outcome := Success;
         Release_Retained_Manifest (Item.Final_Family_Receipt);
      end if;
   end Activate_Composable_Family;

   procedure Complete_Head_Put
     (Item    : in out Flush_Operation;
      Outcome : Client_Objects.Conditional_Put_Result)
   is
      Generation : Generation_Value;
      Valid      : Boolean := False;
      Result     : Outcome_Code;
      Guard      : Checkpoint_Guard;
   begin
      case Outcome.Disposition is
         when Client_Common.Published =>
            if Outcome.Kind = Client_Objects.Put_Response_Available
              and then Outcome.Response.Kind = Client_Low_Level.Object_Put
            then
               Set_Quoted_Generation
                 (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
            end if;
            if not Valid then
               Item.Driver_State.Engine.Gate.Fence;
               Finish_Composable_Phase (Item, Outcome_Unknown);
               return;
            end if;
            if Is_Family_Append (Item) then
               Activate_Composable_Family (Item, Generation, Result);
            else
               Guard.Life := Item.Item.Life'Unchecked_Access;
               Guard.Active := True;
               Activate_Flush_Plan
                 (Item.Item.all,
                  Item.Driver_State.Engine,
                  Item.Driver_State.Plan,
                  Generation,
                  Item.Final_Receipt,
                  Guard,
                  Result);
               Item.Driver_State.Checkpoint_Admitted := Guard.Active;
               if not Guard.Active then
                  Item.Driver_State.Engine := null;
               end if;
            end if;
            Complete_Composable_Flush (Item, Result);

         when Client_Common.Precondition_Failed =>
            Item.Driver_State.Engine.Gate.Fence;
            if Is_Family_Append (Item) then
               Item.Final_Family_Receipt.Phase := Family_Resolved;
               Release_Retained_Manifest (Item.Final_Family_Receipt);
            else
               Item.Final_Receipt.Phase := Flush_Resolved;
            end if;
            Complete_Composable_Flush (Item, Stale_Writer);

         when Client_Common.Cancelled_Before_Publication =>
            Finish_Composable_Phase (Item, Cancelled);

         when Client_Common.Definitely_Not_Published =>
            Finish_Composable_Phase
              (Item,
               (if Outcome.Failure = Client_Common.Cancelled
                then Cancelled
                elsif Outcome.Failure = Client_Common.Timed_Out
                then Timed_Out
                else Storage_Failure));

         when Client_Common.Outcome_Unknown =>
            Item.Driver_State.Engine.Gate.Fence;
            Complete_Composable_Flush (Item, Outcome_Unknown);
      end case;
   end Complete_Head_Put;

   procedure Complete_Immutable_Put
     (Item    : in out Flush_Operation;
      Outcome : Client_Objects.Conditional_Put_Result)
   is
   begin
      case Outcome.Disposition is
         when Client_Common.Published =>
            if Outcome.Kind = Client_Objects.Put_Response_Available
              and then Outcome.Response.Kind = Client_Low_Level.Object_Put
            then
               Advance_After_Immutable (Item);
            else
               Start_Immutable_Read (Item);
            end if;

         when Client_Common.Precondition_Failed | Client_Common.Outcome_Unknown =>
            Start_Immutable_Read (Item);

         when Client_Common.Cancelled_Before_Publication =>
            Finish_Composable_Phase (Item, Cancelled);

         when Client_Common.Definitely_Not_Published =>
            Finish_Composable_Phase
              (Item,
               (if Outcome.Failure = Client_Common.Cancelled
                then Cancelled
                elsif Outcome.Failure = Client_Common.Timed_Out
                then Timed_Out
                else Storage_Failure));
      end case;
   end Complete_Immutable_Put;

   procedure Complete_Current_Put (Item : in out Flush_Operation) is
      Outcome : Client_Objects.Conditional_Put_Result;
      Fault   : Storage_Fault_Mode;
   begin
      begin
         Client_Objects.Finish (Item.Put_Child, Outcome, Item.Payload);
      exception
         when others =>
            if Flyology.Operations.Id (Item.Put_Child) /= 0
              and then not Flyology.Operations.Is_Active (Item.Put_Child)
              and then not Flyology.Operations.Is_Terminal (Item.Put_Child)
            then
               Flyology.Operations.Release (Item.Put_Child);
            end if;
            Item.Driver_State.Engine.Gate.Fence;
            Finish_Composable_Phase (Item, Outcome_Unknown);
            return;
      end;
      Flyology.Operations.Release (Item.Put_Child);
      Consume_Fault
        (Item.Storage.all,
         Flush_Fault_Point (Item.Driver_State.Current_Kind, After_Entry => True),
         Fault);
      if Fault /= No_Fault then
         if Item.Driver_State.Current_Kind = Head_Object then
            Item.Driver_State.Engine.Gate.Fence;
            Complete_Composable_Flush (Item, Outcome_Unknown);
         else
            Start_Immutable_Read (Item);
         end if;
      elsif Item.Driver_State.Current_Kind = Head_Object then
         Complete_Head_Put (Item, Outcome);
      else
         Complete_Immutable_Put (Item, Outcome);
      end if;
   end Complete_Current_Put;

   function Selected_Read_Failure
     (Failure : Client_Common.Failure_Reason) return Outcome_Code
   is
   begin
      return
        (case Failure is
           when Client_Common.Cancelled          => Cancelled,
           when Client_Common.Timed_Out          => Timed_Out,
           when Client_Common.Response_Too_Large => Capacity_Exceeded,
           when others                           => Storage_Failure);
   end Selected_Read_Failure;

   function Selected_Rejection
     (Status : Flyology.HTTP.Status_Code) return Outcome_Code
   is
     --  S3 GetObject/HeadObject fixes 404 as missing immutable authority and
     --  412 as exact-generation mismatch. Both invalidate a manifest-named
     --  SST; other complete rejections remain provider/storage failures.
     (if Status in 404 | 412 then Corrupt else Storage_Failure);

   --  Selected merge recovery uses the same longest compatible v1/v2 prefix
   --  as cacheless recovery; this is format discrimination, not read tuning.
   Selected_SST_Header_Length : constant Positive := Compatible_SST_Header_Length;

   procedure Copy_Selected_Payload
     (Item     : Flyology.Buffers.Unique_Buffer;
      Expected : Positive;
      Image    : out LSM_Runtime.Image_Access)
   is
      procedure Copy (Data : Ada.Streams.Stream_Element_Array) is
      begin
         if Data'Length /= Expected then
            raise Program_Error with "selected-run payload length changed before decode";
         end if;
         for Offset in Natural range 0 .. Expected - 1 loop
            Image (Offset) := Byte (Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)));
         end loop;
      end Copy;
   begin
      Image := null;
      Allocation_Faults.Check (Recovery_SST_Image_Allocation);
      Image := new Formats.Byte_Array'(0 .. Expected - 1 => 0);
      Flyology.Buffers.With_Readable_Data (Item, Copy'Access);
   exception
      when others =>
         LSM_Runtime.Release (Image);
         raise;
   end Copy_Selected_Payload;

   function Lazy_Read_Outcome (Read_Result : Read_Outcome) return Outcome_Code is
   begin
      return
        (case Read_Result is
           when Read_Cancelled          => Cancelled,
           when Read_Timed_Out          => Timed_Out,
           when Read_Capacity_Exceeded  => Capacity_Exceeded,
           when Object_Missing
              | Read_Precondition_Failed
              | Read_Corrupt            => Corrupt,
           when others                  => Storage_Failure);
   end Lazy_Read_Outcome;

   function Lazy_Decode_Outcome
     (Status : LSM_Runtime.Decode_Status) return Outcome_Code
   is
   begin
      return
        (if Status = LSM_Runtime.Decoded
         then Success
         elsif Status
               in LSM_Runtime.Limit_Exceeded
                | LSM_Runtime.Allocation_Failed
                | LSM_Runtime.Runtime_Incompatible
         then Capacity_Exceeded
         elsif Status = LSM_Runtime.Unsupported_Version
         then Unsupported_Format
         else Corrupt);
   end Lazy_Decode_Outcome;

   procedure Release_Lazy_SST_Read_State
     (Item : in out Lazy_SST_Read_Operation)
   is
   begin
      if Item.Driver_State /= null then
         LSM_Runtime.Release (Item.Driver_State.Index);
         Free_Lazy_SST_Read_State (Item.Driver_State);
      end if;
   end Release_Lazy_SST_Read_State;

   procedure Release_Lazy_SST_Table (Holder : in out Lazy_SST_Table_Holder_Access) is
   begin
      if Holder /= null then
         LSM_Runtime.Release (Holder.Table);
         Free_Lazy_SST_Table_Holder (Holder);
      end if;
   end Release_Lazy_SST_Table;

   procedure Complete_Lazy_SST_Read
     (Item        : in out Lazy_SST_Read_Operation;
      Result      : Outcome_Code;
      Disposition : Lazy_SST_Entry_Disposition := Lazy_Read_Failed;
      Sequence    : Sequence_Number := 0;
      Kind        : Flyology.Operations.Terminal_Outcome := Flyology.Operations.Succeeded)
   is
   begin
      if Item.Driver_State /= null then
         LSM_Runtime.Release (Item.Driver_State.Index);
         Item.Driver_State.Phase := Lazy_Read_Terminal;
      end if;
      Item.Final_Result := Result;
      Item.Final_Disposition := Disposition;
      Item.Final_Sequence := Sequence;
      Item.Has_Final_Result := True;
      Flyology.Operations.Drivers.Complete (Item, Kind);
   end Complete_Lazy_SST_Read;

   procedure Fail_Lazy_SST_Read
     (Item  : in out Lazy_SST_Read_Operation;
      Error : Ada.Exceptions.Exception_Occurrence)
   is
   begin
      if Ada.Exceptions.Exception_Identity (Error) = Storage_Error'Identity then
         Complete_Lazy_SST_Read (Item, Capacity_Exceeded);
         return;
      end if;
      Item.Has_Saved_Error := True;
      Ada.Exceptions.Save_Occurrence (Item.Saved_Error, Error);
      Complete_Lazy_SST_Read
        (Item, Storage_Failure, Kind => Flyology.Operations.Failed);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Failed);
         end if;
   end Fail_Lazy_SST_Read;

   function Lazy_Index_Key_Matches
     (Index    : LSM_Runtime.SST_V2_Index;
      Position : Positive;
      Key      : Flyology.Bytes.Unbounded_Bytes) return Boolean
   is
      Index_Item : LSM_Runtime.SST_V2_Index_Entry renames Index.Entries (Position);
   begin
      if Index_Item.Key_Byte_Total /= Flyology.Bytes.Length (Key) then
         return False;
      elsif Index_Item.Key_Byte_Total = 0 then
         return True;
      end if;
      for Offset in Natural range 0 .. Index_Item.Key_Byte_Total - 1 loop
         if Index.Keys (Index_Item.Key_Offset + Offset)
           /= Byte (Flyology.Bytes.Element (Key, Offset + 1))
         then
            return False;
         end if;
      end loop;
      return True;
   end Lazy_Index_Key_Matches;

   function Lazy_SST_Key_Matches
     (Table    : LSM_Runtime.SST;
      Position : Positive;
      Key      : Flyology.Bytes.Unbounded_Bytes) return Boolean
   is
      Item_Entry : LSM_Runtime.SST_Entry renames Table.Entries (Position);
   begin
      if Item_Entry.Key_Byte_Total /= Flyology.Bytes.Length (Key) then
         return False;
      elsif Item_Entry.Key_Byte_Total = 0 then
         return True;
      end if;
      for Offset in Natural range 0 .. Item_Entry.Key_Byte_Total - 1 loop
         if Table.Payload (Item_Entry.Key_Offset + Offset)
           /= Byte (Flyology.Bytes.Element (Key, Offset + 1))
         then
            return False;
         end if;
      end loop;
      return True;
   end Lazy_SST_Key_Matches;

   procedure Select_Lazy_Whole_SST_Entry
     (Item  : in out Lazy_SST_Read_Operation;
      Table : in out LSM_Runtime.SST_Access)
   is
      State    : Lazy_SST_Read_State renames Item.Driver_State.all;
      Selected : Natural := 0;
   begin
      for Position in Table.Entries'Range loop
         if Lazy_SST_Key_Matches (Table.all, Position, State.Item_Key)
           and then Table.Entries (Position).Sequence
                      <= Interfaces.Unsigned_64 (State.Snapshot_At)
         then
            Selected := Position;
            exit;
         end if;
      end loop;
      if Selected = 0 then
         LSM_Runtime.Release (Table);
         Complete_Lazy_SST_Read (Item, Not_Found, Lazy_Key_Absent);
      elsif Table.Entries (Selected).Operation = LSM_Runtime.LSM.Delete_Operation then
         declare
            Sequence : constant Sequence_Number :=
              Sequence_Number (Table.Entries (Selected).Sequence);
         begin
            LSM_Runtime.Release (Table);
            Complete_Lazy_SST_Read
              (Item, Not_Found, Lazy_Tombstone_Found, Sequence);
         end;
      else
         declare
            Item_Entry : LSM_Runtime.SST_Entry renames Table.Entries (Selected);
            Sequence : constant Sequence_Number := Sequence_Number (Item_Entry.Sequence);
         begin
            Flyology.Bytes.Clear (Item.Final_Value);
            Flyology.Bytes.Reserve_Capacity
              (Item.Final_Value, Item_Entry.Value_Byte_Total);
            for Offset in Natural range 1 .. Item_Entry.Value_Byte_Total loop
               Flyology.Bytes.Append
                 (Item.Final_Value,
                  Ada.Streams.Stream_Element
                    (Table.Payload (Item_Entry.Value_Offset + Offset - 1)));
            end loop;
            LSM_Runtime.Release (Table);
            Complete_Lazy_SST_Read
              (Item, Success, Lazy_Value_Found, Sequence);
         end;
      end if;
   exception
      when others =>
         LSM_Runtime.Release (Table);
         raise;
   end Select_Lazy_Whole_SST_Entry;

   procedure Start_Lazy_SST_Range
     (Item  : in out Lazy_SST_Read_Operation;
      First : Natural;
      Last  : Natural;
      Phase : Lazy_SST_Read_Phase)
   is
      State : Lazy_SST_Read_State renames Item.Driver_State.all;
      Count : Natural;
   begin
      if Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Lazy_SST_Read
           (Item, Cancelled, Kind => Flyology.Operations.Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Lazy_SST_Read (Item, Timed_Out);
         return;
      elsif Last < First
        or else Last - First = Natural'Last
      then
         Complete_Lazy_SST_Read (Item, Corrupt);
         return;
      end if;
      Count := Last - First + 1;
      if Count > Flyology.Buffers.Buffer_Capacity (Item.Payload) then
         Complete_Lazy_SST_Read (Item, Capacity_Exceeded);
         return;
      end if;
      State.Requested :=
        (Kind  => OS.Bounded_Range,
         First => OS.Byte_Count (First),
         Last  => OS.Byte_Count (Last),
         Count => 0);
      State.Requested_Bytes := Count;
      Client_Objects.Get_Range
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Run_Key (Item.Storage.all, To_Identifier (State.Descriptor.Run_ID)),
         State.Requested,
         Item.Payload'Unchecked_Access,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         Quoted_Generation (State.Generation),
         Region                => UStrings.To_String (Item.Storage.Client_Region),
         Style                 => Item.Storage.Client_Style,
         Expected_Bucket_Owner => UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
         Request_Payer         => UStrings.To_String (Item.Storage.Client_Request_Payer),
         Checksum_Mode         => Item.Storage.Client_Checksum_Mode,
         Token                 => Item.Cancellation,
         Operation             => Item.Range_Child.all);
      State.Phase := Phase;
      Flyology.Operations.Continue_After (Item, Item.Range_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Complete_Lazy_SST_Read (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Lazy_SST_Read (Item, Error);
   end Start_Lazy_SST_Range;

   procedure Start_Lazy_SST_Whole (Item : in out Lazy_SST_Read_Operation) is
      State : Lazy_SST_Read_State renames Item.Driver_State.all;
   begin
      if Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Lazy_SST_Read
           (Item, Cancelled, Kind => Flyology.Operations.Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Lazy_SST_Read (Item, Timed_Out);
         return;
      elsif State.Object_Length > Flyology.Buffers.Buffer_Capacity (Item.Payload) then
         Complete_Lazy_SST_Read (Item, Capacity_Exceeded);
         return;
      end if;
      Client_Objects.Get_Whole
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Run_Key (Item.Storage.all, To_Identifier (State.Descriptor.Run_ID)),
         Item.Payload'Unchecked_Access,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         Expected_Entity_Tag   => Quoted_Generation (State.Generation),
         Region                => UStrings.To_String (Item.Storage.Client_Region),
         Style                 => Item.Storage.Client_Style,
         Expected_Bucket_Owner => UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
         Request_Payer         => UStrings.To_String (Item.Storage.Client_Request_Payer),
         Checksum_Mode         => Item.Storage.Client_Checksum_Mode,
         Token                 => Item.Cancellation,
         Operation             => Item.Whole_Child.all);
      State.Phase := Lazy_Read_Whole;
      Flyology.Operations.Continue_After (Item, Item.Whole_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Complete_Lazy_SST_Read (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Lazy_SST_Read (Item, Error);
   end Start_Lazy_SST_Whole;

   procedure Start_Lazy_SST_Head (Item : in out Lazy_SST_Read_Operation) is
      State      : Lazy_SST_Read_State renames Item.Driver_State.all;
      Parameters : Client_Low_Level.Head_Object_Parameters := (others => <>);
   begin
      if Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Lazy_SST_Read
           (Item, Cancelled, Kind => Flyology.Operations.Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Lazy_SST_Read (Item, Timed_Out);
         return;
      end if;
      Parameters.Expected_Bucket_Owner := Item.Storage.Expected_Bucket_Owner;
      Parameters.Request_Payer := Item.Storage.Client_Request_Payer;
      Parameters.Checksum_Mode := Item.Storage.Client_Checksum_Mode;
      Client_Objects.Head_Object
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Run_Key (Item.Storage.all, To_Identifier (State.Descriptor.Run_ID)),
         Parameters,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         UStrings.To_String (Item.Storage.Client_Region),
         Item.Storage.Client_Style,
         Item.Cancellation,
         Item.Head_Child.all);
      State.Phase := Lazy_Read_Head;
      Flyology.Operations.Continue_After (Item, Item.Head_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Complete_Lazy_SST_Read (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Lazy_SST_Read (Item, Error);
   end Start_Lazy_SST_Head;

   procedure Complete_Lazy_SST_Head
     (Item : in out Lazy_SST_Read_Operation)
   is
      State       : Lazy_SST_Read_State renames Item.Driver_State.all;
      Outcome     : Client_Objects.Head_Result;
      Read_Result : Read_Outcome := Read_Failed;
      Valid       : Boolean := False;
   begin
      begin
         Client_Objects.Finish (Item.Head_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Head_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Head_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Head_Child.all)
            then
               Flyology.Operations.Release (Item.Head_Child.all);
            end if;
            Fail_Lazy_SST_Read (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Head_Child.all);
      if Outcome.Kind = Client_Objects.Head_Exchange_Failed then
         Read_Result := Refresh_Read_Failure (Outcome.Failure);
      elsif Outcome.Response.Kind = Client_Low_Level.Head_Object_Rejected then
         Read_Result := Refresh_Read_Rejection (Outcome.Response.Status);
      elsif Outcome.Response.Status /= 200
        or else Outcome.Response.Result.Content_Length > OS.Byte_Count (Natural'Last)
      then
         Read_Result := Read_Corrupt;
      else
         Set_Quoted_Generation
           (State.Generation,
            UStrings.To_String (Outcome.Response.Result.Entity_Tag),
            Valid);
         if Valid then
            State.Object_Length := Natural (Outcome.Response.Result.Content_Length);
            if State.Object_Length < Minimum_Compatible_SST_Length then
               Complete_Lazy_SST_Read (Item, Corrupt);
               return;
            end if;
            declare
               Header_Length : constant Positive :=
                 Positive'Min (Compatible_SST_Header_Length, State.Object_Length);
            begin
               Start_Lazy_SST_Range
                 (Item, 0, Header_Length - 1, Lazy_Read_Header);
            end;
            return;
         end if;
         Read_Result := Read_Corrupt;
      end if;
      Complete_Lazy_SST_Read (Item, Lazy_Read_Outcome (Read_Result));
   exception
      when Error : others =>
         Fail_Lazy_SST_Read (Item, Error);
   end Complete_Lazy_SST_Head;

   procedure Select_Lazy_SST_Entry
     (Item : in out Lazy_SST_Read_Operation)
   is
      State : Lazy_SST_Read_State renames Item.Driver_State.all;
   begin
      State.Selected_Position := 0;
      for Position in State.Index.Entries'Range loop
         if Lazy_Index_Key_Matches (State.Index.all, Position, State.Item_Key)
           and then State.Index.Entries (Position).Sequence
                      <= Interfaces.Unsigned_64 (State.Snapshot_At)
         then
            State.Selected_Position := Position;
            exit;
         end if;
      end loop;
      if State.Selected_Position = 0 then
         Complete_Lazy_SST_Read
           (Item, Not_Found, Lazy_Key_Absent);
      else
         declare
            Index_Item : LSM_Runtime.SST_V2_Index_Entry renames
              State.Index.Entries (State.Selected_Position);
         begin
            Start_Lazy_SST_Range
              (Item,
               Index_Item.Frame_Offset,
               Index_Item.Frame_Offset + Index_Item.Frame_Byte_Total - 1,
               Lazy_Read_Frame);
         end;
      end if;
   exception
      when Error : others =>
         Fail_Lazy_SST_Read (Item, Error);
   end Select_Lazy_SST_Entry;

   procedure Complete_Lazy_SST_Whole
     (Item : in out Lazy_SST_Read_Operation)
   is
      State         : Lazy_SST_Read_State renames Item.Driver_State.all;
      Outcome       : Client_Objects.Whole_Get_Result;
      Read_Result   : Read_Outcome := Read_Failed;
      Generation    : Generation_Value;
      Image         : LSM_Runtime.Image_Access := null;
      Table         : LSM_Runtime.SST_Access := null;
      Decode_Status : LSM_Runtime.Decode_Status;
      Valid         : Boolean := False;
   begin
      begin
         Client_Objects.Finish (Item.Whole_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Whole_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Whole_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Whole_Child.all)
            then
               Flyology.Operations.Release (Item.Whole_Child.all);
            end if;
            Fail_Lazy_SST_Read (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Whole_Child.all);
      if Outcome.Kind = Client_Objects.Whole_Get_Exchange_Failed then
         Read_Result := Refresh_Read_Failure (Outcome.Failure);
      elsif Outcome.Response.Kind = Client_Low_Level.Get_Object_Rejected then
         Read_Result := Refresh_Read_Rejection (Outcome.Response.Status);
      else
         Set_Quoted_Generation
           (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
         if not Valid
           or else Generation /= State.Generation
           or else Outcome.Response.Status /= 200
           or else not Outcome.Response.Result.Content_Length.Is_Set
           or else Outcome.Response.Result.Content_Length.Value /= OS.Byte_Count (State.Object_Length)
           or else Flyology.Buffers.Length (Item.Payload) /= State.Object_Length
         then
            Read_Result := Read_Corrupt;
         else
            Read_Result := Object_Read;
         end if;
      end if;
      if Read_Result /= Object_Read then
         Complete_Lazy_SST_Read (Item, Lazy_Read_Outcome (Read_Result));
         return;
      end if;

      Copy_Selected_Payload (Item.Payload, Positive (State.Object_Length), Image);
      Decode_Compatible_SST
        (Image.all,
         To_Head_ID (State.Database_ID),
         Interfaces.Unsigned_32 (State.Family.ID),
         State.Descriptor,
         State.Family.Max_Key_Bytes,
         State.Family.Max_Value_Bytes,
         State.Admission,
         Table,
         Decode_Status);
      LSM_Runtime.Release (Image);
      if Decode_Status /= LSM_Runtime.Decoded then
         LSM_Runtime.Release (Table);
         Complete_Lazy_SST_Read
           (Item, Lazy_Decode_Outcome (Decode_Status));
      elsif State.Purpose = Lazy_Whole_Run then
         Item.Final_Table := new Lazy_SST_Table_Holder'(Table => Table);
         Table := null;
         Complete_Lazy_SST_Read (Item, Success);
      else
         Select_Lazy_Whole_SST_Entry (Item, Table);
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         LSM_Runtime.Release (Table);
         Complete_Lazy_SST_Read (Item, Capacity_Exceeded);
      when Error : others =>
         LSM_Runtime.Release (Image);
         LSM_Runtime.Release (Table);
         Fail_Lazy_SST_Read (Item, Error);
   end Complete_Lazy_SST_Whole;

   procedure Complete_Lazy_SST_Range
     (Item : in out Lazy_SST_Read_Operation)
   is
      State         : Lazy_SST_Read_State renames Item.Driver_State.all;
      Finished_Phase : constant Lazy_SST_Read_Phase := State.Phase;
      Outcome       : Client_Objects.Range_Get_Result;
      Read_Result   : Read_Outcome := Read_Failed;
      Generation    : Generation_Value;
      Image         : LSM_Runtime.Image_Access := null;
      Decode_Status : LSM_Runtime.Decode_Status;
      Valid         : Boolean := False;
      Expected      : Positive;
   begin
      begin
         Client_Objects.Finish (Item.Range_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Range_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Range_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Range_Child.all)
            then
               Flyology.Operations.Release (Item.Range_Child.all);
            end if;
            Fail_Lazy_SST_Read (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Range_Child.all);
      if Outcome.Kind = Client_Objects.Range_Get_Exchange_Failed then
         Read_Result := Refresh_Read_Failure (Outcome.Failure);
      elsif Outcome.Response.Kind = Client_Low_Level.Get_Object_Rejected then
         Read_Result := Refresh_Read_Rejection (Outcome.Response.Status);
      else
         Set_Quoted_Generation
           (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
         if State.Requested_Bytes = 0 then
            Complete_Lazy_SST_Read (Item, Corrupt);
            return;
         end if;
         Expected := Positive (State.Requested_Bytes);
         if not Valid
           or else Generation /= State.Generation
           or else Outcome.Response.Status /= 206
           or else not Outcome.Has_Resolved_Range
           or else Outcome.Resolved.First /= State.Requested.First
           or else Outcome.Resolved.Last /= State.Requested.Last
           or else Outcome.Resolved.Total_Length /= OS.Byte_Count (State.Object_Length)
           or else Flyology.Buffers.Length (Item.Payload) /= Expected
         then
            Read_Result := Read_Corrupt;
         else
            Read_Result := Object_Read;
         end if;
      end if;
      if Read_Result /= Object_Read then
         Complete_Lazy_SST_Read (Item, Lazy_Read_Outcome (Read_Result));
         return;
      end if;

      Expected := Positive (Flyology.Buffers.Length (Item.Payload));
      Copy_Selected_Payload (Item.Payload, Expected, Image);
      case Finished_Phase is
         when Lazy_Read_Header =>
            Inspect_Compatible_SST_Header
              (Image.all,
               To_Head_ID (State.Database_ID),
               Interfaces.Unsigned_32 (State.Family.ID),
               State.Descriptor,
               Interfaces.Unsigned_64 (State.Object_Length),
               State.Admission,
               Decode_Status);
            LSM_Runtime.Release (Image);
            if Decode_Status /= LSM_Runtime.Decoded then
               Complete_Lazy_SST_Read
                 (Item, Lazy_Decode_Outcome (Decode_Status));
            elsif State.Purpose = Lazy_Whole_Run
              or else State.Admission.Format_Version = LSM_Runtime.LSM.SST_Format_Version
            then
               Start_Lazy_SST_Whole (Item);
            else
               Start_Lazy_SST_Range
                 (Item,
                  State.Admission.Index_Offset,
                  State.Admission.Index_Offset + State.Admission.Index_Bytes - 1,
                  Lazy_Read_Index);
            end if;

         when Lazy_Read_Index =>
            LSM_Runtime.Decode_SST_V2_Index
              (Image.all,
               State.Admission,
               To_Head_ID (State.Database_ID),
               Interfaces.Unsigned_32 (State.Family.ID),
               State.Descriptor,
               State.Family.Max_Key_Bytes,
               State.Family.Max_Value_Bytes,
               State.Index,
               Decode_Status);
            LSM_Runtime.Release (Image);
            if Decode_Status /= LSM_Runtime.Decoded then
               Complete_Lazy_SST_Read
                 (Item, Lazy_Decode_Outcome (Decode_Status));
            else
               Select_Lazy_SST_Entry (Item);
            end if;

         when Lazy_Read_Frame =>
            declare
               Frame : LSM_Runtime.SST_V2_Frame_Access := null;
               Index_Item : LSM_Runtime.SST_V2_Index_Entry renames
                 State.Index.Entries (State.Selected_Position);
            begin
               LSM_Runtime.Decode_SST_V2_Frame
                 (Image.all,
                  State.Index.all,
                  State.Selected_Position,
                  Frame,
                  Decode_Status);
               LSM_Runtime.Release (Image);
               if Decode_Status /= LSM_Runtime.Decoded then
                  Complete_Lazy_SST_Read
                    (Item, Lazy_Decode_Outcome (Decode_Status));
               elsif Index_Item.Operation = LSM_Runtime.LSM.Delete_Operation then
                  LSM_Runtime.Release (Frame);
                  Complete_Lazy_SST_Read
                    (Item,
                     Not_Found,
                     Lazy_Tombstone_Found,
                     Sequence_Number (Index_Item.Sequence));
               else
                  Flyology.Bytes.Clear (Item.Final_Value);
                  Flyology.Bytes.Reserve_Capacity
                    (Item.Final_Value, Index_Item.Value_Byte_Total);
                  for Offset in Natural range 1 .. Index_Item.Value_Byte_Total loop
                     Flyology.Bytes.Append
                       (Item.Final_Value,
                        Ada.Streams.Stream_Element
                          (Frame.Payload (Index_Item.Key_Byte_Total + Offset)));
                  end loop;
                  LSM_Runtime.Release (Frame);
                  Complete_Lazy_SST_Read
                    (Item,
                     Success,
                     Lazy_Value_Found,
                     Sequence_Number (Index_Item.Sequence));
               end if;
            exception
               when others =>
                  LSM_Runtime.Release (Frame);
                  raise;
            end;

         when others =>
            LSM_Runtime.Release (Image);
            raise Program_Error with "invalid lazy SST range phase";
      end case;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         Complete_Lazy_SST_Read (Item, Capacity_Exceeded);
      when Error : others =>
         LSM_Runtime.Release (Image);
         Fail_Lazy_SST_Read (Item, Error);
   end Complete_Lazy_SST_Range;

   overriding procedure Drive
     (Item : in out Lazy_SST_Read_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      if Event = Flyology.Operations.Start_Operation then
         Start_Lazy_SST_Head (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Lazy_Read_Head
        and then Item.Head_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Head_Child.all)
      then
         Complete_Lazy_SST_Head (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Lazy_Read_Whole
        and then Item.Whole_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Whole_Child.all)
      then
         Complete_Lazy_SST_Whole (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase
                   in Lazy_Read_Header | Lazy_Read_Index | Lazy_Read_Frame
        and then Item.Range_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Range_Child.all)
      then
         Complete_Lazy_SST_Range (Item);
      else
         raise Program_Error with "invalid lazy SST driver event";
      end if;
   exception
      when Error : others =>
         if Flyology.Operations.Is_Active (Item) then
            Fail_Lazy_SST_Read (Item, Error);
         end if;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Lazy_SST_Read_Operation)
   is
   begin
      if Item.Head_Child /= null
        and then Flyology.Operations.Is_Active (Item.Head_Child.all)
      then
         Flyology.Operations.Cancel (Item.Head_Child.all);
      elsif Item.Head_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Head_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Lazy_Read_Head
      then
         Complete_Lazy_SST_Head (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Item.Whole_Child /= null
        and then Flyology.Operations.Is_Active (Item.Whole_Child.all)
      then
         Flyology.Operations.Cancel (Item.Whole_Child.all);
      elsif Item.Whole_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Whole_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Lazy_Read_Whole
      then
         Complete_Lazy_SST_Whole (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Item.Range_Child /= null
        and then Flyology.Operations.Is_Active (Item.Range_Child.all)
      then
         Flyology.Operations.Cancel (Item.Range_Child.all);
      elsif Item.Range_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Range_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase
                   in Lazy_Read_Header | Lazy_Read_Index | Lazy_Read_Frame
      then
         Complete_Lazy_SST_Range (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Flyology.Operations.Is_Active (Item) then
         Complete_Lazy_SST_Read
           (Item, Cancelled, Kind => Flyology.Operations.Cancelled);
      end if;
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            begin
               Complete_Lazy_SST_Read
                 (Item, Storage_Failure, Kind => Flyology.Operations.Failed);
            exception
               when others =>
                  null;
            end;
         end if;
   end Request_Cancellation;

   procedure Start_Lazy_SST_Read
     (Database_ID           : Database_Identifier;
      Family                : Column_Family_Configuration;
      Run_ID                : Identifier;
      Lowest_Sequence       : Sequence_Number;
      Highest_Sequence      : Sequence_Number;
      Entry_Total           : Interfaces.Unsigned_32;
      Logical_Payload_Bytes : Interfaces.Unsigned_64;
      Purpose               : Lazy_SST_Read_Purpose;
      Snapshot_At           : Sequence_Number;
      Item_Key              : Byte_Array;
      Payload_Buffer        : in out Flyology.Buffers.Unique_Buffer;
      Timeout               : Duration;
      Operation             : in out Lazy_SST_Read_Operation)
   is
      Moved   : Boolean := False;
      Started : Boolean := False;
   begin
      if Operation.Storage.HTTP_Client /= Operation.HTTP
        or else Operation.Storage.Client_Identity = null
      then
         raise Program_Error with "lazy SST operation does not match client-bound storage";
      elsif Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "lazy SST payload belongs to a different pool";
      elsif Flyology.Buffers.Has_Buffer (Operation.Payload)
        or else Operation.Driver_State /= null
        or else Operation.Whole_Child /= null
        or else Operation.Range_Child /= null
        or else Operation.Head_Child /= null
      then
         raise Program_Error with "lazy SST operation retains unconsumed ownership";
      end if;

      Operation.Deadline := Deadline_After (Timeout);
      Operation.HTTP_Deadline :=
        (if Operation.Deadline = Ada.Real_Time.Time_Last
         then Flyology.HTTP.Client.No_Deadline
         else Flyology.HTTP.Client.Deadline_After
                (Remaining_Time (Operation.Deadline)));
      Operation.Final_Result := Invalid_State;
      Operation.Final_Disposition := Lazy_Read_Failed;
      Operation.Final_Sequence := 0;
      Flyology.Bytes.Clear (Operation.Final_Value);
      Release_Lazy_SST_Table (Operation.Final_Table);
      Operation.Final_Purpose := Purpose;
      Operation.Has_Final_Result := False;
      Operation.Has_Saved_Error := False;
      begin
         Operation.Driver_State := new Lazy_SST_Read_State;
         Operation.Driver_State.Database_ID := Database_ID;
         Operation.Driver_State.Family := Family;
         Operation.Driver_State.Snapshot_At := Snapshot_At;
         Operation.Driver_State.Purpose := Purpose;
         Operation.Driver_State.Descriptor :=
           (Run_ID                => To_Head_ID (Run_ID),
            Lowest_Sequence       => Interfaces.Unsigned_64 (Lowest_Sequence),
            Highest_Sequence      => Interfaces.Unsigned_64 (Highest_Sequence),
            Entry_Total           => Entry_Total,
            Logical_Payload_Bytes => Logical_Payload_Bytes);
         if Is_Zero (Database_ID)
           or else Is_Zero (Run_ID)
           or else not Manifests.Valid_Configuration
                         (To_Manifest_Configuration (Family))
           or else Entry_Total = 0
           or else Lowest_Sequence = 0
           or else Lowest_Sequence > Highest_Sequence
           or else (Purpose = Lazy_Point_Entry
                    and then Interfaces.Unsigned_64 (Item_Key'Length) > Family.Max_Key_Bytes)
         then
            Operation.Driver_State.Precheck_Result :=
              (if Purpose = Lazy_Point_Entry
                 and then Interfaces.Unsigned_64 (Item_Key'Length) > Family.Max_Key_Bytes
               then Capacity_Exceeded
               else Invalid_State);
         elsif Purpose = Lazy_Point_Entry then
            Flyology.Bytes.Reserve_Capacity
              (Operation.Driver_State.Item_Key, Item_Key'Length);
            for Value of Item_Key loop
               Flyology.Bytes.Append
                 (Operation.Driver_State.Item_Key,
                  Ada.Streams.Stream_Element (Value));
            end loop;
         end if;
      exception
         when Storage_Error =>
            if Operation.Driver_State /= null then
               Operation.Driver_State.Precheck_Result := Capacity_Exceeded;
            end if;
      end;
      if Operation.Driver_State /= null then
         begin
            Operation.Whole_Child :=
              new Client_Objects.Whole_Get_Operation
                (Operation.Set.all'Unchecked_Access,
                 Operation.HTTP.all'Unchecked_Access,
                 Operation.Payload'Unchecked_Access,
                 (if Operation.Cancellation = null
                  then null
                  else Operation.Cancellation.all'Unchecked_Access));
            Operation.Range_Child :=
              new Client_Objects.Range_Get_Operation
                (Operation.Set.all'Unchecked_Access,
                 Operation.HTTP.all'Unchecked_Access,
                 Operation.Payload'Unchecked_Access,
                 (if Operation.Cancellation = null
                  then null
                  else Operation.Cancellation.all'Unchecked_Access));
            Operation.Head_Child :=
              new Client_Objects.Head_Operation
                (Operation.Set.all'Unchecked_Access,
                 Operation.HTTP.all'Unchecked_Access,
                 (if Operation.Cancellation = null
                  then null
                  else Operation.Cancellation.all'Unchecked_Access));
         exception
            when Storage_Error =>
               Operation.Driver_State.Precheck_Result := Capacity_Exceeded;
         end;
      end if;

      Flyology.Operations.Drivers.Start (Operation);
      Started := True;
      Flyology.Buffers.Move (Payload_Buffer, Operation.Payload);
      Moved := True;
      if Operation.Driver_State = null then
         Operation.Final_Result := Capacity_Exceeded;
         Operation.Has_Final_Result := True;
         Flyology.Operations.Drivers.Complete
           (Operation, Flyology.Operations.Succeeded);
      elsif Operation.Driver_State.Precheck_Result /= Success then
         Complete_Lazy_SST_Read
           (Operation, Operation.Driver_State.Precheck_Result);
      else
         Flyology.Operations.Drive
           (Flyology.Operations.Operation'Class (Operation),
            Flyology.Operations.Start_Operation);
      end if;
   exception
      when others =>
         if Moved and then Flyology.Buffers.Has_Buffer (Operation.Payload) then
            Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
         end if;
         Release_Lazy_SST_Read_State (Operation);
         if Operation.Whole_Child /= null then
            Free_Whole_Get_Operation (Operation.Whole_Child);
         end if;
         if Operation.Range_Child /= null then
            Free_Range_Get_Operation (Operation.Range_Child);
         end if;
         if Operation.Head_Child /= null then
            Free_Head_Operation (Operation.Head_Child);
         end if;
         if Started and then Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Lazy_SST_Read;

   procedure Read_Lazy_SST_Entry
     (Database_ID           : Database_Identifier;
      Family                : Column_Family_Configuration;
      Run_ID                : Identifier;
      Lowest_Sequence       : Sequence_Number;
      Highest_Sequence      : Sequence_Number;
      Entry_Total           : Interfaces.Unsigned_32;
      Logical_Payload_Bytes : Interfaces.Unsigned_64;
      Snapshot_At           : Sequence_Number;
      Item_Key              : Byte_Array;
      Payload_Buffer        : in out Flyology.Buffers.Unique_Buffer;
      Timeout               : Duration;
      Operation             : in out Lazy_SST_Read_Operation) is
   begin
      Start_Lazy_SST_Read
        (Database_ID,
         Family,
         Run_ID,
         Lowest_Sequence,
         Highest_Sequence,
         Entry_Total,
         Logical_Payload_Bytes,
         Lazy_Point_Entry,
         Snapshot_At,
         Item_Key,
         Payload_Buffer,
         Timeout,
         Operation);
   end Read_Lazy_SST_Entry;

   procedure Read_Lazy_SST
     (Database_ID           : Database_Identifier;
      Family                : Column_Family_Configuration;
      Run_ID                : Identifier;
      Lowest_Sequence       : Sequence_Number;
      Highest_Sequence      : Sequence_Number;
      Entry_Total           : Interfaces.Unsigned_32;
      Logical_Payload_Bytes : Interfaces.Unsigned_64;
      Payload_Buffer        : in out Flyology.Buffers.Unique_Buffer;
      Timeout               : Duration;
      Operation             : in out Lazy_SST_Read_Operation) is
   begin
      Start_Lazy_SST_Read
        (Database_ID,
         Family,
         Run_ID,
         Lowest_Sequence,
         Highest_Sequence,
         Entry_Total,
         Logical_Payload_Bytes,
         Lazy_Whole_Run,
         0,
         [1 .. 0 => 0],
         Payload_Buffer,
         Timeout,
         Operation);
   end Read_Lazy_SST;

   procedure Finish_Lazy_SST_Read
     (Operation      : in out Lazy_SST_Read_Operation;
      Disposition    : out Lazy_SST_Entry_Disposition;
      Sequence       : out Sequence_Number;
      Value          : out Flyology.Bytes.Unbounded_Bytes;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
   is
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "lazy SST Finish requires the moved token's pool";
      elsif Flyology.Buffers.Has_Buffer (Payload_Buffer) then
         raise Program_Error with "lazy SST Finish requires a vacant same-pool handle";
      elsif Operation.Has_Final_Result and then Operation.Final_Purpose /= Lazy_Point_Entry then
         raise Program_Error with "point Finish does not match whole-run read";
      end if;
      Disposition := Lazy_Read_Failed;
      Sequence := 0;
      Flyology.Bytes.Clear (Value);
      Result := Invalid_State;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
      Release_Lazy_SST_Read_State (Operation);
      if Operation.Whole_Child /= null then
         Free_Whole_Get_Operation (Operation.Whole_Child);
      end if;
      if Operation.Range_Child /= null then
         Free_Range_Get_Operation (Operation.Range_Child);
      end if;
      if Operation.Head_Child /= null then
         Free_Head_Operation (Operation.Head_Child);
      end if;
      if Operation.Has_Saved_Error then
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity (Operation.Saved_Error),
            Ada.Exceptions.Exception_Message (Operation.Saved_Error));
      elsif not Operation.Has_Final_Result then
         raise Program_Error with "lazy SST operation has no terminal result";
      end if;
      Disposition := Operation.Final_Disposition;
      Sequence := Operation.Final_Sequence;
      Flyology.Bytes.Move (Value, Operation.Final_Value);
      Result := Operation.Final_Result;
   end Finish_Lazy_SST_Read;

   procedure Finish_Lazy_SST_Read
     (Operation      : in out Lazy_SST_Read_Operation;
      Table          : out LSM_Runtime.SST_Access;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer) is
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "lazy SST Finish requires the moved token's pool";
      elsif Flyology.Buffers.Has_Buffer (Payload_Buffer) then
         raise Program_Error with "lazy SST Finish requires a vacant same-pool handle";
      elsif Operation.Has_Final_Result and then Operation.Final_Purpose /= Lazy_Whole_Run then
         raise Program_Error with "whole-run Finish does not match point read";
      end if;
      Table := null;
      Result := Invalid_State;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
      Release_Lazy_SST_Read_State (Operation);
      if Operation.Whole_Child /= null then
         Free_Whole_Get_Operation (Operation.Whole_Child);
      end if;
      if Operation.Range_Child /= null then
         Free_Range_Get_Operation (Operation.Range_Child);
      end if;
      if Operation.Head_Child /= null then
         Free_Head_Operation (Operation.Head_Child);
      end if;
      if Operation.Has_Saved_Error then
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity (Operation.Saved_Error),
            Ada.Exceptions.Exception_Message (Operation.Saved_Error));
      elsif not Operation.Has_Final_Result then
         raise Program_Error with "lazy SST operation has no terminal result";
      end if;
      Result := Operation.Final_Result;
      if Result = Success then
         if Operation.Final_Table = null then
            raise Program_Error with "whole-run operation has no decoded table";
         end if;
         Table := Operation.Final_Table.Table;
         Operation.Final_Table.Table := null;
         Release_Lazy_SST_Table (Operation.Final_Table);
      else
         Release_Lazy_SST_Table (Operation.Final_Table);
      end if;
   end Finish_Lazy_SST_Read;

   overriding procedure Finalize (Item : in out Lazy_SST_Read_Operation) is
   begin
      begin
         Flyology.Operations.Finalize
           (Flyology.Operations.Operation (Item));
      exception
         when others =>
            null;
      end;
      Release_Lazy_SST_Read_State (Item);
      Release_Lazy_SST_Table (Item.Final_Table);
      if Item.Whole_Child /= null then
         Free_Whole_Get_Operation (Item.Whole_Child);
      end if;
      if Item.Range_Child /= null then
         Free_Range_Get_Operation (Item.Range_Child);
      end if;
      if Item.Head_Child /= null then
         Free_Head_Operation (Item.Head_Child);
      end if;
      Flyology.Buffers.Release (Item.Payload);
   end Finalize;

   procedure Release_Lazy_Checkpoint_Read_State
     (Item : in out Lazy_Checkpoint_Read_Operation)
   is
   begin
      if Item.Driver_State /= null then
         Free_Lazy_SST_Run_Array (Item.Driver_State.Runs);
         Free_Lazy_Checkpoint_Read_State (Item.Driver_State);
      end if;
   end Release_Lazy_Checkpoint_Read_State;

   procedure Complete_Lazy_Checkpoint_Read
     (Item        : in out Lazy_Checkpoint_Read_Operation;
      Result      : Outcome_Code;
      Disposition : Lazy_SST_Entry_Disposition := Lazy_Read_Failed;
      Sequence    : Sequence_Number := 0;
      Kind        : Flyology.Operations.Terminal_Outcome := Flyology.Operations.Succeeded)
   is
   begin
      if Item.Driver_State /= null then
         Item.Driver_State.Phase := Lazy_Checkpoint_Terminal;
      end if;
      Item.Final_Result := Result;
      Item.Final_Disposition := Disposition;
      Item.Final_Sequence := Sequence;
      Item.Has_Final_Result := True;
      Flyology.Operations.Drivers.Complete (Item, Kind);
   end Complete_Lazy_Checkpoint_Read;

   procedure Fail_Lazy_Checkpoint_Read
     (Item  : in out Lazy_Checkpoint_Read_Operation;
      Error : Ada.Exceptions.Exception_Occurrence)
   is
   begin
      if Ada.Exceptions.Exception_Identity (Error) = Storage_Error'Identity then
         Complete_Lazy_Checkpoint_Read (Item, Capacity_Exceeded);
         return;
      end if;
      Item.Has_Saved_Error := True;
      Ada.Exceptions.Save_Occurrence (Item.Saved_Error, Error);
      Complete_Lazy_Checkpoint_Read
        (Item, Storage_Failure, Kind => Flyology.Operations.Failed);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Failed);
         end if;
   end Fail_Lazy_Checkpoint_Read;

   procedure Start_Next_Lazy_Checkpoint_Run
     (Item : in out Lazy_Checkpoint_Read_Operation)
   is
      State : Lazy_Checkpoint_Read_State renames Item.Driver_State.all;
   begin
      if Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Lazy_Checkpoint_Read
           (Item, Cancelled, Kind => Flyology.Operations.Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Lazy_Checkpoint_Read (Item, Timed_Out);
         return;
      end if;
      if State.Current_Index > 0
        and then State.Runs (State.Current_Index).Lowest_Sequence > State.Snapshot_At
      then
         State.Current_Index := State.Current_Index - 1;
         State.Phase := Lazy_Checkpoint_Idle;
         Flyology.Operations.Drivers.Reschedule (Item);
         return;
      end if;
      if State.Current_Index = 0 then
         Complete_Lazy_Checkpoint_Read
           (Item, Not_Found, Lazy_Key_Absent);
         return;
      end if;
      declare
         Descriptor : Lazy_SST_Run_Descriptor renames State.Runs (State.Current_Index);
         Raw_Key    : constant Ada.Streams.Stream_Element_Array :=
           Flyology.Bytes.To_Array (State.Item_Key);
         Key        : Byte_Array (1 .. Raw_Key'Length);
      begin
         for Index in Key'Range loop
            Key (Index) := Byte (Raw_Key (Ada.Streams.Stream_Element_Offset (Index)));
         end loop;
         State.Phase := Lazy_Checkpoint_Reading;
         Read_Lazy_SST_Entry
           (State.Database_ID,
            State.Family,
            Descriptor.Run_ID,
            Descriptor.Lowest_Sequence,
            Descriptor.Highest_Sequence,
            Descriptor.Entry_Total,
            Descriptor.Logical_Payload_Bytes,
            State.Snapshot_At,
            Key,
            Item.Payload,
            Remaining_Time (Item.Deadline),
            Item.Child);
         Flyology.Operations.Continue_After (Item, Item.Child);
      end;
   exception
      when Flyology.Operations.Capacity_Error =>
         Complete_Lazy_Checkpoint_Read (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Lazy_Checkpoint_Read (Item, Error);
   end Start_Next_Lazy_Checkpoint_Run;

   procedure Complete_Lazy_Checkpoint_Child
     (Item : in out Lazy_Checkpoint_Read_Operation)
   is
      State       : Lazy_Checkpoint_Read_State renames Item.Driver_State.all;
      Disposition : Lazy_SST_Entry_Disposition;
      Sequence    : Sequence_Number;
      Value       : Flyology.Bytes.Unbounded_Bytes;
      Result      : Outcome_Code;
   begin
      begin
         Finish_Lazy_SST_Read
           (Item.Child,
            Disposition,
            Sequence,
            Value,
            Result,
            Item.Payload);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Child) /= 0
              and then not Flyology.Operations.Is_Active (Item.Child)
              and then not Flyology.Operations.Is_Terminal (Item.Child)
            then
               Flyology.Operations.Release (Item.Child);
            end if;
            Fail_Lazy_Checkpoint_Read (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Child);
      case Disposition is
         when Lazy_Value_Found =>
            if Result /= Success
              or else Sequence = 0
              or else Sequence > State.Snapshot_At
              or else Sequence < State.Runs (State.Current_Index).Lowest_Sequence
              or else Sequence > State.Runs (State.Current_Index).Highest_Sequence
            then
               Complete_Lazy_Checkpoint_Read (Item, Corrupt);
            else
               Flyology.Bytes.Move (Item.Final_Value, Value);
               Complete_Lazy_Checkpoint_Read
                 (Item, Success, Lazy_Value_Found, Sequence);
            end if;
         when Lazy_Tombstone_Found =>
            if Result /= Not_Found
              or else Sequence = 0
              or else Sequence > State.Snapshot_At
              or else Sequence < State.Runs (State.Current_Index).Lowest_Sequence
              or else Sequence > State.Runs (State.Current_Index).Highest_Sequence
            then
               Complete_Lazy_Checkpoint_Read (Item, Corrupt);
            else
               Complete_Lazy_Checkpoint_Read
                 (Item, Not_Found, Lazy_Tombstone_Found, Sequence);
            end if;
         when Lazy_Key_Absent =>
            if Result /= Not_Found
              or else Sequence /= 0
              or else Flyology.Bytes.Length (Value) /= 0
            then
               Complete_Lazy_Checkpoint_Read (Item, Corrupt);
            else
               State.Current_Index := State.Current_Index - 1;
               State.Phase := Lazy_Checkpoint_Idle;
               Flyology.Operations.Drivers.Reschedule (Item);
            end if;
         when Lazy_Read_Failed =>
            Complete_Lazy_Checkpoint_Read
              (Item,
               (if Result in Success | Not_Found then Corrupt else Result));
      end case;
   exception
      when Error : others =>
         Fail_Lazy_Checkpoint_Read (Item, Error);
   end Complete_Lazy_Checkpoint_Child;

   overriding procedure Drive
     (Item : in out Lazy_Checkpoint_Read_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      if Event = Flyology.Operations.Start_Operation
        or else
          (Event = Flyology.Operations.Continue_Operation
           and then Item.Driver_State /= null
           and then Item.Driver_State.Phase = Lazy_Checkpoint_Idle)
      then
         Start_Next_Lazy_Checkpoint_Run (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Lazy_Checkpoint_Reading
        and then Flyology.Operations.Is_Terminal (Item.Child)
      then
         Complete_Lazy_Checkpoint_Child (Item);
      else
         raise Program_Error with "invalid lazy checkpoint driver event";
      end if;
   exception
      when Error : others =>
         if Flyology.Operations.Is_Active (Item) then
            Fail_Lazy_Checkpoint_Read (Item, Error);
         end if;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Lazy_Checkpoint_Read_Operation)
   is
   begin
      if Flyology.Operations.Is_Active (Item.Child) then
         Flyology.Operations.Cancel (Item.Child);
      elsif Flyology.Operations.Is_Terminal (Item.Child)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Lazy_Checkpoint_Reading
      then
         Complete_Lazy_Checkpoint_Child (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Flyology.Operations.Is_Active (Item) then
         Complete_Lazy_Checkpoint_Read
           (Item, Cancelled, Kind => Flyology.Operations.Cancelled);
      end if;
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            begin
               Complete_Lazy_Checkpoint_Read
                 (Item, Storage_Failure, Kind => Flyology.Operations.Failed);
            exception
               when others =>
                  null;
            end;
         end if;
   end Request_Cancellation;

   procedure Read_Lazy_Checkpoint_Entry
     (Database_ID    : Database_Identifier;
      Family         : Column_Family_Configuration;
      Runs           : Lazy_SST_Run_Array;
      Snapshot_At    : Sequence_Number;
      Item_Key       : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Lazy_Checkpoint_Read_Operation)
   is
      Moved   : Boolean := False;
      Started : Boolean := False;
   begin
      if Operation.Storage.HTTP_Client /= Operation.HTTP
        or else Operation.Storage.Client_Identity = null
      then
         raise Program_Error with "lazy checkpoint operation does not match client-bound storage";
      elsif Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "lazy checkpoint payload belongs to a different pool";
      elsif Flyology.Buffers.Has_Buffer (Operation.Payload)
        or else Operation.Driver_State /= null
      then
         raise Program_Error with "lazy checkpoint operation retains unconsumed ownership";
      end if;

      Operation.Deadline := Deadline_After (Timeout);
      Operation.Final_Result := Invalid_State;
      Operation.Final_Disposition := Lazy_Read_Failed;
      Operation.Final_Sequence := 0;
      Flyology.Bytes.Clear (Operation.Final_Value);
      Operation.Has_Final_Result := False;
      Operation.Has_Saved_Error := False;
      begin
         Operation.Driver_State := new Lazy_Checkpoint_Read_State;
         Operation.Driver_State.Database_ID := Database_ID;
         Operation.Driver_State.Family := Family;
         Operation.Driver_State.Snapshot_At := Snapshot_At;
         if Runs'Length > 0 then
            Operation.Driver_State.Runs := new Lazy_SST_Run_Array (1 .. Runs'Length);
            for Offset in Natural range 0 .. Runs'Length - 1 loop
               Operation.Driver_State.Runs (Offset + 1) := Runs (Runs'First + Offset);
            end loop;
            Operation.Driver_State.Current_Index := Runs'Length;
         end if;
         if Is_Zero (Database_ID)
           or else not Manifests.Valid_Configuration
                         (To_Manifest_Configuration (Family))
           or else Interfaces.Unsigned_64 (Item_Key'Length) > Family.Max_Key_Bytes
         then
            Operation.Driver_State.Precheck_Result :=
              (if Interfaces.Unsigned_64 (Item_Key'Length) > Family.Max_Key_Bytes
               then Capacity_Exceeded
               else Invalid_State);
         else
            for Index in Positive range 1 .. Runs'Length loop
               declare
                  Descriptor : Lazy_SST_Run_Descriptor renames
                    Operation.Driver_State.Runs (Index);
               begin
                  if Is_Zero (Descriptor.Run_ID)
                    or else Descriptor.Lowest_Sequence = 0
                    or else Descriptor.Lowest_Sequence > Descriptor.Highest_Sequence
                    or else Descriptor.Entry_Total = 0
                    or else
                      (Index > 1
                       and then Operation.Driver_State.Runs (Index - 1).Highest_Sequence
                                  >= Descriptor.Lowest_Sequence)
                  then
                     Operation.Driver_State.Precheck_Result := Invalid_State;
                  end if;
                  for Earlier in Positive range 1 .. Index - 1 loop
                     if Operation.Driver_State.Runs (Earlier).Run_ID = Descriptor.Run_ID then
                        Operation.Driver_State.Precheck_Result := Invalid_State;
                     end if;
                  end loop;
               end;
            end loop;
            Flyology.Bytes.Reserve_Capacity
              (Operation.Driver_State.Item_Key, Item_Key'Length);
            for Value of Item_Key loop
               Flyology.Bytes.Append
                 (Operation.Driver_State.Item_Key,
                  Ada.Streams.Stream_Element (Value));
            end loop;
         end if;
      exception
         when Storage_Error =>
            if Operation.Driver_State /= null then
               Operation.Driver_State.Precheck_Result := Capacity_Exceeded;
            end if;
      end;

      Flyology.Operations.Drivers.Start (Operation);
      Started := True;
      Flyology.Buffers.Move (Payload_Buffer, Operation.Payload);
      Moved := True;
      if Operation.Driver_State = null then
         Operation.Final_Result := Capacity_Exceeded;
         Operation.Has_Final_Result := True;
         Flyology.Operations.Drivers.Complete
           (Operation, Flyology.Operations.Succeeded);
      elsif Operation.Driver_State.Precheck_Result /= Success then
         Complete_Lazy_Checkpoint_Read
           (Operation, Operation.Driver_State.Precheck_Result);
      else
         Flyology.Operations.Drive
           (Flyology.Operations.Operation'Class (Operation),
            Flyology.Operations.Start_Operation);
      end if;
   exception
      when others =>
         if Moved and then Flyology.Buffers.Has_Buffer (Operation.Payload) then
            Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
         end if;
         Release_Lazy_Checkpoint_Read_State (Operation);
         if Started and then Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Read_Lazy_Checkpoint_Entry;

   procedure Finish_Lazy_Checkpoint_Read
     (Operation      : in out Lazy_Checkpoint_Read_Operation;
      Disposition    : out Lazy_SST_Entry_Disposition;
      Sequence       : out Sequence_Number;
      Value          : out Flyology.Bytes.Unbounded_Bytes;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
   is
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "lazy checkpoint Finish requires the moved token's pool";
      elsif Flyology.Buffers.Has_Buffer (Payload_Buffer) then
         raise Program_Error with "lazy checkpoint Finish requires a vacant same-pool handle";
      end if;
      Disposition := Lazy_Read_Failed;
      Sequence := 0;
      Flyology.Bytes.Clear (Value);
      Result := Invalid_State;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
      Release_Lazy_Checkpoint_Read_State (Operation);
      if Operation.Has_Saved_Error then
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity (Operation.Saved_Error),
            Ada.Exceptions.Exception_Message (Operation.Saved_Error));
      elsif not Operation.Has_Final_Result then
         raise Program_Error with "lazy checkpoint operation has no terminal result";
      end if;
      Disposition := Operation.Final_Disposition;
      Sequence := Operation.Final_Sequence;
      Flyology.Bytes.Move (Value, Operation.Final_Value);
      Result := Operation.Final_Result;
   end Finish_Lazy_Checkpoint_Read;

   overriding procedure Finalize
     (Item : in out Lazy_Checkpoint_Read_Operation)
   is
   begin
      begin
         Flyology.Operations.Finalize
           (Flyology.Operations.Operation (Item));
      exception
         when others =>
            null;
      end;
      Release_Lazy_Checkpoint_Read_State (Item);
      Flyology.Buffers.Release (Item.Payload);
   end Finalize;

   procedure Release_Get_Lease (Item : in out Get_Operation) is
   begin
      if Item.Retained_Life /= null then
         Item.Retained_Life.Release;
         Item.Retained_Life := null;
         Item.Retained_State := null;
      end if;
   end Release_Get_Lease;

   procedure Release_Get_State (Item : in out Get_Operation) is
   begin
      if Item.Driver_State /= null then
         Free_Lazy_SST_Run_Array (Item.Driver_State.Runs);
         Free_Get_Driver_State (Item.Driver_State);
      end if;
      if Item.Child /= null then
         Free_Lazy_Checkpoint_Read_Operation (Item.Child);
      end if;
   end Release_Get_State;

   procedure Complete_Get
     (Item   : in out Get_Operation;
      Result : Outcome_Code;
      Value  : in out Flyology.Bytes.Unbounded_Bytes;
      Kind   : Flyology.Operations.Terminal_Outcome := Flyology.Operations.Succeeded)
   is
      Final_Result : Outcome_Code := Result;
   begin
      Flyology.Bytes.Clear (Item.Final_Value);
      if Item.Driver_State = null then
         Final_Result := Capacity_Exceeded;
      elsif Item.Driver_State.Transaction_Captured
        and then
          (not Item.Txn.Active
           or else Item.Txn.Owner.Arena = null
           or else Item.Txn.Database_ID /= Item.Driver_State.Database_ID
           or else Item.Txn.Incarnation /= Item.Driver_State.Incarnation
           or else Item.Txn.Transaction_ID /= Item.Driver_State.Transaction_ID
           or else Item.Txn.Snapshot_At /= Item.Driver_State.Snapshot_At
           or else Item.Txn.Owner.Arena.Mutation_Version
                     /= Item.Driver_State.Mutation_Version)
      then
         Final_Result := Invalid_State;
      elsif Item.Driver_State.Needs_Observation
        and then Final_Result in Success | Not_Found
      then
         declare
            Raw_Key : constant Ada.Streams.Stream_Element_Array :=
              Flyology.Bytes.To_Array (Item.Driver_State.Item_Key);
            Key     : Byte_Array (1 .. Raw_Key'Length);
         begin
            for Index in Key'Range loop
               Key (Index) := Byte (Raw_Key (Ada.Streams.Stream_Element_Offset (Index)));
            end loop;
            Record_Point_Read
              (Item.Txn.all,
               Item.Driver_State.Family.ID,
               Key,
               Final_Result);
            if Final_Result = Success then
               Final_Result := Result;
            end if;
         end;
      end if;
      if Final_Result = Success then
         Flyology.Bytes.Move (Item.Final_Value, Value);
      else
         Flyology.Bytes.Clear (Value);
      end if;
      Item.Driver_State.Phase := Get_Terminal;
      Item.Final_Result := Final_Result;
      Item.Has_Final_Result := True;
      Release_Get_Lease (Item);
      Flyology.Operations.Drivers.Complete (Item, Kind);
   exception
      when Storage_Error =>
         Flyology.Bytes.Clear (Item.Final_Value);
         Flyology.Bytes.Clear (Value);
         Item.Final_Result := Capacity_Exceeded;
         Item.Has_Final_Result := True;
         if Item.Driver_State /= null then
            Item.Driver_State.Phase := Get_Terminal;
         end if;
         Release_Get_Lease (Item);
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Succeeded);
   end Complete_Get;

   procedure Fail_Get
     (Item  : in out Get_Operation;
      Error : Ada.Exceptions.Exception_Occurrence)
   is
      Empty : Flyology.Bytes.Unbounded_Bytes;
   begin
      if Ada.Exceptions.Exception_Identity (Error) = Storage_Error'Identity then
         Complete_Get (Item, Capacity_Exceeded, Empty);
         return;
      end if;
      Item.Has_Saved_Error := True;
      Ada.Exceptions.Save_Occurrence (Item.Saved_Error, Error);
      Complete_Get
        (Item, Storage_Failure, Empty, Flyology.Operations.Failed);
   exception
      when others =>
         Release_Get_Lease (Item);
         if Flyology.Operations.Is_Active (Item) then
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Failed);
         end if;
   end Fail_Get;

   procedure Copy_Get_Checkpoint_Runs
     (State  : not null Engine_State_Access;
      Family : Column_Family_Configuration;
      Runs   : out Lazy_SST_Run_Array_Access;
      Result : out Outcome_Code)
   is
      Manifest    : constant LSM_Runtime.Checkpoint_Manifest_Access := State.Checkpoint_Manifest;
      Family_Slot : Natural := 0;
   begin
      Runs := null;
      if Manifest = null then
         Result := Not_Found;
         return;
      end if;
      for Index in Manifest.Families'Range loop
         if Manifest.Base.Families (Index).ID = Interfaces.Unsigned_32 (Family.ID) then
            Family_Slot := Index;
            exit;
         end if;
      end loop;
      if Family_Slot = 0 then
         Result := Corrupt;
         return;
      end if;
      declare
         Family_State : LSM_Runtime.Family_LSM_State renames Manifest.Families (Family_Slot);
      begin
         if Family_State.Run_Total = 0 then
            Result := Not_Found;
            return;
         elsif Family_State.First_Run = 0
           or else Family_State.First_Run > Manifest.Run_Total
           or else Family_State.Run_Total > Manifest.Run_Total - Family_State.First_Run + 1
         then
            Result := Corrupt;
            return;
         end if;
         Allocation_Faults.Check (Get_Run_Descriptor_Allocation);
         Runs := new Lazy_SST_Run_Array (1 .. Family_State.Run_Total);
         for Offset in Natural range 0 .. Family_State.Run_Total - 1 loop
            declare
               Descriptor : LSM_Runtime.Run_Descriptor renames
                 Manifest.Runs (Family_State.First_Run + Offset);
            begin
               Runs (Offset + 1) :=
                 (Run_ID                => To_Identifier (Descriptor.Run_ID),
                  Lowest_Sequence       => Sequence_Number (Descriptor.Lowest_Sequence),
                  Highest_Sequence      => Sequence_Number (Descriptor.Highest_Sequence),
                  Entry_Total           => Descriptor.Entry_Total,
                  Logical_Payload_Bytes => Descriptor.Logical_Payload_Bytes);
            end;
         end loop;
      end;
      Result := Success;
   exception
      when Storage_Error =>
         Free_Lazy_SST_Run_Array (Runs);
         Result := Capacity_Exceeded;
   end Copy_Get_Checkpoint_Runs;

   procedure Prepare_Get
     (Operation : in out Get_Operation;
      Family    : Column_Family;
      Item_Key  : Byte_Array)
   is
      State         : Get_Driver_State renames Operation.Driver_State.all;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      Image         : Shared_Image_Access;
      Value_Offset  : Natural;
      Value_Length  : Natural;
      Matched       : Boolean;
      Lookup_Result : Outcome_Code;
   begin
      Operation.Item.Life.Acquire (Operation.Retained_State, State.Precheck_Result);
      if State.Precheck_Result /= Success then
         return;
      end if;
      Operation.Retained_Life := Operation.Item.Life'Unchecked_Access;
      if Operation.Retained_State.Storage = null
        or else Operation.Retained_State.Storage.HTTP_Client = null
        or else Operation.Retained_State.Storage.Client_Identity = null
      then
         State.Precheck_Result := Invalid_State;
         return;
      elsif not Operation.Txn.Active or else Operation.Txn.Owner.Arena = null then
         State.Precheck_Result := Invalid_State;
         return;
      end if;
      Operation.Retained_State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Operation.Txn.Database_ID /= Head.Database_ID
        or else Operation.Txn.Incarnation
                  /= Operation.Retained_State.Gate.Current_Incarnation
      then
         State.Precheck_Result := Invalid_State;
         return;
      end if;
      State.Database_ID := Head.Database_ID;
      State.Incarnation := Operation.Txn.Incarnation;
      State.Transaction_ID := Operation.Txn.Transaction_ID;
      State.Snapshot_At := Operation.Txn.Snapshot_At;
      State.Mutation_Version := Operation.Txn.Owner.Arena.Mutation_Version;
      State.Transaction_Captured := True;
      if Uncertain then
         State.Precheck_Result := Outcome_Unknown;
         return;
      elsif Fenced then
         State.Precheck_Result := Stale_Writer;
         return;
      end if;
      Operation.Retained_State.Gate.Validate_Family
        (Family, State.Family, State.Precheck_Result);
      if State.Precheck_Result /= Success then
         return;
      elsif Interfaces.Unsigned_64 (Item_Key'Length) > State.Family.Max_Key_Bytes then
         State.Precheck_Result := Capacity_Exceeded;
         return;
      end if;
      Flyology.Bytes.Reserve_Capacity (State.Item_Key, Item_Key'Length);
      for Value of Item_Key loop
         Flyology.Bytes.Append (State.Item_Key, Ada.Streams.Stream_Element (Value));
      end loop;

      for Index in reverse Positive range 1 .. Operation.Txn.Owner.Arena.Count loop
         declare
            Mutation : Owned_Mutation renames Operation.Txn.Owner.Arena.Mutations (Index);
         begin
            if Mutation.Family = State.Family.ID and then Same_Owned_Key (Mutation, Item_Key) then
               State.Has_Local_Result := True;
               State.Local_Result :=
                 (if Mutation.Operation = Delete_Mutation then Not_Found else Success);
               if State.Local_Result = Success then
                  Flyology.Bytes.Reserve_Capacity
                    (Operation.Final_Value, Mutation.Value_Length);
                  for Offset in Positive range 1 .. Mutation.Value_Length loop
                     Flyology.Bytes.Append
                       (Operation.Final_Value,
                        Flyology.Bytes.Element
                          (Mutation.Payload, Mutation.Key_Length + Offset));
                  end loop;
               end if;
               return;
            end if;
         end;
      end loop;

      Operation.Retained_State.Gate.Lookup_At
        (State.Family.ID,
         Item_Key,
         State.Snapshot_At,
         null,
         Image,
         Value_Offset,
         Value_Length,
         Matched,
         Lookup_Result);
      if Lookup_Result = Success and then Matched then
         State.Needs_Observation := Operation.Txn.Isolation = Serializable;
         State.Has_Local_Result := True;
         State.Local_Result := Success;
         Flyology.Bytes.Reserve_Capacity (Operation.Final_Value, Value_Length);
         for Offset in Positive range 1 .. Value_Length loop
            Flyology.Bytes.Append
              (Operation.Final_Value,
               Flyology.Bytes.Element (Image.Data, Value_Offset + Offset));
         end loop;
         return;
      elsif Lookup_Result = Not_Found and then Matched then
         State.Needs_Observation := Operation.Txn.Isolation = Serializable;
         State.Has_Local_Result := True;
         State.Local_Result := Not_Found;
         return;
      elsif Lookup_Result /= Not_Found then
         State.Precheck_Result := Lookup_Result;
         return;
      end if;

      State.Needs_Observation := Operation.Txn.Isolation = Serializable;
      Copy_Get_Checkpoint_Runs
        (Operation.Retained_State, State.Family, State.Runs, Lookup_Result);
      if Lookup_Result = Not_Found then
         State.Has_Local_Result := True;
         State.Local_Result := Not_Found;
      elsif Lookup_Result /= Success then
         State.Precheck_Result := Lookup_Result;
      else
         Allocation_Faults.Check (Get_Child_Operation_Allocation);
         Operation.Child :=
           new Lazy_Checkpoint_Read_Operation
             (Operation.Set.all'Unchecked_Access,
              Operation.Retained_State.Storage,
              Operation.Retained_State.Storage.HTTP_Client,
              Operation.Payload_Pool.all'Unchecked_Access,
              (if Operation.Cancellation = null
               then null
               else Operation.Cancellation.all'Unchecked_Access));
      end if;
   exception
      when Storage_Error =>
         State.Precheck_Result := Capacity_Exceeded;
   end Prepare_Get;

   procedure Start_Get_Child (Item : in out Get_Operation) is
      State   : Get_Driver_State renames Item.Driver_State.all;
      Raw_Key : constant Ada.Streams.Stream_Element_Array :=
        Flyology.Bytes.To_Array (State.Item_Key);
      Key     : Byte_Array (1 .. Raw_Key'Length);
   begin
      for Index in Key'Range loop
         Key (Index) := Byte (Raw_Key (Ada.Streams.Stream_Element_Offset (Index)));
      end loop;
      State.Phase := Get_Reading_Checkpoint;
      Read_Lazy_Checkpoint_Entry
        (State.Database_ID,
         State.Family,
         State.Runs.all,
         State.Snapshot_At,
         Key,
         Item.Payload,
         Remaining_Time (Item.Deadline),
         Item.Child.all);
      Flyology.Operations.Continue_After (Item, Item.Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         declare
            Empty : Flyology.Bytes.Unbounded_Bytes;
         begin
            Complete_Get (Item, Capacity_Exceeded, Empty);
         end;
      when Error : others =>
         Fail_Get (Item, Error);
   end Start_Get_Child;

   procedure Complete_Get_Child (Item : in out Get_Operation) is
      Disposition : Lazy_SST_Entry_Disposition;
      Sequence    : Sequence_Number;
      Value       : Flyology.Bytes.Unbounded_Bytes;
      Result      : Outcome_Code;
   begin
      begin
         Finish_Lazy_Checkpoint_Read
           (Item.Child.all,
            Disposition,
            Sequence,
            Value,
            Result,
            Item.Payload);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Child.all)
            then
               Flyology.Operations.Release (Item.Child.all);
            end if;
            Fail_Get (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Child.all);
      if Result = Success and then Disposition = Lazy_Value_Found then
         Complete_Get (Item, Success, Value);
      elsif Result = Not_Found
        and then Disposition in Lazy_Tombstone_Found | Lazy_Key_Absent
      then
         Complete_Get (Item, Not_Found, Value);
      elsif Result in Success | Not_Found then
         Complete_Get (Item, Corrupt, Value);
      else
         Complete_Get (Item, Result, Value);
      end if;
   exception
      when Error : others =>
         Fail_Get (Item, Error);
   end Complete_Get_Child;

   overriding procedure Drive
     (Item : in out Get_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      if Event = Flyology.Operations.Start_Operation then
         if Item.Driver_State.Precheck_Result /= Success then
            declare
               Empty : Flyology.Bytes.Unbounded_Bytes;
            begin
               Complete_Get (Item, Item.Driver_State.Precheck_Result, Empty);
            end;
         elsif Item.Cancellation /= null and then Item.Cancellation.Requested then
            declare
               Empty : Flyology.Bytes.Unbounded_Bytes;
            begin
               Complete_Get
                 (Item, Cancelled, Empty, Flyology.Operations.Cancelled);
            end;
         elsif Item.Deadline <= Ada.Real_Time.Clock then
            declare
               Empty : Flyology.Bytes.Unbounded_Bytes;
            begin
               Complete_Get (Item, Timed_Out, Empty);
            end;
         elsif Item.Driver_State.Has_Local_Result then
            declare
               Value : Flyology.Bytes.Unbounded_Bytes;
            begin
               Flyology.Bytes.Move (Value, Item.Final_Value);
               Complete_Get
                 (Item,
                  Item.Driver_State.Local_Result,
                  Value);
            end;
         else
            Start_Get_Child (Item);
         end if;
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Get_Reading_Checkpoint
        and then Item.Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Child.all)
      then
         Complete_Get_Child (Item);
      else
         raise Program_Error with "invalid Get driver event";
      end if;
   exception
      when Error : others =>
         if Flyology.Operations.Is_Active (Item) then
            Fail_Get (Item, Error);
         end if;
   end Drive;

   overriding procedure Request_Cancellation (Item : in out Get_Operation) is
   begin
      if Item.Child /= null and then Flyology.Operations.Is_Active (Item.Child.all) then
         Flyology.Operations.Cancel (Item.Child.all);
      elsif Item.Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Get_Reading_Checkpoint
      then
         Complete_Get_Child (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Flyology.Operations.Is_Active (Item) then
         declare
            Empty : Flyology.Bytes.Unbounded_Bytes;
         begin
            Complete_Get
              (Item, Cancelled, Empty, Flyology.Operations.Cancelled);
         end;
      end if;
   exception
      when others =>
         Release_Get_Lease (Item);
         if Flyology.Operations.Is_Active (Item) then
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Failed);
         end if;
   end Request_Cancellation;

   procedure Get
     (Family         : Column_Family;
      Item_Key       : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Get_Operation)
   is
      Started : Boolean := False;
      Moved   : Boolean := False;
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "Get payload belongs to a different pool";
      elsif Flyology.Buffers.Has_Buffer (Operation.Payload)
        or else Operation.Driver_State /= null
        or else Operation.Child /= null
        or else Operation.Retained_Life /= null
      then
         raise Program_Error with "Get operation retains unconsumed ownership";
      end if;
      Operation.Deadline := Deadline_After (Timeout);
      Flyology.Bytes.Clear (Operation.Final_Value);
      Operation.Final_Result := Invalid_State;
      Operation.Has_Final_Result := False;
      Operation.Has_Saved_Error := False;
      begin
         Allocation_Faults.Check (Get_Operation_State_Allocation);
         Operation.Driver_State := new Get_Driver_State;
      exception
         when Storage_Error =>
            Operation.Driver_State := null;
      end;
      if Operation.Driver_State /= null then
         Prepare_Get (Operation, Family, Item_Key);
      end if;
      Flyology.Operations.Drivers.Start (Operation);
      Started := True;
      Flyology.Buffers.Move (Payload_Buffer, Operation.Payload);
      Moved := True;
      if Operation.Driver_State = null then
         Operation.Final_Result := Capacity_Exceeded;
         Operation.Has_Final_Result := True;
         Flyology.Operations.Drivers.Complete
           (Operation, Flyology.Operations.Succeeded);
      else
         Flyology.Operations.Drive
           (Flyology.Operations.Operation'Class (Operation),
            Flyology.Operations.Start_Operation);
      end if;
   exception
      when others =>
         if Moved and then Flyology.Buffers.Has_Buffer (Operation.Payload) then
            Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
         end if;
         if Started and then Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         Release_Get_Lease (Operation);
         Release_Get_State (Operation);
         Flyology.Bytes.Clear (Operation.Final_Value);
         raise;
   end Get;

   procedure Finish
     (Operation      : in out Get_Operation;
      Data           : out Flyology.Bytes.Unbounded_Bytes;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
   is
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "Get Finish requires the moved token's pool";
      elsif Flyology.Buffers.Has_Buffer (Payload_Buffer) then
         raise Program_Error with "Get Finish requires a vacant same-pool handle";
      end if;
      Flyology.Bytes.Clear (Data);
      Result := Invalid_State;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
      Release_Get_Lease (Operation);
      Release_Get_State (Operation);
      if Operation.Has_Saved_Error then
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity (Operation.Saved_Error),
            Ada.Exceptions.Exception_Message (Operation.Saved_Error));
      elsif not Operation.Has_Final_Result then
         raise Program_Error with "Get operation has no terminal result";
      end if;
      Result := Operation.Final_Result;
      if Result = Success then
         Flyology.Bytes.Move (Data, Operation.Final_Value);
      else
         Flyology.Bytes.Clear (Operation.Final_Value);
      end if;
   end Finish;

   procedure Get
     (Item           : in out Database;
      Txn            : aliased in out Transaction;
      Family         : Column_Family;
      Item_Key       : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Token          : access Flyology.Cancellation.Token := null;
      Data           : out Flyology.Bytes.Unbounded_Bytes;
      Result         : out Outcome_Code)
   is
      --  One public DB parent plus the established six-slot private selector
      --  stack is the exact synchronous owner geometry. This is derived
      --  scheduling capacity, not a public queue or persisted DB limit.
      Synchronous_Get_Set_Capacity : constant := 7;
      Set : aliased Flyology.Operations.Completion_Set (Synchronous_Get_Set_Capacity);
      Operation : Get_Operation
        (Set'Access,
         Item'Unchecked_Access,
         Txn'Unchecked_Access,
         Payload_Buffer.Owner,
         Token);
   begin
      Get (Family, Item_Key, Payload_Buffer, Timeout, Operation);
      Flyology.Operations.Wait_All (Set);
      Finish (Operation, Data, Result, Payload_Buffer);
      Flyology.Operations.Release (Operation);
   exception
      when others =>
         Flyology.Bytes.Clear (Data);
         raise;
   end Get;

   overriding procedure Finalize (Item : in out Get_Operation) is
   begin
      begin
         Flyology.Operations.Finalize
           (Flyology.Operations.Operation (Item));
      exception
         when others =>
            null;
      end;
      Release_Get_Lease (Item);
      Release_Get_State (Item);
      Flyology.Buffers.Release (Item.Payload);
   end Finalize;

   procedure Release_Scan_Lease (Item : in out Scan_Operation) is
   begin
      if Item.Retained_Life /= null then
         Item.Retained_Life.Release;
         Item.Retained_Life := null;
         Item.Retained_State := null;
      end if;
   end Release_Scan_Lease;

   procedure Release_Scan_State (Item : in out Scan_Operation) is
   begin
      if Item.Driver_State /= null then
         Free_Lazy_SST_Run_Array (Item.Driver_State.Runs);
         if Item.Driver_State.Loaded /= null then
            for Run of Item.Driver_State.Loaded.all loop
               LSM_Runtime.Release (Run.Table);
               Release_Image (Run.Image);
            end loop;
            Free_Scan_Loaded_Run_Array (Item.Driver_State.Loaded);
         end if;
         Free_Scan_Cursor_Bytes (Item.Driver_State.Lower);
         Free_Scan_Cursor_Bytes (Item.Driver_State.Upper);
         Free_Scan_Driver_State (Item.Driver_State);
      end if;
      if Item.Child /= null then
         Free_Lazy_SST_Read_Operation (Item.Child);
      end if;
   end Release_Scan_State;

   procedure Complete_Scan
     (Item   : in out Scan_Operation;
      Result : Outcome_Code;
      Kind   : Flyology.Operations.Terminal_Outcome := Flyology.Operations.Succeeded)
   is
      Final_Result : Outcome_Code := Result;
   begin
      if Item.Driver_State = null then
         Final_Result := Capacity_Exceeded;
      elsif Item.Driver_State.Transaction_Captured
        and then (not Item.Txn.Active
                  or else Item.Txn.Owner.Arena = null
                  or else Item.Txn.Database_ID /= Item.Driver_State.Database_ID
                  or else Item.Txn.Incarnation /= Item.Driver_State.Incarnation
                  or else Item.Txn.Transaction_ID /= Item.Driver_State.Transaction_ID
                  or else Item.Txn.Snapshot_At /= Item.Driver_State.Snapshot_At
                  or else Item.Txn.Owner.Arena.Mutation_Version /= Item.Driver_State.Mutation_Version)
      then
         Final_Result := Invalid_State;
      end if;
      if Final_Result /= Success then
         Release_Scan_Cursor (Item.Candidate_Cursor.Owner.State);
      end if;
      if Item.Driver_State /= null then
         Item.Driver_State.Phase := Scan_Terminal;
      end if;
      Item.Final_Result := Final_Result;
      Item.Has_Final_Result := True;
      Release_Scan_Lease (Item);
      Flyology.Operations.Drivers.Complete (Item, Kind);
   end Complete_Scan;

   procedure Fail_Scan (Item : in out Scan_Operation; Error : Ada.Exceptions.Exception_Occurrence) is
   begin
      if Ada.Exceptions.Exception_Identity (Error) = Storage_Error'Identity then
         Complete_Scan (Item, Capacity_Exceeded);
         return;
      end if;
      Item.Has_Saved_Error := True;
      Ada.Exceptions.Save_Occurrence (Item.Saved_Error, Error);
      Complete_Scan (Item, Storage_Failure, Flyology.Operations.Failed);
   exception
      when others =>
         Release_Scan_Lease (Item);
         if Flyology.Operations.Is_Active (Item) then
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         end if;
   end Fail_Scan;

   procedure Build_Authenticated_Scan_Cursor (Item : in out Scan_Operation) is
      State  : Scan_Driver_State renames Item.Driver_State.all;
      Family : constant Column_Family :=
        (Valid         => True,
         Database_ID   => State.Database_ID,
         Incarnation   => State.Incarnation,
         Configuration => State.Family);
      Result : Outcome_Code;

      procedure Build (Lower, Upper : Byte_Array) is
      begin
         Build_Scan_Cursor
           (Item.Item.all,
            Item.Txn.all,
            Family,
            State.Has_Lower,
            Lower,
            State.Has_Upper,
            Upper,
            State.Loaded,
            Item.Retained_State,
            Item.Candidate_Cursor,
            Result);
      end Build;
   begin
      if State.Has_Lower and then State.Has_Upper then
         Build (State.Lower.all, State.Upper.all);
      elsif State.Has_Lower then
         Build (State.Lower.all, [1 .. 0 => 0]);
      elsif State.Has_Upper then
         Build ([1 .. 0 => 0], State.Upper.all);
      else
         Build ([1 .. 0 => 0], [1 .. 0 => 0]);
      end if;
      Complete_Scan (Item, Result);
   exception
      when Error : others =>
         Fail_Scan (Item, Error);
   end Build_Authenticated_Scan_Cursor;

   procedure Start_Next_Scan_Run (Item : in out Scan_Operation) is
      State : Scan_Driver_State renames Item.Driver_State.all;
   begin
      if Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Scan (Item, Cancelled, Flyology.Operations.Cancelled);
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Scan (Item, Timed_Out);
      elsif State.Runs = null or else State.Current_Run = State.Runs'Last then
         Build_Authenticated_Scan_Cursor (Item);
      else
         State.Current_Run := State.Current_Run + 1;
         declare
            Run : Lazy_SST_Run_Descriptor renames State.Runs (State.Current_Run);
         begin
            Read_Lazy_SST
              (State.Database_ID,
               State.Family,
               Run.Run_ID,
               Run.Lowest_Sequence,
               Run.Highest_Sequence,
               Run.Entry_Total,
               Run.Logical_Payload_Bytes,
               Item.Payload,
               Remaining_Time (Item.Deadline),
               Item.Child.all);
         end;
         State.Phase := Scan_Reading_Run;
         Flyology.Operations.Continue_After (Item, Item.Child.all);
      end if;
   exception
      when Flyology.Operations.Capacity_Error =>
         Complete_Scan (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Scan (Item, Error);
   end Start_Next_Scan_Run;

   procedure Complete_Scan_Run (Item : in out Scan_Operation) is
      State  : Scan_Driver_State renames Item.Driver_State.all;
      Table  : LSM_Runtime.SST_Access := null;
      Result : Outcome_Code;
      Image  : Shared_Image_Access := null;
   begin
      begin
         Finish_Lazy_SST_Read (Item.Child.all, Table, Result, Item.Payload);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Child.all)
            then
               Flyology.Operations.Release (Item.Child.all);
            end if;
            Fail_Scan (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Child.all);
      if Result /= Success then
         LSM_Runtime.Release (Table);
         Complete_Scan (Item, Result);
         return;
      elsif Table = null or else State.Loaded = null or else State.Current_Run not in State.Loaded'Range then
         LSM_Runtime.Release (Table);
         Complete_Scan (Item, Corrupt);
         return;
      end if;
      Image := New_Image (Table.Payload);
      State.Loaded (State.Current_Run) := (Table => Table, Image => Image);
      Table := null;
      Image := null;
      State.Phase := Scan_Idle;
      Flyology.Operations.Drivers.Reschedule (Item);
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Table);
         Release_Image (Image);
         Complete_Scan (Item, Capacity_Exceeded);
      when Error : others =>
         LSM_Runtime.Release (Table);
         Release_Image (Image);
         Fail_Scan (Item, Error);
   end Complete_Scan_Run;

   overriding
   procedure Drive (Item : in out Scan_Operation; Event : Flyology.Operations.Driver_Event) is
   begin
      if Event = Flyology.Operations.Start_Operation
        or else (Event = Flyology.Operations.Continue_Operation
                 and then Item.Driver_State /= null
                 and then Item.Driver_State.Phase = Scan_Idle)
      then
         Start_Next_Scan_Run (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Scan_Reading_Run
        and then Item.Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Child.all)
      then
         Complete_Scan_Run (Item);
      else
         raise Program_Error with "invalid scan driver event";
      end if;
   exception
      when Error : others =>
         if Flyology.Operations.Is_Active (Item) then
            Fail_Scan (Item, Error);
         end if;
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Scan_Operation) is
   begin
      if Item.Child /= null and then Flyology.Operations.Is_Active (Item.Child.all) then
         Flyology.Operations.Cancel (Item.Child.all);
      elsif Item.Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Scan_Reading_Run
      then
         Complete_Scan_Run (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Flyology.Operations.Is_Active (Item) then
         Complete_Scan (Item, Cancelled, Flyology.Operations.Cancelled);
      end if;
   exception
      when others =>
         Release_Scan_Lease (Item);
         if Flyology.Operations.Is_Active (Item) then
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         end if;
   end Request_Cancellation;

   procedure Prepare_Scan
     (Operation : in out Scan_Operation;
      Family    : Column_Family;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array)
   is
      State      : Scan_Driver_State renames Operation.Driver_State.all;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Uncertain  : Boolean;
      Fenced     : Boolean;
      Run_Result : Outcome_Code;
   begin
      Operation.Item.Life.Acquire (Operation.Retained_State, State.Precheck_Result);
      if State.Precheck_Result /= Success then
         return;
      end if;
      Operation.Retained_Life := Operation.Item.Life'Unchecked_Access;
      if Operation.Retained_State.Storage = null
        or else Operation.Retained_State.Storage.HTTP_Client = null
        or else Operation.Retained_State.Storage.Client_Identity = null
      then
         State.Precheck_Result := Invalid_State;
         return;
      elsif not Operation.Txn.Active or else Operation.Txn.Owner.Arena = null then
         State.Precheck_Result := Invalid_State;
         return;
      end if;
      Operation.Retained_State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Operation.Txn.Database_ID /= Head.Database_ID
        or else Operation.Txn.Incarnation /= Operation.Retained_State.Gate.Current_Incarnation
      then
         State.Precheck_Result := Invalid_State;
         return;
      end if;
      State.Database_ID := Head.Database_ID;
      State.Incarnation := Operation.Txn.Incarnation;
      State.Transaction_ID := Operation.Txn.Transaction_ID;
      State.Snapshot_At := Operation.Txn.Snapshot_At;
      State.Mutation_Version := Operation.Txn.Owner.Arena.Mutation_Version;
      State.Transaction_Captured := True;
      if Uncertain then
         State.Precheck_Result := Outcome_Unknown;
         return;
      elsif Fenced then
         State.Precheck_Result := Stale_Writer;
         return;
      end if;
      Operation.Retained_State.Gate.Validate_Family (Family, State.Family, State.Precheck_Result);
      if State.Precheck_Result /= Success then
         return;
      elsif (Has_Lower and then Interfaces.Unsigned_64 (Lower'Length) > State.Family.Max_Key_Bytes)
        or else (Has_Upper and then Interfaces.Unsigned_64 (Upper'Length) > State.Family.Max_Key_Bytes)
      then
         State.Precheck_Result := Capacity_Exceeded;
         return;
      elsif Has_Lower and then Has_Upper and then Compare_Bytes (Lower, Upper) /= Before then
         State.Precheck_Result := Invalid_State;
         return;
      end if;
      State.Has_Lower := Has_Lower;
      State.Has_Upper := Has_Upper;
      if Has_Lower then
         Allocation_Faults.Check (Scan_Cursor_Lower_Allocation);
         State.Lower := new Byte_Array'(Lower);
      end if;
      if Has_Upper then
         Allocation_Faults.Check (Scan_Cursor_Upper_Allocation);
         State.Upper := new Byte_Array'(Upper);
      end if;
      Copy_Get_Checkpoint_Runs (Operation.Retained_State, State.Family, State.Runs, Run_Result);
      if Run_Result = Not_Found then
         State.Runs := null;
      elsif Run_Result /= Success then
         State.Precheck_Result := Run_Result;
         return;
      else
         Allocation_Faults.Check (Scan_Run_Array_Allocation);
         State.Loaded := new Scan_Loaded_Run_Array'(State.Runs'Range => (others => <>));
         Allocation_Faults.Check (Scan_Child_Operation_Allocation);
         Operation.Child :=
           new Lazy_SST_Read_Operation
                 (Operation.Set.all'Unchecked_Access,
                  Operation.Retained_State.Storage,
                  Operation.Retained_State.Storage.HTTP_Client,
                  Operation.Payload_Pool.all'Unchecked_Access,
                  (if Operation.Cancellation = null
                   then null
                   else Operation.Cancellation.all'Unchecked_Access));
      end if;
   exception
      when Storage_Error =>
         State.Precheck_Result := Capacity_Exceeded;
   end Prepare_Scan;

   procedure Start_Scan
     (Family         : Column_Family;
      Has_Lower      : Boolean;
      Lower          : Byte_Array;
      Has_Upper      : Boolean;
      Upper          : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Scan_Operation)
   is
      Started : Boolean := False;
      Moved   : Boolean := False;
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "scan payload belongs to a different pool";
      elsif Flyology.Buffers.Has_Buffer (Operation.Payload)
        or else Operation.Driver_State /= null
        or else Operation.Child /= null
        or else Operation.Retained_Life /= null
        or else Operation.Candidate_Cursor.Owner.State /= null
      then
         raise Program_Error with "scan operation retains unconsumed ownership";
      end if;
      Operation.Deadline := Deadline_After (Timeout);
      Operation.Final_Result := Invalid_State;
      Operation.Has_Final_Result := False;
      Operation.Has_Saved_Error := False;
      begin
         Allocation_Faults.Check (Scan_Operation_State_Allocation);
         Operation.Driver_State := new Scan_Driver_State;
      exception
         when Storage_Error =>
            null;
      end;
      if Operation.Driver_State /= null then
         Prepare_Scan (Operation, Family, Has_Lower, Lower, Has_Upper, Upper);
      end if;
      Flyology.Operations.Drivers.Start (Operation);
      Started := True;
      Flyology.Buffers.Move (Payload_Buffer, Operation.Payload);
      Moved := True;
      if Operation.Driver_State = null then
         Operation.Final_Result := Capacity_Exceeded;
         Operation.Has_Final_Result := True;
         Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);
      elsif Operation.Driver_State.Precheck_Result /= Success then
         Complete_Scan (Operation, Operation.Driver_State.Precheck_Result);
      else
         Flyology.Operations.Drive
           (Flyology.Operations.Operation'Class (Operation), Flyology.Operations.Start_Operation);
      end if;
   exception
      when others =>
         if Moved and then Flyology.Buffers.Has_Buffer (Operation.Payload) then
            Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
         end if;
         if Started and then Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         Release_Scan_Lease (Operation);
         Release_Scan_State (Operation);
         Release_Scan_Cursor (Operation.Candidate_Cursor.Owner.State);
         raise;
   end Start_Scan;

   procedure Finish
     (Operation      : in out Scan_Operation;
      Cursor         : in out Scan_Cursor;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer) is
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "scan Finish requires the moved token's pool";
      elsif Flyology.Buffers.Has_Buffer (Payload_Buffer) then
         raise Program_Error with "scan Finish requires a vacant same-pool handle";
      end if;
      Result := Invalid_State;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
      Release_Scan_Lease (Operation);
      Release_Scan_State (Operation);
      if Operation.Has_Saved_Error then
         Release_Scan_Cursor (Operation.Candidate_Cursor.Owner.State);
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity (Operation.Saved_Error),
            Ada.Exceptions.Exception_Message (Operation.Saved_Error));
      elsif not Operation.Has_Final_Result then
         Release_Scan_Cursor (Operation.Candidate_Cursor.Owner.State);
         raise Program_Error with "scan operation has no terminal result";
      end if;
      Result := Operation.Final_Result;
      if Result = Success then
         declare
            Previous : constant Scan_Cursor_State_Access := Cursor.Owner.State;
         begin
            Cursor.Owner.State := Operation.Candidate_Cursor.Owner.State;
            Operation.Candidate_Cursor.Owner.State := Previous;
         end;
      end if;
      Release_Scan_Cursor (Operation.Candidate_Cursor.Owner.State);
   end Finish;

   procedure Start_Scan
     (Item           : in out Database;
      Txn            : aliased in out Transaction;
      Family         : Column_Family;
      Has_Lower      : Boolean;
      Lower          : Byte_Array;
      Has_Upper      : Boolean;
      Upper          : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Token          : access Flyology.Cancellation.Token := null;
      Cursor         : in out Scan_Cursor;
      Result         : out Outcome_Code)
   is
      --  The public DB parent plus the private whole-run reader and its
      --  provider/HTTP/transport stack need six exact owner slots. This is
      --  derived scheduling geometry, not a persisted or public capacity.
      Synchronous_Scan_Set_Capacity : constant := 6;
      Set                           :
        aliased Flyology.Operations.Completion_Set (Synchronous_Scan_Set_Capacity);
      Operation                     :
        Scan_Operation (Set'Access, Item'Unchecked_Access, Txn'Unchecked_Access, Payload_Buffer.Owner, Token);
   begin
      Start_Scan (Family, Has_Lower, Lower, Has_Upper, Upper, Payload_Buffer, Timeout, Operation);
      Flyology.Operations.Wait_All (Set);
      Finish (Operation, Cursor, Result, Payload_Buffer);
      Flyology.Operations.Release (Operation);
   end Start_Scan;

   procedure Scan
     (Item           : in out Database;
      Txn            : aliased in out Transaction;
      Family         : Column_Family;
      Has_Lower      : Boolean;
      Lower          : Byte_Array;
      Has_Upper      : Boolean;
      Upper          : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Token          : access Flyology.Cancellation.Token := null;
      Rows           : in out Scan_Result;
      Result         : out Outcome_Code)
   is
      Cursor : Scan_Cursor;
      Done   : Boolean;
   begin
      Start_Scan
        (Item,
         Txn,
         Family,
         Has_Lower,
         Lower,
         Has_Upper,
         Upper,
         Payload_Buffer,
         Timeout,
         Token,
         Cursor,
         Result);
      if Result /= Success then
         return;
      end if;
      declare
         State : constant Scan_Cursor_State_Access := Cursor.Owner.State;
      begin
         if State = null then
            Result := Corrupt;
            return;
         end if;
         Continue_Scan_Page
           (Item,
            Txn,
            Cursor,
            State.Maximum_Rows,
            State.Maximum_Bytes,
            Require_Complete => True,
            Rows             => Rows,
            Done             => Done,
            Result           => Result);
      end;
   end Scan;

   overriding
   procedure Finalize (Item : in out Scan_Operation) is
   begin
      begin
         Flyology.Operations.Finalize (Flyology.Operations.Operation (Item));
      exception
         when others =>
            null;
      end;
      Release_Scan_Lease (Item);
      Release_Scan_State (Item);
      Release_Scan_Cursor (Item.Candidate_Cursor.Owner.State);
      Flyology.Buffers.Release (Item.Payload);
   end Finalize;

   procedure Start_Next_Selected_Head (Item : in out Flush_Operation);

   procedure Complete_Selected_Plan (Item : in out Flush_Operation) is
      State        : Flush_Driver_State renames Item.Driver_State.all;
      Family_Index : Natural := 0;
      Result       : Outcome_Code;
   begin
      Complete_Selected_Merge_Plan
        (State.Engine,
         State.Older_Run_ID,
         State.Middle_Run_ID,
         State.Newer_Run_ID,
         State.Output_Run_ID,
         State.Selected_Base,
         State.Selected_Head,
         State.Selected_Source,
         State.Plan,
         Result);
      if Result /= Success then
         Complete_Composable_Flush (Item, Result);
         return;
      end if;
      for Index in State.Plan.SSTs'Range loop
         if State.Plan.SSTs (Index) /= null then
            if Family_Index /= 0 then
               Complete_Composable_Flush (Item, Corrupt);
               return;
            end if;
            Family_Index := Index;
         end if;
      end loop;
      if Family_Index = 0 then
         Complete_Composable_Flush (Item, Corrupt);
         return;
      end if;
      State.Run_Total := 1;
      State.Runs (1) :=
        (Family_ID => Column_Family_ID (State.Plan.Manifest.Base.Families (Family_Index).ID),
         Run_ID    => State.Output_Run_ID);
      Initialize_Flush_Receipt
        (State.Engine,
         State.Plan,
         State.Runs (1 .. 1),
         State.Manifest_ID,
         State.Transition_ID,
         Item.Final_Receipt,
         Result,
         Merge_Older_Run_ID => State.Older_Run_ID,
         Merge_Middle_Run_ID => State.Middle_Run_ID,
         Merge_Newer_Run_ID => State.Newer_Run_ID);
      if Result = Success then
         Prepare_Flush_Images (Item, State, Result);
      end if;
      if Result /= Success then
         Complete_Composable_Flush (Item, Result);
      elsif Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Flush (Item, Cancelled);
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Flush (Item, Timed_Out);
      else
         State.Current_Family_Slot := 0;
         Start_Next_Immutable (Item);
      end if;
   exception
      when Storage_Error =>
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Composable_Flush (Item, Error);
   end Complete_Selected_Plan;

   procedure Start_Selected_Whole (Item : in out Flush_Operation) is
      State : Flush_Driver_State renames Item.Driver_State.all;
      Fault : Storage_Fault_Mode;
   begin
      Consume_Fault (Item.Storage.all, Before_Get, Fault);
      if Fault /= No_Fault then
         Complete_Composable_Flush (Item, Storage_Failure);
         return;
      elsif Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Flush (Item, Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Flush (Item, Timed_Out);
         return;
      elsif Item.Read_Child = null then
         raise Program_Error with "selected-run whole child was not prepared";
      end if;
      Client_Objects.Get_Whole
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Run_Key
           (Item.Storage.all,
            To_Identifier (State.Selected_Source.Manifest.Runs (State.Selected_Run_Index).Run_ID)),
         Item.Payload'Unchecked_Access,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         Expected_Entity_Tag   => Quoted_Generation (State.Selected_Generation),
         Region                => UStrings.To_String (Item.Storage.Client_Region),
         Style                 => Item.Storage.Client_Style,
         Expected_Bucket_Owner => UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
         Request_Payer         => UStrings.To_String (Item.Storage.Client_Request_Payer),
         Checksum_Mode         => Item.Storage.Client_Checksum_Mode,
         Token                 => Item.Cancellation,
         Operation             => Item.Read_Child.all);
      State.Phase := Reading_Selected_Whole;
      Flyology.Operations.Continue_After (Item, Item.Read_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Composable_Flush (Item, Error);
   end Start_Selected_Whole;

   procedure Complete_Selected_Header (Item : in out Flush_Operation) is
      State         : Flush_Driver_State renames Item.Driver_State.all;
      Header_Length : constant Positive :=
        Positive'Min (Selected_SST_Header_Length, State.Selected_Object_Length);
      Outcome       : Client_Objects.Range_Get_Result;
      Image         : LSM_Runtime.Image_Access := null;
      Decode_Status : LSM_Runtime.Decode_Status;
      Generation    : Generation_Value;
      Valid         : Boolean := False;
   begin
      begin
         Client_Objects.Finish (Item.Range_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Range_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Range_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Range_Child.all)
            then
               Flyology.Operations.Release (Item.Range_Child.all);
            end if;
            Fail_Composable_Flush (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Range_Child.all);
      if Outcome.Kind = Client_Objects.Range_Get_Exchange_Failed then
         Complete_Composable_Flush (Item, Selected_Read_Failure (Outcome.Failure));
         return;
      elsif Outcome.Response.Kind = Client_Low_Level.Get_Object_Rejected then
         Complete_Composable_Flush (Item, Selected_Rejection (Outcome.Response.Status));
         return;
      end if;
      Set_Quoted_Generation
        (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
      if not Valid
        or else Generation /= State.Selected_Generation
        --  A complete single-range response is exactly HTTP 206 under the
        --  maintained Object Storage range contract.
        or else Outcome.Response.Status /= 206
        or else not Outcome.Has_Resolved_Range
        or else Outcome.Resolved.First /= 0
        or else Outcome.Resolved.Last /= OS.Byte_Count (Header_Length - 1)
        or else Outcome.Resolved.Total_Length /= OS.Byte_Count (State.Selected_Object_Length)
        or else Flyology.Buffers.Length (Item.Payload) /= Header_Length
      then
         Complete_Composable_Flush (Item, Corrupt);
         return;
      end if;
      Copy_Selected_Payload (Item.Payload, Header_Length, Image);
      Inspect_Compatible_SST_Header
        (Image.all,
         State.Selected_Source.Manifest.Base.Database_ID,
         State.Selected_Source.Manifest.Base.Families (State.Selected_Family_Slot).ID,
         State.Selected_Source.Manifest.Runs (State.Selected_Run_Index),
         Interfaces.Unsigned_64 (State.Selected_Object_Length),
         State.Selected_Admission,
         Decode_Status);
      LSM_Runtime.Release (Image);
      if Decode_Status = LSM_Runtime.Decoded then
         Start_Selected_Whole (Item);
      elsif Decode_Status
            in LSM_Runtime.Limit_Exceeded
             | LSM_Runtime.Allocation_Failed
             | LSM_Runtime.Runtime_Incompatible
      then
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      elsif Decode_Status = LSM_Runtime.Unsupported_Version then
         Complete_Composable_Flush (Item, Unsupported_Format);
      else
         Complete_Composable_Flush (Item, Corrupt);
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      when Error : others =>
         LSM_Runtime.Release (Image);
         Fail_Composable_Flush (Item, Error);
   end Complete_Selected_Header;

   procedure Start_Selected_Header (Item : in out Flush_Operation) is
      State         : Flush_Driver_State renames Item.Driver_State.all;
      Header_Length : constant Positive :=
        Positive'Min (Selected_SST_Header_Length, State.Selected_Object_Length);
   begin
      if Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Flush (Item, Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Flush (Item, Timed_Out);
         return;
      elsif Item.Range_Child = null then
         raise Program_Error with "selected-run range child was not prepared";
      end if;
      Client_Objects.Get_Range
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Run_Key
           (Item.Storage.all,
            To_Identifier (State.Selected_Source.Manifest.Runs (State.Selected_Run_Index).Run_ID)),
         (Kind  => OS.Bounded_Range,
          First => 0,
          Last  => OS.Byte_Count (Header_Length - 1),
          Count => 0),
         Item.Payload'Unchecked_Access,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         Quoted_Generation (State.Selected_Generation),
         Region                => UStrings.To_String (Item.Storage.Client_Region),
         Style                 => Item.Storage.Client_Style,
         Expected_Bucket_Owner => UStrings.To_String (Item.Storage.Expected_Bucket_Owner),
         Request_Payer         => UStrings.To_String (Item.Storage.Client_Request_Payer),
         Checksum_Mode         => Item.Storage.Client_Checksum_Mode,
         Token                 => Item.Cancellation,
         Operation             => Item.Range_Child.all);
      State.Phase := Reading_Selected_Header;
      Flyology.Operations.Continue_After (Item, Item.Range_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Composable_Flush (Item, Error);
   end Start_Selected_Header;

   procedure Complete_Selected_Head (Item : in out Flush_Operation) is
      State      : Flush_Driver_State renames Item.Driver_State.all;
      Outcome    : Client_Objects.Head_Result;
      Generation : Generation_Value;
      Valid      : Boolean := False;
      --  The smallest accepted predecessor remains SST-v1: one entry header
      --  can encode empty key/value bytes before the frozen object trailer.
      Minimum    : constant Natural := Minimum_Compatible_SST_Length;
   begin
      begin
         Client_Objects.Finish (Item.Head_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Head_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Head_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Head_Child.all)
            then
               Flyology.Operations.Release (Item.Head_Child.all);
            end if;
            Fail_Composable_Flush (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Head_Child.all);
      if Outcome.Kind = Client_Objects.Head_Exchange_Failed then
         Complete_Composable_Flush (Item, Selected_Read_Failure (Outcome.Failure));
         return;
      elsif Outcome.Response.Kind = Client_Low_Level.Head_Object_Rejected then
         Complete_Composable_Flush (Item, Selected_Rejection (Outcome.Response.Status));
         return;
      end if;
      Set_Quoted_Generation
        (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
      if not Valid
        --  A complete successful HeadObject is exactly HTTP 200 under the
        --  maintained Object Storage contract.
        or else Outcome.Response.Status /= 200
        or else Outcome.Response.Result.Content_Length > OS.Byte_Count (Natural'Last)
      then
         Complete_Composable_Flush (Item, Corrupt);
         return;
      end if;
      State.Selected_Object_Length := Natural (Outcome.Response.Result.Content_Length);
      State.Selected_Generation := Generation;
      if State.Selected_Object_Length < Minimum then
         Complete_Composable_Flush (Item, Corrupt);
      elsif State.Selected_Object_Length > Flyology.Buffers.Buffer_Capacity (Item.Payload) then
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      else
         Start_Selected_Header (Item);
      end if;
   exception
      when Error : others =>
         Fail_Composable_Flush (Item, Error);
   end Complete_Selected_Head;

   procedure Complete_Selected_Whole (Item : in out Flush_Operation) is
      State         : Flush_Driver_State renames Item.Driver_State.all;
      Outcome       : Client_Objects.Whole_Get_Result;
      Image         : LSM_Runtime.Image_Access := null;
      Decode_Status : LSM_Runtime.Decode_Status;
      Generation    : Generation_Value;
      Valid         : Boolean := False;
   begin
      begin
         Client_Objects.Finish (Item.Read_Child.all, Outcome);
      exception
         when Error : others =>
            if Flyology.Operations.Id (Item.Read_Child.all) /= 0
              and then not Flyology.Operations.Is_Active (Item.Read_Child.all)
              and then not Flyology.Operations.Is_Terminal (Item.Read_Child.all)
            then
               Flyology.Operations.Release (Item.Read_Child.all);
            end if;
            Fail_Composable_Flush (Item, Error);
            return;
      end;
      Flyology.Operations.Release (Item.Read_Child.all);
      if Outcome.Kind = Client_Objects.Whole_Get_Exchange_Failed then
         Complete_Composable_Flush (Item, Selected_Read_Failure (Outcome.Failure));
         return;
      elsif Outcome.Response.Kind = Client_Low_Level.Get_Object_Rejected then
         Complete_Composable_Flush (Item, Selected_Rejection (Outcome.Response.Status));
         return;
      end if;
      Set_Quoted_Generation
        (Generation, UStrings.To_String (Outcome.Response.Result.Entity_Tag), Valid);
      if not Valid
        or else Generation /= State.Selected_Generation
        --  A complete successful whole GetObject is exactly HTTP 200 under
        --  the maintained Object Storage contract.
        or else Outcome.Response.Status /= 200
        or else not Outcome.Response.Result.Content_Length.Is_Set
        or else Outcome.Response.Result.Content_Length.Value /=
          OS.Byte_Count (State.Selected_Admission.Object_Length)
        or else State.Selected_Admission.Object_Length /= State.Selected_Object_Length
        or else Flyology.Buffers.Length (Item.Payload) /= State.Selected_Admission.Object_Length
      then
         Complete_Composable_Flush (Item, Corrupt);
         return;
      end if;
      Copy_Selected_Payload
        (Item.Payload, Positive (State.Selected_Admission.Object_Length), Image);
      Decode_Compatible_SST
        (Image.all,
         State.Selected_Source.Manifest.Base.Database_ID,
         State.Selected_Source.Manifest.Base.Families (State.Selected_Family_Slot).ID,
         State.Selected_Source.Manifest.Runs (State.Selected_Run_Index),
         State.Selected_Source.Manifest.Base.Families (State.Selected_Family_Slot).Max_Key_Bytes,
         State.Selected_Source.Manifest.Base.Families (State.Selected_Family_Slot).Max_Value_Bytes,
         State.Selected_Admission,
         State.Selected_Source.Recovered_SSTs (State.Selected_Run_Index),
         Decode_Status);
      LSM_Runtime.Release (Image);
      if Decode_Status = LSM_Runtime.Decoded then
         Start_Next_Selected_Head (Item);
      elsif Decode_Status
            in LSM_Runtime.Limit_Exceeded
             | LSM_Runtime.Allocation_Failed
             | LSM_Runtime.Runtime_Incompatible
      then
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      elsif Decode_Status = LSM_Runtime.Unsupported_Version then
         Complete_Composable_Flush (Item, Unsupported_Format);
      else
         Complete_Composable_Flush (Item, Corrupt);
      end if;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      when Error : others =>
         LSM_Runtime.Release (Image);
         Fail_Composable_Flush (Item, Error);
   end Complete_Selected_Whole;

   procedure Start_Next_Selected_Head (Item : in out Flush_Operation) is
      State      : Flush_Driver_State renames Item.Driver_State.all;
      Parameters : Client_Low_Level.Head_Object_Parameters := (others => <>);
      Fault      : Storage_Fault_Mode;
   begin
      if State.Selected_Run_Index >= State.Selected_Source.Manifest.Run_Total then
         Complete_Selected_Plan (Item);
         return;
      end if;
      State.Selected_Run_Index := State.Selected_Run_Index + 1;
      State.Selected_Family_Slot := 0;
      for Family_Index in State.Selected_Source.Manifest.Families'Range loop
         declare
            Family : LSM_Runtime.Family_LSM_State renames
              State.Selected_Source.Manifest.Families (Family_Index);
         begin
            if Family.Run_Total > 0
              and then State.Selected_Run_Index in
                Family.First_Run .. Family.First_Run + Family.Run_Total - 1
            then
               State.Selected_Family_Slot := Family_Index;
               exit;
            end if;
         end;
      end loop;
      if State.Selected_Family_Slot = 0 then
         Complete_Composable_Flush (Item, Corrupt);
         return;
      end if;
      Consume_Fault (Item.Storage.all, Before_Get, Fault);
      if Fault /= No_Fault then
         Complete_Composable_Flush (Item, Storage_Failure);
         return;
      elsif Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Flush (Item, Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Flush (Item, Timed_Out);
         return;
      elsif Item.Head_Child = null then
         raise Program_Error with "selected-run HEAD child was not prepared";
      end if;
      State.Selected_Object_Length := 0;
      State.Selected_Generation := (others => <>);
      State.Selected_Admission := (others => <>);
      Parameters.Expected_Bucket_Owner := Item.Storage.Expected_Bucket_Owner;
      Parameters.Request_Payer := Item.Storage.Client_Request_Payer;
      Parameters.Checksum_Mode := Item.Storage.Client_Checksum_Mode;
      Client_Objects.Head_Object
        (Item.HTTP,
         Item.Storage.Client_Origin,
         UStrings.To_String (Item.Storage.Bucket),
         Run_Key
           (Item.Storage.all,
            To_Identifier (State.Selected_Source.Manifest.Runs (State.Selected_Run_Index).Run_ID)),
         Parameters,
         Item.Storage.Client_Identity.all,
         Item.HTTP_Deadline,
         UStrings.To_String (Item.Storage.Client_Region),
         Item.Storage.Client_Style,
         Item.Cancellation,
         Item.Head_Child.all);
      State.Phase := Reading_Selected_Head;
      Flyology.Operations.Continue_After (Item, Item.Head_Child.all);
   exception
      when Flyology.Operations.Capacity_Error =>
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Composable_Flush (Item, Error);
   end Start_Next_Selected_Head;

   procedure Prepare_Composable_Flush (Item : in out Flush_Operation) is
      State  : Flush_Driver_State renames Item.Driver_State.all;
      Result : Outcome_Code;
   begin
      if State.Precheck_Result /= Success then
         Complete_Composable_Flush (Item, State.Precheck_Result);
         return;
      elsif Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Flush (Item, Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Flush (Item, Timed_Out);
         return;
      end if;
      if State.Mode in Adjacent_Merge_Plan | Three_Run_Merge_Plan then
         Prepare_Selected_Merge_Source
           (State.Engine,
            State.Older_Run_ID,
            State.Middle_Run_ID,
            State.Newer_Run_ID,
            State.Output_Run_ID,
            State.Manifest_ID,
            State.Transition_ID,
            State.Selected_Base,
            State.Selected_Head,
            State.Selected_Source,
            Result);
         if Result /= Success then
            Complete_Composable_Flush (Item, Result);
            return;
         end if;
         Allocation_Faults.Check (Recovery_SST_Image_Allocation);
         State.Selected_Source.Recovered_SSTs :=
           new Recovered_SST_Array'
             (1 .. State.Selected_Source.Manifest.Run_Total => null);
         Item.Head_Child :=
           new Client_Objects.Head_Operation
             (Item.Set.all'Unchecked_Access,
              Item.HTTP.all'Unchecked_Access,
              (if Item.Cancellation = null
               then null
               else Item.Cancellation.all'Unchecked_Access));
         Item.Range_Child :=
           new Client_Objects.Range_Get_Operation
             (Item.Set.all'Unchecked_Access,
              Item.HTTP.all'Unchecked_Access,
              Item.Payload'Unchecked_Access,
              (if Item.Cancellation = null
               then null
               else Item.Cancellation.all'Unchecked_Access));
         Item.Read_Child :=
           new Client_Objects.Whole_Get_Operation
             (Item.Set.all'Unchecked_Access,
              Item.HTTP.all'Unchecked_Access,
              Item.Payload'Unchecked_Access,
              (if Item.Cancellation = null
               then null
               else Item.Cancellation.all'Unchecked_Access));
         Start_Next_Selected_Head (Item);
         return;
      end if;
      if State.Mode = Family_Append_Plan then
         Build_Column_Family_Plan
           (State.Engine,
            State.Family_Configuration,
            State.Manifest_ID,
            State.Transition_ID,
            True,
            State.Plan,
            Result);
      else
         Build_Checkpoint_Plan
           (State.Engine,
            State.Runs (1 .. State.Run_Total),
            State.Manifest_ID,
            State.Transition_ID,
            State.Plan,
            Result,
            Replace_Current_Runs => State.Mode = Complete_Replacement_Plan);
      end if;
      if Result /= Success then
         Complete_Composable_Flush (Item, Result);
         return;
      end if;
      if State.Mode = Family_Append_Plan then
         Initialize_Column_Family_Receipt
           (State.Engine,
            State.Family_Configuration,
            State.Manifest_ID,
            State.Transition_ID,
            State.Plan,
            Item.Final_Family_Receipt,
            Result);
      else
         Initialize_Flush_Receipt
           (State.Engine,
            State.Plan,
            State.Runs (1 .. State.Run_Total),
            State.Manifest_ID,
            State.Transition_ID,
            Item.Final_Receipt,
            Result,
            Replace_Current_Runs => State.Mode = Complete_Replacement_Plan);
      end if;
      if Result /= Success then
         Complete_Composable_Flush (Item, Result);
         return;
      end if;
      Item.Read_Child :=
        --  The access values below point only at operation discriminant owners
        --  and its inline retained buffer. The public discriminant contract
        --  requires all of them to outlive Finish/finalization; the child is
        --  drained and freed before any such borrow can end.
        new Client_Objects.Whole_Get_Operation
          (Item.Set.all'Unchecked_Access,
           Item.HTTP.all'Unchecked_Access,
           Item.Payload'Unchecked_Access,
           (if Item.Cancellation = null
            then null
            else Item.Cancellation.all'Unchecked_Access));
      Prepare_Flush_Images (Item, State, Result);
      if Result /= Success then
         Complete_Composable_Flush (Item, Result);
      elsif Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Flush (Item, Cancelled);
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Flush (Item, Timed_Out);
      else
         State.Current_Family_Slot := 0;
         Start_Next_Immutable (Item);
      end if;
   exception
      when Storage_Error =>
         Complete_Composable_Flush (Item, Capacity_Exceeded);
      when Error : others =>
         Fail_Composable_Flush (Item, Error);
   end Prepare_Composable_Flush;

   procedure Await_Composable_Quiescence (Item : in out Flush_Operation) is
      Descriptor        : Interfaces.C.int;
      --  Flyology.IO defines negative descriptors as invalid; this initializer
      --  is overwritten only when an optional cancellation source is present.
      Cancellation_FD   : Interfaces.C.int := -1;
      Ready_Now         : Boolean;
      Already_Cancelled : Boolean := False;
      --  Exactly two owner-stack sources can be live here: lifecycle
      --  quiescence and the optional caller cancellation token. The absolute
      --  deadline is armed separately in the same visible operation slot.
      Sources           : Flyology.Operations.Drivers.Readiness_Source_Array (1 .. 2);
      Count             : Natural := 0;
   begin
      if Item.Cancellation /= null and then Item.Cancellation.Requested then
         Complete_Composable_Flush (Item, Cancelled);
         return;
      elsif Item.Deadline <= Ada.Real_Time.Clock then
         Complete_Composable_Flush (Item, Timed_Out);
         return;
      end if;
      Item.Item.Life.Checkpoint_Wait_Source (Descriptor, Ready_Now);
      if Ready_Now then
         Prepare_Composable_Flush (Item);
         return;
      end if;
      Count := Count + 1;
      Sources (Count) := (Descriptor => Descriptor, For_Write => False);
      if Item.Cancellation /= null then
         Item.Cancellation.Wait_Source (Cancellation_FD, Already_Cancelled);
         if Already_Cancelled then
            Complete_Composable_Flush (Item, Cancelled);
            return;
         end if;
         Count := Count + 1;
         Sources (Count) := (Descriptor => Cancellation_FD, For_Write => False);
      end if;
      Flyology.Operations.Drivers.Arm_Readiness (Item, Sources (1 .. Count));
      Flyology.Operations.Drivers.Arm_Deadline (Item, Remaining_Time (Item.Deadline));
      Item.Driver_State.Phase := Waiting_For_Quiescence;
   exception
      when Error : others =>
         Fail_Composable_Flush (Item, Error);
   end Await_Composable_Quiescence;

   overriding procedure Drive
     (Item : in out Flush_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      if Event in Flyology.Operations.Start_Operation | Flyology.Operations.Source_Ready then
         Await_Composable_Quiescence (Item);
      elsif Event = Flyology.Operations.Deadline_Reached
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Waiting_For_Quiescence
      then
         Complete_Composable_Flush (Item, Timed_Out);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Reading_Selected_Head
        and then Item.Head_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Head_Child.all)
      then
         Complete_Selected_Head (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Reading_Selected_Header
        and then Item.Range_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Range_Child.all)
      then
         Complete_Selected_Header (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Reading_Selected_Whole
        and then Item.Read_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Read_Child.all)
      then
         Complete_Selected_Whole (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase in Putting_Immutable | Putting_Head
        and then Flyology.Operations.Is_Terminal (Item.Put_Child)
      then
         Complete_Current_Put (Item);
      elsif Event = Flyology.Operations.Dependency_Changed
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Reading_Immutable
        and then Item.Read_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Read_Child.all)
      then
         Complete_Immutable_Read (Item);
      else
         raise Program_Error with "invalid composable Flush driver event";
      end if;
   exception
      when Error : others =>
         if Flyology.Operations.Is_Active (Item) then
            Fail_Composable_Flush (Item, Error);
         end if;
   end Drive;

   overriding procedure Request_Cancellation (Item : in out Flush_Operation) is
   begin
      if Flyology.Operations.Is_Active (Item.Put_Child) then
         Flyology.Operations.Cancel (Item.Put_Child);
      elsif Flyology.Operations.Is_Terminal (Item.Put_Child)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase in Putting_Immutable | Putting_Head
      then
         --  A terminal child may have won the race with parent cancellation.
         --  Consume and authenticate it before deciding publication certainty;
         --  cancellation can stop only the next still-active phase.
         Complete_Current_Put (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Item.Head_Child /= null and then Flyology.Operations.Is_Active (Item.Head_Child.all) then
         Flyology.Operations.Cancel (Item.Head_Child.all);
      elsif Item.Head_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Head_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Reading_Selected_Head
      then
         Complete_Selected_Head (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Item.Range_Child /= null and then Flyology.Operations.Is_Active (Item.Range_Child.all) then
         Flyology.Operations.Cancel (Item.Range_Child.all);
      elsif Item.Range_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Range_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase = Reading_Selected_Header
      then
         Complete_Selected_Header (Item);
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Item.Read_Child /= null and then Flyology.Operations.Is_Active (Item.Read_Child.all) then
         Flyology.Operations.Cancel (Item.Read_Child.all);
      elsif Item.Read_Child /= null
        and then Flyology.Operations.Is_Terminal (Item.Read_Child.all)
        and then Item.Driver_State /= null
        and then Item.Driver_State.Phase in Reading_Selected_Whole | Reading_Immutable
      then
         if Item.Driver_State.Phase = Reading_Selected_Whole then
            Complete_Selected_Whole (Item);
         else
            Complete_Immutable_Read (Item);
         end if;
         if Flyology.Operations.Is_Active (Item) then
            Request_Cancellation (Item);
         end if;
      elsif Flyology.Operations.Is_Active (Item) then
         Complete_Composable_Flush (Item, Cancelled, Flyology.Operations.Cancelled);
      end if;
   exception
      when others =>
         if Flyology.Operations.Is_Active (Item) then
            begin
               Complete_Composable_Flush (Item, Storage_Failure, Flyology.Operations.Failed);
            exception
               when others => null;
            end;
         end if;
   end Request_Cancellation;

   procedure Start_Composable_Checkpoint
     (Operation            : in out Flush_Operation;
      Runs                 : Checkpoint_Run_Identity_Array;
      Manifest_ID          : Identifier;
      Transition_ID        : Identifier;
      Payload_Buffer       : in out Flyology.Buffers.Unique_Buffer;
      Timeout              : Duration;
      Mode                 : Flush_Plan_Mode;
      Configuration        : Column_Family_Configuration;
      Older_Run_ID         : Identifier;
      Middle_Run_ID        : Identifier;
      Newer_Run_ID         : Identifier;
      Output_Run_ID        : Identifier;
      Lease                : access Lifecycle_Lease := null)
   is
      Result     : Outcome_Code;
      Moved      : Boolean := False;
      Started    : Boolean := False;
   begin
      if Operation.Storage.HTTP_Client /= Operation.HTTP
        or else Operation.Storage.Client_Identity = null
      then
         raise Program_Error with "Flush operation does not match the client-bound storage context";
      elsif Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "Flush payload buffer belongs to a different pool";
      elsif Flyology.Buffers.Has_Buffer (Operation.Payload)
        or else Operation.Driver_State /= null
        or else Operation.Read_Child /= null
        or else Operation.Range_Child /= null
        or else Operation.Head_Child /= null
      then
         raise Program_Error with "Flush operation retains unconsumed ownership";
      elsif Lease /= null
        and then
          (Lease.Life /= Operation.Item.Life'Unchecked_Access
           or else Lease.State = null
           or else Lease.State.Storage /= Operation.Storage)
      then
         raise Program_Error with "Flush operation does not match the promoted lifecycle lease";
      end if;

      Operation.Deadline := Deadline_After (Timeout);
      Operation.HTTP_Deadline :=
        (if Operation.Deadline = Ada.Real_Time.Time_Last
         then Flyology.HTTP.Client.No_Deadline
         else Flyology.HTTP.Client.Deadline_After (Remaining_Time (Operation.Deadline)));

      Operation.Final_Receipt := (others => <>);
      Operation.Final_Family_Receipt := (others => <>);
      Operation.Final_Is_Family_Append := Mode = Family_Append_Plan;
      Operation.Final_Result := Invalid_State;
      Operation.Has_Final_Result := False;
      Operation.Has_Saved_Error := False;
      begin
         --  The checkpoint plan and its retained images are lazily sized from
         --  the database's persisted limits and per-family state. One bounded
         --  owner-stack state allocation avoids a public DB ceiling; failure
         --  becomes a definite Capacity_Exceeded result before publication.
         Operation.Driver_State := new Flush_Driver_State;
      exception
         when Storage_Error =>
            null;
      end;
      if Operation.Driver_State /= null then
         Operation.Driver_State.Manifest_ID := Manifest_ID;
         Operation.Driver_State.Transition_ID := Transition_ID;
         Operation.Driver_State.Mode := Mode;
         Operation.Driver_State.Older_Run_ID := Older_Run_ID;
         Operation.Driver_State.Middle_Run_ID := Middle_Run_ID;
         Operation.Driver_State.Newer_Run_ID := Newer_Run_ID;
         Operation.Driver_State.Output_Run_ID := Output_Run_ID;
         Operation.Driver_State.Family_Configuration := Configuration;
         if Is_Zero (Manifest_ID)
           or else Is_Zero (Transition_ID)
           or else Manifest_ID = Transition_ID
         then
            Operation.Driver_State.Precheck_Result := Invalid_State;
         elsif Mode = Family_Append_Plan then
            if Runs'Length /= 0 then
               Operation.Driver_State.Precheck_Result := Invalid_State;
            end if;
         elsif Mode in Adjacent_Merge_Plan | Three_Run_Merge_Plan then
            if Runs'Length /= 0
              or else Is_Zero (Older_Run_ID)
              or else Is_Zero (Newer_Run_ID)
              or else Is_Zero (Output_Run_ID)
              or else Older_Run_ID = Newer_Run_ID
              or else
                (if Mode = Three_Run_Merge_Plan
                 then
                   Is_Zero (Middle_Run_ID)
                   or else Middle_Run_ID = Older_Run_ID
                   or else Middle_Run_ID = Newer_Run_ID
                   or else Output_Run_ID = Middle_Run_ID
                 else not Is_Zero (Middle_Run_ID))
              or else Output_Run_ID = Older_Run_ID
              or else Output_Run_ID = Newer_Run_ID
              or else Output_Run_ID = Manifest_ID
              or else Output_Run_ID = Transition_ID
            then
               Operation.Driver_State.Precheck_Result := Invalid_State;
            end if;
         elsif Runs'Length > Maximum_Initial_Column_Families
           or else (Runs'Length = 0 and then Mode /= Complete_Replacement_Plan)
         then
            Operation.Driver_State.Precheck_Result := Invalid_State;
         else
            Operation.Driver_State.Run_Total := Runs'Length;
            for Offset in Natural range 0 .. Runs'Length - 1 loop
               Operation.Driver_State.Runs (Offset + 1) := Runs (Runs'First + Offset);
               if Is_Zero (Runs (Runs'First + Offset).Run_ID)
                 or else Runs (Runs'First + Offset).Run_ID = Manifest_ID
                 or else Runs (Runs'First + Offset).Run_ID = Transition_ID
               then
                  Operation.Driver_State.Precheck_Result := Invalid_State;
               end if;
               if Offset > 0 then
                  for Previous in Natural range 0 .. Offset - 1 loop
                     if Runs (Runs'First + Previous).Family_ID = Runs (Runs'First + Offset).Family_ID
                       or else Runs (Runs'First + Previous).Run_ID = Runs (Runs'First + Offset).Run_ID
                     then
                        Operation.Driver_State.Precheck_Result := Invalid_State;
                     end if;
                  end loop;
               end if;
            end loop;
         end if;
      end if;

      Flyology.Operations.Drivers.Start (Operation);
      Started := True;
      if Operation.Driver_State /= null and then Operation.Driver_State.Precheck_Result = Success then
         if Lease = null then
            Operation.Item.Life.Begin_Composable_Checkpoint (Operation.Driver_State.Engine, Result);
         else
            Promote_Composable_Checkpoint (Lease.all, Operation.Driver_State.Engine, Result);
         end if;
         if Result = Success and then Operation.Driver_State.Engine.Storage /= Operation.Storage then
            Operation.Item.Life.Cancel_Checkpoint;
            raise Program_Error with "Flush operation storage does not own the open database";
         elsif Result = Success then
            Operation.Driver_State.Checkpoint_Admitted := True;
         else
            Operation.Driver_State.Precheck_Result := Result;
         end if;
      end if;
      Flyology.Buffers.Move (Payload_Buffer, Operation.Payload);
      Moved := True;
      if Operation.Driver_State = null then
         Operation.Final_Result := Capacity_Exceeded;
         if Mode = Family_Append_Plan then
            Operation.Final_Family_Receipt.Current_Outcome := Capacity_Exceeded;
         else
            Operation.Final_Receipt.Current_Outcome := Capacity_Exceeded;
         end if;
         Operation.Has_Final_Result := True;
         Flyology.Operations.Drivers.Complete (Operation, Flyology.Operations.Succeeded);
      elsif Operation.Driver_State.Precheck_Result /= Success then
         Complete_Composable_Flush (Operation, Operation.Driver_State.Precheck_Result);
      else
         Flyology.Operations.Drive
           (Flyology.Operations.Operation'Class (Operation), Flyology.Operations.Start_Operation);
      end if;
   exception
      when others =>
         if Moved and then Flyology.Buffers.Has_Buffer (Operation.Payload) then
            Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
         end if;
         if Operation.Driver_State /= null and then Operation.Driver_State.Checkpoint_Admitted then
            Operation.Driver_State.Checkpoint_Admitted := False;
            Operation.Item.Life.Cancel_Checkpoint;
         end if;
         Release_Flush_State (Operation.Driver_State);
         if Mode = Family_Append_Plan then
            Release_Retained_Manifest (Operation.Final_Family_Receipt);
         end if;
         if Started and then Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Composable_Checkpoint;

   procedure Start_Flush
     (Operation      : in out Flush_Operation;
      Runs           : Checkpoint_Run_Identity_Array;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration) is
   begin
      Start_Composable_Checkpoint
        (Operation, Runs, Manifest_ID, Transition_ID, Payload_Buffer, Timeout,
         Additive_Plan,
         (others => <>),
         Zero_Identifier,
         Zero_Identifier,
         Zero_Identifier,
         Zero_Identifier);
   end Start_Flush;

   procedure Add_Column_Family
     (Configuration  : Column_Family_Configuration;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Flush_Operation)
   is
      --  Registry publication preserves every retained run and creates no new
      --  SST. The empty map is therefore derived from the family-append
      --  protocol, not a run-count or capacity choice.
      No_Runs : Checkpoint_Run_Identity_Array (1 .. 0);
   begin
      Start_Composable_Checkpoint
        (Operation,
         No_Runs,
         Manifest_ID,
         Transition_ID,
         Payload_Buffer,
         Timeout,
         Family_Append_Plan,
         Configuration,
         Zero_Identifier,
         Zero_Identifier,
         Zero_Identifier,
         Zero_Identifier);
   end Add_Column_Family;

   procedure Start_Compaction
     (Operation      : in out Flush_Operation;
      Runs           : Checkpoint_Run_Identity_Array;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration) is
   begin
      Start_Composable_Checkpoint
        (Operation, Runs, Manifest_ID, Transition_ID, Payload_Buffer, Timeout,
         Complete_Replacement_Plan,
         (others => <>),
         Zero_Identifier,
         Zero_Identifier,
         Zero_Identifier,
         Zero_Identifier);
   end Start_Compaction;

   procedure Start_Composable_Adjacent_Merge
     (Operation      : in out Flush_Operation;
      Older_Run_ID   : Identifier;
      Newer_Run_ID   : Identifier;
      Output_Run_ID  : Identifier;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Lease          : access Lifecycle_Lease := null)
   is
      No_Runs : Checkpoint_Run_Identity_Array (1 .. 0);
   begin
      Start_Composable_Checkpoint
        (Operation,
         No_Runs,
         Manifest_ID,
         Transition_ID,
         Payload_Buffer,
         Timeout,
         Adjacent_Merge_Plan,
         (others => <>),
         Older_Run_ID,
         Zero_Identifier,
         Newer_Run_ID,
         Output_Run_ID,
         Lease);
   end Start_Composable_Adjacent_Merge;

   procedure Start_Compaction
     (Operation      : in out Flush_Operation;
      Older_Run_ID   : Identifier;
      Newer_Run_ID   : Identifier;
      Output_Run_ID  : Identifier;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration) is
   begin
      Start_Composable_Adjacent_Merge
        (Operation,
         Older_Run_ID,
         Newer_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Payload_Buffer,
         Timeout);
   end Start_Compaction;

   procedure Start_Composable_Three_Run_Merge
     (Operation      : in out Flush_Operation;
      First_Run_ID   : Identifier;
      Middle_Run_ID  : Identifier;
      Last_Run_ID    : Identifier;
      Output_Run_ID  : Identifier;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Lease          : access Lifecycle_Lease := null)
   is
      --  No_Runs is the canonical vacant family-output list because the exact
      --  three selected inputs below determine one output after authenticated
      --  reads. This is operation shape, not a zero-capacity policy.
      No_Runs : Checkpoint_Run_Identity_Array (1 .. 0);
   begin
      Start_Composable_Checkpoint
        (Operation,
         No_Runs,
         Manifest_ID,
         Transition_ID,
         Payload_Buffer,
         Timeout,
         Three_Run_Merge_Plan,
         (others => <>),
         First_Run_ID,
         Middle_Run_ID,
         Last_Run_ID,
         Output_Run_ID,
         Lease);
   end Start_Composable_Three_Run_Merge;

   procedure Start_Compaction
     (Operation      : in out Flush_Operation;
      First_Run_ID   : Identifier;
      Middle_Run_ID  : Identifier;
      Last_Run_ID    : Identifier;
      Output_Run_ID  : Identifier;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration) is
   begin
      Start_Composable_Three_Run_Merge
        (Operation,
         First_Run_ID,
         Middle_Run_ID,
         Last_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Payload_Buffer,
         Timeout);
   end Start_Compaction;

   procedure Finish
     (Operation      : in out Flush_Operation;
      Receipt        : out Flush_Receipt;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
   is
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "Flush Finish requires the original buffer pool";
      elsif Operation.Final_Is_Family_Append then
         raise Program_Error with "family append requires its Column_Family_Receipt Finish";
      end if;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
      Release_Flush_State (Operation.Driver_State);
      if Operation.Read_Child /= null then
         Free_Whole_Get_Operation (Operation.Read_Child);
      end if;
      if Operation.Range_Child /= null then
         Free_Range_Get_Operation (Operation.Range_Child);
      end if;
      if Operation.Head_Child /= null then
         Free_Head_Operation (Operation.Head_Child);
      end if;
      if Operation.Has_Saved_Error then
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity (Operation.Saved_Error),
            Ada.Exceptions.Exception_Message (Operation.Saved_Error));
      elsif not Operation.Has_Final_Result then
         raise Program_Error with "composable Flush has no terminal result";
      end if;
      Receipt := Operation.Final_Receipt;
      Result := Operation.Final_Result;
   end Finish;

   procedure Finish
     (Operation      : in out Flush_Operation;
      Receipt        : out Column_Family_Receipt;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
   is
   begin
      if Payload_Buffer.Owner /= Operation.Payload_Pool then
         raise Program_Error with "family append Finish requires the original buffer pool";
      elsif not Operation.Final_Is_Family_Append then
         raise Program_Error with "Flush publication requires its Flush_Receipt Finish";
      end if;
      Flyology.Operations.Consume (Operation);
      Flyology.Buffers.Move (Operation.Payload, Payload_Buffer);
      Release_Flush_State (Operation.Driver_State);
      if Operation.Read_Child /= null then
         Free_Whole_Get_Operation (Operation.Read_Child);
      end if;
      if Operation.Range_Child /= null then
         Free_Range_Get_Operation (Operation.Range_Child);
      end if;
      if Operation.Head_Child /= null then
         Free_Head_Operation (Operation.Head_Child);
      end if;
      if Operation.Has_Saved_Error then
         Release_Retained_Manifest (Operation.Final_Family_Receipt);
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity (Operation.Saved_Error),
            Ada.Exceptions.Exception_Message (Operation.Saved_Error));
      elsif not Operation.Has_Final_Result then
         Release_Retained_Manifest (Operation.Final_Family_Receipt);
         raise Program_Error with "composable family append has no terminal result";
      end if;
      Receipt := Operation.Final_Family_Receipt;
      Release_Retained_Manifest (Operation.Final_Family_Receipt);
      Result := Operation.Final_Result;
   end Finish;

   overriding procedure Finalize (Item : in out Flush_Operation) is
   begin
      begin
         Flyology.Operations.Finalize (Flyology.Operations.Operation (Item));
      exception
         when others => null;
      end;
      Release_Flush_State (Item.Driver_State);
      if Item.Read_Child /= null then
         Free_Whole_Get_Operation (Item.Read_Child);
      end if;
      if Item.Range_Child /= null then
         Free_Range_Get_Operation (Item.Range_Child);
      end if;
      if Item.Head_Child /= null then
         Free_Head_Operation (Item.Head_Child);
      end if;
      Release_Retained_Manifest (Item.Final_Family_Receipt);
      Flyology.Buffers.Release (Item.Payload);
   end Finalize;

   procedure Confirm_Immutable_Object
     (Storage  : in out Storage_Context;
      Key      : String;
      Kind     : Stored_Object_Kind;
      Image    : not null Shared_Image_Access;
      Deadline : Ada.Real_Time.Time;
      Token    : access Flyology.Cancellation.Token;
      Result   : out Outcome_Code)
   is
      Generation  : Generation_Value;
      Put_Result  : Put_Outcome;
      Read_Data   : Flyology.Bytes.Unbounded_Bytes;
      Read_Result : Read_Outcome;
      Fault       : Storage_Fault_Mode;
   begin
      Storage_Port.Put_Create (Storage, Key, Image, Kind, Deadline, Token, Generation, Put_Result);
      if Put_Result = Object_Published then
         Result := Success;
      elsif Put_Result in Put_Precondition_Failed | Put_Outcome_Unknown then
         Consume_Fault (Storage, Before_Immutable_Reconciliation, Fault);
         if Fault /= No_Fault then
            --  A skipped or unavailable observation after possible admission
            --  cannot establish absence. The receipt must retain exact bytes
            --  and identity for a later caller-driven resolution.
            Result := Outcome_Unknown;
            return;
         end if;
         Storage_Port.Get_Whole
           (Storage,
            Key,
            Kind,
            Deadline,
            Token,
            Read_Data,
            Generation,
            Read_Result,
            Flyology.Bytes.Length (Image.Data));
         if Read_Result = Object_Read and then Exact_Bytes (Image, Read_Data) then
            Result := Success;
         elsif Read_Result = Object_Read then
            Result := Conflict;
         else
            --  Once a create-if-absent call can have entered the provider, a
            --  failed observation cannot prove that the immutable object was
            --  absent. Resolution must retain the same identity and bytes.
            Result := Outcome_Unknown;
         end if;
      elsif Put_Result = Put_Cancelled then
         Result := Cancelled;
      elsif Put_Result = Put_Timed_Out then
         Result := Timed_Out;
      else
         Result := Storage_Failure;
      end if;
   end Confirm_Immutable_Object;

   procedure Stop_Replaced_Engine (State : in out Engine_State_Access) is
   begin
      State.Gate.Request_Close;
      State.Gate.Join;
      Free_Worker (State.Worker);
      Release_State_Images (State);
      Free_State (State);
   end Stop_Replaced_Engine;

   procedure Activate_Flush_Plan
     (Item       : in out Database;
      Old_State  : in out Engine_State_Access;
      Plan       : in out Checkpoint_Plan;
      Generation : Generation_Value;
      Receipt    : in out Flush_Receipt;
      Guard      : in out Checkpoint_Guard;
      Result     : out Outcome_Code)
   is
      Manifest         : constant Manifests.Manifest := Plan.Manifest.Base;
      LSM_Authority    : constant Engine_LSM_Authority := To_Engine_LSM_Authority (Plan.Manifest.all);
      History          : Batch_History_Access := null;
      History_Count    : Natural := 0;
      New_State        : Engine_State_Access := null;
      --  Flush changes only the durable representation of the same open
      --  database. Reusing the live incarnation preserves valid family
      --  handles and active transaction ownership across coordinator swap.
      Stamp            : constant Engine_Incarnation := Old_State.Gate.Current_Incarnation;
      Activation_Fault : Storage_Fault_Mode;
   begin
      Receipt.Phase := Flush_Head_Confirmed;
      Receipt.Current_Outcome := Success;
      Old_State.Gate.Fence;
      Consume_Fault (Old_State.Storage.all, Before_Local_Activation, Activation_Fault);
      if Activation_Fault /= No_Fault then
         Result := Local_Activation_Failed;
      else
         Allocation_Faults.Check (Flush_Activation_State_Allocation);
         --  Move the prepublication suffix snapshot out of Plan before passing
         --  both objects as writable actuals. Allocate_Engine consumes this
         --  recovery-ordered history on every success or failure path.
         History := Plan.History;
         History_Count := Plan.History_Count;
         Plan.History := null;
         Plan.History_Count := 0;
         Allocate_Engine
           (Item.Life'Unchecked_Access,
            Old_State.Storage,
            Receipt.Attempted_Head,
            Generation,
            Manifest,
            LSM_Authority,
            Plan,
            Stamp,
            History,
            History_Count,
            New_State,
            Result);
         if Result /= Success then
            Release_History (History, History_Count);
            Release_Checkpoint_Plan (Plan);
            Result := Local_Activation_Failed;
         end if;
      end if;
      if Result /= Success then
         Receipt.Current_Outcome := Local_Activation_Failed;
         return;
      end if;

      Item.Life.Finish_Checkpoint (New_State, Receipt.Attempted_Head.Highest);
      Guard.Active := False;
      Stop_Replaced_Engine (Old_State);
      Receipt.Phase := Flush_Resolved;
      Receipt.Current_Outcome := Success;
      Result := Success;
   exception
      when Storage_Error =>
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Plan);
         Receipt.Current_Outcome := Local_Activation_Failed;
         Result := Local_Activation_Failed;
   end Activate_Flush_Plan;

   procedure Publish_Flush_Plan
     (Item     : in out Database;
      State    : in out Engine_State_Access;
      Plan     : in out Checkpoint_Plan;
      Deadline : Ada.Real_Time.Time;
      Token    : access Flyology.Cancellation.Token;
      Receipt  : in out Flush_Receipt;
      Guard    : in out Checkpoint_Guard;
      Result   : out Outcome_Code)
   is
      Encoded        : LSM_Runtime.Image_Access := null;
      Owner          : Shared_Image_Access := null;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;
      Encode_Result  : LSM_Runtime.Encode_Status;
   begin
      Receipt.Phase := Objects_Unknown;
      for SST of Plan.SSTs loop
         if SST /= null then
            --  Keep the blocking path byte-identical to the composable flush:
            --  both publish frozen SST-v2 while recovery continues reading v1.
            LSM_Runtime.Encode_SST_V2 (SST.all, Encoded, Encode_Result);
            if Encode_Result /= LSM_Runtime.Encoded then
               Result := Corrupt;
               Receipt.Phase := Flush_Resolved;
               Receipt.Current_Outcome := Result;
               return;
            end if;
            Owner := New_Image (Encoded.all);
            LSM_Runtime.Release (Encoded);
            Confirm_Immutable_Object
              (State.Storage.all,
               Run_Key (State.Storage.all, To_Identifier (SST.Run_ID)),
               Run_Object,
               Owner,
               Deadline,
               Token,
               Result);
            Release_Image (Owner);
            if Result /= Success then
               Receipt.Current_Outcome := Result;
               if Result = Outcome_Unknown then
                  State.Gate.Fence;
               else
                  Receipt.Phase := Flush_Resolved;
               end if;
               return;
            end if;
         end if;
      end loop;

      LSM_Runtime.Encode_Checkpoint_Manifest (Plan.Manifest.all, Encoded, Encode_Result);
      if Encode_Result /= LSM_Runtime.Encoded then
         Result := Corrupt;
         Receipt.Phase := Flush_Resolved;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Owner := New_Image (Encoded.all);
      LSM_Runtime.Release (Encoded);
      Confirm_Immutable_Object
        (State.Storage.all,
         Manifest_Key (State.Storage.all, Receipt.Manifest_ID),
         Manifest_Object,
         Owner,
         Deadline,
         Token,
         Result);
      Release_Image (Owner);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         if Result = Outcome_Unknown then
            State.Gate.Fence;
         else
            Receipt.Phase := Flush_Resolved;
         end if;
         return;
      elsif Token /= null and then Token.Requested then
         Result := Cancelled;
         Receipt.Phase := Flush_Resolved;
         Receipt.Current_Outcome := Result;
         return;
      elsif Deadline <= Ada.Real_Time.Clock then
         Result := Timed_Out;
         Receipt.Phase := Flush_Resolved;
         Receipt.Current_Outcome := Result;
         return;
      end if;

      Owner := New_Image (Formats.Encode_Head (To_Head (Receipt.Attempted_Head)));
      Receipt.Phase := Flush_Head_Unknown;
      Storage_Port.Put_Replace
        (State.Storage.all,
         Full_Key (State.Storage.all, Head_Key_Suffix),
         Owner,
         Receipt.Expected_Generation,
         Deadline,
         Token,
         New_Generation,
         Put_Result);
      Release_Image (Owner);
      if Put_Result = Object_Published then
         Activate_Flush_Plan (Item, State, Plan, New_Generation, Receipt, Guard, Result);
      elsif Put_Result = Put_Precondition_Failed then
         State.Gate.Fence;
         Receipt.Phase := Flush_Resolved;
         Receipt.Current_Outcome := Stale_Writer;
         Result := Stale_Writer;
      elsif Put_Result = Put_Outcome_Unknown then
         State.Gate.Fence;
         Receipt.Current_Outcome := Outcome_Unknown;
         Result := Outcome_Unknown;
      elsif Put_Result = Put_Cancelled then
         Receipt.Phase := Flush_Resolved;
         Receipt.Current_Outcome := Cancelled;
         Result := Cancelled;
      elsif Put_Result = Put_Timed_Out then
         Receipt.Phase := Flush_Resolved;
         Receipt.Current_Outcome := Timed_Out;
         Result := Timed_Out;
      else
         Receipt.Phase := Flush_Resolved;
         Receipt.Current_Outcome := Storage_Failure;
         Result := Storage_Failure;
      end if;
   exception
      when others =>
         LSM_Runtime.Release (Encoded);
         Release_Image (Owner);
         if Receipt.Phase in Objects_Unknown | Flush_Head_Unknown then
            State.Gate.Fence;
            Result := Outcome_Unknown;
         else
            Result := Local_Activation_Failed;
         end if;
         Receipt.Current_Outcome := Result;
   end Publish_Flush_Plan;

   function Plan_Matches_Receipt
     (Plan : Checkpoint_Plan; Head : Head_Snapshot; Receipt : Flush_Receipt) return Boolean
   is
      Attempted : constant Head_Snapshot :=
        (Database_ID            => Head.Database_ID,
         Version                => Head.Version,
         Epoch                  => Head.Epoch,
         Highest                => Head.Highest,
         Latest_Batch           => Head.Latest_Batch,
         Latest_Manifest        => Receipt.Manifest_ID,
         Transition_ID          => Receipt.Attempted_Head.Transition_ID,
         Predecessor_Transition => Head.Transition_ID,
         Transition_Number      => Head.Transition_Number + 1);
   begin
      return
        Plan.Manifest /= null
        and then Head = Receipt.Expected_Head
        and then Plan.Expected_Generation = Receipt.Expected_Generation
        and then Plan.Manifest.Replay_Boundary = Interfaces.Unsigned_64 (Receipt.Replay_Boundary)
        and then To_Identifier (Plan.Manifest.Base.Manifest_ID) = Receipt.Manifest_ID
        and then Attempted = Receipt.Attempted_Head;
   end Plan_Matches_Receipt;

   procedure Publish_Checkpoint
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Replace_Current_Runs : Boolean;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token := null;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code)
   is
      --  The sole deadline is derived from caller policy; the shared
      --  checkpoint publisher introduces no retry, per-object, or
      --  local-activation timeout for either additive or replacement plans.
      Deadline   : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      State      : Engine_State_Access;
      Plan       : Checkpoint_Plan;
      Guard      : Checkpoint_Guard;
   begin
      Receipt := (others => <>);
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      Build_Checkpoint_Plan
        (State,
         Runs,
         Manifest_ID,
         Transition_ID,
         Plan,
         Result,
         Replace_Current_Runs => Replace_Current_Runs);
      if Result = Success then
         Initialize_Flush_Receipt
           (State,
            Plan,
            Runs,
            Manifest_ID,
            Transition_ID,
            Receipt,
            Result,
            Replace_Current_Runs => Replace_Current_Runs);
         if Result = Success then
            Publish_Flush_Plan (Item, State, Plan, Deadline, Token, Receipt, Guard, Result);
         end if;
      end if;
      Release_Checkpoint_Plan (Plan);
      if Guard.Active then
         Item.Life.Finish_Checkpoint;
         Guard.Active := False;
      end if;
      Receipt.Current_Outcome := Result;
   exception
      when others =>
         Release_Checkpoint_Plan (Plan);
         if Guard.Active then
            if Receipt.Phase in Objects_Unknown | Flush_Head_Unknown then
               State.Gate.Fence;
               Result := Outcome_Unknown;
            elsif Receipt.Phase = Flush_Head_Confirmed then
               State.Gate.Fence;
               Result := Local_Activation_Failed;
            else
               Result := Storage_Failure;
            end if;
            Item.Life.Finish_Checkpoint;
            Guard.Active := False;
         else
            Result := Local_Activation_Failed;
         end if;
         Receipt.Current_Outcome := Result;
   end Publish_Checkpoint;

   procedure Synchronous_Checkpoint_Buffer_Capacity
     (State   : not null Engine_State_Access;
      Additional_Family_Name_Length : Natural;
      Maximum : out Natural;
      Result  : out Outcome_Code);

   procedure Publish_Selected_Merge
     (Item          : in out Database;
      Older_Run_ID  : Identifier;
      Middle_Run_ID : Identifier;
      Newer_Run_ID  : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token := null;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code)
   is
      --  The caller supplies the sole deadline budget and every immutable
      --  identity. This caller-selected publisher selects no merge trigger, retry,
      --  helper task, output name, or timing default.
      Deadline     : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      State        : Engine_State_Access;
      Plan         : Checkpoint_Plan;
      Guard        : Checkpoint_Guard;
      Runs         : Checkpoint_Run_Identity_Array (1 .. 1);
      Family_Index : Natural := 0;
      Lease        : aliased Lifecycle_Lease;
      Storage      : access Storage_Context;
      Maximum      : Natural := 0;
      --  One DB parent, one Object Storage child, one HTTP exchange, and one
      --  transport child are the exact selected-merge owner stack. This is
      --  private operation geometry, not a DB queue or public capacity.
      Synchronous_Set_Capacity : constant := 4;
   begin
      Receipt := (others => <>);
      Acquire (Item, Lease, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Storage := Lease.State.Storage;
      if Storage.HTTP_Client /= null then
         if Storage.Client_Identity = null then
            Result := Invalid_State;
            Receipt.Current_Outcome := Result;
            return;
         end if;
         Synchronous_Checkpoint_Buffer_Capacity (Lease.State, 0, Maximum, Result);
         if Result /= Success then
            Receipt.Current_Outcome := Result;
            return;
         end if;
         declare
            Set : aliased Flyology.Operations.Completion_Set (Synchronous_Set_Capacity);
            --  Exactly one moved payload token is reused serially across
            --  selected reads and publication. Capacity one expresses that
            --  ownership geometry and is not a persisted or public ceiling.
            Pool : aliased Flyology.Buffers.Pool
              (Block_Size => Positive (Maximum), Capacity => 1);
            Payload_Buffer : Flyology.Buffers.Unique_Buffer (Pool'Access);
            Operation      : Flush_Operation
              (Set'Access,
               Item'Unchecked_Access,
               Storage,
               Storage.HTTP_Client,
               Pool'Access,
               Token);
            Started : Boolean := False;
         begin
            Flyology.Buffers.Acquire (Payload_Buffer);
            if Is_Zero (Middle_Run_ID) then
               Start_Composable_Adjacent_Merge
                 (Operation,
                  Older_Run_ID,
                  Newer_Run_ID,
                  Output_Run_ID,
                  Manifest_ID,
                  Transition_ID,
                  Payload_Buffer,
                  Timeout,
                  Lease'Access);
            else
               Start_Composable_Three_Run_Merge
                 (Operation,
                  Older_Run_ID,
                  Middle_Run_ID,
                  Newer_Run_ID,
                  Output_Run_ID,
                  Manifest_ID,
                  Transition_ID,
                  Payload_Buffer,
                  Timeout,
                  Lease'Access);
            end if;
            Started := True;
            Flyology.Operations.Wait_All (Set);
            Finish (Operation, Receipt, Result, Payload_Buffer);
         exception
            when Storage_Error =>
               Receipt := (if Started then Operation.Final_Receipt else (others => <>));
               Result :=
                 (if not Started or else Receipt.Phase = No_Flush_Publication
                  then Capacity_Exceeded
                  elsif Receipt.Phase in Objects_Unknown | Flush_Head_Unknown
                  then Outcome_Unknown
                  elsif Receipt.Phase = Flush_Head_Confirmed
                  then Local_Activation_Failed
                  else Storage_Failure);
               Receipt.Current_Outcome := Result;
            when others =>
               Receipt := (if Started then Operation.Final_Receipt else (others => <>));
               Result :=
                 (if Started and then Receipt.Phase in Objects_Unknown | Flush_Head_Unknown
                  then Outcome_Unknown
                  elsif Started and then Receipt.Phase = Flush_Head_Confirmed
                  then Local_Activation_Failed
                  else Storage_Failure);
               Receipt.Current_Outcome := Result;
         end;
         return;
      end if;
      Release (Lease);
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      Build_Selected_Merge_Plan
        (State,
         Older_Run_ID,
         Middle_Run_ID,
         Newer_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Deadline,
         Token,
         Plan,
         Result);
      if Result = Success then
         for Index in Plan.SSTs'Range loop
            if Plan.SSTs (Index) /= null then
               if Family_Index /= 0 then
                  Result := Corrupt;
                  exit;
               end if;
               Family_Index := Index;
            end if;
         end loop;
         if Result = Success and then Family_Index = 0 then
            Result := Corrupt;
         end if;
      end if;
      if Result = Success then
         Runs (1) :=
           (Family_ID => Column_Family_ID (Plan.Manifest.Base.Families (Family_Index).ID),
            Run_ID    => Output_Run_ID);
         Initialize_Flush_Receipt
           (State,
            Plan,
            Runs,
            Manifest_ID,
            Transition_ID,
            Receipt,
            Result,
            Merge_Older_Run_ID => Older_Run_ID,
            Merge_Middle_Run_ID => Middle_Run_ID,
            Merge_Newer_Run_ID => Newer_Run_ID);
         if Result = Success then
            Publish_Flush_Plan (Item, State, Plan, Deadline, Token, Receipt, Guard, Result);
         end if;
      end if;
      Release_Checkpoint_Plan (Plan);
      if Guard.Active then
         Item.Life.Finish_Checkpoint;
         Guard.Active := False;
      end if;
      Receipt.Current_Outcome := Result;
   exception
      when others =>
         Release_Checkpoint_Plan (Plan);
         if Guard.Active then
            if Receipt.Phase in Objects_Unknown | Flush_Head_Unknown then
               State.Gate.Fence;
               Result := Outcome_Unknown;
            elsif Receipt.Phase = Flush_Head_Confirmed then
               State.Gate.Fence;
               Result := Local_Activation_Failed;
            else
               Result := Storage_Failure;
            end if;
            Item.Life.Finish_Checkpoint;
            Guard.Active := False;
         else
            Result := Local_Activation_Failed;
         end if;
         Receipt.Current_Outcome := Result;
   end Publish_Selected_Merge;

   procedure Compact
     (Item          : in out Database;
      Older_Run_ID  : Identifier;
      Newer_Run_ID  : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      Publish_Selected_Merge
        (Item,
         Older_Run_ID,
         Zero_Identifier,
         Newer_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Timeout,
         Token,
         Receipt,
         Result);
   end Compact;

   procedure Publish_Three_Run_Merge
     (Item          : in out Database;
      First_Run_ID  : Identifier;
      Middle_Run_ID : Identifier;
      Last_Run_ID   : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token := null;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      Publish_Selected_Merge
        (Item,
         First_Run_ID,
         Middle_Run_ID,
         Last_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Timeout,
         Token,
         Receipt,
         Result);
   end Publish_Three_Run_Merge;

   procedure Compact
     (Item          : in out Database;
      First_Run_ID  : Identifier;
      Middle_Run_ID : Identifier;
      Last_Run_ID   : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      Publish_Three_Run_Merge
        (Item,
         First_Run_ID,
         Middle_Run_ID,
         Last_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Timeout,
         Token,
         Receipt,
         Result);
   end Compact;

   procedure Synchronous_Checkpoint_Buffer_Capacity
     (State   : not null Engine_State_Access;
      Additional_Family_Name_Length : Natural;
      Maximum : out Natural;
      Result  : out Outcome_Code)
   is
      Base           : Manifests.Manifest;
      Identity_Total : Natural;
      SST_Bound      : Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64
          (LSM_Runtime.SST_V2_Header_Length
           + LSM_Runtime.SST_V2_Index_Trailer_Length
           + LSM_Runtime.LSM.Object_Trailer_Length);
      Manifest_Bound : Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64
          (LSM_Runtime.LSM.Checkpoint_Manifest_Header_Length + LSM_Runtime.LSM.Object_Trailer_Length);

      function Add
        (Total  : in out Interfaces.Unsigned_64;
         Amount : Interfaces.Unsigned_64) return Boolean
      is
      begin
         if Amount > Interfaces.Unsigned_64'Last - Total then
            return False;
         end if;
         Total := Total + Amount;
         return True;
      end Add;

      function Add_Product
        (Total : in out Interfaces.Unsigned_64;
         Count : Interfaces.Unsigned_64;
         Width : Interfaces.Unsigned_64) return Boolean
      is
         Product : Interfaces.Unsigned_64;
      begin
         if Count > 0 and then Width > Interfaces.Unsigned_64'Last / Count then
            return False;
         end if;
         Product := Count * Width;
         return Add (Total, Product);
      end Add_Product;
   begin
      Maximum := 0;
      if not State.LSM_Authority.Enabled then
         Result := Invalid_State;
         return;
      elsif State.LSM_Authority.Maximum_Point_Reads_Per_Transaction = 0
        or else State.LSM_Authority.Maximum_Scan_Ranges_Per_Transaction = 0
      then
         Result := Unsupported_Format;
         return;
      end if;
      State.Gate.Checkpoint_Metadata (Base, Identity_Total, Result);
      if Result /= Success then
         return;
      elsif Interfaces.Unsigned_64 (Identity_Total)
        > Interfaces.Unsigned_64 (State.LSM_Authority.Maximum_Checkpoint_Identities)
      then
         Result := Capacity_Exceeded;
         return;
      end if;

      --  The one synchronous scratch block is allocated only for this call.
      --  Its safe current-writer extent derives from persisted live-entry and
      --  live-byte authority plus frozen SST-v2 frame/index geometry. Index
      --  keys can duplicate at most every live key byte, so twice the complete
      --  live-state byte authority is a safe bound, not a library ceiling.
      if not Add_Product
               (SST_Bound,
                Interfaces.Unsigned_64 (Base.Limits.Maximum_Live_Entries),
                Interfaces.Unsigned_64
                  (LSM_Runtime.SST_V2_Frame_Header_Length
                   + LSM_Runtime.SST_V2_Frame_Trailer_Length
                   + LSM_Runtime.SST_V2_Index_Entry_Header_Length))
        or else not Add (SST_Bound, Base.Limits.Maximum_Live_State_Bytes)
        or else not Add (SST_Bound, Base.Limits.Maximum_Live_State_Bytes)
      then
         Result := Capacity_Exceeded;
         return;
      end if;

      --  The manifest extent uses immutable registry names, persisted total
      --  run/identity ceilings, and frozen manifest-v3 field widths. It stays
      --  safe while already-admitted commits drain before checkpoint capture.
      for Index in Manifests.Family_Slot range 1 .. Base.Family_Total loop
         if not Add
                  (Manifest_Bound,
                   Interfaces.Unsigned_64
                     (LSM_Runtime.LSM.Checkpoint_Family_Header_Length
                      + Base.Families (Index).Name_Length))
         then
            Result := Capacity_Exceeded;
            return;
         end if;
      end loop;
      if Additional_Family_Name_Length > 0
        and then not Add
          (Manifest_Bound,
           Interfaces.Unsigned_64
             (LSM_Runtime.LSM.Checkpoint_Family_Header_Length + Additional_Family_Name_Length))
      then
         Result := Capacity_Exceeded;
         return;
      end if;
      if not Add_Product
               (Manifest_Bound,
                Interfaces.Unsigned_64 (State.LSM_Authority.Maximum_Total_L0_Runs),
                Interfaces.Unsigned_64 (LSM_Runtime.LSM.Run_Descriptor_Length))
        or else not Add_Product
                      (Manifest_Bound,
                       Interfaces.Unsigned_64 (State.LSM_Authority.Maximum_Checkpoint_Identities),
                       Interfaces.Unsigned_64 (Heads.Identifier_Length))
      then
         Result := Capacity_Exceeded;
         return;
      end if;

      declare
         Bound : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64'Max
             (Interfaces.Unsigned_64 (Formats.Head_Image_Length),
              Interfaces.Unsigned_64'Max (SST_Bound, Manifest_Bound));
      begin
         if Bound = 0 or else Bound > Interfaces.Unsigned_64 (Natural'Last) then
            Result := Capacity_Exceeded;
         else
            Maximum := Natural (Bound);
            Result := Success;
         end if;
      end;
   end Synchronous_Checkpoint_Buffer_Capacity;

   procedure Drive_Synchronous_Checkpoint
     (Item                 : in out Database;
      Runs                 : Checkpoint_Run_Identity_Array;
      Manifest_ID          : Identifier;
      Transition_ID        : Identifier;
      Replace_Current_Runs : Boolean;
      Timeout              : Duration;
      Token                : access Flyology.Cancellation.Token;
      Receipt              : out Flush_Receipt;
      Result               : out Outcome_Code)
   is
      --  One DB parent, one Object Storage child, one HTTP exchange, and one
      --  transport child are the exact client checkpoint owner stack. This
      --  private derived capacity is not a DB queue, connection, or default.
      Synchronous_Set_Capacity : constant := 4;
      Lease                    : aliased Lifecycle_Lease;
      Storage                  : access Storage_Context;
      Maximum                  : Natural := 0;
   begin
      Receipt := (others => <>);
      Acquire (Item, Lease, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Storage := Lease.State.Storage;
      if Storage.HTTP_Client = null then
         --  Backend-neutral memory/files operation remains synchronous until
         --  those backends expose a caller-driven child. The client path below
         --  is a literal wait over the public composable DB state machine.
         null;
      elsif Storage.Client_Identity = null then
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      else
         Synchronous_Checkpoint_Buffer_Capacity (Lease.State, 0, Maximum, Result);
         if Result /= Success then
            Receipt.Current_Outcome := Result;
            return;
         end if;
         declare
            Body_Entered : Boolean := False;

            procedure Drive_Client_Checkpoint is
               Set : aliased Flyology.Operations.Completion_Set (Synchronous_Set_Capacity);
               --  Exactly one moved payload token exists in this serial wait.
               --  Capacity one is ownership geometry, not persisted DB policy.
               Pool : aliased Flyology.Buffers.Pool
                 (Block_Size => Positive (Maximum), Capacity => 1);
               Payload_Buffer : Flyology.Buffers.Unique_Buffer (Pool'Access);
               Operation      : Flush_Operation
                 (Set'Access,
                  Item'Unchecked_Access,
                  Storage,
                  Storage.HTTP_Client,
                  Pool'Access,
                  Token);
               Started        : Boolean := False;
            begin
               Body_Entered := True;
               Flyology.Buffers.Acquire (Payload_Buffer);
               Start_Composable_Checkpoint
                 (Operation,
                  Runs,
                  Manifest_ID,
                  Transition_ID,
                  Payload_Buffer,
                  Timeout,
                  (if Replace_Current_Runs then Complete_Replacement_Plan else Additive_Plan),
                  (others => <>),
                  Zero_Identifier,
                  Zero_Identifier,
                  Zero_Identifier,
                  Zero_Identifier,
                  Lease'Access);
               Started := True;
               Flyology.Operations.Wait_All (Set);
               Finish (Operation, Receipt, Result, Payload_Buffer);
            exception
               when Storage_Error =>
                  Receipt := (if Started then Operation.Final_Receipt else (others => <>));
                  Result :=
                    (if not Started or else Receipt.Phase = No_Flush_Publication
                     then Capacity_Exceeded
                     elsif Receipt.Phase in Objects_Unknown | Flush_Head_Unknown
                     then Outcome_Unknown
                     elsif Receipt.Phase = Flush_Head_Confirmed
                     then Local_Activation_Failed
                     else Storage_Failure);
                  Receipt.Current_Outcome := Result;
               when others =>
                  if not Started then
                     Result := Storage_Failure;
                     Receipt := (others => <>);
                  else
                     Receipt := Operation.Final_Receipt;
                     Result :=
                       (if Operation.Has_Final_Result
                        then Operation.Final_Result
                        elsif Receipt.Phase in Objects_Unknown | Flush_Head_Unknown
                        then Outcome_Unknown
                        elsif Receipt.Phase = Flush_Head_Confirmed
                        then Local_Activation_Failed
                        else Storage_Failure);
                  end if;
                  Receipt.Current_Outcome := Result;
            end Drive_Client_Checkpoint;
         begin
            --  A failure while elaborating the temporary completion set or
            --  pool occurs before Drive_Client_Checkpoint can reserve a slot or
            --  enter checkpoint mode, so it is definite capacity failure.
            begin
               Drive_Client_Checkpoint;
            exception
               when Storage_Error =>
                  if not Body_Entered then
                     Receipt := (others => <>);
                     Result := Capacity_Exceeded;
                  else
                     Result :=
                       (if Receipt.Phase in Objects_Unknown | Flush_Head_Unknown
                        then Outcome_Unknown
                        elsif Receipt.Phase = Flush_Head_Confirmed
                        then Local_Activation_Failed
                        else Result);
                  end if;
               when others =>
                  if not Body_Entered then
                     Receipt := (others => <>);
                     Result := Storage_Failure;
                  else
                     Result :=
                       (if Receipt.Phase in Objects_Unknown | Flush_Head_Unknown
                        then Outcome_Unknown
                        elsif Receipt.Phase = Flush_Head_Confirmed
                        then Local_Activation_Failed
                        else Result);
                  end if;
            end;
            if Result /= Success then
               Receipt.Current_Outcome := Result;
            end if;
         end;
         return;
      end if;
      --  End the read lease before the backend-neutral publisher takes the
      --  exclusive checkpoint lifecycle mode.
      Release (Lease);
      Publish_Checkpoint
        (Item,
         Runs,
         Manifest_ID,
         Transition_ID,
         Replace_Current_Runs => Replace_Current_Runs,
         Timeout              => Timeout,
         Token                => Token,
         Receipt              => Receipt,
         Result               => Result);
   end Drive_Synchronous_Checkpoint;

   procedure Flush
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token := null;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      Drive_Synchronous_Checkpoint
        (Item,
         Runs,
         Manifest_ID,
         Transition_ID,
         False,
         Timeout,
         Token,
         Receipt,
         Result);
   end Flush;

   procedure Compact
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      Drive_Synchronous_Checkpoint
        (Item,
         Runs,
         Manifest_ID,
         Transition_ID,
         True,
         Timeout,
         Token,
         Receipt,
         Result);
   end Compact;

   procedure Activate_Recovered_Flush
     (Item          : in out Database;
      Old_State     : in out Engine_State_Access;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Manifest      : Manifests.Manifest;
      LSM_Authority : Engine_LSM_Authority;
      Checkpoint    : in out Checkpoint_Plan;
      History       : in out Batch_History_Access;
      History_Count : in out Natural;
      Receipt       : in out Flush_Receipt;
      Guard         : in out Checkpoint_Guard;
      Result        : out Outcome_Code)
   is
      New_State        : Engine_State_Access := null;
      --  Recovery activates the same logical open database after confirmed
      --  Flush publication, so the original handle incarnation remains valid.
      Stamp            : constant Engine_Incarnation := Old_State.Gate.Current_Incarnation;
      Activation_Fault : Storage_Fault_Mode;
   begin
      Receipt.Phase := Flush_Head_Confirmed;
      Receipt.Current_Outcome := Success;
      Old_State.Gate.Fence;
      Consume_Fault (Old_State.Storage.all, Before_Local_Activation, Activation_Fault);
      if Activation_Fault = No_Fault then
         Allocation_Faults.Check (Flush_Activation_State_Allocation);
         Allocate_Engine
           (Item.Life'Unchecked_Access,
            Old_State.Storage,
            Head,
            Generation,
            Manifest,
            LSM_Authority,
            Checkpoint,
            Stamp,
            History,
            History_Count,
            New_State,
            Result);
      else
         Result := Local_Activation_Failed;
      end if;
      if Result /= Success then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Receipt.Current_Outcome := Local_Activation_Failed;
         Result := Local_Activation_Failed;
         return;
      end if;
      Item.Life.Finish_Checkpoint (New_State, Head.Highest);
      Guard.Active := False;
      Stop_Replaced_Engine (Old_State);
      Receipt.Phase := Flush_Resolved;
      Receipt.Current_Outcome := Success;
      Result := Success;
   exception
      when Storage_Error =>
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Receipt.Current_Outcome := Local_Activation_Failed;
         Result := Local_Activation_Failed;
   end Activate_Recovered_Flush;

   procedure Resolve_Flush
     (Item    : in out Database;
      Receipt : in out Flush_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code)
   is
      --  Resolution receives a fresh caller budget but still performs no
      --  hidden retry; every child uses this one absolute deadline.
      Deadline      : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      State         : Engine_State_Access;
      Plan          : Checkpoint_Plan;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Current_Head  : Head_Snapshot;
      Current_Gen   : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      Manifest      : Manifests.Manifest;
      Root          : Manifests.Manifest;
      LSM_Authority : Engine_LSM_Authority;
      History       : Batch_History_Access := null;
      History_Count : Natural := 0;
      Guard         : Checkpoint_Guard;
   begin
      if Receipt.Phase not in Objects_Unknown | Flush_Head_Unknown | Flush_Head_Confirmed
        or else Receipt.Run_Total = 0
        or else Receipt.Database_ID = Zero_Database_ID
        or else Is_Zero (Receipt.Manifest_ID)
        or else
          (if Receipt.Merges_Adjacent_Runs
           then
             Receipt.Replaces_Current_Runs
             or else Receipt.Run_Total /= 1
             or else Is_Zero (Receipt.Older_Run_ID)
             or else Is_Zero (Receipt.Newer_Run_ID)
             or else Receipt.Older_Run_ID = Receipt.Newer_Run_ID
             or else
               (if Receipt.Merges_Three_Runs
                then
                  Is_Zero (Receipt.Middle_Run_ID)
                  or else Receipt.Middle_Run_ID = Receipt.Older_Run_ID
                  or else Receipt.Middle_Run_ID = Receipt.Newer_Run_ID
                else not Is_Zero (Receipt.Middle_Run_ID))
           else
             Receipt.Merges_Three_Runs
             or else not Is_Zero (Receipt.Older_Run_ID)
             or else not Is_Zero (Receipt.Middle_Run_ID)
             or else not Is_Zero (Receipt.Newer_Run_ID))
      then
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      State.Gate.Snapshot (Current_Head, Current_Gen, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
      elsif Receipt.Incarnation /= State.Gate.Current_Incarnation
        or else not Fenced
        or else Current_Head /= Receipt.Expected_Head
        or else Current_Gen /= Receipt.Expected_Generation
      then
         Result := Invalid_State;
      elsif Receipt.Phase = Objects_Unknown then
         if Receipt.Merges_Adjacent_Runs then
            Build_Selected_Merge_Plan
              (State,
               Receipt.Older_Run_ID,
               Receipt.Middle_Run_ID,
               Receipt.Newer_Run_ID,
               Receipt.Runs (1).Run_ID,
               Receipt.Manifest_ID,
               Receipt.Attempted_Head.Transition_ID,
               Deadline,
               Token,
               Plan,
               Result,
               Allow_Fenced => True);
            if Result = Success then
               declare
                  Exact_Output : Boolean := False;
               begin
                  for Index in Plan.SSTs'Range loop
                     if Plan.SSTs (Index) /= null then
                        if Exact_Output
                          or else Receipt.Run_Total /= 1
                          or else Receipt.Runs (1).Family_ID /=
                            Column_Family_ID (Plan.Manifest.Base.Families (Index).ID)
                          or else Receipt.Runs (1).Run_ID /=
                            To_Identifier (Plan.SSTs (Index).Run_ID)
                        then
                           Result := Invalid_State;
                           exit;
                        end if;
                        Exact_Output := True;
                     end if;
                  end loop;
                  if Result = Success and then not Exact_Output then
                     Result := Invalid_State;
                  end if;
               end;
            end if;
         else
            Build_Checkpoint_Plan
              (State,
               Receipt.Runs (1 .. Receipt.Run_Total),
               Receipt.Manifest_ID,
               Receipt.Attempted_Head.Transition_ID,
               Plan,
               Result,
               Replace_Current_Runs => Receipt.Replaces_Current_Runs,
               Allow_Fenced => True);
         end if;
         if Result = Success and then not Plan_Matches_Receipt (Plan, Current_Head, Receipt) then
            Result := Invalid_State;
         end if;
         if Result = Success then
            Publish_Flush_Plan (Item, State, Plan, Deadline, Token, Receipt, Guard, Result);
         end if;
      else
         Read_Recovery
           (State.Storage.all,
            Receipt.Database_ID,
            Deadline,
            Token,
            Head,
            Generation,
            Manifest,
            Root,
            LSM_Authority,
            Plan,
            History,
            History_Count,
            Result);
         if Result = Success
           and then Plan.Manifest /= null
           and then To_Identifier (Plan.Manifest.Base.Manifest_ID) = Receipt.Manifest_ID
           and then Plan.Manifest.Replay_Boundary = Interfaces.Unsigned_64 (Receipt.Replay_Boundary)
           and then (Head = Receipt.Attempted_Head
                     or else (Head.Transition_Number > Receipt.Attempted_Head.Transition_Number
                              and then Head.Latest_Manifest = Receipt.Manifest_ID))
         then
            Activate_Recovered_Flush
              (Item,
               State,
               Head,
               Generation,
               Manifest,
               LSM_Authority,
               Plan,
               History,
               History_Count,
               Receipt,
               Guard,
               Result);
         elsif Result = Success and then Head = Receipt.Attempted_Head then
            --  The exact attempted HEAD can only be valid when cacheless
            --  recovery also reaches its exact checkpoint manifest/boundary.
            --  Missing or mismatched immutable authority is corruption, not a
            --  competing-writer rejection.
            Result := Corrupt;
         elsif Result = Success and then Head.Transition_Number >= Receipt.Attempted_Head.Transition_Number
         then
            State.Gate.Fence;
            Receipt.Phase := Flush_Resolved;
            Result := Stale_Writer;
         elsif Result = Success then
            Result := Outcome_Unknown;
         end if;
      end if;
      Release_History (History, History_Count);
      Release_Checkpoint_Plan (Plan);
      if Guard.Active then
         Item.Life.Finish_Checkpoint;
         Guard.Active := False;
      end if;
      Receipt.Current_Outcome := Result;
   exception
      when others =>
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Plan);
         if Guard.Active then
            State.Gate.Fence;
            Item.Life.Finish_Checkpoint;
            Guard.Active := False;
         end if;
         Result :=
           (if Receipt.Phase = Flush_Head_Confirmed then Local_Activation_Failed else Outcome_Unknown);
         Receipt.Current_Outcome := Result;
   end Resolve_Flush;

   function Flush_Receipt_Outcome (Item : Flush_Receipt) return Outcome_Code
   is (Item.Current_Outcome);

   function Flush_Receipt_Manifest_ID (Item : Flush_Receipt) return Identifier
   is (Item.Manifest_ID);

   function Flush_Receipt_Transition_ID (Item : Flush_Receipt) return Identifier
   is (Item.Attempted_Head.Transition_ID);

   function Flush_Receipt_Replay_Boundary (Item : Flush_Receipt) return Sequence_Number
   is (Item.Replay_Boundary);

   function Flush_Receipt_Run_Total (Item : Flush_Receipt) return Natural
   is (Item.Run_Total);

   function Flush_Receipt_Run (Item : Flush_Receipt; Index : Positive) return Checkpoint_Run_Identity is
   begin
      if Index > Item.Run_Total then
         raise Constraint_Error with "flush receipt run index is out of range";
      end if;
      return Item.Runs (Index);
   end Flush_Receipt_Run;

   procedure Initialize_Column_Family_Receipt
     (State          : not null Engine_State_Access;
      Configuration  : Column_Family_Configuration;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Plan           : Checkpoint_Plan;
      Receipt        : out Column_Family_Receipt;
      Result         : out Outcome_Code)
   is
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      Encoded       : LSM_Runtime.Image_Access := null;
      Encode_Result : LSM_Runtime.Encode_Status;
   begin
      Receipt := (others => <>);
      State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Plan.Manifest = null
        or else Uncertain
        or else Fenced
        or else Generation /= Plan.Expected_Generation
      then
         Result := (if Uncertain then Outcome_Unknown elsif Fenced then Stale_Writer else Invalid_State);
         return;
      end if;
      LSM_Runtime.Encode_Checkpoint_Manifest (Plan.Manifest.all, Encoded, Encode_Result);
      if Encode_Result /= LSM_Runtime.Encoded then
         LSM_Runtime.Release (Encoded);
         Result := (if Encode_Result = LSM_Runtime.Allocation_Failed then Capacity_Exceeded else Corrupt);
         return;
      end if;
      Receipt.Configuration := Configuration;
      Receipt.Database_ID := Head.Database_ID;
      Receipt.Incarnation := State.Gate.Current_Incarnation;
      Receipt.Manifest_ID := Manifest_ID;
      Receipt.Expected_Generation := Generation;
      Receipt.Expected_Head := Head;
      Receipt.Attempted_Head :=
        (Database_ID            => Head.Database_ID,
         Version                => Head.Version,
         Epoch                  => Head.Epoch,
         Highest                => Head.Highest,
         Latest_Batch           => Head.Latest_Batch,
         Latest_Manifest        => Manifest_ID,
         Transition_ID          => Transition_ID,
         Predecessor_Transition => Head.Transition_ID,
         Transition_Number      => Head.Transition_Number + 1);
      Receipt.Retained_Manifest.Image := New_Image (Encoded.all);
      LSM_Runtime.Release (Encoded);
      Result := Success;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Encoded);
         Release_Retained_Manifest (Receipt);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Encoded);
         Release_Retained_Manifest (Receipt);
         raise;
   end Initialize_Column_Family_Receipt;

   function Family_Configuration_Matches
     (Manifest      : Manifests.Manifest;
      LSM_Authority : Engine_LSM_Authority;
      Expected      : Column_Family_Configuration) return Boolean
   is
      Actual : Column_Family_Configuration;
   begin
      for Index in Manifests.Family_Slot range 1 .. Manifest.Family_Total loop
         if Manifest.Families (Index).ID = Interfaces.Unsigned_32 (Expected.ID) then
            Actual := From_Manifest_Configuration (Manifest.Families (Index));
            Actual.Memtable_Max_Bytes := LSM_Authority.Families (Index).State.Memtable_Max_Bytes;
            Actual.Memtable_Max_Entries := LSM_Authority.Families (Index).State.Memtable_Max_Entries;
            Actual.Maximum_L0_Runs := LSM_Authority.Families (Index).State.Maximum_L0_Runs;
            return LSM_Authority.Families (Index).ID = Manifest.Families (Index).ID
              and then Same_Configuration (Actual, Expected);
         end if;
      end loop;
      return False;
   end Family_Configuration_Matches;

   procedure Recover_Column_Family_Activation
     (Item     : in out Database;
      State    : in out Engine_State_Access;
      Deadline : Ada.Real_Time.Time;
      Token    : access Flyology.Cancellation.Token;
      Receipt  : in out Column_Family_Receipt;
      Guard    : in out Checkpoint_Guard;
      Result   : out Outcome_Code)
   is
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Manifest      : Manifests.Manifest;
      Root          : Manifests.Manifest;
      LSM_Authority : Engine_LSM_Authority;
      Checkpoint    : Checkpoint_Plan;
      History       : Batch_History_Access := null;
      History_Count : Natural := 0;
      Sought_Found  : aliased Boolean := False;
      Core          : Flush_Receipt;
   begin
      Read_Recovery
        (State.Storage.all,
         Receipt.Database_ID,
         Deadline,
         Token,
         Head,
         Generation,
         Manifest,
         Root,
         LSM_Authority,
         Checkpoint,
         History,
         History_Count,
         Result,
         Sought_Manifest => Receipt.Manifest_ID,
         Sought_Found    => Sought_Found'Access);
      if Result /= Success then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Result :=
           (if Receipt.Phase = Family_Head_Confirmed
            then Local_Activation_Failed
            else Outcome_Unknown);
         Receipt.Current_Outcome := Result;
         return;
      elsif Head.Transition_Number < Receipt.Attempted_Head.Transition_Number then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Result :=
           (if Receipt.Phase = Family_Head_Confirmed
            then Local_Activation_Failed
            else Outcome_Unknown);
         Receipt.Current_Outcome := Result;
         return;
      elsif not Sought_Found then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         State.Gate.Fence;
         if Receipt.Phase = Family_Head_Confirmed then
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
         else
            Receipt.Phase := Family_Resolved;
            Receipt.Current_Outcome := Stale_Writer;
            Release_Retained_Manifest (Receipt);
            Result := Stale_Writer;
         end if;
         return;
      end if;

      --  A complete validated successor chain containing the exact attempted
      --  immutable manifest conclusively establishes publication even when
      --  the original conditional-HEAD response was lost. Failures after this
      --  point are local activation failures, never publication uncertainty.
      Receipt.Phase := Family_Head_Confirmed;
      if Checkpoint.Manifest = null
        or else not Family_Configuration_Matches (Manifest, LSM_Authority, Receipt.Configuration)
      then
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         State.Gate.Fence;
         Result := Local_Activation_Failed;
         Receipt.Current_Outcome := Result;
         return;
      end if;

      Core :=
        (Current_Outcome     => Success,
         Phase               => Flush_Head_Confirmed,
         Database_ID         => Receipt.Database_ID,
         Incarnation         => Receipt.Incarnation,
         Manifest_ID         => Receipt.Manifest_ID,
         Replay_Boundary     => Sequence_Number (Checkpoint.Manifest.Replay_Boundary),
         Expected_Generation => Receipt.Expected_Generation,
         Expected_Head       => Receipt.Expected_Head,
         Attempted_Head      => Receipt.Attempted_Head,
         others              => <>);
      Activate_Recovered_Flush
        (Item,
         State,
         Head,
         Generation,
         Manifest,
         LSM_Authority,
         Checkpoint,
         History,
         History_Count,
         Core,
         Guard,
         Result);
      Release_History (History, History_Count);
      Release_Checkpoint_Plan (Checkpoint);
      if Result = Success then
         Receipt.Phase := Family_Resolved;
         Receipt.Current_Outcome := Success;
         Release_Retained_Manifest (Receipt);
      else
         Receipt.Phase := Family_Head_Confirmed;
         Receipt.Current_Outcome := Local_Activation_Failed;
         Result := Local_Activation_Failed;
      end if;
   exception
      when others =>
         Release_History (History, History_Count);
         Release_Checkpoint_Plan (Checkpoint);
         Receipt.Phase := Family_Head_Confirmed;
         Receipt.Current_Outcome := Local_Activation_Failed;
         Result := Local_Activation_Failed;
   end Recover_Column_Family_Activation;

   procedure Attempt_Column_Family_Head
     (Item     : in out Database;
      State    : in out Engine_State_Access;
      Deadline : Ada.Real_Time.Time;
      Token    : access Flyology.Cancellation.Token;
      Receipt  : in out Column_Family_Receipt;
      Guard    : in out Checkpoint_Guard;
      Result   : out Outcome_Code)
   is
      Owner          : Shared_Image_Access := null;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;
   begin
      if Token /= null and then Token.Requested then
         Receipt.Phase := Family_Resolved;
         Receipt.Current_Outcome := Cancelled;
         Release_Retained_Manifest (Receipt);
         Result := Cancelled;
         return;
      elsif Deadline <= Ada.Real_Time.Clock then
         Receipt.Phase := Family_Resolved;
         Receipt.Current_Outcome := Timed_Out;
         Release_Retained_Manifest (Receipt);
         Result := Timed_Out;
         return;
      end if;
      Owner := New_Image (Formats.Encode_Head (To_Head (Receipt.Attempted_Head)));
      Receipt.Phase := Family_Head_Unknown;
      Receipt.Head_Entered := True;
      Storage_Port.Put_Replace
        (State.Storage.all,
         Full_Key (State.Storage.all, Head_Key_Suffix),
         Owner,
         Receipt.Expected_Generation,
         Deadline,
         Token,
         New_Generation,
         Put_Result);
      Release_Image (Owner);
      if Put_Result = Object_Published then
         Receipt.Phase := Family_Head_Confirmed;
         Recover_Column_Family_Activation (Item, State, Deadline, Token, Receipt, Guard, Result);
      elsif Put_Result = Put_Precondition_Failed then
         State.Gate.Fence;
         Receipt.Phase := Family_Resolved;
         Receipt.Current_Outcome := Stale_Writer;
         Release_Retained_Manifest (Receipt);
         Result := Stale_Writer;
      elsif Put_Result = Put_Outcome_Unknown then
         State.Gate.Fence;
         Receipt.Current_Outcome := Outcome_Unknown;
         Result := Outcome_Unknown;
      elsif Put_Result = Put_Cancelled then
         Receipt.Phase := Family_Resolved;
         Receipt.Current_Outcome := Cancelled;
         Release_Retained_Manifest (Receipt);
         Result := Cancelled;
      elsif Put_Result = Put_Timed_Out then
         Receipt.Phase := Family_Resolved;
         Receipt.Current_Outcome := Timed_Out;
         Release_Retained_Manifest (Receipt);
         Result := Timed_Out;
      else
         Receipt.Phase := Family_Resolved;
         Receipt.Current_Outcome := Storage_Failure;
         Release_Retained_Manifest (Receipt);
         Result := Storage_Failure;
      end if;
   exception
      when others =>
         Release_Image (Owner);
         if Receipt.Phase = Family_Head_Confirmed then
            State.Gate.Fence;
            Result := Local_Activation_Failed;
         else
            State.Gate.Fence;
            Result := Outcome_Unknown;
         end if;
         Receipt.Current_Outcome := Result;
   end Attempt_Column_Family_Head;

   procedure Publish_Column_Family_Plan
     (Item     : in out Database;
      State    : in out Engine_State_Access;
      Deadline : Ada.Real_Time.Time;
      Token    : access Flyology.Cancellation.Token;
      Receipt  : in out Column_Family_Receipt;
      Guard    : in out Checkpoint_Guard;
      Result   : out Outcome_Code)
   is
   begin
      Receipt.Phase := Family_Manifest_Unknown;
      Confirm_Immutable_Object
        (State.Storage.all,
         Manifest_Key (State.Storage.all, Receipt.Manifest_ID),
         Manifest_Object,
         Receipt.Retained_Manifest.Image,
         Deadline,
         Token,
         Result);
      if Result = Success then
         Attempt_Column_Family_Head (Item, State, Deadline, Token, Receipt, Guard, Result);
      elsif Result = Outcome_Unknown then
         State.Gate.Fence;
         Receipt.Current_Outcome := Outcome_Unknown;
      else
         Receipt.Phase := Family_Resolved;
         Receipt.Current_Outcome := Result;
         Release_Retained_Manifest (Receipt);
      end if;
   exception
      when others =>
         if Receipt.Phase in Family_Manifest_Unknown | Family_Head_Unknown then
            State.Gate.Fence;
            Result := Outcome_Unknown;
         elsif Receipt.Phase = Family_Head_Confirmed then
            State.Gate.Fence;
            Result := Local_Activation_Failed;
         else
            Result := Storage_Failure;
         end if;
         Receipt.Current_Outcome := Result;
   end Publish_Column_Family_Plan;

   procedure Add_Column_Family
     (Item          : in out Database;
      Configuration : Column_Family_Configuration;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token := null;
      Receipt       : out Column_Family_Receipt;
      Result        : out Outcome_Code)
   is
      Deadline : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      State    : Engine_State_Access := null;
      Plan     : Checkpoint_Plan;
      Guard    : Checkpoint_Guard;
      Lease    : aliased Lifecycle_Lease;
      Storage  : access Storage_Context;
      Maximum  : Natural := 0;
      --  One DB parent, one Object Storage child, one HTTP exchange, and one
      --  transport child are the exact family-append owner stack. This is
      --  operation geometry, not a DB queue, connection, or public default.
      Synchronous_Set_Capacity : constant := 4;
   begin
      Receipt := (others => <>);
      Acquire (Item, Lease, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Storage := Lease.State.Storage;
      if Storage.HTTP_Client /= null then
         if Storage.Client_Identity = null then
            Receipt.Current_Outcome := Invalid_State;
            Result := Invalid_State;
            return;
         end if;
         Synchronous_Checkpoint_Buffer_Capacity
           (Lease.State, Configuration.Name_Length, Maximum, Result);
         if Result /= Success then
            Receipt.Current_Outcome := Result;
            return;
         end if;
         declare
            Set : aliased Flyology.Operations.Completion_Set (Synchronous_Set_Capacity);
            --  Exactly one moved payload token exists in this serial wait.
            --  Capacity one is ownership geometry, not persisted DB policy.
            Pool : aliased Flyology.Buffers.Pool
              (Block_Size => Positive (Maximum), Capacity => 1);
            Payload_Buffer : Flyology.Buffers.Unique_Buffer (Pool'Access);
            Operation      : Flush_Operation
              (Set'Access,
               Item'Unchecked_Access,
               Storage,
               Storage.HTTP_Client,
               Pool'Access,
               Token);
            No_Runs        : Checkpoint_Run_Identity_Array (1 .. 0);
            Started        : Boolean := False;
         begin
            Flyology.Buffers.Acquire (Payload_Buffer);
            Start_Composable_Checkpoint
              (Operation,
               No_Runs,
               Manifest_ID,
               Transition_ID,
               Payload_Buffer,
               Remaining_Time (Deadline),
               Family_Append_Plan,
               Configuration,
               Zero_Identifier,
               Zero_Identifier,
               Zero_Identifier,
               Zero_Identifier,
               Lease'Access);
            Started := True;
            Flyology.Operations.Wait_All (Set);
            Finish (Operation, Receipt, Result, Payload_Buffer);
         exception
            when Storage_Error =>
               Receipt := (if Started then Operation.Final_Family_Receipt else (others => <>));
               Result :=
                 (if not Started or else Receipt.Phase = No_Family_Publication
                  then Capacity_Exceeded
                  elsif Receipt.Phase in Family_Manifest_Unknown | Family_Head_Unknown
                  then Outcome_Unknown
                  elsif Receipt.Phase = Family_Head_Confirmed
                  then Local_Activation_Failed
                  else Storage_Failure);
               Receipt.Current_Outcome := Result;
            when others =>
               Receipt := (if Started then Operation.Final_Family_Receipt else (others => <>));
               Result :=
                 (if Started
                    and then Receipt.Phase in Family_Manifest_Unknown | Family_Head_Unknown
                  then Outcome_Unknown
                  elsif Started and then Receipt.Phase = Family_Head_Confirmed
                  then Local_Activation_Failed
                  else Storage_Failure);
               Receipt.Current_Outcome := Result;
         end;
         return;
      end if;
      Release (Lease);
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      Build_Column_Family_Plan
        (State,
         Configuration,
         Manifest_ID,
         Transition_ID,
         False,
         Plan,
         Result);
      if Result = Success then
         Initialize_Column_Family_Receipt
           (State, Configuration, Manifest_ID, Transition_ID, Plan, Receipt, Result);
      end if;
      if Result = Success then
         Publish_Column_Family_Plan (Item, State, Deadline, Token, Receipt, Guard, Result);
      end if;
      Release_Checkpoint_Plan (Plan);
      if Guard.Active then
         Item.Life.Finish_Checkpoint;
         Guard.Active := False;
      end if;
      Receipt.Current_Outcome := Result;
   exception
      when Storage_Error =>
         Release_Checkpoint_Plan (Plan);
         if Guard.Active then
            if Receipt.Phase in Family_Manifest_Unknown | Family_Head_Unknown then
               State.Gate.Fence;
               Result := Outcome_Unknown;
            elsif Receipt.Phase = Family_Head_Confirmed then
               State.Gate.Fence;
               Result := Local_Activation_Failed;
            else
               Result := Capacity_Exceeded;
            end if;
            Item.Life.Finish_Checkpoint;
            Guard.Active := False;
         else
            Result := Local_Activation_Failed;
         end if;
         Receipt.Current_Outcome := Result;
      when others =>
         Release_Checkpoint_Plan (Plan);
         if Guard.Active then
            if Receipt.Phase in Family_Manifest_Unknown | Family_Head_Unknown then
               State.Gate.Fence;
               Result := Outcome_Unknown;
            elsif Receipt.Phase = Family_Head_Confirmed then
               State.Gate.Fence;
               Result := Local_Activation_Failed;
            else
               Result := Storage_Failure;
            end if;
            Item.Life.Finish_Checkpoint;
            Guard.Active := False;
         else
            Result := Local_Activation_Failed;
         end if;
         Receipt.Current_Outcome := Result;
   end Add_Column_Family;

   procedure Resolve_Add_Column_Family
     (Item    : in out Database;
      Receipt : in out Column_Family_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code)
   is
      Deadline   : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      State      : Engine_State_Access := null;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Uncertain  : Boolean;
      Fenced     : Boolean;
      Guard      : Checkpoint_Guard;
   begin
      if Receipt.Phase not in Family_Manifest_Unknown | Family_Head_Unknown | Family_Head_Confirmed
        or else Receipt.Database_ID = Zero_Database_ID
        or else Receipt.Incarnation = No_Incarnation
        or else Is_Zero (Receipt.Manifest_ID)
        or else Receipt.Retained_Manifest.Image = null
      then
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if State.Gate.Current_Incarnation /= Receipt.Incarnation
        or else Head.Database_ID /= Receipt.Database_ID
        or else Head /= Receipt.Expected_Head
        or else Generation /= Receipt.Expected_Generation
      then
         Result := Invalid_State;
      elsif Receipt.Phase = Family_Manifest_Unknown then
         Confirm_Immutable_Object
           (State.Storage.all,
            Manifest_Key (State.Storage.all, Receipt.Manifest_ID),
            Manifest_Object,
            Receipt.Retained_Manifest.Image,
            Deadline,
            Token,
            Result);
         if Result = Success then
            Attempt_Column_Family_Head (Item, State, Deadline, Token, Receipt, Guard, Result);
         elsif Result /= Outcome_Unknown then
            Receipt.Phase := Family_Resolved;
            Release_Retained_Manifest (Receipt);
         end if;
      else
         Recover_Column_Family_Activation (Item, State, Deadline, Token, Receipt, Guard, Result);
      end if;
      if Guard.Active then
         Item.Life.Finish_Checkpoint;
         Guard.Active := False;
      end if;
      Receipt.Current_Outcome := Result;
   exception
      when others =>
         if Guard.Active then
            if Receipt.Phase = Family_Head_Confirmed then
               State.Gate.Fence;
               Result := Local_Activation_Failed;
            else
               State.Gate.Fence;
               Result := Outcome_Unknown;
            end if;
            Item.Life.Finish_Checkpoint;
            Guard.Active := False;
         else
            Result := Local_Activation_Failed;
         end if;
         Receipt.Current_Outcome := Result;
   end Resolve_Add_Column_Family;

   function Column_Family_Receipt_Outcome (Item : Column_Family_Receipt) return Outcome_Code
   is (Item.Current_Outcome);

   function Column_Family_Receipt_Family_ID (Item : Column_Family_Receipt) return Column_Family_ID
   is (Item.Configuration.ID);

   function Column_Family_Receipt_Manifest_ID (Item : Column_Family_Receipt) return Identifier
   is (Item.Manifest_ID);

   function Column_Family_Receipt_Transition_ID (Item : Column_Family_Receipt) return Identifier
   is (if Item.Head_Entered then Item.Attempted_Head.Transition_ID else Zero_Identifier);

   procedure Highest_Visible (Item : in out Database; Value : out Sequence_Number; Result : out Outcome_Code)
   is
   begin
      Value := Item.Life.Highest (Result);
   end Highest_Visible;

   procedure Observe_L0_Checkpoint
     (Item             : in out Database;
      Include_Families : Boolean;
      Action           : out L0_Checkpoint_Action;
      Families         : out L0_Checkpoint_Family_Array_Access;
      Result           : out Outcome_Code)
   is
      State          : Engine_State_Access;
      Guard          : Checkpoint_Guard;
      Head           : Head_Snapshot;
      Generation     : Generation_Value;
      Uncertain      : Boolean;
      Fenced         : Boolean;
      Family_Total   : Natural := 0;
      Found_Gap      : Boolean := False;
   begin
      Action := No_L0_Checkpoint_Work;
      Families := null;
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;

      if not State.LSM_Authority.Enabled then
         Result := Unsupported_Format;
      elsif State.LSM_Authority.Maximum_Point_Reads_Per_Transaction = 0
        or else State.LSM_Authority.Maximum_Scan_Ranges_Per_Transaction = 0
      then
         Result := Unsupported_Format;
      else
         State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
         if Uncertain then
            Result := Outcome_Unknown;
         elsif Fenced then
            Result := Stale_Writer;
         elsif State.LSM_Authority.Replay_Boundary > Interfaces.Unsigned_64 (Head.Highest) then
            Result := Corrupt;
         else
            Result := Success;
         end if;
      end if;

      if Result = Success then
         for Index in State.LSM_Authority.Families'Range loop
            if State.LSM_Authority.Families (Index).ID = 0 then
               Found_Gap := True;
            elsif Found_Gap or else Family_Total = Maximum_Initial_Column_Families then
               Result := Corrupt;
               exit;
            else
               Family_Total := Family_Total + 1;
            end if;
         end loop;
      end if;

      if Result = Success and then Family_Total = 0 then
         Result := Corrupt;
      elsif Result = Success then
         --  Scratch state is allocated lazily at the exact persisted family
         --  count. Allocation failure is classified below before any
         --  publication identity or storage effect exists.
         declare
            Entry_Total     : Natural;
            Payload_Bytes   : Natural;
            Family_Position : Natural := 0;
            Selected_Total  : Natural := 0;
            Current_Runs    : Checkpoints.Run_Count_Array (1 .. Family_Total) := [others => 0];
            Maximum_Runs    : Checkpoints.Run_Count_Array (1 .. Family_Total) := [others => 0];
            Changed         : Checkpoints.Family_Flag_Array (1 .. Family_Total) := [others => False];
            Nonempty        : Checkpoints.Family_Flag_Array (1 .. Family_Total) := [others => False];
            Family_IDs      : L0_Checkpoint_Family_Array (1 .. Family_Total);
            Selected        : Checkpoints.Family_Flag_Array (1 .. Family_Total) := [others => False];
            Selection       : Checkpoints.Selection;
         begin
            for Index in State.LSM_Authority.Families'Range loop
               if State.LSM_Authority.Families (Index).ID /= 0 then
                  Family_Position := Family_Position + 1;
                  declare
                     Family : Family_LSM_Authority renames State.LSM_Authority.Families (Index);
                  begin
                     Family_IDs (Family_Position) := Column_Family_ID (Family.ID);
                     Current_Runs (Family_Position) := Interfaces.Unsigned_32 (Family.State.Run_Total);
                     Maximum_Runs (Family_Position) := Family.State.Maximum_L0_Runs;

                     State.Gate.Family_Snapshot_Requirements
                       (Column_Family_ID (Family.ID), Entry_Total, Payload_Bytes, Result);
                     if Result = Success then
                        Nonempty (Family_Position) := True;
                     elsif Result = Not_Found then
                        Result := Success;
                     else
                        exit;
                     end if;

                     if State.LSM_Authority.Replay_Boundary = 0 then
                        Changed (Family_Position) := Nonempty (Family_Position);
                     else
                        State.Gate.Family_Delta_Snapshot
                          (Column_Family_ID (Family.ID), null, Entry_Total, Payload_Bytes, Result);
                        if Result = Success then
                           Changed (Family_Position) := True;
                        elsif Result = Not_Found then
                           Result := Success;
                        else
                           exit;
                        end if;
                     end if;
                  end;
               end if;
            end loop;

            if Result = Success then
               Selection :=
                 Checkpoints.Decide
                   (Current_Runs,
                    Maximum_Runs,
                    Changed,
                    Nonempty,
                    Interfaces.Unsigned_64 (Head.Highest) > State.LSM_Authority.Replay_Boundary,
                    State.LSM_Authority.Maximum_Total_L0_Runs);
               case Selection is
                  when Checkpoints.Invalid_Authority =>
                     Result := Corrupt;
                  when Checkpoints.No_Work =>
                     Action := No_L0_Checkpoint_Work;
                  when Checkpoints.Additive_Flush =>
                     Action := Additive_Flush_Required;
                     Selected := Changed;
                  when Checkpoints.Complete_Compaction =>
                     Action := Complete_Compaction_Required;
                     Selected := Nonempty;
                  when Checkpoints.No_Admissible_Checkpoint =>
                     Result := Capacity_Exceeded;
               end case;

               if Result = Success and then Include_Families and then Action /= No_L0_Checkpoint_Work then
                  for Is_Selected of Selected loop
                     if Is_Selected then
                        Selected_Total := Selected_Total + 1;
                     end if;
                  end loop;
                  if Selected_Total > 0 then
                     Allocation_Faults.Check (Checkpoint_Requirement_Family_Allocation);
                     Families := new L0_Checkpoint_Family_Array (1 .. Selected_Total);
                     Selected_Total := 0;
                     for Index in Selected'Range loop
                        if Selected (Index) then
                           Selected_Total := Selected_Total + 1;
                           Families (Selected_Total) := Family_IDs (Index);
                        end if;
                     end loop;
                  end if;
               end if;
            end if;
         end;
      end if;

      Item.Life.Finish_Checkpoint;
      Guard.Active := False;
   exception
      when Storage_Error =>
         Free_L0_Checkpoint_Families (Families);
         if Guard.Active then
            Item.Life.Finish_Checkpoint;
            Guard.Active := False;
         end if;
         Result := Capacity_Exceeded;
      when others =>
         Free_L0_Checkpoint_Families (Families);
         if Guard.Active then
            Item.Life.Finish_Checkpoint;
            Guard.Active := False;
         end if;
         raise;
   end Observe_L0_Checkpoint;

   procedure Required_L0_Checkpoint_Action
     (Item   : in out Database;
      Action : out L0_Checkpoint_Action;
      Result : out Outcome_Code)
   is
      Families : L0_Checkpoint_Family_Array_Access;
   begin
      Observe_L0_Checkpoint (Item, False, Action, Families, Result);
      Free_L0_Checkpoint_Families (Families);
   end Required_L0_Checkpoint_Action;

   procedure Observe_L0_Checkpoint_Requirement
     (Item        : in out Database;
      Requirement : in out L0_Checkpoint_Requirement;
      Result      : out Outcome_Code)
   is
      Action   : L0_Checkpoint_Action;
      Families : L0_Checkpoint_Family_Array_Access;
      Previous : L0_Checkpoint_Family_Array_Access;
   begin
      Observe_L0_Checkpoint (Item, True, Action, Families, Result);
      if Result = Success then
         Previous := Requirement.State.Families;
         Requirement.State.Action := Action;
         Requirement.State.Families := Families;
         Families := Previous;
      end if;
      Free_L0_Checkpoint_Families (Families);
   exception
      when others =>
         Free_L0_Checkpoint_Families (Families);
         raise;
   end Observe_L0_Checkpoint_Requirement;

   function Checkpoint_Requirement_Action
     (Item : L0_Checkpoint_Requirement) return L0_Checkpoint_Action
   is (Item.State.Action);

   function Checkpoint_Requirement_Family_Total (Item : L0_Checkpoint_Requirement) return Natural
   is (if Item.State.Families = null then 0 else Item.State.Families'Length);

   function Checkpoint_Requirement_Family
     (Item : L0_Checkpoint_Requirement; Index : Positive) return Column_Family_ID
   is
   begin
      if Item.State.Families = null or else Index > Item.State.Families'Length then
         raise Constraint_Error with "checkpoint requirement family index is out of range";
      end if;
      return Item.State.Families (Index);
   end Checkpoint_Requirement_Family;

   procedure Set_Test_Paused (Item : in out Database; Value : Boolean; Result : out Outcome_Code) is
      Lease : Lifecycle_Lease;
   begin
      Acquire (Item, Lease, Result);
      if Result = Success then
         Lease.State.Gate.Set_Paused (Value);
      end if;
   end Set_Test_Paused;

   procedure Test_Queue_Depth (Item : in out Database; Value : out Natural; Result : out Outcome_Code) is
      Lease : Lifecycle_Lease;
   begin
      Value := 0;
      Acquire (Item, Lease, Result);
      if Result = Success then
         Value := Lease.State.Gate.Queue_Depth;
      end if;
   end Test_Queue_Depth;

   procedure Fail_Next_Test_Install (Item : in out Database; Result : out Outcome_Code) is
      Lease : Lifecycle_Lease;
   begin
      Acquire (Item, Lease, Result);
      if Result = Success then
         Lease.State.Gate.Fail_Next_Install;
      end if;
   end Fail_Next_Test_Install;

   procedure Set_Test_Get_Paused (Item : in out Storage_Context; Value : Boolean) is
   begin
      Item.Test_Control.Set_Get_Paused (Value);
   end Set_Test_Get_Paused;

   procedure Wait_For_Test_Get (Item : in out Storage_Context; Timeout : Duration; Arrived : out Boolean) is
   begin
      Arrived := False;
      select
         delay Timeout;
      then abort
         Item.Test_Control.Await_Get;
         Arrived := True;
      end select;
   end Wait_For_Test_Get;

   function Test_Get_Waiting (Item : Storage_Context) return Boolean
   is (Item.Test_Control.Get_Waiting);

   procedure Test_Image_Statistics
     (Allocated, Released, Arenas_Allocated, Arenas_Released, Transaction_Bytes, Source_Bytes, Sink_Bytes :
        out Interfaces.Unsigned_64) is
   begin
      Image_Accounting.Snapshot
        (Allocated, Released, Arenas_Allocated, Arenas_Released, Transaction_Bytes, Source_Bytes, Sink_Bytes);
   end Test_Image_Statistics;

   procedure Install_Test_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Legacy        : Boolean;
      Result        : out Outcome_Code)
   is
      --  This test-only canonical empty HEAD uses the persisted root counters
      --  (epoch/transition 1, sequence 0) so open/recovery exercises the same
      --  compatibility boundary as Create; these are not public defaults.
      Head       : constant Head_Snapshot :=
        (Database_ID            => Database_ID,
         Version                =>
           Interfaces.Unsigned_16 (if Legacy then Heads.Legacy_Format else Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => (if Legacy then Zero_Identifier else Manifest_ID),
         Transition_ID          => Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Image      : constant Formats.Head_Image := Formats.Encode_Head (To_Head (Head));
      Data       : Small_Metadata_Buffer;
      Generation : Generation_Value;
      Put_Result : Put_Outcome;
   begin
      Copy_Head_Image (Image, Data);
      Storage_Port.Put_Create
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         Head_Object,
         Ada.Real_Time.Time_Last,
         null,
         Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Install_Test_Head;

   procedure Install_Test_Unsupported_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code)
   is
      --  The otherwise-valid root HEAD isolates unsupported-version handling;
      --  its root counters are persisted-format fixtures, not product policy.
      Head       : constant Head_Snapshot :=
        (Database_ID            => Database_ID,
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => Manifest_ID,
         Transition_ID          => Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Image      : Formats.Head_Image := Formats.Encode_Head (To_Head (Head));
      Data       : Small_Metadata_Buffer;
      Generation : Generation_Value;
      Put_Result : Put_Outcome;

      procedure Put_U32 (Position : Natural; Value : Interfaces.Unsigned_32) is
      begin
         for Offset in Natural range 0 .. 3 loop
            Image (Position + Offset) := Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
         end loop;
      end Put_U32;
   begin
      --  HEAD bytes 8..9 are the big-endian format version, byte 40 starts the
      --  header CRC, and byte 132 starts the full-image CRC. Version 3 is the
      --  deliberately unsupported successor. These offsets are frozen by the
      --  HEAD v1/v2 codec and must move with a deliberate format revision.
      Image (8) := 0;
      Image (9) := 3;
      Image (40 .. 43) := [others => 0];
      Put_U32 (40, Formats.CRC_32C (Image (0 .. 131)));
      Put_U32 (132, Formats.CRC_32C (Image (0 .. 131)));
      Copy_Head_Image (Image, Data);
      Storage_Port.Put_Create
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         Head_Object,
         Ada.Real_Time.Time_Last,
         null,
         Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Install_Test_Unsupported_Head;

   procedure Install_Test_Invalid_V2_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code)
   is
      --  The otherwise-valid v2 root HEAD isolates the mandatory manifest-ID
      --  invariant; its root counters are persisted-format fixtures.
      Head       : constant Head_Snapshot :=
        (Database_ID            => Database_ID,
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => Manifest_ID,
         Transition_ID          => Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Image      : Formats.Head_Image := Formats.Encode_Head (To_Head (Head));
      Data       : Small_Metadata_Buffer;
      Generation : Generation_Value;
      Put_Result : Put_Outcome;

      procedure Put_U32 (Position : Natural; Value : Interfaces.Unsigned_32) is
      begin
         for Offset in Natural range 0 .. 3 loop
            Image (Position + Offset) := Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
         end loop;
      end Put_U32;
   begin
      --  HEAD v2 bytes 76..91 hold Latest_Manifest; zeroing them creates the
      --  targeted semantic failure. CRC fields at 40 and 132 are recomputed so
      --  integrity checks cannot mask the invariant under test.
      Image (76 .. 91) := [others => 0];
      Image (40 .. 43) := [others => 0];
      Put_U32 (40, Formats.CRC_32C (Image (0 .. 131)));
      Put_U32 (132, Formats.CRC_32C (Image (0 .. 131)));
      Copy_Head_Image (Image, Data);
      Storage_Port.Put_Create
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         Head_Object,
         Ada.Real_Time.Time_Last,
         null,
         Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Install_Test_Invalid_V2_Head;

   procedure Corrupt_Test_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code)
   is
      Data           : Small_Metadata_Buffer;
      Length         : Natural;
      Generation     : Generation_Value;
      Read_Result    : Read_Outcome;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;
   begin
      Storage_Port.Get_Whole
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Manifest_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read or else Length = 0 then
         Result := Storage_Failure;
         return;
      end if;
      Data (Length - 1) := Data (Length - 1) xor 1;
      Storage_Port.Put_Replace
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Data,
         Length,
         Generation,
         Ada.Real_Time.Time_Last,
         null,
         New_Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Corrupt_Test_Manifest;

   procedure Remove_Test_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code)
   is
      Status : OS.Status;
   begin
      if Item.Backend = null then
         Result := Invalid_State;
         return;
      end if;
      Item.Backend.Delete_Object
        (UStrings.To_String (Item.Bucket),
         Manifest_Key (Item, Manifest_ID),
         null,
         Ada.Real_Time.Time_Last,
         Status);
      Result := (if Status = OS.Success then Success else Storage_Failure);
   end Remove_Test_Manifest;

   procedure Rewrite_Test_Run
     (Item        : in out Storage_Context;
      Run_ID      : Identifier;
      New_Family  : Interfaces.Unsigned_32;
      Corrupt_CRC : Boolean;
      Result      : out Outcome_Code)
   is
      --  This private fixture admits the repository's bounded checkpoint
      --  corpus through the existing 22,048-byte metadata scratch. Production
      --  recovery derives its exact allocation from the authenticated SST
      --  header and does not inherit this test-only ceiling.
      Data           : Small_Metadata_Buffer;
      Length         : Natural;
      Generation     : Generation_Value;
      Read_Result    : Read_Outcome;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;
      Header_Length  : Natural;
   begin
      Storage_Port.Get_Whole
        (Item,
         Run_Key (Item, Run_ID),
         Run_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read or else Length < LSM_Runtime.LSM.SST_Header_Length + 4 then
         Result := Storage_Failure;
         return;
      end if;
      declare
         Image : Formats.Byte_Array (0 .. Length - 1);
         Owner : Shared_Image_Access := null;
      begin
         for Index in Image'Range loop
            Image (Index) := Data (Index);
         end loop;
         if Corrupt_CRC then
            Image (Image'Last) := Image (Image'Last) xor 1;
         else
            --  SST-v1/v2 share the frozen family field at byte 60. The header
            --  extent is selected by the persisted version, so the fixture
            --  reaches descriptor binding without changing either format.
            if Image (8) = 0 and then Image (9) = Byte (LSM_Runtime.LSM.SST_Format_Version) then
               Header_Length := LSM_Runtime.LSM.SST_Header_Length;
            elsif Image (8) = 0 and then Image (9) = Byte (LSM_Runtime.SST_V2_Format_Version) then
               Header_Length := LSM_Runtime.SST_V2_Header_Length;
            else
               Result := Corrupt;
               return;
            end if;
            Put_U32 (Image, 60, New_Family);
            Image (40 .. 43) := [others => 0];
            Put_U32 (Image, 40, Formats.CRC_32C (Image (0 .. Header_Length - 1)));
            Put_U32 (Image, Length - 4, Formats.CRC_32C (Image (0 .. Length - 5)));
         end if;
         Owner := New_Image (Image);
         Storage_Port.Put_Replace
           (Item,
            Run_Key (Item, Run_ID),
            Owner,
            Generation,
            Ada.Real_Time.Time_Last,
            null,
            New_Generation,
            Put_Result);
         Release_Image (Owner);
      exception
         when others =>
            Release_Image (Owner);
            raise;
      end;
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Rewrite_Test_Run;

   procedure Corrupt_Test_Run (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code)
   is
   begin
      Rewrite_Test_Run (Item, Run_ID, 0, True, Result);
   end Corrupt_Test_Run;

   procedure Remove_Test_Run (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code)
   is
      Status : OS.Status;
   begin
      if Item.Backend = null then
         Result := Invalid_State;
         return;
      end if;
      Item.Backend.Delete_Object
        (UStrings.To_String (Item.Bucket), Run_Key (Item, Run_ID), null, Ada.Real_Time.Time_Last, Status);
      Result := (if Status = OS.Success then Success else Storage_Failure);
   end Remove_Test_Run;

   procedure Rewrite_Test_Run_Family
     (Item      : in out Storage_Context;
      Run_ID    : Identifier;
      Family_ID : Column_Family_ID;
      Result    : out Outcome_Code) is
   begin
      Rewrite_Test_Run (Item, Run_ID, Interfaces.Unsigned_32 (Family_ID), False, Result);
   end Rewrite_Test_Run_Family;

   procedure Convert_Test_Run_To_V1
     (Item    : in out Storage_Context;
      Run_ID  : Identifier;
      Timeout : Duration;
      Result  : out Outcome_Code)
   is
      --  This private compatibility witness replaces one already-published
      --  fixture object only. Production runs remain immutable. The retained
      --  22,048-byte scratch is the existing bounded test corpus, not a DB cap.
      Data           : Small_Metadata_Buffer;
      Length         : Natural;
      Generation     : Generation_Value;
      Read_Result    : Read_Outcome;
      Decoded        : LSM_Runtime.SST_Access := null;
      Encoded        : LSM_Runtime.Image_Access := null;
      Owner          : Shared_Image_Access := null;
      Decode_Result  : LSM_Runtime.Decode_Status;
      Encode_Result  : LSM_Runtime.Encode_Status;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;

      function Read_U32 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_32 is
         Value : Interfaces.Unsigned_32 := 0;
      begin
         for Offset in Natural range 0 .. 3 loop
            Value := Interfaces.Shift_Left (Value, 8) or Interfaces.Unsigned_32 (Image (Position + Offset));
         end loop;
         return Value;
      end Read_U32;

      function Read_U64 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_64 is
         Value : Interfaces.Unsigned_64 := 0;
      begin
         for Offset in Natural range 0 .. 7 loop
            Value := Interfaces.Shift_Left (Value, 8) or Interfaces.Unsigned_64 (Image (Position + Offset));
         end loop;
         return Value;
      end Read_U64;

      function Read_ID (Image : Formats.Byte_Array; Position : Natural) return Identifier is
         Value : Identifier := Zero_Identifier;
      begin
         for Index in Identifier_Index loop
            Value (Index) := Image (Position + Index - Identifier_Index'First);
         end loop;
         return Value;
      end Read_ID;
   begin
      Storage_Port.Get_Whole
        (Item,
         Run_Key (Item, Run_ID),
         Run_Object,
         Deadline_After (Timeout),
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read
        or else Length < LSM_Runtime.SST_V2_Header_Length + LSM_Runtime.LSM.Object_Trailer_Length
      then
         Result :=
           (if Read_Result = Object_Read
            then Corrupt
            else Lazy_Read_Outcome (Read_Result));
         return;
      end if;

      declare
         Image       : Formats.Byte_Array (0 .. Length - 1);
         Database_ID : Identifier;
         Descriptor  : LSM_Runtime.Run_Descriptor;
         Family_ID   : Interfaces.Unsigned_32;
      begin
         for Index in Image'Range loop
            Image (Index) := Data (Index);
         end loop;
         if Image (8) /= 0 or else Image (9) /= Byte (LSM_Runtime.SST_V2_Format_Version) then
            Result := Corrupt;
            return;
         end if;
         Database_ID := Read_ID (Image, 12);
         Family_ID := Read_U32 (Image, 60);
         Descriptor :=
           (Run_ID                => To_Head_ID (Read_ID (Image, 44)),
            Lowest_Sequence       => Read_U64 (Image, 64),
            Highest_Sequence      => Read_U64 (Image, 72),
            Entry_Total           => Read_U32 (Image, 80),
            Logical_Payload_Bytes => Read_U64 (Image, 88));
         --  Unsigned_64'Last deliberately adds no test-only key/value policy:
         --  the authenticated object itself supplies the exact retained sizes.
         LSM_Runtime.Decode_SST_V2
           (Image,
            To_Head_ID (Database_ID),
            Family_ID,
            Descriptor,
            Interfaces.Unsigned_64'Last,
            Interfaces.Unsigned_64'Last,
            Decoded,
            Decode_Result);
      end;
      if Decode_Result /= LSM_Runtime.Decoded then
         Result := Corrupt;
         return;
      end if;
      LSM_Runtime.Encode_SST (Decoded.all, Encoded, Encode_Result);
      if Encode_Result /= LSM_Runtime.Encoded then
         LSM_Runtime.Release (Decoded);
         Result := (if Encode_Result = LSM_Runtime.Allocation_Failed then Capacity_Exceeded else Corrupt);
         return;
      end if;
      Owner := New_Image (Encoded.all);
      LSM_Runtime.Release (Encoded);
      LSM_Runtime.Release (Decoded);
      Storage_Port.Put_Replace
        (Item,
         Run_Key (Item, Run_ID),
         Owner,
         Generation,
         Deadline_After (Timeout),
         null,
         New_Generation,
         Put_Result);
      Release_Image (Owner);
      Result :=
        (case Put_Result is
           when Object_Published        => Success,
           when Put_Precondition_Failed => Stale_Writer,
           when Put_Outcome_Unknown     => Outcome_Unknown,
           when Put_Cancelled           => Cancelled,
           when Put_Timed_Out           => Timed_Out,
           when Put_Definite_Failure    => Storage_Failure);
   exception
      when Storage_Error =>
         Release_Image (Owner);
         LSM_Runtime.Release (Encoded);
         LSM_Runtime.Release (Decoded);
         Result := Capacity_Exceeded;
      when others =>
         Release_Image (Owner);
         LSM_Runtime.Release (Encoded);
         LSM_Runtime.Release (Decoded);
         raise;
   end Convert_Test_Run_To_V1;

   procedure Rewrite_Test_Manifest
     (Item                 : in out Storage_Context;
      Manifest_ID          : Identifier;
      Expected_Database_ID : Database_Identifier;
      Replacement_Database : Database_Identifier;
      Oversize_Family      : Boolean;
      Drop_Last_Family     : Boolean;
      Restricted_Family    : Interfaces.Unsigned_32;
      Restricted_Max_Key   : Interfaces.Unsigned_64;
      Result               : out Outcome_Code)
   is
      Data           : Small_Metadata_Buffer;
      Length         : Natural;
      Generation     : Generation_Value;
      Read_Result    : Read_Outcome;
      Value          : Manifests.Manifest;
      Image          : Manifests.Manifest_Image;
      Encode_Result  : Manifests.Encode_Status;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;
      Found          : Boolean := False;
   begin
      Storage_Port.Get_Whole
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Manifest_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read then
         Result := Storage_Failure;
         return;
      end if;
      Decode_Stored_Manifest (Data, Length, Expected_Database_ID, Value, Result);
      if Result /= Success then
         return;
      end if;
      --  This corruption helper deliberately projects any readable v2 root to
      --  its legacy v1 base before applying the requested damage. It is test
      --  fixture construction, not a supported migration or publication path.
      if Replacement_Database /= Zero_Database_ID then
         Value.Database_ID := To_Head_ID (Replacement_Database);
      end if;
      if Oversize_Family then
         Value.Families (1).Max_Key_Bytes := Reference_Maximum_Key_Bytes + 1;
      end if;
      if Drop_Last_Family then
         if Value.Family_Total <= 1 then
            Result := Invalid_State;
            return;
         end if;
         Value.Families (Value.Family_Total) := (others => <>);
         Value.Family_Total := Value.Family_Total - 1;
      elsif Restricted_Family /= 0 then
         for Index in Manifests.Family_Slot range 1 .. Value.Family_Total loop
            if Value.Families (Index).ID = Restricted_Family then
               Value.Families (Index).Max_Key_Bytes := Restricted_Max_Key;
               Found := True;
               exit;
            end if;
         end loop;
         if not Found then
            Result := Invalid_State;
            return;
         end if;
      end if;
      Manifests.Encode_Manifest (Value, Image, Length, Encode_Result);
      if Encode_Result /= Manifests.Encoded then
         Result := Invalid_State;
         return;
      end if;
      Copy_Manifest_Image (Image, Length, Data);
      Storage_Port.Put_Replace
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Data,
         Length,
         Generation,
         Ada.Real_Time.Time_Last,
         null,
         New_Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Rewrite_Test_Manifest;

   procedure Extend_Test_Manifest_Chain
     (Item        : in out Storage_Context;
      Database_ID : Database_Identifier;
      Root_ID     : Identifier;
      Successors  : Positive;
      Result      : out Outcome_Code)
   is
      Data           : Small_Metadata_Buffer;
      Length         : Natural;
      Generation     : Generation_Value;
      Read_Result    : Read_Outcome;
      Previous       : Manifests.Manifest;
      Current        : Manifests.Manifest;
      Image          : Manifests.Manifest_Image;
      Encode_Result  : Manifests.Encode_Status;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;
      Head           : Head_Snapshot;
      Head_Image     : Formats.Head_Image;
   begin
      Storage_Port.Get_Whole
        (Item,
         Manifest_Key (Item, Root_ID),
         Manifest_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read then
         Result := Storage_Failure;
         return;
      end if;
      Decode_Stored_Manifest (Data, Length, Database_ID, Previous, Result);
      if Result /= Success then
         return;
      end if;
      --  History-depth fixtures deliberately continue from the readable v1
      --  base projection and publish v1 successors. This test-only mixed chain
      --  must not be interpreted as a production downgrade or migration rule.
      --  Test-only 4E/54 domain tags distinguish manifest and transition IDs;
      --  one-byte key/value limits keep chain fixtures minimal. These values
      --  exercise history-depth policy and are not deployable defaults.
      for Index in Positive range 1 .. Successors loop
         if Previous.Family_Total = Manifests.Family_Count'Last then
            Result := Capacity_Exceeded;
            return;
         end if;
         Current := Previous;
         Current.Manifest_ID := To_Head_ID (Structural_ID (16#4E#, Interfaces.Unsigned_64 (Index)));
         Current.Previous_Manifest_ID := Previous.Manifest_ID;
         Current.Expected_Transition_ID := Previous.Publication_Transition_ID;
         Current.Expected_Transition_Number := Previous.Publication_Transition_Number;
         Current.Publication_Transition_ID :=
           To_Head_ID (Structural_ID (16#54#, Interfaces.Unsigned_64 (Index + 1)));
         Current.Publication_Transition_Number := Current.Expected_Transition_Number + 1;
         Current.Registry_Revision := Previous.Registry_Revision + 1;
         Current.Family_Total := Previous.Family_Total + 1;
         Current.Families (Current.Family_Total) :=
           (ID              => Previous.Families (Previous.Family_Total).ID + 1,
            Max_Key_Bytes   => 1,
            Max_Value_Bytes => 1,
            Name_Length     => 2,
            Name            => [1 => 16#78#, 2 => Byte (Index), others => 0]);
         Manifests.Encode_Manifest (Current, Image, Length, Encode_Result);
         if Encode_Result /= Manifests.Encoded then
            Result := Invalid_State;
            return;
         end if;
         Copy_Manifest_Image (Image, Length, Data);
         Storage_Port.Put_Create
           (Item,
            Manifest_Key (Item, To_Identifier (Current.Manifest_ID)),
            Data,
            Length,
            Manifest_Object,
            Ada.Real_Time.Time_Last,
            null,
            New_Generation,
            Put_Result);
         if Put_Result /= Object_Published then
            Result := Storage_Failure;
            return;
         end if;
         Previous := Current;
      end loop;

      Storage_Port.Get_Whole
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Head_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read then
         Result := Storage_Failure;
         return;
      end if;
      Head :=
        (Database_ID            => Database_ID,
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => Previous.Writer_Epoch,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => To_Identifier (Previous.Manifest_ID),
         Transition_ID          => To_Identifier (Previous.Publication_Transition_ID),
         Predecessor_Transition => To_Identifier (Previous.Expected_Transition_ID),
         Transition_Number      => Previous.Publication_Transition_Number);
      Head_Image := Formats.Encode_Head (To_Head (Head));
      Copy_Head_Image (Head_Image, Data);
      Storage_Port.Put_Replace
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         Generation,
         Ada.Real_Time.Time_Last,
         null,
         New_Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Extend_Test_Manifest_Chain;

   procedure Read_Test_Manifest_Version
     (Item        : in out Storage_Context;
      Manifest_ID : Identifier;
      Version     : out Interfaces.Unsigned_16;
      Result      : out Outcome_Code)
   is
      Data        : Small_Metadata_Buffer;
      Length      : Natural;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome;
   begin
      Version := 0;
      Storage_Port.Get_Whole
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Manifest_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      --  This test observation uses the production common-envelope offsets
      --  and does not interpret or authorize any remaining payload.
      if Read_Result = Object_Read and then Length > Common_Version_Low_Offset then
         Version :=
           Interfaces.Shift_Left
             (Interfaces.Unsigned_16 (Data (Common_Version_High_Offset)), Interfaces.Unsigned_16'Size / 2)
           or Interfaces.Unsigned_16 (Data (Common_Version_Low_Offset));
         Result := Success;
      else
         Result := Storage_Failure;
      end if;
   end Read_Test_Manifest_Version;

   procedure Read_Test_Root_LSM_Limits
     (Item                   : in out Storage_Context;
      Manifest_ID            : Identifier;
      Expected_Database      : Database_Identifier;
      Family_ID              : Column_Family_ID;
      Maximum_Total_L0_Runs  : out Interfaces.Unsigned_32;
      Maximum_Identities     : out Interfaces.Unsigned_32;
      Maximum_Point_Reads    : out Interfaces.Unsigned_32;
      Maximum_Scan_Ranges    : out Interfaces.Unsigned_32;
      Memtable_Max_Bytes     : out Interfaces.Unsigned_64;
      Memtable_Max_Entries   : out Interfaces.Unsigned_32;
      Maximum_Family_L0_Runs : out Interfaces.Unsigned_32;
      Result                 : out Outcome_Code)
   is
      Data        : Small_Metadata_Buffer;
      Length      : Natural;
      Generation  : Generation_Value;
      Read_Result : Read_Outcome;
      Status      : LSM_Runtime.Decode_Status;
      Checkpoint  : LSM_Runtime.Checkpoint_Manifest_Access := null;
      Found       : Boolean := False;
   begin
      Maximum_Total_L0_Runs := 0;
      Maximum_Identities := 0;
      Maximum_Point_Reads := 0;
      Maximum_Scan_Ranges := 0;
      Memtable_Max_Bytes := 0;
      Memtable_Max_Entries := 0;
      Maximum_Family_L0_Runs := 0;
      Storage_Port.Get_Whole
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Manifest_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read or else Length = 0 then
         Result := Storage_Failure;
         return;
      end if;
      declare
         Image : Formats.Byte_Array (0 .. Length - 1);
      begin
         for Index in Image'Range loop
            Image (Index) := Data (Index);
         end loop;
         LSM_Runtime.Decode_Checkpoint_Manifest (Image, To_Head_ID (Expected_Database), Checkpoint, Status);
      end;
      if Status /= LSM_Runtime.Decoded then
         LSM_Runtime.Release (Checkpoint);
         Result := Corrupt;
         return;
      end if;
      Maximum_Total_L0_Runs := Checkpoint.Maximum_Total_L0_Runs;
      Maximum_Identities := Checkpoint.Maximum_Checkpoint_Identities;
      Maximum_Point_Reads := Checkpoint.Maximum_Point_Reads_Per_Transaction;
      Maximum_Scan_Ranges := Checkpoint.Maximum_Scan_Ranges_Per_Transaction;
      for Index in Checkpoint.Families'Range loop
         if Checkpoint.Base.Families (Index).ID = Interfaces.Unsigned_32 (Family_ID) then
            Memtable_Max_Bytes := Checkpoint.Families (Index).Memtable_Max_Bytes;
            Memtable_Max_Entries := Checkpoint.Families (Index).Memtable_Max_Entries;
            Maximum_Family_L0_Runs := Checkpoint.Families (Index).Maximum_L0_Runs;
            Found := True;
            exit;
         end if;
      end loop;
      LSM_Runtime.Release (Checkpoint);
      Result := (if Found then Success else Not_Found);
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Checkpoint);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Checkpoint);
         Result := Corrupt;
   end Read_Test_Root_LSM_Limits;

   procedure Read_Test_Live_LSM_Limits
     (Item                   : in out Database;
      Family_ID              : Column_Family_ID;
      Replay_Boundary        : out Interfaces.Unsigned_64;
      Maximum_Total_L0_Runs  : out Interfaces.Unsigned_32;
      Maximum_Identities     : out Interfaces.Unsigned_32;
      Maximum_Point_Reads    : out Interfaces.Unsigned_32;
      Maximum_Scan_Ranges    : out Interfaces.Unsigned_32;
      Memtable_Max_Bytes     : out Interfaces.Unsigned_64;
      Memtable_Max_Entries   : out Interfaces.Unsigned_32;
      Maximum_Family_L0_Runs : out Interfaces.Unsigned_32;
      Result                 : out Outcome_Code)
   is
      Lease : Lifecycle_Lease;
   begin
      Replay_Boundary := 0;
      Maximum_Total_L0_Runs := 0;
      Maximum_Identities := 0;
      Maximum_Point_Reads := 0;
      Maximum_Scan_Ranges := 0;
      Memtable_Max_Bytes := 0;
      Memtable_Max_Entries := 0;
      Maximum_Family_L0_Runs := 0;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      elsif not Lease.State.LSM_Authority.Enabled then
         Result := Unsupported_Format;
         return;
      end if;
      Replay_Boundary := Lease.State.LSM_Authority.Replay_Boundary;
      Maximum_Total_L0_Runs := Lease.State.LSM_Authority.Maximum_Total_L0_Runs;
      Maximum_Identities := Lease.State.LSM_Authority.Maximum_Checkpoint_Identities;
      Maximum_Point_Reads := Lease.State.LSM_Authority.Maximum_Point_Reads_Per_Transaction;
      Maximum_Scan_Ranges := Lease.State.LSM_Authority.Maximum_Scan_Ranges_Per_Transaction;
      for Family of Lease.State.LSM_Authority.Families loop
         if Family.ID = Interfaces.Unsigned_32 (Family_ID) then
            Memtable_Max_Bytes := Family.State.Memtable_Max_Bytes;
            Memtable_Max_Entries := Family.State.Memtable_Max_Entries;
            Maximum_Family_L0_Runs := Family.State.Maximum_L0_Runs;
            Result := Success;
            return;
         end if;
      end loop;
      Result := Not_Found;
   end Read_Test_Live_LSM_Limits;

   procedure Read_Test_Live_Entry_Sequence
     (Item      : in out Database;
      Family_ID : Column_Family_ID;
      Item_Key  : Byte_Array;
      Sequence  : out Sequence_Number;
      Result    : out Outcome_Code)
   is
      Lease : Lifecycle_Lease;
   begin
      Sequence := 0;
      Acquire (Item, Lease, Result);
      if Result = Success then
         Lease.State.Gate.Lookup_Sequence (Family_ID, Item_Key, Sequence, Result);
      end if;
   end Read_Test_Live_Entry_Sequence;

   procedure Read_Test_Checkpoint_Buffer_Capacity
     (Item : in out Database; Maximum : out Natural; Result : out Outcome_Code)
   is
      Lease : Lifecycle_Lease;
   begin
      Maximum := 0;
      Acquire (Item, Lease, Result);
      if Result = Success then
         Synchronous_Checkpoint_Buffer_Capacity (Lease.State, 0, Maximum, Result);
      end if;
   end Read_Test_Checkpoint_Buffer_Capacity;

   procedure Build_Test_First_SST
     (Item             : in out Database;
      Family_ID        : Column_Family_ID;
      Run_ID           : Identifier;
      Entry_Total      : out Natural;
      Lowest_Sequence  : out Sequence_Number;
      Highest_Sequence : out Sequence_Number;
      Result           : out Outcome_Code)
   is
      State         : Engine_State_Access;
      Value         : LSM_Runtime.SST_Access := null;
      Image         : LSM_Runtime.Image_Access := null;
      Encode_Result : LSM_Runtime.Encode_Status;
      Guard         : Checkpoint_Guard;
      pragma Unreferenced (Guard);
   begin
      Entry_Total := 0;
      Lowest_Sequence := 0;
      Highest_Sequence := 0;
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      Build_Family_SST (State, Family_ID, Run_ID, Value, Result);
      if Result = Success then
         LSM_Runtime.Encode_SST (Value.all, Image, Encode_Result);
         if Encode_Result /= LSM_Runtime.Encoded then
            Result := Corrupt;
         else
            Entry_Total := Value.Entry_Total;
            Lowest_Sequence := Sequence_Number (Value.Lowest_Sequence);
            Highest_Sequence := Sequence_Number (Value.Highest_Sequence);
         end if;
      end if;
      LSM_Runtime.Release (Image);
      LSM_Runtime.Release (Value);
      Item.Life.Finish_Checkpoint;
      Guard.Active := False;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         LSM_Runtime.Release (Value);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Image);
         LSM_Runtime.Release (Value);
         raise;
   end Build_Test_First_SST;

   procedure Build_Test_First_Checkpoint
     (Item            : in out Database;
      Runs            : Checkpoint_Run_Identity_Array;
      Manifest_ID     : Identifier;
      Transition_ID   : Identifier;
      Run_Total       : out Natural;
      Identity_Total  : out Natural;
      Replay_Boundary : out Sequence_Number;
      Result          : out Outcome_Code)
   is
      State         : Engine_State_Access;
      Plan          : Checkpoint_Plan;
      Image         : LSM_Runtime.Image_Access := null;
      Encode_Result : LSM_Runtime.Encode_Status;
      Guard         : Checkpoint_Guard;
      pragma Unreferenced (Guard);
   begin
      Run_Total := 0;
      Identity_Total := 0;
      Replay_Boundary := 0;
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      Build_Checkpoint_Plan (State, Runs, Manifest_ID, Transition_ID, Plan, Result);
      if Result = Success then
         LSM_Runtime.Encode_Checkpoint_Manifest (Plan.Manifest.all, Image, Encode_Result);
         if Encode_Result /= LSM_Runtime.Encoded then
            Result := Corrupt;
         else
            Run_Total := Plan.Manifest.Run_Total;
            Identity_Total := Plan.Manifest.Identity_Total;
            Replay_Boundary := Sequence_Number (Plan.Manifest.Replay_Boundary);
         end if;
      end if;
      LSM_Runtime.Release (Image);
      Release_Checkpoint_Plan (Plan);
      Item.Life.Finish_Checkpoint;
      Guard.Active := False;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         Release_Checkpoint_Plan (Plan);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Image);
         Release_Checkpoint_Plan (Plan);
         raise;
   end Build_Test_First_Checkpoint;

   procedure Publish_Test_First_Checkpoint
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code)
   is
      Receipt : Flush_Receipt;
   begin
      --  The retained testing entry point is a literal unbounded wait on the
      --  public certainty-preserving state machine; it adds no fixture-only
      --  publication semantics or timing policy.
      Flush (Item, Runs, Manifest_ID, Transition_ID, Duration'Last, Receipt => Receipt, Result => Result);
   end Publish_Test_First_Checkpoint;

   procedure Build_Test_Compaction_Checkpoint
     (Item             : in out Database;
      Runs             : Checkpoint_Run_Identity_Array;
      Manifest_ID      : Identifier;
      Transition_ID    : Identifier;
      Family_ID        : Column_Family_ID;
      Run_Total        : out Natural;
      Identity_Total   : out Natural;
      Replay_Boundary  : out Sequence_Number;
      Family_Run_Total : out Natural;
      Family_Run_ID    : out Identifier;
      Family_Entries   : out Natural;
      Result           : out Outcome_Code)
   is
      State         : Engine_State_Access;
      Plan          : Checkpoint_Plan;
      Image         : LSM_Runtime.Image_Access := null;
      Encode_Result : LSM_Runtime.Encode_Status;
      Guard         : Checkpoint_Guard;
      pragma Unreferenced (Guard);
   begin
      Run_Total := 0;
      Identity_Total := 0;
      Replay_Boundary := 0;
      Family_Run_Total := 0;
      Family_Run_ID := Zero_Identifier;
      Family_Entries := 0;
      Item.Life.Begin_Checkpoint (State, Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      Build_Checkpoint_Plan
        (State,
         Runs,
         Manifest_ID,
         Transition_ID,
         Plan,
         Result,
         Replace_Current_Runs => True);
      if Result = Success then
         LSM_Runtime.Encode_Checkpoint_Manifest (Plan.Manifest.all, Image, Encode_Result);
         if Encode_Result /= LSM_Runtime.Encoded then
            Result := Corrupt;
         else
            Run_Total := Plan.Manifest.Run_Total;
            Identity_Total := Plan.Manifest.Identity_Total;
            Replay_Boundary := Sequence_Number (Plan.Manifest.Replay_Boundary);
            for Index in Plan.Manifest.Families'Range loop
               if Plan.Manifest.Base.Families (Index).ID = Interfaces.Unsigned_32 (Family_ID) then
                  Family_Run_Total := Plan.Manifest.Families (Index).Run_Total;
                  if Family_Run_Total > 0 then
                     declare
                        Descriptor : LSM_Runtime.Run_Descriptor renames
                          Plan.Manifest.Runs (Plan.Manifest.Families (Index).First_Run);
                     begin
                        Family_Run_ID := To_Identifier (Descriptor.Run_ID);
                        Family_Entries := Natural (Descriptor.Entry_Total);
                     end;
                  end if;
                  exit;
               end if;
            end loop;
         end if;
      end if;
      LSM_Runtime.Release (Image);
      Release_Checkpoint_Plan (Plan);
      Item.Life.Finish_Checkpoint;
      Guard.Active := False;
   exception
      when Storage_Error =>
         LSM_Runtime.Release (Image);
         Release_Checkpoint_Plan (Plan);
         Result := Capacity_Exceeded;
      when others =>
         LSM_Runtime.Release (Image);
         Release_Checkpoint_Plan (Plan);
         raise;
   end Build_Test_Compaction_Checkpoint;

   procedure Publish_Test_Compaction
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      --  This private test adapter drives the public complete-view compaction.
      --  Duration'Last only removes harness timing from the witness; it is not
      --  a production timeout default.
      Compact
        (Item,
         Runs,
         Manifest_ID,
         Transition_ID,
         Duration'Last,
         Token   => null,
         Receipt => Receipt,
         Result  => Result);
   end Publish_Test_Compaction;

   procedure Publish_Test_Adjacent_Merge
     (Item          : in out Database;
      Older_Run_ID  : Identifier;
      Newer_Run_ID  : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      --  The private witness removes harness timing from the public explicitly
      --  selected adjacent merge. Trigger and deadline policy remain absent.
      Compact
        (Item,
         Older_Run_ID,
         Newer_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Duration'Last,
         Token   => null,
         Receipt => Receipt,
         Result  => Result);
   end Publish_Test_Adjacent_Merge;

   procedure Publish_Test_Three_Run_Merge
     (Item          : in out Database;
      First_Run_ID  : Identifier;
      Middle_Run_ID : Identifier;
      Last_Run_ID   : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      --  Duration'Last removes harness timing only. All four immutable IDs
      --  and the exact three-run selection are caller fixture authority, not
      --  a production trigger, fanout, output-name, or deadline policy.
      Compact
        (Item,
         First_Run_ID,
         Middle_Run_ID,
         Last_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Duration'Last,
         Token   => null,
         Receipt => Receipt,
         Result  => Result);
   end Publish_Test_Three_Run_Merge;

   procedure Decode_Runtime_Image_For_Test
     (Data : Byte_Array; Wrong_DB : Boolean; Wrong_Head : Boolean; Result : out Outcome_Code)
   is
      Owned             : Flyology.Bytes.Unbounded_Bytes;
      Batch             : Runtime_Batch;
      --  Test-only structural IDs distinguish the expected database/head from
      --  their wrong-identity variants; changing them only invalidates codec
      --  negative fixtures, not the persisted identifier representation.
      Expected_Database : constant Database_Identifier :=
        (if Wrong_DB
         then Database_Identifier (Structural_ID (16#DB#, 9))
         else Database_Identifier (Structural_ID (0, 1)));
      Head              : constant Head_Snapshot :=
        (Database_ID            => Database_Identifier (Structural_ID (0, 1)),
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 1,
         Latest_Batch           => (if Wrong_Head then Structural_ID (0, 9) else Structural_ID (0, 3)),
         Latest_Manifest        => Structural_ID (0, 7),
         Transition_ID          => Structural_ID (0, 4),
         Predecessor_Transition => Structural_ID (0, 2),
         Transition_Number      => 2);
      --  The decoder harness admits 257 records and one million bytes so tests
      --  reach structural/identity checks without an unrelated capacity result.
      --  This is permissive test policy, not a public or persisted default.
      Limits            : constant Database_Limits :=
        (Maximum_Column_Families           => 2,
         Maximum_Manifest_History          => 2,
         Maximum_Batch_History             => 2,
         Maximum_Transactions_Per_Batch    => 257,
         Maximum_Mutations_Per_Transaction => 257,
         Maximum_Mutations_Per_Batch       => 257,
         Maximum_Live_Entries              => 257,
         Maximum_Transaction_Payload_Bytes => 1_000_000,
         Maximum_Batch_Payload_Bytes       => 1_000_000,
         Maximum_Live_State_Bytes          => 1_000_000,
         --  Unused by batch decoding; nonzero fixture values keep the public
         --  aggregate explicit without introducing runtime fallback policy.
         Maximum_Total_L0_Runs             => 1,
         Maximum_Checkpoint_Identities     => 1,
         Maximum_Point_Reads_Per_Transaction => 1,
         Maximum_Scan_Ranges_Per_Transaction => 1);
   begin
      Flyology.Bytes.Reserve_Capacity (Owned, Data'Length);
      for Value of Data loop
         Flyology.Bytes.Append (Owned, Ada.Streams.Stream_Element (Value));
      end loop;
      Decode_Stored_Batch (Owned, Expected_Database, Limits, True, Head, Batch, Result);
      Release_Runtime_Batch (Batch);
   exception
      when Storage_Error =>
         Release_Runtime_Batch (Batch);
         Result := Capacity_Exceeded;
      when others =>
         Release_Runtime_Batch (Batch);
         Result := Corrupt;
   end Decode_Runtime_Image_For_Test;

   procedure Check_Runtime_Reference_Parity (Result : out Outcome_Code) is
      --  Domain-separated test IDs and root counters make each runtime/reference
      --  parity case deterministic. They are witness identities, not wire tags
      --  or deployable defaults.
      Expected  : constant Head_Snapshot :=
        (Database_ID            => Database_Identifier (Structural_ID (16#D1#, 1)),
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => Structural_ID (16#4D#, 1),
         Transition_ID          => Structural_ID (16#E1#, 1),
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Items     : Work_Group;
      Batch     : Runtime_Batch;
      Reference : Batches.Commit_Batch;
      Image     : Batches.Batch_Image;
      Length    : Natural;
      Status    : Batches.Encode_Status;

      procedure Release_Items is
      begin
         for Index in Items'Range loop
            Release_Arena (Items (Index).Arena);
         end loop;
      end Release_Items;
   begin
      --  Cases 1..4 cover every supported group cardinality used by this
      --  parity witness; the range is a bounded test dimension.
      for Case_Number in Group_Count range 1 .. 4 loop
         Items := [others => <>];
         Batch := (others => <>);
         Reference := Batches.Empty_Batch;
         declare
            --  B1/A1 are test-only batch/transaction domain tags; they keep
            --  parity artifacts stable and have no persisted-format authority.
            Batch_ID : constant Identifier := Structural_ID (16#B1#, Interfaces.Unsigned_64 (Case_Number));
         begin
            for Transaction_Index in Commit_Slot range 1 .. Case_Number loop
               declare
                  Mutations : Owned_Mutation_Array_Access := new Owned_Mutation_Array (1 .. 1);
               begin
                  Mutations (1).Family := Column_Family_ID (Transaction_Index);
                  Mutations (1).Operation :=
                    (if Transaction_Index mod 2 = 0 then Delete_Mutation else Put_Mutation);
                  Mutations (1).Key_Length := 2;
                  Mutations (1).Value_Length := (if Mutations (1).Operation = Put_Mutation then 1 else 0);
                  Flyology.Bytes.Append
                    (Mutations (1).Payload, Ada.Streams.Stream_Element (Transaction_Index));
                  Flyology.Bytes.Append (Mutations (1).Payload, Ada.Streams.Stream_Element (Case_Number));
                  if Mutations (1).Operation = Put_Mutation then
                     Flyology.Bytes.Append (Mutations (1).Payload, Ada.Streams.Stream_Element (16#80#));
                  end if;
                  Items (Transaction_Index).Transaction_ID :=
                    Transaction_Identifier
                      (Structural_ID (16#A1#, Interfaces.Unsigned_64 (Transaction_Index)));
                  Items (Transaction_Index).Batch_ID := Batch_ID;
                  Items (Transaction_Index).Arena :=
                    new Transaction_Arena'
                      (Mutations  => Mutations,
                       Count      => 1,
                       Bytes_Used => Interfaces.Unsigned_64 (2 + Mutations (1).Value_Length),
                       others     => <>);
                  Image_Accounting.Record_Arena_Allocation;
               exception
                  when others =>
                     Free_Owned_Mutations (Mutations);
                     raise;
               end;
            end loop;
            Build_Runtime_Batch (Items, Case_Number, Expected, Batch, Result);
            Release_Items;
            if Result /= Success or else Batch.Image = null then
               Release_Runtime_Batch (Batch);
               return;
            end if;

            Reference.Database_ID := To_Head_ID (Batch.Database_ID);
            Reference.Epoch := Heads.Writer_Epoch (Batch.Epoch);
            Reference.Batch_ID := To_Head_ID (Batch.Batch_ID);
            Reference.Previous_Batch_ID := To_Head_ID (Batch.Previous_Batch_ID);
            Reference.Expected_Transition_ID := To_Head_ID (Batch.Expected_Transition_ID);
            Reference.Expected_Transition_Number :=
              Heads.Transition_Ordinal (Batch.Expected_Transition_Number);
            Reference.Publication_Transition_ID := To_Head_ID (Batch.Publication_Transition_ID);
            Reference.Publication_Transition_Number :=
              Heads.Transition_Ordinal (Batch.Publication_Transition_Number);
            Reference.First_Sequence := Heads.Commit_Sequence (Batch.First_Sequence);
            Reference.Last_Sequence := Heads.Commit_Sequence (Batch.Last_Sequence);
            Reference.Transaction_Total := Batch.Transaction_Total;
            Reference.Mutation_Total := Batch.Mutation_Total;
            for Index in Positive range 1 .. Batch.Transaction_Total loop
               Reference.Transactions (Index) :=
                 (Transaction_ID => To_Head_ID (Identifier (Batch.Transactions (Index).Transaction_ID)),
                  Sequence       => Heads.Commit_Sequence (Batch.Transactions (Index).Sequence),
                  First_Mutation => Batch.Transactions (Index).First_Mutation,
                  Mutations      => Batch.Transactions (Index).Mutation_Count);
            end loop;
            for Index in Positive range 1 .. Batch.Mutation_Total loop
               declare
                  Source : Runtime_Mutation renames Batch.Mutations (Index);
                  Target : Batches.Mutation renames Reference.Mutations (Index);
               begin
                  Target.Column_Family := Interfaces.Unsigned_32 (Source.Family);
                  Target.Operation :=
                    (if Source.Operation = Put_Mutation then Batches.Put else Batches.Delete);
                  Target.Key_Size := Source.Key_Length;
                  Target.Value_Size := Source.Value_Length;
                  for Offset in Positive range 1 .. Source.Key_Length loop
                     Target.Key (Offset) :=
                       Byte (Flyology.Bytes.Element (Batch.Image.Data, Source.Key_Offset + Offset));
                  end loop;
                  for Offset in Positive range 1 .. Source.Value_Length loop
                     Target.Value (Offset) :=
                       Byte (Flyology.Bytes.Element (Batch.Image.Data, Source.Value_Offset + Offset));
                  end loop;
               end;
            end loop;
            Batches.Encode_Batch (Reference, Image, Length, Status);
            if Status /= Batches.Encoded or else Length /= Flyology.Bytes.Length (Batch.Image.Data) then
               Release_Runtime_Batch (Batch);
               Result := Corrupt;
               return;
            end if;
            for Index in Natural range 0 .. Length - 1 loop
               if Image (Index) /= Byte (Flyology.Bytes.Element (Batch.Image.Data, Index + 1)) then
                  Release_Runtime_Batch (Batch);
                  Result := Corrupt;
                  return;
               end if;
            end loop;
            Release_Runtime_Batch (Batch);
         end;
      end loop;
      Result := Success;
   exception
      when Storage_Error =>
         Release_Items;
         Release_Runtime_Batch (Batch);
         Result := Capacity_Exceeded;
      when others =>
         Release_Items;
         Release_Runtime_Batch (Batch);
         Result := Corrupt;
   end Check_Runtime_Reference_Parity;

   overriding
   procedure Finalize (Item : in out Database) is
      Result : Outcome_Code;
   begin
      Close (Item, Result);
   end Finalize;

end Flyology.DB;
