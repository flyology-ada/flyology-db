with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Flyology.DB.LSM_Formats;
with Flyology.DB.LSM_Runtime_Formats;
with Flyology.DB.Manifest_Formats;
with Interfaces;

package body Flyology.DB.LSM_Format_Tests is

   package Formats renames Flyology.DB.Formats;
   package Head renames Flyology.DB.Head_Policy;
   package Manifests renames Flyology.DB.Manifest_Formats;
   package Runtime renames Flyology.DB.LSM_Runtime_Formats;

   --  These dimensions are fixture coverage choices: two run slots permit an
   --  ordering probe, four identities/entries permit exact and one-over caps,
   --  and eight-byte key/value arrays cover tails. They are not DB defaults.
   package LSM is new
     Flyology.DB.LSM_Formats.Reference
       (Maximum_Runs_Per_Family => 2,
        Maximum_Identities      => 4,
        Maximum_SST_Entries     => 4,
        Maximum_Key_Bytes       => 8,
        Maximum_Value_Bytes     => 8);

   use type Formats.Byte;
   use type Formats.Byte_Array;
   use type Head.Identifier;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type LSM.Checkpoint_Manifest;
   use type LSM.Decode_Status;
   use type LSM.Encode_Status;
   use type LSM.SST;
   use type Runtime.Allocation_Status;
   use type Runtime.Decode_Status;
   use type Runtime.Encode_Status;
   use type Runtime.Checkpoint_Manifest_Access;
   use type Runtime.Image_Access;
   use type Runtime.SST_Access;

   --  Exact extents derived independently by generate_lsm_goldens.py from the
   --  frozen field tables and fixture values; they are not product limits.
   Previous_Manifest_Length : constant := 358;
   Manifest_Length          : constant := 366;
   SST_Length               : constant := 164;

   --  Each equality restates the normative field-width formula rather than an
   --  independent expected size. A failure is a wire-table/golden drift event.
   pragma
     Compile_Time_Error
       (LSM.Previous_Checkpoint_Manifest_Header_Length
        /= Manifests.Manifest_Header_Length + 8 + 4 + 4 + 4 + 4,
        "previous checkpoint manifest header arithmetic changed");
   pragma
     Compile_Time_Error
       (LSM.Checkpoint_Manifest_Header_Length
        /= LSM.Previous_Checkpoint_Manifest_Header_Length + 4 + 4,
        "checkpoint manifest header arithmetic changed");
   pragma
     Compile_Time_Error
       (LSM.Checkpoint_Family_Header_Length /= Manifests.Family_Frame_Header_Length + 8 + 4 + 4 + 4 + 4,
        "checkpoint family header arithmetic changed");
   pragma
     Compile_Time_Error
       (LSM.Run_Descriptor_Length /= Head.Identifier_Length + 8 + 8 + 4 + 4 + 8,
        "run descriptor arithmetic changed");
   pragma
     Compile_Time_Error
       (LSM.SST_Header_Length /= 44 + Head.Identifier_Length + 4 + 8 + 8 + 4 + 4 + 8,
        "SST header arithmetic changed");
   pragma
     Compile_Time_Error
       (LSM.SST_Entry_Header_Length /= 8 + 1 + 1 + 2 + 4 + 4, "SST entry header arithmetic changed");

   function ID (Last : Interfaces.Unsigned_8) return Head.Identifier is
      Result : Head.Identifier := [others => 0];
   begin
      Result (Result'Last) := Last;
      return Result;
   end ID;

   function Nibble (Item : Character) return Formats.Byte is
   begin
      if Item in '0' .. '9' then
         return Character'Pos (Item) - Character'Pos ('0');
      elsif Item in 'A' .. 'F' then
         return Character'Pos (Item) - Character'Pos ('A') + 10;
      else
         raise Constraint_Error with "invalid golden hex digit";
      end if;
   end Nibble;

   function Hex (Data : String) return Formats.Byte_Array is
      Result : Formats.Byte_Array (0 .. Data'Length / 2 - 1);
   begin
      if Data'Length mod 2 /= 0 then
         raise Constraint_Error with "odd golden hex length";
      end if;
      for Index in Result'Range loop
         Result (Index) :=
           16 * Nibble (Data (Data'First + 2 * Index)) + Nibble (Data (Data'First + 2 * Index + 1));
      end loop;
      return Result;
   end Hex;

   --  Compatibility fixtures emitted independently by generate_lsm_goldens.py
   --  from the normative field tables. Any byte change requires an explicit
   --  format decision and coordinated generator/decoder fixture update.
   Manifest_Golden : constant Formats.Byte_Array (0 .. Manifest_Length - 1) :=
     Hex
       ("464C5943464D30310003030000000000000000000000000000000001000000E40000000000000086BE69EDC3"
        & "0000000000000000000000000000000700000000000000000000000000000003000000000000000000000000"
        & "0000000400000000000000020000000000000000000000000000000800000000000000030000000000000001"
        & "0000000000000002000000010000004000000040000000400000000800000040000000400000010000000000"
        & "0020000000000000010000000000000004000000000000000000000200000002000000040000000200000000"
        & "0000000800000004000000010000000000000000000000080000000000000008000200000000000000001000"
        & "0000001000000002000000010000000063660000000000000000000000000000000900000000000000010000"
        & "000000000002000000030000000000000000000000040000000000000000000000000000000A000000000000"
        & "0000000000000000000B451EAAFD");

   --  Exact manifest-v2 compatibility image. Runtime decoding must retain it
   --  without inventing v3 serializable limits; the bounded reference codec
   --  intentionally accepts only the current format.
   Previous_Manifest_Golden : constant Formats.Byte_Array (0 .. Previous_Manifest_Length - 1) :=
     Hex
       ("464C5943464D30310002030000000000000000000000000000000001000000DC000000000000008686644133"
        & "0000000000000000000000000000000700000000000000000000000000000003000000000000000000000000"
        & "0000000400000000000000020000000000000000000000000000000800000000000000030000000000000001"
        & "0000000000000002000000010000004000000040000000400000000800000040000000400000010000000000"
        & "0020000000000000010000000000000004000000000000000000000200000002000000040000000200000000"
        & "0000000100000000000000000000000800000000000000080002000000000000000010000000001000000002"
        & "0000000100000000636600000000000000000000000000000009000000000000000100000000000000020000"
        & "00030000000000000000000000040000000000000000000000000000000A0000000000000000000000000000"
        & "000B69B7DBB7");

   --  Independent SST-v1 compatibility image from the same generator and
   --  normative tables; changing a byte is a persisted-format review event.
   SST_Golden : constant Formats.Byte_Array (0 .. SST_Length - 1) :=
     Hex
       ("464C5953535430310001040000000000000000000000000000000001000000600000000000000040B295ECF7"
        & "0000000000000000000000000000000900000001000000000000000100000000000000020000000300000000"
        & "0000000000000004000000000000000201000000000000010000000161780000000000000001020000000000"
        & "00010000000061000000000000000201000000000000010000000062AE274ADA");

   function Base_Manifest return Manifests.Manifest is
      Result : Manifests.Manifest := Manifests.Empty_Manifest;
   begin
      --  Maintained manifest-v1 successor fixture: stable small identities and
      --  ordinals exercise every inherited v2 header field without creating
      --  product identity or sequencing policy.
      Result.Database_ID := ID (1);
      Result.Manifest_ID := ID (7);
      Result.Previous_Manifest_ID := ID (3);
      Result.Expected_Transition_ID := ID (4);
      Result.Expected_Transition_Number := 2;
      Result.Publication_Transition_ID := ID (8);
      Result.Publication_Transition_Number := 3;
      Result.Writer_Epoch := 1;
      Result.Registry_Revision := 2;
      Result.Family_Total := 1;
      --  Existing manifest-test values are reused only to make the fixture's
      --  v1 base structurally valid; they are not defaults in this package.
      Result.Limits :=
        (Maximum_Column_Families           => 64,
         Maximum_Manifest_History          => 64,
         Maximum_Batch_History             => 64,
         Maximum_Transactions_Per_Batch    => 8,
         Maximum_Mutations_Per_Transaction => 64,
         Maximum_Mutations_Per_Batch       => 64,
         Maximum_Live_Entries              => 256,
         Maximum_Transaction_Payload_Bytes => 2 * 1_024 * 1_024,
         Maximum_Batch_Payload_Bytes       => 16 * 1_024 * 1_024,
         Maximum_Live_State_Bytes          => 64 * 1_024 * 1_024);
      Result.Families (1).ID := 1;
      Result.Families (1).Max_Key_Bytes := 8;
      Result.Families (1).Max_Value_Bytes := 8;
      Result.Families (1).Name_Length := 2;
      Result.Families (1).Name (1 .. 2) := [Character'Pos ('c'), Character'Pos ('f')];
      return Result;
   end Base_Manifest;

   function Checkpoint_Fixture return LSM.Checkpoint_Manifest is
      Result : LSM.Checkpoint_Manifest := LSM.Empty_Checkpoint_Manifest;
   begin
      --  Reference coverage shape: one family and run exercise exact mapping;
      --  two ordered identities and a sequence boundary exercise ledger and
      --  replay rules. These values are fixtures, not database defaults.
      Result.Base := Base_Manifest;
      Result.Replay_Boundary := 2;
      Result.Maximum_Total_L0_Runs := 2;
      Result.Maximum_Checkpoint_Identities := 4;
      --  Maintained serializable reference geometry persisted by manifest v3.
      Result.Maximum_Point_Reads_Per_Transaction := 8;
      Result.Maximum_Scan_Ranges_Per_Transaction := 4;
      Result.Identity_Total := 2;
      Result.Identities (1) := ID (10);
      Result.Identities (2) := ID (11);
      Result.Family_LSM (1).Memtable_Max_Bytes := 4 * 1_024;
      Result.Family_LSM (1).Memtable_Max_Entries := 16;
      Result.Family_LSM (1).Maximum_L0_Runs := 2;
      Result.Family_LSM (1).Run_Total := 1;
      Result.Family_LSM (1).Runs (1) :=
        (Run_ID                => ID (9),
         Lowest_Sequence       => 1,
         Highest_Sequence      => 2,
         Entry_Total           => 3,
         Logical_Payload_Bytes => 4);
      return Result;
   end Checkpoint_Fixture;

   function SST_Fixture return LSM.SST is
      Result : LSM.SST := LSM.Empty_SST;
   begin
      --  Structured counterpart of the independent SST golden: run 9 in
      --  family 1 covers sequences 1..2 and the exact three-entry/four-byte
      --  descriptor. Values are compatibility-fixture data, not defaults.
      Result.Database_ID := ID (1);
      Result.Run_ID := ID (9);
      Result.Family_ID := 1;
      Result.Lowest_Sequence := 1;
      Result.Highest_Sequence := 2;
      Result.Entry_Total := 3;
      Result.Logical_Payload_Bytes := 4;
      Result.Entries (1).Sequence := 2;
      Result.Entries (1).Operation := LSM.Put_Operation;
      Result.Entries (1).Key_Byte_Total := 1;
      Result.Entries (1).Value_Byte_Total := 1;
      Result.Entries (1).Key (1) := Character'Pos ('a');
      Result.Entries (1).Value (1) := Character'Pos ('x');
      Result.Entries (2).Sequence := 1;
      Result.Entries (2).Operation := LSM.Delete_Operation;
      Result.Entries (2).Key_Byte_Total := 1;
      Result.Entries (2).Key (1) := Character'Pos ('a');
      Result.Entries (3).Sequence := 2;
      Result.Entries (3).Operation := LSM.Put_Operation;
      Result.Entries (3).Key_Byte_Total := 1;
      Result.Entries (3).Key (1) := Character'Pos ('b');
      return Result;
   end SST_Fixture;

   --  Canonical structured counterparts of the two frozen golden images;
   --  equality with the generator output is the cross-implementation witness.
   Checkpoint : constant LSM.Checkpoint_Manifest := Checkpoint_Fixture;
   Table      : constant LSM.SST := SST_Fixture;

   --  Test-only big-endian field writers mirror frozen U32/U64 widths so a
   --  corruption probe can repair checksums without calling the codec under
   --  test. Loop widths and byte masks are derived, not policy choices.
   procedure Put_U32 (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_32)
   is
   begin
      for Offset in Natural range 0 .. 3 loop
         Image (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64 (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_64)
   is
   begin
      for Offset in Natural range 0 .. 7 loop
         Image (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   procedure Repair_Checksums (Image : in out Formats.Byte_Array; Header_Length : Natural) is
      Header : Formats.Byte_Array (0 .. Header_Length - 1) := Image (0 .. Header_Length - 1);
   begin
      --  Common-envelope bytes 40..43 are the frozen header checksum field;
      --  the final four bytes are the frozen whole-object CRC trailer.
      Header (40 .. 43) := [others => 0];
      Put_U32 (Image, 40, Formats.CRC_32C (Header));
      Put_U32 (Image, Image'Last - 3, Formats.CRC_32C (Image (0 .. Image'Last - 4)));
   end Repair_Checksums;

   procedure Expect_Manifest
     (Image    : Formats.Byte_Array;
      Limits   : LSM.Checkpoint_Reader_Caps;
      Expected : LSM.Decode_Status;
      Context  : String)
   is
      Value  : LSM.Checkpoint_Manifest;
      Status : LSM.Decode_Status;
   begin
      LSM.Decode_Checkpoint_Manifest (Image, ID (1), Limits, Value, Status);
      if Status /= Expected then
         raise Program_Error with Context & ": " & LSM.Decode_Status'Image (Status);
      elsif Status /= LSM.Decoded and then Value /= LSM.Empty_Checkpoint_Manifest then
         raise Program_Error with Context & ": partial manifest output";
      end if;
   end Expect_Manifest;

   procedure Expect_SST
     (Image    : Formats.Byte_Array;
      Limits   : LSM.SST_Reader_Caps;
      Expected : LSM.Decode_Status;
      Context  : String)
   is
      Value  : LSM.SST;
      Status : LSM.Decode_Status;
   begin
      LSM.Decode_SST (Image, ID (1), Limits, Value, Status);
      if Status /= Expected then
         raise Program_Error with Context & ": " & LSM.Decode_Status'Image (Status);
      elsif Status /= LSM.Decoded and then Value /= LSM.Empty_SST then
         raise Program_Error with Context & ": partial SST output";
      end if;
   end Expect_SST;

   procedure Test_Goldens_And_Extents is
      Manifest_Image  : LSM.Checkpoint_Manifest_Image;
      Manifest_Value  : LSM.Checkpoint_Manifest;
      Manifest_Status : LSM.Decode_Status;
      SST_Image       : LSM.SST_Image;
      SST_Value       : LSM.SST;
      SST_Status      : LSM.Decode_Status;
      Length          : Natural;
      Encode_Status   : LSM.Encode_Status;
   begin
      LSM.Encode_Checkpoint_Manifest (Checkpoint, Manifest_Image, Length, Encode_Status);
      if Encode_Status /= LSM.Encoded
        or else Length /= Manifest_Length
        or else Manifest_Image (0 .. Length - 1) /= Manifest_Golden
      then
         raise Program_Error with "checkpoint manifest differs from independent golden";
      end if;
      LSM.Decode_Checkpoint_Manifest
        (Manifest_Golden, ID (1), LSM.Default_Checkpoint_Reader_Caps, Manifest_Value, Manifest_Status);
      if Manifest_Status /= LSM.Decoded or else Manifest_Value /= Checkpoint then
         raise Program_Error with "checkpoint manifest golden did not round-trip";
      end if;

      LSM.Encode_SST (Table, SST_Image, Length, Encode_Status);
      if Encode_Status /= LSM.Encoded
        or else Length /= SST_Length
        or else SST_Image (0 .. Length - 1) /= SST_Golden
      then
         raise Program_Error with "SST differs from independent golden";
      end if;
      LSM.Decode_SST (SST_Golden, ID (1), LSM.Default_SST_Reader_Caps, SST_Value, SST_Status);
      if SST_Status /= LSM.Decoded or else SST_Value /= Table then
         raise Program_Error with "SST golden did not round-trip";
      end if;

      declare
         --  Arbitrary nonzero lower bounds exercise positional byte admission;
         --  7 and 11 are test/reference shifts, never persisted offsets.
         Shifted_Manifest : constant Formats.Byte_Array (7 .. 7 + Manifest_Length - 1) := Manifest_Golden;
         Shifted_SST      : constant Formats.Byte_Array (11 .. 11 + SST_Length - 1) := SST_Golden;
      begin
         Expect_Manifest
           (Shifted_Manifest,
            LSM.Default_Checkpoint_Reader_Caps,
            LSM.Decoded,
            "shifted manifest lower bound");
         Expect_SST (Shifted_SST, LSM.Default_SST_Reader_Caps, LSM.Decoded, "shifted SST lower bound");
      end;

      for Size in Natural range 0 .. Manifest_Length - 1 loop
         declare
            Short : Formats.Byte_Array (1 .. Size);
         begin
            if Size > 0 then
               Short := Manifest_Golden (0 .. Size - 1);
            end if;
            Expect_Manifest
              (Short, LSM.Default_Checkpoint_Reader_Caps, LSM.Invalid_Length, "truncated manifest accepted");
         end;
      end loop;
      for Size in Natural range 0 .. SST_Length - 1 loop
         declare
            Short : Formats.Byte_Array (1 .. Size);
         begin
            if Size > 0 then
               Short := SST_Golden (0 .. Size - 1);
            end if;
            Expect_SST (Short, LSM.Default_SST_Reader_Caps, LSM.Invalid_Length, "truncated SST accepted");
         end;
      end loop;
      declare
         Long_Manifest : Formats.Byte_Array (0 .. Manifest_Length) := [others => 0];
         Long_SST      : Formats.Byte_Array (0 .. SST_Length) := [others => 0];
      begin
         Long_Manifest (0 .. Manifest_Length - 1) := Manifest_Golden;
         Long_SST (0 .. SST_Length - 1) := SST_Golden;
         Expect_Manifest
           (Long_Manifest, LSM.Default_Checkpoint_Reader_Caps, LSM.Invalid_Length, "manifest trailing byte");
         Expect_SST (Long_SST, LSM.Default_SST_Reader_Caps, LSM.Invalid_Length, "SST trailing byte");
      end;
   end Test_Goldens_And_Extents;

   procedure Test_Manifest_Rejection is
      --  Corruption offsets below directly probe the normative v3 table:
      --  common version/kind/flags/database/header/CRC at 9/10/11/27/28/40;
      --  inherited limits/state at 156/196/204/208/216, new limits at 220/224,
      --  family state at 256/268, run high sequence 306, and ledger 330/346.
      Corrupt : LSM.Checkpoint_Manifest_Image := [others => 0];
      --  Derived from Manifest_Golden: one run, two identities, and 134 exact
      --  payload bytes. One-less variants below prove each cap independently.
      Exact   : constant LSM.Checkpoint_Reader_Caps :=
        (Runs_Per_Family => 1, Identities => 2, Payload_Bytes => 134);
      Changed : LSM.Checkpoint_Manifest;
   begin
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Corrupt (0) := Corrupt (0) xor 1;
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Magic, "manifest magic corruption");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Corrupt (9) := 4;
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Unsupported_Version, "manifest version corruption");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Corrupt (10) := 4;
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Object_Kind, "manifest kind corruption");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Corrupt (11) := 1;
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Flags, "manifest flags corruption");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Corrupt (27) := 2;
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Wrong_Database, "manifest database corruption");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U32 (Corrupt, 28, LSM.Checkpoint_Manifest_Header_Length + 1);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Length, "manifest header length");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Corrupt (40) := Corrupt (40) xor 1;
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1),
         (Runs_Per_Family => 0, others => <>),
         LSM.Header_Checksum_Failed,
         "manifest cap hid corrupt header");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Corrupt (300) := Corrupt (300) xor 1;
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Object_Checksum_Failed, "manifest object checksum");

      Expect_Manifest (Manifest_Golden, Exact, LSM.Decoded, "exact manifest caps");
      Expect_Manifest
        (Manifest_Golden, (Exact with delta Runs_Per_Family => 0), LSM.Limit_Exceeded, "run cap");
      Expect_Manifest
        (Manifest_Golden, (Exact with delta Identities => 1), LSM.Limit_Exceeded, "identity cap");
      Expect_Manifest
        (Manifest_Golden,
         (Exact with delta Payload_Bytes => 133),
         LSM.Limit_Exceeded,
         "manifest payload cap");

      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U32 (Corrupt, 216, 1);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "manifest reserved field");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U64 (Corrupt, 196, 0);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "zero replay boundary");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U32 (Corrupt, 204, 0);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "zero database run limit");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U32 (Corrupt, 208, 0);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "zero identity limit");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U32 (Corrupt, 220, 0);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "zero point-read limit");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U32 (Corrupt, 224, 0);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "zero scan-range limit");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U64 (Corrupt, 256, 0);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "zero memtable byte limit");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U32 (Corrupt, 268, 0);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "zero family run limit");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U64 (Corrupt, 306, 3);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "run beyond boundary");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Corrupt (346 .. 361) := Corrupt (330 .. 345);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Invalid_Manifest_State, "duplicate identity");
      Corrupt (0 .. Manifest_Length - 1) := Manifest_Golden;
      Put_U32 (Corrupt, 156, Manifests.Max_Batch_Transactions + 1);
      Repair_Checksums (Corrupt (0 .. Manifest_Length - 1), LSM.Checkpoint_Manifest_Header_Length);
      Expect_Manifest
        (Corrupt (0 .. Manifest_Length - 1), Exact, LSM.Limit_Exceeded, "base representation limit");

      Changed := Checkpoint;
      Changed.Family_LSM (2).Memtable_Max_Bytes := 1;
      if LSM.Structurally_Valid (Changed) then
         raise Program_Error with "nonzero unused manifest family state accepted";
      end if;
   end Test_Manifest_Rejection;

   procedure Test_SST_Rejection is
      --  Corruption offsets directly probe SST-v1: common version/kind/flags/
      --  database/header/CRC at 9/10/11/27/28/40; header reserved at 84;
      --  entry sequence/tag/flags at 96/104/105 and later ordering bytes.
      Corrupt : LSM.SST_Image := [others => 0];
      --  Derived from SST_Golden: three entries, one-byte keys/values, and 64
      --  payload bytes. These caps authenticate the exact fixture boundary.
      Exact   : constant LSM.SST_Reader_Caps :=
        (Entries => 3, Key_Bytes => 1, Value_Bytes => 1, Payload_Bytes => 64);
      Changed : LSM.SST;
      Image   : LSM.SST_Image;
      Length  : Natural;
      Status  : LSM.Encode_Status;
   begin
      Expect_SST (SST_Golden, Exact, LSM.Decoded, "exact SST caps");
      Expect_SST (SST_Golden, (Exact with delta Entries => 2), LSM.Limit_Exceeded, "SST entry cap");
      Expect_SST (SST_Golden, (Exact with delta Key_Bytes => 0), LSM.Limit_Exceeded, "SST key cap");
      Expect_SST (SST_Golden, (Exact with delta Value_Bytes => 0), LSM.Limit_Exceeded, "SST value cap");
      Expect_SST (SST_Golden, (Exact with delta Payload_Bytes => 63), LSM.Limit_Exceeded, "SST payload cap");

      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (0) := Corrupt (0) xor 1;
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_Magic, "SST magic corruption");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (9) := 2;
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Unsupported_Version, "SST version corruption");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (10) := 3;
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_Object_Kind, "SST kind corruption");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (11) := 1;
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_Flags, "SST flags corruption");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (27) := 2;
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Wrong_Database, "SST database corruption");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Put_U32 (Corrupt, 28, LSM.SST_Header_Length + 1);
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_Length, "SST header length");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (40) := Corrupt (40) xor 1;
      Expect_SST
        (Corrupt (0 .. SST_Length - 1),
         (Entries => 0, others => <>),
         LSM.Header_Checksum_Failed,
         "SST cap hid corrupt header");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (117) := Corrupt (117) xor 1;
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Object_Checksum_Failed, "SST object checksum");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Put_U32 (Corrupt, 84, 1);
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_SST_State, "SST reserved field");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Put_U64 (Corrupt, 118, 2);
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_SST_State, "duplicate key sequence");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (159) := Character'Pos ('0');
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_SST_State, "unordered SST key");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (105) := 1;
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_Entry, "entry flags");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Put_U64 (Corrupt, 96, 0);
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_Entry, "zero entry sequence");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (104) := 0;
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_Entry, "unknown entry operation");
      Corrupt (0 .. SST_Length - 1) := SST_Golden;
      Corrupt (104) := LSM.Delete_Operation;
      Repair_Checksums (Corrupt (0 .. SST_Length - 1), LSM.SST_Header_Length);
      Expect_SST (Corrupt (0 .. SST_Length - 1), Exact, LSM.Invalid_Entry, "Delete entry with value");

      Changed := Table;
      Changed.Entries (2).Value_Byte_Total := 1;
      Changed.Entries (2).Value (1) := 1;
      LSM.Encode_SST (Changed, Image, Length, Status);
      if Status /= LSM.Invalid_Value or else Length /= 0 then
         raise Program_Error with "Delete value encoded";
      end if;
      Changed := Table;
      Changed.Entries (4).Sequence := 1;
      if LSM.Structurally_Valid (Changed) then
         raise Program_Error with "nonzero unused SST entry accepted";
      end if;
      if not LSM.Descriptor_Matches (Table, ID (1), 1, Checkpoint.Family_LSM (1).Runs (1))
        or else LSM.Descriptor_Matches (Table, ID (2), 1, Checkpoint.Family_LSM (1).Runs (1))
        or else LSM.Descriptor_Matches (Table, ID (1), 2, Checkpoint.Family_LSM (1).Runs (1))
      then
         raise Program_Error with "SST descriptor/database/family binding is not exact";
      end if;
   end Test_SST_Rejection;

   procedure Test_Runtime_Golden_Parity is
      Manifest_Value : Runtime.Checkpoint_Manifest_Access;
      Manifest_Read  : Runtime.Checkpoint_Manifest_Access;
      Manifest_Image : Runtime.Image_Access;
      Manifest_Head  : Runtime.Checkpoint_Header_Admission;
      Table_Value    : Runtime.SST_Access;
      Table_Read     : Runtime.SST_Access;
      Table_Image    : Runtime.Image_Access;
      Table_Head     : Runtime.SST_Header_Admission;
      Allocation     : Runtime.Allocation_Status;
      Encode_Status  : Runtime.Encode_Status;
      Decode_Status  : Runtime.Decode_Status;
      Descriptor     : constant Runtime.Run_Descriptor :=
        (Run_ID                => ID (9),
         Lowest_Sequence       => 1,
         Highest_Sequence      => 2,
         Entry_Total           => 3,
         Logical_Payload_Bytes => 4);
   begin
      Runtime.Create_Checkpoint_Manifest (1, 1, 2, Manifest_Value, Allocation);
      if Allocation /= Runtime.Allocated then
         raise Program_Error with "runtime manifest fixture allocation failed";
      end if;
      Manifest_Value.Base := Base_Manifest;
      Manifest_Value.Replay_Boundary := 2;
      Manifest_Value.Maximum_Total_L0_Runs := 2;
      Manifest_Value.Maximum_Checkpoint_Identities := 4;
      Manifest_Value.Maximum_Point_Reads_Per_Transaction := 8;
      Manifest_Value.Maximum_Scan_Ranges_Per_Transaction := 4;
      Manifest_Value.Families (1) :=
        (Memtable_Max_Bytes   => 4 * 1_024,
         Memtable_Max_Entries => 16,
         Maximum_L0_Runs      => 2,
         First_Run            => 1,
         Run_Total            => 1);
      Manifest_Value.Runs (1) := Descriptor;
      Manifest_Value.Identities := [ID (10), ID (11)];
      Runtime.Encode_Checkpoint_Manifest (Manifest_Value.all, Manifest_Image, Encode_Status);
      if Encode_Status /= Runtime.Encoded or else Manifest_Image.all /= Manifest_Golden then
         raise Program_Error with "runtime manifest differs from proven golden";
      end if;
      Runtime.Inspect_Checkpoint_Manifest_Header
        (Manifest_Golden (0 .. Runtime.LSM.Checkpoint_Manifest_Header_Length - 1),
         ID (1),
         Manifest_Golden'Length,
         Manifest_Head,
         Decode_Status);
      --  Derived upper bound: envelope/trailer + one maximum-name family +
      --  two admitted runs + two actual identities. It is not a product cap.
      if Decode_Status /= Runtime.Decoded
        or else Manifest_Head.Object_Length /= Manifest_Length
        or else Manifest_Head.Format_Version /= Runtime.LSM.Checkpoint_Manifest_Format_Version
        or else Manifest_Head.Header_Length /= Runtime.LSM.Checkpoint_Manifest_Header_Length
        or else Manifest_Head.Maximum_Point_Reads_Per_Transaction /= 8
        or else Manifest_Head.Maximum_Scan_Ranges_Per_Transaction /= 4
        or else Manifest_Head.Maximum_Object_Length /= 232 + 307 + 96 + 32
      then
         raise Program_Error with "runtime manifest header admission mismatch";
      end if;
      Runtime.Inspect_Checkpoint_Manifest_Header
        (Previous_Manifest_Golden (0 .. Runtime.LSM.Previous_Checkpoint_Manifest_Header_Length - 1),
         ID (1),
         Previous_Manifest_Golden'Length,
         Manifest_Head,
         Decode_Status);
      if Decode_Status /= Runtime.Decoded
        or else Manifest_Head.Format_Version
                /= Runtime.LSM.Previous_Checkpoint_Manifest_Format_Version
        or else Manifest_Head.Header_Length
                /= Runtime.LSM.Previous_Checkpoint_Manifest_Header_Length
        or else Manifest_Head.Maximum_Point_Reads_Per_Transaction /= 0
        or else Manifest_Head.Maximum_Scan_Ranges_Per_Transaction /= 0
      then
         raise Program_Error with "runtime manifest-v2 exact header admission changed";
      end if;
      Runtime.Inspect_Checkpoint_Manifest_Header
        (Previous_Manifest_Golden (0 .. Runtime.LSM.Previous_Checkpoint_Manifest_Header_Length + 3),
         ID (1),
         Previous_Manifest_Golden'Length,
         Manifest_Head,
         Decode_Status);
      if Decode_Status /= Runtime.Invalid_Length then
         raise Program_Error with "runtime manifest accepted an intermediate header extent";
      end if;
      Runtime.Decode_Checkpoint_Manifest (Manifest_Golden, ID (1), Manifest_Read, Decode_Status);
      if Decode_Status /= Runtime.Decoded
        or else not Runtime.Structurally_Valid (Manifest_Read.all)
        or else Manifest_Read.Run_Total /= 1
        or else Manifest_Read.Identity_Total /= 2
        or else Manifest_Read.Maximum_Point_Reads_Per_Transaction /= 8
        or else Manifest_Read.Maximum_Scan_Ranges_Per_Transaction /= 4
      then
         raise Program_Error with "runtime manifest golden did not round-trip";
      end if;

      Runtime.Release (Manifest_Read);
      Runtime.Decode_Checkpoint_Manifest (Previous_Manifest_Golden, ID (1), Manifest_Read, Decode_Status);
      if Decode_Status /= Runtime.Decoded
        or else not Runtime.Structurally_Valid (Manifest_Read.all)
        or else Manifest_Read.Maximum_Point_Reads_Per_Transaction /= 0
        or else Manifest_Read.Maximum_Scan_Ranges_Per_Transaction /= 0
      then
         raise Program_Error with "runtime manifest-v2 backward read changed";
      end if;

      Runtime.Create_SST (3, 4, Table_Value, Allocation);
      if Allocation /= Runtime.Allocated then
         raise Program_Error with "runtime SST fixture allocation failed";
      end if;
      Table_Value.Database_ID := ID (1);
      Table_Value.Run_ID := ID (9);
      Table_Value.Family_ID := 1;
      Table_Value.Lowest_Sequence := 1;
      Table_Value.Highest_Sequence := 2;
      Table_Value.Logical_Payload_Bytes := 4;
      Table_Value.Payload :=
        [Character'Pos ('a'), Character'Pos ('x'), Character'Pos ('a'), Character'Pos ('b')];
      Table_Value.Entries (1) :=
        (Sequence         => 2,
         Operation        => Runtime.LSM.Put_Operation,
         Key_Offset       => 1,
         Key_Byte_Total   => 1,
         Value_Offset     => 2,
         Value_Byte_Total => 1);
      Table_Value.Entries (2) :=
        (Sequence         => 1,
         Operation        => Runtime.LSM.Delete_Operation,
         Key_Offset       => 3,
         Key_Byte_Total   => 1,
         Value_Offset     => 4,
         Value_Byte_Total => 0);
      Table_Value.Entries (3) :=
        (Sequence         => 2,
         Operation        => Runtime.LSM.Put_Operation,
         Key_Offset       => 4,
         Key_Byte_Total   => 1,
         Value_Offset     => 5,
         Value_Byte_Total => 0);
      Runtime.Encode_SST (Table_Value.all, Table_Image, Encode_Status);
      if Encode_Status /= Runtime.Encoded or else Table_Image.all /= SST_Golden then
         if Encode_Status = Runtime.Encoded and then Table_Image.all'Length = SST_Golden'Length then
            for Index in SST_Golden'Range loop
               if Table_Image (Index) /= SST_Golden (Index) then
                  raise Program_Error
                    with
                      "runtime SST differs at byte"
                      & Natural'Image (Index)
                      & " actual="
                      & Formats.Byte'Image (Table_Image (Index))
                      & " expected="
                      & Formats.Byte'Image (SST_Golden (Index));
               end if;
            end loop;
         end if;
         raise Program_Error
           with
             "runtime SST differs from proven golden: status="
             & Runtime.Encode_Status'Image (Encode_Status)
             & " length="
             & Natural'Image ((if Table_Image = null then 0 else Table_Image.all'Length));
      end if;
      Runtime.Inspect_SST_Header
        (SST_Golden (0 .. Runtime.LSM.SST_Header_Length - 1),
         ID (1),
         1,
         Descriptor,
         SST_Golden'Length,
         Table_Head,
         Decode_Status);
      if Decode_Status /= Runtime.Decoded
        or else Table_Head.Object_Length /= SST_Length
        or else Table_Head.Entry_Total /= 3
        or else Table_Head.Payload_Bytes /= 4
      then
         raise Program_Error with "runtime SST header admission mismatch";
      end if;
      Runtime.Decode_SST (SST_Golden, ID (1), 1, Descriptor, 8, 8, Table_Read, Decode_Status);
      if Decode_Status /= Runtime.Decoded
        or else not Runtime.Structurally_Valid (Table_Read.all)
        or else not Runtime.Descriptor_Matches (Table_Read.all, ID (1), 1, Descriptor)
      then
         raise Program_Error with "runtime SST golden did not round-trip";
      end if;

      declare
         --  Nonzero lower bounds verify that operational parsing is positional;
         --  these test shifts are not persisted offsets or allocation policy.
         Shifted_Manifest       : constant Formats.Byte_Array (7 .. 7 + Manifest_Length - 1) :=
           Manifest_Golden;
         Shifted_SST            : constant Formats.Byte_Array (11 .. 11 + SST_Length - 1) := SST_Golden;
         Shifted_Manifest_Value : Runtime.Checkpoint_Manifest_Access;
         Shifted_Table_Value    : Runtime.SST_Access;
      begin
         Runtime.Decode_Checkpoint_Manifest (Shifted_Manifest, ID (1), Shifted_Manifest_Value, Decode_Status);
         if Decode_Status /= Runtime.Decoded then
            raise Program_Error with "runtime manifest rejected shifted lower bound";
         end if;
         Runtime.Decode_SST (Shifted_SST, ID (1), 1, Descriptor, 8, 8, Shifted_Table_Value, Decode_Status);
         if Decode_Status /= Runtime.Decoded then
            Runtime.Release (Shifted_Manifest_Value);
            raise Program_Error with "runtime SST rejected shifted lower bound";
         end if;
         Runtime.Release (Shifted_Manifest_Value);
         Runtime.Release (Shifted_Table_Value);
      end;

      Runtime.Release (Manifest_Image);
      Runtime.Release (Manifest_Read);
      Runtime.Release (Manifest_Value);
      Runtime.Release (Table_Image);
      Runtime.Release (Table_Read);
      Runtime.Release (Table_Value);
   exception
      when others =>
         Runtime.Release (Manifest_Image);
         Runtime.Release (Manifest_Read);
         Runtime.Release (Manifest_Value);
         Runtime.Release (Table_Image);
         Runtime.Release (Table_Read);
         Runtime.Release (Table_Value);
         raise;
   end Test_Runtime_Golden_Parity;

   procedure Test_Runtime_Persisted_Limits is
      --  One beyond the retired 64/256 toy bounds demonstrates that the
      --  operational codec follows the explicit persisted family values below.
      --  These are regression-fixture dimensions, not replacement defaults.
      Key_Total      : constant := 65;
      Value_Total    : constant := 257;
      Payload_Total  : constant := Key_Total + Value_Total;
      Table_Value    : Runtime.SST_Access;
      Table_Read     : Runtime.SST_Access;
      Image          : Runtime.Image_Access;
      Manifest       : Runtime.Checkpoint_Manifest_Access;
      Manifest_Read  : Runtime.Checkpoint_Manifest_Access;
      Manifest_Image : Runtime.Image_Access;
      Allocation     : Runtime.Allocation_Status;
      Encode_Status  : Runtime.Encode_Status;
      Decode_Status  : Runtime.Decode_Status;
      Descriptor     : constant Runtime.Run_Descriptor :=
        (Run_ID                => ID (20),
         Lowest_Sequence       => 7,
         Highest_Sequence      => 7,
         Entry_Total           => 1,
         Logical_Payload_Bytes => Payload_Total);
   begin
      Runtime.Create_SST (1, Payload_Total, Table_Value, Allocation);
      if Allocation /= Runtime.Allocated then
         raise Program_Error with "persisted-limit SST allocation failed";
      end if;
      Table_Value.Database_ID := ID (1);
      Table_Value.Run_ID := Descriptor.Run_ID;
      Table_Value.Family_ID := 1;
      Table_Value.Lowest_Sequence := 7;
      Table_Value.Highest_Sequence := 7;
      Table_Value.Logical_Payload_Bytes := Payload_Total;
      Table_Value.Entries (1) :=
        (Sequence         => 7,
         Operation        => Runtime.LSM.Put_Operation,
         Key_Offset       => 1,
         Key_Byte_Total   => Key_Total,
         Value_Offset     => Key_Total + 1,
         Value_Byte_Total => Value_Total);
      Table_Value.Payload (1 .. Key_Total) := [others => Character'Pos ('k')];
      Table_Value.Payload (Key_Total + 1 .. Payload_Total) := [others => Character'Pos ('v')];
      Runtime.Encode_SST (Table_Value.all, Image, Encode_Status);
      if Encode_Status /= Runtime.Encoded then
         raise Program_Error with "persisted-limit SST did not encode";
      end if;
      Runtime.Decode_SST
        (Image.all, ID (1), 1, Descriptor, Key_Total, Value_Total, Table_Read, Decode_Status);
      if Decode_Status /= Runtime.Decoded
        or else Table_Read.Entries (1).Key_Byte_Total /= Key_Total
        or else Table_Read.Entries (1).Value_Byte_Total /= Value_Total
        or else Table_Read.Payload /= Table_Value.Payload
      then
         raise Program_Error with "persisted family bounds did not size runtime SST";
      end if;

      --  Three runs and five identities exceed this test's bounded proof-oracle
      --  instance (2/4). Persisted maxima authorize the exact runtime shape;
      --  the values remain coverage choices, not production defaults.
      Runtime.Create_Checkpoint_Manifest (1, 3, 5, Manifest, Allocation);
      if Allocation /= Runtime.Allocated then
         raise Program_Error with "persisted-limit manifest allocation failed";
      end if;
      Manifest.Base := Base_Manifest;
      Manifest.Replay_Boundary := 3;
      Manifest.Maximum_Total_L0_Runs := 3;
      Manifest.Maximum_Checkpoint_Identities := 5;
      --  Persisted caller authority also sizes later serializable observations.
      Manifest.Maximum_Point_Reads_Per_Transaction := 8;
      Manifest.Maximum_Scan_Ranges_Per_Transaction := 4;
      Manifest.Families (1) :=
        (Memtable_Max_Bytes   => 4 * 1_024,
         Memtable_Max_Entries => 16,
         Maximum_L0_Runs      => 3,
         First_Run            => 1,
         Run_Total            => 3);
      for Index in Manifest.Runs'Range loop
         Manifest.Runs (Index) :=
           (Run_ID                => ID (Interfaces.Unsigned_8 (20 + Index)),
            Lowest_Sequence       => Interfaces.Unsigned_64 (Index),
            Highest_Sequence      => Interfaces.Unsigned_64 (Index),
            Entry_Total           => 1,
            Logical_Payload_Bytes => 1);
      end loop;
      for Index in Manifest.Identities'Range loop
         Manifest.Identities (Index) := ID (Interfaces.Unsigned_8 (30 + Index));
      end loop;
      Runtime.Encode_Checkpoint_Manifest (Manifest.all, Manifest_Image, Encode_Status);
      if Encode_Status /= Runtime.Encoded then
         raise Program_Error with "persisted-limit manifest did not encode";
      end if;
      Runtime.Decode_Checkpoint_Manifest (Manifest_Image.all, ID (1), Manifest_Read, Decode_Status);
      if Decode_Status /= Runtime.Decoded
        or else Manifest_Read.Run_Total /= 3
        or else Manifest_Read.Identity_Total /= 5
      then
         raise Program_Error with "persisted run/identity limits did not size runtime manifest";
      end if;

      Runtime.Release (Image);
      Runtime.Release (Table_Read);
      Runtime.Release (Table_Value);
      Runtime.Release (Manifest_Image);
      Runtime.Release (Manifest_Read);
      Runtime.Release (Manifest);
   exception
      when others =>
         Runtime.Release (Image);
         Runtime.Release (Table_Read);
         Runtime.Release (Table_Value);
         Runtime.Release (Manifest_Image);
         Runtime.Release (Manifest_Read);
         Runtime.Release (Manifest);
         raise;
   end Test_Runtime_Persisted_Limits;

   procedure Test_Runtime_Rejection is
      --  Corruption positions use the frozen manifest-v3 table: identity count
      --  212, family run count 272, run high sequence 306, and ledger
      --  identities 330/346. They are compatibility offsets, not test policy.
      Corrupt_Manifest : Formats.Byte_Array (Manifest_Golden'Range) := Manifest_Golden;
      Corrupt_SST      : Formats.Byte_Array (SST_Golden'Range) := SST_Golden;
      Manifest_Value   : Runtime.Checkpoint_Manifest_Access;
      Table_Value      : Runtime.SST_Access;
      Allocation       : Runtime.Allocation_Status;
      Decode_Status    : Runtime.Decode_Status;
      Descriptor       : constant Runtime.Run_Descriptor :=
        (Run_ID                => ID (9),
         Lowest_Sequence       => 1,
         Highest_Sequence      => 2,
         Entry_Total           => 3,
         Logical_Payload_Bytes => 4);
   begin
      --  Natural'Last is the qualified host representation boundary and must
      --  be rejected before an unencodable SST allocation is attempted.
      Runtime.Create_SST (1, Natural'Last, Table_Value, Allocation);
      if Allocation /= Runtime.Invalid_Extent or else Table_Value /= null then
         raise Program_Error with "runtime SST builder allocated an unencodable extent";
      end if;

      Corrupt_Manifest (308) := Corrupt_Manifest (308) xor 1;
      Runtime.Decode_Checkpoint_Manifest (Corrupt_Manifest, ID (1), Manifest_Value, Decode_Status);
      if Decode_Status /= Runtime.Object_Checksum_Failed or else Manifest_Value /= null then
         raise Program_Error with "runtime manifest corruption published partial state";
      end if;

      Corrupt_Manifest := Manifest_Golden;
      Put_U32 (Corrupt_Manifest, 212, 5);
      Repair_Checksums (Corrupt_Manifest, Runtime.LSM.Checkpoint_Manifest_Header_Length);
      Runtime.Decode_Checkpoint_Manifest (Corrupt_Manifest, ID (1), Manifest_Value, Decode_Status);
      if Decode_Status /= Runtime.Invalid_Manifest_State or else Manifest_Value /= null then
         raise Program_Error with "runtime manifest accepted identity count above persisted maximum";
      end if;

      Corrupt_Manifest := Manifest_Golden;
      Put_U32 (Corrupt_Manifest, 272, 3);
      Repair_Checksums (Corrupt_Manifest, Runtime.LSM.Checkpoint_Manifest_Header_Length);
      Runtime.Decode_Checkpoint_Manifest (Corrupt_Manifest, ID (1), Manifest_Value, Decode_Status);
      if Decode_Status /= Runtime.Invalid_Manifest_State or else Manifest_Value /= null then
         raise Program_Error with "runtime manifest accepted run count above family maximum";
      end if;

      Corrupt_Manifest := Manifest_Golden;
      Put_U64 (Corrupt_Manifest, 306, 3);
      Repair_Checksums (Corrupt_Manifest, Runtime.LSM.Checkpoint_Manifest_Header_Length);
      Runtime.Decode_Checkpoint_Manifest (Corrupt_Manifest, ID (1), Manifest_Value, Decode_Status);
      if Decode_Status /= Runtime.Invalid_Manifest_State or else Manifest_Value /= null then
         raise Program_Error with "runtime manifest allocated before replay validation";
      end if;

      Corrupt_Manifest := Manifest_Golden;
      Corrupt_Manifest (346 .. 361) := Corrupt_Manifest (330 .. 345);
      Repair_Checksums (Corrupt_Manifest, Runtime.LSM.Checkpoint_Manifest_Header_Length);
      Runtime.Decode_Checkpoint_Manifest (Corrupt_Manifest, ID (1), Manifest_Value, Decode_Status);
      if Decode_Status /= Runtime.Invalid_Identity or else Manifest_Value /= null then
         raise Program_Error with "runtime manifest allocated before identity ordering validation";
      end if;

      Corrupt_SST (117) := Corrupt_SST (117) xor 1;
      Runtime.Decode_SST (Corrupt_SST, ID (1), 1, Descriptor, 8, 8, Table_Value, Decode_Status);
      if Decode_Status /= Runtime.Object_Checksum_Failed or else Table_Value /= null then
         raise Program_Error with "runtime SST corruption published partial state";
      end if;
      Runtime.Decode_SST (SST_Golden, ID (1), 1, Descriptor, 0, 8, Table_Value, Decode_Status);
      if Decode_Status /= Runtime.Limit_Exceeded or else Table_Value /= null then
         raise Program_Error with "runtime SST family key limit was not enforced before allocation";
      end if;
   end Test_Runtime_Rejection;

   procedure Run is
   begin
      if not LSM.Structurally_Valid (Checkpoint) or else not LSM.Structurally_Valid (Table) then
         raise Program_Error with "LSM fixture is not structurally valid";
      end if;
      Test_Goldens_And_Extents;
      Test_Manifest_Rejection;
      Test_SST_Rejection;
      Test_Runtime_Golden_Parity;
      Test_Runtime_Persisted_Limits;
      Test_Runtime_Rejection;
   end Run;

end Flyology.DB.LSM_Format_Tests;
