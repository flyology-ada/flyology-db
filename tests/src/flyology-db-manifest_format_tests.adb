with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Flyology.DB.Manifest_Formats;
with Interfaces;

package body Flyology.DB.Manifest_Format_Tests is

   package Formats renames Flyology.DB.Formats;
   package Head renames Flyology.DB.Head_Policy;
   package Manifests renames Flyology.DB.Manifest_Formats;

   use type Formats.Byte_Array;
   use type Head.Identifier;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Manifests.Decode_Status;
   use type Manifests.Encode_Status;
   use type Manifests.Manifest;

   Fixture_Length : constant := 272;

   pragma
     Compile_Time_Error
       (Manifests.Family_Frame_Header_Length /= 4 + 4 + 8 + 8 + 2 + 2,
        "manifest family-frame width arithmetic changed");
   pragma
     Compile_Time_Error
       (Manifests.Max_Manifest_Image_Length /= 18_312, "manifest maximum image width changed");

   function ID (Last : Interfaces.Unsigned_8) return Head.Identifier is
      Result : Head.Identifier := [others => 0];
   begin
      Result (Result'Last) := Last;
      return Result;
   end ID;

   procedure Set_Name (Item : in out Manifests.Column_Family_Configuration; Data : Formats.Byte_Array) is
   begin
      if Data'Length > Manifests.Max_Family_Name_Bytes then
         raise Constraint_Error with "test family name exceeds manifest cap";
      end if;
      Item.Name_Length := Data'Length;
      Item.Name := [others => 0];
      if Data'Length > 0 then
         for Offset in Natural range 0 .. Data'Length - 1 loop
            Item.Name (Offset + 1) := Data (Data'First + Offset);
         end loop;
      end if;
   end Set_Name;

   function Default_Limits return Manifests.Database_Limits
   is ((Maximum_Column_Families           => 64,
        Maximum_Manifest_History          => 64,
        Maximum_Batch_History             => 64,
        Maximum_Transactions_Per_Batch    => 8,
        Maximum_Mutations_Per_Transaction => 64,
        Maximum_Mutations_Per_Batch       => 64,
        Maximum_Live_Entries              => 256,
        Maximum_Transaction_Payload_Bytes => 2 * 1_024 * 1_024,
        Maximum_Batch_Payload_Bytes       => 16 * 1_024 * 1_024,
        Maximum_Live_State_Bytes          => 64 * 1_024 * 1_024));

   function Root_Manifest return Manifests.Manifest is
      Result : Manifests.Manifest := Manifests.Empty_Manifest;
   begin
      Result.Database_ID := ID (1);
      Result.Manifest_ID := ID (3);
      Result.Publication_Transition_ID := ID (4);
      Result.Publication_Transition_Number := 1;
      Result.Writer_Epoch := 1;
      Result.Registry_Revision := 1;
      Result.Family_Total := 2;
      Result.Limits := Default_Limits;
      Result.Families (1).ID := 1;
      Result.Families (1).Max_Key_Bytes := 4 * 1_024;
      Result.Families (1).Max_Value_Bytes := 1_024 * 1_024;
      Set_Name
        (Result.Families (1),
         [Character'Pos ('a'),
          Character'Pos ('c'),
          Character'Pos ('c'),
          Character'Pos ('o'),
          Character'Pos ('u'),
          Character'Pos ('n'),
          Character'Pos ('t'),
          Character'Pos ('s')]);
      Result.Families (2).ID := 2;
      Result.Families (2).Max_Key_Bytes := 20;
      Result.Families (2).Max_Value_Bytes := 400;
      Set_Name
        (Result.Families (2),
         [Character'Pos ('a'),
          Character'Pos ('u'),
          Character'Pos ('d'),
          Character'Pos ('i'),
          Character'Pos ('t'),
          Character'Pos ('-'),
          16#CF#,
          16#80#]);
      return Result;
   end Root_Manifest;

   Fixture : constant Manifests.Manifest := Root_Manifest;

   --  Frozen from an independent Ruby big-endian/CRC-32C encoder. It covers
   --  two family profiles and one canonical two-byte UTF-8 sequence.
   Golden : constant Formats.Byte_Array (0 .. Fixture_Length - 1) :=
     [16#46#,
      16#4C#,
      16#59#,
      16#43#,
      16#46#,
      16#4D#,
      16#30#,
      16#31#,
      16#00#,
      16#01#,
      16#03#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#C4#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#48#,
      16#BF#,
      16#15#,
      16#3F#,
      16#5D#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#03#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#04#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#02#,
      16#00#,
      16#00#,
      16#00#,
      16#40#,
      16#00#,
      16#00#,
      16#00#,
      16#40#,
      16#00#,
      16#00#,
      16#00#,
      16#40#,
      16#00#,
      16#00#,
      16#00#,
      16#08#,
      16#00#,
      16#00#,
      16#00#,
      16#40#,
      16#00#,
      16#00#,
      16#00#,
      16#40#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#20#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#04#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#10#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#10#,
      16#00#,
      16#00#,
      16#00#,
      16#08#,
      16#00#,
      16#00#,
      16#61#,
      16#63#,
      16#63#,
      16#6F#,
      16#75#,
      16#6E#,
      16#74#,
      16#73#,
      16#00#,
      16#00#,
      16#00#,
      16#02#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#14#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#90#,
      16#00#,
      16#08#,
      16#00#,
      16#00#,
      16#61#,
      16#75#,
      16#64#,
      16#69#,
      16#74#,
      16#2D#,
      16#CF#,
      16#80#,
      16#64#,
      16#0E#,
      16#E8#,
      16#46#];

   procedure Put_U16
     (Item     : in out Manifests.Manifest_Image;
      Position : Manifests.Manifest_Image_Index;
      Value    : Interfaces.Unsigned_16) is
   begin
      Item (Position) := Formats.Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);
      Item (Position + 1) := Formats.Byte (Value and 16#FF#);
   end Put_U16;

   procedure Put_U32
     (Item     : in out Manifests.Manifest_Image;
      Position : Manifests.Manifest_Image_Index;
      Value    : Interfaces.Unsigned_32) is
   begin
      for Offset in Natural range 0 .. 3 loop
         Item (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64
     (Item     : in out Manifests.Manifest_Image;
      Position : Manifests.Manifest_Image_Index;
      Value    : Interfaces.Unsigned_64) is
   begin
      for Offset in Natural range 0 .. 7 loop
         Item (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   procedure Repair_Checksums (Item : in out Manifests.Manifest_Image; Length : Natural) is
   begin
      Item (40 .. 43) := [others => 0];
      Put_U32 (Item, 40, Formats.CRC_32C (Item (0 .. Manifests.Manifest_Header_Length - 1)));
      Put_U32 (Item, Length - 4, Formats.CRC_32C (Item (0 .. Length - 5)));
   end Repair_Checksums;

   procedure Expect_Decode
     (Item     : Formats.Byte_Array;
      Limits   : Manifests.Reader_Caps;
      Expected : Manifests.Decode_Status;
      Context  : String)
   is
      Value  : Manifests.Manifest;
      Status : Manifests.Decode_Status;
   begin
      Manifests.Decode_Manifest (Item, Fixture.Database_ID, Limits, Value, Status);
      if Status /= Expected then
         raise Program_Error with Context & ": " & Manifests.Decode_Status'Image (Status);
      elsif Status /= Manifests.Decoded and then Value /= Manifests.Empty_Manifest then
         raise Program_Error with Context & ": partial output";
      end if;
   end Expect_Decode;

   procedure Expect_Default_Decode
     (Item : Formats.Byte_Array; Expected : Manifests.Decode_Status; Context : String) is
   begin
      Expect_Decode (Item, Manifests.Default_Reader_Caps, Expected, Context);
   end Expect_Default_Decode;

   procedure Encode_Checked
     (Value : Manifests.Manifest; Image : out Manifests.Manifest_Image; Length : out Natural)
   is
      Status : Manifests.Encode_Status;
   begin
      Manifests.Encode_Manifest (Value, Image, Length, Status);
      if Status /= Manifests.Encoded then
         raise Program_Error with "valid manifest did not encode";
      end if;
   end Encode_Checked;

   procedure Test_Golden_And_Extent is
      Image  : Manifests.Manifest_Image;
      Length : Natural;
      Value  : Manifests.Manifest;
      Status : Manifests.Decode_Status;
   begin
      Encode_Checked (Fixture, Image, Length);
      if Length /= Fixture_Length or else Image (0 .. Length - 1) /= Golden then
         raise Program_Error with "manifest differs from independent 272-byte golden";
      end if;
      Manifests.Decode_Manifest (Golden, Fixture.Database_ID, Manifests.Default_Reader_Caps, Value, Status);
      if Status /= Manifests.Decoded or else Value /= Fixture then
         raise Program_Error with "golden manifest did not round-trip";
      end if;
      for Size in Natural range 0 .. Fixture_Length - 1 loop
         declare
            Short : Formats.Byte_Array (1 .. Size);
         begin
            if Size > 0 then
               for Offset in Natural range 0 .. Size - 1 loop
                  Short (Offset + 1) := Golden (Offset);
               end loop;
            end if;
            Expect_Default_Decode (Short, Manifests.Invalid_Length, "truncated manifest accepted");
         end;
      end loop;
      declare
         Long : Formats.Byte_Array (0 .. Fixture_Length) := [others => 0];
      begin
         Long (0 .. Fixture_Length - 1) := Golden;
         Expect_Default_Decode (Long, Manifests.Invalid_Length, "trailing manifest byte accepted");
      end;
   end Test_Golden_And_Extent;

   procedure Test_Envelope_And_Semantics is
      Corrupt             : Manifests.Manifest_Image := [others => 0];
      type Position_List is array (Positive range <>) of Natural;
      Required_ID_Offsets : constant Position_List := [44, 100];
   begin
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (0) := Corrupt (0) xor 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Magic, "magic");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (9) := 2;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Unsupported_Version, "version");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (10) := 2;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Object_Kind, "kind");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (11) := 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Flags, "flags");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (27) := 9;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Wrong_Database, "database");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (31) := Corrupt (31) xor 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Length, "header extent");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (40) := Corrupt (40) xor 1;
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Header_Checksum_Failed, "header checksum");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (250) := Corrupt (250) xor 1;
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Object_Checksum_Failed, "object checksum");

      for First of Required_ID_Offsets loop
         Corrupt (0 .. Fixture_Length - 1) := Golden;
         Corrupt (First .. First + 15) := [others => 0];
         Repair_Checksums (Corrupt, Fixture_Length);
         Expect_Default_Decode
           (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Manifest_State, "zero required ID");
      end loop;
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 116, 2);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Manifest_State, "root publication ordinal");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 132, 2);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Manifest_State, "root revision");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (75) := 7;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Manifest_State,
         "root carried predecessor manifest");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (91) := 7;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Manifest_State,
         "root carried expected HEAD ID");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 124, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Manifest_State, "zero root epoch");
   end Test_Envelope_And_Semantics;

   procedure Test_Names_And_Families is
      Corrupt         : Manifests.Manifest_Image := [others => 0];
      Changed         : Manifests.Manifest;
      Image           : Manifests.Manifest_Image;
      Length          : Natural;
      type Byte_List is array (Positive range <>) of Formats.Byte;
      Invalid_Leaders : constant Byte_List := [16#00#, 16#C0#, 16#F5#];
   begin
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U16 (Corrupt, 220, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Name, "empty family name");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 196, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Family, "zero family ID");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 200, 1);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Family, "family flags");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U16 (Corrupt, 222, 1);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Family, "family reserved field");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 232, 1);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Family, "duplicate family ID");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 232, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Family, "unordered family ID");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (260 .. 267) := Corrupt (224 .. 231);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Duplicate_Name, "duplicate name");

      for Invalid_First of Invalid_Leaders loop
         Corrupt (0 .. Fixture_Length - 1) := Golden;
         Corrupt (224) := Invalid_First;
         Repair_Checksums (Corrupt, Fixture_Length);
         Expect_Default_Decode
           (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Name, "invalid UTF-8 leading byte");
      end loop;
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (224 .. 226) := [16#ED#, 16#A0#, 16#80#];
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Name, "UTF-8 surrogate");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (224 .. 227) := [16#F4#, 16#90#, 16#80#, 16#80#];
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Name, "UTF-8 above U+10FFFF");

      --  Exact UTF-8 bytes are identity; canonical equivalents are not normalized.
      Changed := Fixture;
      Set_Name (Changed.Families (1), [16#C3#, 16#A9#]);
      Set_Name (Changed.Families (2), [Character'Pos ('e'), 16#CC#, 16#81#]);
      Encode_Checked (Changed, Image, Length);
      Expect_Default_Decode
        (Image (0 .. Length - 1), Manifests.Decoded, "canonical UTF-8 spellings collapsed");

      Changed := Fixture;
      Changed.Families (1).Name (Changed.Families (1).Name_Length + 1) := 1;
      if Manifests.Structurally_Valid (Changed) then
         raise Program_Error with "nonzero family-name tail accepted";
      end if;
      declare
         Encode_Result : Manifests.Encode_Status;
      begin
         Manifests.Encode_Manifest (Changed, Image, Length, Encode_Result);
         if Encode_Result /= Manifests.Invalid_Value or else Length /= 0 then
            raise Program_Error with "noncanonical family record encoded";
         end if;
      end;
   end Test_Names_And_Families;

   procedure Test_Limits_And_Caps is
      Corrupt : Manifests.Manifest_Image := [others => 0];
      Exact   : constant Manifests.Reader_Caps :=
        (Families      => 2,
         Name_Bytes    => 8,
         Payload_Bytes => 72,
         Key_Bytes     => 4 * 1_024,
         Value_Bytes   => 1_024 * 1_024);
   begin
      Expect_Decode (Golden, Exact, Manifests.Decoded, "exact caps");
      Expect_Decode (Golden, (Exact with delta Families => 1), Manifests.Limit_Exceeded, "family cap");
      Expect_Decode (Golden, (Exact with delta Name_Bytes => 7), Manifests.Limit_Exceeded, "name cap");
      Expect_Decode (Golden, (Exact with delta Payload_Bytes => 71), Manifests.Limit_Exceeded, "payload cap");
      Expect_Decode
        (Golden, (Exact with delta Key_Bytes => 4 * 1_024 - 1), Manifests.Limit_Exceeded, "key cap");
      Expect_Decode
        (Golden, (Exact with delta Value_Bytes => 1_024 * 1_024 - 1), Manifests.Limit_Exceeded, "value cap");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U16 (Corrupt, 220, Manifests.Max_Family_Name_Bytes + 1);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Limit_Exceeded, "name width one-over");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 140, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Manifest_State, "zero family count accepted");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 140, Manifests.Max_Families + 1);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Limit_Exceeded, "family wire one-over");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 144, Manifests.Max_Families + 1);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Limit_Exceeded, "configured family one-over");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 204, Interfaces.Unsigned_64'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Manifest_State,
         "default U64 ceiling converted unsafely");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 204, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Family, "zero max key");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 160, 65);
      Put_U32 (Corrupt, 164, 65);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Decoded, "runtime-sized mutation counts");

      declare
         type Offset_List is array (Positive range <>) of Natural;
         Count_Offsets : constant Offset_List := [144, 148, 152, 156];
      begin
         for Offset of Count_Offsets loop
            Corrupt (0 .. Fixture_Length - 1) := Golden;
            Put_U32 (Corrupt, Offset, Interfaces.Unsigned_32'Last);
            Repair_Checksums (Corrupt, Fixture_Length);
            Expect_Default_Decode
              (Corrupt (0 .. Fixture_Length - 1),
               Manifests.Limit_Exceeded,
               "U32 maximum configured count was not a resource limit");
            Corrupt (0 .. Fixture_Length - 1) := Golden;
            Put_U32 (Corrupt, Offset, 0);
            Repair_Checksums (Corrupt, Fixture_Length);
            Expect_Default_Decode
              (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Limits, "zero configured count accepted");
         end loop;
      end;
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 160, Interfaces.Unsigned_32'Last);
      Put_U32 (Corrupt, 164, Interfaces.Unsigned_32'Last);
      Put_U32 (Corrupt, 168, Interfaces.Unsigned_32'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Decoded,
         "runtime-sized mutation/live counts were narrowed by the codec");
      declare
         type Offset_List is array (Positive range <>) of Natural;
         Dynamic_Count_Offsets : constant Offset_List := [160, 164, 168];
      begin
         for Offset of Dynamic_Count_Offsets loop
            Corrupt (0 .. Fixture_Length - 1) := Golden;
            Put_U32 (Corrupt, Offset, 0);
            Repair_Checksums (Corrupt, Fixture_Length);
            Expect_Default_Decode
              (Corrupt (0 .. Fixture_Length - 1),
               Manifests.Invalid_Limits,
               "zero dynamic configured count accepted");
         end loop;
      end;

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 160, 64);
      Put_U32 (Corrupt, 164, 63);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Limits,
         "per-transaction mutation cap exceeded batch cap");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 156, 16);
      Put_U32 (Corrupt, 160, 16);
      Put_U32 (Corrupt, 164, 16);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Decoded,
         "transaction count equal to batch mutation count rejected");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 156, 16);
      Put_U32 (Corrupt, 160, 15);
      Put_U32 (Corrupt, 164, 15);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Limits,
         "transaction count one over batch mutation count accepted");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 172, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Limits,
         "zero transaction payload budget accepted");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 180, 1);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Limits,
         "batch payload below transaction payload accepted");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 188, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Limits, "zero live-state budget accepted");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 212, 0);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode (Corrupt (0 .. Fixture_Length - 1), Manifests.Invalid_Family, "zero max value");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 204, 1_500_000);
      Put_U64 (Corrupt, 212, 1_500_000);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Manifest_State,
         "family logical payload exceeded transaction budget");
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 32, Interfaces.Unsigned_64'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Manifests.Invalid_Length,
         "U64 payload extent converted unsafely");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (40) := Corrupt (40) xor 1;
      Expect_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         (Families => 0, others => <>),
         Manifests.Header_Checksum_Failed,
         "cap hid corrupt header");
   end Test_Limits_And_Caps;

   procedure Test_Maximum_Instance is
      Maximum : Manifests.Manifest := Manifests.Empty_Manifest;
      Image   : Manifests.Manifest_Image;
      Length  : Natural;
      Value   : Manifests.Manifest;
      Status  : Manifests.Decode_Status;
   begin
      Maximum.Database_ID := ID (10);
      Maximum.Manifest_ID := ID (11);
      Maximum.Publication_Transition_ID := ID (12);
      Maximum.Publication_Transition_Number := 1;
      Maximum.Writer_Epoch := 1;
      Maximum.Registry_Revision := 1;
      Maximum.Family_Total := Manifests.Max_Families;
      Maximum.Limits := Default_Limits;
      Maximum.Limits.Maximum_Transactions_Per_Batch := Manifests.Max_Batch_Transactions;
      Maximum.Limits.Maximum_Live_Entries := Manifests.Max_Live_Entries;
      Maximum.Limits.Maximum_Transaction_Payload_Bytes := Interfaces.Unsigned_64'Last;
      Maximum.Limits.Maximum_Batch_Payload_Bytes := Interfaces.Unsigned_64'Last;
      Maximum.Limits.Maximum_Live_State_Bytes := Interfaces.Unsigned_64'Last;
      for Index in Manifests.Family_Slot loop
         Maximum.Families (Index).ID := Interfaces.Unsigned_32 (Index);
         Maximum.Families (Index).Max_Key_Bytes := 1;
         Maximum.Families (Index).Max_Value_Bytes := 1;
         Maximum.Families (Index).Name_Length := Manifests.Max_Family_Name_Bytes;
         Maximum.Families (Index).Name := [others => Character'Pos ('a')];
         Maximum.Families (Index).Name (1) := Formats.Byte (Index);
         if Index = 1 then
            Maximum.Families (Index).Name (1) := Character'Pos ('A');
         end if;
      end loop;
      Encode_Checked (Maximum, Image, Length);
      if Length /= Manifests.Max_Manifest_Image_Length then
         raise Program_Error with "maximum manifest did not reach 18,312 bytes";
      end if;
      Manifests.Decode_Manifest (Image, Maximum.Database_ID, Manifests.Default_Reader_Caps, Value, Status);
      if Status /= Manifests.Decoded or else Value /= Maximum then
         raise Program_Error with "maximum manifest did not round-trip";
      end if;
      declare
         One_Over : Formats.Byte_Array (0 .. Manifests.Max_Manifest_Image_Length) := [others => 0];
      begin
         One_Over (0 .. Image'Last) := Image;
         Expect_Decode
           (One_Over,
            Manifests.Default_Reader_Caps,
            Manifests.Limit_Exceeded,
            "one-over object extent was not a resource limit");
      end;
   end Test_Maximum_Instance;

   procedure Test_Publication_And_Predecessor is
      Previous      : constant Manifests.Manifest := Fixture;
      Current       : Manifests.Manifest := Fixture;
      Image         : Manifests.Manifest_Image;
      Corrupt       : Manifests.Manifest_Image;
      Length        : Natural;
      Decoded_Value : Manifests.Manifest;
      Decode_Result : Manifests.Decode_Status;
      Root_Head     : constant Head.Head_State :=
        (Database_ID            => Fixture.Database_ID,
         Version                => Manifests.Manifest_Head_Format,
         Epoch                  => 1,
         Highest_Visible        => 0,
         Latest_Batch           => Head.Zero_Identifier,
         Latest_Manifest        => Fixture.Manifest_ID,
         Transition_ID          => Fixture.Publication_Transition_ID,
         Predecessor_Transition => Fixture.Expected_Transition_ID,
         Transition_Number      => 1);
   begin
      if not Manifests.Manifest_Head_Structurally_Valid (Root_Head)
        or else not Manifests.Valid_Root_Publication (Root_Head, Fixture)
        or else not Manifests.Referenced_By (Fixture, Root_Head)
      then
         raise Program_Error with "exact root HEAD binding rejected";
      end if;
      for Dimension in Positive range 1 .. 10 loop
         declare
            Wrong : Head.Head_State := Root_Head;
         begin
            case Dimension is
               when 1  =>
                  Wrong.Database_ID := Head.Zero_Identifier;

               when 2  =>
                  Wrong.Version := Head.Legacy_Format;

               when 3  =>
                  Wrong.Epoch := 0;

               when 4  =>
                  Wrong.Latest_Manifest := Head.Zero_Identifier;

               when 5  =>
                  Wrong.Transition_ID := Head.Zero_Identifier;

               when 6  =>
                  Wrong.Latest_Batch := ID (99);

               when 7  =>
                  Wrong.Epoch := 2;

               when 8  =>
                  Wrong.Predecessor_Transition := ID (99);

               when 9  =>
                  Wrong.Transition_Number := 2;
                  Wrong.Predecessor_Transition := Head.Zero_Identifier;

               when 10 =>
                  Wrong.Transition_Number := 2;
                  Wrong.Predecessor_Transition := Root_Head.Transition_ID;
                  Wrong.Transition_ID := ID (98);
                  Wrong.Highest_Visible := 1;
            end case;
            if Manifests.Manifest_Head_Structurally_Valid (Wrong) then
               raise Program_Error with "unreachable manifest HEAD-v2 shape accepted";
            end if;
         end;
      end loop;
      declare
         Later : Head.Head_State := Root_Head;
      begin
         Later.Transition_Number := 2;
         Later.Predecessor_Transition := Root_Head.Transition_ID;
         Later.Transition_ID := ID (98);
         Later.Highest_Visible := 1;
         Later.Latest_Batch := ID (97);
         if not Manifests.Manifest_Head_Structurally_Valid (Later) then
            raise Program_Error with "reachable committed manifest HEAD-v2 shape rejected";
         end if;
      end;
      for Dimension in Positive range 1 .. 9 loop
         declare
            Wrong : Head.Head_State := Root_Head;
         begin
            case Dimension is
               when 1 =>
                  Wrong.Database_ID := ID (99);

               when 2 =>
                  Wrong.Version := Head.Legacy_Format;

               when 3 =>
                  Wrong.Epoch := 2;

               when 4 =>
                  Wrong.Highest_Visible := 1;

               when 5 =>
                  Wrong.Latest_Manifest := ID (99);

               when 6 =>
                  Wrong.Transition_ID := ID (99);

               when 7 =>
                  Wrong.Latest_Batch := ID (99);

               when 8 =>
                  Wrong.Transition_Number := 2;

               when 9 =>
                  Wrong.Predecessor_Transition := ID (99);
            end case;
            if Manifests.Valid_Root_Publication (Wrong, Fixture) then
               raise Program_Error with "root manifest HEAD mismatch accepted";
            end if;
         end;
      end loop;

      Current.Manifest_ID := ID (5);
      Current.Previous_Manifest_ID := Previous.Manifest_ID;
      Current.Expected_Transition_ID := Previous.Publication_Transition_ID;
      Current.Expected_Transition_Number := Previous.Publication_Transition_Number;
      Current.Publication_Transition_ID := ID (6);
      Current.Publication_Transition_Number := 2;
      Current.Registry_Revision := 2;
      Current.Family_Total := 3;
      Current.Families (3).ID := 3;
      Current.Families (3).Max_Key_Bytes := 20;
      Current.Families (3).Max_Value_Bytes := 400;
      Set_Name (Current.Families (3), [Character'Pos ('n'), Character'Pos ('e'), Character'Pos ('w')]);
      if not Manifests.Valid_Predecessor (Current, Previous) then
         raise Program_Error with "direct append-only manifest successor rejected";
      end if;
      Current.Families (1).Name (Current.Families (1).Name_Length + 1) := 1;
      if Manifests.Valid_Predecessor (Current, Previous) then
         raise Program_Error with "noncanonical existing family accepted in predecessor chain";
      end if;
      Current.Families (1).Name (Current.Families (1).Name_Length + 1) := 0;
      Encode_Checked (Current, Image, Length);
      Manifests.Decode_Manifest
        (Image (0 .. Length - 1),
         Current.Database_ID,
         Manifests.Default_Reader_Caps,
         Decoded_Value,
         Decode_Result);
      if Decode_Result /= Manifests.Decoded or else Decoded_Value /= Current then
         raise Program_Error with "successor manifest did not round-trip structurally";
      end if;
      Corrupt := Image;
      Corrupt (60 .. 75) := [others => 0];
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1), Manifests.Invalid_Manifest_State, "zero predecessor ID");
      Corrupt := Image;
      Corrupt (76 .. 91) := [others => 0];
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1), Manifests.Invalid_Manifest_State, "zero expected HEAD ID");
      Corrupt := Image;
      Put_U64 (Corrupt, 92, 0);
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1), Manifests.Invalid_Manifest_State, "zero expected HEAD number");
      Corrupt := Image;
      Put_U64 (Corrupt, 92, Interfaces.Unsigned_64'Last);
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1),
         Manifests.Invalid_Manifest_State,
         "maximum expected HEAD number overflowed");
      Corrupt := Image;
      Put_U64 (Corrupt, 116, Current.Expected_Transition_Number);
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1),
         Manifests.Invalid_Manifest_State,
         "publication HEAD number did not advance");
      Corrupt := Image;
      Corrupt (100 .. 115) := Corrupt (76 .. 91);
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1),
         Manifests.Invalid_Manifest_State,
         "publication HEAD ID reused expected ID");
      Corrupt := Image;
      Put_U64 (Corrupt, 124, 0);
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1), Manifests.Invalid_Manifest_State, "zero successor epoch");
      Corrupt := Image;
      Put_U64 (Corrupt, 124, 100);
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1),
         Manifests.Invalid_Manifest_State,
         "successor epoch exceeded expected HEAD ordinal");
      Corrupt := Image;
      Put_U64 (Corrupt, 132, 1);
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1), Manifests.Invalid_Manifest_State, "successor revision did not advance");
      Corrupt := Image;
      Corrupt (44 .. 59) := Corrupt (60 .. 75);
      Repair_Checksums (Corrupt, Length);
      Expect_Default_Decode
        (Corrupt (0 .. Length - 1),
         Manifests.Invalid_Manifest_State,
         "successor reused predecessor manifest ID");
      declare
         Candidate : Head.Head_State := Root_Head;
      begin
         Candidate.Latest_Manifest := Current.Manifest_ID;
         Candidate.Transition_ID := Current.Publication_Transition_ID;
         Candidate.Predecessor_Transition := Current.Expected_Transition_ID;
         Candidate.Transition_Number := 2;
         if not Manifests.Valid_Publication (Root_Head, Candidate, Current) then
            raise Program_Error with "exact successor HEAD transition rejected";
         end if;
         for Dimension in Positive range 1 .. 9 loop
            declare
               Wrong : Head.Head_State := Candidate;
            begin
               case Dimension is
                  when 1 =>
                     Wrong.Database_ID := ID (99);

                  when 2 =>
                     Wrong.Version := Head.Legacy_Format;

                  when 3 =>
                     Wrong.Epoch := 2;

                  when 4 =>
                     Wrong.Highest_Visible := 1;

                  when 5 =>
                     Wrong.Latest_Batch := ID (99);

                  when 6 =>
                     Wrong.Latest_Manifest := ID (99);

                  when 7 =>
                     Wrong.Transition_ID := ID (99);

                  when 8 =>
                     Wrong.Predecessor_Transition := ID (99);

                  when 9 =>
                     Wrong.Transition_Number := 3;
               end case;
               if Manifests.Valid_Publication (Root_Head, Wrong, Current) then
                  raise Program_Error with "successor HEAD mismatch accepted";
               end if;
            end;
         end loop;

         if not Manifests.Referenced_By (Current, Candidate) then
            raise Program_Error with "exact successor recovery binding rejected";
         end if;
         declare
            Wrong : Head.Head_State := Candidate;
         begin
            Wrong.Predecessor_Transition := ID (99);
            if Manifests.Referenced_By (Current, Wrong) then
               raise Program_Error with "exact reference accepted wrong expected predecessor";
            end if;
         end;
         Candidate.Transition_Number := 3;
         Candidate.Transition_ID := ID (9);
         if Manifests.Referenced_By (Current, Candidate) then
            raise Program_Error with "immediate reference accepted stale expected predecessor";
         end if;
         Candidate.Predecessor_Transition := Current.Publication_Transition_ID;
         if not Manifests.Referenced_By (Current, Candidate) then
            raise Program_Error with "immediate successor recovery binding rejected";
         end if;
         Candidate.Predecessor_Transition := ID (99);
         if Manifests.Referenced_By (Current, Candidate) then
            raise Program_Error with "immediate reference accepted wrong publication predecessor";
         end if;
         Candidate.Predecessor_Transition := Current.Publication_Transition_ID;
         Candidate.Transition_ID := Current.Publication_Transition_ID;
         if Manifests.Referenced_By (Current, Candidate) then
            raise Program_Error with "immediate HEAD transition reused manifest publication ID";
         end if;
         Candidate.Transition_Number := 4;
         Candidate.Predecessor_Transition := ID (9);
         if not Manifests.Referenced_By (Current, Candidate) then
            raise Program_Error with "historical HEAD transition-ID recurrence rejected";
         end if;
         Candidate.Epoch := 4;
         if Manifests.Referenced_By (Current, Candidate) then
            raise Program_Error with "recovery HEAD epoch gap exceeded ordinal gap";
         end if;
      end;
      Current.Families (1).Max_Value_Bytes := 401;
      if Manifests.Valid_Predecessor (Current, Previous) then
         raise Program_Error with "existing family configuration changed";
      end if;
      Current.Families (1) := Previous.Families (1);
      Current.Expected_Transition_Number := 2;
      Current.Publication_Transition_Number := 3;
      if Manifests.Valid_Predecessor (Current, Previous) then
         raise Program_Error with "immediate transition reused predecessor ID";
      end if;
      Current.Expected_Transition_ID := ID (8);
      if not Manifests.Valid_Predecessor (Current, Previous) then
         raise Program_Error with "interposed metadata transition rejected";
      end if;
      Current.Expected_Transition_Number := 3;
      Current.Publication_Transition_Number := 4;
      Current.Expected_Transition_ID := Previous.Publication_Transition_ID;
      if not Manifests.Valid_Predecessor (Current, Previous) then
         raise Program_Error with "historical transition-ID recurrence rejected";
      end if;
      Current.Writer_Epoch := 4;
      if Manifests.Valid_Predecessor (Current, Previous) then
         raise Program_Error with "epoch gap exceeded ordinal gap";
      end if;
   end Test_Publication_And_Predecessor;

   procedure Run is
   begin
      Test_Golden_And_Extent;
      Test_Envelope_And_Semantics;
      Test_Names_And_Families;
      Test_Limits_And_Caps;
      Test_Maximum_Instance;
      Test_Publication_And_Predecessor;
   end Run;

end Flyology.DB.Manifest_Format_Tests;
