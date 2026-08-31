package body Flyology.DB.Testing is

   procedure Fail_Next_Allocation (Point : Allocation_Fault_Point) is
   begin
      Set_Test_Allocation_Fault
        (case Point is
           when Transaction_Arena         => Transaction_Arena_Allocation,
           when Transaction_Payload       => Transaction_Payload_Allocation,
           when Batch_Descriptors         => Batch_Descriptor_Allocation,
           when Runtime_Mutation_Lookup   => Runtime_Mutation_Lookup_Allocation,
           when Storage_Sink              => Storage_Sink_Allocation,
           when Recovery_History          => Recovery_History_Allocation,
           when Recovery_History_Lookup   => Recovery_History_Lookup_Allocation,
           when Engine_State              => Engine_State_Allocation,
           when Identity_Tables           => Identity_Table_Allocation,
           when Projection_Scratch        => Projection_Scratch_Allocation,
           when Checkpoint_Requirement_Families => Checkpoint_Requirement_Family_Allocation,
           when Root_Checkpoint_State     => Root_Checkpoint_State_Allocation,
           when Root_Checkpoint_Image     => Root_Checkpoint_Image_Allocation,
           when Root_Manifest_Retention   => Root_Manifest_Retention_Allocation,
           when Checkpoint_References     => Checkpoint_Reference_Allocation,
           when Checkpoint_SST            => Checkpoint_SST_Allocation,
           when Checkpoint_Manifest       => Checkpoint_Manifest_Allocation,
           when Recovery_Manifest_Header  => Recovery_Manifest_Header_Allocation,
           when Recovery_Manifest_Image   => Recovery_Manifest_Image_Allocation,
           when Recovery_SST_Header       => Recovery_SST_Header_Allocation,
           when Recovery_SST_Image        => Recovery_SST_Image_Allocation,
           when Recovery_Checkpoint_Image => Recovery_Checkpoint_Image_Allocation,
           when Recovery_Snapshot_Base    => Recovery_Snapshot_Base_Allocation,
           when Flush_Activation_State    => Flush_Activation_State_Allocation);
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

   procedure Publication_Counts
     (Item          : in out Storage_Context;
      Batch_Puts    : out Natural;
      Run_Puts      : out Natural;
      Manifest_Puts : out Natural;
      Head_Puts     : out Natural) is
   begin
      Item.Test_Control.Publication_Counts (Batch_Puts, Run_Puts, Manifest_Puts, Head_Puts);
   end Publication_Counts;

   function Attempted_Transition_Number (Item : Commit_Receipt) return Interfaces.Unsigned_64
   is (Item.Attempted_Head.Transition_Number);

   procedure Pause_Next_Commit_After_Admission is
   begin
      Arm_Test_Commit_Handoff (After_Admission);
   end Pause_Next_Commit_After_Admission;

   procedure Pause_Next_Commit_After_Result_Collection is
   begin
      Arm_Test_Commit_Handoff (After_Result_Collection);
   end Pause_Next_Commit_After_Result_Collection;

   function Commit_Handoff_Waiting return Boolean
   is (Test_Commit_Handoff_Waiting);

   procedure Resume_Commit_Handoff is
   begin
      Resume_Test_Commit_Handoff;
   end Resume_Commit_Handoff;

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

   procedure Corrupt_Run (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code) is
   begin
      Corrupt_Test_Run (Item, Run_ID, Result);
   end Corrupt_Run;

   procedure Remove_Run (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code) is
   begin
      Remove_Test_Run (Item, Run_ID, Result);
   end Remove_Run;

   procedure Rewrite_Run_Family
     (Item      : in out Storage_Context;
      Run_ID    : Identifier;
      Family_ID : Column_Family_ID;
      Result    : out Outcome_Code) is
   begin
      Rewrite_Test_Run_Family (Item, Run_ID, Family_ID, Result);
   end Rewrite_Run_Family;

   procedure Convert_Run_To_V1
     (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code) is
   begin
      --  The established public testing adapter is backend-only, so this
      --  client timeout formal is unused. Duration'Last preserves its former
      --  no-deadline test-helper authority without becoming DB policy.
      Convert_Test_Run_To_V1 (Item, Run_ID, Duration'Last, Result);
   end Convert_Run_To_V1;

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
      Maximum_Point_Reads    : out Interfaces.Unsigned_32;
      Maximum_Scan_Ranges    : out Interfaces.Unsigned_32;
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
         Maximum_Point_Reads,
         Maximum_Scan_Ranges,
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
      Maximum_Point_Reads    : out Interfaces.Unsigned_32;
      Maximum_Scan_Ranges    : out Interfaces.Unsigned_32;
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
         Maximum_Point_Reads,
         Maximum_Scan_Ranges,
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

   procedure Checkpoint_Buffer_Capacity
     (Item : in out Database; Maximum : out Natural; Result : out Outcome_Code) is
   begin
      Read_Test_Checkpoint_Buffer_Capacity (Item, Maximum, Result);
   end Checkpoint_Buffer_Capacity;

   procedure Build_First_SST
     (Item             : in out Database;
      Family_ID        : Column_Family_ID;
      Run_ID           : Identifier;
      Entry_Total      : out Natural;
      Lowest_Sequence  : out Sequence_Number;
      Highest_Sequence : out Sequence_Number;
      Result           : out Outcome_Code) is
   begin
      Build_Test_First_SST (Item, Family_ID, Run_ID, Entry_Total, Lowest_Sequence, Highest_Sequence, Result);
   end Build_First_SST;

   procedure Build_First_Checkpoint
     (Item            : in out Database;
      Runs            : Checkpoint_Run_Identity_Array;
      Manifest_ID     : Identifier;
      Transition_ID   : Identifier;
      Run_Total       : out Natural;
      Identity_Total  : out Natural;
      Replay_Boundary : out Sequence_Number;
      Result          : out Outcome_Code) is
   begin
      Build_Test_First_Checkpoint
        (Item, Runs, Manifest_ID, Transition_ID, Run_Total, Identity_Total, Replay_Boundary, Result);
   end Build_First_Checkpoint;

   procedure Publish_First_Checkpoint
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code) is
   begin
      Publish_Test_First_Checkpoint (Item, Runs, Manifest_ID, Transition_ID, Result);
   end Publish_First_Checkpoint;

   procedure Build_Compaction_Checkpoint
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
      Result           : out Outcome_Code) is
   begin
      Build_Test_Compaction_Checkpoint
        (Item,
         Runs,
         Manifest_ID,
         Transition_ID,
         Family_ID,
         Run_Total,
         Identity_Total,
         Replay_Boundary,
         Family_Run_Total,
         Family_Run_ID,
         Family_Entries,
         Result);
   end Build_Compaction_Checkpoint;

   procedure Publish_Compaction
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      Publish_Test_Compaction (Item, Runs, Manifest_ID, Transition_ID, Receipt, Result);
   end Publish_Compaction;

   procedure Publish_Adjacent_Merge
     (Item          : in out Database;
      Older_Run_ID  : Identifier;
      Newer_Run_ID  : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code) is
   begin
      Publish_Test_Adjacent_Merge
        (Item,
         Older_Run_ID,
         Newer_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Receipt,
         Result);
   end Publish_Adjacent_Merge;

   procedure Publish_Three_Run_Merge
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
      Publish_Test_Three_Run_Merge
        (Item,
         First_Run_ID,
         Middle_Run_ID,
         Last_Run_ID,
         Output_Run_ID,
         Manifest_ID,
         Transition_ID,
         Receipt,
         Result);
   end Publish_Three_Run_Merge;

   function Receipt_Replaces_Current_Runs (Item : Flush_Receipt) return Boolean
   is (Item.Replaces_Current_Runs);

   function Test_Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier
   is (Structural_ID (Tag, Number));

end Flyology.DB.Testing;
