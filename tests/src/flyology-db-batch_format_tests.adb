with Flyology.DB.Batch_Formats;
with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Interfaces;

package body Flyology.DB.Batch_Format_Tests is

   package Batches renames Flyology.DB.Batch_Formats;
   package Formats renames Flyology.DB.Formats;
   package Head renames Flyology.DB.Head_Policy;

   use type Batches.Commit_Batch;
   use type Batches.Decode_Status;
   use type Batches.Encode_Status;
   use type Batches.Mutation_Kind;
   use type Formats.Byte_Array;
   use type Head.Identifier;
   use type Head.Transition_Ordinal;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  Independently generated golden-batch length. It is derived from the
   --  frozen v1 headers plus this fixture's exact frames/payload and changes
   --  only with an intentional fixture or wire-format revision.
   Fixture_Length : constant := 223;

   function ID (Last : Interfaces.Unsigned_8) return Head.Identifier is
      Result : Head.Identifier := [others => 0];
   begin
      Result (Result'Last) := Last;
      return Result;
   end ID;

   function Minimal_Batch return Batches.Commit_Batch is
      Result : Batches.Commit_Batch := Batches.Empty_Batch;
   begin
      Result.Database_ID := ID (1);
      Result.Epoch := 1;
      Result.Batch_ID := ID (3);
      Result.Expected_Transition_ID := ID (2);
      Result.Expected_Transition_Number := 1;
      Result.Publication_Transition_ID := ID (4);
      Result.Publication_Transition_Number := 2;
      Result.First_Sequence := 1;
      Result.Last_Sequence := 1;
      Result.Transaction_Total := 1;
      Result.Mutation_Total := 2;
      Result.Transactions (1).Transaction_ID := ID (5);
      Result.Transactions (1).Sequence := 1;
      Result.Transactions (1).First_Mutation := 1;
      Result.Transactions (1).Mutations := 2;
      Result.Mutations (1).Column_Family := 1;
      Result.Mutations (1).Operation := Batches.Put;
      Result.Mutations (1).Key_Size := 2;
      Result.Mutations (1).Key (1 .. 2) := [16#00#, 16#FF#];
      Result.Mutations (1).Value_Size := 0;
      Result.Mutations (2).Column_Family := 2;
      Result.Mutations (2).Operation := Batches.Delete;
      Result.Mutations (2).Key_Size := 1;
      Result.Mutations (2).Key (1) := 16#80#;
      Result.Mutations (2).Value_Size := 0;
      return Result;
   end Minimal_Batch;

   --  Canonical two-mutation batch and its matching HEAD form one compatibility
   --  fixture: root counters start at one and publication advances to two.
   --  These are golden-test identities, not product defaults.
   Fixture : constant Batches.Commit_Batch := Minimal_Batch;

   Referencing_Head : constant Head.Head_State :=
     (Database_ID            => ID (1),
      Version                => Head.Current_Format,
      Epoch                  => 1,
      Highest_Visible        => 1,
      Latest_Batch           => ID (3),
      Latest_Manifest        => ID (7),
      Transition_ID          => ID (4),
      Predecessor_Transition => ID (2),
      Transition_Number      => 2);

   --  Frozen independently from the Ada encoder. It exercises empty Put values,
   --  a zero byte in a key, a high-bit byte, Delete, and two column families.
   Golden : constant Formats.Byte_Array (0 .. Fixture_Length - 1) :=
     [16#46#,
      16#4C#,
      16#59#,
      16#42#,
      16#41#,
      16#54#,
      16#43#,
      16#31#,
      16#00#,
      16#01#,
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
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#9C#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#3F#,
      16#69#,
      16#DB#,
      16#B5#,
      16#EB#,
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
      16#02#,
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
      16#02#,
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
      16#01#,
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
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#05#,
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
      16#1F#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#02#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#FF#,
      16#00#,
      16#00#,
      16#00#,
      16#02#,
      16#02#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#01#,
      16#00#,
      16#00#,
      16#00#,
      16#00#,
      16#80#,
      16#73#,
      16#F3#,
      16#4A#,
      16#66#];

   function Frozen_Golden return Byte_Array is
   begin
      return Result : Byte_Array (1 .. Golden'Length) do
         for Offset in Natural range 0 .. Golden'Length - 1 loop
            Result (Offset + 1) := Byte (Golden (Golden'First + Offset));
         end loop;
      end return;
   end Frozen_Golden;

   procedure Put_U32
     (Item : in out Batches.Batch_Image; Position : Batches.Batch_Image_Index; Value : Interfaces.Unsigned_32)
   is
   begin
      for Offset in Natural range 0 .. 3 loop
         Item (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64
     (Item : in out Batches.Batch_Image; Position : Batches.Batch_Image_Index; Value : Interfaces.Unsigned_64)
   is
   begin
      for Offset in Natural range 0 .. 7 loop
         Item (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   procedure Repair_Checksums (Item : in out Batches.Batch_Image; Length : Natural) is
   begin
      Item (40 .. 43) := [others => 0];
      Put_U32 (Item, 40, Formats.CRC_32C (Item (0 .. Batches.Batch_Header_Length - 1)));
      Put_U32 (Item, Length - 4, Formats.CRC_32C (Item (0 .. Length - 5)));
   end Repair_Checksums;

   procedure Expect_Decode
     (Item          : Formats.Byte_Array;
      Observed_Head : Head.Head_State;
      Limits        : Batches.Reader_Caps;
      Expected      : Batches.Decode_Status;
      Context       : String)
   is
      Value  : Batches.Commit_Batch;
      Status : Batches.Decode_Status;
   begin
      Batches.Decode_Latest_Batch (Item, Fixture.Database_ID, Observed_Head, Limits, Value, Status);
      if Status /= Expected then
         raise Program_Error with Context & ": " & Batches.Decode_Status'Image (Status);
      elsif Status /= Batches.Decoded and then Value /= Batches.Empty_Batch then
         raise Program_Error with Context & ": decode failure returned partial output";
      end if;
   end Expect_Decode;

   procedure Expect_Default_Decode
     (Item : Formats.Byte_Array; Expected : Batches.Decode_Status; Context : String) is
   begin
      Expect_Decode (Item, Referencing_Head, Batches.Default_Reader_Caps, Expected, Context);
   end Expect_Default_Decode;

   procedure Encode_Checked
     (Value : Batches.Commit_Batch; Image : out Batches.Batch_Image; Length : out Natural)
   is
      Status : Batches.Encode_Status;
   begin
      Batches.Encode_Batch (Value, Image, Length, Status);
      if Status /= Batches.Encoded then
         raise Program_Error with "valid test batch did not encode: " & Batches.Encode_Status'Image (Status);
      end if;
   end Encode_Checked;

   procedure Test_Golden_And_Extent is
      Image  : Batches.Batch_Image;
      Length : Natural;
      Value  : Batches.Commit_Batch;
      Status : Batches.Decode_Status;
   begin
      if not Batches.Structurally_Valid (Fixture) then
         raise Program_Error with "minimal batch was structurally invalid";
      end if;
      Encode_Checked (Fixture, Image, Length);
      if Length /= Fixture_Length or else Image (0 .. Length - 1) /= Golden then
         raise Program_Error with "batch encoding differs from the independent 223-byte golden image";
      end if;

      Batches.Decode_Latest_Batch
        (Golden, Fixture.Database_ID, Referencing_Head, Batches.Default_Reader_Caps, Value, Status);
      if Status /= Batches.Decoded or else Value /= Fixture then
         raise Program_Error with "golden batch did not round-trip";
      end if;

      for Size in Natural range 0 .. Fixture_Length - 1 loop
         declare
            Short : Formats.Byte_Array (1 .. Size);
         begin
            for Offset in Natural range 0 .. Size - 1 loop
               Short (Offset + 1) := Golden (Offset);
            end loop;
            Expect_Default_Decode (Short, Batches.Invalid_Length, "truncated batch was accepted");
         end;
      end loop;

      declare
         Long : Formats.Byte_Array (0 .. Fixture_Length) := [others => 0];
      begin
         Long (0 .. Fixture_Length - 1) := Golden;
         Expect_Default_Decode (Long, Batches.Invalid_Length, "trailing byte was accepted");
      end;
   end Test_Golden_And_Extent;

   procedure Test_Envelope_And_Semantics is
      Corrupt               : Batches.Batch_Image := [others => 0];
      --  Frozen batch-v1 offsets of required nonzero identities/counters. The
      --  sweep proves each field fails closed independently; offset movement is
      --  wire-incompatible and must track the normative codec table.
      Required_Field_Starts : constant array (Positive range 1 .. 7) of Natural :=
        [44, 52, 84, 100, 108, 124, 132];
   begin
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (0) := Corrupt (0) xor 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Magic, "invalid magic survived repair");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (9) := 2;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Unsupported_Version, "version survived repair");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (10) := 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Object_Kind, "kind survived repair");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (11) := 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Flags, "flags survived repair");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (27) := 9;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Wrong_Database, "wrong database survived repair");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (12 .. 27) := [others => 0];
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Wrong_Database, "zero database ID survived repair");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (31) := Corrupt (31) xor 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Length, "header extent survived repair");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (40) := Corrupt (40) xor 1;
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Header_Checksum_Failed, "bad header CRC accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (202) := Corrupt (202) xor 1;
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Object_Checksum_Failed, "bad object CRC accepted");

      for First of Required_Field_Starts loop
         Corrupt (0 .. Fixture_Length - 1) := Golden;
         Corrupt (First .. First + (if First in 44 | 100 | 124 | 132 then 7 else 15)) := [others => 0];
         Repair_Checksums (Corrupt, Fixture_Length);
         Expect_Default_Decode
           (Corrupt (0 .. Fixture_Length - 1),
            Batches.Invalid_Batch_State,
            "zero required batch field survived repair");
      end loop;

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (108 .. 123) := Corrupt (84 .. 99);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Batch_State, "transition IDs aliased");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (83) := 9;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Invalid_Batch_State,
         "first batch accepted a predecessor ID");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (147) := 2;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Invalid_Batch_State,
         "sequence interval disagreed with transaction count");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (151) := 0;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Batch_State, "zero txn count accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (155) := 0;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Batch_State, "zero mutation count accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (156 .. 171) := [others => 0];
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Transaction, "zero transaction ID accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (179) := 2;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Invalid_Transaction,
         "wrong transaction sequence accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (183) := 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Transaction, "wrong frame count accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (187) := 30;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Mutation, "wrong frame length accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (188 .. 191) := [others => 0];
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Mutation, "zero column family accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (192) := 3;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Mutation, "unknown operation accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (193) := 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Mutation, "mutation flags accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Corrupt (217) := 1;
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Mutation, "Delete value accepted");
   end Test_Envelope_And_Semantics;

   procedure Test_Caps is
      --  Exact caps are derived from Fixture: one transaction, two mutations,
      --  two key bytes, no value bytes, and 63 total framed payload bytes.
      --  One-below variants prove each independent reader budget.
      Exact   : constant Batches.Reader_Caps :=
        (Transactions => 1, Mutations => 2, Key_Bytes => 2, Value_Bytes => 0, Payload_Bytes => 63);
      Corrupt : Batches.Batch_Image := [others => 0];
   begin
      Expect_Decode (Golden, Referencing_Head, Exact, Batches.Decoded, "exact reader caps rejected fixture");
      Expect_Decode
        (Golden,
         Referencing_Head,
         (Exact with delta Transactions => 0),
         Batches.Limit_Exceeded,
         "transaction cap was not distinct");
      Expect_Decode
        (Golden,
         Referencing_Head,
         (Exact with delta Mutations => 1),
         Batches.Limit_Exceeded,
         "mutation cap was not distinct");
      Expect_Decode
        (Golden,
         Referencing_Head,
         (Exact with delta Key_Bytes => 1),
         Batches.Limit_Exceeded,
         "key cap was not distinct");
      Expect_Decode
        (Golden,
         Referencing_Head,
         (Exact with delta Payload_Bytes => 62),
         Batches.Limit_Exceeded,
         "payload cap was not distinct");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 148, Interfaces.Unsigned_32 (Batches.Max_Transactions + 1));
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Limit_Exceeded,
         "wire transaction count above the operational cap was called corruption");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 152, Interfaces.Unsigned_32 (Batches.Max_Mutations + 1));
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Limit_Exceeded,
         "wire mutation count above the operational cap was called corruption");

      declare
         Batch            : Batches.Commit_Batch := Fixture;
         Image            : Batches.Batch_Image;
         Length           : Natural;
         Publication_Head : constant Head.Head_State := Referencing_Head;
      begin
         Batch.Mutations (1).Value_Size := 1;
         Batch.Mutations (1).Value (1) := 16#7F#;
         Encode_Checked (Batch, Image, Length);
         Expect_Decode
           (Image (0 .. Length - 1),
            Publication_Head,
            (Transactions  => 1,
             Mutations     => 2,
             Key_Bytes     => 2,
             Value_Bytes   => 1,
             Payload_Bytes => Length - Batches.Batch_Header_Length - Batches.Batch_Trailer_Length),
            Batches.Decoded,
            "exact value cap rejected fixture");
         Expect_Decode
           (Image (0 .. Length - 1),
            Publication_Head,
            (Transactions  => 1,
             Mutations     => 2,
             Key_Bytes     => 2,
             Value_Bytes   => 0,
             Payload_Bytes => Length - Batches.Batch_Header_Length - Batches.Batch_Trailer_Length),
            Batches.Limit_Exceeded,
            "value cap was not distinct");

         Batch := Fixture;
         Batch.Mutations (1).Key_Size := 0;
         Encode_Checked (Batch, Image, Length);
         Expect_Decode
           (Image (0 .. Length - 1),
            Publication_Head,
            Batches.Default_Reader_Caps,
            Batches.Decoded,
            "empty key was rejected");
      end;
   end Test_Caps;

   procedure Test_Head_Binding is
      Wrong : Head.Head_State;
   begin
      for Dimension in Positive range 1 .. 7 loop
         Wrong := Referencing_Head;
         case Dimension is
            when 1 =>
               Wrong.Database_ID := ID (9);

            when 2 =>
               Wrong.Epoch := 2;

            when 3 =>
               Wrong.Latest_Batch := ID (9);

            when 4 =>
               Wrong.Transition_ID := ID (9);

            when 5 =>
               Wrong.Predecessor_Transition := ID (9);

            when 6 =>
               Wrong.Highest_Visible := 2;

            when 7 =>
               Wrong.Transition_Number := 3;
         end case;
         Expect_Decode
           (Golden,
            Wrong,
            Batches.Default_Reader_Caps,
            Batches.Head_Mismatch,
            "head mismatch dimension was accepted");
      end loop;
   end Test_Head_Binding;

   procedure Test_Extreme_Wire_Values is
      Corrupt : Batches.Batch_Image := [others => 0];
   begin
      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 32, Interfaces.Unsigned_64'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1), Batches.Invalid_Length, "maximum payload length was accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 148, Interfaces.Unsigned_32'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Limit_Exceeded,
         "maximum transaction count was not classified as a limit");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 152, Interfaces.Unsigned_32'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Limit_Exceeded,
         "maximum mutation count was not classified as a limit");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 184, Interfaces.Unsigned_32'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Invalid_Transaction,
         "maximum transaction body length was accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 194, Interfaces.Unsigned_32'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Limit_Exceeded,
         "maximum key length was not classified as a limit");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U32 (Corrupt, 198, Interfaces.Unsigned_32'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Limit_Exceeded,
         "maximum value length was not classified as a limit");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 100, Interfaces.Unsigned_64'Last);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Invalid_Batch_State,
         "maximum expected transition number was accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 124, 3);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Invalid_Batch_State,
         "non-successor publication number was accepted");

      Corrupt (0 .. Fixture_Length - 1) := Golden;
      Put_U64 (Corrupt, 100, 2);
      Put_U64 (Corrupt, 124, 3);
      Repair_Checksums (Corrupt, Fixture_Length);
      Expect_Default_Decode
        (Corrupt (0 .. Fixture_Length - 1),
         Batches.Invalid_Batch_State,
         "first-batch expected number did not equal its epoch");
   end Test_Extreme_Wire_Values;

   procedure Test_Cacheless_Traversal is
      --  Previous is the frozen fixture; Current deliberately advances every
      --  batch/HEAD link and sequence once. Exact IDs are traversal witnesses,
      --  not product identity allocation policy.
      Previous         : constant Batches.Commit_Batch := Fixture;
      Current          : Batches.Commit_Batch := Fixture;
      Previous_Image   : Batches.Batch_Image;
      Current_Image    : Batches.Batch_Image;
      Previous_Length  : Natural;
      Current_Length   : Natural;
      Previous_Decoded : Batches.Commit_Batch;
      Current_Decoded  : Batches.Commit_Batch;
      Previous_Status  : Batches.Decode_Status;
      Current_Status   : Batches.Decode_Status;
      Live_Head        : Head.Head_State := Referencing_Head;
   begin
      Current.Batch_ID := ID (6);
      Current.Previous_Batch_ID := Previous.Batch_ID;
      Current.Expected_Transition_ID := ID (9);
      Current.Expected_Transition_Number := 3;
      Current.Publication_Transition_ID := ID (7);
      Current.Publication_Transition_Number := 4;
      Current.First_Sequence := 2;
      Current.Last_Sequence := 2;
      Current.Transactions (1).Transaction_ID := ID (8);
      Current.Transactions (1).Sequence := 2;

      Live_Head.Highest_Visible := 2;
      Live_Head.Latest_Batch := Current.Batch_ID;
      Live_Head.Predecessor_Transition := Current.Expected_Transition_ID;
      Live_Head.Transition_ID := Current.Publication_Transition_ID;
      Live_Head.Transition_Number := Current.Publication_Transition_Number;

      Encode_Checked (Previous, Previous_Image, Previous_Length);
      Encode_Checked (Current, Current_Image, Current_Length);
      Batches.Decode_Latest_Batch
        (Current_Image (0 .. Current_Length - 1),
         Fixture.Database_ID,
         Live_Head,
         Batches.Default_Reader_Caps,
         Current_Decoded,
         Current_Status);
      if Current_Status /= Batches.Decoded then
         raise Program_Error with "live HEAD did not decode the latest batch";
      end if;

      Batches.Decode_Batch
        (Previous_Image (0 .. Previous_Length - 1),
         Fixture.Database_ID,
         Batches.Default_Reader_Caps,
         Previous_Decoded,
         Previous_Status);
      if Previous_Status /= Batches.Decoded then
         raise Program_Error with "predecessor required an unavailable historical HEAD";
      elsif not Batches.Valid_Predecessor (Current_Decoded, Previous_Decoded) then
         raise Program_Error with "cacheless predecessor traversal rejected a valid link";
      end if;
   end Test_Cacheless_Traversal;

   procedure Test_Maximum_Batch is
      Batch     : Batches.Commit_Batch := Batches.Empty_Batch;
      Image     : Batches.Batch_Image;
      Length    : Natural;
      Value     : Batches.Commit_Batch;
      Status    : Batches.Decode_Status;
      Live_Head : Head.Head_State := Referencing_Head;
   begin
      Batch.Database_ID := ID (1);
      Batch.Epoch := 1;
      Batch.Batch_ID := ID (20);
      Batch.Expected_Transition_ID := ID (21);
      Batch.Expected_Transition_Number := 1;
      Batch.Publication_Transition_ID := ID (22);
      Batch.Publication_Transition_Number := 2;
      Batch.First_Sequence := 1;
      Batch.Last_Sequence := Batches.Max_Transactions;
      Batch.Transaction_Total := Batches.Max_Transactions;
      Batch.Mutation_Total := Batches.Max_Mutations;

      for Transaction_Index in Batches.Transaction_Slot loop
         Batch.Transactions (Transaction_Index).Transaction_ID :=
           ID (Interfaces.Unsigned_8 (32 + Transaction_Index));
         Batch.Transactions (Transaction_Index).Sequence := Head.Commit_Sequence (Transaction_Index);
         Batch.Transactions (Transaction_Index).First_Mutation :=
           Batches.Mutation_Count ((Transaction_Index - 1) * 4 + 1);
         Batch.Transactions (Transaction_Index).Mutations := 4;
      end loop;

      for Mutation_Index in Batches.Mutation_Slot loop
         Batch.Mutations (Mutation_Index).Column_Family := Interfaces.Unsigned_32 (Mutation_Index);
         Batch.Mutations (Mutation_Index).Operation := Batches.Put;
         Batch.Mutations (Mutation_Index).Key_Size := Batches.Max_Key_Bytes;
         Batch.Mutations (Mutation_Index).Value_Size := Batches.Max_Value_Bytes;
         for Index in Batch.Mutations (Mutation_Index).Key'Range loop
            Batch.Mutations (Mutation_Index).Key (Index) := Formats.Byte ((Mutation_Index + Index) mod 256);
         end loop;
         for Index in Batch.Mutations (Mutation_Index).Value'Range loop
            Batch.Mutations (Mutation_Index).Value (Index) := Formats.Byte ((Mutation_Index + Index) mod 256);
         end loop;
      end loop;

      Live_Head.Highest_Visible := Batch.Last_Sequence;
      Live_Head.Latest_Batch := Batch.Batch_ID;
      Live_Head.Predecessor_Transition := Batch.Expected_Transition_ID;
      Live_Head.Transition_ID := Batch.Publication_Transition_ID;
      Encode_Checked (Batch, Image, Length);
      if Length /= Batches.Max_Batch_Image_Length then
         raise Program_Error with "maximum batch did not fill the exact bounded image";
      end if;
      Batches.Decode_Latest_Batch
        (Image (0 .. Length - 1), Batch.Database_ID, Live_Head, Batches.Default_Reader_Caps, Value, Status);
      if Status /= Batches.Decoded or else Value /= Batch then
         raise Program_Error with "maximum batch did not round-trip";
      end if;
   end Test_Maximum_Batch;

   procedure Test_Duplicates_And_Predecessor is
      --  The frozen fixture is the exact predecessor authority for all
      --  successor, duplicate-ID, and chain-corruption mutations in this test.
      Previous         : constant Batches.Commit_Batch := Fixture;
      Current          : Batches.Commit_Batch := Fixture;
      Image            : Batches.Batch_Image;
      Length           : Natural;
      Publication_Head : Head.Head_State := Referencing_Head;
      Corrupt          : Batches.Batch_Image;
   begin
      Current.Batch_ID := ID (6);
      Current.Previous_Batch_ID := Previous.Batch_ID;
      Current.Expected_Transition_ID := Previous.Publication_Transition_ID;
      Current.Expected_Transition_Number := Previous.Publication_Transition_Number;
      Current.Publication_Transition_ID := ID (7);
      Current.Publication_Transition_Number := Current.Expected_Transition_Number + 1;
      Current.First_Sequence := 2;
      Current.Last_Sequence := 2;
      Current.Transactions (1).Transaction_ID := ID (8);
      Current.Transactions (1).Sequence := 2;
      if not Batches.Is_First_Batch (Previous) then
         raise Program_Error with "first-batch predicate rejected the initial batch";
      end if;
      if not Batches.Valid_Predecessor (Current, Previous) then
         raise Program_Error with "valid predecessor chain was rejected";
      end if;

      declare
         Bad : Batches.Commit_Batch := Current;
      begin
         Bad.Previous_Batch_ID := ID (9);
         if Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "wrong predecessor batch was accepted";
         end if;
         Bad := Current;
         Bad.Batch_ID := Previous.Batch_ID;
         if Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "self-referential batch ID was accepted";
         end if;
         Bad := Current;
         Bad.First_Sequence := 3;
         Bad.Last_Sequence := 3;
         Bad.Transactions (1).Sequence := 3;
         if Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "sequence gap was accepted";
         end if;
         Bad := Current;
         Bad.Database_ID := ID (9);
         if Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "cross-database predecessor was accepted";
         end if;
         Bad := Current;
         Bad.Expected_Transition_ID := ID (9);
         if Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "direct ordinal edge accepted the wrong transition ID";
         end if;
         Bad := Current;
         Bad.Expected_Transition_ID := ID (9);
         Bad.Expected_Transition_Number := Current.Expected_Transition_Number + 1;
         Bad.Publication_Transition_Number := Bad.Expected_Transition_Number + 1;
         if not Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "same-epoch metadata transition was rejected";
         end if;
         Bad := Current;
         Bad.Expected_Transition_ID := Previous.Publication_Transition_ID;
         Bad.Expected_Transition_Number := Current.Expected_Transition_Number + 1;
         Bad.Publication_Transition_Number := Bad.Expected_Transition_Number + 1;
         if Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "immediate successor reused the predecessor transition ID";
         end if;
         Bad := Current;
         Bad.Expected_Transition_ID := Previous.Publication_Transition_ID;
         Bad.Expected_Transition_Number := Current.Expected_Transition_Number + 2;
         Bad.Publication_Transition_Number := Bad.Expected_Transition_Number + 1;
         if not Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "historical transition ID recurrence was rejected";
         end if;
         Bad := Current;
         Bad.Epoch := 2;
         Bad.Expected_Transition_ID := ID (9);
         Bad.Expected_Transition_Number := Current.Expected_Transition_Number + 1;
         Bad.Publication_Transition_Number := Bad.Expected_Transition_Number + 1;
         if not Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "writer-acquisition transition was rejected";
         end if;
         Bad := Current;
         Bad.Expected_Transition_Number := 1;
         Bad.Publication_Transition_Number := 2;
         if Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "ordinal regression was accepted";
         end if;
         Bad := Current;
         Bad.Epoch := 0;
         if Batches.Valid_Predecessor (Bad, Previous) then
            raise Program_Error with "epoch regression was accepted";
         end if;
      end;

      declare
         Previous_Late : Batches.Commit_Batch := Current;
         Current_Late  : Batches.Commit_Batch := Current;
      begin
         Previous_Late.Expected_Transition_Number := 9;
         Previous_Late.Publication_Transition_Number := 10;
         Current_Late.Batch_ID := ID (10);
         Current_Late.Previous_Batch_ID := Previous_Late.Batch_ID;
         Current_Late.Epoch := 3;
         Current_Late.Expected_Transition_ID := ID (11);
         Current_Late.Expected_Transition_Number := 11;
         Current_Late.Publication_Transition_ID := ID (12);
         Current_Late.Publication_Transition_Number := 12;
         Current_Late.First_Sequence := 3;
         Current_Late.Last_Sequence := 3;
         Current_Late.Transactions (1).Sequence := 3;
         if Batches.Valid_Predecessor (Current_Late, Previous_Late) then
            raise Program_Error with "epoch advance exceeded the ordinal gap";
         end if;
      end;

      Current := Fixture;
      Current.Transaction_Total := 2;
      Current.Mutation_Total := 2;
      Current.Last_Sequence := 2;
      Current.Transactions (1).Mutations := 1;
      Current.Transactions (2).Transaction_ID := ID (6);
      Current.Transactions (2).Sequence := 2;
      Current.Transactions (2).First_Mutation := 2;
      Current.Transactions (2).Mutations := 1;
      Publication_Head.Highest_Visible := 2;
      Encode_Checked (Current, Image, Length);
      Expect_Decode
        (Image (0 .. Length - 1),
         Publication_Head,
         Batches.Default_Reader_Caps,
         Batches.Decoded,
         "valid multi-transaction batch was rejected");
      Corrupt := Image;
      Corrupt (204 .. 219) := Corrupt (156 .. 171);
      Repair_Checksums (Corrupt, Length);
      Expect_Decode
        (Corrupt (0 .. Length - 1),
         Publication_Head,
         Batches.Default_Reader_Caps,
         Batches.Duplicate_Transaction,
         "duplicate transaction ID accepted");

      Current := Fixture;
      Current.Mutations (1).Column_Family := 1;
      Current.Mutations (1).Key_Size := 1;
      Current.Mutations (1).Key (1) := 16#61#;
      Current.Mutations (2).Column_Family := 1;
      Current.Mutations (2).Operation := Batches.Put;
      Current.Mutations (2).Key_Size := 1;
      Current.Mutations (2).Key (1) := 16#62#;
      Publication_Head := Referencing_Head;
      Encode_Checked (Current, Image, Length);
      Corrupt := Image;
      Corrupt (217) := 16#61#;
      Repair_Checksums (Corrupt, Length);
      Expect_Decode
        (Corrupt (0 .. Length - 1),
         Publication_Head,
         Batches.Default_Reader_Caps,
         Batches.Duplicate_Key,
         "duplicate column-family key accepted");
   end Test_Duplicates_And_Predecessor;

   procedure Run is
   begin
      Test_Golden_And_Extent;
      Test_Envelope_And_Semantics;
      Test_Caps;
      Test_Head_Binding;
      Test_Extreme_Wire_Values;
      Test_Cacheless_Traversal;
      Test_Maximum_Batch;
      Test_Duplicates_And_Predecessor;
   end Run;

end Flyology.DB.Batch_Format_Tests;
