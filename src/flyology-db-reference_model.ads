with Interfaces;
with Flyology.DB.Formats;

--  Defines the bounded deterministic reference semantics used by oracle workloads.
private package Flyology.DB.Reference_Model
  with SPARK_Mode => On
is

   Max_Key_Bytes            : constant := 32;
   Max_Value_Bytes          : constant := 64;
   Max_Versions             : constant := 64;
   Max_Mutations            : constant := 8;
   Max_Point_Reads          : constant := 8;
   Max_Ranges               : constant := 4;

   subtype Key_Length is Natural range 0 .. Max_Key_Bytes;
   subtype Value_Length is Natural range 0 .. Max_Value_Bytes;

   subtype Key_Byte_Index is Positive range 1 .. Max_Key_Bytes;
   subtype Value_Byte_Index is Positive range 1 .. Max_Value_Bytes;
   type Key_Bytes is array (Key_Byte_Index) of Formats.Byte;
   type Value_Bytes is array (Value_Byte_Index) of Formats.Byte;

   type Key is record
      Length : Key_Length := 0;
      Bytes  : Key_Bytes := [others => 0];
   end record;

   type Value is record
      Length : Value_Length := 0;
      Bytes  : Value_Bytes := [others => 0];
   end record;

   type Column_Family_ID is new Interfaces.Unsigned_32 range 1 .. Interfaces.Unsigned_32'Last;
   type Sequence_Number is new Interfaces.Unsigned_64;

   type Isolation_Level is (Snapshot, Serializable);
   type Result_Code is
     (Success,
      Not_Found,
      Conflict,
      Serialization_Failure,
      Capacity_Exceeded,
      Sequence_Exhausted,
      Invalid_Transaction,
      Invalid_Range);

   type Database_State is private;
   type Transaction is private;

   --  Bytewise key equality over the declared lengths.
   function Equal (Left, Right : Key) return Boolean;

   --  Strict unsigned lexicographic ordering over the declared bytes.
   function Less (Left, Right : Key) return Boolean;

   --  Reset all logical state and the global commit sequence.
   procedure Initialize (State : out Database_State);

   --  Begin a transaction at the current global sequence.
   procedure Begin_Transaction
     (State : Database_State;
      Mode  : Isolation_Level;
      Item  : out Transaction);

   --  Buffer or replace this transaction's mutation for one exact key.
   procedure Put
     (Item   : in out Transaction;
      Family : Column_Family_ID;
      Name   : Key;
      Data   : Value;
      Result : out Result_Code);

   --  Buffer or replace this transaction's tombstone for one exact key.
   procedure Delete
     (Item   : in out Transaction;
      Family : Column_Family_ID;
      Name   : Key;
      Result : out Result_Code);

   --  Read from buffered mutations first and then the fixed transaction snapshot.
   --  Serializable transactions retain the point read even when the key is absent.
   procedure Get
     (State  : Database_State;
      Item   : in out Transaction;
      Family : Column_Family_ID;
      Name   : Key;
      Data   : out Value;
      Result : out Result_Code);

   --  Record one serializable half-open scan predicate `[Lower, Upper)`.
   procedure Observe_Range
     (Item      : in out Transaction;
      Family    : Column_Family_ID;
      Has_Lower : Boolean;
      Lower     : Key;
      Has_Upper : Boolean;
      Upper     : Key;
      Result    : out Result_Code);

   --  Atomically validate and append all buffered mutations at one global sequence.
   procedure Commit
     (State    : in out Database_State;
      Item     : in out Transaction;
      Sequence : out Sequence_Number;
      Result   : out Result_Code);

   --  Discard every buffered mutation and observation.
   procedure Rollback (Item : in out Transaction; Result : out Result_Code);

   --  Highest sequence committed in State.
   function Highest_Sequence (State : Database_State) return Sequence_Number;

   --  Whether Item remains active.
   function Is_Active (Item : Transaction) return Boolean;

private

   subtype Version_Count is Natural range 0 .. Max_Versions;
   subtype Mutation_Count is Natural range 0 .. Max_Mutations;
   subtype Point_Read_Count is Natural range 0 .. Max_Point_Reads;
   subtype Range_Count is Natural range 0 .. Max_Ranges;

   subtype Version_Index is Positive range 1 .. Max_Versions;
   subtype Mutation_Index is Positive range 1 .. Max_Mutations;
   subtype Point_Read_Index is Positive range 1 .. Max_Point_Reads;
   subtype Range_Index is Positive range 1 .. Max_Ranges;

   type Version_Record is record
      Family   : Column_Family_ID := Column_Family_ID'First;
      Name     : Key;
      Data     : Value;
      Sequence : Sequence_Number := 0;
      Deleted  : Boolean := False;
   end record;

   type Version_Array is array (Version_Index) of Version_Record;

   type Database_State is record
      Highest : Sequence_Number := 0;
      Count   : Version_Count := 0;
      Versions : Version_Array;
   end record;

   type Mutation_Record is record
      Family  : Column_Family_ID := Column_Family_ID'First;
      Name    : Key;
      Data    : Value;
      Deleted : Boolean := False;
   end record;

   type Mutation_Array is array (Mutation_Index) of Mutation_Record;

   type Point_Read is record
      Family : Column_Family_ID := Column_Family_ID'First;
      Name   : Key;
   end record;

   type Point_Read_Array is array (Point_Read_Index) of Point_Read;

   type Scan_Range is record
      Family    : Column_Family_ID := Column_Family_ID'First;
      Has_Lower : Boolean := False;
      Lower     : Key;
      Has_Upper : Boolean := False;
      Upper     : Key;
   end record;

   type Scan_Range_Array is array (Range_Index) of Scan_Range;

   type Transaction is record
      Active         : Boolean := False;
      Mode           : Isolation_Level := Snapshot;
      Snapshot_At    : Sequence_Number := 0;
      Mutation_Total : Mutation_Count := 0;
      Mutations      : Mutation_Array;
      Point_Total    : Point_Read_Count := 0;
      Point_Reads    : Point_Read_Array;
      Range_Total    : Range_Count := 0;
      Ranges         : Scan_Range_Array;
   end record;

end Flyology.DB.Reference_Model;
