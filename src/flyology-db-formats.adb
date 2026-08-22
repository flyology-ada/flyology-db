package body Flyology.DB.Formats
  with SPARK_Mode => On
is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Magic : constant Byte_Array (0 .. 7) :=
     [Character'Pos ('F'), Character'Pos ('L'), Character'Pos ('Y'), Character'Pos ('H'),
      Character'Pos ('E'), Character'Pos ('A'), Character'Pos ('D'), Character'Pos ('1')];

   Head_Kind     : constant Byte := 1;
   Header_Length : constant Interfaces.Unsigned_32 := 132;

   procedure Put_U16
     (Image : in out Head_Image;
      Position    : Head_Image_Index;
      Value : Interfaces.Unsigned_16)
   with Pre => Position <= Head_Image_Index'Last - 1;

   procedure Put_U32
     (Image : in out Head_Image;
      Position    : Head_Image_Index;
      Value : Interfaces.Unsigned_32)
   with Pre => Position <= Head_Image_Index'Last - 3;

   procedure Put_U64
     (Image : in out Head_Image;
      Position    : Head_Image_Index;
      Value : Interfaces.Unsigned_64)
   with Pre => Position <= Head_Image_Index'Last - 7;

   function Read_U16
     (Image : Head_Image;
      Position    : Head_Image_Index) return Interfaces.Unsigned_16
   with Pre => Position <= Head_Image_Index'Last - 1;

   function Read_U32
     (Image : Head_Image;
      Position    : Head_Image_Index) return Interfaces.Unsigned_32
   with Pre => Position <= Head_Image_Index'Last - 3;

   function Read_U64
     (Image : Head_Image;
      Position    : Head_Image_Index) return Interfaces.Unsigned_64
   with Pre => Position <= Head_Image_Index'Last - 7;

   procedure Put_Identifier
     (Image : in out Head_Image;
      Position    : Head_Image_Index;
      Value : Head_Policy.Identifier)
   with Pre => Position <= Head_Image_Index'Last - Head_Policy.Identifier_Length + 1;

   function Read_Identifier
     (Image : Head_Image;
      Position    : Head_Image_Index) return Head_Policy.Identifier
   with Pre => Position <= Head_Image_Index'Last - Head_Policy.Identifier_Length + 1;

   function Header_Checksum (Image : Head_Image) return Interfaces.Unsigned_32;

   procedure Put_U16
     (Image : in out Head_Image;
      Position    : Head_Image_Index;
      Value : Interfaces.Unsigned_16)
   is
   begin
      Image (Position) := Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);
      Image (Position + 1) := Byte (Value and 16#FF#);
   end Put_U16;

   procedure Put_U32
     (Image : in out Head_Image;
      Position    : Head_Image_Index;
      Value : Interfaces.Unsigned_32)
   is
   begin
      for Offset in Natural range 0 .. 3 loop
         Image (Position + Offset) :=
           Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64
     (Image : in out Head_Image;
      Position    : Head_Image_Index;
      Value : Interfaces.Unsigned_64)
   is
   begin
      for Offset in Natural range 0 .. 7 loop
         Image (Position + Offset) :=
           Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   function Read_U16
     (Image : Head_Image;
      Position    : Head_Image_Index) return Interfaces.Unsigned_16
   is
   begin
      return Interfaces.Shift_Left (Interfaces.Unsigned_16 (Image (Position)), 8)
        or Interfaces.Unsigned_16 (Image (Position + 1));
   end Read_U16;

   function Read_U32
     (Image : Head_Image;
      Position    : Head_Image_Index) return Interfaces.Unsigned_32
   is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      for Offset in Natural range 0 .. 3 loop
         Result := Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_32 (Image (Position + Offset));
      end loop;
      return Result;
   end Read_U32;

   function Read_U64
     (Image : Head_Image;
      Position    : Head_Image_Index) return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Offset in Natural range 0 .. 7 loop
         Result := Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_64 (Image (Position + Offset));
      end loop;
      return Result;
   end Read_U64;

   procedure Put_Identifier
     (Image : in out Head_Image;
      Position    : Head_Image_Index;
      Value : Head_Policy.Identifier)
   is
   begin
      for Index in Head_Policy.Identifier_Index loop
         Image (Position + Index - Head_Policy.Identifier_Index'First) := Value (Index);
      end loop;
   end Put_Identifier;

   function Read_Identifier
     (Image : Head_Image;
      Position    : Head_Image_Index) return Head_Policy.Identifier
   is
      Result : Head_Policy.Identifier;
   begin
      for Index in Head_Policy.Identifier_Index loop
         Result (Index) := Image (Position + Index - Head_Policy.Identifier_Index'First);
      end loop;
      return Result;
   end Read_Identifier;

   function CRC_32C (Data : Byte_Array) return Interfaces.Unsigned_32 is
      Polynomial : constant Interfaces.Unsigned_32 := 16#82F6_3B78#;
      Result     : Interfaces.Unsigned_32 := 16#FFFF_FFFF#;
   begin
      for Index in Data'Range loop
         Result := Result xor Interfaces.Unsigned_32 (Data (Index));
         for Bit in Natural range 0 .. 7 loop
            if (Result and 1) = 1 then
               Result := Interfaces.Shift_Right (Result, 1) xor Polynomial;
            else
               Result := Interfaces.Shift_Right (Result, 1);
            end if;
         end loop;
      end loop;
      return not Result;
   end CRC_32C;

   function Header_Checksum (Image : Head_Image) return Interfaces.Unsigned_32 is
      Header : Byte_Array (0 .. Natural (Header_Length) - 1) := Image (0 .. Natural (Header_Length) - 1);
   begin
      Header (40 .. 43) := [others => 0];
      return CRC_32C (Header);
   end Header_Checksum;

   function Encode_Head (Value : Head_Policy.Head_State) return Head_Image is
      Result : Head_Image := [others => 0];
   begin
      Result (0 .. 7) := Magic;
      Put_U16 (Result, 8, Interfaces.Unsigned_16 (Value.Version));
      Result (10) := Head_Kind;
      Result (11) := 0;
      Put_Identifier (Result, 12, Value.Database_ID);
      Put_U32 (Result, 28, Header_Length);
      Put_U64 (Result, 32, 0);
      Put_U64 (Result, 44, Interfaces.Unsigned_64 (Value.Epoch));
      Put_U64 (Result, 52, Interfaces.Unsigned_64 (Value.Highest_Visible));
      Put_Identifier (Result, 60, Value.Latest_Batch);
      Put_Identifier (Result, 76, Value.Latest_Manifest);
      Put_Identifier (Result, 92, Value.Transition_ID);
      Put_Identifier (Result, 108, Value.Predecessor_Transition);
      Put_U64 (Result, 124, Interfaces.Unsigned_64 (Value.Transition_Number));
      Put_U32 (Result, 40, Header_Checksum (Result));
      Put_U32 (Result, 132, CRC_32C (Result (0 .. 131)));
      return Result;
   end Encode_Head;

   procedure Decode_Head
     (Image             : Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Value             : out Head_Policy.Head_State;
      Status            : out Decode_Status)
   is
      Fixed     : Head_Image;
      Candidate : Head_Policy.Head_State;
   begin
      Value := (others => <>);

      if Image'Length /= Head_Image_Length then
         Status := Invalid_Length;
         return;
      end if;

      for Offset in Head_Image_Index loop
         Fixed (Offset) := Image (Image'First + Offset);
      end loop;

      if Fixed (0 .. 7) /= Magic then
         Status := Invalid_Magic;
      elsif Read_U16 (Fixed, 8) /= Interfaces.Unsigned_16 (Head_Policy.Current_Format) then
         Status := Unsupported_Version;
      elsif Fixed (10) /= Head_Kind then
         Status := Invalid_Object_Kind;
      elsif Fixed (11) /= 0 then
         Status := Invalid_Flags;
      elsif Read_Identifier (Fixed, 12) /= Expected_Database then
         Status := Wrong_Database;
      elsif Read_U32 (Fixed, 28) /= Header_Length or else Read_U64 (Fixed, 32) /= 0 then
         Status := Invalid_Length;
      elsif Read_U32 (Fixed, 40) /= Header_Checksum (Fixed) then
         Status := Header_Checksum_Failed;
      elsif Read_U32 (Fixed, 132) /= CRC_32C (Fixed (0 .. 131)) then
         Status := Object_Checksum_Failed;
      elsif Read_U64 (Fixed, 124) = 0 then
         Status := Invalid_Head_State;
      else
         Candidate :=
           (Database_ID            => Read_Identifier (Fixed, 12),
            Version                => Head_Policy.Format_Version (Read_U16 (Fixed, 8)),
            Epoch                  => Head_Policy.Writer_Epoch (Read_U64 (Fixed, 44)),
            Highest_Visible        => Head_Policy.Commit_Sequence (Read_U64 (Fixed, 52)),
            Latest_Batch           => Read_Identifier (Fixed, 60),
            Latest_Manifest        => Read_Identifier (Fixed, 76),
            Transition_ID          => Read_Identifier (Fixed, 92),
            Predecessor_Transition => Read_Identifier (Fixed, 108),
            Transition_Number      => Head_Policy.Transition_Ordinal (Read_U64 (Fixed, 124)));

         if not Head_Policy.Structurally_Valid (Candidate) then
            Status := Invalid_Head_State;
         else
            Value := Candidate;
            Status := Decoded;
         end if;
      end if;
   end Decode_Head;

end Flyology.DB.Formats;
