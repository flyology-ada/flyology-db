with Interfaces;
with Flyology.Cancellation;
with Flyology.Bytes;
private with Ada.Finalization;
private with Ada.Strings.Unbounded;
private with Flyology.Object_Storage.Backends;

--  Experimental object-native transactional key-value database.

package Flyology.DB is

   --  Project lifecycle classification: the crate is explicitly experimental,
   --  so no stable compatibility promise exists. Changing this flag is a
   --  release-policy decision, not an implementation detail.
   Experimental : constant Boolean := True;

   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (Positive range <>) of Byte;

   --  Persisted-format authority: every opaque database, transaction, batch,
   --  manifest, run, and transition identity is exactly 16 bytes. Widening or
   --  narrowing it is incompatible with every existing object format.
   Identifier_Length   : constant := 16;
   subtype Identifier_Index is Positive range 1 .. Identifier_Length;
   type Identifier is array (Identifier_Index) of Byte;
   --  Persisted semantic sentinel: the all-zero identity means absent and is
   --  rejected wherever a definite identity is required. Reclassifying it as
   --  usable would invalidate structural and nonreuse rules.
   Zero_Identifier     : constant Identifier := [others => 0];
   type Database_Identifier is new Identifier;
   type Transaction_Identifier is new Identifier;
   --  Public typed forms of the same frozen absence sentinel; they add no
   --  separate namespace policy or wire representation.
   Zero_Database_ID    : constant Database_Identifier := [others => 0];
   Zero_Transaction_ID : constant Transaction_Identifier := [others => 0];

   type Sequence_Number is new Interfaces.Unsigned_64;
   type Column_Family_ID is new Interfaces.Unsigned_32 range 1 .. Interfaces.Unsigned_32'Last;

   --  Current manifest-v1 implementation/reference admission dimensions from
   --  the persisted-format contract: 64 family frames and 255 UTF-8 name
   --  bytes. They are public creation/name ceilings, not defaults for the
   --  persisted Database_Limits fields; changing them requires format, runtime,
   --  fixture, and proof compatibility review.
   Maximum_Initial_Column_Families  : constant := 64;
   Maximum_Column_Family_Name_Bytes : constant := 255;

   --  Persisted database-wide admission limits. Every field is explicit; the
   --  runtime applies no implicit defaults when creating a database.
   type Database_Limits is record
      Maximum_Column_Families           : Interfaces.Unsigned_32;
      Maximum_Manifest_History          : Interfaces.Unsigned_32;
      Maximum_Batch_History             : Interfaces.Unsigned_32;
      Maximum_Transactions_Per_Batch    : Interfaces.Unsigned_32;
      Maximum_Mutations_Per_Transaction : Interfaces.Unsigned_32;
      Maximum_Mutations_Per_Batch       : Interfaces.Unsigned_32;
      Maximum_Live_Entries              : Interfaces.Unsigned_32;
      Maximum_Transaction_Payload_Bytes : Interfaces.Unsigned_64;
      Maximum_Batch_Payload_Bytes       : Interfaces.Unsigned_64;
      Maximum_Live_State_Bytes          : Interfaces.Unsigned_64;
      Maximum_Total_L0_Runs             : Interfaces.Unsigned_32;
      Maximum_Checkpoint_Identities     : Interfaces.Unsigned_32;
   end record;

   type Column_Family_Configuration is private;
   type Column_Family_Configuration_Array is array (Positive range <>) of Column_Family_Configuration;
   type Column_Family is private;
   type Checkpoint_Run_Identity is private;
   type Checkpoint_Run_Identity_Array is array (Positive range <>) of Checkpoint_Run_Identity;

   --  Construct one immutable family configuration. Name must contain one to
   --  255 exact UTF-8 bytes and contain no NUL. Key/value and memtable limits
   --  plus the per-family L0 run bound must be nonzero. Invalid input raises
   --  Constraint_Error before storage effects. These caller-selected values
   --  are persisted authority; there are no library defaults.
   function Configure_Column_Family
     (ID                   : Column_Family_ID;
      Name                 : Byte_Array;
      Max_Key_Bytes        : Interfaces.Unsigned_64;
      Max_Value_Bytes      : Interfaces.Unsigned_64;
      Memtable_Max_Bytes   : Interfaces.Unsigned_64;
      Memtable_Max_Entries : Interfaces.Unsigned_32;
      Maximum_L0_Runs      : Interfaces.Unsigned_32) return Column_Family_Configuration;

   --  Bind one configured family to the immutable run identity selected by a
   --  checkpoint operation. Run_ID must be nonzero. Flush requires one mapping
   --  for every persisted family, rejects duplicate families or run IDs, and
   --  publishes only mappings whose family snapshot is nonempty. The mapping
   --  is borrowed only for the call and is never retained.
   --  @param Family_ID Stable persisted family identifier
   --  @param Run_ID Caller-owned stable immutable run identity
   --  @return Valid immutable family/run mapping
   --  @exception Constraint_Error Run_ID is zero
   function Configure_Checkpoint_Run
     (Family_ID : Column_Family_ID; Run_ID : Identifier) return Checkpoint_Run_Identity;

   type Outcome_Code is
     (Success,
      Not_Found,
      Already_Exists,
      Conflict,
      Capacity_Exceeded,
      Invalid_State,
      Timed_Out,
      Cancelled,
      Outcome_Unknown,
      Local_Activation_Failed,
      Unsupported_Format,
      Corrupt,
      Storage_Failure,
      Stale_Writer);

   type Storage_Context is limited private;
   type Database is limited private;
   type Transaction is limited private;
   type Create_Receipt is private;
   type Commit_Receipt is private;
   --  Project admission policy documented by the synchronous topology: one
   --  public atomic group has at most eight members. This is a bounded API and
   --  coordinator-capacity choice, not a wire-count limit or database default.
   Maximum_Group_Transactions : constant := 8;
   type Transaction_Array is array (Positive range <>) of Transaction;
   type Commit_Receipt_Array is array (Positive range <>) of Commit_Receipt;

   --  Create an empty database and publish its initial HEAD if absent.
   --  Item and Storage must remain alive until Close returns.
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
      Result                : out Outcome_Code);

   --  Resume a confirmed-manifest creation before HEAD admission, or reconcile
   --  a possibly admitted HEAD publication without replaying it.
   procedure Resolve_Create
     (Item    : in out Database;
      Storage : not null access Storage_Context;
      Receipt : in out Create_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code);

   --  Outcome most recently assigned to Receipt.
   function Create_Receipt_Outcome (Item : Create_Receipt) return Outcome_Code;

   --  Stable immutable manifest identity carried by Receipt.
   function Create_Receipt_Manifest_ID (Item : Create_Receipt) return Identifier;

   --  Attempted HEAD transition identity, or zero before HEAD admission.
   function Create_Receipt_Transition_ID (Item : Create_Receipt) return Identifier;

   --  Open and recover one database solely through HEAD and predecessor batches.
   --  Item and Storage must remain alive until Close returns.
   procedure Open
     (Item        : in out Database;
      Storage     : not null access Storage_Context;
      Database_ID : Database_Identifier;
      Timeout     : Duration;
      Token       : access Flyology.Cancellation.Token := null;
      Result      : out Outcome_Code);

   --  Drain admitted commits, stop and join the coordinator, and close Item.
   procedure Close (Item : in out Database; Result : out Outcome_Code);

   --  Begin one bounded transaction with a caller-stable idempotency identity.
   procedure Begin_Transaction
     (Item           : in out Database;
      Transaction_ID : Transaction_Identifier;
      Txn            : out Transaction;
      Result         : out Outcome_Code);

   --  Open one stable family handle by its persisted numeric ID.
   procedure Open_Column_Family
     (Item : in out Database; ID : Column_Family_ID; Family : out Column_Family; Result : out Outcome_Code);

   --  Open one stable family handle by its exact persisted UTF-8 name bytes.
   procedure Open_Column_Family
     (Item : in out Database; Name : Byte_Array; Family : out Column_Family; Result : out Outcome_Code);

   --  Read a buffered mutation or latest confirmed committed value into owned
   --  bytes. Data is empty on every non-Success outcome.
   procedure Get
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Byte_Array;
      Data     : out Flyology.Bytes.Unbounded_Bytes;
      Result   : out Outcome_Code);

   --  Borrow Item_Key/Data for this call and copy them once into the
   --  transaction-owned arena; no caller bytes are retained after return.
   procedure Put
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Byte_Array;
      Data     : Byte_Array;
      Result   : out Outcome_Code);

   --  Borrow Item_Key for this call and copy it once into the transaction-owned
   --  arena; no caller bytes are retained after return.
   procedure Delete
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Byte_Array;
      Result   : out Outcome_Code);

   --  Consume an active transaction without publishing it.
   procedure Rollback (Txn : in out Transaction; Result : out Outcome_Code);

   --  Submit Txn to the bounded long-lived commit coordinator and wait for it.
   --  An Outcome_Unknown receipt must be resolved and must never be replayed.
   --  Txn is consumed exactly when it is admitted to the coordinator. Rejections
   --  detected before admission leave Txn active and rollbackable, including
   --  invalid, cancelled, timed-out, conflicting, and capacity outcomes. Every
   --  outcome detected after admission consumes Txn. Cancellation no longer
   --  applies after admission, and Commit waits for terminal classification.
   --  Transaction_ID is also the immutable batch identity for this singleton.
   --  A pre-admission outcome returns a receipt with zero transaction/batch IDs;
   --  every admitted terminal outcome retains both stable identities.
   procedure Commit
     (Item    : in out Database;
      Txn     : in out Transaction;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Receipt : out Commit_Receipt;
      Result  : out Outcome_Code);

   --  Atomically admit and publish one explicit synchronous transaction group.
   --  Transactions and Receipts must have matching ranges of two through
   --  Maximum_Group_Transactions members. The whole group shares one absolute
   --  deadline, immutable batch, HEAD transition, and terminal classification.
   --  All transactions remain active on pre-admission rejection and all are
   --  consumed on admission, whatever later terminal outcome is reported.
   --  Group_ID is the exact immutable batch identity;
   --  callers must allocate it from the same never-reused namespace as singleton
   --  Transaction_ID values.
   procedure Commit_Group
     (Item         : in out Database;
      Group_ID     : Identifier;
      Transactions : in out Transaction_Array;
      Timeout      : Duration;
      Token        : access Flyology.Cancellation.Token := null;
      Receipts     : out Commit_Receipt_Array;
      Result       : out Outcome_Code);

   --  Reconcile the exact batch and HEAD transition retained by Receipt.
   procedure Resolve
     (Item    : in out Database;
      Receipt : in out Commit_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code);

   --  Outcome most recently assigned to Receipt.
   function Receipt_Outcome (Item : Commit_Receipt) return Outcome_Code;

   --  Stable application transaction identity carried by Receipt.
   function Receipt_Transaction_ID (Item : Commit_Receipt) return Transaction_Identifier;

   --  Sequence assigned to the receipt's transaction, or zero before confirmation.
   function Receipt_Sequence (Item : Commit_Receipt) return Sequence_Number;

   --  Immutable batch identity retained by the receipt.
   function Receipt_Batch_ID (Item : Commit_Receipt) return Identifier;

   --  Return the highest sequence confirmed visible while Item is safely open.
   procedure Highest_Visible (Item : in out Database; Value : out Sequence_Number; Result : out Outcome_Code);

private

   --  Bounded synchronous coordinator policy: eight visible operation slots
   --  match the maximum public group width. Raising it changes memory and
   --  backpressure behavior; it does not change persisted bytes.
   Maximum_Commit_Slots     : constant := 8;
   --  Current operational representation bound for manifest/batch history,
   --  aligned with the persisted-format runtime-compatibility contract. A
   --  larger persisted limit is not silently accepted by this implementation.
   Maximum_History_Batches  : constant := 64;
   --  Local representation cap for opaque provider ETag/version strings. It is
   --  not a content hash or wire-format field; changing it alters provider
   --  compatibility and protected-state memory.
   Maximum_Generation_Bytes : constant := 256;

   --  Bounded batch-codec reference/proof dimensions fixed by the v1 format
   --  qualification corpus. They never narrow persisted family key/value
   --  authority or dynamically allocated production data.
   Reference_Maximum_Key_Bytes        : constant := 64;
   Reference_Maximum_Value_Bytes      : constant := 256;
   --  Derived exact reference image ceiling: the accepted batch-v1 header,
   --  maximum reference payload, and trailer total 22,048 bytes. Changing a
   --  component requires coordinated formula, golden, test, and proof updates.
   Maximum_Small_Metadata_Image_Bytes : constant := 22_048;

   subtype Column_Family_Name_Length is Natural range 0 .. Maximum_Column_Family_Name_Bytes;
   type Column_Family_Name_Storage is array (Positive range 1 .. Maximum_Column_Family_Name_Bytes) of Byte;

   --  Zero lengths/limits and an all-zero name are invalid construction-state
   --  sentinels; Configure_Column_Family must replace them before publication.
   --  They introduce no implicit family policy or persisted defaults.
   type Column_Family_Configuration is record
      ID                   : Column_Family_ID := Column_Family_ID'First;
      Name_Length          : Column_Family_Name_Length := 0;
      Name                 : Column_Family_Name_Storage := [others => 0];
      Max_Key_Bytes        : Interfaces.Unsigned_64 := 0;
      Max_Value_Bytes      : Interfaces.Unsigned_64 := 0;
      Memtable_Max_Bytes   : Interfaces.Unsigned_64 := 0;
      Memtable_Max_Entries : Interfaces.Unsigned_32 := 0;
      Maximum_L0_Runs      : Interfaces.Unsigned_32 := 0;
   end record;

   --  Zero fields are vacant construction sentinels only. The public
   --  constructor replaces them and the planner revalidates exact registry
   --  coverage before allocating or publishing anything.
   type Checkpoint_Run_Identity is record
      Family_ID : Column_Family_ID := Column_Family_ID'First;
      Run_ID    : Identifier := Zero_Identifier;
   end record;

   type Engine_Incarnation is new Interfaces.Unsigned_64;
   --  In-memory handle sentinel: zero means no live engine incarnation and is
   --  never issued to an open database. This is lifecycle policy, not persisted.
   No_Incarnation : constant Engine_Incarnation := 0;

   type Internal_Allocation_Fault_Point is
     (No_Allocation_Fault,
      Transaction_Arena_Allocation,
      Transaction_Payload_Allocation,
      Batch_Descriptor_Allocation,
      Storage_Sink_Allocation,
      Recovery_History_Allocation,
      Engine_State_Allocation,
      Identity_Table_Allocation,
      Projection_Scratch_Allocation,
      Root_Checkpoint_State_Allocation,
      Root_Checkpoint_Image_Allocation,
      Root_Manifest_Retention_Allocation,
      Checkpoint_Reference_Allocation,
      Checkpoint_SST_Allocation,
      Checkpoint_Manifest_Allocation,
      Recovery_Manifest_Header_Allocation,
      Recovery_Manifest_Image_Allocation,
      Recovery_SST_Header_Allocation,
      Recovery_SST_Image_Allocation,
      Recovery_Checkpoint_Image_Allocation);
   procedure Set_Test_Allocation_Fault (Point : Internal_Allocation_Fault_Point);
   procedure Decode_Runtime_Image_For_Test
     (Data : Byte_Array; Wrong_DB : Boolean; Wrong_Head : Boolean; Result : out Outcome_Code);
   procedure Check_Runtime_Reference_Parity (Result : out Outcome_Code);
   function Group_Mutation_Total_Fits_Wire (Value : Natural) return Boolean;

   type Column_Family is record
      Valid         : Boolean := False;
      Database_ID   : Database_Identifier := Zero_Database_ID;
      Incarnation   : Engine_Incarnation := No_Incarnation;
      Configuration : Column_Family_Configuration;
   end record;

   type Mutation_Kind is (Put_Mutation, Delete_Mutation);

   protected type Shared_Image_References is
      procedure Retain;
      procedure Release (Last : out Boolean);
   private
      --  A newly allocated image starts with its creator's one owning lease;
      --  retain/release accounting and final reclamation depend on this count.
      Count : Positive := 1;
   end Shared_Image_References;

   type Shared_Image_Record is limited record
      References : Shared_Image_References;
      Data       : Flyology.Bytes.Unbounded_Bytes;
   end record;
   type Shared_Image_Access is access Shared_Image_Record;

   type Shared_Image_Lease is new Ada.Finalization.Controlled with record
      Image : Shared_Image_Access := null;
   end record;

   overriding
   procedure Adjust (Item : in out Shared_Image_Lease);
   overriding
   procedure Finalize (Item : in out Shared_Image_Lease);

   --  Mutation field initializers are vacant arena state only. Admission fills
   --  the exact operation and byte extents before encoding, so Put_Mutation is
   --  not an application default; zero lengths become meaningful only for an
   --  admitted empty-key or empty-value mutation.
   type Owned_Mutation is record
      Family       : Column_Family_ID := Column_Family_ID'First;
      Operation    : Mutation_Kind := Put_Mutation;
      Key_Length   : Natural := 0;
      Value_Length : Natural := 0;
      Payload      : Flyology.Bytes.Unbounded_Bytes;
   end record;
   type Owned_Mutation_Array is array (Positive range <>) of Owned_Mutation;
   type Owned_Mutation_Array_Access is access Owned_Mutation_Array;

   type Transaction_Arena is limited record
      Mutations  : Owned_Mutation_Array_Access := null;
      Count      : Natural := 0;
      Bytes_Used : Interfaces.Unsigned_64 := 0;
   end record;
   type Transaction_Arena_Access is access Transaction_Arena;

   type Transaction_Arena_Owner is new Ada.Finalization.Limited_Controlled with record
      Arena : Transaction_Arena_Access := null;
   end record;

   overriding
   procedure Finalize (Item : in out Transaction_Arena_Owner);

   type Transaction is limited record
      Active         : Boolean := False;
      Database_ID    : Database_Identifier := Zero_Database_ID;
      Incarnation    : Engine_Incarnation := No_Incarnation;
      Transaction_ID : Transaction_Identifier := Zero_Transaction_ID;
      Owner          : Transaction_Arena_Owner;
   end record;

   --  In-memory vacant HEADs use the current persisted version and canonical
   --  first transition number; zero identities/counters remain absence
   --  sentinels. Changing version 2 or transition 1 changes root/recovery
   --  interpretation and requires a persisted-format decision.
   type Head_Snapshot is record
      Database_ID            : Database_Identifier := Zero_Database_ID;
      Version                : Interfaces.Unsigned_16 := 2;
      Epoch                  : Interfaces.Unsigned_64 := 0;
      Highest                : Sequence_Number := 0;
      Latest_Batch           : Identifier := Zero_Identifier;
      Latest_Manifest        : Identifier := Zero_Identifier;
      Transition_ID          : Identifier := Zero_Identifier;
      Predecessor_Transition : Identifier := Zero_Identifier;
      Transition_Number      : Interfaces.Unsigned_64 := 1;
   end record;

   subtype Small_Metadata_Index is Natural range 0 .. Maximum_Small_Metadata_Image_Bytes - 1;
   type Receipt_Phase is (No_Publication, Head_Publication_Unknown, Resolved);

   type Commit_Receipt is record
      Current_Outcome   : Outcome_Code := Invalid_State;
      Phase             : Receipt_Phase := No_Publication;
      Transaction_ID    : Transaction_Identifier := Zero_Transaction_ID;
      Assigned_Sequence : Sequence_Number := 0;
      Batch_ID          : Identifier := Zero_Identifier;
      Retained_Image    : Shared_Image_Lease;
      Expected_Head     : Head_Snapshot;
      Attempted_Head    : Head_Snapshot;
   end record;

   type Create_Receipt_Phase is
     (No_Create_Publication, Manifest_Confirmed, Head_Publication_Unknown, Head_Confirmed);

   type Create_Receipt is record
      Current_Outcome   : Outcome_Code := Invalid_State;
      Phase             : Create_Receipt_Phase := No_Create_Publication;
      Database_ID       : Database_Identifier := Zero_Database_ID;
      Manifest_ID       : Identifier := Zero_Identifier;
      Retained_Manifest : Shared_Image_Lease;
      Attempted_Head    : Head_Snapshot;
   end record;

   type Storage_Fault_Point is
     (Before_Batch_Put,
      After_Batch_Put,
      Before_Run_Put,
      After_Run_Put,
      Before_Manifest_Put,
      After_Manifest_Put,
      Before_Head_Put,
      After_Head_Put,
      Before_Get,
      Before_Manifest_Get,
      Before_Local_Activation);
   type Storage_Fault_Mode is (No_Fault, Definite_Failure, Unknown_After_Entry);
   type Storage_Fault_Count is array (Storage_Fault_Point) of Natural;
   type Storage_Fault_Modes is array (Storage_Fault_Point) of Storage_Fault_Mode;

   protected type Storage_Test_Control is
      procedure Arm (Point : Storage_Fault_Point; Mode : Storage_Fault_Mode; Count : Positive);
      procedure Clear;
      procedure Consume (Point : Storage_Fault_Point; Mode : out Storage_Fault_Mode);
      procedure Record_Put (Is_Head, Is_Manifest, Is_Run : Boolean);
      procedure Publication_Counts
        (Batch_Total : out Natural; Manifest_Total : out Natural; Head_Total : out Natural);
      procedure Publication_Counts
        (Batch_Total    : out Natural;
         Run_Total      : out Natural;
         Manifest_Total : out Natural;
         Head_Total     : out Natural);
      procedure Set_Get_Paused (Value : Boolean);
      procedure Arrive_Get;
      entry Await_Get;
      entry Continue_Get;
      function Get_Waiting return Boolean;
   private
      Fault_Counts  : Storage_Fault_Count := [others => 0];
      Fault_Modes   : Storage_Fault_Modes := [others => No_Fault];
      Batch_Puts    : Natural := 0;
      Run_Puts      : Natural := 0;
      Manifest_Puts : Natural := 0;
      Head_Puts     : Natural := 0;
      Get_Paused    : Boolean := False;
      Waiting_Gets  : Natural := 0;
   end Storage_Test_Control;

   type Storage_Context is limited record
      Backend      : access Flyology.Object_Storage.Backends.Backend'Class := null;
      Bucket       : Ada.Strings.Unbounded.Unbounded_String;
      Prefix       : Ada.Strings.Unbounded.Unbounded_String;
      Test_Control : Storage_Test_Control;
   end record;

   type Engine_State (<>);
   type Engine_State_Access is access Engine_State;

   --  In-memory lifecycle policy only; enumeration positions are never
   --  persisted. Checkpointing excludes new calls while a synchronous flush
   --  waits for earlier leases and borrows immutable live-state images.
   type Database_Lifecycle_Mode is (Closed, Opening, Opened, Closing, Resolving, Checkpointing);

   protected type Database_Lifecycle is
      procedure Begin_Open (Result : out Outcome_Code);
      procedure Complete_Open
        (State : not null Engine_State_Access; Visible : Sequence_Number; Result : out Outcome_Code);
      procedure Abort_Open;
      procedure Acquire (State : out Engine_State_Access; Result : out Outcome_Code);
      procedure Release;
      procedure Begin_Close (State : out Engine_State_Access; Result : out Outcome_Code);
      procedure Begin_Resolve (State : out Engine_State_Access; Result : out Outcome_Code);
      procedure Begin_Checkpoint (State : out Engine_State_Access; Result : out Outcome_Code);
      entry Await_Quiescent;
      procedure Finish_Close;
      procedure Finish_Resolve (State : not null Engine_State_Access; Visible : Sequence_Number);
      procedure Cancel_Resolve;
      procedure Finish_Checkpoint;
      procedure Cancel_Checkpoint;
      procedure Set_Visible (Value : Sequence_Number);
      function Highest (Result : out Outcome_Code) return Sequence_Number;
   private
      Mode         : Database_Lifecycle_Mode := Closed;
      Current      : Engine_State_Access := null;
      Active_Calls : Natural := 0;
      Last_Visible : Sequence_Number := 0;
   end Database_Lifecycle;
   type Database_Lifecycle_Access is access all Database_Lifecycle;

   type Database is new Ada.Finalization.Limited_Controlled with record
      Life : aliased Database_Lifecycle;
   end record;

   overriding
   procedure Finalize (Item : in out Database);

   procedure Set_Test_Paused (Item : in out Database; Value : Boolean; Result : out Outcome_Code);
   procedure Test_Queue_Depth (Item : in out Database; Value : out Natural; Result : out Outcome_Code);
   procedure Fail_Next_Test_Install (Item : in out Database; Result : out Outcome_Code);
   procedure Set_Test_Get_Paused (Item : in out Storage_Context; Value : Boolean);
   procedure Wait_For_Test_Get (Item : in out Storage_Context; Timeout : Duration; Arrived : out Boolean);
   function Test_Get_Waiting (Item : Storage_Context) return Boolean;
   procedure Test_Image_Statistics
     (Allocated, Released, Arenas_Allocated, Arenas_Released, Transaction_Bytes, Source_Bytes, Sink_Bytes :
        out Interfaces.Unsigned_64);
   procedure Install_Test_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Legacy        : Boolean;
      Result        : out Outcome_Code);
   procedure Install_Test_Unsupported_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code);
   procedure Install_Test_Invalid_V2_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code);
   procedure Corrupt_Test_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code);
   procedure Remove_Test_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code);
   procedure Corrupt_Test_Run (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code);
   procedure Remove_Test_Run (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code);
   procedure Rewrite_Test_Run_Family
     (Item      : in out Storage_Context;
      Run_ID    : Identifier;
      Family_ID : Column_Family_ID;
      Result    : out Outcome_Code);
   procedure Rewrite_Test_Manifest
     (Item                 : in out Storage_Context;
      Manifest_ID          : Identifier;
      Expected_Database_ID : Database_Identifier;
      Replacement_Database : Database_Identifier;
      Oversize_Family      : Boolean;
      Drop_Last_Family     : Boolean;
      Restricted_Family    : Interfaces.Unsigned_32;
      Restricted_Max_Key   : Interfaces.Unsigned_64;
      Result               : out Outcome_Code);
   procedure Extend_Test_Manifest_Chain
     (Item        : in out Storage_Context;
      Database_ID : Database_Identifier;
      Root_ID     : Identifier;
      Successors  : Positive;
      Result      : out Outcome_Code);
   procedure Read_Test_Manifest_Version
     (Item        : in out Storage_Context;
      Manifest_ID : Identifier;
      Version     : out Interfaces.Unsigned_16;
      Result      : out Outcome_Code);
   procedure Read_Test_Root_LSM_Limits
     (Item                   : in out Storage_Context;
      Manifest_ID            : Identifier;
      Expected_Database      : Database_Identifier;
      Family_ID              : Column_Family_ID;
      Maximum_Total_L0_Runs  : out Interfaces.Unsigned_32;
      Maximum_Identities     : out Interfaces.Unsigned_32;
      Memtable_Max_Bytes     : out Interfaces.Unsigned_64;
      Memtable_Max_Entries   : out Interfaces.Unsigned_32;
      Maximum_Family_L0_Runs : out Interfaces.Unsigned_32;
      Result                 : out Outcome_Code);
   procedure Read_Test_Live_LSM_Limits
     (Item                   : in out Database;
      Family_ID              : Column_Family_ID;
      Replay_Boundary        : out Interfaces.Unsigned_64;
      Maximum_Total_L0_Runs  : out Interfaces.Unsigned_32;
      Maximum_Identities     : out Interfaces.Unsigned_32;
      Memtable_Max_Bytes     : out Interfaces.Unsigned_64;
      Memtable_Max_Entries   : out Interfaces.Unsigned_32;
      Maximum_Family_L0_Runs : out Interfaces.Unsigned_32;
      Result                 : out Outcome_Code);
   procedure Read_Test_Live_Entry_Sequence
     (Item      : in out Database;
      Family_ID : Column_Family_ID;
      Item_Key  : Byte_Array;
      Sequence  : out Sequence_Number;
      Result    : out Outcome_Code);
   procedure Build_Test_First_SST
     (Item             : in out Database;
      Family_ID        : Column_Family_ID;
      Run_ID           : Identifier;
      Entry_Total      : out Natural;
      Lowest_Sequence  : out Sequence_Number;
      Highest_Sequence : out Sequence_Number;
      Result           : out Outcome_Code);
   procedure Build_Test_First_Checkpoint
     (Item            : in out Database;
      Runs            : Checkpoint_Run_Identity_Array;
      Manifest_ID     : Identifier;
      Transition_ID   : Identifier;
      Run_Total       : out Natural;
      Identity_Total  : out Natural;
      Replay_Boundary : out Sequence_Number;
      Result          : out Outcome_Code);
   procedure Publish_Test_First_Checkpoint
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code);
   function Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier;

end Flyology.DB;
