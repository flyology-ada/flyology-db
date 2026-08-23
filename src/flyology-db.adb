with Ada.Real_Time;
with Ada.Streams;
with Ada.Unchecked_Deallocation;
with Flyology.DB.Batch_Formats;
with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Flyology.Object_Storage;

package body Flyology.DB is

   package OS renames Flyology.Object_Storage;
   package Backends renames Flyology.Object_Storage.Backends;
   package Batches renames Flyology.DB.Batch_Formats;
   package Heads renames Flyology.DB.Head_Policy;
   package UStrings renames Ada.Strings.Unbounded;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Byte;
   use type Interfaces.Unsigned_64;
   use type Batches.Decode_Status;
   use type Batches.Encode_Status;
   use type Batches.Mutation_Kind;
   use type Flyology.DB.Formats.Decode_Status;
   use type OS.Status;

   Head_Key_Suffix   : constant String := "meta/HEAD";
   Commit_Key_Prefix : constant String := "commits/";

   subtype Generation_Length is Natural range 0 .. Maximum_Generation_Bytes;
   type Generation_Value is record
      Length : Generation_Length := 0;
      Data   : String (1 .. Maximum_Generation_Bytes) := [others => Character'Val (0)];
   end record;

   type Read_Outcome is
     (Object_Read,
      Object_Missing,
      Read_Precondition_Failed,
      Read_Cancelled,
      Read_Timed_Out,
      Read_Failed,
      Read_Corrupt);
   type Put_Outcome is
     (Object_Published,
      Put_Precondition_Failed,
      Put_Cancelled,
      Put_Timed_Out,
      Put_Definite_Failure,
      Put_Outcome_Unknown);

   type Object_Buffer is array (Batch_Receipt_Index) of Byte;

   type Buffer_Source is new Backends.Byte_Source with record
      Data   : Object_Buffer := [others => 0];
      Length : Natural range 0 .. Maximum_Batch_Image_Bytes := 0;
      Cursor : Natural range 0 .. Maximum_Batch_Image_Bytes := 0;
   end record;

   overriding
   function Declared_Length (Item : Buffer_Source) return Backends.Source_Length;

   overriding
   procedure Read
     (Item     : in out Buffer_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time);

   type Buffer_Sink is new Backends.Byte_Sink with record
      Data       : Object_Buffer := [others => 0];
      Length     : Natural range 0 .. Maximum_Batch_Image_Bytes := 0;
      Written    : Natural range 0 .. Maximum_Batch_Image_Bytes := 0;
      Begun      : Boolean := False;
      Overflowed : Boolean := False;
      Generation : Generation_Value;
   end record;

   overriding
   procedure Begin_Object
     (Item           : in out Buffer_Sink;
      Info           : OS.Object_Information;
      First          : OS.Byte_Count;
      Content_Length : OS.Byte_Count;
      Partial        : Boolean;
      Token          : access Flyology.Cancellation.Token;
      Deadline       : Ada.Real_Time.Time);

   overriding
   procedure Write
     (Item     : in out Buffer_Sink;
      Data     : Ada.Streams.Stream_Element_Array;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time);

   function Is_Zero (Item : Identifier) return Boolean
   is (Item = Zero_Identifier);

   function Is_Zero (Item : Database_Identifier) return Boolean
   is (Item = Zero_Database_ID);

   function Is_Zero (Item : Transaction_Identifier) return Boolean
   is (Item = Zero_Transaction_ID);

   function To_Head_ID (Item : Identifier) return Heads.Identifier
   is (Heads.Identifier (Item));

   function To_Head_ID (Item : Database_Identifier) return Heads.Identifier
   is (Heads.Identifier (Identifier (Item)));

   function To_Head_ID (Item : Transaction_Identifier) return Heads.Identifier
   is (Heads.Identifier (Identifier (Item)));

   function To_Identifier (Item : Heads.Identifier) return Identifier
   is (Identifier (Item));

   function To_Database_ID (Item : Heads.Identifier) return Database_Identifier
   is (Database_Identifier (Identifier (Item)));

   function To_Transaction_ID (Item : Heads.Identifier) return Transaction_Identifier
   is (Transaction_Identifier (Identifier (Item)));

   function Same_Key (Left, Right : Key) return Boolean
   is (Left.Length = Right.Length
       and then (Left.Length = 0 or else Left.Bytes (1 .. Left.Length) = Right.Bytes (1 .. Right.Length)));

   function To_Head (Item : Head_Snapshot) return Heads.Head_State
   is ((Database_ID            => To_Head_ID (Item.Database_ID),
        Version                => Heads.Current_Format,
        Epoch                  => Heads.Writer_Epoch (Item.Epoch),
        Highest_Visible        => Heads.Commit_Sequence (Item.Highest),
        Latest_Batch           => To_Head_ID (Item.Latest_Batch),
        Latest_Manifest        => To_Head_ID (Item.Latest_Manifest),
        Transition_ID          => To_Head_ID (Item.Transition_ID),
        Predecessor_Transition => To_Head_ID (Item.Predecessor_Transition),
        Transition_Number      => Heads.Transition_Ordinal (Item.Transition_Number)));

   function From_Head (Item : Heads.Head_State) return Head_Snapshot
   is ((Database_ID            => To_Database_ID (Item.Database_ID),
        Epoch                  => Interfaces.Unsigned_64 (Item.Epoch),
        Highest                => Sequence_Number (Item.Highest_Visible),
        Latest_Batch           => To_Identifier (Item.Latest_Batch),
        Latest_Manifest        => To_Identifier (Item.Latest_Manifest),
        Transition_ID          => To_Identifier (Item.Transition_ID),
        Predecessor_Transition => To_Identifier (Item.Predecessor_Transition),
        Transition_Number      => Interfaces.Unsigned_64 (Item.Transition_Number)));

   function Same_Head (Left, Right : Head_Snapshot) return Boolean
   is (Left = Right);

   function Deadline_After (Timeout : Duration) return Ada.Real_Time.Time is
   begin
      if Timeout <= 0.0 then
         return Ada.Real_Time.Clock;
      else
         return Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout);
      end if;
   exception
      when Constraint_Error =>
         return Ada.Real_Time.Time_Last;
   end Deadline_After;

   procedure Set_Generation (Target : out Generation_Value; Value : String) is
   begin
      Target := (others => <>);
      if Value'Length <= Maximum_Generation_Bytes then
         Target.Length := Value'Length;
         if Value'Length > 0 then
            Target.Data (1 .. Value'Length) := Value;
         end if;
      end if;
   end Set_Generation;

   function Generation_String (Item : Generation_Value) return String
   is (if Item.Length = 0 then "" else Item.Data (1 .. Item.Length));

   function Full_Key (Storage : Storage_Context; Suffix : String) return String
   is (UStrings.To_String (Storage.Prefix) & "/" & Suffix);

   function Hex_Character (Value : Byte) return Character is
      Hex_Digits : constant String := "0123456789abcdef";
   begin
      return Hex_Digits (Natural (Value) + 1);
   end Hex_Character;

   function Identifier_Hex (Item : Identifier) return String is
      Result : String (1 .. Identifier_Length * 2);
   begin
      for Index in Identifier_Index loop
         Result ((Index - 1) * 2 + 1) := Hex_Character (Item (Index) / 16);
         Result ((Index - 1) * 2 + 2) := Hex_Character (Item (Index) mod 16);
      end loop;
      return Result;
   end Identifier_Hex;

   function Batch_Key (Storage : Storage_Context; Batch_ID : Identifier) return String
   is (Full_Key (Storage, Commit_Key_Prefix & Identifier_Hex (Batch_ID)));

   function Structural_ID (Tag : Byte; Number : Interfaces.Unsigned_64) return Identifier is
      Result : Identifier := [others => 0];
   begin
      Result (1) := Tag;
      for Offset in Natural range 0 .. 7 loop
         Result (Identifier_Length - Offset) := Byte (Interfaces.Shift_Right (Number, Offset * 8) and 16#FF#);
      end loop;
      return Result;
   end Structural_ID;

   procedure Consume_Fault
     (Storage : in out Storage_Context; Point : Storage_Fault_Point; Mode : out Storage_Fault_Mode) is
   begin
      Storage.Test_Control.Consume (Point, Mode);
   end Consume_Fault;

   protected body Storage_Test_Control is

      procedure Arm (Point : Storage_Fault_Point; Mode : Storage_Fault_Mode; Count : Positive) is
      begin
         Fault_Modes (Point) := Mode;
         Fault_Counts (Point) := Count;
      end Arm;

      procedure Clear is
      begin
         Fault_Modes := [others => No_Fault];
         Fault_Counts := [others => 0];
      end Clear;

      procedure Consume (Point : Storage_Fault_Point; Mode : out Storage_Fault_Mode) is
      begin
         Mode := No_Fault;
         if Fault_Counts (Point) > 0 then
            Mode := Fault_Modes (Point);
            Fault_Counts (Point) := Fault_Counts (Point) - 1;
            if Fault_Counts (Point) = 0 then
               Fault_Modes (Point) := No_Fault;
            end if;
         end if;
      end Consume;

      procedure Record_Put (Is_Head : Boolean) is
      begin
         if Is_Head then
            if Head_Puts < Natural'Last then
               Head_Puts := Head_Puts + 1;
            end if;
         else
            if Batch_Puts < Natural'Last then
               Batch_Puts := Batch_Puts + 1;
            end if;
         end if;
      end Record_Put;

      procedure Publication_Counts (Batch_Total : out Natural; Head_Total : out Natural) is
      begin
         Batch_Total := Batch_Puts;
         Head_Total := Head_Puts;
      end Publication_Counts;

      procedure Set_Get_Paused (Value : Boolean) is
      begin
         Get_Paused := Value;
      end Set_Get_Paused;

      procedure Arrive_Get is
      begin
         if Get_Paused and then Waiting_Gets < Natural'Last then
            Waiting_Gets := Waiting_Gets + 1;
         end if;
      end Arrive_Get;

      entry Continue_Get when not Get_Paused is
      begin
         if Waiting_Gets > 0 then
            Waiting_Gets := Waiting_Gets - 1;
         end if;
      end Continue_Get;

      function Get_Waiting return Boolean
      is (Waiting_Gets > 0);

   end Storage_Test_Control;

   package Storage_Port is
      procedure Bucket_Available
        (Storage  : in out Storage_Context;
         Deadline : Ada.Real_Time.Time;
         Token    : access Flyology.Cancellation.Token;
         Result   : out Outcome_Code);

      procedure Get_Whole
        (Storage    : in out Storage_Context;
         Key        : String;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Data       : out Object_Buffer;
         Length     : out Natural;
         Generation : out Generation_Value;
         Result     : out Read_Outcome);

      procedure Put_Create
        (Storage    : in out Storage_Context;
         Key        : String;
         Data       : Object_Buffer;
         Length     : Natural;
         Is_Head    : Boolean;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome);

      procedure Put_Replace
        (Storage    : in out Storage_Context;
         Key        : String;
         Data       : Object_Buffer;
         Length     : Natural;
         Expected   : Generation_Value;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome);
   end Storage_Port;

   overriding
   function Declared_Length (Item : Buffer_Source) return Backends.Source_Length
   is ((Kind => Backends.Known, Bytes => OS.Byte_Count (Item.Length)));

   overriding
   procedure Read
     (Item     : in out Buffer_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time)
   is
      pragma Unreferenced (Deadline);
      Count : Natural;
   begin
      Last := Data'First - 1;
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      elsif Item.Cursor = Item.Length then
         Finished := True;
         return;
      end if;
      Count := Natural'Min (Data'Length, Item.Length - Item.Cursor);
      for Offset in Natural range 0 .. Count - 1 loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Ada.Streams.Stream_Element (Item.Data (Item.Cursor + Offset));
      end loop;
      Item.Cursor := Item.Cursor + Count;
      Last := Data'First + Ada.Streams.Stream_Element_Offset (Count) - 1;
      Finished := Item.Cursor = Item.Length;
   end Read;

   overriding
   procedure Begin_Object
     (Item           : in out Buffer_Sink;
      Info           : OS.Object_Information;
      First          : OS.Byte_Count;
      Content_Length : OS.Byte_Count;
      Partial        : Boolean;
      Token          : access Flyology.Cancellation.Token;
      Deadline       : Ada.Real_Time.Time)
   is
      pragma Unreferenced (First, Partial, Deadline);
      Raw_Generation : constant String := UStrings.To_String (Info.Entity_Tag);
   begin
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
      Item.Begun := True;
      if Content_Length > OS.Byte_Count (Maximum_Batch_Image_Bytes)
        or else Raw_Generation'Length > Maximum_Generation_Bytes
      then
         Item.Overflowed := True;
      else
         Item.Length := Natural (Content_Length);
         Set_Generation (Item.Generation, Raw_Generation);
      end if;
   end Begin_Object;

   overriding
   procedure Write
     (Item     : in out Buffer_Sink;
      Data     : Ada.Streams.Stream_Element_Array;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time)
   is
      pragma Unreferenced (Deadline);
   begin
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      elsif Item.Overflowed then
         return;
      elsif Data'Length > Item.Length - Item.Written then
         Item.Overflowed := True;
         return;
      end if;
      for Offset in Natural range 0 .. Data'Length - 1 loop
         Item.Data (Item.Written + Offset) :=
           Byte (Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)));
      end loop;
      Item.Written := Item.Written + Data'Length;
   end Write;

   package body Storage_Port is

      procedure Bucket_Available
        (Storage  : in out Storage_Context;
         Deadline : Ada.Real_Time.Time;
         Token    : access Flyology.Cancellation.Token;
         Result   : out Outcome_Code)
      is
         Status : OS.Status;
      begin
         if Storage.Backend = null then
            Result := Invalid_State;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            return;
         end if;
         Storage.Backend.Head_Bucket
           (Bucket   => UStrings.To_String (Storage.Bucket),
            Token    => Token,
            Deadline => Deadline,
            Result   => Status);
         case Status is
            when OS.Success                         =>
               Result := Success;

            when OS.Not_Found | OS.Bucket_Not_Found =>
               Result := Not_Found;

            when others                             =>
               Result := Storage_Failure;
         end case;
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Result := Cancelled;
         when others =>
            if Deadline <= Ada.Real_Time.Clock then
               Result := Timed_Out;
            else
               Result := Storage_Failure;
            end if;
      end Bucket_Available;

      procedure Get_Whole
        (Storage    : in out Storage_Context;
         Key        : String;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Data       : out Object_Buffer;
         Length     : out Natural;
         Generation : out Generation_Value;
         Result     : out Read_Outcome)
      is
         Sink   : Buffer_Sink;
         Info   : OS.Object_Information;
         Status : OS.Status;
         Fault  : Storage_Fault_Mode;
      begin
         Data := [others => 0];
         Length := 0;
         Generation := (others => <>);
         Storage.Test_Control.Arrive_Get;
         Storage.Test_Control.Continue_Get;
         Consume_Fault (Storage, Before_Get, Fault);
         if Fault /= No_Fault then
            Result := Read_Failed;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Read_Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Read_Timed_Out;
            return;
         end if;
         Storage.Backend.Get_Object
           (Bucket     => UStrings.To_String (Storage.Bucket),
            Key        => Key,
            Requested  => OS.Whole_Object,
            Sink       => Sink,
            Token      => Token,
            Deadline   => Deadline,
            Info       => Info,
            Result     => Status,
            Conditions => Backends.Default_Read_Conditions);
         case Status is
            when OS.Success                               =>
               if not Sink.Begun
                 or else Sink.Overflowed
                 or else Sink.Written /= Sink.Length
                 or else Sink.Generation.Length = 0
                 or else UStrings.To_String (Info.Entity_Tag) /= Generation_String (Sink.Generation)
               then
                  Result := Read_Corrupt;
               else
                  Data := Sink.Data;
                  Length := Sink.Length;
                  Generation := Sink.Generation;
                  Result := Object_Read;
               end if;

            when OS.Not_Found | OS.Bucket_Not_Found       =>
               Result := Object_Missing;

            when OS.Precondition_Failed | OS.Not_Modified =>
               Result := Read_Precondition_Failed;

            when others                                   =>
               Result := Read_Failed;
         end case;
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Result := Read_Cancelled;
         when others =>
            if Deadline <= Ada.Real_Time.Clock then
               Result := Read_Timed_Out;
            else
               Result := Read_Failed;
            end if;
      end Get_Whole;

      procedure Put_Common
        (Storage      : in out Storage_Context;
         Key          : String;
         Data         : Object_Buffer;
         Length       : Natural;
         Conditions   : OS.Write_Conditions;
         Before_Point : Storage_Fault_Point;
         After_Point  : Storage_Fault_Point;
         Deadline     : Ada.Real_Time.Time;
         Token        : access Flyology.Cancellation.Token;
         Generation   : out Generation_Value;
         Result       : out Put_Outcome)
      is
         Source  : Buffer_Source;
         Info    : OS.Object_Information;
         Status  : OS.Status;
         Fault   : Storage_Fault_Mode;
         Entered : Boolean := False;
      begin
         Generation := (others => <>);
         Consume_Fault (Storage, Before_Point, Fault);
         if Fault = Definite_Failure then
            Result := Put_Definite_Failure;
            return;
         elsif Fault = Unknown_After_Entry then
            Result := Put_Outcome_Unknown;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Put_Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Put_Timed_Out;
            return;
         end if;
         Source.Data := Data;
         Source.Length := Length;
         Entered := True;
         Storage.Test_Control.Record_Put (Before_Point = Before_Head_Put);
         Storage.Backend.Put_Object
           (Bucket     => UStrings.To_String (Storage.Bucket),
            Key        => Key,
            Source     => Source,
            Options    => OS.Default_Put_Options,
            Token      => Token,
            Deadline   => Deadline,
            Info       => Info,
            Result     => Status,
            Conditions => Conditions);
         Consume_Fault (Storage, After_Point, Fault);
         if Fault /= No_Fault then
            Result := Put_Outcome_Unknown;
         elsif Status = OS.Success then
            if UStrings.Length (Info.Entity_Tag) = 0
              or else UStrings.Length (Info.Entity_Tag) > Maximum_Generation_Bytes
            then
               Result := Put_Outcome_Unknown;
            else
               Set_Generation (Generation, UStrings.To_String (Info.Entity_Tag));
               Result := Object_Published;
            end if;
         elsif Status = OS.Precondition_Failed then
            Result := Put_Precondition_Failed;
         elsif Status = OS.Backend_Unavailable then
            Result := Put_Outcome_Unknown;
         else
            Result := Put_Definite_Failure;
         end if;
      exception
         when others =>
            if Entered then
               Result := Put_Outcome_Unknown;
            elsif Token /= null and then Token.Requested then
               Result := Put_Cancelled;
            elsif Deadline <= Ada.Real_Time.Clock then
               Result := Put_Timed_Out;
            else
               Result := Put_Definite_Failure;
            end if;
      end Put_Common;

      procedure Put_Create
        (Storage    : in out Storage_Context;
         Key        : String;
         Data       : Object_Buffer;
         Length     : Natural;
         Is_Head    : Boolean;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome)
      is
         Conditions   : OS.Write_Conditions := OS.Default_Write_Conditions;
         Before_Point : constant Storage_Fault_Point :=
           (if Is_Head then Before_Head_Put else Before_Batch_Put);
         After_Point  : constant Storage_Fault_Point := (if Is_Head then After_Head_Put else After_Batch_Put);
      begin
         Conditions.If_None_Match := UStrings.To_Unbounded_String ("*");
         Put_Common
           (Storage,
            Key,
            Data,
            Length,
            Conditions,
            Before_Point,
            After_Point,
            Deadline,
            Token,
            Generation,
            Result);
      end Put_Create;

      procedure Put_Replace
        (Storage    : in out Storage_Context;
         Key        : String;
         Data       : Object_Buffer;
         Length     : Natural;
         Expected   : Generation_Value;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome)
      is
         Conditions : OS.Write_Conditions := OS.Default_Write_Conditions;
      begin
         Conditions.If_Match := UStrings.To_Unbounded_String ('"' & Generation_String (Expected) & '"');
         Put_Common
           (Storage,
            Key,
            Data,
            Length,
            Conditions,
            Before_Head_Put,
            After_Head_Put,
            Deadline,
            Token,
            Generation,
            Result);
      end Put_Replace;

   end Storage_Port;

   subtype Commit_Slot is Positive range 1 .. Maximum_Commit_Slots;
   subtype Group_Count is Natural range 0 .. Maximum_Commit_Slots;

   type Work_Item is record
      Transaction_ID : Transaction_Identifier := Zero_Transaction_ID;
      Mutation_Count : Natural range 0 .. Maximum_Transaction_Mutations := 0;
      Bytes_Used     : Natural range 0 .. Maximum_Transaction_Bytes := 0;
      Mutations      : Pending_Mutation_Array;
      Deadline       : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Batch_ID       : Identifier := Zero_Identifier;
      Group_ID       : Interfaces.Unsigned_64 := 0;
      Group_Member   : Commit_Slot := Commit_Slot'First;
   end record;
   type Work_Group is array (Commit_Slot) of Work_Item;

   type Slot_Token is record
      Index      : Commit_Slot := Commit_Slot'First;
      Generation : Interfaces.Unsigned_64 := 0;
   end record;
   type Token_Group is array (Commit_Slot) of Slot_Token;
   type Receipt_Group is array (Commit_Slot) of Commit_Receipt;

   type Slot_State is (Free, Queued, Running, Completed);
   type Completion_Slot is record
      State      : Slot_State := Free;
      Generation : Interfaces.Unsigned_64 := 0;
      Order      : Interfaces.Unsigned_64 := 0;
      Work       : Work_Item;
      Receipt    : Commit_Receipt;
      Result     : Outcome_Code := Invalid_State;
   end record;
   type Completion_Array is array (Commit_Slot) of Completion_Slot;

   type State_Entry is record
      Family   : Column_Family_ID := Column_Family_ID'First;
      Item_Key : Key;
      Data     : Value;
   end record;
   subtype State_Entry_Slot is Positive range 1 .. Maximum_State_Entries;
   type State_Entry_Array is array (State_Entry_Slot) of State_Entry;
   subtype Seen_Transaction_Slot is Positive range 1 .. Maximum_Seen_Transactions;
   type Seen_Transaction_Array is array (Seen_Transaction_Slot) of Transaction_Identifier;
   subtype Used_Batch_Slot is Positive range 1 .. Maximum_History_Batches;
   type Used_Batch_ID_Array is array (Used_Batch_Slot) of Identifier;
   subtype Reserved_Identity_Slot is Positive range 1 .. Maximum_Reserved_Identities;
   type Reserved_Identity_Array is array (Reserved_Identity_Slot) of Identifier;

   protected type Coordinator is
      procedure Initialize (Head : Head_Snapshot; Generation : Generation_Value);

      procedure Recover_Batch (Batch : Batches.Commit_Batch; Result : out Outcome_Code);

      procedure Transaction_Available (Transaction_ID : Transaction_Identifier; Result : out Outcome_Code);

      procedure Admit
        (Txn      : Transaction;
         Deadline : Ada.Real_Time.Time;
         Token    : access Flyology.Cancellation.Token;
         Slot     : out Slot_Token;
         Result   : out Outcome_Code);

      procedure Admit_Group
        (Transactions : Transaction_Array;
         Batch_ID     : Identifier;
         Deadline     : Ada.Real_Time.Time;
         Token        : access Flyology.Cancellation.Token;
         Tokens       : out Token_Group;
         Count        : out Group_Count;
         Result       : out Outcome_Code);

      entry Take_Group
        (Items      : out Work_Group;
         Tokens     : out Token_Group;
         Count      : out Group_Count;
         Head       : out Head_Snapshot;
         Generation : out Generation_Value;
         Stop       : out Boolean);

      procedure Prepublication_Check (Items : Work_Group; Count : Group_Count; Result : out Outcome_Code);

      procedure Complete_Group
        (Tokens         : Token_Group;
         Receipts       : Receipt_Group;
         Count          : Group_Count;
         Result         : Outcome_Code;
         Mark_Uncertain : Boolean;
         Mark_Fenced    : Boolean);

      entry Await_Result (Commit_Slot)
        (Generation : Interfaces.Unsigned_64; Receipt : out Commit_Receipt; Result : out Outcome_Code);

      procedure Install_Published
        (Batch      : Batches.Commit_Batch;
         Head       : Head_Snapshot;
         Generation : Generation_Value;
         Result     : out Outcome_Code);

      procedure Snapshot
        (Head         : out Head_Snapshot;
         Generation   : out Generation_Value;
         Is_Uncertain : out Boolean;
         Is_Fenced    : out Boolean);

      procedure Lookup
        (Family : Column_Family_ID; Item_Key : Key; Data : out Value; Result : out Outcome_Code);

      procedure Fence;
      procedure Set_Paused (Value : Boolean);
      function Queue_Depth return Natural;
      procedure Fail_Next_Install;
      procedure Request_Close;
      procedure Mark_Stopped;
      entry Join;
      function Highest return Sequence_Number;
   private
      Slots           : Completion_Array;
      Queue_Order     : Interfaces.Unsigned_64 := 0;
      In_Use_Count    : Natural range 0 .. Maximum_Commit_Slots := 0;
      Queued_Count    : Natural range 0 .. Maximum_Commit_Slots := 0;
      In_Flight_Bytes : Natural range 0 .. Maximum_Commit_Bytes := 0;
      Current_Head    : Head_Snapshot;
      Head_Generation : Generation_Value;
      Entries         : State_Entry_Array;
      Entry_Count     : Natural range 0 .. Maximum_State_Entries := 0;
      Seen            : Seen_Transaction_Array := [others => Zero_Transaction_ID];
      Seen_Count      : Natural range 0 .. Maximum_Seen_Transactions := 0;
      Used_Batches    : Used_Batch_ID_Array := [others => Zero_Identifier];
      History_Count   : Natural range 0 .. Maximum_History_Batches := 0;
      Reserved        : Reserved_Identity_Array := [others => Zero_Identifier];
      Reserved_Count  : Natural range 0 .. Maximum_Reserved_Identities := 0;
      Uncertain       : Boolean := False;
      Fenced          : Boolean := False;
      Closing         : Boolean := False;
      Stopped         : Boolean := False;
      Paused          : Boolean := False;
      Fail_Install    : Boolean := False;
   end Coordinator;

   protected body Coordinator is

      procedure Initialize (Head : Head_Snapshot; Generation : Generation_Value) is
      begin
         Current_Head := Head;
         Head_Generation := Generation;
      end Initialize;

      procedure Apply_Batch
        (Batch : Batches.Commit_Batch; Identities_Reserved : Boolean; Result : out Outcome_Code)
      is
         Found                 : Natural;
         Identity_Found        : Boolean;
         Batch_ID              : constant Identifier := To_Identifier (Batch.Batch_ID);
         Additional_Identities : Natural := Batch.Transaction_Total;
      begin
         if Batch.Transaction_Total = 0 then
            Result := Corrupt;
            return;
         elsif Batch.Transaction_Total /= 1
           or else To_Identifier (Batch.Transactions (1).Transaction_ID) /= Batch_ID
         then
            Additional_Identities := Additional_Identities + 1;
         end if;
         if History_Count = Maximum_History_Batches
           or else Seen_Count + Batch.Transaction_Total > Maximum_Seen_Transactions
           or else (not Identities_Reserved
                    and then Reserved_Count > Maximum_Reserved_Identities - Additional_Identities)
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Existing in Positive range 1 .. History_Count loop
            if Used_Batches (Existing) = Batch_ID then
               Result := Corrupt;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. Seen_Count loop
            if Identifier (Seen (Existing)) = Batch_ID then
               Result := Corrupt;
               return;
            end if;
         end loop;
         Identity_Found := False;
         for Existing in Positive range 1 .. Reserved_Count loop
            Identity_Found := Identity_Found or else Reserved (Existing) = Batch_ID;
         end loop;
         if Identity_Found /= Identities_Reserved then
            Result := Corrupt;
            return;
         end if;
         for Transaction_Index in Batches.Transaction_Slot range 1 .. Batch.Transaction_Total loop
            declare
               Transaction_ID : constant Transaction_Identifier :=
                 To_Transaction_ID (Batch.Transactions (Transaction_Index).Transaction_ID);
            begin
               if Batch.Transaction_Total > 1 and then Identifier (Transaction_ID) = Batch_ID then
                  Result := Corrupt;
                  return;
               end if;
               for Existing in Positive range 1 .. Seen_Count loop
                  if Seen (Existing) = Transaction_ID then
                     Result := Corrupt;
                     return;
                  end if;
               end loop;
               for Existing in Positive range 1 .. History_Count loop
                  if Used_Batches (Existing) = Identifier (Transaction_ID) then
                     Result := Corrupt;
                     return;
                  end if;
               end loop;
               Identity_Found := False;
               for Existing in Positive range 1 .. Reserved_Count loop
                  Identity_Found := Identity_Found or else Reserved (Existing) = Identifier (Transaction_ID);
               end loop;
               if Identity_Found /= Identities_Reserved then
                  Result := Corrupt;
                  return;
               end if;
            end;
         end loop;
         for Mutation_Index in Batches.Mutation_Slot range 1 .. Batch.Mutation_Total loop
            declare
               Mutation : Batches.Mutation renames Batch.Mutations (Mutation_Index);
               Item_Key : Key;
               Data     : Value;
            begin
               Item_Key.Length := Key_Length (Mutation.Key_Size);
               for Byte_Index in Positive range 1 .. Item_Key.Length loop
                  Item_Key.Bytes (Byte_Index) := Mutation.Key (Byte_Index);
               end loop;
               Data.Length := Value_Length (Mutation.Value_Size);
               for Byte_Index in Positive range 1 .. Data.Length loop
                  Data.Bytes (Byte_Index) := Mutation.Value (Byte_Index);
               end loop;
               Found := 0;
               for Existing in Positive range 1 .. Entry_Count loop
                  if Entries (Existing).Family = Column_Family_ID (Mutation.Column_Family)
                    and then Same_Key (Entries (Existing).Item_Key, Item_Key)
                  then
                     Found := Existing;
                     exit;
                  end if;
               end loop;
               if Mutation.Operation = Batches.Put then
                  if Found = 0 then
                     if Entry_Count = Maximum_State_Entries then
                        Result := Capacity_Exceeded;
                        return;
                     end if;
                     Entry_Count := Entry_Count + 1;
                     Found := Entry_Count;
                  end if;
                  Entries (Found) :=
                    (Family => Column_Family_ID (Mutation.Column_Family), Item_Key => Item_Key, Data => Data);
               elsif Found > 0 then
                  for Existing in Found .. Entry_Count - 1 loop
                     Entries (Existing) := Entries (Existing + 1);
                  end loop;
                  Entry_Count := Entry_Count - 1;
               end if;
            end;
         end loop;
         if not Identities_Reserved and then Additional_Identities > Batch.Transaction_Total then
            Reserved_Count := Reserved_Count + 1;
            Reserved (Reserved_Count) := Batch_ID;
         end if;
         for Transaction_Index in Batches.Transaction_Slot range 1 .. Batch.Transaction_Total loop
            Seen_Count := Seen_Count + 1;
            Seen (Seen_Count) := To_Transaction_ID (Batch.Transactions (Transaction_Index).Transaction_ID);
            if not Identities_Reserved then
               Reserved_Count := Reserved_Count + 1;
               Reserved (Reserved_Count) :=
                 To_Identifier (Batch.Transactions (Transaction_Index).Transaction_ID);
            end if;
         end loop;
         History_Count := History_Count + 1;
         Used_Batches (History_Count) := Batch_ID;
         Result := Success;
      end Apply_Batch;

      procedure Recover_Batch (Batch : Batches.Commit_Batch; Result : out Outcome_Code) is
      begin
         Apply_Batch (Batch, False, Result);
      end Recover_Batch;

      procedure Transaction_Available (Transaction_ID : Transaction_Identifier; Result : out Outcome_Code) is
      begin
         if Closing then
            Result := Invalid_State;
            return;
         elsif Fenced then
            Result := Stale_Writer;
            return;
         elsif Stopped then
            Result := Storage_Failure;
            return;
         elsif Uncertain then
            Result := Outcome_Unknown;
            return;
         end if;
         for Existing in Positive range 1 .. Seen_Count loop
            if Seen (Existing) = Transaction_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. History_Count loop
            if Used_Batches (Existing) = Identifier (Transaction_ID) then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. Reserved_Count loop
            if Reserved (Existing) = Identifier (Transaction_ID) then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Index in Commit_Slot loop
            if Slots (Index).State /= Free
              and then (Slots (Index).Work.Transaction_ID = Transaction_ID
                        or else Slots (Index).Work.Batch_ID = Identifier (Transaction_ID))
            then
               Result := Conflict;
               return;
            end if;
         end loop;
         Result := Success;
      end Transaction_Available;

      procedure Admit
        (Txn      : Transaction;
         Deadline : Ada.Real_Time.Time;
         Token    : access Flyology.Cancellation.Token;
         Slot     : out Slot_Token;
         Result   : out Outcome_Code)
      is
         Selected           : Commit_Slot := Commit_Slot'First;
         Candidate_Batch_ID : constant Identifier := Identifier (Txn.Transaction_ID);
         Put_Count          : Natural := 0;
      begin
         Slot := (others => <>);
         if Closing then
            Result := Invalid_State;
            return;
         elsif Fenced then
            Result := Stale_Writer;
            return;
         elsif Stopped then
            Result := Storage_Failure;
            return;
         elsif Uncertain then
            Result := Outcome_Unknown;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            return;
         elsif In_Use_Count = Maximum_Commit_Slots
           or else In_Flight_Bytes > Maximum_Commit_Bytes - Txn.Bytes_Used
           or else History_Count = Maximum_History_Batches
           or else Seen_Count = Maximum_Seen_Transactions
           or else Reserved_Count = Maximum_Reserved_Identities
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Index in Mutation_Slot range 1 .. Txn.Mutation_Count loop
            if Txn.Mutations (Index).Operation = Put_Mutation then
               Put_Count := Put_Count + 1;
            end if;
         end loop;
         if Entry_Count > Maximum_State_Entries - Put_Count then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Existing in Positive range 1 .. Seen_Count loop
            if Seen (Existing) = Txn.Transaction_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. History_Count loop
            if Used_Batches (Existing) = Candidate_Batch_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Index in Commit_Slot loop
            if Slots (Index).State /= Free
              and then (Slots (Index).Work.Transaction_ID = Txn.Transaction_ID
                        or else Slots (Index).Work.Batch_ID = Candidate_Batch_ID)
            then
               Result := Conflict;
               return;
            elsif Slots (Index).State = Free then
               Selected := Index;
            end if;
         end loop;
         for Existing in Positive range 1 .. Reserved_Count loop
            if Reserved (Existing) = Candidate_Batch_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         if Queue_Order = Interfaces.Unsigned_64'Last
           or else Slots (Selected).Generation = Interfaces.Unsigned_64'Last
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         Reserved_Count := Reserved_Count + 1;
         Reserved (Reserved_Count) := Candidate_Batch_ID;
         Queue_Order := Queue_Order + 1;
         Slots (Selected).Generation := Slots (Selected).Generation + 1;
         Slots (Selected).Order := Queue_Order;
         Slots (Selected).Work.Transaction_ID := Txn.Transaction_ID;
         Slots (Selected).Work.Mutation_Count := Txn.Mutation_Count;
         Slots (Selected).Work.Bytes_Used := Txn.Bytes_Used;
         Slots (Selected).Work.Deadline := Deadline;
         Slots (Selected).Work.Batch_ID := Candidate_Batch_ID;
         Slots (Selected).Work.Group_ID := Queue_Order;
         Slots (Selected).Work.Group_Member := Commit_Slot'First;
         Slots (Selected).Receipt := (others => <>);
         Slots (Selected).Receipt.Transaction_ID := Txn.Transaction_ID;
         Slots (Selected).Receipt.Batch_ID := Candidate_Batch_ID;
         Slots (Selected).Receipt.Expected_Head := Current_Head;
         for Index in Mutation_Slot range 1 .. Txn.Mutation_Count loop
            Slots (Selected).Work.Mutations (Index) := Txn.Mutations (Index);
         end loop;
         Slots (Selected).State := Queued;
         In_Use_Count := In_Use_Count + 1;
         Queued_Count := Queued_Count + 1;
         In_Flight_Bytes := In_Flight_Bytes + Txn.Bytes_Used;
         Slot := (Index => Selected, Generation => Slots (Selected).Generation);
         Result := Success;
      end Admit;

      procedure Admit_Group
        (Transactions : Transaction_Array;
         Batch_ID     : Identifier;
         Deadline     : Ada.Real_Time.Time;
         Token        : access Flyology.Cancellation.Token;
         Tokens       : out Token_Group;
         Count        : out Group_Count;
         Result       : out Outcome_Code)
      is
         Total_Bytes     : Natural := 0;
         Total_Mutations : Natural := 0;
         Put_Count       : Natural := 0;
         Selected        : Commit_Slot;
      begin
         Tokens := [others => <>];
         Count := 0;
         if Closing then
            Result := Invalid_State;
            return;
         elsif Fenced then
            Result := Stale_Writer;
            return;
         elsif Stopped then
            Result := Storage_Failure;
            return;
         elsif Uncertain then
            Result := Outcome_Unknown;
            return;
         elsif Transactions'Length < 2 then
            Result := Invalid_State;
            return;
         elsif Transactions'Length > Maximum_Group_Transactions then
            Result := Capacity_Exceeded;
            return;
         elsif Is_Zero (Batch_ID) then
            Result := Invalid_State;
            return;
         elsif Token /= null and then Token.Requested then
            Result := Cancelled;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            return;
         elsif In_Use_Count > Maximum_Commit_Slots - Transactions'Length then
            Result := Capacity_Exceeded;
            return;
         elsif History_Count = Maximum_History_Batches
           or else Seen_Count > Maximum_Seen_Transactions - Transactions'Length
           or else Reserved_Count > Maximum_Reserved_Identities - (Transactions'Length + 1)
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Existing in Positive range 1 .. History_Count loop
            if Used_Batches (Existing) = Batch_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Index in Commit_Slot loop
            if Slots (Index).State /= Free
              and then (Slots (Index).Work.Batch_ID = Batch_ID
                        or else Identifier (Slots (Index).Work.Transaction_ID) = Batch_ID)
            then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Existing in Positive range 1 .. Reserved_Count loop
            if Reserved (Existing) = Batch_ID then
               Result := Conflict;
               return;
            end if;
         end loop;
         for Offset in Natural range 0 .. Transactions'Length - 1 loop
            declare
               Item : Transaction renames Transactions (Transactions'First + Offset);
            begin
               if not Item.Active or else Item.Mutation_Count = 0 then
                  Result := Invalid_State;
                  return;
               elsif Identifier (Item.Transaction_ID) = Batch_ID then
                  Result := Conflict;
                  return;
               elsif Total_Bytes > Maximum_Commit_Bytes - Item.Bytes_Used
                 or else Total_Mutations > Batches.Max_Mutations - Item.Mutation_Count
               then
                  Result := Capacity_Exceeded;
                  return;
               end if;
               Total_Bytes := Total_Bytes + Item.Bytes_Used;
               Total_Mutations := Total_Mutations + Item.Mutation_Count;
               for Index in Mutation_Slot range 1 .. Item.Mutation_Count loop
                  if Item.Mutations (Index).Operation = Put_Mutation then
                     Put_Count := Put_Count + 1;
                  end if;
               end loop;
               for Existing in Positive range 1 .. Seen_Count loop
                  if Seen (Existing) = Item.Transaction_ID then
                     Result := Conflict;
                     return;
                  end if;
               end loop;
               for Existing in Positive range 1 .. History_Count loop
                  if Used_Batches (Existing) = Identifier (Item.Transaction_ID) then
                     Result := Conflict;
                     return;
                  end if;
               end loop;
               for Existing in Positive range 1 .. Reserved_Count loop
                  if Reserved (Existing) = Identifier (Item.Transaction_ID) then
                     Result := Conflict;
                     return;
                  end if;
               end loop;
               for Index in Commit_Slot loop
                  if Slots (Index).State /= Free
                    and then (Slots (Index).Work.Transaction_ID = Item.Transaction_ID
                              or else Slots (Index).Work.Batch_ID = Identifier (Item.Transaction_ID))
                  then
                     Result := Conflict;
                     return;
                  end if;
               end loop;
               if Offset > 0 then
                  for Previous in Natural range 0 .. Offset - 1 loop
                     if Transactions (Transactions'First + Previous).Transaction_ID = Item.Transaction_ID then
                        Result := Conflict;
                        return;
                     end if;
                  end loop;
               end if;
            end;
         end loop;
         if Put_Count > Maximum_State_Entries - Entry_Count then
            Result := Capacity_Exceeded;
            return;
         end if;
         if Total_Bytes > Maximum_Commit_Bytes - In_Flight_Bytes
           or else Queue_Order = Interfaces.Unsigned_64'Last
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Index in Commit_Slot loop
            if Slots (Index).State = Free and then Slots (Index).Generation = Interfaces.Unsigned_64'Last then
               Result := Capacity_Exceeded;
               return;
            end if;
         end loop;

         Reserved_Count := Reserved_Count + 1;
         Reserved (Reserved_Count) := Batch_ID;
         for Offset in Natural range 0 .. Transactions'Length - 1 loop
            Reserved_Count := Reserved_Count + 1;
            Reserved (Reserved_Count) :=
              Identifier (Transactions (Transactions'First + Offset).Transaction_ID);
         end loop;
         Queue_Order := Queue_Order + 1;
         Count := Group_Count (Transactions'Length);
         for Offset in Natural range 0 .. Transactions'Length - 1 loop
            Selected := Commit_Slot'First;
            for Index in Commit_Slot loop
               if Slots (Index).State = Free then
                  Selected := Index;
                  exit;
               end if;
            end loop;
            declare
               Item : Transaction renames Transactions (Transactions'First + Offset);
            begin
               Slots (Selected).Generation := Slots (Selected).Generation + 1;
               Slots (Selected).Order := Queue_Order;
               Slots (Selected).Work.Transaction_ID := Item.Transaction_ID;
               Slots (Selected).Work.Mutation_Count := Item.Mutation_Count;
               Slots (Selected).Work.Bytes_Used := Item.Bytes_Used;
               Slots (Selected).Work.Deadline := Deadline;
               Slots (Selected).Work.Batch_ID := Batch_ID;
               Slots (Selected).Work.Group_ID := Queue_Order;
               Slots (Selected).Work.Group_Member := Commit_Slot (Offset + 1);
               Slots (Selected).Receipt := (others => <>);
               Slots (Selected).Receipt.Transaction_ID := Item.Transaction_ID;
               Slots (Selected).Receipt.Batch_ID := Batch_ID;
               Slots (Selected).Receipt.Expected_Head := Current_Head;
               for Index in Mutation_Slot range 1 .. Item.Mutation_Count loop
                  Slots (Selected).Work.Mutations (Index) := Item.Mutations (Index);
               end loop;
               Slots (Selected).State := Queued;
               Tokens (Offset + 1) := (Index => Selected, Generation => Slots (Selected).Generation);
            end;
         end loop;
         In_Use_Count := In_Use_Count + Count;
         Queued_Count := Queued_Count + Count;
         In_Flight_Bytes := In_Flight_Bytes + Total_Bytes;
         Result := Success;
      end Admit_Group;

      entry Take_Group
        (Items      : out Work_Group;
         Tokens     : out Token_Group;
         Count      : out Group_Count;
         Head       : out Head_Snapshot;
         Generation : out Generation_Value;
         Stop       : out Boolean)
        when Closing or else Fenced or else (Queued_Count > 0 and then not Uncertain and then not Paused)
      is
         Selected       : Commit_Slot;
         Selected_Order : Interfaces.Unsigned_64;
         Selected_Group : Interfaces.Unsigned_64 := 0;
         Found          : Boolean;
      begin
         Items := [others => <>];
         Tokens := [others => <>];
         Count := 0;
         Head := Current_Head;
         Generation := Head_Generation;
         if Closing or else Fenced then
            Stop := True;
            return;
         end if;
         Stop := False;
         Selected := Commit_Slot'First;
         Selected_Order := Interfaces.Unsigned_64'Last;
         for Index in Commit_Slot loop
            if Slots (Index).State = Queued and then Slots (Index).Order < Selected_Order then
               Selected := Index;
               Selected_Order := Slots (Index).Order;
            end if;
         end loop;
         if Selected_Order = Interfaces.Unsigned_64'Last then
            return;
         end if;
         Selected_Group := Slots (Selected).Work.Group_ID;
         for Member in Commit_Slot loop
            Found := False;
            for Index in Commit_Slot loop
               if Slots (Index).State = Queued
                 and then Slots (Index).Work.Group_ID = Selected_Group
                 and then Slots (Index).Work.Group_Member = Member
               then
                  Selected := Index;
                  Found := True;
                  exit;
               end if;
            end loop;
            exit when not Found;
            Count := Count + 1;
            Items (Count) := Slots (Selected).Work;
            Tokens (Count) := (Index => Selected, Generation => Slots (Selected).Generation);
            Slots (Selected).State := Running;
            Queued_Count := Queued_Count - 1;
         end loop;
      end Take_Group;

      procedure Prepublication_Check (Items : Work_Group; Count : Group_Count; Result : out Outcome_Code) is
         Put_Count : Natural := 0;
      begin
         if History_Count = Maximum_History_Batches or else Seen_Count + Count > Maximum_Seen_Transactions
         then
            Result := Capacity_Exceeded;
            return;
         end if;
         for Left in Commit_Slot range 1 .. Count loop
            for Existing in Positive range 1 .. Seen_Count loop
               if Seen (Existing) = Items (Left).Transaction_ID then
                  Result := Conflict;
                  return;
               end if;
            end loop;
            for Right in Commit_Slot range 1 .. Left - 1 loop
               if Items (Right).Transaction_ID = Items (Left).Transaction_ID then
                  Result := Conflict;
                  return;
               end if;
            end loop;
            for Mutation_Index in Mutation_Slot range 1 .. Items (Left).Mutation_Count loop
               if Items (Left).Mutations (Mutation_Index).Operation = Put_Mutation then
                  Put_Count := Put_Count + 1;
               end if;
            end loop;
         end loop;
         if Entry_Count + Put_Count > Maximum_State_Entries then
            Result := Capacity_Exceeded;
         else
            Result := Success;
         end if;
      end Prepublication_Check;

      procedure Complete_Group
        (Tokens         : Token_Group;
         Receipts       : Receipt_Group;
         Count          : Group_Count;
         Result         : Outcome_Code;
         Mark_Uncertain : Boolean;
         Mark_Fenced    : Boolean) is
      begin
         for Group_Index in Commit_Slot range 1 .. Count loop
            declare
               Index : constant Commit_Slot := Tokens (Group_Index).Index;
            begin
               if Slots (Index).State = Running
                 and then Slots (Index).Generation = Tokens (Group_Index).Generation
               then
                  Slots (Index).Receipt := Receipts (Group_Index);
                  Slots (Index).Result := Result;
                  Slots (Index).State := Completed;
               end if;
            end;
         end loop;
         if Mark_Uncertain and then Count > 0 then
            Uncertain := True;
         end if;
         if Mark_Fenced then
            Fenced := True;
            for Index in Commit_Slot loop
               if Slots (Index).State = Queued then
                  Slots (Index).Receipt.Current_Outcome := Stale_Writer;
                  Slots (Index).Result := Stale_Writer;
                  Slots (Index).State := Completed;
                  Queued_Count := Queued_Count - 1;
               end if;
            end loop;
         end if;
      end Complete_Group;

      entry Await_Result (for Index in Commit_Slot)
        (Generation : Interfaces.Unsigned_64; Receipt : out Commit_Receipt; Result : out Outcome_Code)
        when Slots (Index).State = Completed
      is
      begin
         if Slots (Index).Generation /= Generation then
            Receipt := (others => <>);
            Result := Invalid_State;
         else
            Receipt := Slots (Index).Receipt;
            Result := Slots (Index).Result;
         end if;
         In_Use_Count := In_Use_Count - 1;
         In_Flight_Bytes := In_Flight_Bytes - Slots (Index).Work.Bytes_Used;
         Slots (Index).State := Free;
      end Await_Result;

      procedure Install_Published
        (Batch      : Batches.Commit_Batch;
         Head       : Head_Snapshot;
         Generation : Generation_Value;
         Result     : out Outcome_Code) is
      begin
         if Fail_Install then
            Fail_Install := False;
            raise Program_Error with "injected local installation failure";
         end if;
         Apply_Batch (Batch, True, Result);
         if Result = Success then
            Current_Head := Head;
            Head_Generation := Generation;
         end if;
      end Install_Published;

      procedure Snapshot
        (Head         : out Head_Snapshot;
         Generation   : out Generation_Value;
         Is_Uncertain : out Boolean;
         Is_Fenced    : out Boolean) is
      begin
         Head := Current_Head;
         Generation := Head_Generation;
         Is_Uncertain := Uncertain;
         Is_Fenced := Fenced;
      end Snapshot;

      procedure Lookup
        (Family : Column_Family_ID; Item_Key : Key; Data : out Value; Result : out Outcome_Code) is
      begin
         Data := (others => <>);
         for Index in Positive range 1 .. Entry_Count loop
            if Entries (Index).Family = Family and then Same_Key (Entries (Index).Item_Key, Item_Key) then
               Data := Entries (Index).Data;
               Result := Success;
               return;
            end if;
         end loop;
         Result := Not_Found;
      end Lookup;

      procedure Fence is
      begin
         Fenced := True;
         Uncertain := False;
         for Index in Commit_Slot loop
            if Slots (Index).State = Queued then
               Slots (Index).Receipt.Current_Outcome := Stale_Writer;
               Slots (Index).Result := Stale_Writer;
               Slots (Index).State := Completed;
               Queued_Count := Queued_Count - 1;
            end if;
         end loop;
      end Fence;

      procedure Set_Paused (Value : Boolean) is
      begin
         Paused := Value;
      end Set_Paused;

      function Queue_Depth return Natural
      is (Queued_Count);

      procedure Fail_Next_Install is
      begin
         Fail_Install := True;
      end Fail_Next_Install;

      procedure Request_Close is
      begin
         Closing := True;
         for Index in Commit_Slot loop
            if Slots (Index).State = Queued then
               Slots (Index).Receipt.Current_Outcome := Storage_Failure;
               Slots (Index).Result := Storage_Failure;
               Slots (Index).State := Completed;
               Queued_Count := Queued_Count - 1;
            end if;
         end loop;
      end Request_Close;

      procedure Mark_Stopped is
      begin
         for Index in Commit_Slot loop
            if Slots (Index).State in Queued | Running then
               if Slots (Index).State = Queued then
                  Queued_Count := Queued_Count - 1;
               end if;
               Slots (Index).Receipt.Current_Outcome := Storage_Failure;
               Slots (Index).Result := Storage_Failure;
               Slots (Index).State := Completed;
            end if;
         end loop;
         Stopped := True;
      end Mark_Stopped;

      entry Join when Stopped and then In_Use_Count = 0 is
      begin
         null;
      end Join;

      function Highest return Sequence_Number
      is (Current_Head.Highest);

   end Coordinator;

   task type Commit_Worker (State : not null Engine_State_Access) is
      pragma Task_Info (Flyology.Native_Task);
   end Commit_Worker;
   type Commit_Worker_Access is access Commit_Worker;

   type Engine_State is limited record
      Storage : access Storage_Context;
      Life    : Database_Lifecycle_Access := null;
      Gate    : Coordinator;
      Worker  : Commit_Worker_Access := null;
   end record;

   protected body Database_Lifecycle is

      procedure Begin_Open (Result : out Outcome_Code) is
      begin
         if Mode /= Closed then
            Result := Invalid_State;
         else
            Mode := Opening;
            Result := Success;
         end if;
      end Begin_Open;

      procedure Complete_Open
        (State : not null Engine_State_Access; Visible : Sequence_Number; Result : out Outcome_Code) is
      begin
         if Mode /= Opening or else Current /= null then
            Result := Invalid_State;
         else
            Current := State;
            Last_Visible := Visible;
            Mode := Opened;
            Result := Success;
         end if;
      end Complete_Open;

      procedure Abort_Open is
      begin
         if Mode = Opening then
            Mode := Closed;
         end if;
      end Abort_Open;

      procedure Acquire (State : out Engine_State_Access; Result : out Outcome_Code) is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
         elsif Active_Calls = Natural'Last then
            Result := Capacity_Exceeded;
         else
            Active_Calls := Active_Calls + 1;
            State := Current;
            Result := Success;
         end if;
      end Acquire;

      procedure Release is
      begin
         if Active_Calls = 0 then
            raise Program_Error with "database lifecycle lease underflow";
         end if;
         Active_Calls := Active_Calls - 1;
      end Release;

      procedure Begin_Close (State : out Engine_State_Access; Result : out Outcome_Code) is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
         else
            Mode := Closing;
            State := Current;
            Result := Success;
         end if;
      end Begin_Close;

      procedure Begin_Resolve (State : out Engine_State_Access; Result : out Outcome_Code) is
      begin
         State := null;
         if Mode /= Opened or else Current = null then
            Result := Invalid_State;
         else
            Mode := Resolving;
            State := Current;
            Result := Success;
         end if;
      end Begin_Resolve;

      entry Await_Quiescent when Mode in Closing | Resolving and then Active_Calls = 0 is
      begin
         null;
      end Await_Quiescent;

      procedure Finish_Close is
      begin
         if Mode not in Closing | Resolving or else Active_Calls /= 0 then
            raise Program_Error with "invalid database close completion";
         end if;
         Current := null;
         Mode := Closed;
      end Finish_Close;

      procedure Finish_Resolve (State : not null Engine_State_Access; Visible : Sequence_Number) is
      begin
         if Mode /= Resolving or else Active_Calls /= 0 then
            raise Program_Error with "invalid database resolution completion";
         end if;
         Current := State;
         Last_Visible := Visible;
         Mode := Opened;
      end Finish_Resolve;

      procedure Cancel_Resolve is
      begin
         if Mode /= Resolving or else Current = null then
            raise Program_Error with "invalid database resolution cancellation";
         end if;
         Mode := Opened;
      end Cancel_Resolve;

      procedure Set_Visible (Value : Sequence_Number) is
      begin
         if Mode in Opened | Closing | Resolving and then Value > Last_Visible then
            Last_Visible := Value;
         end if;
      end Set_Visible;

      function Highest (Result : out Outcome_Code) return Sequence_Number is
      begin
         if Mode /= Opened then
            Result := Invalid_State;
            return 0;
         else
            Result := Success;
            return Last_Visible;
         end if;
      end Highest;

   end Database_Lifecycle;

   type Lifecycle_Lease is new Ada.Finalization.Limited_Controlled with record
      Life  : Database_Lifecycle_Access := null;
      State : Engine_State_Access := null;
   end record;

   overriding
   procedure Finalize (Item : in out Lifecycle_Lease) is
   begin
      if Item.Life /= null then
         Item.Life.Release;
         Item.Life := null;
         Item.State := null;
      end if;
   end Finalize;

   procedure Acquire (Item : in out Database; Lease : in out Lifecycle_Lease; Result : out Outcome_Code) is
   begin
      Item.Life.Acquire (Lease.State, Result);
      if Result = Success then
         Lease.Life := Item.Life'Unchecked_Access;
      end if;
   end Acquire;

   type Admission_Guard is new Ada.Finalization.Limited_Controlled with record
      State  : Engine_State_Access := null;
      Tokens : Token_Group;
      Count  : Group_Count := 0;
      Next   : Natural range 1 .. Maximum_Commit_Slots + 1 := 1;
      Active : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Admission_Guard) is
      Ignored_Receipt : Commit_Receipt;
      Ignored_Result  : Outcome_Code;
   begin
      if Item.Active then
         if Item.Next <= Item.Count then
            for Index in Commit_Slot range Item.Next .. Item.Count loop
               Item.State.Gate.Await_Result (Item.Tokens (Index).Index)
                 (Item.Tokens (Index).Generation, Ignored_Receipt, Ignored_Result);
            end loop;
         end if;
         Item.Active := False;
      end if;
   end Finalize;

   procedure Free_Worker is new
     Ada.Unchecked_Deallocation (Object => Commit_Worker, Name => Commit_Worker_Access);
   procedure Free_State is new
     Ada.Unchecked_Deallocation (Object => Engine_State, Name => Engine_State_Access);

   procedure Copy_Batch_Image (Image : Batches.Batch_Image; Length : Natural; Target : out Object_Buffer) is
   begin
      Target := [others => 0];
      for Index in Natural range 0 .. Length - 1 loop
         Target (Index) := Image (Index);
      end loop;
   end Copy_Batch_Image;

   procedure Copy_Head_Image (Image : Formats.Head_Image; Target : out Object_Buffer) is
   begin
      Target := [others => 0];
      for Index in Formats.Head_Image_Index loop
         Target (Index) := Image (Index);
      end loop;
   end Copy_Head_Image;

   function Exact_Bytes
     (Left : Object_Buffer; Left_Length : Natural; Right : Object_Buffer; Right_Length : Natural)
      return Boolean is
   begin
      return
        Left_Length = Right_Length
        and then (Left_Length = 0 or else Left (0 .. Left_Length - 1) = Right (0 .. Right_Length - 1));
   end Exact_Bytes;

   procedure Build_Batch
     (Items    : Work_Group;
      Count    : Group_Count;
      Expected : Head_Snapshot;
      Batch    : out Batches.Commit_Batch;
      Image    : out Batches.Batch_Image;
      Length   : out Natural;
      Receipts : out Receipt_Group;
      Result   : out Outcome_Code)
   is
      Mutation_Total : Natural := 0;
      Next_Mutation  : Natural := 1;
      Encode_Result  : Batches.Encode_Status;
      Batch_ID       : Identifier;
      Publication_ID : Identifier;

   begin
      Batch := Batches.Empty_Batch;
      Image := [others => 0];
      Receipts := [others => <>];
      Length := 0;
      if Count = 0
        or else Expected.Highest > Sequence_Number'Last - Sequence_Number (Count)
        or else Expected.Transition_Number = Interfaces.Unsigned_64'Last
      then
         Result := Capacity_Exceeded;
         return;
      end if;
      for Index in Commit_Slot range 1 .. Count loop
         Mutation_Total := Mutation_Total + Items (Index).Mutation_Count;
      end loop;
      if Mutation_Total = 0 or else Mutation_Total > Batches.Max_Mutations then
         Result := Invalid_State;
         return;
      end if;

      Batch_ID := Items (1).Batch_ID;
      if Is_Zero (Batch_ID) or else Batch_ID = Expected.Latest_Batch then
         Result := Conflict;
         return;
      end if;
      for Index in Commit_Slot range 2 .. Count loop
         if Items (Index).Batch_ID /= Batch_ID then
            Result := Invalid_State;
            return;
         end if;
      end loop;
      Publication_ID := Structural_ID (16#C3#, Expected.Transition_Number + 1);
      if Publication_ID = Expected.Transition_ID then
         Publication_ID := Structural_ID (16#C4#, Expected.Transition_Number + 1);
      end if;

      Batch.Database_ID := To_Head_ID (Expected.Database_ID);
      Batch.Epoch := Heads.Writer_Epoch (Expected.Epoch);
      Batch.Batch_ID := To_Head_ID (Batch_ID);
      Batch.Previous_Batch_ID :=
        (if Expected.Highest = 0 then Heads.Zero_Identifier else To_Head_ID (Expected.Latest_Batch));
      Batch.Expected_Transition_ID := To_Head_ID (Expected.Transition_ID);
      Batch.Expected_Transition_Number := Heads.Transition_Ordinal (Expected.Transition_Number);
      Batch.Publication_Transition_ID := To_Head_ID (Publication_ID);
      Batch.Publication_Transition_Number := Heads.Transition_Ordinal (Expected.Transition_Number + 1);
      Batch.First_Sequence := Heads.Commit_Sequence (Expected.Highest + 1);
      Batch.Last_Sequence := Heads.Commit_Sequence (Expected.Highest + Sequence_Number (Count));
      Batch.Transaction_Total := Batches.Transaction_Count (Count);
      Batch.Mutation_Total := Batches.Mutation_Count (Mutation_Total);

      for Transaction_Index in Commit_Slot range 1 .. Count loop
         Batch.Transactions (Transaction_Index).Transaction_ID :=
           To_Head_ID (Items (Transaction_Index).Transaction_ID);
         Batch.Transactions (Transaction_Index).Sequence :=
           Heads.Commit_Sequence (Expected.Highest + Sequence_Number (Transaction_Index));
         Batch.Transactions (Transaction_Index).First_Mutation := Batches.Mutation_Count (Next_Mutation);
         Batch.Transactions (Transaction_Index).Mutations :=
           Batches.Mutation_Count (Items (Transaction_Index).Mutation_Count);
         for Source_Index in Mutation_Slot range 1 .. Items (Transaction_Index).Mutation_Count loop
            declare
               Source : Pending_Mutation renames Items (Transaction_Index).Mutations (Source_Index);
               Target : Batches.Mutation renames Batch.Mutations (Next_Mutation);
            begin
               Target.Column_Family := Interfaces.Unsigned_32 (Source.Family);
               Target.Operation := (if Source.Operation = Put_Mutation then Batches.Put else Batches.Delete);
               Target.Key_Size := Batches.Key_Length (Source.Item_Key.Length);
               for Byte_Index in Positive range 1 .. Source.Item_Key.Length loop
                  Target.Key (Byte_Index) := Source.Item_Key.Bytes (Byte_Index);
               end loop;
               Target.Value_Size :=
                 (if Source.Operation = Put_Mutation then Batches.Value_Length (Source.Data.Length) else 0);
               for Byte_Index in Positive range 1 .. Source.Data.Length loop
                  Target.Value (Byte_Index) := Source.Data.Bytes (Byte_Index);
               end loop;
               Next_Mutation := Next_Mutation + 1;
            end;
         end loop;
      end loop;

      if not Batches.Structurally_Valid (Batch) then
         Result := Invalid_State;
         return;
      end if;
      Batches.Encode_Batch (Batch, Image, Length, Encode_Result);
      if Encode_Result /= Batches.Encoded then
         Result := Invalid_State;
         return;
      end if;
      for Index in Commit_Slot range 1 .. Count loop
         Receipts (Index).Transaction_ID := Items (Index).Transaction_ID;
         Receipts (Index).Assigned_Sequence := Expected.Highest + Sequence_Number (Index);
         Receipts (Index).Batch_ID := Batch_ID;
         Receipts (Index).Batch_Length := Length;
         Receipts (Index).Expected_Head := Expected;
         Receipts (Index).Attempted_Head :=
           (Database_ID            => Expected.Database_ID,
            Epoch                  => Expected.Epoch,
            Highest                => Expected.Highest + Sequence_Number (Count),
            Latest_Batch           => Batch_ID,
            Latest_Manifest        => Expected.Latest_Manifest,
            Transition_ID          => Publication_ID,
            Predecessor_Transition => Expected.Transition_ID,
            Transition_Number      => Expected.Transition_Number + 1);
         for Byte_Index in Natural range 0 .. Length - 1 loop
            Receipts (Index).Batch_Image (Byte_Index) := Image (Byte_Index);
         end loop;
      end loop;
      Result := Success;
   end Build_Batch;

   procedure Finish_Work
     (State          : not null Engine_State_Access;
      Tokens         : Token_Group;
      Receipts       : in out Receipt_Group;
      Count          : Group_Count;
      Result         : Outcome_Code;
      Mark_Uncertain : Boolean := False;
      Mark_Fenced    : Boolean := False) is
   begin
      for Index in Commit_Slot range 1 .. Count loop
         Receipts (Index).Current_Outcome := Result;
         if Result = Success then
            Receipts (Index).Phase := Resolved;
         elsif Mark_Uncertain then
            Receipts (Index).Phase := Head_Publication_Unknown;
         end if;
      end loop;
      State.Gate.Complete_Group (Tokens, Receipts, Count, Result, Mark_Uncertain, Mark_Fenced);
   end Finish_Work;

   procedure Process_Group
     (State           : not null Engine_State_Access;
      Items           : Work_Group;
      Tokens          : Token_Group;
      Count           : Group_Count;
      Head            : Head_Snapshot;
      Head_Generation : Generation_Value)
   is
      Batch                : Batches.Commit_Batch;
      Batch_Image          : Batches.Batch_Image;
      Batch_Data           : Object_Buffer;
      Batch_Length         : Natural;
      Receipts             : Receipt_Group;
      Result               : Outcome_Code;
      Put_Result           : Put_Outcome;
      Read_Result          : Read_Outcome;
      Ignored_Generation   : Generation_Value;
      Published_Generation : Generation_Value;
      Read_Data            : Object_Buffer;
      Read_Length          : Natural;
      Head_Image           : Formats.Head_Image;
      Head_Data            : Object_Buffer;
      Deadline             : Ada.Real_Time.Time := Items (1).Deadline;
      Token                : constant access Flyology.Cancellation.Token := null;
      Attempted_Head       : Head_Snapshot;
      Head_Confirmed       : Boolean := False;
   begin
      Receipts := [others => <>];
      for Index in Commit_Slot range 1 .. Count loop
         Receipts (Index).Transaction_ID := Items (Index).Transaction_ID;
         Receipts (Index).Batch_ID := Items (Index).Batch_ID;
         Receipts (Index).Expected_Head := Head;
      end loop;
      for Index in Commit_Slot range 2 .. Count loop
         if Items (Index).Deadline < Deadline then
            Deadline := Items (Index).Deadline;
         end if;
      end loop;
      State.Gate.Prepublication_Check (Items, Count, Result);
      if Result /= Success then
         Finish_Work (State, Tokens, Receipts, Count, Result);
         return;
      elsif Deadline <= Ada.Real_Time.Clock then
         Finish_Work (State, Tokens, Receipts, Count, Timed_Out);
         return;
      end if;

      Build_Batch (Items, Count, Head, Batch, Batch_Image, Batch_Length, Receipts, Result);
      if Result /= Success then
         Finish_Work (State, Tokens, Receipts, Count, Result);
         return;
      end if;
      Copy_Batch_Image (Batch_Image, Batch_Length, Batch_Data);
      Storage_Port.Put_Create
        (State.Storage.all,
         Batch_Key (State.Storage.all, Receipts (1).Batch_ID),
         Batch_Data,
         Batch_Length,
         False,
         Deadline,
         Token,
         Ignored_Generation,
         Put_Result);
      if Put_Result /= Object_Published then
         if Put_Result = Put_Outcome_Unknown then
            Storage_Port.Get_Whole
              (State.Storage.all,
               Batch_Key (State.Storage.all, Receipts (1).Batch_ID),
               Deadline,
               Token,
               Read_Data,
               Read_Length,
               Ignored_Generation,
               Read_Result);
            if Read_Result = Object_Read
              and then Exact_Bytes (Batch_Data, Batch_Length, Read_Data, Read_Length)
            then
               null;
            else
               Finish_Work
                 (State,
                  Tokens,
                  Receipts,
                  Count,
                  (if Read_Result = Read_Cancelled
                   then Cancelled
                   elsif Read_Result = Read_Timed_Out
                   then Timed_Out
                   else Storage_Failure));
               return;
            end if;
         elsif Put_Result = Put_Precondition_Failed then
            --  A batch identity is one-shot at the public transaction boundary.
            --  Exact bytes can continue only inside the original unknown Put;
            --  a later admission must never replay the application operation.
            Finish_Work (State, Tokens, Receipts, Count, Conflict, Mark_Fenced => True);
            return;
         else
            Finish_Work
              (State,
               Tokens,
               Receipts,
               Count,
               (if Put_Result = Put_Cancelled
                then Cancelled
                elsif Put_Result = Put_Timed_Out
                then Timed_Out
                else Storage_Failure));
            return;
         end if;
      end if;

      Attempted_Head := Receipts (1).Attempted_Head;
      Head_Image := Formats.Encode_Head (To_Head (Attempted_Head));
      Copy_Head_Image (Head_Image, Head_Data);
      Storage_Port.Put_Replace
        (State.Storage.all,
         Full_Key (State.Storage.all, Head_Key_Suffix),
         Head_Data,
         Formats.Head_Image_Length,
         Head_Generation,
         Deadline,
         Token,
         Published_Generation,
         Put_Result);
      case Put_Result is
         when Object_Published        =>
            Head_Confirmed := True;
            State.Gate.Install_Published (Batch, Attempted_Head, Published_Generation, Result);
            State.Life.Set_Visible (Attempted_Head.Highest);
            if Result = Success then
               Finish_Work (State, Tokens, Receipts, Count, Success);
            else
               --  Durable publication remains successful even if the local
               --  in-memory installation fails. Fence reuse until recovery.
               Finish_Work (State, Tokens, Receipts, Count, Success, Mark_Fenced => True);
            end if;

         when Put_Precondition_Failed =>
            Finish_Work (State, Tokens, Receipts, Count, Stale_Writer, Mark_Fenced => True);

         when Put_Outcome_Unknown     =>
            Finish_Work (State, Tokens, Receipts, Count, Outcome_Unknown, Mark_Uncertain => True);

         when Put_Cancelled           =>
            Finish_Work (State, Tokens, Receipts, Count, Cancelled);

         when Put_Timed_Out           =>
            Finish_Work (State, Tokens, Receipts, Count, Timed_Out);

         when Put_Definite_Failure    =>
            Finish_Work (State, Tokens, Receipts, Count, Storage_Failure);
      end case;
   exception
      when others =>
         if Head_Confirmed then
            State.Life.Set_Visible (Attempted_Head.Highest);
            Finish_Work (State, Tokens, Receipts, Count, Success, Mark_Fenced => True);
         else
            Finish_Work (State, Tokens, Receipts, Count, Storage_Failure);
         end if;
   end Process_Group;

   task body Commit_Worker is
      Items      : Work_Group;
      Tokens     : Token_Group;
      Count      : Group_Count;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Stop       : Boolean;
   begin
      loop
         State.Gate.Take_Group (Items, Tokens, Count, Head, Generation, Stop);
         exit when Stop;
         Process_Group (State, Items, Tokens, Count, Head, Generation);
      end loop;
      State.Gate.Mark_Stopped;
   exception
      when others =>
         State.Gate.Mark_Stopped;
   end Commit_Worker;

   subtype History_Slot is Positive range 1 .. Maximum_History_Batches;
   type Batch_History is array (History_Slot) of Batches.Commit_Batch;

   procedure Decode_Stored_Batch
     (Data              : Object_Buffer;
      Length            : Natural;
      Expected_Database : Database_Identifier;
      Latest            : Boolean;
      Head              : Head_Snapshot;
      Batch             : out Batches.Commit_Batch;
      Result            : out Outcome_Code)
   is
      Status : Batches.Decode_Status;
   begin
      Batch := Batches.Empty_Batch;
      if Length = 0 or else Length > Batches.Max_Batch_Image_Length then
         Result := Corrupt;
         return;
      end if;
      declare
         Image : Formats.Byte_Array (0 .. Length - 1);
      begin
         for Index in Image'Range loop
            Image (Index) := Data (Index);
         end loop;
         if Latest then
            Batches.Decode_Latest_Batch
              (Image,
               To_Head_ID (Expected_Database),
               To_Head (Head),
               Batches.Default_Reader_Caps,
               Batch,
               Status);
         else
            Batches.Decode_Batch
              (Image, To_Head_ID (Expected_Database), Batches.Default_Reader_Caps, Batch, Status);
         end if;
      end;
      Result := (if Status = Batches.Decoded then Success else Corrupt);
   end Decode_Stored_Batch;

   procedure Read_Recovery
     (Storage     : in out Storage_Context;
      Database_ID : Database_Identifier;
      Deadline    : Ada.Real_Time.Time;
      Token       : access Flyology.Cancellation.Token;
      Head        : out Head_Snapshot;
      Generation  : out Generation_Value;
      History     : out Batch_History;
      Count       : out Natural;
      Result      : out Outcome_Code)
   is
      Data             : Object_Buffer;
      Length           : Natural;
      Read_Result      : Read_Outcome;
      Decode_Result    : Formats.Decode_Status;
      Batch_Result     : Outcome_Code;
      Current_Batch_ID : Identifier;
      Batch_Generation : Generation_Value;
   begin
      Head := (others => <>);
      Generation := (others => <>);
      History := [others => Batches.Empty_Batch];
      Count := 0;
      Storage_Port.Get_Whole
        (Storage,
         Full_Key (Storage, Head_Key_Suffix),
         Deadline,
         Token,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read then
         Result :=
           (if Read_Result = Object_Missing
            then Not_Found
            elsif Read_Result = Read_Cancelled
            then Cancelled
            elsif Read_Result = Read_Timed_Out
            then Timed_Out
            elsif Read_Result = Read_Corrupt
            then Corrupt
            else Storage_Failure);
         return;
      elsif Length /= Formats.Head_Image_Length then
         Result := Corrupt;
         return;
      end if;
      declare
         Image : Formats.Head_Image;
         Value : Heads.Head_State;
      begin
         for Index in Formats.Head_Image_Index loop
            Image (Index) := Data (Index);
         end loop;
         Formats.Decode_Head (Image, To_Head_ID (Database_ID), Value, Decode_Result);
         if Decode_Result /= Formats.Decoded then
            Result := Corrupt;
            return;
         end if;
         Head := From_Head (Value);
      end;
      if Head.Highest = 0 then
         Result := Success;
         return;
      end if;

      Current_Batch_ID := Head.Latest_Batch;
      loop
         if Count = Maximum_History_Batches then
            Result := Capacity_Exceeded;
            return;
         end if;
         Storage_Port.Get_Whole
           (Storage,
            Batch_Key (Storage, Current_Batch_ID),
            Deadline,
            Token,
            Data,
            Length,
            Batch_Generation,
            Read_Result);
         if Read_Result /= Object_Read then
            Result :=
              (if Read_Result = Read_Cancelled
               then Cancelled
               elsif Read_Result = Read_Timed_Out
               then Timed_Out
               elsif Read_Result in Object_Missing | Read_Corrupt
               then Corrupt
               else Storage_Failure);
            return;
         end if;
         Count := Count + 1;
         Decode_Stored_Batch (Data, Length, Database_ID, Count = 1, Head, History (Count), Batch_Result);
         if Batch_Result /= Success then
            Result := Batch_Result;
            return;
         elsif To_Identifier (History (Count).Batch_ID) /= Current_Batch_ID then
            Result := Corrupt;
            return;
         elsif Count > 1 and then not Batches.Valid_Predecessor (History (Count - 1), History (Count)) then
            Result := Corrupt;
            return;
         elsif Batches.Is_First_Batch (History (Count)) then
            exit;
         end if;
         Current_Batch_ID := To_Identifier (History (Count).Previous_Batch_ID);
      end loop;
      Result := Success;
   end Read_Recovery;

   procedure Allocate_Engine
     (Life       : not null Database_Lifecycle_Access;
      Storage    : not null access Storage_Context;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      History    : Batch_History;
      Count      : Natural;
      State      : out Engine_State_Access;
      Result     : out Outcome_Code) is
   begin
      State := new Engine_State;
      --  Database retains this caller-owned context only until Close/Finalize.
      State.Storage := Storage.all'Unchecked_Access;
      State.Life := Life;
      State.Gate.Initialize (Head, Generation);
      for Index in reverse History_Slot range 1 .. Count loop
         State.Gate.Recover_Batch (History (Index), Result);
         if Result /= Success then
            Free_State (State);
            State := null;
            return;
         end if;
      end loop;
      State.Worker := new Commit_Worker (State);
      Result := Success;
   exception
      when others =>
         if State /= null then
            if State.Worker /= null then
               State.Gate.Request_Close;
               State.Gate.Join;
               Free_Worker (State.Worker);
            end if;
            Free_State (State);
         end if;
         State := null;
         Result := Storage_Failure;
   end Allocate_Engine;

   procedure Start_Engine
     (Item       : in out Database;
      Storage    : not null access Storage_Context;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      History    : Batch_History;
      Count      : Natural;
      Result     : out Outcome_Code)
   is
      State : Engine_State_Access;
   begin
      Allocate_Engine (Item.Life'Unchecked_Access, Storage, Head, Generation, History, Count, State, Result);
      if Result = Success then
         Item.Life.Complete_Open (State, Head.Highest, Result);
         if Result /= Success then
            State.Gate.Request_Close;
            State.Gate.Join;
            Free_Worker (State.Worker);
            Free_State (State);
         end if;
      end if;
   end Start_Engine;

   function To_Key (Data : Byte_Array) return Key is
   begin
      if Data'Length > Maximum_Key_Bytes then
         raise Constraint_Error with "key exceeds Flyology.DB operational cap";
      end if;
      return Result : Key do
         Result.Length := Data'Length;
         for Index in Natural range 0 .. Data'Length - 1 loop
            Result.Bytes (Index + 1) := Data (Data'First + Index);
         end loop;
      end return;
   end To_Key;

   function To_Value (Data : Byte_Array) return Value is
   begin
      if Data'Length > Maximum_Value_Bytes then
         raise Constraint_Error with "value exceeds Flyology.DB operational cap";
      end if;
      return Result : Value do
         Result.Length := Data'Length;
         for Index in Natural range 0 .. Data'Length - 1 loop
            Result.Bytes (Index + 1) := Data (Data'First + Index);
         end loop;
      end return;
   end To_Value;

   procedure Create
     (Item                  : in out Database;
      Storage               : not null access Storage_Context;
      Database_ID           : Database_Identifier;
      Initial_Transition_ID : Identifier;
      Timeout               : Duration;
      Token                 : access Flyology.Cancellation.Token := null;
      Result                : out Outcome_Code)
   is
      Deadline        : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Head            : Head_Snapshot;
      Head_Image      : Formats.Head_Image;
      Data            : Object_Buffer;
      Read_Data       : Object_Buffer;
      Length          : Natural;
      Generation      : Generation_Value;
      Read_Generation : Generation_Value;
      Put_Result      : Put_Outcome;
      Read_Result     : Read_Outcome;
      History         : constant Batch_History := [others => Batches.Empty_Batch];
      Bucket_Result   : Outcome_Code;
   begin
      if Storage.Backend = null or else Is_Zero (Database_ID) or else Is_Zero (Initial_Transition_ID) then
         Result := Invalid_State;
         return;
      end if;
      Item.Life.Begin_Open (Result);
      if Result /= Success then
         return;
      end if;
      Storage_Port.Bucket_Available (Storage.all, Deadline, Token, Bucket_Result);
      if Bucket_Result /= Success then
         Result := Bucket_Result;
         Item.Life.Abort_Open;
         return;
      end if;
      Head :=
        (Database_ID            => Database_ID,
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => Zero_Identifier,
         Transition_ID          => Initial_Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Head_Image := Formats.Encode_Head (To_Head (Head));
      Copy_Head_Image (Head_Image, Data);
      Storage_Port.Put_Create
        (Storage.all,
         Full_Key (Storage.all, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         True,
         Deadline,
         Token,
         Generation,
         Put_Result);
      if Put_Result = Object_Published then
         Start_Engine (Item, Storage, Head, Generation, History, 0, Result);
      elsif Put_Result = Put_Outcome_Unknown then
         Storage_Port.Get_Whole
           (Storage.all,
            Full_Key (Storage.all, Head_Key_Suffix),
            Deadline,
            Token,
            Read_Data,
            Length,
            Read_Generation,
            Read_Result);
         if Read_Result = Object_Read
           and then Exact_Bytes (Data, Formats.Head_Image_Length, Read_Data, Length)
         then
            Start_Engine (Item, Storage, Head, Read_Generation, History, 0, Result);
         else
            Result := Outcome_Unknown;
         end if;
      elsif Put_Result = Put_Precondition_Failed then
         Storage_Port.Get_Whole
           (Storage.all,
            Full_Key (Storage.all, Head_Key_Suffix),
            Deadline,
            Token,
            Read_Data,
            Length,
            Read_Generation,
            Read_Result);
         if Read_Result = Object_Read
           and then Exact_Bytes (Data, Formats.Head_Image_Length, Read_Data, Length)
         then
            Start_Engine (Item, Storage, Head, Read_Generation, History, 0, Result);
         else
            Result := Already_Exists;
         end if;
      elsif Put_Result = Put_Cancelled then
         Result := Cancelled;
      elsif Put_Result = Put_Timed_Out then
         Result := Timed_Out;
      else
         Result := Storage_Failure;
      end if;
      if Result /= Success then
         Item.Life.Abort_Open;
      end if;
   end Create;

   procedure Open
     (Item        : in out Database;
      Storage     : not null access Storage_Context;
      Database_ID : Database_Identifier;
      Timeout     : Duration;
      Token       : access Flyology.Cancellation.Token := null;
      Result      : out Outcome_Code)
   is
      Deadline      : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      History       : Batch_History;
      History_Count : Natural;
      Bucket_Result : Outcome_Code;
   begin
      if Storage.Backend = null or else Is_Zero (Database_ID) then
         Result := Invalid_State;
         return;
      end if;
      Item.Life.Begin_Open (Result);
      if Result /= Success then
         return;
      end if;
      Storage_Port.Bucket_Available (Storage.all, Deadline, Token, Bucket_Result);
      if Bucket_Result /= Success then
         Result := Bucket_Result;
         Item.Life.Abort_Open;
         return;
      end if;
      Read_Recovery
        (Storage.all, Database_ID, Deadline, Token, Head, Generation, History, History_Count, Result);
      if Result = Success then
         Start_Engine (Item, Storage, Head, Generation, History, History_Count, Result);
      end if;
      if Result /= Success then
         Item.Life.Abort_Open;
      end if;
   end Open;

   procedure Reset_Transaction (Txn : out Transaction) is
   begin
      Txn.Active := False;
      Txn.Database_ID := Zero_Database_ID;
      Txn.Transaction_ID := Zero_Transaction_ID;
      Txn.Mutation_Count := 0;
      Txn.Bytes_Used := 0;
      for Index in Mutation_Slot loop
         Txn.Mutations (Index) := (others => <>);
      end loop;
   end Reset_Transaction;

   procedure Close (Item : in out Database; Result : out Outcome_Code) is
      State : Engine_State_Access;
   begin
      Item.Life.Begin_Close (State, Result);
      if Result /= Success then
         return;
      end if;
      State.Gate.Request_Close;
      Item.Life.Await_Quiescent;
      State.Gate.Join;
      Free_Worker (State.Worker);
      Free_State (State);
      Item.Life.Finish_Close;
      Result := Success;
   end Close;

   procedure Begin_Transaction
     (Item           : in out Database;
      Transaction_ID : Transaction_Identifier;
      Txn            : out Transaction;
      Result         : out Outcome_Code)
   is
      Lease      : Lifecycle_Lease;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Uncertain  : Boolean;
      Fenced     : Boolean;
   begin
      Reset_Transaction (Txn);
      if Is_Zero (Transaction_ID) then
         Result := Invalid_State;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Transaction_Available (Transaction_ID, Result);
      if Result = Success then
         Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
         Txn.Active := True;
         Txn.Database_ID := Head.Database_ID;
         Txn.Transaction_ID := Transaction_ID;
      end if;
   end Begin_Transaction;

   procedure Get
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
      Data     : out Value;
      Result   : out Outcome_Code)
   is
      Lease      : Lifecycle_Lease;
      Index      : Natural;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Uncertain  : Boolean;
      Fenced     : Boolean;
   begin
      Data := (others => <>);
      if not Txn.Active then
         Result := Invalid_State;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      for Reverse_Index in reverse Mutation_Slot range 1 .. Txn.Mutation_Count loop
         Index := Reverse_Index;
         if Txn.Mutations (Index).Family = Family and then Same_Key (Txn.Mutations (Index).Item_Key, Item_Key)
         then
            if Txn.Mutations (Index).Operation = Delete_Mutation then
               Result := Not_Found;
            else
               Data := Txn.Mutations (Index).Data;
               Result := Success;
            end if;
            return;
         end if;
      end loop;
      Lease.State.Gate.Lookup (Family, Item_Key, Data, Result);
   end Get;

   procedure Store_Mutation
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family_ID;
      Item_Key  : Key;
      Data      : Value;
      Operation : Mutation_Kind;
      Result    : out Outcome_Code)
   is
      Lease      : Lifecycle_Lease;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Uncertain  : Boolean;
      Fenced     : Boolean;
      Existing   : Natural := 0;
      Old_Bytes  : Natural := 0;
      New_Bytes  : constant Natural :=
        Item_Key.Length + (if Operation = Put_Mutation then Data.Length else 0);
   begin
      if not Txn.Active then
         Result := Invalid_State;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      for Index in Mutation_Slot range 1 .. Txn.Mutation_Count loop
         if Txn.Mutations (Index).Family = Family and then Same_Key (Txn.Mutations (Index).Item_Key, Item_Key)
         then
            Existing := Index;
            Old_Bytes :=
              Txn.Mutations (Index).Item_Key.Length
              + (if Txn.Mutations (Index).Operation = Put_Mutation
                 then Txn.Mutations (Index).Data.Length
                 else 0);
            exit;
         end if;
      end loop;
      if Existing = 0 and then Txn.Mutation_Count = Maximum_Transaction_Mutations then
         Result := Capacity_Exceeded;
         return;
      elsif Txn.Bytes_Used - Old_Bytes + New_Bytes > Maximum_Transaction_Bytes then
         Result := Capacity_Exceeded;
         return;
      end if;
      if Existing = 0 then
         Txn.Mutation_Count := Txn.Mutation_Count + 1;
         Existing := Txn.Mutation_Count;
      end if;
      Txn.Mutations (Existing) :=
        (Family => Family, Operation => Operation, Item_Key => Item_Key, Data => Data);
      Txn.Bytes_Used := Txn.Bytes_Used - Old_Bytes + New_Bytes;
      Result := Success;
   end Store_Mutation;

   procedure Put
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
      Data     : Value;
      Result   : out Outcome_Code) is
   begin
      Store_Mutation (Item, Txn, Family, Item_Key, Data, Put_Mutation, Result);
   end Put;

   procedure Delete
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family_ID;
      Item_Key : Key;
      Result   : out Outcome_Code) is
   begin
      Store_Mutation (Item, Txn, Family, Item_Key, (others => <>), Delete_Mutation, Result);
   end Delete;

   procedure Rollback (Txn : in out Transaction; Result : out Outcome_Code) is
   begin
      if not Txn.Active then
         Result := Invalid_State;
      else
         Reset_Transaction (Txn);
         Result := Success;
      end if;
   end Rollback;

   procedure Commit
     (Item    : in out Database;
      Txn     : in out Transaction;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Receipt : out Commit_Receipt;
      Result  : out Outcome_Code)
   is
      Deadline   : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Lease      : Lifecycle_Lease;
      Admission  : Admission_Guard;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Uncertain  : Boolean;
      Fenced     : Boolean;
   begin
      Receipt := (others => <>);
      if not Txn.Active or else Txn.Mutation_Count = 0 then
         Result := Invalid_State;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Txn.Database_ID /= Head.Database_ID then
         Result := Invalid_State;
         return;
      end if;
      Lease.State.Gate.Admit (Txn, Deadline, Token, Admission.Tokens (1), Result);
      if Result = Success then
         Admission.State := Lease.State;
         Admission.Count := 1;
         Admission.Active := True;
         Reset_Transaction (Txn);
         Lease.State.Gate.Await_Result (Admission.Tokens (1).Index)
           (Admission.Tokens (1).Generation, Receipt, Result);
         Admission.Active := False;
      end if;
   end Commit;

   procedure Commit_Group
     (Item         : in out Database;
      Group_ID     : Identifier;
      Transactions : in out Transaction_Array;
      Timeout      : Duration;
      Token        : access Flyology.Cancellation.Token := null;
      Receipts     : out Commit_Receipt_Array;
      Result       : out Outcome_Code)
   is
      Deadline      : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Lease         : Lifecycle_Lease;
      Admission     : Admission_Guard;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      Member_Result : Outcome_Code := Invalid_State;
   begin
      Receipts := [others => <>];
      if Transactions'Length /= Receipts'Length or else Transactions'Length < 2 then
         Result := Invalid_State;
         return;
      elsif Transactions'Length > Maximum_Group_Transactions then
         Result := Capacity_Exceeded;
         return;
      end if;
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      for Offset in Natural range 0 .. Transactions'Length - 1 loop
         if not Transactions (Transactions'First + Offset).Active
           or else Transactions (Transactions'First + Offset).Mutation_Count = 0
           or else Transactions (Transactions'First + Offset).Database_ID /= Head.Database_ID
         then
            Result := Invalid_State;
            return;
         end if;
      end loop;
      Lease.State.Gate.Admit_Group
        (Transactions, Group_ID, Deadline, Token, Admission.Tokens, Admission.Count, Result);
      if Result /= Success then
         return;
      end if;
      Admission.State := Lease.State;
      Admission.Active := True;
      for Offset in Natural range 0 .. Transactions'Length - 1 loop
         Reset_Transaction (Transactions (Transactions'First + Offset));
      end loop;
      for Index in Commit_Slot range 1 .. Admission.Count loop
         Lease.State.Gate.Await_Result (Admission.Tokens (Index).Index)
           (Admission.Tokens (Index).Generation,
            Receipts (Receipts'First + Natural (Index) - 1),
            Member_Result);
         Admission.Next := Natural (Index) + 1;
         if Index = 1 then
            Result := Member_Result;
         elsif Member_Result /= Result then
            Result := Storage_Failure;
         end if;
      end loop;
   end Commit_Group;

   type Receipt_Resolution is (Receipt_Committed, Receipt_Rejected, Receipt_Unresolved);

   procedure Reconcile_Receipt
     (Storage     : in out Storage_Context;
      Database_ID : Database_Identifier;
      Receipt     : Commit_Receipt;
      Deadline    : Ada.Real_Time.Time;
      Token       : access Flyology.Cancellation.Token;
      Observed    : out Head_Snapshot;
      Generation  : out Generation_Value;
      History     : out Batch_History;
      Count       : out Natural;
      Resolution  : out Receipt_Resolution;
      Result      : out Outcome_Code)
   is
      Exact   : Boolean := False;
      Encoded : Batches.Batch_Image;
      Length  : Natural;
      Status  : Batches.Encode_Status;
   begin
      Resolution := Receipt_Unresolved;
      Read_Recovery (Storage, Database_ID, Deadline, Token, Observed, Generation, History, Count, Result);
      if Result /= Success then
         return;
      end if;
      for Index in History_Slot range 1 .. Count loop
         if To_Identifier (History (Index).Batch_ID) = Receipt.Batch_ID then
            Batches.Encode_Batch (History (Index), Encoded, Length, Status);
            Exact := Status = Batches.Encoded and then Length = Receipt.Batch_Length;
            if Exact then
               for Byte_Index in Natural range 0 .. Length - 1 loop
                  if Encoded (Byte_Index) /= Receipt.Batch_Image (Byte_Index) then
                     Exact := False;
                     exit;
                  end if;
               end loop;
            end if;
            if Exact then
               Resolution := Receipt_Committed;
            else
               Result := Corrupt;
            end if;
            return;
         end if;
      end loop;
      if Observed.Transition_Number >= Receipt.Attempted_Head.Transition_Number then
         Resolution := Receipt_Rejected;
      end if;
   end Reconcile_Receipt;

   procedure Resolve
     (Item    : in out Database;
      Receipt : in out Commit_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code)
   is
      Deadline      : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Observed      : Head_Snapshot;
      Read_Result   : Outcome_Code;
      Storage       : access Storage_Context;
      Database_ID   : Database_Identifier;
      Current_Head  : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
      State         : Engine_State_Access;
      New_State     : Engine_State_Access;
      History       : Batch_History;
      History_Count : Natural;
      Resolution    : Receipt_Resolution;
   begin
      if Receipt.Phase /= Head_Publication_Unknown then
         Result := Invalid_State;
         return;
      end if;
      Item.Life.Begin_Resolve (State, Result);
      if Result /= Success then
         return;
      end if;
      Item.Life.Await_Quiescent;
      State.Gate.Snapshot (Current_Head, Generation, Uncertain, Fenced);
      if Current_Head.Database_ID /= Receipt.Expected_Head.Database_ID then
         Item.Life.Cancel_Resolve;
         Result := Invalid_State;
         return;
      end if;
      Storage := State.Storage;
      Database_ID := Receipt.Expected_Head.Database_ID;
      Reconcile_Receipt
        (Storage.all,
         Database_ID,
         Receipt,
         Deadline,
         Token,
         Observed,
         Generation,
         History,
         History_Count,
         Resolution,
         Read_Result);
      if Read_Result /= Success then
         Item.Life.Cancel_Resolve;
         Result := Read_Result;
         return;
      elsif Resolution = Receipt_Committed or else Same_Head (Observed, Receipt.Attempted_Head) then
         Allocate_Engine
           (Item.Life'Unchecked_Access,
            Storage,
            Observed,
            Generation,
            History,
            History_Count,
            New_State,
            Result);
         if Result /= Success then
            Item.Life.Cancel_Resolve;
            return;
         end if;
         State.Gate.Request_Close;
         State.Gate.Join;
         Free_Worker (State.Worker);
         Free_State (State);
         Item.Life.Finish_Resolve (New_State, Observed.Highest);
         Receipt.Current_Outcome := Success;
         Receipt.Phase := Resolved;
         Result := Success;
      elsif Resolution = Receipt_Rejected then
         State.Gate.Fence;
         Item.Life.Cancel_Resolve;
         Receipt.Current_Outcome := Stale_Writer;
         Receipt.Phase := Resolved;
         Result := Stale_Writer;
      else
         Item.Life.Cancel_Resolve;
         Result := Outcome_Unknown;
      end if;
   end Resolve;

   function Receipt_Outcome (Item : Commit_Receipt) return Outcome_Code
   is (Item.Current_Outcome);

   function Receipt_Transaction_ID (Item : Commit_Receipt) return Transaction_Identifier
   is (Item.Transaction_ID);

   function Receipt_Sequence (Item : Commit_Receipt) return Sequence_Number
   is (Item.Assigned_Sequence);

   function Receipt_Batch_ID (Item : Commit_Receipt) return Identifier
   is (Item.Batch_ID);

   procedure Highest_Visible (Item : in out Database; Value : out Sequence_Number; Result : out Outcome_Code)
   is
   begin
      Value := Item.Life.Highest (Result);
   end Highest_Visible;

   procedure Set_Test_Paused (Item : in out Database; Value : Boolean; Result : out Outcome_Code) is
      Lease : Lifecycle_Lease;
   begin
      Acquire (Item, Lease, Result);
      if Result = Success then
         Lease.State.Gate.Set_Paused (Value);
      end if;
   end Set_Test_Paused;

   procedure Test_Queue_Depth (Item : in out Database; Value : out Natural; Result : out Outcome_Code) is
      Lease : Lifecycle_Lease;
   begin
      Value := 0;
      Acquire (Item, Lease, Result);
      if Result = Success then
         Value := Lease.State.Gate.Queue_Depth;
      end if;
   end Test_Queue_Depth;

   procedure Fail_Next_Test_Install (Item : in out Database; Result : out Outcome_Code) is
      Lease : Lifecycle_Lease;
   begin
      Acquire (Item, Lease, Result);
      if Result = Success then
         Lease.State.Gate.Fail_Next_Install;
      end if;
   end Fail_Next_Test_Install;

   procedure Set_Test_Get_Paused (Item : in out Storage_Context; Value : Boolean) is
   begin
      Item.Test_Control.Set_Get_Paused (Value);
   end Set_Test_Get_Paused;

   function Test_Get_Waiting (Item : Storage_Context) return Boolean is
   begin
      return Item.Test_Control.Get_Waiting;
   end Test_Get_Waiting;

   overriding
   procedure Finalize (Item : in out Database) is
      Result : Outcome_Code;
   begin
      Close (Item, Result);
   end Finalize;

end Flyology.DB;
