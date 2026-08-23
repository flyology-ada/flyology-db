with Interfaces;

private package Flyology.DB.Testing is

   subtype Fault_Point is Storage_Fault_Point;
   subtype Fault_Mode is Storage_Fault_Mode;

   --  Arm one deterministic storage fault for the next Count matching calls.
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

   function Attempted_Transition_Number (Item : Commit_Receipt) return Interfaces.Unsigned_64;

   procedure Pause_Coordinator (Item : in out Database; Result : out Outcome_Code);
   procedure Resume_Coordinator (Item : in out Database; Result : out Outcome_Code);
   procedure Queue_Depth (Item : in out Database; Value : out Natural; Result : out Outcome_Code);
   procedure Fail_Next_Install (Item : in out Database; Result : out Outcome_Code);
   procedure Pause_Gets (Item : in out Storage_Context);
   procedure Resume_Gets (Item : in out Storage_Context);
   procedure Wait_For_Get
     (Item : in out Storage_Context; Timeout : Duration; Arrived : out Boolean);
   function Get_Waiting (Item : Storage_Context) return Boolean;
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
   function Test_Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier;

end Flyology.DB.Testing;
