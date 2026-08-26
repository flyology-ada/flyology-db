with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Flyology.DB.Checkpoint_Policy;
with Flyology_TLA.Codecs;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;
with Interfaces;

procedure Flyology.DB.TLA_Conformance is

   use Ada.Strings.Unbounded;
   use type Checkpoint_Policy.Selection;

   package Policy renames Flyology.DB.Checkpoint_Policy;
   package Codecs renames Flyology_TLA.Codecs;

   --  These are private checked-trace fixture bounds, not DB limits or harness defaults.
   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 16_384,
      Maximum_Steps        => 4,
      Maximum_JSON_Depth   => 16,
      Maximum_Object_Names => 256,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 4_096,
      Maximum_Value_Bytes  => 8_192);

   type Checkpoint_Adapter is new Flyology_TLA.Replay.Adapter with record
      Buggy : Boolean := False;
   end record;

   overriding
   procedure Reset
     (Self                : in out Checkpoint_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self                  : in out Checkpoint_Adapter;
      Command               : Flyology_TLA.Replay.Replay_Command;
      Observed_Outcome_JSON : out Unbounded_String;
      Observed_State_JSON   : out Unbounded_String;
      Outcome               : out Flyology_TLA.Replay.Adapter_Outcome);

   function Member (Source : String; Name : String) return String
   is (Codecs.Object_Member (Source, Name, Limits));

   function Integer_Member (Source : String; Name : String) return Interfaces.Unsigned_32
   is (Interfaces.Unsigned_32 (Codecs.Decode_Integer (Member (Source, Name))));

   function Boolean_Member (Source : String; Name : String) return Boolean
   is (Codecs.Decode_Boolean (Member (Source, Name)));

   function Selection_Image (Item : Policy.Selection) return String
   is (case Item is
         when Policy.No_Work                  => "NoWork",
         when Policy.Additive_Flush           => "Additive",
         when Policy.Complete_Compaction      => "Complete",
         when Policy.No_Admissible_Checkpoint => "NoAdmissible",
         when Policy.Invalid_Authority        => "InvalidAuthority");

   function Observation_Image
     (Selection : Policy.Selection; Selected_1 : Boolean; Selected_2 : Boolean) return String is
   begin
      return
        "{""selection"":"
        & Codecs.Encode_String (Selection_Image (Selection))
        & ",""selected_f1"":"
        & Codecs.Encode_Boolean (Selected_1)
        & ",""selected_f2"":"
        & Codecs.Encode_Boolean (Selected_2)
        & "}";
   end Observation_Image;

   function State_Image
     (Selection : Policy.Selection; Selected_1 : Boolean; Selected_2 : Boolean) return String is
   begin
      return
        "{""phase"":"
        & Codecs.Encode_String ("Observed")
        & ",""action"":"
        & Codecs.Encode_String (Selection_Image (Selection))
        & ",""selected_f1"":"
        & Codecs.Encode_Boolean (Selected_1)
        & ",""selected_f2"":"
        & Codecs.Encode_Boolean (Selected_2)
        & "}";
   end State_Image;

   procedure Reset
     (Self                : in out Checkpoint_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Self);
   begin
      Observed_State_JSON :=
        To_Unbounded_String
          ("{""phase"":""Ready"",""action"":""Unobserved"",""selected_f1"":false,"
           & """selected_f2"":false}");
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   procedure Apply
     (Self                  : in out Checkpoint_Adapter;
      Command               : Flyology_TLA.Replay.Replay_Command;
      Observed_Outcome_JSON : out Unbounded_String;
      Observed_State_JSON   : out Unbounded_String;
      Outcome               : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      Source       : constant String := To_String (Command.Input_JSON);
      Current      : Policy.Run_Count_Array (1 .. 2);
      Maximum      : Policy.Run_Count_Array (1 .. 2);
      Changed      : Policy.Family_Flag_Array (1 .. 2);
      Nonempty     : Policy.Family_Flag_Array (1 .. 2);
      Decision     : Policy.Selection;
      Selected_1   : Boolean := False;
      Selected_2   : Boolean := False;
      Action       : constant String := To_String (Command.Action);
      Model_Source : constant String := To_String (Command.Model_Source);
   begin
      if Command.Index /= 1
        or else To_String (Command.Role) /= "checkpoint-selection"
        or else Action /= Model_Source
        or else Action
                not in "L0CheckpointNoWorkWitness!ObserveNoWork"
                     | "L0CheckpointAdditiveWitness!ObserveAdditive"
                     | "L0CheckpointSelectionWitness!ObserveComplete"
                     | "L0CheckpointNoAdmissibleWitness!ObserveNoAdmissible"
      then
         raise Codecs.Codec_Error with "unsupported checkpoint-selection trace command";
      elsif Codecs.Object_Size (Source, Limits) /= 10 then
         raise Codecs.Codec_Error with "unexpected checkpoint-selection input shape";
      end if;

      Current := [1 => Integer_Member (Source, "current_f1"), 2 => Integer_Member (Source, "current_f2")];
      Maximum := [1 => Integer_Member (Source, "maximum_f1"), 2 => Integer_Member (Source, "maximum_f2")];
      Changed := [1 => Boolean_Member (Source, "changed_f1"), 2 => Boolean_Member (Source, "changed_f2")];
      Nonempty := [1 => Boolean_Member (Source, "nonempty_f1"), 2 => Boolean_Member (Source, "nonempty_f2")];
      Decision :=
        Policy.Decide
          (Current,
           Maximum,
           Changed,
           Nonempty,
           Boolean_Member (Source, "dirty"),
           Integer_Member (Source, "total_maximum"));

      if Decision = Policy.Invalid_Authority then
         raise Codecs.Codec_Error with "model supplied invalid checkpoint authority";
      elsif Self.Buggy and then Decision = Policy.Complete_Compaction then
         Decision := Policy.Additive_Flush;
      end if;

      if Decision = Policy.Additive_Flush then
         Selected_1 := Changed (1);
         Selected_2 := Changed (2);
      elsif Decision = Policy.Complete_Compaction then
         Selected_1 := Nonempty (1);
         Selected_2 := Nonempty (2);
      end if;

      Observed_Outcome_JSON := To_Unbounded_String (Observation_Image (Decision, Selected_1, Selected_2));
      Observed_State_JSON := To_Unbounded_String (State_Image (Decision, Selected_1, Selected_2));
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : Codecs.Codec_Error | Constraint_Error =>
         Observed_Outcome_JSON := Null_Unbounded_String;
         Observed_State_JSON := Null_Unbounded_String;
         Outcome :=
           (Succeeded => False, Detail => To_Unbounded_String (Ada.Exceptions.Exception_Message (Error)));
   end Apply;

   Flags : Flyology_TLA.Command_Line.Application_Flag_Array :=
     [1 =>
        Flyology_TLA.Command_Line.Flag
          ("--buggy", "misclassify complete compaction to test divergence reporting")];

begin
   declare
      Config : Flyology_TLA.Command_Line.Configuration := Flyology_TLA.Command_Line.Parse (Limits, Flags);
   begin
      if Flyology_TLA.Command_Line.Help_Requested (Config) then
         Flyology_TLA.Command_Line.Put_Help (Flags);
         return;
      end if;

      declare
         Trace   : constant Flyology_TLA.Traces.Trace := Flyology_TLA.Command_Line.Load (Config);
         Adapter : Checkpoint_Adapter;
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         Adapter.Buggy := Flyology_TLA.Command_Line.Is_Set (Flags (1));
         Flyology_TLA.Replay.Run (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end;
exception
   when Error : Flyology_TLA.Command_Line.Usage_Error =>
      Flyology_TLA.Command_Line.Fail (Ada.Exceptions.Exception_Message (Error), Flags, Show_Help => True);
   when Error : Flyology_TLA.Traces.Trace_Error =>
      Flyology_TLA.Command_Line.Fail ("cannot load trace: " & Ada.Exceptions.Exception_Message (Error));
end Flyology.DB.TLA_Conformance;
