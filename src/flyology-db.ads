with Interfaces;
with Flyology.Cancellation;
private with Ada.Finalization;
private with Ada.Strings.Unbounded;
private with Flyology.Object_Storage.Backends;

--  Experimental object-native transactional key-value database.

package Flyology.DB is

   --  Persisted formats and public semantics may change before a stable release.
   Experimental : constant Boolean := True;

   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (Positive range <>) of Byte;

   Identifier_Length   : constant := 16;
   subtype Identifier_Index is Positive range 1 .. Identifier_Length;
   type Identifier is array (Identifier_Index) of Byte;
   Zero_Identifier     : constant Identifier := [others => 0];
   type Database_Identifier is new Identifier;
   type Transaction_Identifier is new Identifier;
   Zero_Database_ID    : constant Database_Identifier := [others => 0];
   Zero_Transaction_ID : constant Transaction_Identifier := [others => 0];

   type Sequence_Number is new Interfaces.Unsigned_64;
   type Column_Family_ID is new Interfaces.Unsigned_32 range 1 .. Interfaces.Unsigned_32'Last;

   Maximum_Key_Bytes   : constant := 64;
   Maximum_Value_Bytes : constant := 256;
   subtype Key_Length is Natural range 0 .. Maximum_Key_Bytes;
   subtype Value_Length is Natural range 0 .. Maximum_Value_Bytes;
   type Key_Storage is array (Positive range 1 .. Maximum_Key_Bytes) of Byte;
   type Value_Storage is array (Positive range 1 .. Maximum_Value_Bytes) of Byte;

   type Key is record
      Length : Key_Length := 0;
      Bytes  : Key_Storage := [others => 0];
   end record;

   type Value is record
      Length : Value_Length := 0;
      Bytes  : Value_Storage := [others => 0];
   end record;

   --  Construct one arbitrary-byte key within the version-1 operational cap.
   --  @param Data Exact key bytes; an empty array constructs an empty key
   --  @return Bounded key value
   --  @exception Constraint_Error Data exceeds Maximum_Key_Bytes
   function To_Key (Data : Byte_Array) return Key;

   --  Construct one arbitrary-byte value within the version-1 operational cap.
   --  @param Data Exact value bytes; an empty array constructs an empty value
   --  @return Bounded value
   --  @exception Constraint_Error Data exceeds Maximum_Value_Bytes
   function To_Value (Data : Byte_Array) return Value;

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
      Corrupt,
      Storage_Failure,
      Stale_Writer);

   type Storage_Context is limited private;
   type Database is limited private;
   type Transaction is limited private;
   type Commit_Receipt is private;
   Maximum_Group_Transactions : constant := 8;
   type Transaction_Array is array (Positive range <>) of Transaction;
   type Commit_Receipt_Array is array (Positive range <>) of Commit_Receipt;

   --  Create an empty database and publish its initial HEAD if absent.
   --  Item and Storage must remain alive until Close returns.
   procedure Create
     (Item                  : in out Database;
      Storage               : not null access Storage_Context;
      Database_ID           : Database_Identifier;
      Initial_Transition_ID : Identifier;
      Timeout               : Duration;
      Token                 : access Flyology.Cancellation.Token := null;
      Result                : out Outcome_Code);

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

   --  Read a buffered mutation or the latest confirmed committed value.
   procedure Get
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
      Data     : out Value;
      Result   : out Outcome_Code);

   --  Buffer or replace one Put mutation while Item remains safely usable.
   procedure Put
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
      Data     : Value;
      Result   : out Outcome_Code);

   --  Buffer or replace one Delete mutation while Item remains safely usable.
   procedure Delete
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
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

   Maximum_Transaction_Mutations : constant := 64;
   Maximum_Transaction_Bytes     : constant := 4_096;
   Maximum_Commit_Slots          : constant := 8;
   Maximum_Commit_Bytes          : constant := 16_384;
   Maximum_History_Batches       : constant := 64;
   Maximum_State_Entries         : constant := 256;
   Maximum_Seen_Transactions     : constant := 512;
   Maximum_Reserved_Identities   : constant := Maximum_History_Batches * (Maximum_Group_Transactions + 1);
   Maximum_Generation_Bytes      : constant := 256;
   Maximum_Batch_Image_Bytes     : constant := 22_048;

   type Mutation_Kind is (Put_Mutation, Delete_Mutation);
   type Pending_Mutation is record
      Family    : Column_Family_ID := Column_Family_ID'First;
      Operation : Mutation_Kind := Put_Mutation;
      Item_Key  : Key;
      Data      : Value;
   end record;
   subtype Mutation_Slot is Positive range 1 .. Maximum_Transaction_Mutations;
   type Pending_Mutation_Array is array (Mutation_Slot) of Pending_Mutation;

   type Transaction is limited record
      Active         : Boolean := False;
      Database_ID    : Database_Identifier := Zero_Database_ID;
      Transaction_ID : Transaction_Identifier := Zero_Transaction_ID;
      Mutation_Count : Natural range 0 .. Maximum_Transaction_Mutations := 0;
      Bytes_Used     : Natural range 0 .. Maximum_Transaction_Bytes := 0;
      Mutations      : Pending_Mutation_Array;
   end record;

   type Head_Snapshot is record
      Database_ID            : Database_Identifier := Zero_Database_ID;
      Epoch                  : Interfaces.Unsigned_64 := 0;
      Highest                : Sequence_Number := 0;
      Latest_Batch           : Identifier := Zero_Identifier;
      Latest_Manifest        : Identifier := Zero_Identifier;
      Transition_ID          : Identifier := Zero_Identifier;
      Predecessor_Transition : Identifier := Zero_Identifier;
      Transition_Number      : Interfaces.Unsigned_64 := 1;
   end record;

   subtype Batch_Receipt_Index is Natural range 0 .. Maximum_Batch_Image_Bytes - 1;
   type Batch_Receipt_Image is array (Batch_Receipt_Index) of Byte;
   type Receipt_Phase is (No_Publication, Head_Publication_Unknown, Resolved);

   type Commit_Receipt is record
      Current_Outcome   : Outcome_Code := Invalid_State;
      Phase             : Receipt_Phase := No_Publication;
      Transaction_ID    : Transaction_Identifier := Zero_Transaction_ID;
      Assigned_Sequence : Sequence_Number := 0;
      Batch_ID          : Identifier := Zero_Identifier;
      Batch_Length      : Natural range 0 .. Maximum_Batch_Image_Bytes := 0;
      Batch_Image       : Batch_Receipt_Image := [others => 0];
      Expected_Head     : Head_Snapshot;
      Attempted_Head    : Head_Snapshot;
   end record;

   type Storage_Fault_Point is
     (Before_Batch_Put, After_Batch_Put, Before_Head_Put, After_Head_Put, Before_Get);
   type Storage_Fault_Mode is (No_Fault, Definite_Failure, Unknown_After_Entry);
   type Storage_Fault_Count is array (Storage_Fault_Point) of Natural;
   type Storage_Fault_Modes is array (Storage_Fault_Point) of Storage_Fault_Mode;

   protected type Storage_Test_Control is
      procedure Arm (Point : Storage_Fault_Point; Mode : Storage_Fault_Mode; Count : Positive);
      procedure Clear;
      procedure Consume (Point : Storage_Fault_Point; Mode : out Storage_Fault_Mode);
      procedure Record_Put (Is_Head : Boolean);
      procedure Publication_Counts (Batch_Total : out Natural; Head_Total : out Natural);
      procedure Set_Get_Paused (Value : Boolean);
      procedure Arrive_Get;
      entry Continue_Get;
      function Get_Waiting return Boolean;
   private
      Fault_Counts : Storage_Fault_Count := [others => 0];
      Fault_Modes  : Storage_Fault_Modes := [others => No_Fault];
      Batch_Puts   : Natural := 0;
      Head_Puts    : Natural := 0;
      Get_Paused   : Boolean := False;
      Waiting_Gets : Natural := 0;
   end Storage_Test_Control;

   type Storage_Context is limited record
      Backend      : access Flyology.Object_Storage.Backends.Backend'Class := null;
      Bucket       : Ada.Strings.Unbounded.Unbounded_String;
      Prefix       : Ada.Strings.Unbounded.Unbounded_String;
      Test_Control : Storage_Test_Control;
   end record;

   type Engine_State;
   type Engine_State_Access is access Engine_State;

   type Database_Lifecycle_Mode is (Closed, Opening, Opened, Closing, Resolving);

   protected type Database_Lifecycle is
      procedure Begin_Open (Result : out Outcome_Code);
      procedure Complete_Open
        (State : not null Engine_State_Access; Visible : Sequence_Number; Result : out Outcome_Code);
      procedure Abort_Open;
      procedure Acquire (State : out Engine_State_Access; Result : out Outcome_Code);
      procedure Release;
      procedure Begin_Close (State : out Engine_State_Access; Result : out Outcome_Code);
      procedure Begin_Resolve (State : out Engine_State_Access; Result : out Outcome_Code);
      entry Await_Quiescent;
      procedure Finish_Close;
      procedure Finish_Resolve (State : not null Engine_State_Access; Visible : Sequence_Number);
      procedure Cancel_Resolve;
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
   function Test_Get_Waiting (Item : Storage_Context) return Boolean;
   function Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier;

end Flyology.DB;
