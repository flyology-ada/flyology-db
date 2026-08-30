with Interfaces;
with Flyology.DB.Batch_Formats;
with Flyology.DB.Formats;

package body Flyology.DB.Commit_Authority_Formats
  with SPARK_Mode => On
is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Formats.Byte_Array;
   use type Flyology.DB.Formats.Decode_Status;
   use type Heads.Format_Version;
   use type Heads.Transition_Ordinal;
   use type Heads.Writer_Epoch;

   subtype Header_Index is Natural range 0 .. Authority_Header_Length - 1;
   subtype Header_Image is Formats.Byte_Array (Header_Index);

   Magic : constant Formats.Byte_Array (0 .. 7) :=
     [Character'Pos ('F'),
      Character'Pos ('L'),
      Character'Pos ('Y'),
      Character'Pos ('C'),
      Character'Pos ('A'),
      Character'Pos ('U'),
      Character'Pos ('T'),
      Character'Pos ('1')];

   Authority_Format_Version : constant Interfaces.Unsigned_16 := 1;
   Authority_Object_Kind    : constant Formats.Byte := 1;

   --  Batch format version 1 freezes object kind 2 for immutable commit
   --  batches. Authority envelopes embed that existing persisted object.
   Embedded_Batch_Object_Kind : constant Formats.Byte := 2;

   procedure Put_U16 (Image : in out Header_Image; Position : Header_Index; Value : Interfaces.Unsigned_16)
   with Pre => Position <= Header_Index'Last - 1;

   procedure Put_U32 (Image : in out Header_Image; Position : Header_Index; Value : Interfaces.Unsigned_32)
   with Pre => Position <= Header_Index'Last - 3;

   procedure Put_U64 (Image : in out Header_Image; Position : Header_Index; Value : Interfaces.Unsigned_64)
   with Pre => Position <= Header_Index'Last - 7;

   function Read_U16 (Image : Header_Image; Position : Header_Index) return Interfaces.Unsigned_16
   with Pre => Position <= Header_Index'Last - 1;

   function Read_U32 (Image : Header_Image; Position : Header_Index) return Interfaces.Unsigned_32
   with Pre => Position <= Header_Index'Last - 3;

   function Read_U64 (Image : Header_Image; Position : Header_Index) return Interfaces.Unsigned_64
   with Pre => Position <= Header_Index'Last - 7;

   procedure Put_Identifier (Image : in out Header_Image; Position : Header_Index; Value : Heads.Identifier)
   with Pre => Position <= Header_Index'Last - Heads.Identifier_Length + 1;

   function Read_Identifier (Image : Header_Image; Position : Header_Index) return Heads.Identifier
   with Pre => Position <= Header_Index'Last - Heads.Identifier_Length + 1;

   function Header_Checksum (Image : Header_Image) return Interfaces.Unsigned_32;

   function Batch_U32 (Batch : Byte_Array; Offset : Natural) return Interfaces.Unsigned_32
   with Pre => Batch'Length >= 4 and then Offset <= Batch'Length - 4;

   function Batch_U16 (Batch : Byte_Array; Offset : Natural) return Interfaces.Unsigned_16
   with Pre => Batch'Length >= 2 and then Offset <= Batch'Length - 2;

   function Batch_U64 (Batch : Byte_Array; Offset : Natural) return Interfaces.Unsigned_64
   with Pre => Batch'Length >= 8 and then Offset <= Batch'Length - 8;

   function Batch_Identifier (Batch : Byte_Array; Offset : Natural) return Heads.Identifier
   with
     Pre => Batch'Length >= Heads.Identifier_Length and then Offset <= Batch'Length - Heads.Identifier_Length;

   procedure Put_U16 (Image : in out Header_Image; Position : Header_Index; Value : Interfaces.Unsigned_16) is
   begin
      Image (Position) := Formats.Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);
      Image (Position + 1) := Formats.Byte (Value and 16#FF#);
   end Put_U16;

   procedure Put_U32 (Image : in out Header_Image; Position : Header_Index; Value : Interfaces.Unsigned_32) is
   begin
      for Offset in Natural range 0 .. 3 loop
         Image (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64 (Image : in out Header_Image; Position : Header_Index; Value : Interfaces.Unsigned_64) is
   begin
      for Offset in Natural range 0 .. 7 loop
         Image (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   function Read_U16 (Image : Header_Image; Position : Header_Index) return Interfaces.Unsigned_16 is
   begin
      return
        Interfaces.Shift_Left (Interfaces.Unsigned_16 (Image (Position)), 8)
        or Interfaces.Unsigned_16 (Image (Position + 1));
   end Read_U16;

   function Read_U32 (Image : Header_Image; Position : Header_Index) return Interfaces.Unsigned_32 is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      for Offset in Natural range 0 .. 3 loop
         Result := Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_32 (Image (Position + Offset));
      end loop;
      return Result;
   end Read_U32;

   function Read_U64 (Image : Header_Image; Position : Header_Index) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Offset in Natural range 0 .. 7 loop
         Result := Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_64 (Image (Position + Offset));
      end loop;
      return Result;
   end Read_U64;

   procedure Put_Identifier (Image : in out Header_Image; Position : Header_Index; Value : Heads.Identifier)
   is
   begin
      for Index in Heads.Identifier_Index loop
         Image (Position + Index - Heads.Identifier_Index'First) := Value (Index);
      end loop;
   end Put_Identifier;

   function Read_Identifier (Image : Header_Image; Position : Header_Index) return Heads.Identifier is
      Result : Heads.Identifier;
   begin
      for Index in Heads.Identifier_Index loop
         Result (Index) := Image (Position + Index - Heads.Identifier_Index'First);
      end loop;
      return Result;
   end Read_Identifier;

   function Header_Checksum (Image : Header_Image) return Interfaces.Unsigned_32 is
      Header : Header_Image := Image;
   begin
      Header (44 .. 47) := [others => 0];
      return Formats.CRC_32C (Header);
   end Header_Checksum;

   function Batch_U32 (Batch : Byte_Array; Offset : Natural) return Interfaces.Unsigned_32 is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      for Index in Natural range 0 .. 3 loop
         Result :=
           Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_32 (Batch (Batch'First + Offset + Index));
      end loop;
      return Result;
   end Batch_U32;

   function Batch_U16 (Batch : Byte_Array; Offset : Natural) return Interfaces.Unsigned_16 is
   begin
      return
        Interfaces.Shift_Left (Interfaces.Unsigned_16 (Batch (Batch'First + Offset)), 8)
        or Interfaces.Unsigned_16 (Batch (Batch'First + Offset + 1));
   end Batch_U16;

   function Batch_U64 (Batch : Byte_Array; Offset : Natural) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Index in Natural range 0 .. 7 loop
         Result :=
           Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_64 (Batch (Batch'First + Offset + Index));
      end loop;
      return Result;
   end Batch_U64;

   function Batch_Identifier (Batch : Byte_Array; Offset : Natural) return Heads.Identifier is
      Result : Heads.Identifier;
   begin
      for Index in Heads.Identifier_Index loop
         pragma Loop_Invariant
           (Natural (Index - Heads.Identifier_Index'First) <= Batch'Length - Offset - 1);
         Result (Index) :=
           Batch (Batch'First + (Offset + Natural (Index - Heads.Identifier_Index'First)));
      end loop;
      return Result;
   end Batch_Identifier;

   function Structurally_Valid (Value : Authority_Metadata) return Boolean is
      Difference : Interfaces.Unsigned_64;
   begin
      if Heads.Is_Zero (Value.Transaction_ID)
        or else Heads.Is_Zero (Value.Batch_ID)
        or else not Heads.Structurally_Valid (Value.Expected_Head)
        or else Value.Expected_Head.Highest_Visible >= Value.Attempted_Head.Highest_Visible
      then
         return False;
      end if;
      Difference :=
        Interfaces.Unsigned_64 (Value.Attempted_Head.Highest_Visible)
        - Interfaces.Unsigned_64 (Value.Expected_Head.Highest_Visible);
      return
        Difference in 1 .. Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)
        and then Value.Assigned_Sequence > Value.Expected_Head.Highest_Visible
        and then Value.Assigned_Sequence <= Value.Attempted_Head.Highest_Visible
        and then Heads.Structurally_Valid (Value.Attempted_Head)
        and then Value.Expected_Head.Database_ID = Value.Attempted_Head.Database_ID
        and then Value.Expected_Head.Version = Heads.Current_Format
        and then Value.Attempted_Head.Version = Heads.Current_Format
        and then Value.Expected_Head.Epoch = Value.Attempted_Head.Epoch
        and then Value.Attempted_Head.Latest_Batch = Value.Batch_ID
        and then Value.Attempted_Head.Latest_Manifest = Value.Expected_Head.Latest_Manifest
        and then not Heads.Is_Zero (Value.Attempted_Head.Transition_ID)
        and then Value.Attempted_Head.Transition_ID /= Value.Expected_Head.Transition_ID
        and then Value.Attempted_Head.Predecessor_Transition = Value.Expected_Head.Transition_ID
        and then Value.Expected_Head.Transition_Number < Heads.Transition_Ordinal'Last
        and then Value.Attempted_Head.Transition_Number = Value.Expected_Head.Transition_Number + 1;
   end Structurally_Valid;

   function Batch_Member_Valid (Value : Authority_Metadata; Batch : Byte_Array) return Boolean is
      Batch_Header_Length  : constant := Batch_Formats.Batch_Header_Length;
      Batch_Trailer_Length : constant := Batch_Formats.Batch_Trailer_Length;
      Header               : Formats.Byte_Array (0 .. Batch_Header_Length - 1);
      Payload_Length       : Interfaces.Unsigned_64;
      Transaction_Total    : Interfaces.Unsigned_32;
      Cursor               : Natural := Batch_Header_Length;
      Payload_End          : Natural;
      Member_Total         : Natural := 0;
      Stored_Checksum      : Interfaces.Unsigned_32;
      Header_Checksum      : Interfaces.Unsigned_32;
      Expected_Total       : Interfaces.Unsigned_64;
   begin
      if not Structurally_Valid (Value) or else Batch'Length < Batch_Header_Length + Batch_Trailer_Length then
         return False;
      end if;
      for Offset in Header'Range loop
         Header (Offset) := Batch (Batch'First + Offset);
      end loop;
      Payload_Length := Batch_U64 (Batch, 32);
      if Payload_Length > Interfaces.Unsigned_64 (Natural'Last)
        or else Natural (Payload_Length) > Natural'Last - Batch_Header_Length - Batch_Trailer_Length
        or else Batch_Header_Length + Natural (Payload_Length) + Batch_Trailer_Length /= Batch'Length
      then
         return False;
      end if;

      if Header (0 .. 7)
        /= Formats.Byte_Array'
             (Character'Pos ('F'),
              Character'Pos ('L'),
              Character'Pos ('Y'),
              Character'Pos ('B'),
              Character'Pos ('A'),
              Character'Pos ('T'),
              Character'Pos ('C'),
              Character'Pos ('1'))
        or else Batch_U16 (Batch, 8) /= Batch_Formats.Batch_Format_Version
        or else Header (10) /= Embedded_Batch_Object_Kind
        or else Header (11) /= 0
        or else Batch_Identifier (Batch, 12) /= Value.Expected_Head.Database_ID
        or else Batch_U32 (Batch, 28) /= Interfaces.Unsigned_32 (Batch_Header_Length)
      then
         return False;
      end if;

      Header_Checksum := Batch_U32 (Batch, 40);
      Header (40 .. 43) := [others => 0];
      if Header_Checksum /= Formats.CRC_32C (Header) then
         return False;
      end if;
      Stored_Checksum := Batch_U32 (Batch, Batch'Length - Batch_Trailer_Length);
      if Stored_Checksum
        /= Formats.CRC_32C (Formats.Byte_Array (Batch (Batch'First .. Batch'Last - Batch_Trailer_Length)))
      then
         return False;
      end if;

      Expected_Total :=
        Interfaces.Unsigned_64 (Value.Attempted_Head.Highest_Visible)
        - Interfaces.Unsigned_64 (Value.Expected_Head.Highest_Visible);
      Transaction_Total := Batch_U32 (Batch, 148);
      if Interfaces.Unsigned_64 (Transaction_Total) /= Expected_Total
        or else Batch_U64 (Batch, 44) /= Interfaces.Unsigned_64 (Value.Expected_Head.Epoch)
        or else Batch_Identifier (Batch, 52) /= Value.Batch_ID
        or else Batch_Identifier (Batch, 68) /= Value.Expected_Head.Latest_Batch
        or else Batch_Identifier (Batch, 84) /= Value.Expected_Head.Transition_ID
        or else Batch_U64 (Batch, 100) /= Interfaces.Unsigned_64 (Value.Expected_Head.Transition_Number)
        or else Batch_Identifier (Batch, 108) /= Value.Attempted_Head.Transition_ID
        or else Batch_U64 (Batch, 124) /= Interfaces.Unsigned_64 (Value.Attempted_Head.Transition_Number)
        or else Batch_U64 (Batch, 132) /= Interfaces.Unsigned_64 (Value.Expected_Head.Highest_Visible) + 1
        or else Batch_U64 (Batch, 140) /= Interfaces.Unsigned_64 (Value.Attempted_Head.Highest_Visible)
      then
         return False;
      end if;

      Payload_End := Batch_Header_Length + Natural (Payload_Length);
      for Transaction_Index in Interfaces.Unsigned_32 range 1 .. Transaction_Total loop
         if Cursor > Payload_End or else Payload_End - Cursor < 32 then
            return False;
         end if;
         declare
            Transaction_ID : constant Heads.Identifier := Batch_Identifier (Batch, Cursor);
            Sequence       : constant Interfaces.Unsigned_64 := Batch_U64 (Batch, Cursor + 16);
            Body_Length    : constant Interfaces.Unsigned_32 := Batch_U32 (Batch, Cursor + 28);
         begin
            if Sequence /= Batch_U64 (Batch, 132) + Interfaces.Unsigned_64 (Transaction_Index) - 1
              or else Interfaces.Unsigned_64 (Body_Length)
                      > Interfaces.Unsigned_64 (Payload_End - Cursor - 32)
            then
               return False;
            end if;
            if Transaction_ID = Value.Transaction_ID
              and then Sequence = Interfaces.Unsigned_64 (Value.Assigned_Sequence)
            then
               if Member_Total = 1 then
                  return False;
               end if;
               Member_Total := 1;
            end if;
            Cursor := Cursor + 32 + Natural (Body_Length);
         end;
      end loop;
      return Cursor = Payload_End and then Member_Total = 1;
   end Batch_Member_Valid;

   function Source_Batch_Member_Valid (Value : Authority_Metadata; Source : Source_Type) return Boolean is
      Batch_Header_Length  : constant := Batch_Formats.Batch_Header_Length;
      Batch_Trailer_Length : constant := Batch_Formats.Batch_Trailer_Length;
      Length               : constant Natural := Source_Length (Source);
      Header               : Formats.Byte_Array (0 .. Batch_Header_Length - 1);
      Payload_Length       : Interfaces.Unsigned_64;
      Transaction_Total    : Interfaces.Unsigned_32;
      Cursor               : Natural := Batch_Header_Length;
      Payload_End          : Natural;
      Member_Total         : Natural := 0;
      Expected_Total       : Interfaces.Unsigned_64;

      function Read_U16_At (Offset : Natural) return Interfaces.Unsigned_16
      with Pre => Length >= 2 and then Offset <= Length - 2
      is
      begin
         return
           Interfaces.Shift_Left (Interfaces.Unsigned_16 (Source_Element (Source, Offset + 1)), 8)
           or Interfaces.Unsigned_16 (Source_Element (Source, Offset + 2));
      end Read_U16_At;

      function Read_U32_At (Offset : Natural) return Interfaces.Unsigned_32
      with Pre => Length >= 4 and then Offset <= Length - 4
      is
         Result : Interfaces.Unsigned_32 := 0;
      begin
         for Index in Natural range 0 .. 3 loop
            pragma Loop_Invariant (Index + 1 <= Length - Offset);
            Result :=
              Interfaces.Shift_Left (Result, 8)
              or Interfaces.Unsigned_32 (Source_Element (Source, Offset + (Index + 1)));
         end loop;
         return Result;
      end Read_U32_At;

      function Read_U64_At (Offset : Natural) return Interfaces.Unsigned_64
      with Pre => Length >= 8 and then Offset <= Length - 8
      is
         Result : Interfaces.Unsigned_64 := 0;
      begin
         for Index in Natural range 0 .. 7 loop
            pragma Loop_Invariant (Index + 1 <= Length - Offset);
            Result :=
              Interfaces.Shift_Left (Result, 8)
              or Interfaces.Unsigned_64 (Source_Element (Source, Offset + (Index + 1)));
         end loop;
         return Result;
      end Read_U64_At;

      function Read_Identifier_At (Offset : Natural) return Heads.Identifier
      with Pre => Length >= Heads.Identifier_Length and then Offset <= Length - Heads.Identifier_Length
      is
         Result : Heads.Identifier;
      begin
         for Index in Heads.Identifier_Index loop
            pragma Loop_Invariant
              (Natural (Index - Heads.Identifier_Index'First) + 1 <= Length - Offset);
            Result (Index) :=
              Source_Element
                (Source, Offset + (Natural (Index - Heads.Identifier_Index'First) + 1));
         end loop;
         return Result;
      end Read_Identifier_At;

      function Source_CRC (Last_Offset : Natural; Zero_Header_CRC : Boolean) return Interfaces.Unsigned_32
      with Pre => Length > 0 and then Last_Offset < Length
      is
         --  Streaming form of Formats.CRC_32C for a noncontiguous source; the
         --  polynomial and initialization are the same frozen CRC-32C contract.
         Polynomial : constant Interfaces.Unsigned_32 := 16#82F6_3B78#;
         Result     : Interfaces.Unsigned_32 := 16#FFFF_FFFF#;
         Item       : Interfaces.Unsigned_8;
      begin
         for Offset in Natural range 0 .. Last_Offset loop
            pragma Loop_Invariant (Offset < Length);
            Item :=
              (if Zero_Header_CRC and then Offset in 40 .. 43
               then 0
               else Source_Element (Source, Offset + 1));
            Result := Result xor Interfaces.Unsigned_32 (Item);
            for Bit in Natural range 0 .. 7 loop
               if (Result and 1) = 1 then
                  Result := Interfaces.Shift_Right (Result, 1) xor Polynomial;
               else
                  Result := Interfaces.Shift_Right (Result, 1);
               end if;
            end loop;
         end loop;
         return not Result;
      end Source_CRC;
   begin
      if not Structurally_Valid (Value) or else Length < Batch_Header_Length + Batch_Trailer_Length then
         return False;
      end if;
      for Offset in Header'Range loop
         Header (Offset) := Source_Element (Source, Offset + 1);
      end loop;
      Payload_Length := Read_U64_At (32);
      if Payload_Length > Interfaces.Unsigned_64 (Natural'Last)
        or else Natural (Payload_Length) > Natural'Last - Batch_Header_Length - Batch_Trailer_Length
        or else Batch_Header_Length + Natural (Payload_Length) + Batch_Trailer_Length /= Length
      then
         return False;
      end if;

      if Header (0 .. 7)
        /= Formats.Byte_Array'
             (Character'Pos ('F'),
              Character'Pos ('L'),
              Character'Pos ('Y'),
              Character'Pos ('B'),
              Character'Pos ('A'),
              Character'Pos ('T'),
              Character'Pos ('C'),
              Character'Pos ('1'))
        or else Read_U16_At (8) /= Batch_Formats.Batch_Format_Version
        or else Header (10) /= Embedded_Batch_Object_Kind
        or else Header (11) /= 0
        or else Read_Identifier_At (12) /= Value.Expected_Head.Database_ID
        or else Read_U32_At (28) /= Interfaces.Unsigned_32 (Batch_Header_Length)
        or else Read_U32_At (40) /= Source_CRC (Batch_Header_Length - 1, True)
        or else Read_U32_At (Length - Batch_Trailer_Length)
                /= Source_CRC (Length - Batch_Trailer_Length - 1, False)
      then
         return False;
      end if;

      Expected_Total :=
        Interfaces.Unsigned_64 (Value.Attempted_Head.Highest_Visible)
        - Interfaces.Unsigned_64 (Value.Expected_Head.Highest_Visible);
      Transaction_Total := Read_U32_At (148);
      if Interfaces.Unsigned_64 (Transaction_Total) /= Expected_Total
        or else Read_U64_At (44) /= Interfaces.Unsigned_64 (Value.Expected_Head.Epoch)
        or else Read_Identifier_At (52) /= Value.Batch_ID
        or else Read_Identifier_At (68) /= Value.Expected_Head.Latest_Batch
        or else Read_Identifier_At (84) /= Value.Expected_Head.Transition_ID
        or else Read_U64_At (100) /= Interfaces.Unsigned_64 (Value.Expected_Head.Transition_Number)
        or else Read_Identifier_At (108) /= Value.Attempted_Head.Transition_ID
        or else Read_U64_At (124) /= Interfaces.Unsigned_64 (Value.Attempted_Head.Transition_Number)
        or else Read_U64_At (132) /= Interfaces.Unsigned_64 (Value.Expected_Head.Highest_Visible) + 1
        or else Read_U64_At (140) /= Interfaces.Unsigned_64 (Value.Attempted_Head.Highest_Visible)
      then
         return False;
      end if;

      Payload_End := Batch_Header_Length + Natural (Payload_Length);
      for Transaction_Index in Interfaces.Unsigned_32 range 1 .. Transaction_Total loop
         if Cursor > Payload_End or else Payload_End - Cursor < 32 then
            return False;
         end if;
         declare
            Transaction_ID : constant Heads.Identifier := Read_Identifier_At (Cursor);
            Sequence       : constant Interfaces.Unsigned_64 := Read_U64_At (Cursor + 16);
            Body_Length    : constant Interfaces.Unsigned_32 := Read_U32_At (Cursor + 28);
         begin
            if Sequence /= Read_U64_At (132) + Interfaces.Unsigned_64 (Transaction_Index) - 1
              or else Interfaces.Unsigned_64 (Body_Length)
                      > Interfaces.Unsigned_64 (Payload_End - Cursor - 32)
            then
               return False;
            end if;
            if Transaction_ID = Value.Transaction_ID
              and then Sequence = Interfaces.Unsigned_64 (Value.Assigned_Sequence)
            then
               if Member_Total = 1 then
                  return False;
               end if;
               Member_Total := 1;
            end if;
            Cursor := Cursor + 32 + Natural (Body_Length);
         end;
      end loop;
      return Cursor = Payload_End and then Member_Total = 1;
   end Source_Batch_Member_Valid;

   function Encoded_Length (Batch_Length : Natural) return Natural is
   begin
      if Batch_Length = 0
        or else Batch_Length > Natural'Last - Authority_Header_Length - Authority_Trailer_Length
      then
         return 0;
      end if;
      return Authority_Header_Length + Batch_Length + Authority_Trailer_Length;
   end Encoded_Length;

   procedure Encode_Header
     (Value : Authority_Metadata; Batch_Length : Natural; Image : out Byte_Array; Status : out Encode_Status)
   is
      Header          : Header_Image := [others => 0];
      Expected_Image  : Formats.Head_Image;
      Attempted_Image : Formats.Head_Image;
      Required        : constant Natural := Encoded_Length (Batch_Length);
   begin
      Image := [Image'Range => 0];
      if not Structurally_Valid (Value) then
         Status := Invalid_Value;
         return;
      elsif Required = 0 or else Image'Length /= Required then
         Status := Invalid_Length;
         return;
      end if;

      Expected_Image := Formats.Encode_Head (Value.Expected_Head);
      Attempted_Image := Formats.Encode_Head (Value.Attempted_Head);
      Header (0 .. 7) := Magic;
      Put_U16 (Header, 8, Authority_Format_Version);
      Header (10) := Authority_Object_Kind;
      Header (11) := 0;
      Put_Identifier (Header, 12, Value.Expected_Head.Database_ID);
      Put_U64 (Header, 28, Interfaces.Unsigned_64 (Required));
      Put_U64 (Header, 36, Interfaces.Unsigned_64 (Batch_Length));
      Put_Identifier (Header, 48, Value.Transaction_ID);
      Put_U64 (Header, 64, Interfaces.Unsigned_64 (Value.Assigned_Sequence));
      Put_Identifier (Header, 72, Value.Batch_ID);
      Header (88 .. 223) := Expected_Image;
      Header (224 .. 359) := Attempted_Image;
      Put_U32 (Header, 44, Header_Checksum (Header));
      for Offset in Header_Index loop
         Image (Image'First + Offset) := Header (Offset);
      end loop;
      Status := Encoded;
   end Encode_Header;

   function Batch_First (Image : Byte_Array) return Positive
   is (Image'First + Authority_Header_Length);

   procedure Seal (Image : in out Byte_Array) is
      Checksum : constant Interfaces.Unsigned_32 :=
        Formats.CRC_32C (Formats.Byte_Array (Image (Image'First .. Image'Last - Authority_Trailer_Length)));
      Position : constant Positive := Image'Last - Authority_Trailer_Length + 1;
   begin
      for Offset in Natural range 0 .. 3 loop
         Image (Position + Offset) := Byte (Interfaces.Shift_Right (Checksum, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Seal;

   procedure Decode
     (Image             : Byte_Array;
      Expected_Database : Heads.Identifier;
      Value             : out Authority_Metadata;
      Batch_Start       : out Positive;
      Batch_Length      : out Natural;
      Status            : out Decode_Status)
   is
      Header            : Header_Image;
      Expected_Head     : Heads.Head_State;
      Attempted_Head    : Heads.Head_State;
      Expected_Status   : Formats.Decode_Status;
      Attempted_Status  : Formats.Decode_Status;
      Expected_Image    : Formats.Head_Image;
      Attempted_Image   : Formats.Head_Image;
      Wire_Total_Length : Interfaces.Unsigned_64;
      Wire_Batch_Length : Interfaces.Unsigned_64;
      Stored_Checksum   : Interfaces.Unsigned_32 := 0;
      Candidate         : Authority_Metadata;
   begin
      Value := Empty_Authority;
      Batch_Start := Positive'First;
      Batch_Length := 0;
      if Image'Length
        < Authority_Header_Length
          + Batch_Formats.Batch_Header_Length
          + Batch_Formats.Batch_Trailer_Length
          + Authority_Trailer_Length
      then
         Status := Invalid_Length;
         return;
      end if;
      for Offset in Header_Index loop
         Header (Offset) := Image (Image'First + Offset);
      end loop;
      Wire_Total_Length := Read_U64 (Header, 28);
      Wire_Batch_Length := Read_U64 (Header, 36);
      if Header (0 .. 7) /= Magic then
         Status := Invalid_Magic;
         return;
      elsif Read_U16 (Header, 8) /= Authority_Format_Version then
         Status := Unsupported_Version;
         return;
      elsif Header (10) /= Authority_Object_Kind then
         Status := Invalid_Object_Kind;
         return;
      elsif Header (11) /= 0 then
         Status := Invalid_Flags;
         return;
      elsif Read_Identifier (Header, 12) /= Expected_Database then
         Status := Wrong_Database;
         return;
      elsif Wire_Total_Length > Interfaces.Unsigned_64 (Natural'Last)
        or else Natural (Wire_Total_Length) /= Image'Length
        or else Wire_Batch_Length
                < Interfaces.Unsigned_64
                    (Batch_Formats.Batch_Header_Length + Batch_Formats.Batch_Trailer_Length)
        or else Wire_Batch_Length > Interfaces.Unsigned_64 (Natural'Last)
      then
         Status := Invalid_Length;
         return;
      end if;

      Batch_Length := Natural (Wire_Batch_Length);
      if Encoded_Length (Batch_Length) /= Image'Length then
         Batch_Length := 0;
         Status := Invalid_Length;
         return;
      elsif Read_U32 (Header, 44) /= Header_Checksum (Header) then
         Batch_Length := 0;
         Status := Header_Checksum_Failed;
         return;
      end if;

      for Offset in Natural range 0 .. 3 loop
         Stored_Checksum :=
           Interfaces.Shift_Left (Stored_Checksum, 8)
           or Interfaces.Unsigned_32 (Image (Image'Last - Authority_Trailer_Length + 1 + Offset));
      end loop;
      if Stored_Checksum
        /= Formats.CRC_32C (Formats.Byte_Array (Image (Image'First .. Image'Last - Authority_Trailer_Length)))
      then
         Batch_Length := 0;
         Status := Object_Checksum_Failed;
         return;
      end if;

      Expected_Image := Header (88 .. 223);
      Attempted_Image := Header (224 .. 359);
      Formats.Decode_Head (Expected_Image, Expected_Database, Expected_Head, Expected_Status);
      Formats.Decode_Head (Attempted_Image, Expected_Database, Attempted_Head, Attempted_Status);
      if Expected_Status /= Formats.Decoded or else Attempted_Status /= Formats.Decoded then
         Batch_Length := 0;
         Status := Invalid_Authority_State;
         return;
      end if;

      Candidate :=
        (Transaction_ID    => Read_Identifier (Header, 48),
         Assigned_Sequence => Heads.Commit_Sequence (Read_U64 (Header, 64)),
         Batch_ID          => Read_Identifier (Header, 72),
         Expected_Head     => Expected_Head,
         Attempted_Head    => Attempted_Head);
      if not Structurally_Valid (Candidate) then
         Batch_Length := 0;
         Status := Invalid_Authority_State;
         return;
      end if;
      Value := Candidate;
      Batch_Start := Image'First + Authority_Header_Length;
      Status := Decoded;
   end Decode;

   package body Reference is
      procedure Encode
        (Value  : Authority_Metadata;
         Batch  : Reference_Batch;
         Image  : out Reference_Image;
         Status : out Encode_Status) is
      begin
         Encode_Header (Value, Batch'Length, Image, Status);
         if Status = Encoded then
            for Offset in Natural range 0 .. Batch'Length - 1 loop
               Image (Batch_First (Image) + Offset) := Batch (Batch'First + Offset);
            end loop;
            Seal (Image);
         end if;
      end Encode;
   end Reference;

end Flyology.DB.Commit_Authority_Formats;
