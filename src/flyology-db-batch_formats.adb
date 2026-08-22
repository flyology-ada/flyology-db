package body Flyology.DB.Batch_Formats
  with SPARK_Mode => On
is

   use type Formats.Byte;
   use type Formats.Byte_Array;
   use type Head_Policy.Transition_Ordinal;
   use type Head_Policy.Writer_Epoch;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Magic : constant Formats.Byte_Array (0 .. 7) :=
     [Character'Pos ('F'), Character'Pos ('L'), Character'Pos ('Y'), Character'Pos ('B'),
      Character'Pos ('A'), Character'Pos ('T'), Character'Pos ('C'), Character'Pos ('1')];

   Batch_Kind : constant Formats.Byte := 2;
   Max_Mutation_Image_Length : constant :=
     Mutation_Frame_Header_Length + Max_Key_Bytes + Max_Value_Bytes;

   procedure Put_U16
     (Image    : in out Batch_Image;
      Position : Batch_Image_Index;
      Value    : Interfaces.Unsigned_16)
   with Pre => Position <= Batch_Image_Index'Last - 1;

   procedure Put_U32
     (Image    : in out Batch_Image;
      Position : Batch_Image_Index;
      Value    : Interfaces.Unsigned_32)
   with Pre => Position <= Batch_Image_Index'Last - 3;

   procedure Put_U64
     (Image    : in out Batch_Image;
      Position : Batch_Image_Index;
      Value    : Interfaces.Unsigned_64)
   with Pre => Position <= Batch_Image_Index'Last - 7;

   function Read_U16
     (Image    : Batch_Image;
      Position : Batch_Image_Index) return Interfaces.Unsigned_16
   with Pre => Position <= Batch_Image_Index'Last - 1;

   function Read_U32
     (Image    : Batch_Image;
      Position : Batch_Image_Index) return Interfaces.Unsigned_32
   with Pre => Position <= Batch_Image_Index'Last - 3;

   function Read_U64
     (Image    : Batch_Image;
      Position : Batch_Image_Index) return Interfaces.Unsigned_64
   with Pre => Position <= Batch_Image_Index'Last - 7;

   procedure Put_Identifier
     (Image    : in out Batch_Image;
      Position : Batch_Image_Index;
      Value    : Head_Policy.Identifier)
   with Pre => Position <= Batch_Image_Index'Last - Head_Policy.Identifier_Length + 1;

   function Read_Identifier
     (Image    : Batch_Image;
      Position : Batch_Image_Index) return Head_Policy.Identifier
   with Pre => Position <= Batch_Image_Index'Last - Head_Policy.Identifier_Length + 1;

   function Header_Checksum (Image : Batch_Image) return Interfaces.Unsigned_32;

   function Same_Key (Left, Right : Mutation) return Boolean;

   subtype Payload_Count is Natural range 0 .. Max_Payload_Bytes;

   procedure Decode_Mutation_Count
     (Wire    : Interfaces.Unsigned_32;
      Maximum : Mutation_Count;
      Result  : out Mutation_Count;
      Valid   : out Boolean)
   with
     Post =>
       (if Valid then Result <= Maximum and then Interfaces.Unsigned_32 (Result) = Wire
        else Result = 0);

   procedure Decode_Extent
     (Wire    : Interfaces.Unsigned_32;
      Maximum : Payload_Count;
      Result  : out Payload_Count;
      Valid   : out Boolean)
   with
     Post =>
       (if Valid then Result <= Maximum and then Interfaces.Unsigned_32 (Result) = Wire
        else Result = 0);

   procedure Copy_Key
     (Image  : Batch_Image;
      Start  : Natural;
      Count  : Key_Length;
      Target : in out Key_Bytes)
   with Pre => Start <= Max_Batch_Image_Length - Count;

   procedure Copy_Value
     (Image  : Batch_Image;
      Start  : Natural;
      Count  : Value_Length;
      Target : in out Value_Bytes)
   with Pre => Start <= Max_Batch_Image_Length - Count;

   procedure Put_U16
     (Image    : in out Batch_Image;
      Position : Batch_Image_Index;
      Value    : Interfaces.Unsigned_16)
   is
   begin
      Image (Position) := Formats.Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);
      Image (Position + 1) := Formats.Byte (Value and 16#FF#);
   end Put_U16;

   procedure Put_U32
     (Image    : in out Batch_Image;
      Position : Batch_Image_Index;
      Value    : Interfaces.Unsigned_32)
   is
   begin
      for Offset in Natural range 0 .. 3 loop
         Image (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64
     (Image    : in out Batch_Image;
      Position : Batch_Image_Index;
      Value    : Interfaces.Unsigned_64)
   is
   begin
      for Offset in Natural range 0 .. 7 loop
         Image (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   function Read_U16
     (Image    : Batch_Image;
      Position : Batch_Image_Index) return Interfaces.Unsigned_16
   is
   begin
      return Interfaces.Shift_Left (Interfaces.Unsigned_16 (Image (Position)), 8)
        or Interfaces.Unsigned_16 (Image (Position + 1));
   end Read_U16;

   function Read_U32
     (Image    : Batch_Image;
      Position : Batch_Image_Index) return Interfaces.Unsigned_32
   is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      for Offset in Natural range 0 .. 3 loop
         Result := Interfaces.Shift_Left (Result, 8)
           or Interfaces.Unsigned_32 (Image (Position + Offset));
      end loop;
      return Result;
   end Read_U32;

   function Read_U64
     (Image    : Batch_Image;
      Position : Batch_Image_Index) return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Offset in Natural range 0 .. 7 loop
         Result := Interfaces.Shift_Left (Result, 8)
           or Interfaces.Unsigned_64 (Image (Position + Offset));
      end loop;
      return Result;
   end Read_U64;

   procedure Put_Identifier
     (Image    : in out Batch_Image;
      Position : Batch_Image_Index;
      Value    : Head_Policy.Identifier)
   is
   begin
      for Index in Head_Policy.Identifier_Index loop
         Image (Position + (Index - Head_Policy.Identifier_Index'First)) := Value (Index);
      end loop;
   end Put_Identifier;

   function Read_Identifier
     (Image    : Batch_Image;
      Position : Batch_Image_Index) return Head_Policy.Identifier
   is
      Result : Head_Policy.Identifier;
   begin
      for Index in Head_Policy.Identifier_Index loop
         Result (Index) := Image (Position + (Index - Head_Policy.Identifier_Index'First));
      end loop;
      return Result;
   end Read_Identifier;

   function Header_Checksum (Image : Batch_Image) return Interfaces.Unsigned_32 is
      Header : Formats.Byte_Array (0 .. Batch_Header_Length - 1) :=
        Image (0 .. Batch_Header_Length - 1);
   begin
      Header (40 .. 43) := [others => 0];
      return Formats.CRC_32C (Header);
   end Header_Checksum;

   function Same_Key (Left, Right : Mutation) return Boolean is
   begin
      if Left.Column_Family /= Right.Column_Family
        or else Left.Key_Size /= Right.Key_Size
      then
         return False;
      end if;

      for Index in Positive range 1 .. Left.Key_Size loop
         if Left.Key (Index) /= Right.Key (Index) then
            return False;
         end if;
      end loop;
      return True;
   end Same_Key;

   procedure Decode_Mutation_Count
     (Wire    : Interfaces.Unsigned_32;
      Maximum : Mutation_Count;
      Result  : out Mutation_Count;
      Valid   : out Boolean)
   is
   begin
      if Wire <= Interfaces.Unsigned_32 (Maximum) then
         Result := Mutation_Count (Wire);
         Valid := True;
      else
         Result := 0;
         Valid := False;
      end if;
   end Decode_Mutation_Count;

   procedure Decode_Extent
     (Wire    : Interfaces.Unsigned_32;
      Maximum : Payload_Count;
      Result  : out Payload_Count;
      Valid   : out Boolean)
   is
   begin
      if Wire <= Interfaces.Unsigned_32 (Maximum) then
         Result := Payload_Count (Wire);
         Valid := True;
      else
         Result := 0;
         Valid := False;
      end if;
   end Decode_Extent;

   procedure Copy_Key
     (Image  : Batch_Image;
      Start  : Natural;
      Count  : Key_Length;
      Target : in out Key_Bytes)
   is
   begin
      for Index in Positive range 1 .. Count loop
         Target (Index) := Image (Start + (Index - 1));
      end loop;
   end Copy_Key;

   procedure Copy_Value
     (Image  : Batch_Image;
      Start  : Natural;
      Count  : Value_Length;
      Target : in out Value_Bytes)
   is
   begin
      for Index in Positive range 1 .. Count loop
         Target (Index) := Image (Start + (Index - 1));
      end loop;
   end Copy_Value;

   function Structurally_Valid (Value : Commit_Batch) return Boolean is
      Next_Mutation : Natural := 1;
   begin
      if Head_Policy.Is_Zero (Value.Database_ID)
        or else Value.Epoch = 0
        or else Head_Policy.Is_Zero (Value.Batch_ID)
        or else
          (not Head_Policy.Is_Zero (Value.Previous_Batch_ID)
           and then Value.Batch_ID = Value.Previous_Batch_ID)
        or else Head_Policy.Is_Zero (Value.Expected_Transition_ID)
        or else Head_Policy.Is_Zero (Value.Publication_Transition_ID)
        or else Value.Expected_Transition_ID = Value.Publication_Transition_ID
        or else Value.Expected_Transition_Number = Head_Policy.Transition_Ordinal'Last
        or else Value.Publication_Transition_Number /= Value.Expected_Transition_Number + 1
        or else Value.First_Sequence = 0
        or else Value.Last_Sequence < Value.First_Sequence
        or else Value.Transaction_Total = 0
        or else Value.Mutation_Total = 0
        or else Interfaces.Unsigned_64 (Value.Last_Sequence - Value.First_Sequence) + 1
          /= Interfaces.Unsigned_64 (Value.Transaction_Total)
        or else
          (Head_Policy.Is_Zero (Value.Previous_Batch_ID) /= (Value.First_Sequence = 1))
        or else
          (if Value.First_Sequence = 1 then
             Interfaces.Unsigned_64 (Value.Expected_Transition_Number) /=
               Interfaces.Unsigned_64 (Value.Epoch)
           else
             Interfaces.Unsigned_64 (Value.Expected_Transition_Number) <=
               Interfaces.Unsigned_64 (Value.Epoch))
      then
         return False;
      end if;

      for Transaction_Index in Transaction_Slot range 1 .. Value.Transaction_Total loop
         pragma Loop_Invariant
           (Next_Mutation in 1 .. Value.Mutation_Total + 1);
         declare
            Item : Transaction renames Value.Transactions (Transaction_Index);
         begin
            if Head_Policy.Is_Zero (Item.Transaction_ID)
              or else Item.Sequence /=
                Value.First_Sequence + Head_Policy.Commit_Sequence (Transaction_Index - 1)
              or else Item.Mutations = 0
              or else Next_Mutation > Value.Mutation_Total
              or else Item.First_Mutation /= Next_Mutation
              or else Item.Mutations > (Value.Mutation_Total - Next_Mutation) + 1
            then
               return False;
            end if;

            for Earlier in Transaction_Slot range 1 .. Transaction_Index - 1 loop
               if Value.Transactions (Earlier).Transaction_ID = Item.Transaction_ID then
                  return False;
               end if;
            end loop;

            for Offset in Natural range 0 .. Item.Mutations - 1 loop
               pragma Loop_Invariant
                 (Next_Mutation + Offset <= Value.Mutation_Total);
               declare
                  Mutation_Index : constant Mutation_Slot := Mutation_Slot (Next_Mutation + Offset);
                  Change         : Mutation renames Value.Mutations (Mutation_Index);
               begin
                  if Change.Column_Family = 0
                    or else (Change.Operation = Delete and then Change.Value_Size /= 0)
                  then
                     return False;
                  end if;

                  for Earlier in Natural range 0 .. Offset - 1 loop
                     pragma Loop_Invariant
                       (Next_Mutation + Earlier <= Value.Mutation_Total);
                     if Same_Key
                       (Value.Mutations (Mutation_Slot (Next_Mutation + Earlier)), Change)
                     then
                        return False;
                     end if;
                  end loop;
               end;
            end loop;
            Next_Mutation := Next_Mutation + Item.Mutations;
         end;
      end loop;

      return Next_Mutation = Value.Mutation_Total + 1;
   end Structurally_Valid;

   function Encoded_Length (Value : Commit_Batch) return Natural is
      Base   : constant Natural :=
        ((Batch_Header_Length + Batch_Trailer_Length)
         + Value.Transaction_Total * Transaction_Frame_Header_Length)
        + Value.Mutation_Total * Mutation_Frame_Header_Length;
      Result    : Natural := Base;
      Processed : Mutation_Count := 0;
   begin
      for Index in Mutation_Slot range 1 .. Value.Mutation_Total loop
         pragma Loop_Invariant (Processed = Index - 1);
         pragma Loop_Invariant (Result >= Base);
         pragma Loop_Invariant
           (Result <= Base + Processed * (Max_Key_Bytes + Max_Value_Bytes));
         Result := Result
           + (Value.Mutations (Index).Key_Size + Value.Mutations (Index).Value_Size);
         Processed := Processed + 1;
      end loop;
      pragma Assert (Processed = Value.Mutation_Total);
      pragma Assert
        (Base + Processed * (Max_Key_Bytes + Max_Value_Bytes) <= Max_Batch_Image_Length);
      pragma Assert (Result >= Batch_Header_Length + Batch_Trailer_Length);
      pragma Assert (Result <= Max_Batch_Image_Length);
      return Result;
   end Encoded_Length;

   procedure Encode_Mutation
     (Change : Mutation;
      Image  : in out Batch_Image;
      Cursor : in out Natural)
   with
     Pre => Cursor <= Max_Batch_Image_Length
       - (Mutation_Frame_Header_Length + (Change.Key_Size + Change.Value_Size)),
     Post => Cursor = Cursor'Old
       + (Mutation_Frame_Header_Length + (Change.Key_Size + Change.Value_Size))
       and then Cursor <= Max_Batch_Image_Length;

   procedure Encode_Mutation
     (Change : Mutation;
      Image  : in out Batch_Image;
      Cursor : in out Natural)
   is
      Data_Start : Natural;
   begin
      Put_U32 (Image, Batch_Image_Index (Cursor), Change.Column_Family);
      Image (Cursor + 4) := (if Change.Operation = Put then 1 else 2);
      Image (Cursor + 5) := 0;
      Put_U32 (Image, Batch_Image_Index (Cursor + 6), Interfaces.Unsigned_32 (Change.Key_Size));
      Put_U32 (Image, Batch_Image_Index (Cursor + 10), Interfaces.Unsigned_32 (Change.Value_Size));
      Data_Start := Cursor + Mutation_Frame_Header_Length;

      for Byte_Index in Positive range 1 .. Change.Key_Size loop
         Image (Data_Start + (Byte_Index - 1)) := Change.Key (Byte_Index);
      end loop;
      for Byte_Index in Positive range 1 .. Change.Value_Size loop
         Image (Data_Start + (Change.Key_Size + (Byte_Index - 1))) := Change.Value (Byte_Index);
      end loop;
      Cursor := Data_Start + (Change.Key_Size + Change.Value_Size);
   end Encode_Mutation;

   procedure Encode_Transaction
     (Value             : Commit_Batch;
      Transaction_Index : Transaction_Slot;
      Image             : in out Batch_Image;
      Cursor            : in out Natural)
   with
     Pre => Transaction_Index <= Value.Transaction_Total
       and then Value.Transactions (Transaction_Index).First_Mutation > 0
       and then Value.Transactions (Transaction_Index).Mutations > 0
       and then Value.Transactions (Transaction_Index).First_Mutation <=
         (Max_Mutations - Value.Transactions (Transaction_Index).Mutations) + 1
       and then Cursor <= Max_Batch_Image_Length
         - (Transaction_Frame_Header_Length
            + Value.Transactions (Transaction_Index).Mutations * Max_Mutation_Image_Length),
     Post => Cursor >= Cursor'Old
       and then Cursor <= Cursor'Old
         + (Transaction_Frame_Header_Length
            + Value.Transactions (Transaction_Index).Mutations * Max_Mutation_Image_Length);

   procedure Encode_Transaction
     (Value             : Commit_Batch;
      Transaction_Index : Transaction_Slot;
      Image             : in out Batch_Image;
      Cursor            : in out Natural)
   is
      Item        : Transaction renames Value.Transactions (Transaction_Index);
      Body_Length : Natural := 0;
      Data_Start  : Natural;
   begin
      for Offset in Natural range 0 .. Item.Mutations - 1 loop
         pragma Loop_Invariant
           (Body_Length <= Offset * Max_Mutation_Image_Length);
         declare
            Change : Mutation renames Value.Mutations (Mutation_Slot (Item.First_Mutation + Offset));
         begin
            Body_Length := Body_Length
              + (Mutation_Frame_Header_Length + (Change.Key_Size + Change.Value_Size));
         end;
      end loop;

      Put_Identifier (Image, Batch_Image_Index (Cursor), Item.Transaction_ID);
      Put_U64 (Image, Batch_Image_Index (Cursor + 16), Interfaces.Unsigned_64 (Item.Sequence));
      Put_U32 (Image, Batch_Image_Index (Cursor + 24), Interfaces.Unsigned_32 (Item.Mutations));
      Put_U32 (Image, Batch_Image_Index (Cursor + 28), Interfaces.Unsigned_32 (Body_Length));
      Cursor := Cursor + Transaction_Frame_Header_Length;
      Data_Start := Cursor;

      for Offset in Natural range 0 .. Item.Mutations - 1 loop
         pragma Loop_Invariant (Cursor >= Data_Start);
         pragma Loop_Invariant
           (Cursor <= Data_Start + Offset * Max_Mutation_Image_Length);
         Encode_Mutation
           (Value.Mutations (Mutation_Slot (Item.First_Mutation + Offset)), Image, Cursor);
      end loop;
   end Encode_Transaction;

   procedure Encode_Batch
     (Value  : Commit_Batch;
      Image  : out Batch_Image;
      Length : out Natural;
      Status : out Encode_Status)
   is
      Object_Length : Natural;
      Cursor        : Natural := Batch_Header_Length;
   begin
      Image := [others => 0];
      Length := 0;
      if not Structurally_Valid (Value) then
         Status := Invalid_Value;
         return;
      end if;

      Object_Length := Encoded_Length (Value);
      Image (0 .. 7) := Magic;
      Put_U16 (Image, 8, Interfaces.Unsigned_16 (Head_Policy.Current_Format));
      Image (10) := Batch_Kind;
      Image (11) := 0;
      Put_Identifier (Image, 12, Value.Database_ID);
      Put_U32 (Image, 28, Interfaces.Unsigned_32 (Batch_Header_Length));
      Put_U64
        (Image, 32,
         Interfaces.Unsigned_64
           (Object_Length - (Batch_Header_Length + Batch_Trailer_Length)));
      Put_U64 (Image, 44, Interfaces.Unsigned_64 (Value.Epoch));
      Put_Identifier (Image, 52, Value.Batch_ID);
      Put_Identifier (Image, 68, Value.Previous_Batch_ID);
      Put_Identifier (Image, 84, Value.Expected_Transition_ID);
      Put_U64 (Image, 100, Interfaces.Unsigned_64 (Value.Expected_Transition_Number));
      Put_Identifier (Image, 108, Value.Publication_Transition_ID);
      Put_U64 (Image, 124, Interfaces.Unsigned_64 (Value.Publication_Transition_Number));
      Put_U64 (Image, 132, Interfaces.Unsigned_64 (Value.First_Sequence));
      Put_U64 (Image, 140, Interfaces.Unsigned_64 (Value.Last_Sequence));
      Put_U32 (Image, 148, Interfaces.Unsigned_32 (Value.Transaction_Total));
      Put_U32 (Image, 152, Interfaces.Unsigned_32 (Value.Mutation_Total));
      Put_U32 (Image, 40, Header_Checksum (Image));

      for Transaction_Index in Transaction_Slot range 1 .. Value.Transaction_Total loop
         if Value.Transactions (Transaction_Index).First_Mutation = 0
           or else Value.Transactions (Transaction_Index).Mutations = 0
           or else Value.Transactions (Transaction_Index).First_Mutation >
             (Max_Mutations - Value.Transactions (Transaction_Index).Mutations) + 1
         then
            Image := [others => 0];
            Status := Invalid_Value;
            return;
         elsif Cursor > Max_Batch_Image_Length
           - (Transaction_Frame_Header_Length
              + Value.Transactions (Transaction_Index).Mutations * Max_Mutation_Image_Length)
         then
            Image := [others => 0];
            Status := Invalid_Value;
            return;
         end if;
         Encode_Transaction (Value, Transaction_Index, Image, Cursor);
      end loop;

      if Cursor > Max_Batch_Image_Length - Batch_Trailer_Length then
         Image := [others => 0];
         Status := Invalid_Value;
         return;
      elsif Cursor + Batch_Trailer_Length /= Object_Length then
         Image := [others => 0];
         Status := Invalid_Value;
         return;
      end if;
      Length := Cursor + Batch_Trailer_Length;
      Put_U32 (Image, Batch_Image_Index (Cursor), Formats.CRC_32C (Image (0 .. Cursor - 1)));
      Status := Encoded;
   end Encode_Batch;

   function Published_By
     (Value            : Commit_Batch;
      Referencing_Head : Head_Policy.Head_State) return Boolean
   is
   begin
      return Head_Policy.Structurally_Valid (Referencing_Head)
        and then Structurally_Valid (Value)
        and then Referencing_Head.Database_ID = Value.Database_ID
        and then Referencing_Head.Epoch = Value.Epoch
        and then Referencing_Head.Latest_Batch = Value.Batch_ID
        and then Referencing_Head.Transition_ID = Value.Publication_Transition_ID
        and then Referencing_Head.Predecessor_Transition = Value.Expected_Transition_ID
        and then Referencing_Head.Transition_Number = Value.Publication_Transition_Number
        and then Referencing_Head.Highest_Visible = Value.Last_Sequence;
   end Published_By;

   function Valid_Predecessor
     (Current  : Commit_Batch;
      Previous : Commit_Batch) return Boolean
   is
   begin
      if not Structurally_Valid (Current)
        or else not Structurally_Valid (Previous)
        or else Is_First_Batch (Current)
        or else Current.Database_ID /= Previous.Database_ID
        or else Current.Previous_Batch_ID /= Previous.Batch_ID
        or else Previous.Last_Sequence = Head_Policy.Commit_Sequence'Last
        or else Current.First_Sequence /= Previous.Last_Sequence + 1
        or else Current.Epoch < Previous.Epoch
        or else Current.Expected_Transition_Number < Previous.Publication_Transition_Number
      then
         return False;
      end if;

      declare
         Ordinal_Gap : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64
             (Current.Expected_Transition_Number - Previous.Publication_Transition_Number);
         Epoch_Gap : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Current.Epoch - Previous.Epoch);
      begin
         return Epoch_Gap <= Ordinal_Gap
           and then
             (if Ordinal_Gap = 0 then
                Current.Expected_Transition_ID = Previous.Publication_Transition_ID
              elsif Ordinal_Gap = 1 then
                Current.Expected_Transition_ID /= Previous.Publication_Transition_ID);
      end;
   end Valid_Predecessor;

   procedure Decode_Batch
     (Image             : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Limits            : Reader_Caps;
      Value             : out Commit_Batch;
      Status            : out Decode_Status)
   is
      Fixed             : Batch_Image := [others => 0];
      Candidate         : Commit_Batch := Empty_Batch;
      Cursor            : Natural := Batch_Header_Length;
      Payload_End       : Natural;
      Payload_Length    : Interfaces.Unsigned_64;
      Transaction_Wire  : Interfaces.Unsigned_32;
      Mutation_Wire     : Interfaces.Unsigned_32;
      Expected_Number_Wire    : Interfaces.Unsigned_64;
      Publication_Number_Wire : Interfaces.Unsigned_64;
      Parsed_Mutations  : Natural := 0;
   begin
      Value := Empty_Batch;

      if Image'Length < Batch_Header_Length + Batch_Trailer_Length then
         Status := Invalid_Length;
         return;
      elsif Image'Length > Max_Batch_Image_Length then
         Status := Limit_Exceeded;
         return;
      end if;

      Fixed (0 .. Image'Length - 1) := Image;

      Payload_Length := Read_U64 (Fixed, 32);
      if Payload_Length /= Interfaces.Unsigned_64
        (Image'Length - (Batch_Header_Length + Batch_Trailer_Length))
      then
         Status := Invalid_Length;
         return;
      elsif Fixed (0 .. 7) /= Magic then
         Status := Invalid_Magic;
         return;
      elsif Read_U16 (Fixed, 8) /= Interfaces.Unsigned_16 (Head_Policy.Current_Format) then
         Status := Unsupported_Version;
         return;
      elsif Fixed (10) /= Batch_Kind then
         Status := Invalid_Object_Kind;
         return;
      elsif Fixed (11) /= 0 then
         Status := Invalid_Flags;
         return;
      elsif Read_Identifier (Fixed, 12) /= Expected_Database then
         Status := Wrong_Database;
         return;
      elsif Read_U32 (Fixed, 28) /= Interfaces.Unsigned_32 (Batch_Header_Length) then
         Status := Invalid_Length;
         return;
      elsif Read_U32 (Fixed, 40) /= Header_Checksum (Fixed) then
         Status := Header_Checksum_Failed;
         return;
      elsif Read_U32 (Fixed, Batch_Image_Index (Image'Length - Batch_Trailer_Length))
        /= Formats.CRC_32C
          (Fixed (0 .. Image'Length - (Batch_Trailer_Length + 1)))
      then
         Status := Object_Checksum_Failed;
         return;
      elsif Payload_Length > Interfaces.Unsigned_64 (Limits.Payload_Bytes) then
         Status := Limit_Exceeded;
         return;
      end if;

      Transaction_Wire := Read_U32 (Fixed, 148);
      Mutation_Wire := Read_U32 (Fixed, 152);
      if Transaction_Wire = 0
        or else Mutation_Wire = 0
      then
         Status := Invalid_Batch_State;
         return;
      elsif Transaction_Wire > Interfaces.Unsigned_32 (Transaction_Count'Last)
        or else Mutation_Wire > Interfaces.Unsigned_32 (Mutation_Count'Last)
        or else Transaction_Wire > Interfaces.Unsigned_32 (Limits.Transactions)
        or else Mutation_Wire > Interfaces.Unsigned_32 (Limits.Mutations)
      then
         Status := Limit_Exceeded;
         return;
      end if;

      Candidate.Database_ID := Read_Identifier (Fixed, 12);
      Candidate.Epoch := Head_Policy.Writer_Epoch (Read_U64 (Fixed, 44));
      Candidate.Batch_ID := Read_Identifier (Fixed, 52);
      Candidate.Previous_Batch_ID := Read_Identifier (Fixed, 68);
      Candidate.Expected_Transition_ID := Read_Identifier (Fixed, 84);
      Expected_Number_Wire := Read_U64 (Fixed, 100);
      Candidate.Publication_Transition_ID := Read_Identifier (Fixed, 108);
      Publication_Number_Wire := Read_U64 (Fixed, 124);
      Candidate.First_Sequence := Head_Policy.Commit_Sequence (Read_U64 (Fixed, 132));
      Candidate.Last_Sequence := Head_Policy.Commit_Sequence (Read_U64 (Fixed, 140));
      Candidate.Transaction_Total := Transaction_Count (Transaction_Wire);
      Candidate.Mutation_Total := Mutation_Count (Mutation_Wire);

      if Head_Policy.Is_Zero (Candidate.Database_ID)
        or else Candidate.Epoch = 0
        or else Head_Policy.Is_Zero (Candidate.Batch_ID)
        or else
          (not Head_Policy.Is_Zero (Candidate.Previous_Batch_ID)
           and then Candidate.Batch_ID = Candidate.Previous_Batch_ID)
        or else Head_Policy.Is_Zero (Candidate.Expected_Transition_ID)
        or else Head_Policy.Is_Zero (Candidate.Publication_Transition_ID)
        or else Candidate.Expected_Transition_ID = Candidate.Publication_Transition_ID
        or else Expected_Number_Wire = 0
        or else Expected_Number_Wire = Interfaces.Unsigned_64'Last
        or else Publication_Number_Wire /= Expected_Number_Wire + 1
        or else Candidate.First_Sequence = 0
        or else Candidate.Last_Sequence < Candidate.First_Sequence
        or else Interfaces.Unsigned_64 (Candidate.Last_Sequence - Candidate.First_Sequence) + 1
          /= Interfaces.Unsigned_64 (Candidate.Transaction_Total)
        or else
          (Head_Policy.Is_Zero (Candidate.Previous_Batch_ID) /= (Candidate.First_Sequence = 1))
        or else
          (if Candidate.First_Sequence = 1 then
             Expected_Number_Wire /= Interfaces.Unsigned_64 (Candidate.Epoch)
           else
             Expected_Number_Wire <= Interfaces.Unsigned_64 (Candidate.Epoch))
      then
         Status := Invalid_Batch_State;
         return;
      end if;
      Candidate.Expected_Transition_Number := Head_Policy.Transition_Ordinal (Expected_Number_Wire);
      Candidate.Publication_Transition_Number :=
        Head_Policy.Transition_Ordinal (Publication_Number_Wire);

      Payload_End := Image'Length - Batch_Trailer_Length;
      for Transaction_Index in Transaction_Slot range 1 .. Candidate.Transaction_Total loop
         pragma Loop_Invariant (Parsed_Mutations <= Candidate.Mutation_Total);
         pragma Loop_Invariant (Cursor >= Batch_Header_Length);
         pragma Loop_Invariant (Cursor <= Payload_End);
         declare
            Transaction_Mutations_Wire : Interfaces.Unsigned_32;
            Body_Length_Wire           : Interfaces.Unsigned_32;
            Transaction_Mutations      : Mutation_Count;
            Body_Length                : Payload_Count;
            Count_Valid                : Boolean;
            Extent_Valid               : Boolean;
            Transaction_End       : Natural;
         begin
            if Cursor > Payload_End
              or else Transaction_Frame_Header_Length > Payload_End - Cursor
            then
               Status := Invalid_Transaction;
               return;
            end if;
            Candidate.Transactions (Transaction_Index).Transaction_ID :=
              Read_Identifier (Fixed, Batch_Image_Index (Cursor));
            Candidate.Transactions (Transaction_Index).Sequence :=
              Head_Policy.Commit_Sequence (Read_U64 (Fixed, Batch_Image_Index (Cursor + 16)));
            Transaction_Mutations_Wire := Read_U32 (Fixed, Batch_Image_Index (Cursor + 24));
            Body_Length_Wire := Read_U32 (Fixed, Batch_Image_Index (Cursor + 28));
            Cursor := Cursor + Transaction_Frame_Header_Length;

            Decode_Mutation_Count
              (Transaction_Mutations_Wire,
               Candidate.Mutation_Total - Parsed_Mutations,
               Transaction_Mutations,
               Count_Valid);
            Decode_Extent
              (Body_Length_Wire,
               Payload_Count (Payload_End - Cursor),
               Body_Length,
               Extent_Valid);

            if Head_Policy.Is_Zero (Candidate.Transactions (Transaction_Index).Transaction_ID)
              or else Candidate.Transactions (Transaction_Index).Sequence /=
                Candidate.First_Sequence + Head_Policy.Commit_Sequence (Transaction_Index - 1)
              or else not Count_Valid
              or else not Extent_Valid
              or else Transaction_Mutations = 0
            then
               Status := Invalid_Transaction;
               return;
            end if;

            for Earlier in Transaction_Slot range 1 .. Transaction_Index - 1 loop
               if Candidate.Transactions (Earlier).Transaction_ID =
                 Candidate.Transactions (Transaction_Index).Transaction_ID
               then
                  Status := Duplicate_Transaction;
                  return;
               end if;
            end loop;

            Candidate.Transactions (Transaction_Index).First_Mutation :=
              Mutation_Count (Parsed_Mutations + 1);
            Candidate.Transactions (Transaction_Index).Mutations := Transaction_Mutations;
            Transaction_End := Cursor + Body_Length;
            pragma Assert (Transaction_End <= Payload_End);

            for Offset in Natural range 0 .. Transaction_Mutations - 1 loop
               pragma Loop_Invariant
                 (Parsed_Mutations + Transaction_Mutations <= Candidate.Mutation_Total);
               pragma Loop_Invariant
                 (Parsed_Mutations + Offset < Candidate.Mutation_Total);
               pragma Loop_Invariant (Cursor <= Transaction_End);
               pragma Loop_Invariant (Transaction_End <= Payload_End);
               declare
                  Mutation_Index : constant Mutation_Slot :=
                    Mutation_Slot (Parsed_Mutations + (Offset + 1));
                  Key_Wire       : Interfaces.Unsigned_32;
                  Value_Wire     : Interfaces.Unsigned_32;
                  Operation_Code : Formats.Byte;
                  Flags_Code     : Formats.Byte;
                  Key_Count      : Key_Length;
                  Value_Count    : Value_Length;
               begin
                  if Cursor > Transaction_End
                    or else Mutation_Frame_Header_Length > Transaction_End - Cursor
                  then
                     Status := Invalid_Mutation;
                     return;
                  end if;

                  Candidate.Mutations (Mutation_Index).Column_Family :=
                    Read_U32 (Fixed, Batch_Image_Index (Cursor));
                  Operation_Code := Fixed (Cursor + 4);
                  Flags_Code := Fixed (Cursor + 5);
                  Key_Wire := Read_U32 (Fixed, Batch_Image_Index (Cursor + 6));
                  Value_Wire := Read_U32 (Fixed, Batch_Image_Index (Cursor + 10));
                  Cursor := Cursor + Mutation_Frame_Header_Length;

                  if Candidate.Mutations (Mutation_Index).Column_Family = 0
                    or else Flags_Code /= 0
                    or else Operation_Code not in 1 .. 2
                  then
                     Status := Invalid_Mutation;
                     return;
                  elsif Key_Wire > Interfaces.Unsigned_32 (Key_Length'Last)
                    or else Value_Wire > Interfaces.Unsigned_32 (Value_Length'Last)
                  then
                     Status := Limit_Exceeded;
                     return;
                  elsif Key_Wire > Interfaces.Unsigned_32 (Limits.Key_Bytes)
                    or else Value_Wire > Interfaces.Unsigned_32 (Limits.Value_Bytes)
                  then
                     Status := Limit_Exceeded;
                     return;
                  elsif Operation_Code = 2 and then Value_Wire /= 0 then
                     Status := Invalid_Mutation;
                     return;
                  end if;

                  Key_Count := Key_Length (Key_Wire);
                  Value_Count := Value_Length (Value_Wire);
                  if Natural (Key_Count) > Transaction_End - Cursor then
                     Status := Invalid_Mutation;
                     return;
                  end if;

                  Candidate.Mutations (Mutation_Index).Operation :=
                    (if Operation_Code = 1 then Put else Delete);
                  Candidate.Mutations (Mutation_Index).Key_Size := Key_Count;
                  Copy_Key
                    (Fixed, Cursor, Key_Count,
                     Candidate.Mutations (Mutation_Index).Key);
                  Cursor := Cursor + Key_Count;

                  if Natural (Value_Count) > Transaction_End - Cursor then
                     Status := Invalid_Mutation;
                     return;
                  end if;
                  Candidate.Mutations (Mutation_Index).Value_Size := Value_Count;
                  Copy_Value
                    (Fixed, Cursor, Value_Count,
                     Candidate.Mutations (Mutation_Index).Value);
                  Cursor := Cursor + Value_Count;
                  pragma Assert (Cursor <= Transaction_End);

                  for Earlier in Natural range 0 .. Offset - 1 loop
                     pragma Loop_Invariant
                       (Parsed_Mutations + Earlier < Candidate.Mutation_Total);
                     if Same_Key
                       (Candidate.Mutations
                          (Mutation_Slot (Parsed_Mutations + (Earlier + 1))),
                        Candidate.Mutations (Mutation_Index))
                     then
                        Status := Duplicate_Key;
                        return;
                     end if;
                  end loop;
               end;
            end loop;

            if Cursor /= Transaction_End then
               Status := Invalid_Transaction;
               return;
            end if;
            Parsed_Mutations := Parsed_Mutations + Transaction_Mutations;
         end;
      end loop;

      if Cursor /= Payload_End or else Parsed_Mutations /= Candidate.Mutation_Total then
         Status := Invalid_Length;
      elsif not Structurally_Valid (Candidate) then
         Status := Invalid_Batch_State;
      else
         Value := Candidate;
         Status := Decoded;
      end if;
   end Decode_Batch;

   procedure Decode_Latest_Batch
     (Image             : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Referencing_Head  : Head_Policy.Head_State;
      Limits            : Reader_Caps;
      Value             : out Commit_Batch;
      Status            : out Decode_Status)
   is
   begin
      Decode_Batch (Image, Expected_Database, Limits, Value, Status);
      if Status = Decoded and then not Published_By (Value, Referencing_Head) then
         Value := Empty_Batch;
         Status := Head_Mismatch;
      end if;
   end Decode_Latest_Batch;

end Flyology.DB.Batch_Formats;
