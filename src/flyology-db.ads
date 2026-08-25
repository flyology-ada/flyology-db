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
private with Flyology.Object_Storage.Client.Scoped;
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
   type Create_Receipt is private;
   type Commit_Receipt is private;
   --  Self-contained checkpoint publication and reconciliation state.
   type Flush_Receipt is private;
   --  Caller-composable checkpoint publication. The discriminants are
   --  retained borrows: Set, Item, Storage, HTTP, Payload_Pool, and
   --  Cancellation must outlive terminal Finish or scope-abandonment drain.
   --  Storage must be bound to the exact HTTP client. Payload_Pool supplies
   --  caller-selected scratch capacity; the DB introduces no body-size
   --  default or ceiling. The current owner stack needs four reusable set
   --  slots while a conditional Put, reconciliation Get, or selected-run read
   --  is active: DB, Object Storage, HTTP exchange, and transport.
   type Flush_Operation
     (Set          : not null access Flyology.Operations.Completion_Set'Class;
      Item         : not null access Database;
      Storage      : not null access Storage_Context;
      HTTP         : not null access Flyology.HTTP.Client.Client;
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
   --  @param Runs Exact family/run identity map copied before return
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
   --  runs. Runs must map every persisted family to one caller-stable identity;
   --  empty or unchanged families consume no new run object or identity. Every
   --  identity that names an attempted object or HEAD becomes unavailable for
   --  reuse once its publication begins. One absolute monotonic deadline
   --  covers planning, publication, reconciliation, and local activation.
   --  Outcome_Unknown must be resolved and never replayed as a new operation.
   --  @param Item Open database whose committed prefix is checkpointed
   --  @param Runs Exact caller-owned family/run identity map borrowed for this call
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
      Recovery_Checkpoint_Image_Allocation,
      Recovery_Snapshot_Base_Allocation,
      Flush_Activation_State_Allocation);
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
   type Whole_Get_Operation_Access is access Flyology.Object_Storage.Client.Scoped.Whole_Get_Operation;
   type Range_Get_Operation_Access is access Flyology.Object_Storage.Client.Scoped.Range_Get_Operation;
   type Head_Operation_Access is access Flyology.Object_Storage.Client.Scoped.Head_Operation;

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
      Put_Child        : Flyology.Object_Storage.Client.Scoped.Conditional_Put_Operation
        (Set, HTTP, Cancellation);
      Read_Child       : Whole_Get_Operation_Access := null;
      Range_Child      : Range_Get_Operation_Access := null;
      Head_Child       : Head_Operation_Access := null;
      Driver_State     : Flush_Driver_State_Access := null;
      --  Vacant-operation sentinel only. Start_Flush replaces it with the one
      --  caller-derived monotonic deadline before the operation can be active.
      Deadline         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      HTTP_Deadline    : Flyology.HTTP.Client.Monotonic_Deadline;
      Final_Receipt    : Flush_Receipt;
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
   procedure Refresh_Test_Replica
     (Item    : in out Database;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code);
   procedure Start_Test_Compaction
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
   function Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier;

end Flyology.DB;
