with Ada.Real_Time;
with Ada.Streams;
with Ada.Unchecked_Deallocation;
with Flyology.DB.Batch_Formats;
with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Flyology.DB.Manifest_Formats;
with Flyology.Object_Storage;

package body Flyology.DB is

   package OS renames Flyology.Object_Storage;
   package Backends renames Flyology.Object_Storage.Backends;
   package Batches renames Flyology.DB.Batch_Formats;
   package Heads renames Flyology.DB.Head_Policy;
   package Manifests renames Flyology.DB.Manifest_Formats;
   package UStrings renames Ada.Strings.Unbounded;

   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Byte;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Batches.Decode_Status;
   use type Batches.Encode_Status;
   use type Batches.Key_Bytes;
   use type Batches.Mutation_Kind;
   use type Flyology.DB.Formats.Decode_Status;
   use type Manifests.Decode_Status;
   use type Manifests.Encode_Status;
   use type Manifests.Family_Name_Bytes;
   use type Manifests.Manifest;
   use type OS.Status;

   Head_Key_Suffix   : constant String := "meta/HEAD";
   Commit_Key_Prefix : constant String := "commits/";
   Manifest_Key_Prefix : constant String := "manifests/";

   type Stored_Object_Kind is (Batch_Object, Manifest_Object, Head_Object);

   protected Incarnation_Source is
      procedure Allocate (Value : out Engine_Incarnation; Result : out Outcome_Code);
   private
      Last : Engine_Incarnation := No_Incarnation;
   end Incarnation_Source;

   protected body Incarnation_Source is
      procedure Allocate (Value : out Engine_Incarnation; Result : out Outcome_Code) is
      begin
         Value := No_Incarnation;
         if Last = Engine_Incarnation'Last then
            Result := Capacity_Exceeded;
         else
            Last := Last + 1;
            Value := Last;
            Result := Success;
         end if;
      end Allocate;
   end Incarnation_Source;

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

   function Same_Configuration
     (Left, Right : Column_Family_Configuration) return Boolean
   is (Left = Right);

   function To_Manifest_Configuration
     (Item : Column_Family_Configuration) return Manifests.Column_Family_Configuration
   is
      Result : Manifests.Column_Family_Configuration;
   begin
      Result.ID := Interfaces.Unsigned_32 (Item.ID);
      Result.Name_Length := Item.Name_Length;
      Result.Max_Key_Bytes := Item.Max_Key_Bytes;
      Result.Max_Value_Bytes := Item.Max_Value_Bytes;
      for Index in Item.Name'Range loop
         Result.Name (Index) := Item.Name (Index);
      end loop;
      return Result;
   end To_Manifest_Configuration;

   function From_Manifest_Configuration
     (Item : Manifests.Column_Family_Configuration) return Column_Family_Configuration
   is
      Result : Column_Family_Configuration;
   begin
      Result.ID := Column_Family_ID (Item.ID);
      Result.Name_Length := Item.Name_Length;
      Result.Max_Key_Bytes := Item.Max_Key_Bytes;
      Result.Max_Value_Bytes := Item.Max_Value_Bytes;
      for Index in Item.Name'Range loop
         Result.Name (Index) := Item.Name (Index);
      end loop;
      return Result;
   end From_Manifest_Configuration;

   function To_Manifest_Limits (Item : Database_Limits) return Manifests.Database_Limits
   is ((Maximum_Column_Families           => Item.Maximum_Column_Families,
        Maximum_Manifest_History          => Item.Maximum_Manifest_History,
        Maximum_Batch_History             => Item.Maximum_Batch_History,
        Maximum_Transactions_Per_Batch    => Item.Maximum_Transactions_Per_Batch,
        Maximum_Mutations_Per_Transaction => Item.Maximum_Mutations_Per_Transaction,
        Maximum_Mutations_Per_Batch       => Item.Maximum_Mutations_Per_Batch,
        Maximum_Live_Entries              => Item.Maximum_Live_Entries,
        Maximum_Transaction_Payload_Bytes => Item.Maximum_Transaction_Payload_Bytes,
        Maximum_Batch_Payload_Bytes       => Item.Maximum_Batch_Payload_Bytes,
        Maximum_Live_State_Bytes          => Item.Maximum_Live_State_Bytes));

   function To_Head (Item : Head_Snapshot) return Heads.Head_State
   is ((Database_ID            => To_Head_ID (Item.Database_ID),
        Version                => Heads.Format_Version (Item.Version),
        Epoch                  => Heads.Writer_Epoch (Item.Epoch),
        Highest_Visible        => Heads.Commit_Sequence (Item.Highest),
        Latest_Batch           => To_Head_ID (Item.Latest_Batch),
        Latest_Manifest        => To_Head_ID (Item.Latest_Manifest),
        Transition_ID          => To_Head_ID (Item.Transition_ID),
        Predecessor_Transition => To_Head_ID (Item.Predecessor_Transition),
        Transition_Number      => Heads.Transition_Ordinal (Item.Transition_Number)));

   function From_Head (Item : Heads.Head_State) return Head_Snapshot
   is ((Database_ID            => To_Database_ID (Item.Database_ID),
        Version                => Interfaces.Unsigned_16 (Item.Version),
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

   function Manifest_Key (Storage : Storage_Context; Manifest_ID : Identifier) return String
   is (Full_Key (Storage, Manifest_Key_Prefix & Identifier_Hex (Manifest_ID)));

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

      procedure Record_Put (Is_Head, Is_Manifest : Boolean) is
      begin
         if Is_Head then
            if Head_Puts < Natural'Last then
               Head_Puts := Head_Puts + 1;
            end if;
         elsif Is_Manifest then
            if Manifest_Puts < Natural'Last then
               Manifest_Puts := Manifest_Puts + 1;
            end if;
         else
            if Batch_Puts < Natural'Last then
               Batch_Puts := Batch_Puts + 1;
            end if;
         end if;
      end Record_Put;

      procedure Publication_Counts
        (Batch_Total : out Natural; Manifest_Total : out Natural; Head_Total : out Natural) is
      begin
         Batch_Total := Batch_Puts;
         Manifest_Total := Manifest_Puts;
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

      entry Await_Get when Waiting_Gets > 0 is
      begin
         null;
      end Await_Get;

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
         Kind       : Stored_Object_Kind;
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
         Kind       : Stored_Object_Kind;
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
         Kind       : Stored_Object_Kind;
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
         if Kind = Manifest_Object then
            Consume_Fault (Storage, Before_Manifest_Get, Fault);
         else
            Consume_Fault (Storage, Before_Get, Fault);
         end if;
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
         Storage.Test_Control.Record_Put
           (Is_Head     => Before_Point = Before_Head_Put,
            Is_Manifest => Before_Point = Before_Manifest_Put);
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
         Kind       : Stored_Object_Kind;
         Deadline   : Ada.Real_Time.Time;
         Token      : access Flyology.Cancellation.Token;
         Generation : out Generation_Value;
         Result     : out Put_Outcome)
      is
         Conditions   : OS.Write_Conditions := OS.Default_Write_Conditions;
         Before_Point : constant Storage_Fault_Point :=
           (case Kind is
              when Head_Object     => Before_Head_Put,
              when Manifest_Object => Before_Manifest_Put,
              when Batch_Object    => Before_Batch_Put);
         After_Point  : constant Storage_Fault_Point :=
           (case Kind is
              when Head_Object     => After_Head_Put,
              when Manifest_Object => After_Manifest_Put,
              when Batch_Object    => After_Batch_Put);
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
      procedure Initialize
        (Head        : Head_Snapshot;
         Generation  : Generation_Value;
         Manifest    : Manifests.Manifest;
         Stamp       : Engine_Incarnation);

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

      procedure Validate_Batch (Batch : Batches.Commit_Batch; Result : out Outcome_Code);

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

      procedure Find_Family
        (ID : Column_Family_ID; Configuration : out Column_Family_Configuration; Result : out Outcome_Code);

      procedure Find_Family
        (Name : Byte_Array; Configuration : out Column_Family_Configuration; Result : out Outcome_Code);

      procedure Validate_Family
        (Family : Column_Family; Configuration : out Column_Family_Configuration; Result : out Outcome_Code);

      procedure Validate_Transaction_Bounds
        (Mutation_Count : Natural; Payload_Bytes : Natural; Result : out Outcome_Code);

      function Current_Incarnation return Engine_Incarnation;

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
      Current_Manifest : Manifests.Manifest;
      Incarnation     : Engine_Incarnation := No_Incarnation;
      Live_State_Bytes : Natural range 0 .. Maximum_Live_State_Bytes := 0;
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

      procedure Initialize
        (Head        : Head_Snapshot;
         Generation  : Generation_Value;
         Manifest    : Manifests.Manifest;
         Stamp       : Engine_Incarnation) is
      begin
         Current_Head := Head;
         Head_Generation := Generation;
         Current_Manifest := Manifest;
         Incarnation := Stamp;
      end Initialize;

      procedure Apply_Batch
        (Batch               : Batches.Commit_Batch;
         Identities_Reserved : Boolean;
         Install             : Boolean;
         Result              : out Outcome_Code)
      is
         Identity_Found        : Boolean;
         Batch_ID              : constant Identifier := To_Identifier (Batch.Batch_ID);
         Additional_Identities : Natural := Batch.Transaction_Total;
         Candidate_Entries     : State_Entry_Array := [others => <>];
         Candidate_Count       : Natural range 0 .. Maximum_State_Entries := 0;
         Candidate_Bytes       : Natural range 0 .. Maximum_Live_State_Bytes := 0;
         Batch_Payload         : Interfaces.Unsigned_64 := 0;
         Policy_Failure        : constant Outcome_Code :=
           (if Identities_Reserved then Capacity_Exceeded else Corrupt);
         type Mutation_Projection is array (Batches.Mutation_Slot) of Batches.Mutation;
         type Mutation_Matches is array (Batches.Mutation_Slot) of Boolean;
         Projected       : Mutation_Projection := [others => <>];
         Projected_Count : Natural range 0 .. Batches.Max_Mutations := 0;
         Matched         : Mutation_Matches := [others => False];

         function Same_Mutation_Key (Left, Right : Batches.Mutation) return Boolean is
         begin
            return
              Left.Column_Family = Right.Column_Family
              and then Left.Key_Size = Right.Key_Size
              and then
              (Left.Key_Size = 0
               or else Left.Key (1 .. Left.Key_Size) = Right.Key (1 .. Right.Key_Size));
         end Same_Mutation_Key;

         function Matches_Entry (Mutation : Batches.Mutation; State_Item : State_Entry) return Boolean is
         begin
            if Mutation.Column_Family /= Interfaces.Unsigned_32 (State_Item.Family)
              or else Mutation.Key_Size /= State_Item.Item_Key.Length
            then
               return False;
            end if;
            for Index in Positive range 1 .. State_Item.Item_Key.Length loop
               if Mutation.Key (Index) /= State_Item.Item_Key.Bytes (Index) then
                  return False;
               end if;
            end loop;
            return True;
         end Matches_Entry;
      begin
         if Batch.Transaction_Total = 0
           or else Interfaces.Unsigned_32 (Batch.Transaction_Total) >
             Current_Manifest.Limits.Maximum_Transactions_Per_Batch
           or else Interfaces.Unsigned_32 (Batch.Mutation_Total) >
             Current_Manifest.Limits.Maximum_Mutations_Per_Batch
         then
            Result := Policy_Failure;
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
               Transaction_Payload : Interfaces.Unsigned_64 := 0;
            begin
               if Interfaces.Unsigned_32 (Batch.Transactions (Transaction_Index).Mutations) >
                 Current_Manifest.Limits.Maximum_Mutations_Per_Transaction
               then
                  Result := Policy_Failure;
                  return;
               end if;
               for Mutation_Index in Batches.Mutation_Slot range
                 Batch.Transactions (Transaction_Index).First_Mutation ..
                   Batch.Transactions (Transaction_Index).First_Mutation
                     + Batch.Transactions (Transaction_Index).Mutations - 1
               loop
                  declare
                     Mutation_Bytes : constant Interfaces.Unsigned_64 :=
                       Interfaces.Unsigned_64 (Batch.Mutations (Mutation_Index).Key_Size)
                       + Interfaces.Unsigned_64 (Batch.Mutations (Mutation_Index).Value_Size);
                  begin
                     Transaction_Payload := Transaction_Payload + Mutation_Bytes;
                  end;
               end loop;
               if Transaction_Payload > Current_Manifest.Limits.Maximum_Transaction_Payload_Bytes
                 or else Batch_Payload >
                   Current_Manifest.Limits.Maximum_Batch_Payload_Bytes - Transaction_Payload
               then
                  Result := Policy_Failure;
                  return;
               end if;
               Batch_Payload := Batch_Payload + Transaction_Payload;
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
               Family   : Manifests.Column_Family_Configuration;
               Family_Found : Boolean := False;
               Projection_Index : Natural := 0;
            begin
               for Family_Index in Manifests.Family_Slot range 1 .. Current_Manifest.Family_Total loop
                  if Current_Manifest.Families (Family_Index).ID = Mutation.Column_Family then
                     Family := Current_Manifest.Families (Family_Index);
                     Family_Found := True;
                     exit;
                  end if;
               end loop;
               if not Family_Found
                 or else Interfaces.Unsigned_64 (Mutation.Key_Size) > Family.Max_Key_Bytes
                 or else Interfaces.Unsigned_64 (Mutation.Value_Size) > Family.Max_Value_Bytes
               then
                  Result := Policy_Failure;
                  return;
               end if;
               for Existing in Batches.Mutation_Slot range 1 .. Projected_Count loop
                  if Same_Mutation_Key (Projected (Existing), Mutation) then
                     Projection_Index := Existing;
                     exit;
                  end if;
               end loop;
               if Projection_Index = 0 then
                  Projected_Count := Projected_Count + 1;
                  Projection_Index := Projected_Count;
               end if;
               Projected (Projection_Index) := Mutation;
            end;
         end loop;

         for Existing in Positive range 1 .. Entry_Count loop
            declare
               Projection_Index : Natural := 0;
               Item_Key         : constant Key := Entries (Existing).Item_Key;
               Data             : Value := Entries (Existing).Data;
               Entry_Bytes      : Natural;
            begin
               for Index in Batches.Mutation_Slot range 1 .. Projected_Count loop
                  if Matches_Entry (Projected (Index), Entries (Existing)) then
                     Projection_Index := Index;
                     Matched (Index) := True;
                     exit;
                  end if;
               end loop;
               if Projection_Index = 0 or else Projected (Projection_Index).Operation = Batches.Put then
                  if Projection_Index > 0 then
                     Data := (others => <>);
                     Data.Length := Value_Length (Projected (Projection_Index).Value_Size);
                     for Byte_Index in Positive range 1 .. Data.Length loop
                        Data.Bytes (Byte_Index) := Projected (Projection_Index).Value (Byte_Index);
                     end loop;
                  end if;
                  Entry_Bytes := Item_Key.Length + Data.Length;
                  if Candidate_Bytes > Maximum_Live_State_Bytes - Entry_Bytes then
                     Result := Policy_Failure;
                     return;
                  end if;
                  Candidate_Count := Candidate_Count + 1;
                  Candidate_Bytes := Candidate_Bytes + Entry_Bytes;
                  Candidate_Entries (Candidate_Count) :=
                    (Family => Entries (Existing).Family, Item_Key => Item_Key, Data => Data);
               end if;
            end;
         end loop;

         for Index in Batches.Mutation_Slot range 1 .. Projected_Count loop
            if not Matched (Index) and then Projected (Index).Operation = Batches.Put then
               declare
                  Item_Key    : Key;
                  Data        : Value;
                  Entry_Bytes : constant Natural :=
                    Projected (Index).Key_Size + Projected (Index).Value_Size;
               begin
                  if Candidate_Count = Maximum_State_Entries
                    or else Candidate_Bytes > Maximum_Live_State_Bytes - Entry_Bytes
                  then
                     Result := Policy_Failure;
                     return;
                  end if;
                  Item_Key.Length := Key_Length (Projected (Index).Key_Size);
                  for Byte_Index in Positive range 1 .. Item_Key.Length loop
                     Item_Key.Bytes (Byte_Index) := Projected (Index).Key (Byte_Index);
                  end loop;
                  Data.Length := Value_Length (Projected (Index).Value_Size);
                  for Byte_Index in Positive range 1 .. Data.Length loop
                     Data.Bytes (Byte_Index) := Projected (Index).Value (Byte_Index);
                  end loop;
                  Candidate_Count := Candidate_Count + 1;
                  Candidate_Bytes := Candidate_Bytes + Entry_Bytes;
                  Candidate_Entries (Candidate_Count) :=
                    (Family => Column_Family_ID (Projected (Index).Column_Family),
                     Item_Key => Item_Key,
                     Data => Data);
               end;
            end if;
         end loop;
         if Interfaces.Unsigned_32 (Candidate_Count) > Current_Manifest.Limits.Maximum_Live_Entries
           or else Interfaces.Unsigned_64 (Candidate_Bytes) >
             Current_Manifest.Limits.Maximum_Live_State_Bytes
         then
            Result := Policy_Failure;
            return;
         end if;
         if Install then
            Entries := Candidate_Entries;
            Entry_Count := Candidate_Count;
            Live_State_Bytes := Candidate_Bytes;
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
         end if;
         Result := Success;
      end Apply_Batch;

      procedure Recover_Batch (Batch : Batches.Commit_Batch; Result : out Outcome_Code) is
      begin
         Apply_Batch (Batch, False, True, Result);
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
         elsif Current_Manifest.Limits.Maximum_Transactions_Per_Batch < 1
           or else Interfaces.Unsigned_32 (Txn.Mutation_Count) >
             Current_Manifest.Limits.Maximum_Mutations_Per_Batch
           or else Interfaces.Unsigned_64 (Txn.Bytes_Used) >
             Current_Manifest.Limits.Maximum_Batch_Payload_Bytes
         then
            Result := Capacity_Exceeded;
            return;
         elsif In_Use_Count = Maximum_Commit_Slots
           or else In_Flight_Bytes > Maximum_Commit_Bytes - Txn.Bytes_Used
           or else History_Count = Maximum_History_Batches
           or else Interfaces.Unsigned_32 (History_Count) =
             Current_Manifest.Limits.Maximum_Batch_History
           or else Seen_Count = Maximum_Seen_Transactions
           or else Reserved_Count = Maximum_Reserved_Identities
         then
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
         elsif Interfaces.Unsigned_32 (Transactions'Length) >
           Current_Manifest.Limits.Maximum_Transactions_Per_Batch
         then
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
           or else Interfaces.Unsigned_32 (History_Count) =
             Current_Manifest.Limits.Maximum_Batch_History
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
         if Interfaces.Unsigned_32 (Total_Mutations) >
           Current_Manifest.Limits.Maximum_Mutations_Per_Batch
           or else Interfaces.Unsigned_64 (Total_Bytes) >
             Current_Manifest.Limits.Maximum_Batch_Payload_Bytes
         then
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
         end loop;
         Result := Success;
      end Prepublication_Check;

      procedure Validate_Batch (Batch : Batches.Commit_Batch; Result : out Outcome_Code) is
      begin
         Apply_Batch (Batch, True, False, Result);
      end Validate_Batch;

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
         Apply_Batch (Batch, True, True, Result);
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

      procedure Find_Family
        (ID : Column_Family_ID; Configuration : out Column_Family_Configuration; Result : out Outcome_Code)
      is
      begin
         Configuration := (others => <>);
         for Index in Manifests.Family_Slot range 1 .. Current_Manifest.Family_Total loop
            if Current_Manifest.Families (Index).ID = Interfaces.Unsigned_32 (ID) then
               Configuration := From_Manifest_Configuration (Current_Manifest.Families (Index));
               Result := Success;
               return;
            end if;
         end loop;
         Result := Not_Found;
      end Find_Family;

      procedure Find_Family
        (Name : Byte_Array; Configuration : out Column_Family_Configuration; Result : out Outcome_Code)
      is
         Candidate : Manifests.Column_Family_Configuration;
      begin
         Configuration := (others => <>);
         if Name'Length = 0 or else Name'Length > Maximum_Column_Family_Name_Bytes then
            Result := Not_Found;
            return;
         end if;
         Candidate.Name_Length := Name'Length;
         for Offset in Natural range 0 .. Name'Length - 1 loop
            Candidate.Name (Offset + 1) := Name (Name'First + Offset);
         end loop;
         for Index in Manifests.Family_Slot range 1 .. Current_Manifest.Family_Total loop
            if Current_Manifest.Families (Index).Name_Length = Candidate.Name_Length
              and then Current_Manifest.Families (Index).Name (1 .. Candidate.Name_Length) =
                Candidate.Name (1 .. Candidate.Name_Length)
            then
               Configuration := From_Manifest_Configuration (Current_Manifest.Families (Index));
               Result := Success;
               return;
            end if;
         end loop;
         Result := Not_Found;
      end Find_Family;

      procedure Validate_Family
        (Family : Column_Family; Configuration : out Column_Family_Configuration; Result : out Outcome_Code)
      is
      begin
         Configuration := (others => <>);
         if not Family.Valid
           or else Family.Database_ID /= Current_Head.Database_ID
           or else Family.Incarnation /= Incarnation
         then
            Result := Invalid_State;
            return;
         end if;
         Find_Family (Family.Configuration.ID, Configuration, Result);
         if Result = Success and then not Same_Configuration (Configuration, Family.Configuration) then
            Configuration := (others => <>);
            Result := Invalid_State;
         end if;
      end Validate_Family;

      procedure Validate_Transaction_Bounds
        (Mutation_Count : Natural; Payload_Bytes : Natural; Result : out Outcome_Code) is
      begin
         if Interfaces.Unsigned_32 (Mutation_Count) >
           Current_Manifest.Limits.Maximum_Mutations_Per_Transaction
           or else Interfaces.Unsigned_64 (Payload_Bytes) >
             Current_Manifest.Limits.Maximum_Transaction_Payload_Bytes
         then
            Result := Capacity_Exceeded;
         else
            Result := Success;
         end if;
      end Validate_Transaction_Bounds;

      function Current_Incarnation return Engine_Incarnation
      is (Incarnation);

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

   type Activation_Guard is new Ada.Finalization.Limited_Controlled with record
      Life   : Database_Lifecycle_Access := null;
      Active : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Activation_Guard) is
   begin
      if Item.Active and then Item.Life /= null then
         Item.Life.Abort_Open;
         Item.Active := False;
      end if;
   end Finalize;

   type Resolve_Guard is new Ada.Finalization.Limited_Controlled with record
      Life   : Database_Lifecycle_Access := null;
      Active : Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Resolve_Guard) is
   begin
      if Item.Active and then Item.Life /= null then
         Item.Life.Cancel_Resolve;
         Item.Active := False;
      end if;
   end Finalize;

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

   procedure Copy_Manifest_Image
     (Image : Manifests.Manifest_Image; Length : Natural; Target : out Object_Buffer) is
   begin
      Target := [others => 0];
      if Length > 0 then
         for Index in Natural range 0 .. Length - 1 loop
            Target (Index) := Image (Index);
         end loop;
      end if;
   end Copy_Manifest_Image;

   function Exact_Bytes
     (Left : Object_Buffer; Left_Length : Natural; Right : Object_Buffer; Right_Length : Natural)
      return Boolean is
   begin
      return
        Left_Length = Right_Length
        and then (Left_Length = 0 or else Left (0 .. Left_Length - 1) = Right (0 .. Right_Length - 1));
   end Exact_Bytes;

   function Head_Database_ID (Data : Object_Buffer) return Database_Identifier is
      Result : Database_Identifier := Zero_Database_ID;
   begin
      for Index in Identifier_Index loop
         Result (Index) := Data (11 + Index);
      end loop;
      return Result;
   end Head_Database_ID;

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
      if Expected.Version /= Interfaces.Unsigned_16 (Heads.Current_Format)
        or else Is_Zero (Expected.Latest_Manifest)
      then
         Result := Unsupported_Format;
         return;
      elsif Count = 0
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
            Version                => Expected.Version,
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
      State.Gate.Validate_Batch (Batch, Result);
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
         Batch_Object,
         Deadline,
         Token,
         Ignored_Generation,
         Put_Result);
      if Put_Result /= Object_Published then
         if Put_Result = Put_Outcome_Unknown then
            Storage_Port.Get_Whole
              (State.Storage.all,
              Batch_Key (State.Storage.all, Receipts (1).Batch_ID),
               Batch_Object,
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
   type Manifest_History is array (History_Slot) of Manifests.Manifest;

   procedure Decode_Stored_Manifest
     (Data              : Object_Buffer;
      Length            : Natural;
      Expected_Database : Database_Identifier;
      Value             : out Manifests.Manifest;
      Result            : out Outcome_Code)
   is
      Status : Manifests.Decode_Status;
   begin
      Value := Manifests.Empty_Manifest;
      if Length = 0 or else Length > Manifests.Max_Manifest_Image_Length then
         Result := Corrupt;
         return;
      end if;
      declare
         Image : Formats.Byte_Array (0 .. Length - 1);
      begin
         for Index in Image'Range loop
            Image (Index) := Data (Index);
         end loop;
         Manifests.Decode_Manifest
           (Image, To_Head_ID (Expected_Database), Manifests.Default_Reader_Caps, Value, Status);
      end;
      Result :=
        (if Status = Manifests.Decoded then Success
         elsif Status = Manifests.Limit_Exceeded then Capacity_Exceeded
         else Corrupt);
   end Decode_Stored_Manifest;

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
      Manifest    : out Manifests.Manifest;
      Root        : out Manifests.Manifest;
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
      Ignored_Generation : Generation_Value;
      Manifests_Seen   : Manifest_History := [others => Manifests.Empty_Manifest];
      Manifest_Count   : Natural := 0;
      Current_Manifest_ID : Identifier;
   begin
      Head := (others => <>);
      Generation := (others => <>);
      Manifest := Manifests.Empty_Manifest;
      Root := Manifests.Empty_Manifest;
      History := [others => Batches.Empty_Batch];
      Count := 0;
      Storage_Port.Get_Whole
        (Storage,
         Full_Key (Storage, Head_Key_Suffix),
         Head_Object,
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
            Result :=
              (if Decode_Result = Formats.Unsupported_Version then Unsupported_Format else Corrupt);
            return;
         end if;
         Head := From_Head (Value);
      end;
      if Head.Version = Interfaces.Unsigned_16 (Heads.Legacy_Format) then
         Result := Unsupported_Format;
         return;
      elsif Head.Version /= Interfaces.Unsigned_16 (Heads.Current_Format)
        or else Is_Zero (Head.Latest_Manifest)
      then
         Result := Corrupt;
         return;
      end if;

      Current_Manifest_ID := Head.Latest_Manifest;
      loop
         if Manifest_Count = Maximum_History_Batches then
            Result :=
              (if Manifests_Seen (1).Limits.Maximum_Manifest_History <=
                   Maximum_History_Batches
               then Corrupt
               else Capacity_Exceeded);
            return;
         elsif Manifest_Count > 0
           and then Interfaces.Unsigned_32 (Manifest_Count) =
             Manifests_Seen (1).Limits.Maximum_Manifest_History
         then
            Result := Corrupt;
            return;
         end if;
         Storage_Port.Get_Whole
           (Storage,
            Manifest_Key (Storage, Current_Manifest_ID),
            Manifest_Object,
            Deadline,
            Token,
            Data,
            Length,
            Ignored_Generation,
            Read_Result);
         if Read_Result /= Object_Read then
            Result :=
              (if Read_Result = Read_Cancelled then Cancelled
               elsif Read_Result = Read_Timed_Out then Timed_Out
               elsif Read_Result in Object_Missing | Read_Corrupt then Corrupt
               else Storage_Failure);
            return;
         end if;
         Manifest_Count := Manifest_Count + 1;
         Decode_Stored_Manifest
           (Data, Length, Database_ID, Manifests_Seen (Manifest_Count), Result);
         if Result /= Success then
            return;
         elsif To_Identifier (Manifests_Seen (Manifest_Count).Manifest_ID) /= Current_Manifest_ID
         then
            Result := Corrupt;
            return;
         elsif Manifest_Count = 1
           and then not Manifests.Referenced_By (Manifests_Seen (1), To_Head (Head))
         then
            Result := Corrupt;
            return;
         elsif Manifest_Count > 1
           and then not Manifests.Valid_Predecessor
             (Manifests_Seen (Manifest_Count - 1), Manifests_Seen (Manifest_Count))
         then
            Result := Corrupt;
            return;
         elsif Manifests.Is_Root (Manifests_Seen (Manifest_Count)) then
            Root := Manifests_Seen (Manifest_Count);
            exit;
         end if;
         Current_Manifest_ID :=
           To_Identifier (Manifests_Seen (Manifest_Count).Previous_Manifest_ID);
      end loop;
      Manifest := Manifests_Seen (1);
      if not Manifests.Runtime_Compatible (Manifest) then
         Result := Capacity_Exceeded;
         return;
      elsif Head.Highest = 0 then
         Result := Success;
         return;
      end if;

      Current_Batch_ID := Head.Latest_Batch;
      loop
         if Count = Maximum_History_Batches
           or else Interfaces.Unsigned_32 (Count) = Manifest.Limits.Maximum_Batch_History
         then
            Result := Corrupt;
            return;
         end if;
         Storage_Port.Get_Whole
           (Storage,
            Batch_Key (Storage, Current_Batch_ID),
            Batch_Object,
            Deadline,
            Token,
            Data,
            Length,
            Ignored_Generation,
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

   procedure Reconcile_Create_Head
     (Storage       : in out Storage_Context;
      Expected_Root : Manifests.Manifest;
      Observed_Data : Object_Buffer;
      Observed_Length : Natural;
      Deadline      : Ada.Real_Time.Time;
      Token         : access Flyology.Cancellation.Token;
      Head          : out Head_Snapshot;
      Generation    : out Generation_Value;
      Manifest      : out Manifests.Manifest;
      History       : out Batch_History;
      Count         : out Natural;
      Result        : out Outcome_Code)
   is
      Observed_Database : Database_Identifier := Zero_Database_ID;
      Root              : Manifests.Manifest;
      Read_Result       : Outcome_Code;
   begin
      Head := (others => <>);
      Generation := (others => <>);
      Manifest := Manifests.Empty_Manifest;
      History := [others => Batches.Empty_Batch];
      Count := 0;
      if Observed_Length /= Formats.Head_Image_Length then
         Result := Corrupt;
         return;
      end if;
      Observed_Database := Head_Database_ID (Observed_Data);
      if Is_Zero (Observed_Database) then
         Result := Corrupt;
         return;
      end if;
      Read_Recovery
        (Storage,
         Observed_Database,
         Deadline,
         Token,
         Head,
         Generation,
         Manifest,
         Root,
         History,
         Count,
         Read_Result);
      if Read_Result = Success then
         if Observed_Database = To_Database_ID (Expected_Root.Database_ID)
           and then Root = Expected_Root
         then
            Result := Success;
         else
            Result := Already_Exists;
         end if;
      elsif Read_Result = Unsupported_Format then
         Result :=
           (if Observed_Data (8) = 0
              and then Observed_Data (9) = Byte (Formats.Legacy_Head_Format_Version)
            then Already_Exists
            else Unsupported_Format);
      elsif Read_Result = Corrupt then
         Result := Corrupt;
      elsif Read_Result = Capacity_Exceeded then
         Result := Capacity_Exceeded;
      else
         Result := Outcome_Unknown;
      end if;
   end Reconcile_Create_Head;

   procedure Allocate_Engine
     (Life       : not null Database_Lifecycle_Access;
      Storage    : not null access Storage_Context;
      Head       : Head_Snapshot;
      Generation : Generation_Value;
      Manifest   : Manifests.Manifest;
      Incarnation : Engine_Incarnation;
      History    : Batch_History;
      Count      : Natural;
      State      : out Engine_State_Access;
      Result     : out Outcome_Code) is
   begin
      State := new Engine_State;
      --  Database retains this caller-owned context only until Close/Finalize.
      State.Storage := Storage.all'Unchecked_Access;
      State.Life := Life;
      State.Gate.Initialize (Head, Generation, Manifest, Incarnation);
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
      Manifest   : Manifests.Manifest;
      Incarnation : Engine_Incarnation;
      History    : Batch_History;
      Count      : Natural;
      Result     : out Outcome_Code)
   is
      State : Engine_State_Access;
   begin
      Allocate_Engine
        (Item.Life'Unchecked_Access,
         Storage,
         Head,
         Generation,
         Manifest,
         Incarnation,
         History,
         Count,
         State,
         Result);
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

   function Configure_Column_Family
     (ID              : Column_Family_ID;
      Name            : Byte_Array;
      Max_Key_Bytes   : Interfaces.Unsigned_64;
      Max_Value_Bytes : Interfaces.Unsigned_64) return Column_Family_Configuration
   is
      Candidate : Manifests.Column_Family_Configuration;
   begin
      if Name'Length = 0 or else Name'Length > Maximum_Column_Family_Name_Bytes then
         raise Constraint_Error with "column-family name length is invalid";
      end if;
      Candidate.ID := Interfaces.Unsigned_32 (ID);
      Candidate.Name_Length := Name'Length;
      Candidate.Max_Key_Bytes := Max_Key_Bytes;
      Candidate.Max_Value_Bytes := Max_Value_Bytes;
      for Offset in Natural range 0 .. Name'Length - 1 loop
         Candidate.Name (Offset + 1) := Name (Name'First + Offset);
      end loop;
      if not Manifests.Valid_Configuration (Candidate) then
         raise Constraint_Error with "column-family configuration is invalid";
      end if;
      return From_Manifest_Configuration (Candidate);
   end Configure_Column_Family;

   procedure Build_Root_Manifest
     (Database_ID           : Database_Identifier;
      Manifest_ID           : Identifier;
      Initial_Transition_ID : Identifier;
      Limits                : Database_Limits;
      Initial_Families      : Column_Family_Configuration_Array;
      Value                 : out Manifests.Manifest;
      Result                : out Outcome_Code)
   is
      Candidate : Manifests.Manifest;
      Moved     : Manifests.Column_Family_Configuration;
      Position  : Positive;
   begin
      Value := Manifests.Empty_Manifest;
      if Is_Zero (Database_ID)
        or else Is_Zero (Manifest_ID)
        or else Is_Zero (Initial_Transition_ID)
        or else Initial_Families'Length = 0
        or else Initial_Families'Length > Maximum_Initial_Column_Families
      then
         Result := Invalid_State;
         return;
      end if;
      Candidate.Database_ID := To_Head_ID (Database_ID);
      Candidate.Manifest_ID := To_Head_ID (Manifest_ID);
      Candidate.Publication_Transition_ID := To_Head_ID (Initial_Transition_ID);
      Candidate.Publication_Transition_Number := 1;
      Candidate.Writer_Epoch := 1;
      Candidate.Registry_Revision := 1;
      Candidate.Family_Total := Initial_Families'Length;
      Candidate.Limits := To_Manifest_Limits (Limits);
      for Offset in Natural range 0 .. Initial_Families'Length - 1 loop
         Candidate.Families (Offset + 1) :=
           To_Manifest_Configuration (Initial_Families (Initial_Families'First + Offset));
      end loop;
      for Index in Manifests.Family_Slot range 2 .. Candidate.Family_Total loop
         Moved := Candidate.Families (Index);
         Position := Index;
         while Position > 1 and then Candidate.Families (Position - 1).ID > Moved.ID loop
            Candidate.Families (Position) := Candidate.Families (Position - 1);
            Position := Position - 1;
         end loop;
         Candidate.Families (Position) := Moved;
      end loop;
      if not Manifests.Structurally_Valid (Candidate) then
         Result := Invalid_State;
      elsif not Manifests.Runtime_Compatible (Candidate) then
         Result := Capacity_Exceeded;
      else
         Value := Candidate;
         Result := Success;
      end if;
   end Build_Root_Manifest;

   procedure Create
     (Item                  : in out Database;
      Storage               : not null access Storage_Context;
      Database_ID           : Database_Identifier;
      Manifest_ID           : Identifier;
      Initial_Transition_ID : Identifier;
      Limits                : Database_Limits;
      Initial_Families      : Column_Family_Configuration_Array;
      Timeout               : Duration;
      Token                 : access Flyology.Cancellation.Token := null;
      Receipt               : out Create_Receipt;
      Result                : out Outcome_Code)
   is
      Deadline        : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Head            : Head_Snapshot;
      Head_Image      : Formats.Head_Image;
      Head_Data       : Object_Buffer;
      Manifest_Value  : Manifests.Manifest;
      Manifest_Image  : Manifests.Manifest_Image;
      Manifest_Length : Natural;
      Encode_Result   : Manifests.Encode_Status;
      Manifest_Data   : Object_Buffer;
      Read_Data       : Object_Buffer;
      Length          : Natural;
      Generation      : Generation_Value;
      Read_Generation : Generation_Value;
      Put_Result      : Put_Outcome;
      Read_Result     : Read_Outcome;
      History         : constant Batch_History := [others => Batches.Empty_Batch];
      Bucket_Result   : Outcome_Code;
      Stamp           : Engine_Incarnation;
      Activation_Fault : Storage_Fault_Mode;
      Guard           : Activation_Guard;
      pragma Unreferenced (Guard);

      procedure Finish_Activation
        (Activated_Head       : Head_Snapshot;
         Activated_Generation : Generation_Value;
         Activated_Manifest   : Manifests.Manifest;
         Activated_History    : Batch_History;
         Activated_Count      : Natural) is
      begin
         Receipt.Phase := Head_Confirmed;
         Receipt.Current_Outcome := Success;
         Consume_Fault (Storage.all, Before_Local_Activation, Activation_Fault);
         if Activation_Fault /= No_Fault then
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
            return;
         end if;
         Incarnation_Source.Allocate (Stamp, Result);
         if Result = Success then
            Start_Engine
              (Item,
               Storage,
               Activated_Head,
               Activated_Generation,
               Activated_Manifest,
               Stamp,
               Activated_History,
               Activated_Count,
               Result);
         end if;
         if Result = Success then
            Guard.Active := False;
         else
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
         end if;
      end Finish_Activation;

      procedure Attempt_Head is
      begin
         if Token /= null and then Token.Requested then
            Result := Cancelled;
            Receipt.Current_Outcome := Result;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            Receipt.Current_Outcome := Result;
            return;
         end if;
         Storage_Port.Put_Create
           (Storage.all,
            Full_Key (Storage.all, Head_Key_Suffix),
            Head_Data,
            Formats.Head_Image_Length,
            Head_Object,
            Deadline,
            Token,
            Generation,
            Put_Result);
         if Put_Result = Object_Published then
            Finish_Activation (Head, Generation, Manifest_Value, History, 0);
         elsif Put_Result in Put_Outcome_Unknown | Put_Precondition_Failed then
            if Put_Result = Put_Outcome_Unknown then
               Receipt.Phase := Head_Publication_Unknown;
            end if;
            Storage_Port.Get_Whole
              (Storage.all,
               Full_Key (Storage.all, Head_Key_Suffix),
               Head_Object,
               Deadline,
               Token,
               Read_Data,
               Length,
               Read_Generation,
               Read_Result);
            if Read_Result = Object_Read
              and then Exact_Bytes (Head_Data, Formats.Head_Image_Length, Read_Data, Length)
            then
               Generation := Read_Generation;
               Finish_Activation (Head, Read_Generation, Manifest_Value, History, 0);
            elsif Read_Result = Object_Read then
               declare
                  Observed_Head     : Head_Snapshot;
                  Observed_Manifest : Manifests.Manifest;
                  Observed_History  : Batch_History;
                  Observed_Count    : Natural;
               begin
                  Reconcile_Create_Head
                    (Storage.all,
                     Manifest_Value,
                     Read_Data,
                     Length,
                     Deadline,
                     Token,
                     Observed_Head,
                     Read_Generation,
                     Observed_Manifest,
                     Observed_History,
                     Observed_Count,
                     Result);
                  if Result = Success then
                     Finish_Activation
                       (Observed_Head,
                        Read_Generation,
                        Observed_Manifest,
                        Observed_History,
                        Observed_Count);
                  else
                     Receipt.Current_Outcome := Result;
                  end if;
               end;
            elsif Put_Result = Put_Precondition_Failed then
               Result := Outcome_Unknown;
               Receipt.Current_Outcome := Result;
            else
               Result := Outcome_Unknown;
               Receipt.Current_Outcome := Result;
            end if;
         elsif Put_Result = Put_Cancelled then
            Result := Cancelled;
            Receipt.Current_Outcome := Result;
         elsif Put_Result = Put_Timed_Out then
            Result := Timed_Out;
            Receipt.Current_Outcome := Result;
         else
            Result := Storage_Failure;
            Receipt.Current_Outcome := Result;
         end if;
      end Attempt_Head;
   begin
      Receipt := (others => <>);
      Build_Root_Manifest
        (Database_ID, Manifest_ID, Initial_Transition_ID, Limits, Initial_Families, Manifest_Value, Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Manifests.Encode_Manifest (Manifest_Value, Manifest_Image, Manifest_Length, Encode_Result);
      if Encode_Result /= Manifests.Encoded
        or else Storage.Backend = null
        or else not OS.Valid_Object_Key (Manifest_Key (Storage.all, Manifest_ID))
        or else not OS.Valid_Object_Key (Full_Key (Storage.all, Head_Key_Suffix))
      then
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Copy_Manifest_Image (Manifest_Image, Manifest_Length, Manifest_Data);
      Receipt.Database_ID := Database_ID;
      Receipt.Manifest_ID := Manifest_ID;
      Receipt.Manifest_Length := Manifest_Length;
      for Index in Natural range 0 .. Manifest_Length - 1 loop
         Receipt.Manifest_Image (Index) := Manifest_Data (Index);
      end loop;
      Head :=
        (Database_ID            => Database_ID,
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => Manifest_ID,
         Transition_ID          => Initial_Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Receipt.Attempted_Head := Head;
      Head_Image := Formats.Encode_Head (To_Head (Head));
      Copy_Head_Image (Head_Image, Head_Data);
      Item.Life.Begin_Open (Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Storage_Port.Bucket_Available (Storage.all, Deadline, Token, Bucket_Result);
      if Bucket_Result /= Success then
         Result := Bucket_Result;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Storage_Port.Put_Create
        (Storage.all,
         Manifest_Key (Storage.all, Manifest_ID),
         Manifest_Data,
         Manifest_Length,
         Manifest_Object,
         Deadline,
         Token,
         Generation,
         Put_Result);
      if Put_Result = Object_Published then
         Receipt.Phase := Manifest_Confirmed;
         Attempt_Head;
      elsif Put_Result in Put_Outcome_Unknown | Put_Precondition_Failed then
         Storage_Port.Get_Whole
           (Storage.all,
            Manifest_Key (Storage.all, Manifest_ID),
            Manifest_Object,
            Deadline,
            Token,
            Read_Data,
            Length,
            Read_Generation,
            Read_Result);
         if Read_Result = Object_Read
           and then Exact_Bytes (Manifest_Data, Manifest_Length, Read_Data, Length)
         then
            Receipt.Phase := Manifest_Confirmed;
            Attempt_Head;
         elsif Read_Result = Object_Read then
            Result := Already_Exists;
            Receipt.Current_Outcome := Result;
         else
            Result := Outcome_Unknown;
            Receipt.Current_Outcome := Result;
         end if;
      elsif Put_Result = Put_Cancelled then
         Result := Cancelled;
         Receipt.Current_Outcome := Result;
      elsif Put_Result = Put_Timed_Out then
         Result := Timed_Out;
         Receipt.Current_Outcome := Result;
      else
         Result := Storage_Failure;
         Receipt.Current_Outcome := Result;
      end if;
   exception
      when others =>
         Result :=
           (if Receipt.Phase = Head_Confirmed then Local_Activation_Failed
            elsif Receipt.Phase = Head_Publication_Unknown then Outcome_Unknown
            else Storage_Failure);
         Receipt.Current_Outcome := Result;
   end Create;

   procedure Resolve_Create
     (Item    : in out Database;
      Storage : not null access Storage_Context;
      Receipt : in out Create_Receipt;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null;
      Result  : out Outcome_Code)
   is
      Deadline        : constant Ada.Real_Time.Time := Deadline_After (Timeout);
      Manifest_Value  : Manifests.Manifest;
      Decode_Result   : Outcome_Code;
      Manifest_Data   : Object_Buffer := [others => 0];
      Head_Image      : Formats.Head_Image;
      Head_Data       : Object_Buffer;
      Read_Data       : Object_Buffer;
      Length          : Natural;
      Generation      : Generation_Value;
      Put_Result      : Put_Outcome;
      Read_Result     : Read_Outcome;
      Bucket_Result   : Outcome_Code;
      History         : constant Batch_History := [others => Batches.Empty_Batch];
      Stamp           : Engine_Incarnation;
      Activation_Fault : Storage_Fault_Mode;
      Guard           : Activation_Guard;
      pragma Unreferenced (Guard);

      procedure Activate
        (Activated_Head       : Head_Snapshot;
         Activated_Generation : Generation_Value;
         Activated_Manifest   : Manifests.Manifest;
         Activated_History    : Batch_History;
         Activated_Count      : Natural) is
      begin
         Receipt.Phase := Head_Confirmed;
         Receipt.Current_Outcome := Success;
         Consume_Fault (Storage.all, Before_Local_Activation, Activation_Fault);
         if Activation_Fault /= No_Fault then
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
            return;
         end if;
         Incarnation_Source.Allocate (Stamp, Result);
         if Result = Success then
            Start_Engine
              (Item,
               Storage,
               Activated_Head,
               Activated_Generation,
               Activated_Manifest,
               Stamp,
               Activated_History,
               Activated_Count,
               Result);
         end if;
         if Result = Success then
            Guard.Active := False;
         else
            Receipt.Current_Outcome := Local_Activation_Failed;
            Result := Local_Activation_Failed;
         end if;
      end Activate;
   begin
      if Receipt.Manifest_Length > 0 then
         for Index in Natural range 0 .. Receipt.Manifest_Length - 1 loop
            Manifest_Data (Index) := Receipt.Manifest_Image (Index);
         end loop;
      end if;
      if Receipt.Phase = Head_Confirmed then
         Result := Local_Activation_Failed;
         Receipt.Current_Outcome := Result;
         return;
      elsif Receipt.Database_ID = Zero_Database_ID
        or else Is_Zero (Receipt.Manifest_ID)
        or else Receipt.Manifest_Length = 0
        or else Storage.Backend = null
      then
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Decode_Stored_Manifest
        (Manifest_Data,
         Receipt.Manifest_Length,
         Receipt.Database_ID,
         Manifest_Value,
         Decode_Result);
      if Decode_Result /= Success
        or else To_Identifier (Manifest_Value.Manifest_ID) /= Receipt.Manifest_ID
        or else not Manifests.Valid_Root_Publication
          (To_Head (Receipt.Attempted_Head), Manifest_Value)
        or else not OS.Valid_Object_Key (Manifest_Key (Storage.all, Receipt.Manifest_ID))
        or else not OS.Valid_Object_Key (Full_Key (Storage.all, Head_Key_Suffix))
      then
         Result := Invalid_State;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Head_Image := Formats.Encode_Head (To_Head (Receipt.Attempted_Head));
      Copy_Head_Image (Head_Image, Head_Data);
      Item.Life.Begin_Open (Result);
      if Result /= Success then
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Storage_Port.Bucket_Available (Storage.all, Deadline, Token, Bucket_Result);
      if Bucket_Result /= Success then
         Result := Bucket_Result;
         Receipt.Current_Outcome := Result;
         return;
      end if;
      Storage_Port.Get_Whole
        (Storage.all,
         Manifest_Key (Storage.all, Receipt.Manifest_ID),
         Manifest_Object,
         Deadline,
         Token,
         Read_Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result = Object_Read
        and then Exact_Bytes (Manifest_Data, Receipt.Manifest_Length, Read_Data, Length)
      then
         if Receipt.Phase = No_Create_Publication then
            Receipt.Phase := Manifest_Confirmed;
         end if;
      elsif Read_Result = Object_Read then
         Result := (if Receipt.Phase = No_Create_Publication then Already_Exists else Corrupt);
         Receipt.Current_Outcome := Result;
         return;
      elsif Read_Result = Object_Missing then
         Result := (if Receipt.Phase = No_Create_Publication then Storage_Failure else Corrupt);
         Receipt.Current_Outcome := Result;
         return;
      else
         Result :=
           (if Receipt.Phase = Head_Publication_Unknown then Outcome_Unknown
            elsif Read_Result = Read_Cancelled then Cancelled
            elsif Read_Result = Read_Timed_Out then Timed_Out
            else Outcome_Unknown);
         Receipt.Current_Outcome := Result;
         return;
      end if;
      if Receipt.Phase = Manifest_Confirmed then
         if Token /= null and then Token.Requested then
            Result := Cancelled;
            Receipt.Current_Outcome := Result;
            return;
         elsif Deadline <= Ada.Real_Time.Clock then
            Result := Timed_Out;
            Receipt.Current_Outcome := Result;
            return;
         end if;
         Storage_Port.Put_Create
           (Storage.all,
            Full_Key (Storage.all, Head_Key_Suffix),
            Head_Data,
            Formats.Head_Image_Length,
            Head_Object,
            Deadline,
            Token,
            Generation,
            Put_Result);
         if Put_Result = Object_Published then
            Activate (Receipt.Attempted_Head, Generation, Manifest_Value, History, 0);
            return;
         elsif Put_Result = Put_Outcome_Unknown then
            Receipt.Phase := Head_Publication_Unknown;
         elsif Put_Result = Put_Precondition_Failed then
            null;
         elsif Put_Result = Put_Cancelled then
            Result := Cancelled;
            Receipt.Current_Outcome := Result;
            return;
         elsif Put_Result = Put_Timed_Out then
            Result := Timed_Out;
            Receipt.Current_Outcome := Result;
            return;
         else
            Result := Storage_Failure;
            Receipt.Current_Outcome := Result;
            return;
         end if;
      end if;
      Storage_Port.Get_Whole
        (Storage.all,
         Full_Key (Storage.all, Head_Key_Suffix),
         Head_Object,
         Deadline,
         Token,
         Read_Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result = Object_Read
        and then Exact_Bytes (Head_Data, Formats.Head_Image_Length, Read_Data, Length)
      then
         Activate (Receipt.Attempted_Head, Generation, Manifest_Value, History, 0);
      elsif Read_Result = Object_Read then
         declare
            Observed_Head     : Head_Snapshot;
            Observed_Manifest : Manifests.Manifest;
            Observed_History  : Batch_History;
            Observed_Count    : Natural;
         begin
            Reconcile_Create_Head
              (Storage.all,
               Manifest_Value,
               Read_Data,
               Length,
               Deadline,
               Token,
               Observed_Head,
               Generation,
               Observed_Manifest,
               Observed_History,
               Observed_Count,
               Result);
            if Result = Success then
               Activate
                 (Observed_Head,
                  Generation,
                  Observed_Manifest,
                  Observed_History,
                  Observed_Count);
            else
               Receipt.Current_Outcome := Result;
            end if;
         end;
      else
         Result := Outcome_Unknown;
         Receipt.Current_Outcome := Result;
      end if;
   exception
      when others =>
         Result :=
           (if Receipt.Phase = Head_Confirmed then Local_Activation_Failed
            elsif Receipt.Phase = Head_Publication_Unknown then Outcome_Unknown
            else Storage_Failure);
         Receipt.Current_Outcome := Result;
   end Resolve_Create;

   function Create_Receipt_Outcome (Item : Create_Receipt) return Outcome_Code
   is (Item.Current_Outcome);

   function Create_Receipt_Manifest_ID (Item : Create_Receipt) return Identifier
   is (Item.Manifest_ID);

   function Create_Receipt_Transition_ID (Item : Create_Receipt) return Identifier
   is (if Item.Phase in Head_Publication_Unknown | Head_Confirmed
       then Item.Attempted_Head.Transition_ID
       else Zero_Identifier);

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
      Manifest      : Manifests.Manifest;
      Root          : Manifests.Manifest;
      History       : Batch_History;
      History_Count : Natural;
      Bucket_Result : Outcome_Code;
      Stamp         : Engine_Incarnation;
      Guard         : Activation_Guard;
      pragma Unreferenced (Guard);
   begin
      if Storage.Backend = null or else Is_Zero (Database_ID) then
         Result := Invalid_State;
         return;
      end if;
      Item.Life.Begin_Open (Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Storage_Port.Bucket_Available (Storage.all, Deadline, Token, Bucket_Result);
      if Bucket_Result /= Success then
         Result := Bucket_Result;
         return;
      end if;
      Read_Recovery
        (Storage.all,
         Database_ID,
         Deadline,
         Token,
         Head,
         Generation,
         Manifest,
         Root,
         History,
         History_Count,
         Result);
      if Result = Success then
         Incarnation_Source.Allocate (Stamp, Result);
      end if;
      if Result = Success then
         Start_Engine
           (Item, Storage, Head, Generation, Manifest, Stamp, History, History_Count, Result);
      end if;
      if Result = Success then
         Guard.Active := False;
      end if;
   exception
      when others =>
         Result := Storage_Failure;
   end Open;

   procedure Reset_Transaction (Txn : out Transaction) is
   begin
      Txn.Active := False;
      Txn.Database_ID := Zero_Database_ID;
      Txn.Incarnation := No_Incarnation;
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
         Txn.Incarnation := Lease.State.Gate.Current_Incarnation;
         Txn.Transaction_ID := Transaction_ID;
      end if;
   end Begin_Transaction;

   procedure Open_Column_Family
     (Item   : in out Database;
      ID     : Column_Family_ID;
      Family : out Column_Family;
      Result : out Outcome_Code)
   is
      Lease         : Lifecycle_Lease;
      Configuration : Column_Family_Configuration;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
   begin
      Family := (others => <>);
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
      elsif Fenced then
         Result := Stale_Writer;
      else
         Lease.State.Gate.Find_Family (ID, Configuration, Result);
         if Result = Success then
            Family :=
              (Valid         => True,
               Database_ID   => Head.Database_ID,
               Incarnation   => Lease.State.Gate.Current_Incarnation,
               Configuration => Configuration);
         end if;
      end if;
   end Open_Column_Family;

   procedure Open_Column_Family
     (Item   : in out Database;
      Name   : Byte_Array;
      Family : out Column_Family;
      Result : out Outcome_Code)
   is
      Lease         : Lifecycle_Lease;
      Configuration : Column_Family_Configuration;
      Head          : Head_Snapshot;
      Generation    : Generation_Value;
      Uncertain     : Boolean;
      Fenced        : Boolean;
   begin
      Family := (others => <>);
      Acquire (Item, Lease, Result);
      if Result /= Success then
         return;
      end if;
      Lease.State.Gate.Snapshot (Head, Generation, Uncertain, Fenced);
      if Uncertain then
         Result := Outcome_Unknown;
      elsif Fenced then
         Result := Stale_Writer;
      else
         Lease.State.Gate.Find_Family (Name, Configuration, Result);
         if Result = Success then
            Family :=
              (Valid         => True,
               Database_ID   => Head.Database_ID,
               Incarnation   => Lease.State.Gate.Current_Incarnation,
               Configuration => Configuration);
         end if;
      end if;
   end Open_Column_Family;

   procedure Get
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
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
      Configuration : Column_Family_Configuration;
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
      if Txn.Database_ID /= Head.Database_ID
        or else Txn.Incarnation /= Lease.State.Gate.Current_Incarnation
      then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      Lease.State.Gate.Validate_Family (Family, Configuration, Result);
      if Result /= Success or else Item_Key.Length > Natural (Configuration.Max_Key_Bytes) then
         if Result = Success then
            Result := Capacity_Exceeded;
         end if;
         return;
      end if;
      for Reverse_Index in reverse Mutation_Slot range 1 .. Txn.Mutation_Count loop
         Index := Reverse_Index;
         if Txn.Mutations (Index).Family = Family.Configuration.ID
           and then Same_Key (Txn.Mutations (Index).Item_Key, Item_Key)
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
      Lease.State.Gate.Lookup (Family.Configuration.ID, Item_Key, Data, Result);
   end Get;

   procedure Store_Mutation
     (Item      : in out Database;
      Txn       : in out Transaction;
      Family    : Column_Family;
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
      Configuration : Column_Family_Configuration;
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
      if Txn.Database_ID /= Head.Database_ID
        or else Txn.Incarnation /= Lease.State.Gate.Current_Incarnation
      then
         Result := Invalid_State;
         return;
      elsif Uncertain then
         Result := Outcome_Unknown;
         return;
      elsif Fenced then
         Result := Stale_Writer;
         return;
      end if;
      Lease.State.Gate.Validate_Family (Family, Configuration, Result);
      if Result /= Success then
         return;
      elsif Item_Key.Length > Natural (Configuration.Max_Key_Bytes)
        or else (Operation = Put_Mutation and then Data.Length > Natural (Configuration.Max_Value_Bytes))
      then
         Result := Capacity_Exceeded;
         return;
      end if;
      for Index in Mutation_Slot range 1 .. Txn.Mutation_Count loop
         if Txn.Mutations (Index).Family = Family.Configuration.ID
           and then Same_Key (Txn.Mutations (Index).Item_Key, Item_Key)
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
      Lease.State.Gate.Validate_Transaction_Bounds
        (Txn.Mutation_Count + (if Existing = 0 then 1 else 0),
         Txn.Bytes_Used - Old_Bytes + New_Bytes,
         Result);
      if Result /= Success then
         return;
      end if;
      if Existing = 0 then
         Txn.Mutation_Count := Txn.Mutation_Count + 1;
         Existing := Txn.Mutation_Count;
      end if;
      Txn.Mutations (Existing) :=
        (Family => Family.Configuration.ID, Operation => Operation, Item_Key => Item_Key, Data => Data);
      Txn.Bytes_Used := Txn.Bytes_Used - Old_Bytes + New_Bytes;
      Result := Success;
   end Store_Mutation;

   procedure Put
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
      Item_Key : Key;
      Data     : Value;
      Result   : out Outcome_Code) is
   begin
      Store_Mutation (Item, Txn, Family, Item_Key, Data, Put_Mutation, Result);
   end Put;

   procedure Delete
     (Item     : in out Database;
      Txn      : in out Transaction;
      Family   : Column_Family;
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
      if Txn.Database_ID /= Head.Database_ID
        or else Txn.Incarnation /= Lease.State.Gate.Current_Incarnation
      then
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
           or else Transactions (Transactions'First + Offset).Incarnation /=
             Lease.State.Gate.Current_Incarnation
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
      Manifest    : out Manifests.Manifest;
      History     : out Batch_History;
      Count       : out Natural;
      Resolution  : out Receipt_Resolution;
      Result      : out Outcome_Code)
   is
      Exact   : Boolean := False;
      Encoded : Batches.Batch_Image;
      Length  : Natural;
      Status  : Batches.Encode_Status;
      Root    : Manifests.Manifest;
   begin
      Resolution := Receipt_Unresolved;
      Read_Recovery
        (Storage,
         Database_ID,
         Deadline,
         Token,
         Observed,
         Generation,
         Manifest,
         Root,
         History,
         Count,
         Result);
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
      Manifest      : Manifests.Manifest;
      Stamp         : Engine_Incarnation;
      Resolution    : Receipt_Resolution;
      Guard         : Resolve_Guard;
      pragma Unreferenced (Guard);
   begin
      if Receipt.Phase /= Head_Publication_Unknown then
         Result := Invalid_State;
         return;
      end if;
      Item.Life.Begin_Resolve (State, Result);
      if Result /= Success then
         return;
      end if;
      Guard.Life := Item.Life'Unchecked_Access;
      Guard.Active := True;
      Item.Life.Await_Quiescent;
      State.Gate.Snapshot (Current_Head, Generation, Uncertain, Fenced);
      if Current_Head.Database_ID /= Receipt.Expected_Head.Database_ID then
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
         Manifest,
         History,
         History_Count,
         Resolution,
         Read_Result);
      if Read_Result /= Success then
         Result := Read_Result;
         return;
      elsif Resolution = Receipt_Committed or else Same_Head (Observed, Receipt.Attempted_Head) then
         Incarnation_Source.Allocate (Stamp, Result);
         if Result /= Success then
            return;
         end if;
         Allocate_Engine
           (Item.Life'Unchecked_Access,
            Storage,
            Observed,
            Generation,
            Manifest,
            Stamp,
            History,
            History_Count,
            New_State,
            Result);
         if Result /= Success then
            return;
         end if;
         State.Gate.Request_Close;
         State.Gate.Join;
         Free_Worker (State.Worker);
         Free_State (State);
         Item.Life.Finish_Resolve (New_State, Observed.Highest);
         Guard.Active := False;
         Receipt.Current_Outcome := Success;
         Receipt.Phase := Resolved;
         Result := Success;
      elsif Resolution = Receipt_Rejected then
         State.Gate.Fence;
         Item.Life.Cancel_Resolve;
         Guard.Active := False;
         Receipt.Current_Outcome := Stale_Writer;
         Receipt.Phase := Resolved;
         Result := Stale_Writer;
      else
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

   procedure Wait_For_Test_Get
     (Item : in out Storage_Context; Timeout : Duration; Arrived : out Boolean) is
   begin
      Arrived := False;
      select
         delay Timeout;
      then abort
         Item.Test_Control.Await_Get;
         Arrived := True;
      end select;
   end Wait_For_Test_Get;

   function Test_Get_Waiting (Item : Storage_Context) return Boolean
   is (Item.Test_Control.Get_Waiting);

   procedure Install_Test_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Legacy        : Boolean;
      Result        : out Outcome_Code)
   is
      Head       : constant Head_Snapshot :=
        (Database_ID            => Database_ID,
         Version                =>
           Interfaces.Unsigned_16 (if Legacy then Heads.Legacy_Format else Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => (if Legacy then Zero_Identifier else Manifest_ID),
         Transition_ID          => Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Image      : constant Formats.Head_Image := Formats.Encode_Head (To_Head (Head));
      Data       : Object_Buffer;
      Generation : Generation_Value;
      Put_Result : Put_Outcome;
   begin
      Copy_Head_Image (Image, Data);
      Storage_Port.Put_Create
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         Head_Object,
         Ada.Real_Time.Time_Last,
         null,
         Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Install_Test_Head;

   procedure Install_Test_Unsupported_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code)
   is
      Head       : constant Head_Snapshot :=
        (Database_ID            => Database_ID,
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => Manifest_ID,
         Transition_ID          => Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Image      : Formats.Head_Image := Formats.Encode_Head (To_Head (Head));
      Data       : Object_Buffer;
      Generation : Generation_Value;
      Put_Result : Put_Outcome;

      procedure Put_U32 (Position : Natural; Value : Interfaces.Unsigned_32) is
      begin
         for Offset in Natural range 0 .. 3 loop
            Image (Position + Offset) :=
              Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
         end loop;
      end Put_U32;
   begin
      Image (8) := 0;
      Image (9) := 3;
      Image (40 .. 43) := [others => 0];
      Put_U32 (40, Formats.CRC_32C (Image (0 .. 131)));
      Put_U32 (132, Formats.CRC_32C (Image (0 .. 131)));
      Copy_Head_Image (Image, Data);
      Storage_Port.Put_Create
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         Head_Object,
         Ada.Real_Time.Time_Last,
         null,
         Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Install_Test_Unsupported_Head;

   procedure Install_Test_Invalid_V2_Head
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Manifest_ID   : Identifier;
      Transition_ID : Identifier;
      Result        : out Outcome_Code)
   is
      Head       : constant Head_Snapshot :=
        (Database_ID            => Database_ID,
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => 1,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => Manifest_ID,
         Transition_ID          => Transition_ID,
         Predecessor_Transition => Zero_Identifier,
         Transition_Number      => 1);
      Image      : Formats.Head_Image := Formats.Encode_Head (To_Head (Head));
      Data       : Object_Buffer;
      Generation : Generation_Value;
      Put_Result : Put_Outcome;

      procedure Put_U32 (Position : Natural; Value : Interfaces.Unsigned_32) is
      begin
         for Offset in Natural range 0 .. 3 loop
            Image (Position + Offset) :=
              Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
         end loop;
      end Put_U32;
   begin
      Image (76 .. 91) := [others => 0];
      Image (40 .. 43) := [others => 0];
      Put_U32 (40, Formats.CRC_32C (Image (0 .. 131)));
      Put_U32 (132, Formats.CRC_32C (Image (0 .. 131)));
      Copy_Head_Image (Image, Data);
      Storage_Port.Put_Create
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         Head_Object,
         Ada.Real_Time.Time_Last,
         null,
         Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Install_Test_Invalid_V2_Head;

   procedure Corrupt_Test_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code)
   is
      Data           : Object_Buffer;
      Length         : Natural;
      Generation     : Generation_Value;
      Read_Result    : Read_Outcome;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;
   begin
      Storage_Port.Get_Whole
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Manifest_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read or else Length = 0 then
         Result := Storage_Failure;
         return;
      end if;
      Data (Length - 1) := Data (Length - 1) xor 1;
      Storage_Port.Put_Replace
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Data,
         Length,
         Generation,
         Ada.Real_Time.Time_Last,
         null,
         New_Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Corrupt_Test_Manifest;

   procedure Remove_Test_Manifest
     (Item : in out Storage_Context; Manifest_ID : Identifier; Result : out Outcome_Code)
   is
      Status : OS.Status;
   begin
      Item.Backend.Delete_Object
        (UStrings.To_String (Item.Bucket),
         Manifest_Key (Item, Manifest_ID),
         null,
         Ada.Real_Time.Time_Last,
         Status);
      Result := (if Status = OS.Success then Success else Storage_Failure);
   end Remove_Test_Manifest;

   procedure Rewrite_Test_Manifest
     (Item                 : in out Storage_Context;
      Manifest_ID          : Identifier;
      Expected_Database_ID : Database_Identifier;
      Replacement_Database : Database_Identifier;
      Oversize_Family      : Boolean;
      Drop_Last_Family     : Boolean;
      Restricted_Family    : Interfaces.Unsigned_32;
      Restricted_Max_Key   : Interfaces.Unsigned_64;
      Result               : out Outcome_Code)
   is
      Data           : Object_Buffer;
      Length         : Natural;
      Generation     : Generation_Value;
      Read_Result    : Read_Outcome;
      Value          : Manifests.Manifest;
      Image          : Manifests.Manifest_Image;
      Encode_Result  : Manifests.Encode_Status;
      New_Generation : Generation_Value;
      Put_Result     : Put_Outcome;
      Found          : Boolean := False;
   begin
      Storage_Port.Get_Whole
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Manifest_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read then
         Result := Storage_Failure;
         return;
      end if;
      Decode_Stored_Manifest (Data, Length, Expected_Database_ID, Value, Result);
      if Result /= Success then
         return;
      end if;
      if Replacement_Database /= Zero_Database_ID then
         Value.Database_ID := To_Head_ID (Replacement_Database);
      end if;
      if Oversize_Family then
         Value.Families (1).Max_Key_Bytes := Maximum_Key_Bytes + 1;
      end if;
      if Drop_Last_Family then
         if Value.Family_Total <= 1 then
            Result := Invalid_State;
            return;
         end if;
         Value.Families (Value.Family_Total) := (others => <>);
         Value.Family_Total := Value.Family_Total - 1;
      elsif Restricted_Family /= 0 then
         for Index in Manifests.Family_Slot range 1 .. Value.Family_Total loop
            if Value.Families (Index).ID = Restricted_Family then
               Value.Families (Index).Max_Key_Bytes := Restricted_Max_Key;
               Found := True;
               exit;
            end if;
         end loop;
         if not Found then
            Result := Invalid_State;
            return;
         end if;
      end if;
      Manifests.Encode_Manifest (Value, Image, Length, Encode_Result);
      if Encode_Result /= Manifests.Encoded then
         Result := Invalid_State;
         return;
      end if;
      Copy_Manifest_Image (Image, Length, Data);
      Storage_Port.Put_Replace
        (Item,
         Manifest_Key (Item, Manifest_ID),
         Data,
         Length,
         Generation,
         Ada.Real_Time.Time_Last,
         null,
         New_Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Rewrite_Test_Manifest;

   procedure Extend_Test_Manifest_Chain
     (Item          : in out Storage_Context;
      Database_ID   : Database_Identifier;
      Root_ID       : Identifier;
      Successors    : Positive;
      Result        : out Outcome_Code)
   is
      Data            : Object_Buffer;
      Length          : Natural;
      Generation      : Generation_Value;
      Read_Result     : Read_Outcome;
      Previous        : Manifests.Manifest;
      Current         : Manifests.Manifest;
      Image           : Manifests.Manifest_Image;
      Encode_Result   : Manifests.Encode_Status;
      New_Generation  : Generation_Value;
      Put_Result      : Put_Outcome;
      Head            : Head_Snapshot;
      Head_Image      : Formats.Head_Image;
   begin
      Storage_Port.Get_Whole
        (Item,
         Manifest_Key (Item, Root_ID),
         Manifest_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read then
         Result := Storage_Failure;
         return;
      end if;
      Decode_Stored_Manifest (Data, Length, Database_ID, Previous, Result);
      if Result /= Success then
         return;
      end if;
      for Index in Positive range 1 .. Successors loop
         if Previous.Family_Total = Manifests.Family_Count'Last then
            Result := Capacity_Exceeded;
            return;
         end if;
         Current := Previous;
         Current.Manifest_ID := To_Head_ID (Structural_ID (16#4E#, Interfaces.Unsigned_64 (Index)));
         Current.Previous_Manifest_ID := Previous.Manifest_ID;
         Current.Expected_Transition_ID := Previous.Publication_Transition_ID;
         Current.Expected_Transition_Number := Previous.Publication_Transition_Number;
         Current.Publication_Transition_ID :=
           To_Head_ID (Structural_ID (16#54#, Interfaces.Unsigned_64 (Index + 1)));
         Current.Publication_Transition_Number := Current.Expected_Transition_Number + 1;
         Current.Registry_Revision := Previous.Registry_Revision + 1;
         Current.Family_Total := Previous.Family_Total + 1;
         Current.Families (Current.Family_Total) :=
           (ID              => Previous.Families (Previous.Family_Total).ID + 1,
            Max_Key_Bytes   => 1,
            Max_Value_Bytes => 1,
            Name_Length     => 2,
            Name            => [1 => 16#78#, 2 => Byte (Index), others => 0]);
         Manifests.Encode_Manifest (Current, Image, Length, Encode_Result);
         if Encode_Result /= Manifests.Encoded then
            Result := Invalid_State;
            return;
         end if;
         Copy_Manifest_Image (Image, Length, Data);
         Storage_Port.Put_Create
           (Item,
            Manifest_Key (Item, To_Identifier (Current.Manifest_ID)),
            Data,
            Length,
            Manifest_Object,
            Ada.Real_Time.Time_Last,
            null,
            New_Generation,
            Put_Result);
         if Put_Result /= Object_Published then
            Result := Storage_Failure;
            return;
         end if;
         Previous := Current;
      end loop;

      Storage_Port.Get_Whole
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Head_Object,
         Ada.Real_Time.Time_Last,
         null,
         Data,
         Length,
         Generation,
         Read_Result);
      if Read_Result /= Object_Read then
         Result := Storage_Failure;
         return;
      end if;
      Head :=
        (Database_ID            => Database_ID,
         Version                => Interfaces.Unsigned_16 (Heads.Current_Format),
         Epoch                  => Previous.Writer_Epoch,
         Highest                => 0,
         Latest_Batch           => Zero_Identifier,
         Latest_Manifest        => To_Identifier (Previous.Manifest_ID),
         Transition_ID          => To_Identifier (Previous.Publication_Transition_ID),
         Predecessor_Transition => To_Identifier (Previous.Expected_Transition_ID),
         Transition_Number      => Previous.Publication_Transition_Number);
      Head_Image := Formats.Encode_Head (To_Head (Head));
      Copy_Head_Image (Head_Image, Data);
      Storage_Port.Put_Replace
        (Item,
         Full_Key (Item, Head_Key_Suffix),
         Data,
         Formats.Head_Image_Length,
         Generation,
         Ada.Real_Time.Time_Last,
         null,
         New_Generation,
         Put_Result);
      Result := (if Put_Result = Object_Published then Success else Storage_Failure);
   end Extend_Test_Manifest_Chain;

   overriding
   procedure Finalize (Item : in out Database) is
      Result : Outcome_Code;
   begin
      Close (Item, Result);
   end Finalize;

end Flyology.DB;
