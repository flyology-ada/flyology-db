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
   begin
      Item.Test_Control.Publication_Counts (Batch_Puts, Head_Puts);
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

   function Get_Waiting (Item : Storage_Context) return Boolean is
   begin
      return Test_Get_Waiting (Item);
   end Get_Waiting;

   function Test_Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier
   is (Structural_ID (Tag, Number));

end Flyology.DB.Testing;
