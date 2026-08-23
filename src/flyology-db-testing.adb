package body Flyology.DB.Testing is

   procedure Fail_Next_Allocation (Point : Allocation_Fault_Point) is
   begin
      Set_Test_Allocation_Fault
        (case Point is
           when Transaction_Arena       => Transaction_Arena_Allocation,
           when Transaction_Payload     => Transaction_Payload_Allocation,
           when Batch_Descriptors       => Batch_Descriptor_Allocation,
           when Storage_Sink            => Storage_Sink_Allocation,
           when Recovery_History        => Recovery_History_Allocation,
           when Engine_State            => Engine_State_Allocation,
           when Identity_Tables         => Identity_Table_Allocation,
           when Projection_Scratch      => Projection_Scratch_Allocation,
           when Root_Checkpoint_State   => Root_Checkpoint_State_Allocation,
           when Root_Checkpoint_Image   => Root_Checkpoint_Image_Allocation,
           when Root_Manifest_Retention => Root_Manifest_Retention_Allocation);
   end Fail_Next_Allocation;

   procedure Decode_Runtime_Image
     (Data       : Byte_Array;
      Wrong_DB   : Boolean := False;
      Wrong_Head : Boolean := False;
      Result     : out Outcome_Code) is
   begin
      Decode_Runtime_Image_For_Test (Data, Wrong_DB, Wrong_Head, Result);
   end Decode_Runtime_Image;

   procedure Check_Runtime_Reference_Parity (Result : out Outcome_Code) is
   begin
      Flyology.DB.Check_Runtime_Reference_Parity (Result);
   end Check_Runtime_Reference_Parity;

   function Group_Mutation_Total_Fits_Wire (Value : Natural) return Boolean
   is (Flyology.DB.Group_Mutation_Total_Fits_Wire (Value));

   procedure Arm
     (Item : in out Storage_Context; Point : Fault_Point; Mode : Fault_Mode; Count : Positive := 1) is
   begin
      Item.Test_Control.Arm (Point, Mode, Count);
   end Arm;

   procedure Clear (Item : in out Storage_Context) is
   begin
      Item.Test_Control.Clear;
   end Clear;

   procedure Publication_Counts
     (Item : in out Storage_Context; Batch_Puts : out Natural; Head_Puts : out Natural)
   is
      Manifest_Puts : Natural;
   begin
      Item.Test_Control.Publication_Counts (Batch_Puts, Manifest_Puts, Head_Puts);
   end Publication_Counts;

   procedure Publication_Counts
     (Item          : in out Storage_Context;
      Batch_Puts    : out Natural;
      Manifest_Puts : out Natural;
      Head_Puts     : out Natural) is
   begin
      Item.Test_Control.Publication_Counts (Batch_Puts, Manifest_Puts, Head_Puts);
   end Publication_Counts;

   function Attempted_Transition_Number (Item : Commit_Receipt) return Interfaces.Unsigned_64
   is (Item.Attempted_Head.Transition_Number);

   procedure Pause_Coordinator (Item : in out Database; Result : out Outcome_Code) is
   begin
      Set_Test_Paused (Item, True, Result);
   end Pause_Coordinator;

   procedure Resume_Coordinator (Item : in out Database; Result : out Outcome_Code) is
   begin
      Set_Test_Paused (Item, False, Result);
   end Resume_Coordinator;

   procedure Queue_Depth (Item : in out Database; Value : out Natural; Result : out Outcome_Code) is
   begin
      Test_Queue_Depth (Item, Value, Result);
   end Queue_Depth;

   procedure Fail_Next_Install (Item : in out Database; Result : out Outcome_Code) is
   begin
      Fail_Next_Test_Install (Item, Result);
   end Fail_Next_Install;

   procedure Pause_Gets (Item : in out Storage_Context) is
   begin
      Set_Test_Get_Paused (Item, True);
   end Pause_Gets;

   procedure Resume_Gets (Item : in out Storage_Context) is
   begin
      Set_Test_Get_Paused (Item, False);
   end Resume_Gets;

   procedure Wait_For_Get (Item : in out Storage_Context; Timeout : Duration; Arrived : out Boolean) is
   begin
      Wait_For_Test_Get (Item, Timeout, Arrived);
   end Wait_For_Get;

   function Get_Waiting (Item : Storage_Context) return Boolean
   is (Test_Get_Waiting (Item));

   procedure Image_Statistics
     (Allocated, Released, Arenas_Allocated, Arenas_Released, Transaction_Bytes, Source_Bytes, Sink_Bytes :
        out Interfaces.Unsigned_64) is
   begin
      Test_Image_Statistics
        (Allocated, Released, Arenas_Allocated, Arenas_Released, Transaction_Bytes, Source_Bytes, Sink_Bytes);
   end Image_Statistics;

   function Receipt_Retains_Image (Item : Commit_Receipt) return Boolean
   is (Item.Retained_Image.Image /= null);

   function Create_Receipt_Retains_Manifest (Item : Create_Receipt) return Boolean
   is (Item.Retained_Manifest.Image /= null);

   procedure Install_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Legacy        : Boolean;
      Result        : out Outcome_Code) is
   begin
      Install_Test_Head (Item, Database_ID, Manifest_ID, Transition_ID, Legacy, Result);
   end Install_Head;

   procedure Install_Unsupported_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code) is
   begin
      Install_Test_Unsupported_Head (Item, Database_ID, Manifest_ID, Transition_ID, Result);
   end Install_Unsupported_Head;

   procedure Install_Invalid_V2_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code) is
   begin
      Install_Test_Invalid_V2_Head (Item, Database_ID, Manifest_ID, Transition_ID, Result);
   end Install_Invalid_V2_Head;

   procedure Corrupt_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code) is
   begin
      Corrupt_Test_Manifest (Item, Manifest_ID, Result);
   end Corrupt_Manifest;

   procedure Remove_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code) is
   begin
      Remove_Test_Manifest (Item, Manifest_ID, Result);
   end Remove_Manifest;

   procedure Rewrite_Manifest
     (Item                 : in out Storage_Context;
      Manifest_ID          : Identifier;
      Expected_Database_ID : Database_Identifier;
      Replacement_Database : Database_Identifier;
      Oversize_Family      : Boolean;
      Result               : out Outcome_Code) is
   begin
      Rewrite_Test_Manifest
        (Item, Manifest_ID, Expected_Database_ID, Replacement_Database, Oversize_Family, False, 0, 0, Result);
   end Rewrite_Manifest;

   procedure Restrict_Manifest
     (Item                 : in out Storage_Context;
      Manifest_ID          : Identifier;
      Expected_Database_ID : Database_Identifier;
      Drop_Last_Family     : Boolean;
      Restricted_Family    : Interfaces.Unsigned_32;
      Restricted_Max_Key   : Interfaces.Unsigned_64;
      Result               : out Outcome_Code) is
   begin
      Rewrite_Test_Manifest
        (Item,
         Manifest_ID,
         Expected_Database_ID,
         Zero_Database_ID,
         False,
         Drop_Last_Family,
         Restricted_Family,
         Restricted_Max_Key,
         Result);
   end Restrict_Manifest;

   procedure Extend_Manifest_Chain
     (Item        : in out Storage_Context;
      Database_ID : Database_Identifier;
      Root_ID     : Identifier;
      Successors  : Positive;
      Result      : out Outcome_Code) is
   begin
      Extend_Test_Manifest_Chain (Item, Database_ID, Root_ID, Successors, Result);
   end Extend_Manifest_Chain;

   procedure Manifest_Version
     (Item        : in out Storage_Context;
      Manifest_ID : Identifier;
      Version     : out Interfaces.Unsigned_16;
      Result      : out Outcome_Code) is
   begin
      Read_Test_Manifest_Version (Item, Manifest_ID, Version, Result);
   end Manifest_Version;

   procedure Root_LSM_Limits
     (Item                   : in out Storage_Context;
      Manifest_ID            : Identifier;
      Expected_Database      : Database_Identifier;
      Family_ID              : Column_Family_ID;
      Maximum_Total_L0_Runs  : out Interfaces.Unsigned_32;
      Maximum_Identities     : out Interfaces.Unsigned_32;
      Memtable_Max_Bytes     : out Interfaces.Unsigned_64;
      Memtable_Max_Entries   : out Interfaces.Unsigned_32;
      Maximum_Family_L0_Runs : out Interfaces.Unsigned_32;
      Result                 : out Outcome_Code) is
   begin
      Read_Test_Root_LSM_Limits
        (Item,
         Manifest_ID,
         Expected_Database,
         Family_ID,
         Maximum_Total_L0_Runs,
         Maximum_Identities,
         Memtable_Max_Bytes,
         Memtable_Max_Entries,
         Maximum_Family_L0_Runs,
         Result);
   end Root_LSM_Limits;

   procedure Live_LSM_Limits
     (Item                   : in out Database;
      Family_ID              : Column_Family_ID;
      Replay_Boundary        : out Interfaces.Unsigned_64;
      Maximum_Total_L0_Runs  : out Interfaces.Unsigned_32;
      Maximum_Identities     : out Interfaces.Unsigned_32;
      Memtable_Max_Bytes     : out Interfaces.Unsigned_64;
      Memtable_Max_Entries   : out Interfaces.Unsigned_32;
      Maximum_Family_L0_Runs : out Interfaces.Unsigned_32;
      Result                 : out Outcome_Code) is
   begin
      Read_Test_Live_LSM_Limits
        (Item,
         Family_ID,
         Replay_Boundary,
         Maximum_Total_L0_Runs,
         Maximum_Identities,
         Memtable_Max_Bytes,
         Memtable_Max_Entries,
         Maximum_Family_L0_Runs,
         Result);
   end Live_LSM_Limits;

   procedure Live_Entry_Sequence
     (Item      : in out Database;
      Family_ID : Column_Family_ID;
      Item_Key  : Byte_Array;
      Sequence  : out Sequence_Number;
      Result    : out Outcome_Code) is
   begin
      Read_Test_Live_Entry_Sequence (Item, Family_ID, Item_Key, Sequence, Result);
   end Live_Entry_Sequence;

   function Test_Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier
   is (Structural_ID (Tag, Number));

end Flyology.DB.Testing;
