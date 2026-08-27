with Interfaces;
with Flyology.Buffers;
with Flyology.Cancellation;
with Flyology.Bytes;
with Flyology.HTTP.Client;
with Flyology.Operations;
private with Ada.Exceptions;
private with Ada.Finalization;
private with Ada.Real_Time;
private with Ada.Strings.Unbounded;
private with Flyology.HTTP;
private with Flyology.Object_Storage.Backends;
private with Flyology.Object_Storage.Client.Low_Level;
private with Flyology.Object_Storage.Client.Objects;
private with Flyology.Wake_Sources;
private with Interfaces.C;

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
      --  Persisted serializable-observation count authority. Exact point keys
      --  and range endpoints remain bounded by their selected family; these
      --  database-wide counts add backpressure without a library default.
      Maximum_Point_Reads_Per_Transaction : Interfaces.Unsigned_32;
      Maximum_Scan_Ranges_Per_Transaction : Interfaces.Unsigned_32;
   end record;

   --  One failure-atomic read of the exact installed persisted database
   --  configuration. Registry_Revision and Family_Count come from the same
   --  authenticated manifest as Limits; this record adds no defaults or
   --  mutable policy.
   --  @field Registry_Revision Exact installed registry revision
   --  @field Family_Count Exact installed family total
   --  @field Limits Complete installed database-wide limits
   type Database_Configuration_Snapshot is record
      Registry_Revision : Interfaces.Unsigned_64;
      Family_Count      : Interfaces.Unsigned_32;
      Limits            : Database_Limits;
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

   --  Whether Item carries one complete constructible or persisted family
   --  configuration. This predicate selects no fallback values.
   --  @param Item Family configuration to validate
   --  @return True only when every base and LSM field is valid
   function Is_Valid_Column_Family_Configuration (Item : Column_Family_Configuration) return Boolean;

   --  Stable persisted numeric family identity.
   --  @param Item Valid complete family configuration
   --  @return Exact persisted family ID
   function Column_Family_Configuration_ID
     (Item : Column_Family_Configuration) return Column_Family_ID
     with Pre => Is_Valid_Column_Family_Configuration (Item);

   --  Exact persisted UTF-8 family-name bytes, without normalization.
   --  @param Item Valid complete family configuration
   --  @return Exact persisted family-name bytes
   function Column_Family_Configuration_Name
     (Item : Column_Family_Configuration) return Byte_Array
     with Pre => Is_Valid_Column_Family_Configuration (Item);

   --  Exact persisted maximum key extent.
   --  @param Item Valid complete family configuration
   --  @return Exact maximum key bytes
   function Column_Family_Configuration_Max_Key_Bytes
     (Item : Column_Family_Configuration) return Interfaces.Unsigned_64
     with Pre => Is_Valid_Column_Family_Configuration (Item);

   --  Exact persisted maximum value extent.
   --  @param Item Valid complete family configuration
   --  @return Exact maximum value bytes
   function Column_Family_Configuration_Max_Value_Bytes
     (Item : Column_Family_Configuration) return Interfaces.Unsigned_64
     with Pre => Is_Valid_Column_Family_Configuration (Item);

   --  Exact persisted logical memtable byte authority.
   --  @param Item Valid complete family configuration
   --  @return Exact memtable byte ceiling
   function Column_Family_Configuration_Memtable_Max_Bytes
     (Item : Column_Family_Configuration) return Interfaces.Unsigned_64
     with Pre => Is_Valid_Column_Family_Configuration (Item);

   --  Exact persisted memtable-entry authority.
   --  @param Item Valid complete family configuration
   --  @return Exact memtable entry ceiling
   function Column_Family_Configuration_Memtable_Max_Entries
     (Item : Column_Family_Configuration) return Interfaces.Unsigned_32
     with Pre => Is_Valid_Column_Family_Configuration (Item);

   --  Exact persisted per-family L0-run authority.
   --  @param Item Valid complete family configuration
   --  @return Exact per-family L0-run ceiling
   function Column_Family_Configuration_Maximum_L0_Runs
     (Item : Column_Family_Configuration) return Interfaces.Unsigned_32
     with Pre => Is_Valid_Column_Family_Configuration (Item);

   --  Bind one configured family to the immutable run identity selected by a
   --  checkpoint operation. Run_ID must be nonzero. Flush and complete
   --  compaction require one mapping for every family that produces an SST,
   --  reject duplicate families or run IDs, and continue accepting a full
   --  persisted-family map by ignoring no-work entries. The mapping is
   --  borrowed only for the call and is never retained.
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

   --  Transaction isolation selected explicitly at Begin. Snapshot preserves
   --  fixed-snapshot write/write validation; Serializable additionally retains
   --  exact read predicates for commit-time validation. Enumeration positions
   --  are runtime-only and are never persisted or placed on the wire.
   --  @enum Snapshot Fixed snapshot plus write/write validation only
   --  @enum Serializable Snapshot validation plus retained read predicates
   type Isolation_Level is (Snapshot, Serializable);

   type Storage_Context is limited private;
   type Database is limited private;
   type Transaction is limited private;
   --  Limited owned materialization replaced atomically by Scan. Its dynamic
   --  storage is bounded only by persisted database/family authorities and is
   --  reclaimed automatically; the type introduces no copy or default limit.
   type Scan_Result is limited private;
   --  Limited owned fixed-snapshot page position. It copies range endpoints
   --  and retains identity/version facts only; no Database, Transaction,
   --  Column_Family, or caller-array access value survives Start_Scan.
   type Scan_Cursor is limited private;
   type Create_Receipt is private;
   --  Self-contained exact family-registry publication and reconciliation
   --  authority. Its retained immutable bytes are reclaimed automatically.
   type Column_Family_Receipt is private;
   type Commit_Receipt is private;
   --  Self-contained checkpoint publication and reconciliation state.
   type Flush_Receipt is private;
   --  Runtime-only maintenance choice derived from persisted L0 limits and an
   --  exact current writer view. Enumeration positions are never persisted or
   --  placed on the wire.
   --  @enum No_L0_Checkpoint_Work No committed suffix requires a checkpoint
   --  @enum Additive_Flush_Required Current runs admit one delta run per changed family
   --  @enum Complete_Compaction_Required Additive growth is full but a complete
   --  run per nonempty family fits
   type L0_Checkpoint_Action is
     (No_L0_Checkpoint_Work,
      Additive_Flush_Required,
      Complete_Compaction_Required);
   --  Owned exact-family projection of one checkpoint-action observation.
   --  Dynamic storage is derived from the observed persisted registry and is
   --  reclaimed automatically; the type retains no Database borrow.
   type L0_Checkpoint_Requirement is limited private;
   --  Caller-composable initial database publication. The discriminants are
   --  retained borrows and must outlive terminal Finish or abandonment drain.
   --  Storage must be bound to the exact HTTP client. Payload_Pool supplies
   --  caller-selected publication/reconciliation scratch capacity; the DB
   --  introduces no object-size bound, retry, helper task, or timeout default.
   --  The worst-case owner stack needs five reusable slots while an existing
   --  or ambiguously published HEAD is reconciled: DB Create, DB recovery,
   --  Object Storage, HTTP exchange, and transport.
   type Create_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation with private;
   --  Caller-composable checkpoint and family-registry publication. The discriminants are
   --  retained borrows: Set, Item, Storage, HTTP, Payload_Pool, and
   --  Cancellation must outlive terminal Finish or scope-abandonment drain.
   --  Storage must be bound to the exact HTTP client. Payload_Pool supplies
   --  caller-selected scratch capacity; the DB introduces no body-size
   --  default or ceiling. The worst-case owner stack needs five reusable set
   --  slots while receipt resolution owns the bounded recovery child: DB
   --  Flush, DB recovery, Object Storage, HTTP exchange, and transport. Normal
   --  publication and selected-run reads use at most the shorter four-slot
   --  prefix.
   type Flush_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation with private;
   --  Caller-composable monotonic replica refresh. The discriminants are
   --  retained borrows and must outlive terminal Finish or abandonment drain.
   --  Storage must be bound to the exact HTTP client. Payload_Pool supplies
   --  caller-selected recovery scratch capacity; the DB introduces no body
   --  size default or ceiling. The owner stack has the same four-slot geometry
   --  as composable checkpoint I/O: DB, Object Storage, HTTP, and transport.
   type Refresh_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation with private;
   --  Caller-composable cacheless open. The discriminants are retained borrows
   --  and must outlive terminal Finish or abandonment drain. Storage must be
   --  bound to the exact HTTP client. Payload_Pool supplies the caller-selected
   --  recovery scratch capacity; the DB introduces no recovery-object bound,
   --  helper task, retry, or timeout default. A failed or abandoned operation
   --  restores Item to the closed lifecycle state.
   type Open_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation with private;
   --  Caller-composable fixed-snapshot point read. Item and Txn are retained
   --  borrows through terminal publication; the caller must not use Txn while
   --  the operation is active. Payload_Pool supplies the sole caller-selected
   --  storage scratch bound. The operation checks transaction-local and
   --  committed suffix state before reading immutable checkpoint runs, and
   --  introduces no helper task, retry, run cap, timeout default, or cache.
   type Get_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Txn          : not null access Transaction;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token)
   is new Flyology.Operations.Operation with private;
   --  Caller-composable authenticated fixed-snapshot scan initialization or
   --  storage-backed page advancement.
   --  Item and Txn are retained borrows through terminal publication; the
   --  caller must not use Txn while the operation is active. Payload_Pool
   --  supplies the sole caller-selected object-read scratch bound. The
   --  established Start_Scan form reads each run's canonical
   --  snapshot-visible entries through generation-bound next-entry reads and
   --  creates the same owned materialized cursor used by storage-free
   --  Next_Scan_Page. Start_Storage_Backed_Scan instead retains exact run
   --  descriptors plus in-memory sources; the composable Next_Scan_Page
   --  overload fetches at most one authenticated current head per immutable
   --  run while building a page. Neither form introduces a helper task,
   --  mutation retry, run cap, page default, prefetch, or cache.
   type Scan_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Txn          : not null access Transaction;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation with private;
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

   --  Create through the owner-driven publication operation while moving one
   --  exact caller scratch token. The client-bound path waits the same state
   --  machine as the composable form; backend-neutral storage retains the
   --  established synchronous implementation. Payload_Buffer is restored
   --  before return or propagation of an unexpected local exception.
   --  @param Item Closed database to create or reconcile idempotently
   --  @param Storage Client-bound context, or backend-neutral synchronous context
   --  @param Database_ID Exact new database identity
   --  @param Manifest_ID Stable immutable root-manifest identity
   --  @param Initial_Transition_ID Stable initial HEAD transition identity
   --  @param Limits Complete caller-selected persisted database limits
   --  @param Initial_Families Complete caller-selected initial family registry
   --  @param Payload_Buffer Acquired caller-owned publication/recovery scratch token
   --  @param Timeout Whole-create monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Receipt Exact publication and reconciliation authority
   --  @param Result Definite terminal or presently unknown outcome
   procedure Create
     (Item                  : in out Database;
      Storage               : not null access Storage_Context;
      Database_ID           : Database_Identifier;
      Manifest_ID           : Identifier;
      Initial_Transition_ID : Identifier;
      Limits                : Database_Limits;
      Initial_Families      : Column_Family_Configuration_Array;
      Payload_Buffer        : in out Flyology.Buffers.Unique_Buffer;
      Timeout               : Duration;
      Token                 : access Flyology.Cancellation.Token := null;
      Receipt               : out Create_Receipt;
      Result                : out Outcome_Code)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Start or restart one owner-driven initial publication. All caller input
   --  is copied into owned manifest/HEAD state before return. Conditional
   --  mutation is never replayed; ambiguous admission retains exact receipt
   --  authority for Resolve_Create.
   --  @param Database_ID Exact new database identity copied before return
   --  @param Manifest_ID Stable immutable root-manifest identity
   --  @param Initial_Transition_ID Stable initial HEAD transition identity
   --  @param Limits Complete caller-selected persisted database limits
   --  @param Initial_Families Complete caller-selected initial family registry
   --  @param Payload_Buffer Acquired caller-owned scratch token moved until Finish
   --  @param Timeout Whole-create monotonic timeout budget
   --  @param Operation Fresh or consumed client-bound Create operation
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Storage binding
   procedure Create
     (Database_ID           : Database_Identifier;
      Manifest_ID           : Identifier;
      Initial_Transition_ID : Identifier;
      Limits                : Database_Limits;
      Initial_Families      : Column_Family_Configuration_Array;
      Payload_Buffer        : in out Flyology.Buffers.Unique_Buffer;
      Timeout               : Duration;
      Operation             : in out Create_Operation)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Consume one terminal Create and restore its exact token into any vacant
   --  same-pool handle. Receipt remains self-contained for caller-driven
   --  reconciliation when Result is Outcome_Unknown.
   --  @param Operation Terminal caller-owned Create operation
   --  @param Receipt Exact publication and reconciliation authority
   --  @param Result Definite terminal or presently unknown outcome
   --  @param Payload_Buffer Vacant same-pool destination for the exact token
   procedure Finish
     (Operation      : in out Create_Operation;
      Receipt        : out Create_Receipt;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
     with Pre => Flyology.Operations.Is_Terminal (Operation)
       and then not Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool,
       Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Start or restart receipt-driven Create resolution on the same provider-
   --  owned state machine as Create. The exact receipt authority and scratch
   --  token move into Operation until typed Finish. A confirmed manifest may
   --  admit its exact HEAD mutation once; an unknown HEAD is reconciled only
   --  by reads and is never replayed.
   --  @param Receipt Exact resumable Create publication authority moved until Finish
   --  @param Payload_Buffer Acquired caller-owned scratch token moved until Finish
   --  @param Timeout Whole-resolution monotonic timeout budget
   --  @param Operation Fresh or consumed client-bound Create operation
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Storage binding
   procedure Resolve_Create
     (Receipt        : in out Create_Receipt;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Create_Operation)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Resume or reconcile Create through the owner-driven operation while
   --  moving one exact caller scratch token. Client-bound execution waits the
   --  same state machine as the composable overload; backend-neutral storage
   --  retains the established direct synchronous implementation.
   --  @param Item Closed database to activate after conclusive resolution
   --  @param Storage Exact storage binding retained by an activated database
   --  @param Receipt Exact resumable Create publication authority
   --  @param Payload_Buffer Acquired caller-owned resolution scratch token
   --  @param Timeout Whole-resolution monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Result Definite terminal or presently unknown outcome
   procedure Resolve_Create
     (Item           : in out Database;
      Storage        : not null access Storage_Context;
      Receipt        : in out Create_Receipt;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Token          : access Flyology.Cancellation.Token := null;
      Result         : out Outcome_Code)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer);

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

   --  Open through the owner-driven recovery operation while moving one exact
   --  caller scratch token. This synchronous overload waits the same state
   --  machine as the composable form below and restores Payload_Buffer before
   --  return or propagation of an unexpected local exception.
   --  @param Item Closed database to open
   --  @param Storage Client-bound object-storage context retained until Close
   --  @param Database_ID Exact persisted database identity to authenticate
   --  @param Payload_Buffer Acquired caller-owned recovery scratch token
   --  @param Timeout Whole-open monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Result Complete recovery/install or typed failure outcome
   procedure Open
     (Item           : in out Database;
      Storage        : not null access Storage_Context;
      Database_ID    : Database_Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Token          : access Flyology.Cancellation.Token := null;
      Result         : out Outcome_Code)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Start or restart one cacheless open in an established caller-owned
   --  operation. Lifecycle admission and owner validation precede moving the
   --  exact Payload_Buffer token. Database_ID is copied before return.
   --  @param Database_ID Exact persisted database identity to authenticate
   --  @param Payload_Buffer Acquired caller-owned recovery scratch token
   --  @param Timeout Whole-open monotonic timeout budget
   --  @param Operation Fresh or consumed client-bound open operation
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Storage binding
   procedure Open
     (Database_ID    : Database_Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Open_Operation)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Consume one terminal owner-driven open and restore its exact scratch
   --  token into any vacant same-pool handle. An unexpected provider exception
   --  is re-raised only after ownership restoration and lifecycle cleanup.
   --  @param Operation Terminal composable open operation
   --  @param Result Complete recovery/install or typed failure outcome
   --  @param Payload_Buffer Vacant same-pool destination for the exact token
   procedure Finish
     (Operation      : in out Open_Operation;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
     with Pre => Flyology.Operations.Is_Terminal (Operation)
       and then not Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool,
       Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Perform one caller-triggered monotonic refresh of an open handle used as
   --  a read-only replica. The caller must finish every transaction and other
   --  operation on Item before calling. Refresh validates a complete
   --  authoritative recovery graph and atomically installs it only when its
   --  transition-number/writer-epoch pair is newer than the installed pair;
   --  observing the same or an older valid pair succeeds without changing the
   --  local view. Allocation or recovery failure preserves the prior view.
   --  This call neither polls nor retries and never promotes a fenced handle;
   --  Stale_Writer remains terminal for that handle. Timeout is the caller's
   --  one monotonic budget, and Token supplies optional cooperative
   --  cancellation. The operation selects no replica lease, cadence,
   --  registration, retention, or promotion policy.
   --  @param Item Open caller-designated read-only replica handle to refresh
   --  @param Timeout Whole-refresh monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Result Monotonic install/no-op or typed failure outcome
   procedure Refresh_Replica
     (Item    : in out Database;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code);

   --  Start or restart one owner-driven replica refresh. All validation,
   --  operation-slot reservation, and lifecycle admission occur before the
   --  exact Payload_Buffer token moves into operation ownership. Every child
   --  uses one absolute deadline and the shared recovery request/consume
   --  machine; there is no helper task, retry, or retained caller-handle
   --  pointer. On an exception during Start, the lifecycle and slot roll back
   --  and Payload_Buffer is restored byte/tag/metadata/length exact.
   --  @param Payload_Buffer Acquired caller-owned recovery scratch token
   --  @param Timeout Whole-refresh monotonic timeout budget
   --  @param Operation Fresh or consumed client-bound refresh operation
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Storage binding
   procedure Refresh_Replica
     (Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Refresh_Operation)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Consume a terminal owner-driven refresh and restore its exact scratch
   --  token. Payload_Buffer may be any vacant handle from the original pool;
   --  no pointer to the initiating handle is retained. An unexpected provider
   --  exception is re-raised only after ownership restoration and operation
   --  consumption.
   --  @param Operation Terminal composable refresh operation
   --  @param Result Monotonic install/no-op or typed failure outcome
   --  @param Payload_Buffer Vacant same-pool destination for the exact token
   procedure Finish
     (Operation      : in out Refresh_Operation;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
     with Pre => Flyology.Operations.Is_Terminal (Operation)
       and then not Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool,
       Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Append one explicit immutable column-family configuration and publish
   --  one conditional manifest-bearing HEAD transition. Configuration supplies
   --  every key/value, memtable, and L0 authority; the DB selects no defaults.
   --  ID must be strictly greater than the current last family ID and Name must
   --  be unique. The current state must be an exact durable checkpoint with no
   --  later commit suffix; call Flush first when commits follow that checkpoint.
   --  This preserves every existing run and reserved identity without selecting
   --  new run identities. Manifest_ID and Transition_ID are caller-stable and
   --  never reusable after their publication begins. Outcome_Unknown must be
   --  resolved with the exact Receipt and never replayed under replacement
   --  identities. Success makes the family discoverable through
   --  Open_Column_Family.
   --  @param Item Open current-writer database whose registry is extended
   --  @param Configuration Exact caller-selected family authority to append
   --  @param Manifest_ID Stable immutable successor-manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Receipt Self-contained publication and reconciliation authority
   --  @param Result Definite terminal or presently unknown outcome
   procedure Add_Column_Family
     (Item          : in out Database;
      Configuration : Column_Family_Configuration;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token := null;
      Receipt       : out Column_Family_Receipt;
      Result        : out Outcome_Code);

   --  Start the same family-registry publication in an established caller-owned
   --  checkpoint operation. Configuration and identities are copied before
   --  return. Initiating owner/request-shape validation, completion-slot
   --  reservation, and lifecycle admission precede moving Payload_Buffer;
   --  persisted-state validation then runs in the owner-driven operation.
   --  Successful initiation leaves the caller handle vacant until the typed
   --  Finish below. No helper task, retry, second deadline, or retained caller
   --  input is introduced.
   --  @param Configuration Exact caller-selected family authority to append
   --  @param Manifest_ID Stable immutable successor-manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Payload_Buffer Acquired caller-owned scratch token moved until Finish
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @param Operation Fresh or consumed client-bound checkpoint operation
   procedure Add_Column_Family
     (Configuration  : Column_Family_Configuration;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Flush_Operation)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Consume a terminal composable family append and restore its exact input
   --  token into any vacant same-pool handle. Receipt preserves the same
   --  publication and reconciliation authority as the synchronous overload.
   --  @param Operation Terminal caller-owned checkpoint operation
   --  @param Receipt Self-contained publication and reconciliation authority
   --  @param Result Definite terminal or presently unknown outcome
   --  @param Payload_Buffer Vacant same-pool destination for the exact token
   --  @exception Program_Error Operation contains a Flush result instead
   procedure Finish
     (Operation      : in out Flush_Operation;
      Receipt        : out Column_Family_Receipt;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
     with Pre => Flyology.Operations.Is_Terminal (Operation)
       and then not Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool,
       Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Continue exact immutable-manifest confirmation or reconcile the attempted
   --  HEAD retained by Receipt. No identity, configuration, or bytes change.
   --  @param Item Same open database retained by the original append attempt
   --  @param Receipt Original nonterminal receipt, updated in place
   --  @param Timeout Whole-resolution monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Result Terminal or still-unknown resolution outcome
   procedure Resolve_Add_Column_Family
     (Item    : in out Database;
      Receipt : in out Column_Family_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code);

   --  Outcome most recently assigned to Receipt.
   --  @param Item Family-registry publication receipt
   --  @return Most recent terminal or nonterminal classification
   function Column_Family_Receipt_Outcome (Item : Column_Family_Receipt) return Outcome_Code;

   --  Stable appended family identity carried by Receipt.
   --  @param Item Family-registry publication receipt
   --  @return Exact caller-supplied family ID, or zero before plan admission
   function Column_Family_Receipt_Family_ID (Item : Column_Family_Receipt) return Column_Family_ID;

   --  Stable immutable successor-manifest identity carried by Receipt.
   --  @param Item Family-registry publication receipt
   --  @return Exact caller-supplied manifest ID, or zero before plan admission
   function Column_Family_Receipt_Manifest_ID (Item : Column_Family_Receipt) return Identifier;

   --  Attempted HEAD transition identity, or zero before conditional HEAD
   --  call entry.
   --  @param Item Family-registry publication receipt
   --  @return Exact caller-supplied transition ID or zero
   function Column_Family_Receipt_Transition_ID (Item : Column_Family_Receipt) return Identifier;

   --  Drain admitted commits, stop and join the coordinator, and close Item.
   procedure Close (Item : in out Database; Result : out Outcome_Code);

   --  Begin one bounded transaction with a caller-stable idempotency identity
   --  and capture the current global sequence for later write validation.
   procedure Begin_Transaction
     (Item           : in out Database;
      Transaction_ID : Transaction_Identifier;
      Txn            : out Transaction;
      Result         : out Outcome_Code);

   --  Begin one bounded transaction at an explicit isolation level. A
   --  Serializable transaction retains distinct external point and half-open
   --  range observations up to their independent persisted limits; a legacy
   --  manifest without both authorities is rejected as Unsupported_Format.
   --  No isolation is inferred.
   --  @param Item Open database whose current sequence and persisted limits are used
   --  @param Transaction_ID Caller-stable never-reused transaction identity
   --  @param Isolation Explicit runtime isolation selection
   --  @param Txn Vacant transaction output populated only on Success
   --  @param Result Success or the exact lifecycle, format, identity, or capacity outcome
   procedure Begin_Transaction
     (Item           : in out Database;
      Transaction_ID : Transaction_Identifier;
      Isolation      : Isolation_Level;
      Txn            : out Transaction;
      Result         : out Outcome_Code);

   --  Open one stable family handle by its persisted numeric ID.
   procedure Open_Column_Family
     (Item : in out Database; ID : Column_Family_ID; Family : out Column_Family; Result : out Outcome_Code);

   --  Open one stable family handle by its exact persisted UTF-8 name bytes.
   procedure Open_Column_Family
     (Item : in out Database; Name : Byte_Array; Family : out Column_Family; Result : out Outcome_Code);

   --  Replace Configuration with the exact installed manifest revision,
   --  family count, and persisted database-wide limits. Failure leaves the
   --  caller's prior Configuration unchanged. This is a local authoritative
   --  snapshot: it performs no storage I/O, refresh, migration, or retry.
   --  @param Item Open database whose installed manifest is inspected
   --  @param Configuration Prior value replaced only on Success
   --  @param Result Success or the exact lifecycle/certainty outcome
   procedure Read_Configuration
     (Item          : in out Database;
      Configuration : in out Database_Configuration_Snapshot;
      Result        : out Outcome_Code);

   --  Atomically replace Configuration and the used prefix of Families with
   --  one installed registry snapshot. Configuration.Family_Count is the
   --  exact used-prefix length; entries are in stable increasing family-ID
   --  order. If Families is shorter than that count, Capacity_Exceeded leaves
   --  both caller outputs unchanged. Success leaves any excess tail elements
   --  unchanged. The call performs no storage I/O, refresh, or dynamic allocation.
   --  @param Item Open database whose complete installed registry is inspected
   --  @param Configuration Prior database snapshot replaced only on Success
   --  @param Families Caller-owned capacity whose used prefix is replaced
   --  @param Result Success, Capacity_Exceeded, or exact lifecycle outcome
   procedure Read_Configuration
     (Item          : in out Database;
      Configuration : in out Database_Configuration_Snapshot;
      Families      : in out Column_Family_Configuration_Array;
      Result        : out Outcome_Code);

   --  Replace Configuration with the exact installed settings for Family.
   --  Family must belong to Item's current engine incarnation. Failure leaves
   --  the caller's prior Configuration unchanged. The returned value combines
   --  the authenticated base family record and its persisted LSM extension
   --  from one installed engine snapshot.
   --  @param Item Open database whose installed family authority is inspected
   --  @param Family Current family handle to validate
   --  @param Configuration Prior value replaced only on Success
   --  @param Result Success or the exact validation/lifecycle outcome
   procedure Read_Configuration
     (Item          : in out Database;
      Family        : Column_Family;
      Configuration : in out Column_Family_Configuration;
      Result        : out Outcome_Code);

   --  Read the newest buffered mutation first, then the newest committed value
   --  at the transaction's fixed Begin snapshot, into owned bytes. Conflict
   --  means the requested snapshot predates retained checkpoint history. Data
   --  is empty on every non-Success outcome. A Serializable external read
   --  retains its exact family/key predicate on Success or Not_Found;
   --  Capacity_Exceeded means a new predicate could not be retained, never
   --  that the observation was silently omitted.
   --  @param Item Open database that owns committed and checkpoint read authority
   --  @param Txn Active transaction whose fixed snapshot and observations are used
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Item_Key Exact arbitrary-byte key borrowed only for this call
   --  @param Data Owned value bytes, empty on every non-Success outcome
   --  @param Result Success, Not_Found, or the exact validation/capacity/lifecycle outcome
   procedure Get
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Byte_Array;
      Data     : out Flyology.Bytes.Unbounded_Bytes;
      Result   : out Outcome_Code);

   --  Start or restart the storage-backed form of the same fixed-snapshot
   --  point read in an established caller-owned operation. Family and Item_Key
   --  are copied before return. Lifecycle and completion-slot admission occur
   --  before the exact Payload_Buffer token moves into operation ownership.
   --  Successful initiation leaves the caller handle vacant until typed
   --  Finish. The operation retains exclusive use of its Txn discriminant
   --  while active and records a Serializable point observation only after a
   --  conclusive Success or Not_Found result.
   --  @param Family Valid family handle copied for the fixed read
   --  @param Item_Key Exact arbitrary-byte key copied before return
   --  @param Payload_Buffer Acquired caller-owned storage scratch token
   --  @param Timeout One monotonic budget for the complete read
   --  @param Operation Fresh or consumed database/transaction-bound operation
   procedure Get
     (Family         : Column_Family;
      Item_Key       : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Get_Operation)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Consume a terminal owner-driven Get, restore its exact scratch token
   --  into any vacant same-pool handle, and return the same Data/Result pair as
   --  the synchronous overload. Data is empty on every non-Success outcome.
   --  An unexpected retained exception is re-raised only after token and
   --  operation ownership are restored.
   --  @param Operation Terminal fixed-snapshot point read
   --  @param Data Owned value bytes, empty on every non-Success outcome
   --  @param Result Success, Not_Found, or exact typed failure
   --  @param Payload_Buffer Vacant same-pool destination for the exact token
   procedure Finish
     (Operation      : in out Get_Operation;
      Data           : out Flyology.Bytes.Unbounded_Bytes;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
     with Pre => Flyology.Operations.Is_Terminal (Operation)
       and then not Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool,
       Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Wait on the same owner-driven storage-backed Get state machine. The
   --  caller supplies the sole scratch token and whole-operation timeout; the
   --  established null cancellation default matches the other DB waits and
   --  selects no retry or background execution policy.
   --  @param Item Open database that owns the fixed snapshot state
   --  @param Txn Active transaction borrowed exclusively during this call
   --  @param Family Valid family handle
   --  @param Item_Key Exact arbitrary-byte key
   --  @param Payload_Buffer Acquired caller-owned storage scratch token
   --  @param Timeout One monotonic budget for the complete read
   --  @param Token Optional cooperative cancellation token
   --  @param Data Owned value bytes, empty on every non-Success outcome
   --  @param Result Success, Not_Found, or exact typed failure
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
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer),
       Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Validate and observe one canonical half-open scan predicate without
   --  reading or returning rows. A false endpoint flag means that endpoint is
   --  unbounded and its byte argument is ignored. When both endpoints are
   --  present, Lower must compare strictly before Upper; an empty or reversed
   --  interval returns Invalid_State. Snapshot transactions validate only.
   --  Serializable transactions lazily retain normalized same-family
   --  components: overlapping or endpoint-touching predicates become their
   --  exact union, while cross-family predicates remain distinct. The
   --  database's persisted range count bounds components and the selected
   --  family's key limit bounds endpoints. Capacity_Exceeded means the exact
   --  prior set remains retained. Present endpoint bytes are borrowed only for
   --  this call and copied before Success. Scan uses this same endpoint rule.
   --  @param Item Open database that owns committed conflict history
   --  @param Txn Active transaction whose isolation and observations are used
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Has_Lower True when Lower is the inclusive endpoint
   --  @param Lower Inclusive endpoint bytes, ignored when Has_Lower is false
   --  @param Has_Upper True when Upper is the exclusive endpoint
   --  @param Upper Exclusive endpoint bytes, ignored when Has_Upper is false
   --  @param Result Success or the exact validation, capacity, or lifecycle outcome
   procedure Observe_Range
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array;
      Result    : out Outcome_Code);

   --  Materialize every live row in one canonical half-open family interval
   --  at Txn's fixed snapshot, ordered by unsigned-byte lexicographic key.
   --  Endpoint flags and validation match Observe_Range. Exact row count and
   --  key-plus-value bytes are bounded by the database's persisted live-state
   --  limits; individual extents remain bounded by the selected family. There
   --  is no page size, byte default, timeout, storage I/O, or helper task.
   --  The implementation captures and completes the same owned physical
   --  cursor used by Next_Scan_Page; no cursor state escapes this call.
   --  Rows is replaced atomically only on Success and remains unchanged on
   --  every failure. A Serializable success merges the exact predicate into
   --  its normalized retained components only after complete materialization;
   --  failure publishes neither rows nor a predicate. Endpoint bytes are
   --  borrowed only for this call.
   --  @param Item Open database that owns fixed-snapshot state
   --  @param Txn Active transaction whose snapshot and own mutations are read
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Has_Lower True when Lower is the inclusive endpoint
   --  @param Lower Inclusive endpoint bytes, ignored when Has_Lower is false
   --  @param Has_Upper True when Upper is the exclusive endpoint
   --  @param Upper Exclusive endpoint bytes, ignored when Has_Upper is false
   --  @param Rows Controlled owned result replaced only on Success
   --  @param Result Success or the exact validation, capacity, conflict, or lifecycle outcome
   procedure Scan
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array;
      Rows      : in out Scan_Result;
      Result    : out Outcome_Code);

   --  Start or restart one fixed-snapshot paged scan. Endpoint rules and
   --  family validation are identical to Scan. Before Success the cursor owns
   --  exact ordered descriptors, retained immutable image leases, copied own
   --  mutations, and present endpoints; failure preserves the prior Cursor
   --  exactly. The cursor binds Txn's fixed committed snapshot and current
   --  own-mutation version. A later successful Put/Delete invalidates
   --  subsequent page calls instead of mixing transaction views. This call
   --  materializes no result rows and records no Serializable predicate.
   --  @param Item Open database that owns fixed-snapshot state
   --  @param Txn Active transaction whose snapshot and own writes are fixed
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Has_Lower True when Lower is the inclusive endpoint
   --  @param Lower Inclusive endpoint bytes, ignored when Has_Lower is false
   --  @param Has_Upper True when Upper is the exclusive endpoint
   --  @param Upper Exclusive endpoint bytes, ignored when Has_Upper is false
   --  @param Cursor Owned page position replaced only on Success
   --  @param Result Success or the exact validation, capacity, or lifecycle outcome
   procedure Start_Scan
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
      Has_Lower : Boolean;
      Lower     : Byte_Array;
      Has_Upper : Boolean;
      Upper     : Byte_Array;
      Cursor    : in out Scan_Cursor;
      Result    : out Outcome_Code);

   --  Start or restart authenticated object-storage initialization of one
   --  fixed-snapshot cursor. The exact manifest run slice is traversed one
   --  authenticated next entry at a time under one absolute monotonic
   --  deadline and caller-bounded scratch, then merged with the captured
   --  committed suffix and transaction-local mutations.
   --  Payload_Buffer moves into Operation only after validation and operation
   --  admission. Typed Finish is the sole restoration and cursor-publication
   --  authority. Any failure preserves the caller's prior cursor exactly.
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Has_Lower True when Lower is the inclusive endpoint
   --  @param Lower Inclusive endpoint bytes, ignored when Has_Lower is false
   --  @param Has_Upper True when Upper is the exclusive endpoint
   --  @param Upper Exclusive endpoint bytes, ignored when Has_Upper is false
   --  @param Payload_Buffer Acquired caller scratch token moved into Operation
   --  @param Timeout Caller-selected duration for the complete initialization
   --  @param Operation Fresh or consumed operation receiving retained ownership
   procedure Start_Scan
     (Family         : Column_Family;
      Has_Lower      : Boolean;
      Lower          : Byte_Array;
      Has_Upper      : Boolean;
      Upper          : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Scan_Operation)
   with
     Pre  =>
       Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
     Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Start or restart one authenticated storage-backed cursor
   --  initialization. Unlike Start_Scan, this form does not traverse every
   --  selected immutable run before publication. It retains exact run
   --  descriptors, committed in-memory sources, transaction-local bytes,
   --  endpoints, and identity/version authority. Later object reads occur
   --  only through the composable Next_Scan_Page overload. No result row or
   --  Serializable predicate is published here.
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Has_Lower True when Lower is the inclusive endpoint
   --  @param Lower Inclusive endpoint bytes, ignored when Has_Lower is false
   --  @param Has_Upper True when Upper is the exclusive endpoint
   --  @param Upper Exclusive endpoint bytes, ignored when Has_Upper is false
   --  @param Payload_Buffer Acquired caller scratch token moved into Operation
   --  @param Timeout Caller-selected duration for initialization
   --  @param Operation Fresh or consumed operation receiving retained ownership
   procedure Start_Storage_Backed_Scan
     (Family         : Column_Family;
      Has_Lower      : Boolean;
      Lower          : Byte_Array;
      Has_Upper      : Boolean;
      Upper          : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Scan_Operation)
   with
     Pre  =>
       Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
     Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Blocking wait over the same storage-backed initialization state
   --  machine. The caller selects the sole scratch token and timeout; the
   --  optional null cancellation token is the established Flyology
   --  convention and introduces no retry or hidden deadline.
   --  @param Item Open client-bound database owning the fixed snapshot
   --  @param Txn Active transaction retained for the duration of the call
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Has_Lower True when Lower is the inclusive endpoint
   --  @param Lower Inclusive endpoint bytes, ignored when Has_Lower is false
   --  @param Has_Upper True when Upper is the exclusive endpoint
   --  @param Upper Exclusive endpoint bytes, ignored when Has_Upper is false
   --  @param Payload_Buffer Acquired caller scratch token restored before return
   --  @param Timeout Caller-selected duration for initialization
   --  @param Token Optional caller-owned cancellation token
   --  @param Cursor Existing cursor replaced only on Success
   --  @param Result Success or exact validation, capacity, storage, or lifecycle outcome
   procedure Start_Storage_Backed_Scan
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
   with
     Pre  => Flyology.Buffers.Has_Buffer (Payload_Buffer),
     Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Consume a terminal authenticated scan initialization. On Success,
   --  Cursor atomically receives the new fixed-snapshot position; otherwise
   --  it is unchanged. Payload_Buffer may be any vacant handle from the same
   --  pool and receives the exact token moved by Start_Scan.
   --  @param Operation Terminal scan initialization to consume
   --  @param Cursor Existing cursor replaced only on Success
   --  @param Result Success or exact validation, capacity, storage, or lifecycle outcome
   --  @param Payload_Buffer Vacant same-pool handle receiving the exact moved token
   procedure Finish
     (Operation      : in out Scan_Operation;
      Cursor         : in out Scan_Cursor;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
   with
     Pre  =>
       Flyology.Operations.Is_Terminal (Operation)
       and then not Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool,
     Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Start or restart one storage-backed page. Cursor is borrowed only for
   --  validation and exact candidate cloning during this call; the caller
   --  must not use or finalize it until typed Finish. One absolute deadline
   --  covers every generation-bound next-entry child. Maximum_Rows and
   --  Maximum_Bytes are explicit caller backpressure and have no defaults.
   --  The operation retains at most one authoritative and one candidate head
   --  per immutable run while active. Mutation replay, prefetch, caching, and
   --  helper tasks are absent.
   --  @param Cursor Active storage-backed cursor borrowed through Finish
   --  @param Maximum_Rows Caller-selected maximum rows for this page
   --  @param Maximum_Bytes Caller-selected maximum key-plus-value bytes
   --  @param Payload_Buffer Acquired caller scratch token moved into Operation
   --  @param Timeout Caller-selected duration for the complete page
   --  @param Operation Fresh or consumed operation receiving retained ownership
   procedure Next_Scan_Page
     (Cursor         : in out Scan_Cursor;
      Maximum_Rows   : Interfaces.Unsigned_32;
      Maximum_Bytes  : Interfaces.Unsigned_64;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Scan_Operation)
   with
     Pre  =>
       Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
     Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Consume one terminal storage-backed page. Success atomically replaces
   --  the exact cursor revision and Rows, and returns the terminal completion
   --  flag. Failure preserves both. Payload_Buffer may be any vacant handle
   --  from the original pool and receives the exact moved token.
   --  @param Operation Terminal storage-backed page operation
   --  @param Cursor Exact cursor passed to Next_Scan_Page
   --  @param Rows Existing result replaced only on Success
   --  @param Done True only when this successful page physically exhausts all sources
   --  @param Result Success or exact validation, capacity, storage, or lifecycle outcome
   --  @param Payload_Buffer Vacant same-pool handle receiving the exact moved token
   procedure Finish
     (Operation      : in out Scan_Operation;
      Cursor         : in out Scan_Cursor;
      Rows           : in out Scan_Result;
      Done           : out Boolean;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
   with
     Pre  =>
       Flyology.Operations.Is_Terminal (Operation)
       and then not Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool,
     Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Blocking wait over the same authenticated scan-initialization state
   --  machine. The optional null cancellation token follows the established
   --  Flyology operation convention and selects no timeout or retry policy.
   --  @param Item Open client-bound database owning the fixed snapshot
   --  @param Txn Active transaction retained for the duration of the call
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Has_Lower True when Lower is the inclusive endpoint
   --  @param Lower Inclusive endpoint bytes, ignored when Has_Lower is false
   --  @param Has_Upper True when Upper is the exclusive endpoint
   --  @param Upper Exclusive endpoint bytes, ignored when Has_Upper is false
   --  @param Payload_Buffer Acquired caller scratch token restored before return
   --  @param Timeout Caller-selected duration for the complete initialization
   --  @param Token Optional caller-owned cancellation token
   --  @param Cursor Existing cursor replaced only on Success
   --  @param Result Success or exact validation, capacity, storage, or lifecycle outcome
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
   with
     Pre  => Flyology.Buffers.Has_Buffer (Payload_Buffer),
     Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Materialize a complete authenticated fixed-snapshot interval by
   --  waiting on the storage-backed Scan_Operation initialization, then
   --  requesting one complete page from that cursor's established physical
   --  merge engine. One absolute timeout covers both phases. Persisted
   --  live-row and live-byte limits are the complete-page budgets; no page
   --  default, second storage path, helper task, retry, or additional capacity
   --  is introduced. Rows is replaced only on Success, and Payload_Buffer is
   --  always restored.
   --  @param Item Open client-bound database owning the fixed snapshot
   --  @param Txn Active transaction retained for the duration of the call
   --  @param Family Valid handle selecting persisted family limits and identity
   --  @param Has_Lower True when Lower is the inclusive endpoint
   --  @param Lower Inclusive endpoint bytes, ignored when Has_Lower is false
   --  @param Has_Upper True when Upper is the exclusive endpoint
   --  @param Upper Exclusive endpoint bytes, ignored when Has_Upper is false
   --  @param Payload_Buffer Acquired caller scratch token restored before return
   --  @param Timeout Caller-selected duration for the complete authenticated scan
   --  @param Token Optional caller-owned cancellation token
   --  @param Rows Controlled owned result replaced only on Success
   --  @param Result Success or the exact validation, capacity, storage, or lifecycle outcome
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
   with
     Pre  => Flyology.Buffers.Has_Buffer (Payload_Buffer),
     Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Materialize the maximal next contiguous page that fits both explicit
   --  caller budgets. Maximum_Rows and Maximum_Bytes have no defaults and are
   --  per-call backpressure, not persisted or library-selected policy. When a
   --  following row does not fit, the maximal nonempty prefix succeeds and
   --  remains resumable. When the first remaining indivisible row cannot fit
   --  an empty page, Capacity_Exceeded preserves Cursor and Rows exactly.
   --  Allocation and validation failure have the same atomic boundary. A
   --  valid empty view succeeds with an empty Rows and Done true,
   --  including for zero budgets. The final nonempty page also sets Done true;
   --  a later call returns Invalid_State. Done is false on every failure.
   --  Serializable mode records the complete original range atomically with
   --  the first successful page and never consumes another range component.
   --  @param Item Exact open database bound by Cursor
   --  @param Txn Exact active transaction and own-mutation version bound by Cursor
   --  @param Cursor Owned fixed-snapshot page position advanced only on Success
   --  @param Maximum_Rows Caller-selected maximum rows for this page
   --  @param Maximum_Bytes Caller-selected maximum key-plus-value bytes for this page
   --  @param Rows Controlled owned page replaced only on Success
   --  @param Done True only when this successful page completes the range
   --  @param Result Success or the exact validation, capacity, conflict, or lifecycle outcome
   procedure Next_Scan_Page
     (Item          : in out Database;
      Txn           : in out Transaction;
      Cursor        : in out Scan_Cursor;
      Maximum_Rows  : Interfaces.Unsigned_32;
      Maximum_Bytes : Interfaces.Unsigned_64;
      Rows          : in out Scan_Result;
      Done          : out Boolean;
      Result        : out Outcome_Code);

   --  Blocking wait over the same storage-backed page state machine. All
   --  budgets and timeout remain caller-selected. The optional null token is
   --  the established convention for no cancellation source, not a retry or
   --  deadline policy.
   --  @param Item Exact open database bound by Cursor
   --  @param Txn Exact active transaction and own-mutation version bound by Cursor
   --  @param Cursor Active storage-backed cursor advanced only on Success
   --  @param Maximum_Rows Caller-selected maximum rows for this page
   --  @param Maximum_Bytes Caller-selected maximum key-plus-value bytes
   --  @param Payload_Buffer Acquired caller scratch token restored before return
   --  @param Timeout Caller-selected duration for the complete page
   --  @param Token Optional caller-owned cancellation token
   --  @param Rows Existing result replaced only on Success
   --  @param Done True only when this successful page physically exhausts all sources
   --  @param Result Success or exact validation, capacity, storage, or lifecycle outcome
   procedure Next_Scan_Page
     (Item           : in out Database;
      Txn            : aliased in out Transaction;
      Cursor         : in out Scan_Cursor;
      Maximum_Rows   : Interfaces.Unsigned_32;
      Maximum_Bytes  : Interfaces.Unsigned_64;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Token          : access Flyology.Cancellation.Token := null;
      Rows           : in out Scan_Result;
      Done           : out Boolean;
      Result         : out Outcome_Code)
   with
     Pre  => Flyology.Buffers.Has_Buffer (Payload_Buffer),
     Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Number of live rows retained by Item, including zero for a fresh or
   --  successfully empty result.
   --  @param Item Controlled scan result
   --  @return Exact retained row count
   function Scan_Row_Count (Item : Scan_Result) return Natural;

   --  Copy one retained row into caller-owned bytes. Position is one-based in
   --  canonical key order. Invalid_State leaves both outputs empty when the
   --  position is outside the current result; allocation failure reports
   --  Capacity_Exceeded and likewise publishes no partial row.
   --  @param Item Controlled scan result whose bytes remain owned by Item
   --  @param Position One-based row position
   --  @param Item_Key Owned exact key bytes, empty on failure
   --  @param Data Owned exact value bytes, empty on failure
   --  @param Result Success, Invalid_State, or Capacity_Exceeded
   procedure Read_Scan_Row
     (Item     : Scan_Result;
      Position : Positive;
      Item_Key : out Flyology.Bytes.Unbounded_Bytes;
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
   --  Commit returns Conflict when a written key or retained Serializable
   --  point/range predicate intersects a post-Begin write, or when the
   --  captured sequence predates retained exact history.
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
   --  Group members validate writes and retained Serializable predicates
   --  independently against external committed history.
   --  The explicit group is one atomic co-commit unit, so overlapping member
   --  writes remain ordered by their existing deterministic member sequence.
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

   --  Start checkpoint publication in an established operation. All
   --  initiating owner and request-shape validation, pool compatibility,
   --  completion-slot reservation, and lifecycle admission precede ownership
   --  transfer. Successful Start
   --  moves Payload_Buffer's exact token into Operation and leaves the caller
   --  handle vacant until typed Finish. Insufficient caller-selected block
   --  capacity is a definite prepublication Capacity_Exceeded result. No
   --  helper task, hidden retry, or second deadline is introduced.
   --  @param Operation Fresh or consumed client-bound Flush operation
   --  @param Runs Exact affected-family/run identity map copied before return
   --  @param Manifest_ID Stable immutable checkpoint manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Payload_Buffer Acquired caller-owned scratch token moved until Finish
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Storage binding
   procedure Start_Flush
     (Operation      : in out Flush_Operation;
      Runs           : Checkpoint_Run_Identity_Array;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Start an exact complete-view compaction in an established operation.
   --  Runs maps every nonempty family to a caller-selected fresh output
   --  identity; an all-empty replacement accepts an empty map. A legacy full
   --  family map remains accepted and its empty-family entries are ignored.
   --  Compaction copies Runs and
   --  retains no borrow of that map after return. It removes no stored
   --  predecessor and selects no trigger, level, fanout, schedule, retry, or
   --  garbage-collection policy. Its normal operation-owner borrows and the
   --  moved Payload_Buffer remain retained until Finish or finalization drain.
   --  Ownership, deadline, certainty, and exact same-identity reconciliation
   --  are identical to Start_Flush.
   --  @param Operation Fresh or consumed client-bound checkpoint operation
   --  @param Runs Exact nonempty-family/output-run identity map copied before return
   --  @param Manifest_ID Stable immutable successor-manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Payload_Buffer Acquired caller-owned scratch token moved until Finish
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Storage binding
   procedure Start_Compaction
     (Operation      : in out Flush_Operation;
      Runs           : Checkpoint_Run_Identity_Array;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Start an exact caller-selected adjacent-run compaction. Older_Run_ID
   --  and Newer_Run_ID must name adjacent current descriptors in one family;
   --  Output_Run_ID, Manifest_ID, and Transition_ID are fresh caller-stable
   --  identities. Every version and tombstone is retained, including through
   --  a later committed suffix. The operation selects no pair, trigger,
   --  level, schedule, retry, retention horizon, or deletion policy. Runs are
   --  authenticated and copied into operation-owned state; no caller ID
   --  borrow survives return. Normal operation-owner borrows and the moved
   --  Payload_Buffer remain until Finish or finalization drain.
   --  @param Operation Fresh or consumed client-bound checkpoint operation
   --  @param Older_Run_ID Exact older adjacent current-run identity
   --  @param Newer_Run_ID Exact newer adjacent current-run identity
   --  @param Output_Run_ID Fresh immutable merged-run identity
   --  @param Manifest_ID Stable immutable successor-manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Payload_Buffer Acquired caller-owned scratch token moved until Finish
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Storage binding
   procedure Start_Compaction
     (Operation      : in out Flush_Operation;
      Older_Run_ID   : Identifier;
      Newer_Run_ID   : Identifier;
      Output_Run_ID  : Identifier;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Start an exact caller-selected three-run compaction. First_Run_ID,
   --  Middle_Run_ID, and Last_Run_ID must name three consecutive current
   --  descriptors in one family. Exactly three is the already-qualified
   --  algorithm shape, not an automatic fanout or policy default. The merge
   --  retains every version and tombstone, preserves surrounding runs and any
   --  later committed suffix, and selects no trigger, level, schedule, retry,
   --  retention horizon, pruning, or deletion policy. Selected identities are
   --  copied into operation-owned state; no caller ID borrow survives return.
   --  @param Operation Fresh or consumed client-bound checkpoint operation
   --  @param First_Run_ID Exact first consecutive current-run identity
   --  @param Middle_Run_ID Exact middle consecutive current-run identity
   --  @param Last_Run_ID Exact last consecutive current-run identity
   --  @param Output_Run_ID Fresh immutable merged-run identity
   --  @param Manifest_ID Stable immutable successor-manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Payload_Buffer Acquired caller-owned scratch token moved until Finish
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Storage binding
   procedure Start_Compaction
     (Operation      : in out Flush_Operation;
      First_Run_ID   : Identifier;
      Middle_Run_ID  : Identifier;
      Last_Run_ID    : Identifier;
      Output_Run_ID  : Identifier;
      Manifest_ID    : Identifier;
      Transition_ID  : Identifier;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Consume a terminal composable Flush and restore its exact input token.
   --  Payload_Buffer may be any vacant handle from the original pool; no
   --  pointer to the initiating handle is retained. The restored token keeps
   --  its tag and metadata and contains operation scratch bytes. Result and
   --  Receipt are the same certainty projection as synchronous Flush. An
   --  unexpected retained provider exception is re-raised only after token
   --  restoration and operation consumption.
   --  @param Operation Terminal composable Flush operation
   --  @param Receipt Self-contained operation identity and certainty record
   --  @param Result Terminal or presently unknown operation outcome
   --  @param Payload_Buffer Vacant same-pool destination for the exact token
   --  @exception Program_Error Operation contains a family-append result instead
   procedure Finish
     (Operation      : in out Flush_Operation;
      Receipt        : out Flush_Receipt;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer)
     with Pre => Flyology.Operations.Is_Terminal (Operation)
       and then not Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool,
       Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Publish an immutable checkpoint at the current committed boundary. The
   --  first call writes complete nonempty-family runs; each later call appends
   --  one suffix-delta run for every affected family and retains prior current
   --  runs. Runs must map every family that has a complete or suffix snapshot
   --  to one caller-stable identity. A legacy full family map remains accepted;
   --  empty or unchanged entries consume no new run object or identity. Every
   --  identity that names an attempted object or HEAD becomes unavailable for
   --  reuse once its publication begins. One absolute monotonic deadline
   --  covers planning, publication, reconciliation, and local activation.
   --  Outcome_Unknown must be resolved and never replayed as a new operation.
   --  @param Item Open database whose committed prefix is checkpointed
   --  @param Runs Exact caller-owned affected-family/run map borrowed for this call
   --  @param Manifest_ID Stable immutable checkpoint manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Receipt Self-contained operation identity and certainty record
   --  @param Result Terminal or presently unknown operation outcome
   procedure Flush
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token := null;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code);

   --  Publish an exact complete live-state replacement. The caller supplies
   --  one fresh output-run identity for every nonempty family; empty families
   --  consume no output object or identity, and an all-empty view accepts an
   --  empty map. A legacy full family map remains accepted. The operation preserves
   --  any later committed suffix and every never-reuse ledger entry, confirms
   --  complete immutable outputs before one conditional HEAD transition, and
   --  retains superseded objects. It chooses no automatic compaction or
   --  deletion policy. Client-backed execution waits on Start_Compaction;
   --  memory/files use the equivalent backend-neutral publisher.
   --  @param Item Open database whose complete live view is compacted
   --  @param Runs Exact nonempty-family/output-run identity map
   --  @param Manifest_ID Stable immutable successor-manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @param Token Cooperative cancellation token, or null for no token
   --  @param Receipt Self-contained publication and reconciliation authority
   --  @param Result Terminal or presently unknown operation outcome
   procedure Compact
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Timeout       : Duration;
      Token         : access Flyology.Cancellation.Token;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code);

   --  Replace two exact adjacent current runs with one fresh immutable run.
   --  The caller supplies every selected and publication identity. The merge
   --  retains every version and tombstone, preserves retained surrounding
   --  runs and any later committed suffix, confirms the output and successor
   --  before conditional HEAD, and retains predecessor objects. It selects no
   --  automatic trigger, level, schedule, retry, pruning, or deletion policy.
   --  Client-backed execution waits on the adjacent Start_Compaction overload;
   --  memory/files use the equivalent backend-neutral publisher.
   --  @param Item Open database whose exact adjacent runs are compacted
   --  @param Older_Run_ID Exact older adjacent current-run identity
   --  @param Newer_Run_ID Exact newer adjacent current-run identity
   --  @param Output_Run_ID Fresh immutable merged-run identity
   --  @param Manifest_ID Stable immutable successor-manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @param Token Cooperative cancellation token, or null for no token
   --  @param Receipt Self-contained publication and reconciliation authority
   --  @param Result Terminal or presently unknown operation outcome
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
      Result        : out Outcome_Code);

   --  Replace three exact consecutive current runs with one fresh immutable
   --  run. Exactly three is the qualified algorithm shape exposed to an
   --  explicit caller; it is not a fanout, trigger, or maintenance default.
   --  Every selected and publication identity is caller-supplied. The merge
   --  retains every version and tombstone, surrounding runs, any later suffix,
   --  and every predecessor object. Client-backed execution waits on the
   --  matching Start_Compaction overload; memory/files use the equivalent
   --  backend-neutral publisher.
   --  @param Item Open database whose exact consecutive runs are compacted
   --  @param First_Run_ID Exact first consecutive current-run identity
   --  @param Middle_Run_ID Exact middle consecutive current-run identity
   --  @param Last_Run_ID Exact last consecutive current-run identity
   --  @param Output_Run_ID Fresh immutable merged-run identity
   --  @param Manifest_ID Stable immutable successor-manifest identity
   --  @param Transition_ID Stable attempted HEAD transition identity
   --  @param Timeout Whole-operation monotonic timeout budget
   --  @param Token Cooperative cancellation token, or null for no token
   --  @param Receipt Self-contained publication and reconciliation authority
   --  @param Result Terminal or presently unknown operation outcome
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
      Result        : out Outcome_Code);

   --  Continue exact immutable-object reconciliation or reconcile the
   --  attempted HEAD retained by Receipt. Resolve_Flush never changes an
   --  identity and never republishes application work under a new identity.
   --  @param Item Same open database retained by the original Flush
   --  @param Receipt Original nonterminal Flush receipt, updated in place
   --  @param Timeout Whole-resolution monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Result Terminal or still-unknown resolution outcome
   procedure Resolve_Flush
     (Item    : in out Database;
      Receipt : in out Flush_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code);

   --  Start exact receipt-driven Flush reconciliation in an established
   --  provider-bound operation. Receipt and Payload_Buffer move into
   --  Operation and remain owned there until typed Finish. Objects_Unknown
   --  reconstructs and authenticates the original immutable bytes before
   --  continuing their same-identity publication; HEAD uncertainty performs
   --  read-only recovery and local activation. No identity, application work,
   --  helper task, retry policy, or second deadline is introduced.
   --  @param Receipt Original nonterminal Flush receipt moved until Finish
   --  @param Payload_Buffer Acquired caller-owned scratch token moved until Finish
   --  @param Timeout Whole-resolution monotonic timeout budget
   --  @param Operation Fresh or consumed client-bound Flush operation
   --  @exception Capacity_Error Completion set has no reusable parent slot
   --  @exception Program_Error Operation owners do not match Receipt or buffer ownership
   procedure Resolve_Flush
     (Receipt        : in out Flush_Receipt;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Flush_Operation)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer)
       and then Payload_Buffer.Owner = Operation.Payload_Pool
       and then not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation),
       Post => not Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Blocking wait over the same provider-bound Resolve_Flush state machine.
   --  The exact receipt and caller scratch token are restored before return.
   --  Backend-neutral storage retains the established direct resolver until
   --  those providers expose caller-driven children.
   --  @param Item Same open database retained by the original Flush
   --  @param Storage Exact storage binding owned by Item
   --  @param Receipt Original nonterminal Flush receipt, updated in place
   --  @param Payload_Buffer Acquired caller scratch token restored before return
   --  @param Timeout Whole-resolution monotonic timeout budget
   --  @param Token Optional cooperative cancellation token
   --  @param Result Terminal or still-unknown resolution outcome
   procedure Resolve_Flush
     (Item           : in out Database;
      Storage        : not null access Storage_Context;
      Receipt        : in out Flush_Receipt;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Token          : access Flyology.Cancellation.Token := null;
      Result         : out Outcome_Code)
     with Pre => Flyology.Buffers.Has_Buffer (Payload_Buffer),
       Post => Flyology.Buffers.Has_Buffer (Payload_Buffer);

   --  Outcome most recently assigned to Receipt.
   --  @param Item Flush receipt to inspect
   --  @return Most recent certainty-preserving outcome
   function Flush_Receipt_Outcome (Item : Flush_Receipt) return Outcome_Code;

   --  Stable immutable checkpoint manifest identity carried by Receipt.
   --  @param Item Flush receipt to inspect
   --  @return Exact manifest identity or zero before admission
   function Flush_Receipt_Manifest_ID (Item : Flush_Receipt) return Identifier;

   --  Attempted HEAD transition identity, or zero before storage admission.
   --  @param Item Flush receipt to inspect
   --  @return Exact attempted transition identity or zero
   function Flush_Receipt_Transition_ID (Item : Flush_Receipt) return Identifier;

   --  Exact committed sequence represented by the checkpoint.
   --  @param Item Flush receipt to inspect
   --  @return Exact replay boundary or zero before admission
   function Flush_Receipt_Replay_Boundary (Item : Flush_Receipt) return Sequence_Number;

   --  Number of exact family/run mappings retained by Receipt.
   --  @param Item Flush receipt to inspect
   --  @return Retained mapping count or zero before admission
   function Flush_Receipt_Run_Total (Item : Flush_Receipt) return Natural;

   --  Return retained family/run mapping Index. Constraint_Error is raised
   --  when Index is outside 1 .. Flush_Receipt_Run_Total (Item).
   --  @param Item Flush receipt to inspect
   --  @param Index One-based retained mapping index
   --  @return Exact caller-supplied family/run mapping
   --  @exception Constraint_Error Index is outside the retained map
   function Flush_Receipt_Run (Item : Flush_Receipt; Index : Positive) return Checkpoint_Run_Identity;

   --  Return the highest sequence confirmed visible while Item is safely open.
   procedure Highest_Visible (Item : in out Database; Value : out Sequence_Number; Result : out Outcome_Code);

   --  Inspect the exact quiescent writer view and report the next L0 action
   --  implied solely by persisted per-family and database-wide run ceilings.
   --  The call serializes with commit/checkpoint lifecycle work but performs no
   --  storage I/O, reserves no publication identity, and starts no background
   --  task. A later commit can change the answer; Flush and Compact therefore
   --  revalidate every bound and publication precondition. On Capacity_Exceeded
   --  neither additive Flush nor complete compaction can fit; Action is only
   --  meaningful when Result is Success.
   --  @param Item Open writer database whose current L0 requirement is inspected
   --  @param Action Exact current action selected from persisted run authorities
   --  @param Result Success or a definite local state/capacity classification
   procedure Required_L0_Checkpoint_Action
     (Item   : in out Database;
      Action : out L0_Checkpoint_Action;
      Result : out Outcome_Code);

   --  Atomically replace Requirement with the action and exact affected
   --  family IDs from one quiescent writer observation. Additive_Flush_Required
   --  carries every suffix-changed family; Complete_Compaction_Required carries
   --  every complete-view nonempty family; No_L0_Checkpoint_Work carries none.
   --  Failure preserves the prior Requirement. The result reserves no identity
   --  and a later commit may invalidate it before publication admission.
   --  @param Item Open writer database whose current L0 requirement is inspected
   --  @param Requirement Owned observation replaced only after complete success
   --  @param Result Success or a definite local state/capacity classification
   procedure Observe_L0_Checkpoint_Requirement
     (Item        : in out Database;
      Requirement : in out L0_Checkpoint_Requirement;
      Result      : out Outcome_Code);

   --  @param Item Successfully observed checkpoint requirement
   --  @return Action captured by the observation
   function Checkpoint_Requirement_Action
     (Item : L0_Checkpoint_Requirement) return L0_Checkpoint_Action;

   --  @param Item Successfully observed checkpoint requirement
   --  @return Number of exact affected families carried by Item
   function Checkpoint_Requirement_Family_Total (Item : L0_Checkpoint_Requirement) return Natural;

   --  Return one exact affected family in stable registry order.
   --  @param Item Successfully observed checkpoint requirement
   --  @param Index One-based affected-family position
   --  @return Exact stable column-family ID
   --  @exception Constraint_Error Index is outside the retained family set
   function Checkpoint_Requirement_Family
     (Item : L0_Checkpoint_Requirement; Index : Positive) return Column_Family_ID;

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

   subtype Generation_Length is Natural range 0 .. Maximum_Generation_Bytes;
   --  Opaque provider-generation storage uses the adjacent compatibility cap;
   --  Length is the exact authenticated byte count and Data is never parsed as
   --  a checksum or persisted DB field.
   type Generation_Value is record
      Length : Generation_Length := 0;
      Data   : String (1 .. Maximum_Generation_Bytes) := [others => Character'Val (0)];
   end record;

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
      Point_Read_Node_Allocation,
      Point_Read_Key_Allocation,
      --  Test-only failure positions distinguish unlinked range-node and
      --  endpoint-copy rollback. Their positions are never persisted or
      --  exposed; adding them changes only deterministic fault coverage.
      Scan_Range_Node_Allocation,
      Scan_Range_Lower_Allocation,
      Scan_Range_Upper_Allocation,
      --  Scan materialization faults distinguish immutable-source capture,
      --  result-state/descriptor ownership, and exact payload reservation.
      --  They are test-only runtime states and never persisted or exposed.
      Scan_Source_Allocation,
      Scan_Result_State_Allocation,
      Scan_Result_Rows_Allocation,
      Scan_Result_Payload_Allocation,
      --  Cursor faults distinguish the owned state and exact endpoint/last-key
      --  copies plus the private retained source/entry arrays. They are
      --  test-only positions, not product allocation policy or stable ABI.
      Scan_Cursor_State_Allocation,
      Scan_Cursor_Lower_Allocation,
      Scan_Cursor_Upper_Allocation,
      Scan_Cursor_Last_Key_Allocation,
      Scan_Cursor_Source_Allocation,
      Scan_Cursor_Entry_Allocation,
      Scan_Cursor_Owned_Bytes_Allocation,
      Batch_Descriptor_Allocation,
      Storage_Sink_Allocation,
      Recovery_History_Allocation,
      --  Test-only owner-state failure before any recovery lifecycle
      --  admission is transferred. This is neither persisted nor policy.
      Recovery_Driver_State_Allocation,
      Engine_State_Allocation,
      Identity_Table_Allocation,
      Projection_Scratch_Allocation,
      --  Test-only failure before publishing an exact owned checkpoint-family
      --  projection. This position is neither persisted nor product policy.
      Checkpoint_Requirement_Family_Allocation,
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
      Recovery_Checkpoint_Image_Allocation,
      Recovery_Snapshot_Base_Allocation,
      Flush_Activation_State_Allocation,
      --  Test-only positions distinguish the public Get owner state, copied
      --  immutable-run descriptors, and private selector child. They are not
      --  persisted, public allocation policy, or stable ABI.
      Get_Operation_State_Allocation,
      Get_Run_Descriptor_Allocation,
      Get_Child_Operation_Allocation,
      --  Test-only positions distinguish authenticated scan owner state, the
      --  exact run array, lazily selected entry nodes, and its private
      --  next-entry reader child. They
      --  are not persisted, public allocation policy, or stable ABI.
      Scan_Operation_State_Allocation,
      Scan_Run_Array_Allocation,
      Scan_Run_Entry_Allocation,
      Scan_Child_Operation_Allocation);
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

   type Owned_Point_Read;
   type Owned_Point_Read_Access is access Owned_Point_Read;
   --  One lazily allocated exact serializable point predicate. Family and key
   --  are copied from a validated Get; vacant initializers have no persisted or
   --  application-policy meaning. Next is transaction-owned linkage only.
   type Owned_Point_Read is record
      Family     : Column_Family_ID := Column_Family_ID'First;
      Key_Length : Natural := 0;
      Key        : Flyology.Bytes.Unbounded_Bytes;
      Next       : Owned_Point_Read_Access := null;
   end record;

   type Owned_Scan_Range;
   type Owned_Scan_Range_Access is access Owned_Scan_Range;
   --  One lazily allocated normalized serializable half-open component.
   --  Same-family overlap and endpoint contact are stored as their exact
   --  union; cross-family components remain distinct. Present endpoints are
   --  copied only after family-limit, ordering, and normalized-count
   --  validation; absent endpoint storage is vacant and ignored. The flags
   --  and linkage are runtime ownership state, never persisted or encoded.
   type Owned_Scan_Range is record
      Family       : Column_Family_ID := Column_Family_ID'First;
      Has_Lower    : Boolean := False;
      Lower_Length : Natural := 0;
      Lower        : Flyology.Bytes.Unbounded_Bytes;
      Has_Upper    : Boolean := False;
      Upper_Length : Natural := 0;
      Upper        : Flyology.Bytes.Unbounded_Bytes;
      Next         : Owned_Scan_Range_Access := null;
   end record;

   type Transaction_Arena is limited record
      Mutations        : Owned_Mutation_Array_Access := null;
      Count            : Natural := 0;
      Bytes_Used       : Interfaces.Unsigned_64 := 0;
      Point_Reads      : Owned_Point_Read_Access := null;
      Point_Read_Count : Interfaces.Unsigned_32 := 0;
      Scan_Ranges      : Owned_Scan_Range_Access := null;
      Scan_Range_Count : Interfaces.Unsigned_32 := 0;
      --  Runtime-only fixed-view witness. It increments after every successful
      --  Put/Delete, including in-place replacement, and is never persisted.
      --  Unsigned_64 exhaustion is representational failure classified before
      --  mutation publication; it is not a database limit or normal-use budget.
      Mutation_Version : Interfaces.Unsigned_64 := 0;
   end record;
   type Transaction_Arena_Access is access Transaction_Arena;

   type Transaction_Arena_Owner is new Ada.Finalization.Limited_Controlled with record
      Arena : Transaction_Arena_Access := null;
   end record;

   overriding
   procedure Finalize (Item : in out Transaction_Arena_Owner);

   type Scan_Row_Descriptor is record
      Key_Offset   : Natural := 0;
      Key_Length   : Natural := 0;
      Value_Offset : Natural := 0;
      Value_Length : Natural := 0;
   end record;
   type Scan_Row_Descriptor_Array is array (Positive range <>) of Scan_Row_Descriptor;
   type Scan_Row_Descriptor_Array_Access is access Scan_Row_Descriptor_Array;
   type Scan_Result_State is record
      Rows    : Scan_Row_Descriptor_Array_Access := null;
      Count   : Natural := 0;
      Payload : Flyology.Bytes.Unbounded_Bytes;
   end record;
   type Scan_Result_State_Access is access Scan_Result_State;
   --  Scan results own one exact descriptor array and combined key/value byte
   --  image through a single swappable state pointer. Null is the canonical
   --  fresh or successfully empty result; it is not a result-size policy.
   type Scan_Result_Owner is new Ada.Finalization.Limited_Controlled with record
      State : Scan_Result_State_Access := null;
   end record;

   overriding
   procedure Finalize (Item : in out Scan_Result_Owner);

   type Scan_Result is limited record
      Owner : Scan_Result_Owner;
   end record;

   type Scan_Cursor_Byte_Array_Access is access Byte_Array;
   --  One cursor-owned immutable merge entry. Image-backed entries retain an
   --  exact engine image lease; transaction-local entries instead own the
   --  exact key/value payload copied at Start_Scan. Offsets and zero lengths
   --  are derived runtime descriptors and are never persisted.
   type Physical_Scan_Entry is record
      Image        : Shared_Image_Lease;
      Owned        : Flyology.Bytes.Unbounded_Bytes;
      Key_Offset   : Natural := 0;
      Key_Length   : Natural := 0;
      Value_Offset : Natural := 0;
      Value_Length : Natural := 0;
      Operation    : Mutation_Kind := Put_Mutation;
   end record;
   type Physical_Scan_Entry_Array is array (Positive range <>) of Physical_Scan_Entry;
   type Physical_Scan_Entry_Array_Access is access Physical_Scan_Entry_Array;

   --  One storage-backed cursor source retains the exact immutable-run facts
   --  selected by authenticated manifest recovery and, at most, one current
   --  authenticated head. Start_Key is the strict lower bound after a
   --  consumed head. Entries_Read is checked against the persisted run total;
   --  none of these runtime fields are persisted or select page policy.
   type Storage_Scan_Run_State is record
      Run_ID                : Identifier := Zero_Identifier;
      Lowest_Sequence       : Sequence_Number := 0;
      Highest_Sequence      : Sequence_Number := 0;
      Entry_Total           : Interfaces.Unsigned_32 := 0;
      Logical_Payload_Bytes : Interfaces.Unsigned_64 := 0;
      Has_Start             : Boolean := False;
      Start_Key             : Scan_Cursor_Byte_Array_Access := null;
      Has_Head              : Boolean := False;
      Head_Key              : Scan_Cursor_Byte_Array_Access := null;
      Head_Value            : Scan_Cursor_Byte_Array_Access := null;
      Head_Operation        : Mutation_Kind := Put_Mutation;
      Head_Sequence         : Sequence_Number := 0;
      Exhausted             : Boolean := False;
      Entries_Read          : Interfaces.Unsigned_32 := 0;
   end record;
   type Storage_Scan_Run_Array is array (Positive range <>) of Storage_Scan_Run_State;
   type Storage_Scan_Run_Array_Access is access Storage_Scan_Run_Array;

   --  Each source owns one exact contiguous key-ordered entry interval.
   --  Source array order is oldest to newest authority. Zero position is the
   --  runtime exhausted sentinel; it is neither persisted nor product policy.
   type Physical_Scan_Source is record
      First              : Positive := Positive'First;
      Last               : Positive := Positive'First;
      Position           : Natural := 0;
      Candidate_Position : Natural := 0;
      Build_Position     : Natural := 0;
   end record;
   type Physical_Scan_Source_Array is array (Positive range <>) of Physical_Scan_Source;
   type Physical_Scan_Source_Array_Access is access Physical_Scan_Source_Array;

   type Scan_Cursor_State is record
      Active             : Boolean := False;
      Done               : Boolean := False;
      Predicate_Recorded : Boolean := False;
      Storage_Backed     : Boolean := False;
      --  Runtime-only publication generation. Zero is the vacant sentinel;
      --  successful initialization starts at one and every page advances it
      --  with checked arithmetic. It is neither persisted nor caller policy.
      Revision           : Interfaces.Unsigned_64 := 0;
      Database_ID        : Database_Identifier := Zero_Database_ID;
      Incarnation        : Engine_Incarnation := No_Incarnation;
      Transaction_ID     : Transaction_Identifier := Zero_Transaction_ID;
      Snapshot_At        : Sequence_Number := 0;
      Mutation_Version   : Interfaces.Unsigned_64 := 0;
      Family             : Column_Family_Configuration;
      Has_Lower          : Boolean := False;
      Lower              : Scan_Cursor_Byte_Array_Access := null;
      Has_Upper          : Boolean := False;
      Upper              : Scan_Cursor_Byte_Array_Access := null;
      Has_Last           : Boolean := False;
      Last_Key           : Scan_Cursor_Byte_Array_Access := null;
      Storage_Runs       : Storage_Scan_Run_Array_Access := null;
      Entries            : Physical_Scan_Entry_Array_Access := null;
      Sources            : Physical_Scan_Source_Array_Access := null;
      Maximum_Rows       : Interfaces.Unsigned_32 := 0;
      Maximum_Bytes      : Interfaces.Unsigned_64 := 0;
   end record;
   type Scan_Cursor_State_Access is access Scan_Cursor_State;
   --  One swappable pointer gives Start_Scan atomic replacement and makes all
   --  endpoint/position storage cursor-owned. Null is the vacant inactive
   --  state, not a page default or persisted sentinel.
   type Scan_Cursor_Owner is new Ada.Finalization.Limited_Controlled with record
      State : Scan_Cursor_State_Access := null;
   end record;

   overriding
   procedure Finalize (Item : in out Scan_Cursor_Owner);

   type Scan_Cursor is limited record
      Owner : Scan_Cursor_Owner;
   end record;

   type L0_Checkpoint_Family_Array is array (Positive range <>) of Column_Family_ID;
   type L0_Checkpoint_Family_Array_Access is access L0_Checkpoint_Family_Array;
   --  Null is the canonical fresh/no-work family set. Non-null arrays have the
   --  exact observed count; no spare capacity or hidden ceiling is selected.
   type L0_Checkpoint_Requirement_State is new Ada.Finalization.Limited_Controlled with record
      Action   : L0_Checkpoint_Action := No_L0_Checkpoint_Work;
      Families : L0_Checkpoint_Family_Array_Access := null;
   end record;

   overriding
   procedure Finalize (Item : in out L0_Checkpoint_Requirement_State);

   type L0_Checkpoint_Requirement is limited record
      State : L0_Checkpoint_Requirement_State;
   end record;

   type Transaction is limited record
      Active         : Boolean := False;
      Database_ID    : Database_Identifier := Zero_Database_ID;
      Incarnation    : Engine_Incarnation := No_Incarnation;
      Transaction_ID : Transaction_Identifier := Zero_Transaction_ID;
      --  Snapshot sequence is captured from authenticated HEAD at Begin. Zero
      --  is the valid empty-database snapshot and the vacant reset value; it
      --  controls write/write validation but is not a new persisted field.
      Snapshot_At : Sequence_Number := 0;
      --  Snapshot and zero observation capacities are vacant/reset state only.
      --  Begin assigns the caller-selected runtime mode and exact persisted
      --  point/range ceilings; none is a public default or new persisted field.
      Isolation        : Isolation_Level := Snapshot;
      Point_Read_Limit : Interfaces.Unsigned_32 := 0;
      Scan_Range_Limit : Interfaces.Unsigned_32 := 0;
      Owner            : Transaction_Arena_Owner;
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

   --  Runtime-only certainty phases. Enumeration positions are never
   --  persisted. Manifest_Unknown retains exact immutable bytes for same-ID
   --  continuation; Family_Head_Unknown permits read-only HEAD reconciliation;
   --  Family_Head_Confirmed records durable success awaiting local activation.
   type Column_Family_Receipt_Phase is
     (No_Family_Publication,
      Family_Manifest_Unknown,
      Family_Head_Unknown,
      Family_Head_Confirmed,
      Family_Resolved);

   type Column_Family_Receipt is record
      Current_Outcome   : Outcome_Code := Invalid_State;
      Phase             : Column_Family_Receipt_Phase := No_Family_Publication;
      Configuration     : Column_Family_Configuration;
      Database_ID       : Database_Identifier := Zero_Database_ID;
      Incarnation       : Engine_Incarnation := No_Incarnation;
      Manifest_ID       : Identifier := Zero_Identifier;
      Retained_Manifest : Shared_Image_Lease;
      Expected_Generation : Generation_Value;
      Expected_Head     : Head_Snapshot;
      Attempted_Head    : Head_Snapshot;
      --  Runtime-only certainty witness: True immediately before entering the
      --  conditional HEAD provider call. It prevents a pre-call rejection
      --  from exposing an identity as though publication had been attempted.
      Head_Entered      : Boolean := False;
   end record;

   --  Receipt phases are in-memory certainty states, never persisted enum
   --  positions. Objects_Unknown permits only same-identity exact-byte
   --  continuation; Flush_Head_Unknown requires read-only HEAD reconciliation;
   --  Flush_Head_Confirmed records durable success awaiting local activation.
   type Flush_Receipt_Phase is
     (No_Flush_Publication, Objects_Unknown, Flush_Head_Unknown, Flush_Head_Confirmed, Flush_Resolved);

   --  The fixed receipt map is derived from the manifest-v1/v2 64-family
   --  compatibility ceiling. It retains caller identities without borrowing
   --  the caller array or introducing a second Flush-specific capacity.
   subtype Flush_Run_Receipt_Array is Checkpoint_Run_Identity_Array (1 .. Maximum_Initial_Column_Families);

   type Flush_Receipt is record
      Current_Outcome     : Outcome_Code := Invalid_State;
      Phase               : Flush_Receipt_Phase := No_Flush_Publication;
      --  Private operation-shape authority used only to rebuild the exact
      --  same plan during Objects_Unknown reconciliation. False is additive
      --  Flush; True is complete current-run replacement. It is runtime state,
      --  not a persisted flag, public default, or automatic compaction policy.
      Replaces_Current_Runs : Boolean := False;
      --  Private exact-plan authority for an explicitly selected adjacent
      --  merge. The selected input identities are retained only so
      --  Objects_Unknown reconciliation can rebuild the same immutable bytes;
      --  they are neither a trigger nor a retained borrow.
      Merges_Adjacent_Runs : Boolean := False;
      --  Exact-three qualification authority only. When true, Middle_Run_ID
      --  completes the caller-selected triple between Older/Newer. It is not
      --  a persisted fanout, trigger, level, or automatic-selection policy.
      Merges_Three_Runs    : Boolean := False;
      Older_Run_ID         : Identifier := Zero_Identifier;
      Middle_Run_ID        : Identifier := Zero_Identifier;
      Newer_Run_ID         : Identifier := Zero_Identifier;
      Run_Total           : Natural range 0 .. Maximum_Initial_Column_Families := 0;
      Runs                : Flush_Run_Receipt_Array := [others => (others => <>)];
      Database_ID         : Database_Identifier := Zero_Database_ID;
      Incarnation         : Engine_Incarnation := 0;
      Manifest_ID         : Identifier := Zero_Identifier;
      Replay_Boundary     : Sequence_Number := 0;
      Expected_Generation : Generation_Value;
      Expected_Head       : Head_Snapshot;
      Attempted_Head      : Head_Snapshot;
   end record;

   type Flush_Driver_State;
   type Flush_Driver_State_Access is access Flush_Driver_State;
   type Refresh_Driver_State;
   type Refresh_Driver_State_Access is access Refresh_Driver_State;
   type Refresh_Operation_Access is access Refresh_Operation;
   type Get_Driver_State;
   type Get_Driver_State_Access is access Get_Driver_State;
   type Scan_Driver_State;
   type Scan_Driver_State_Access is access Scan_Driver_State;
   type Lazy_SST_Read_State;
   type Lazy_SST_Read_State_Access is access Lazy_SST_Read_State;
   type Lazy_Checkpoint_Read_State;
   type Lazy_Checkpoint_Read_State_Access is access Lazy_Checkpoint_Read_State;
   type Lazy_SST_Entry_Disposition is
     (Lazy_Value_Found, Lazy_Tombstone_Found, Lazy_Key_Absent, Lazy_Read_Failed);
   type Lazy_SST_Read_Purpose is (Lazy_Point_Entry, Lazy_Next_Entry);
   type Lazy_SST_Run_Descriptor is record
      Run_ID                : Identifier := Zero_Identifier;
      Lowest_Sequence       : Sequence_Number := 0;
      Highest_Sequence      : Sequence_Number := 0;
      Entry_Total           : Interfaces.Unsigned_32 := 0;
      Logical_Payload_Bytes : Interfaces.Unsigned_64 := 0;
   end record;
   type Lazy_SST_Run_Array is array (Positive range <>) of Lazy_SST_Run_Descriptor;
   type Whole_Get_Operation_Access is access Flyology.Object_Storage.Client.Objects.Whole_Get_Operation;
   type Range_Get_Operation_Access is access Flyology.Object_Storage.Client.Objects.Range_Get_Operation;
   type Head_Operation_Access is access Flyology.Object_Storage.Client.Objects.Head_Operation;

   --  @exclude
   type Flush_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation (Set) with record
      Payload          : aliased Flyology.Buffers.Unique_Buffer (Payload_Pool);
      Put_Child        : Flyology.Object_Storage.Client.Objects.Conditional_Put_Operation
        (Set, HTTP, Cancellation);
      Read_Child       : Whole_Get_Operation_Access := null;
      Range_Child      : Range_Get_Operation_Access := null;
      Head_Child       : Head_Operation_Access := null;
      Recovery_Child   : Refresh_Operation_Access := null;
      Driver_State     : Flush_Driver_State_Access := null;
      --  Vacant-operation sentinel only. Start_Flush replaces it with the one
      --  caller-derived monotonic deadline before the operation can be active.
      Deadline         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      HTTP_Deadline    : Flyology.HTTP.Client.Monotonic_Deadline;
      Final_Receipt    : Flush_Receipt;
      Final_Family_Receipt : Column_Family_Receipt;
      Final_Create_Receipt : Create_Receipt;
      --  Runtime terminal-result discriminator for the two typed Finish
      --  overloads sharing this checkpoint state machine. It is never
      --  persisted and prevents the wrong Finish from consuming ownership.
      Final_Is_Family_Append : Boolean := False;
      Final_Is_Create  : Boolean := False;
      Final_Result     : Outcome_Code := Invalid_State;
      Has_Final_Result : Boolean := False;
      Has_Saved_Error  : Boolean := False;
      Saved_Error      : Ada.Exceptions.Exception_Occurrence;
   end record;

   --  @exclude
   overriding procedure Drive
     (Item : in out Flush_Operation;
      Event : Flyology.Operations.Driver_Event);
   --  @exclude
   overriding procedure Request_Cancellation (Item : in out Flush_Operation);
   --  @exclude
   overriding procedure Finalize (Item : in out Flush_Operation);

   --  @exclude
   type Create_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flush_Operation (Set, Item, Storage, HTTP, Payload_Pool, Cancellation)
       with null record;

   --  @exclude
   overriding procedure Drive
     (Item : in out Create_Operation;
      Event : Flyology.Operations.Driver_Event);

   --  @exclude
   type Refresh_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation (Set) with record
      Payload          : aliased Flyology.Buffers.Unique_Buffer (Payload_Pool);
      Read_Child       : Whole_Get_Operation_Access := null;
      Range_Child      : Range_Get_Operation_Access := null;
      Head_Child       : Head_Operation_Access := null;
      Driver_State     : Refresh_Driver_State_Access := null;
      --  Vacant-operation sentinel only. Refresh_Replica replaces it with the
      --  caller-derived monotonic deadline before the operation can be active.
      Deadline         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      HTTP_Deadline    : Flyology.HTTP.Client.Monotonic_Deadline;
      Final_Result     : Outcome_Code := Invalid_State;
      Has_Final_Result : Boolean := False;
      Has_Saved_Error  : Boolean := False;
      Saved_Error      : Ada.Exceptions.Exception_Occurrence;
   end record;

   --  @exclude
   overriding procedure Drive
     (Item : in out Refresh_Operation;
      Event : Flyology.Operations.Driver_Event);
   --  @exclude
   overriding procedure Request_Cancellation (Item : in out Refresh_Operation);
   --  @exclude
   overriding procedure Finalize (Item : in out Refresh_Operation);

   --  @exclude
   type Open_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Refresh_Operation (Set, Item, Storage, HTTP, Payload_Pool, Cancellation)
       with null record;

   --  @exclude
   overriding procedure Drive
     (Item : in out Open_Operation;
      Event : Flyology.Operations.Driver_Event);

   --  Private engine operation for one generation-bound SST-v1/v2 point or
   --  next-visible-entry read. Version 2 reads only header/index/one frame;
   --  version 1 uses the frozen authenticated whole-object compatibility
   --  fallback.
   --  The retained borrows and moved token follow the public operation
   --  convention, but this type deliberately adds no public read contract.
   type Lazy_SST_Read_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation (Set) with record
      Payload          : aliased Flyology.Buffers.Unique_Buffer (Payload_Pool);
      Whole_Child      : Whole_Get_Operation_Access := null;
      Range_Child      : Range_Get_Operation_Access := null;
      Head_Child       : Head_Operation_Access := null;
      Driver_State     : Lazy_SST_Read_State_Access := null;
      Deadline         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      HTTP_Deadline    : Flyology.HTTP.Client.Monotonic_Deadline;
      Final_Result     : Outcome_Code := Invalid_State;
      Final_Disposition : Lazy_SST_Entry_Disposition := Lazy_Read_Failed;
      Final_Sequence   : Sequence_Number := 0;
      Final_Key        : Flyology.Bytes.Unbounded_Bytes;
      Final_Value      : Flyology.Bytes.Unbounded_Bytes;
      Final_Purpose     : Lazy_SST_Read_Purpose := Lazy_Point_Entry;
      Has_Final_Result : Boolean := False;
      Has_Saved_Error  : Boolean := False;
      Saved_Error      : Ada.Exceptions.Exception_Occurrence;
   end record;
   type Lazy_SST_Read_Operation_Access is access Lazy_SST_Read_Operation;

   procedure Read_Lazy_SST_Entry
     (Database_ID          : Database_Identifier;
      Family               : Column_Family_Configuration;
      Run_ID               : Identifier;
      Lowest_Sequence      : Sequence_Number;
      Highest_Sequence     : Sequence_Number;
      Entry_Total          : Interfaces.Unsigned_32;
      Logical_Payload_Bytes : Interfaces.Unsigned_64;
      Snapshot_At          : Sequence_Number;
      Item_Key             : Byte_Array;
      Payload_Buffer       : in out Flyology.Buffers.Unique_Buffer;
      Timeout              : Duration;
      Operation            : in out Lazy_SST_Read_Operation);

   --  Read one exact next snapshot-visible entry from a single immutable run.
   --  A present start is inclusive or strict as selected; a present upper
   --  bound is exclusive. Version 2 authenticates its index and only the
   --  selected frame, while frozen version 1 uses its required whole-object
   --  compatibility path. No page, prefetch, or retry policy is selected.
   procedure Read_Lazy_SST_Next_Entry
     (Database_ID           : Database_Identifier;
      Family                : Column_Family_Configuration;
      Run_ID                : Identifier;
      Lowest_Sequence       : Sequence_Number;
      Highest_Sequence      : Sequence_Number;
      Entry_Total           : Interfaces.Unsigned_32;
      Logical_Payload_Bytes : Interfaces.Unsigned_64;
      Snapshot_At           : Sequence_Number;
      Has_Start             : Boolean;
      Start_Key             : Byte_Array;
      Start_Inclusive       : Boolean;
      Has_Upper             : Boolean;
      Upper_Key             : Byte_Array;
      Payload_Buffer        : in out Flyology.Buffers.Unique_Buffer;
      Timeout               : Duration;
      Operation             : in out Lazy_SST_Read_Operation);

   procedure Finish_Lazy_SST_Read
     (Operation      : in out Lazy_SST_Read_Operation;
      Disposition    : out Lazy_SST_Entry_Disposition;
      Sequence       : out Sequence_Number;
      Value          : out Flyology.Bytes.Unbounded_Bytes;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer);

   --  Consume one terminal next-entry read, restore the exact moved scratch
   --  token into any vacant same-pool handle, and move out only authenticated
   --  key/value bytes. Tombstones return the exact key and no value.
   procedure Finish_Lazy_SST_Next_Entry
     (Operation      : in out Lazy_SST_Read_Operation;
      Disposition    : out Lazy_SST_Entry_Disposition;
      Sequence       : out Sequence_Number;
      Item_Key       : out Flyology.Bytes.Unbounded_Bytes;
      Value          : out Flyology.Bytes.Unbounded_Bytes;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer);

   overriding procedure Drive
     (Item : in out Lazy_SST_Read_Operation;
      Event : Flyology.Operations.Driver_Event);
   overriding procedure Request_Cancellation (Item : in out Lazy_SST_Read_Operation);
   overriding procedure Finalize (Item : in out Lazy_SST_Read_Operation);

   --  Private fixed-snapshot parent over one exact oldest-to-newest manifest
   --  run slice. The dynamic retained copy has the caller/persisted extent;
   --  this operation introduces no run ceiling or public read contract.
   type Lazy_Checkpoint_Read_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation (Set) with record
      Payload          : aliased Flyology.Buffers.Unique_Buffer (Payload_Pool);
      Child            : aliased Lazy_SST_Read_Operation
        (Set, Storage, HTTP, Payload_Pool, Cancellation);
      Driver_State     : Lazy_Checkpoint_Read_State_Access := null;
      Deadline         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Final_Result     : Outcome_Code := Invalid_State;
      Final_Disposition : Lazy_SST_Entry_Disposition := Lazy_Read_Failed;
      Final_Sequence   : Sequence_Number := 0;
      Final_Value      : Flyology.Bytes.Unbounded_Bytes;
      Has_Final_Result : Boolean := False;
      Has_Saved_Error  : Boolean := False;
      Saved_Error      : Ada.Exceptions.Exception_Occurrence;
   end record;
   type Lazy_Checkpoint_Read_Operation_Access is access Lazy_Checkpoint_Read_Operation;

   procedure Read_Lazy_Checkpoint_Entry
     (Database_ID    : Database_Identifier;
      Family         : Column_Family_Configuration;
      Runs           : Lazy_SST_Run_Array;
      Snapshot_At    : Sequence_Number;
      Item_Key       : Byte_Array;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer;
      Timeout        : Duration;
      Operation      : in out Lazy_Checkpoint_Read_Operation);

   procedure Finish_Lazy_Checkpoint_Read
     (Operation      : in out Lazy_Checkpoint_Read_Operation;
      Disposition    : out Lazy_SST_Entry_Disposition;
      Sequence       : out Sequence_Number;
      Value          : out Flyology.Bytes.Unbounded_Bytes;
      Result         : out Outcome_Code;
      Payload_Buffer : in out Flyology.Buffers.Unique_Buffer);

   overriding procedure Drive
     (Item : in out Lazy_Checkpoint_Read_Operation;
      Event : Flyology.Operations.Driver_Event);
   overriding procedure Request_Cancellation (Item : in out Lazy_Checkpoint_Read_Operation);
   overriding procedure Finalize (Item : in out Lazy_Checkpoint_Read_Operation);

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
      --  Test-only boundary between an inconclusive immutable create and its
      --  exact-byte read-only observation. It introduces no retry policy.
      Before_Immutable_Reconciliation,
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
      Backend               : access Flyology.Object_Storage.Backends.Backend'Class := null;
      HTTP_Client           : access Flyology.HTTP.Client.Client := null;
      Client_Origin         : Flyology.HTTP.Origin;
      Client_Identity       : access Flyology.Object_Storage.Client.Low_Level.Credentials := null;
      Bucket                : Ada.Strings.Unbounded.Unbounded_String;
      Prefix                : Ada.Strings.Unbounded.Unbounded_String;
      Client_Region         : Ada.Strings.Unbounded.Unbounded_String;
      Client_Content_Type   : Ada.Strings.Unbounded.Unbounded_String;
      Expected_Bucket_Owner : Ada.Strings.Unbounded.Unbounded_String;
      Client_Request_Payer  : Ada.Strings.Unbounded.Unbounded_String;
      Client_Checksum_Mode  : Boolean := False;
      --  Vacant-state initializer only: Bind_Client always overwrites Style
      --  before HTTP_Client makes this context usable, so Path_Style is not a
      --  DB request default or caller policy.
      Client_Style          : Flyology.Object_Storage.Client.Low_Level.Addressing_Style :=
        Flyology.Object_Storage.Client.Low_Level.Path_Style;
      Test_Control          : Storage_Test_Control;
   end record;

   function Run_Key (Storage : Storage_Context; Run_ID : Identifier) return String;

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
      procedure Begin_Composable_Resolve
        (State  : out Engine_State_Access;
         Result : out Outcome_Code);
      procedure Begin_Checkpoint (State : out Engine_State_Access; Result : out Outcome_Code);
      procedure Begin_Composable_Checkpoint
        (State  : out Engine_State_Access;
         Result : out Outcome_Code);
      --  @exclude
      procedure Promote_Composable_Checkpoint
        (Expected : not null Engine_State_Access;
         State    : out Engine_State_Access;
         Result   : out Outcome_Code);
      procedure Checkpoint_Wait_Source
        (Descriptor : out Interfaces.C.int;
         Ready_Now  : out Boolean);
      procedure Resolve_Wait_Source
        (Descriptor : out Interfaces.C.int;
         Ready_Now  : out Boolean);
      entry Await_Quiescent;
      procedure Finish_Close;
      procedure Finish_Resolve (State : not null Engine_State_Access; Visible : Sequence_Number);
      procedure Cancel_Resolve;
      procedure Finish_Checkpoint;
      procedure Finish_Checkpoint (State : not null Engine_State_Access; Visible : Sequence_Number);
      procedure Cancel_Checkpoint;
      procedure Set_Visible (Value : Sequence_Number);
      function Highest (Result : out Outcome_Code) return Sequence_Number;
   private
      Mode         : Database_Lifecycle_Mode := Closed;
      Current      : Engine_State_Access := null;
      Active_Calls : Natural := 0;
      Last_Visible : Sequence_Number := 0;
      Quiescence_Wake      : Flyology.Wake_Sources.Source;
      Quiescence_Signalled : Boolean := False;
   end Database_Lifecycle;
   type Database_Lifecycle_Access is access all Database_Lifecycle;

   type Database is new Ada.Finalization.Limited_Controlled with record
      Life : aliased Database_Lifecycle;
   end record;

   --  @exclude
   type Get_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Txn          : not null access Transaction;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token) is
     new Flyology.Operations.Operation (Set) with record
      Payload          : Flyology.Buffers.Unique_Buffer (Payload_Pool);
      Child            : Lazy_Checkpoint_Read_Operation_Access := null;
      Driver_State     : Get_Driver_State_Access := null;
      Retained_Life    : Database_Lifecycle_Access := null;
      Retained_State   : Engine_State_Access := null;
      --  Vacant-operation sentinel only. Get replaces it with the caller's
      --  derived monotonic deadline before any child can start.
      Deadline         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Final_Value      : Flyology.Bytes.Unbounded_Bytes;
      Final_Result     : Outcome_Code := Invalid_State;
      Has_Final_Result : Boolean := False;
      Has_Saved_Error  : Boolean := False;
      Saved_Error      : Ada.Exceptions.Exception_Occurrence;
   end record;

   --  @exclude
   overriding procedure Drive
     (Item : in out Get_Operation;
      Event : Flyology.Operations.Driver_Event);
   --  @exclude
   overriding procedure Request_Cancellation (Item : in out Get_Operation);
   --  @exclude
   overriding procedure Finalize (Item : in out Get_Operation);

   --  @exclude
   type Scan_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Txn          : not null access Transaction;
      Payload_Pool : not null access Flyology.Buffers.Pool;
      Cancellation : access Flyology.Cancellation.Token)
   is new Flyology.Operations.Operation (Set) with record
      Payload          : aliased Flyology.Buffers.Unique_Buffer (Payload_Pool);
      Child            : Lazy_SST_Read_Operation_Access := null;
      Driver_State     : Scan_Driver_State_Access := null;
      Candidate_Cursor : Scan_Cursor;
      Candidate_Rows   : Scan_Result;
      --  Runtime-only typed-Finish discriminator and exact cursor borrow for
      --  page publication. They are cleared by Finish and are never persisted
      --  or exposed as caller-selected identity policy.
      Final_Is_Page    : Boolean := False;
      Borrowed_Cursor  : Scan_Cursor_State_Access := null;
      Borrowed_Revision : Interfaces.Unsigned_64 := 0;
      Retained_Life    : Database_Lifecycle_Access := null;
      Retained_State   : Engine_State_Access := null;
      --  Vacant-operation sentinel only. Start_Scan replaces it with the
      --  caller-derived monotonic deadline before any child can start.
      Deadline         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Final_Result     : Outcome_Code := Invalid_State;
      Final_Done       : Boolean := False;
      Has_Final_Result : Boolean := False;
      Has_Saved_Error  : Boolean := False;
      Saved_Error      : Ada.Exceptions.Exception_Occurrence;
   end record;

   --  @exclude
   overriding
   procedure Drive (Item : in out Scan_Operation; Event : Flyology.Operations.Driver_Event);
   --  @exclude
   overriding
   procedure Request_Cancellation (Item : in out Scan_Operation);
   --  @exclude
   overriding
   procedure Finalize (Item : in out Scan_Operation);

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
   procedure Convert_Test_Run_To_V1
     (Item    : in out Storage_Context;
      Run_ID  : Identifier;
      Timeout : Duration;
      Result  : out Outcome_Code);
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
      Maximum_Point_Reads    : out Interfaces.Unsigned_32;
      Maximum_Scan_Ranges    : out Interfaces.Unsigned_32;
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
      Maximum_Point_Reads    : out Interfaces.Unsigned_32;
      Maximum_Scan_Ranges    : out Interfaces.Unsigned_32;
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
   procedure Read_Test_Checkpoint_Buffer_Capacity
     (Item : in out Database; Maximum : out Natural; Result : out Outcome_Code);
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
      Result           : out Outcome_Code);
   procedure Publish_Test_Compaction
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code);
   procedure Publish_Test_Adjacent_Merge
     (Item          : in out Database;
      Older_Run_ID  : Identifier;
      Newer_Run_ID  : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code);
   procedure Publish_Test_Three_Run_Merge
     (Item          : in out Database;
      First_Run_ID  : Identifier;
      Middle_Run_ID : Identifier;
      Last_Run_ID   : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code);
   function Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier;

end Flyology.DB;
