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

   function Attempted_Transition_Number (Item : Commit_Receipt) return Interfaces.Unsigned_64;

   procedure Pause_Coordinator (Item : in out Database; Result : out Outcome_Code);
   procedure Resume_Coordinator (Item : in out Database; Result : out Outcome_Code);
   procedure Queue_Depth (Item : in out Database; Value : out Natural; Result : out Outcome_Code);
   procedure Fail_Next_Install (Item : in out Database; Result : out Outcome_Code);
   procedure Pause_Gets (Item : in out Storage_Context);
   procedure Resume_Gets (Item : in out Storage_Context);
   function Get_Waiting (Item : Storage_Context) return Boolean;
   function Test_Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier;

end Flyology.DB.Testing;
