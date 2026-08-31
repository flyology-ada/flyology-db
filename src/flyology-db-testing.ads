with Interfaces;

private package Flyology.DB.Testing is

   type Allocation_Fault_Point is
     (Transaction_Arena,
      Transaction_Payload,
      Batch_Descriptors,
      Runtime_Mutation_Lookup,
      Storage_Sink,
      Recovery_History,
      Recovery_History_Lookup,
      Engine_State,
      Identity_Tables,
      Projection_Scratch,
      Checkpoint_Requirement_Families,
      Root_Checkpoint_State,
      Root_Checkpoint_Image,
      Root_Manifest_Retention,
      Checkpoint_References,
      Checkpoint_SST,
      Checkpoint_Manifest,
      Recovery_Manifest_Header,
      Recovery_Manifest_Image,
      Recovery_SST_Header,
      Recovery_SST_Image,
      Recovery_Checkpoint_Image,
      Recovery_Snapshot_Base,
      Flush_Activation_State);

   procedure Fail_Next_Allocation (Point : Allocation_Fault_Point);
   procedure Decode_Runtime_Image
     (Data       : Byte_Array;
      Wrong_DB   : Boolean := False;
      Wrong_Head : Boolean := False;
      Result     : out Outcome_Code);
   procedure Check_Runtime_Reference_Parity (Result : out Outcome_Code);
   function Group_Mutation_Total_Fits_Wire (Value : Natural) return Boolean;

   subtype Fault_Point is Storage_Fault_Point;
   subtype Fault_Mode is Storage_Fault_Mode;

   --  Arm one deterministic storage fault for the next Count matching calls.
   --  Count defaults to one as test-harness convenience only; it does not
   --  define production retry or fault policy.
   procedure Arm
     (Item : in out Storage_Context; Point : Fault_Point; Mode : Fault_Mode; Count : Positive := 1);

   --  Clear every deterministic storage fault.
   procedure Clear (Item : in out Storage_Context);

   procedure Publication_Counts
     (Item : in out Storage_Context; Batch_Puts : out Natural; Head_Puts : out Natural);
   procedure Publication_Counts
     (Item          : in out Storage_Context;
      Batch_Puts    : out Natural;
      Manifest_Puts : out Natural;
      Head_Puts     : out Natural);
   procedure Publication_Counts
     (Item          : in out Storage_Context;
      Batch_Puts    : out Natural;
      Run_Puts      : out Natural;
      Manifest_Puts : out Natural;
      Head_Puts     : out Natural);

   function Attempted_Transition_Number (Item : Commit_Receipt) return Interfaces.Unsigned_64;

   procedure Pause_Next_Commit_After_Admission;
   procedure Pause_Next_Commit_After_Result_Collection;
   function Commit_Handoff_Waiting return Boolean;
   procedure Resume_Commit_Handoff;

   procedure Pause_Coordinator (Item : in out Database; Result : out Outcome_Code);
   procedure Resume_Coordinator (Item : in out Database; Result : out Outcome_Code);
   procedure Queue_Depth (Item : in out Database; Value : out Natural; Result : out Outcome_Code);
   procedure Fail_Next_Install (Item : in out Database; Result : out Outcome_Code);
   procedure Pause_Gets (Item : in out Storage_Context);
   procedure Resume_Gets (Item : in out Storage_Context);
   procedure Wait_For_Get (Item : in out Storage_Context; Timeout : Duration; Arrived : out Boolean);
   function Get_Waiting (Item : Storage_Context) return Boolean;
   procedure Image_Statistics
     (Allocated, Released, Arenas_Allocated, Arenas_Released, Transaction_Bytes, Source_Bytes, Sink_Bytes :
        out Interfaces.Unsigned_64);
   function Receipt_Retains_Image (Item : Commit_Receipt) return Boolean;
   function Create_Receipt_Retains_Manifest (Item : Create_Receipt) return Boolean;
   procedure Install_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Legacy        : Boolean;
      Result        : out Outcome_Code);
   procedure Install_Unsupported_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code);
   procedure Install_Invalid_V2_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code);
   procedure Corrupt_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code);
   procedure Remove_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code);
   procedure Corrupt_Run (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code);
   procedure Remove_Run (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code);
   procedure Rewrite_Run_Family
     (Item      : in out Storage_Context;
      Run_ID    : Identifier;
      Family_ID : Column_Family_ID;
      Result    : out Outcome_Code);
   procedure Convert_Run_To_V1
     (Item : in out Storage_Context; Run_ID : Identifier; Result : out Outcome_Code);
   procedure Rewrite_Manifest
     (Item                 : in out Storage_Context;
      Manifest_ID          : Identifier;
      Expected_Database_ID : Database_Identifier;
      Replacement_Database : Database_Identifier;
      Oversize_Family      : Boolean;
      Result               : out Outcome_Code);
   procedure Restrict_Manifest
     (Item                 : in out Storage_Context;
      Manifest_ID          : Identifier;
      Expected_Database_ID : Database_Identifier;
      Drop_Last_Family     : Boolean;
      Restricted_Family    : Interfaces.Unsigned_32;
      Restricted_Max_Key   : Interfaces.Unsigned_64;
      Result               : out Outcome_Code);
   procedure Extend_Manifest_Chain
     (Item        : in out Storage_Context;
      Database_ID : Database_Identifier;
      Root_ID     : Identifier;
      Successors  : Positive;
      Result      : out Outcome_Code);
   procedure Manifest_Version
     (Item        : in out Storage_Context;
      Manifest_ID : Identifier;
      Version     : out Interfaces.Unsigned_16;
      Result      : out Outcome_Code);
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
      Result                 : out Outcome_Code);
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
      Result                 : out Outcome_Code);
   procedure Live_Entry_Sequence
     (Item      : in out Database;
      Family_ID : Column_Family_ID;
      Item_Key  : Byte_Array;
      Sequence  : out Sequence_Number;
      Result    : out Outcome_Code);
   procedure Checkpoint_Buffer_Capacity
     (Item : in out Database; Maximum : out Natural; Result : out Outcome_Code);
   procedure Build_First_SST
     (Item             : in out Database;
      Family_ID        : Column_Family_ID;
      Run_ID           : Identifier;
      Entry_Total      : out Natural;
      Lowest_Sequence  : out Sequence_Number;
      Highest_Sequence : out Sequence_Number;
      Result           : out Outcome_Code);
   procedure Build_First_Checkpoint
     (Item            : in out Database;
      Runs            : Checkpoint_Run_Identity_Array;
      Manifest_ID     : Identifier;
      Transition_ID   : Identifier;
      Run_Total       : out Natural;
      Identity_Total  : out Natural;
      Replay_Boundary : out Sequence_Number;
      Result          : out Outcome_Code);
   procedure Publish_First_Checkpoint
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code);
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
      Result           : out Outcome_Code);
   procedure Publish_Compaction
     (Item          : in out Database;
      Runs          : Checkpoint_Run_Identity_Array;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code);
   procedure Publish_Adjacent_Merge
     (Item          : in out Database;
      Older_Run_ID  : Identifier;
      Newer_Run_ID  : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code);
   procedure Publish_Three_Run_Merge
     (Item          : in out Database;
      First_Run_ID  : Identifier;
      Middle_Run_ID : Identifier;
      Last_Run_ID   : Identifier;
      Output_Run_ID : Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Receipt       : out Flush_Receipt;
      Result        : out Outcome_Code);
   function Receipt_Replaces_Current_Runs (Item : Flush_Receipt) return Boolean;
   function Test_Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier;

end Flyology.DB.Testing;
