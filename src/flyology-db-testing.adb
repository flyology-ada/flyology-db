package body Flyology.DB.Testing is

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
     (Item : in out Storage_Context; Batch_Puts : out Natural; Head_Puts : out Natural) is
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

   procedure Wait_For_Get
     (Item : in out Storage_Context; Timeout : Duration; Arrived : out Boolean) is
   begin
      Wait_For_Test_Get (Item, Timeout, Arrived);
   end Wait_For_Get;

   function Get_Waiting (Item : Storage_Context) return Boolean
   is (Test_Get_Waiting (Item));

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
        (Item,
         Manifest_ID,
         Expected_Database_ID,
         Replacement_Database,
         Oversize_Family,
         False,
         0,
         0,
         Result);
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

   function Test_Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier
   is (Structural_ID (Tag, Number));

end Flyology.DB.Testing;
