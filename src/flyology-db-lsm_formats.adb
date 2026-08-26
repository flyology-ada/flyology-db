package body Flyology.DB.LSM_Formats
  with SPARK_Mode => On
is

   package body Reference
     with SPARK_Mode => On
   is

      use type Formats.Byte;
      use type Formats.Byte_Array;
      use type Interfaces.Unsigned_16;

      --  Manifest v3 intentionally retains the frozen FLYCFM01 kind magic so
      --  its independent version field selects the compatible layout.
      Manifest_Magic : constant Formats.Byte_Array (0 .. 7) :=
        [Character'Pos ('F'),
         Character'Pos ('L'),
         Character'Pos ('Y'),
         Character'Pos ('C'),
         Character'Pos ('F'),
         Character'Pos ('M'),
         Character'Pos ('0'),
         Character'Pos ('1')];

      --  FLYSST01 is the accepted SST-v1 magic frozen by the persisted-format
      --  table; changing it requires a new compatibility decision and golden.
      SST_Magic : constant Formats.Byte_Array (0 .. 7) :=
        [Character'Pos ('F'),
         Character'Pos ('L'),
         Character'Pos ('Y'),
         Character'Pos ('S'),
         Character'Pos ('S'),
         Character'Pos ('T'),
         Character'Pos ('0'),
         Character'Pos ('1')];

      --  Canonical zero values define unused fixed-array tails in the bounded
      --  reference representation; they are not persisted sentinels. Accepting
      --  another tail would let distinct records encode as identical bytes.
      Empty_Run    : constant Run_Descriptor := (others => <>);
      Empty_Family : constant Family_LSM_State := (others => <>);
      Empty_Entry  : constant SST_Entry := (others => <>);

      --  Common-envelope arithmetic: these helpers implement frozen
      --  big-endian U16/U32/U64 fields and the inherited 16-byte identifier.
      --  Loop widths and 16#FF# masks are derived, not resource policy.
      procedure Put_U16
        (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_16)
      with Pre => Image'First = 0 and then Image'Length >= 2 and then Position <= Image'Last - 1;

      procedure Put_U32
        (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_32)
      with Pre => Image'First = 0 and then Image'Length >= 4 and then Position <= Image'Last - 3;

      procedure Put_U64
        (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_64)
      with Pre => Image'First = 0 and then Image'Length >= 8 and then Position <= Image'Last - 7;

      function Read_U16 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_16
      with Pre => Image'First = 0 and then Image'Length >= 2 and then Position <= Image'Last - 1;

      function Read_U32 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_32
      with Pre => Image'First = 0 and then Image'Length >= 4 and then Position <= Image'Last - 3;

      function Read_U64 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_64
      with Pre => Image'First = 0 and then Image'Length >= 8 and then Position <= Image'Last - 7;

      procedure Put_Identifier
        (Image : in out Formats.Byte_Array; Position : Natural; Value : Head_Policy.Identifier)
      with
        Pre =>
          Image'First = 0
          and then Image'Length >= Head_Policy.Identifier_Length
          and then Position <= Image'Last - Head_Policy.Identifier_Length + 1;

      function Read_Identifier (Image : Formats.Byte_Array; Position : Natural) return Head_Policy.Identifier
      with
        Pre =>
          Image'First = 0
          and then Image'Length >= Head_Policy.Identifier_Length
          and then Position <= Image'Last - Head_Policy.Identifier_Length + 1;

      procedure Put_U16
        (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_16) is
      begin
         Image (Position) := Formats.Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);
         Image (Position + 1) := Formats.Byte (Value and 16#FF#);
      end Put_U16;

      procedure Put_U32
        (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_32) is
      begin
         for Offset in Natural range 0 .. 3 loop
            Image (Position + Offset) :=
              Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
         end loop;
      end Put_U32;

      procedure Put_U64
        (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_64) is
      begin
         for Offset in Natural range 0 .. 7 loop
            Image (Position + Offset) :=
              Formats.Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
         end loop;
      end Put_U64;

      function Read_U16 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_16 is
      begin
         return
           Interfaces.Shift_Left (Interfaces.Unsigned_16 (Image (Position)), 8)
           or Interfaces.Unsigned_16 (Image (Position + 1));
      end Read_U16;

      function Read_U32 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_32 is
         Result : Interfaces.Unsigned_32 := 0;
      begin
         for Offset in Natural range 0 .. 3 loop
            Result := Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_32 (Image (Position + Offset));
         end loop;
         return Result;
      end Read_U32;

      function Read_U64 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_64 is
         Result : Interfaces.Unsigned_64 := 0;
      begin
         for Offset in Natural range 0 .. 7 loop
            Result := Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_64 (Image (Position + Offset));
         end loop;
         return Result;
      end Read_U64;

      procedure Put_Identifier
        (Image : in out Formats.Byte_Array; Position : Natural; Value : Head_Policy.Identifier) is
      begin
         for Index in Head_Policy.Identifier_Index loop
            Image (Position + (Index - Head_Policy.Identifier_Index'First)) := Value (Index);
         end loop;
      end Put_Identifier;

      function Read_Identifier (Image : Formats.Byte_Array; Position : Natural) return Head_Policy.Identifier
      is
         Result : Head_Policy.Identifier;
      begin
         for Index in Head_Policy.Identifier_Index loop
            Result (Index) := Image (Position + (Index - Head_Policy.Identifier_Index'First));
         end loop;
         return Result;
      end Read_Identifier;

      function Manifest_Header_Checksum (Image : Checkpoint_Manifest_Image) return Interfaces.Unsigned_32 is
         Header : Formats.Byte_Array (0 .. Checkpoint_Manifest_Header_Length - 1) :=
           Image (0 .. Checkpoint_Manifest_Header_Length - 1);
      begin
         --  Common-envelope bytes 40..43 are the frozen header-CRC field and
         --  are zeroed during calculation. Moving them is wire-incompatible.
         Header (40 .. 43) := [others => 0];
         return Formats.CRC_32C (Header);
      end Manifest_Header_Checksum;

      function SST_Header_Checksum (Image : SST_Image) return Interfaces.Unsigned_32 is
         Header : Formats.Byte_Array (0 .. SST_Header_Length - 1) := Image (0 .. SST_Header_Length - 1);
      begin
         --  SST uses the same frozen header-CRC bytes 40..43 and covers its
         --  exact 96-byte header with that field zeroed.
         Header (40 .. 43) := [others => 0];
         return Formats.CRC_32C (Header);
      end SST_Header_Checksum;

      function Identifier_Less (Left, Right : Head_Policy.Identifier) return Boolean is
      begin
         for Index in Head_Policy.Identifier_Index loop
            if Left (Index) < Right (Index) then
               return True;
            elsif Left (Index) > Right (Index) then
               return False;
            end if;
         end loop;
         return False;
      end Identifier_Less;

      function Same_Key (Left, Right : SST_Entry) return Boolean is
      begin
         if Left.Key_Byte_Total /= Right.Key_Byte_Total then
            return False;
         end if;
         for Index in Natural range 1 .. Left.Key_Byte_Total loop
            if Left.Key (Index) /= Right.Key (Index) then
               return False;
            end if;
         end loop;
         return True;
      end Same_Key;

      function Key_Less (Left, Right : SST_Entry) return Boolean is
         --  Derived comparison span: only the shorter exact key prefix can be
         --  equal; it is algorithmic and introduces no key-size policy.
         Common : constant Natural := Natural'Min (Left.Key_Byte_Total, Right.Key_Byte_Total);
      begin
         for Index in Natural range 1 .. Common loop
            if Left.Key (Index) < Right.Key (Index) then
               return True;
            elsif Left.Key (Index) > Right.Key (Index) then
               return False;
            end if;
         end loop;
         return Left.Key_Byte_Total < Right.Key_Byte_Total;
      end Key_Less;

      function Canonical_Entry_Tails (Value : SST_Entry) return Boolean is
      begin
         for Index in Key_Index loop
            if Index > Value.Key_Byte_Total and then Value.Key (Index) /= 0 then
               return False;
            end if;
         end loop;
         for Index in Value_Index loop
            if Index > Value.Value_Byte_Total and then Value.Value (Index) /= 0 then
               return False;
            end if;
         end loop;
         return True;
      end Canonical_Entry_Tails;

      function Entry_Logical_Bytes (Value : SST_Entry) return Interfaces.Unsigned_64
      is (Interfaces.Unsigned_64 (Value.Key_Byte_Total)
          + (if Value.Operation = Put_Operation then Interfaces.Unsigned_64 (Value.Value_Byte_Total) else 0));

      function Valid_Entry (Value : SST_Entry) return Boolean
      is (Value.Sequence > 0
          and then Value.Operation in Put_Operation | Delete_Operation
          and then (if Value.Operation = Delete_Operation then Value.Value_Byte_Total = 0)
          and then Canonical_Entry_Tails (Value));

      function Valid_Run_Descriptor (Value : Run_Descriptor) return Boolean
      is (not Head_Policy.Is_Zero (Value.Run_ID)
          and then Value.Lowest_Sequence > 0
          and then Value.Lowest_Sequence <= Value.Highest_Sequence
          and then Value.Entry_Total > 0);

      function Structurally_Valid (Value : Checkpoint_Manifest) return Boolean is
         --  Zero is the additive identity for the checked aggregate run count,
         --  not an admitted-run default or ceiling.
         Total_Runs : Natural := 0;
      begin
         if not Manifests.Structurally_Valid (Value.Base)
           or else Value.Maximum_Total_L0_Runs = 0
           or else Value.Maximum_Checkpoint_Identities = 0
           or else Value.Maximum_Point_Reads_Per_Transaction = 0
           or else Value.Maximum_Scan_Ranges_Per_Transaction = 0
           or else Interfaces.Unsigned_64 (Value.Identity_Total)
                   > Interfaces.Unsigned_64 (Value.Maximum_Checkpoint_Identities)
         then
            return False;
         end if;

         for Family_Index in Manifests.Family_Slot range 1 .. Value.Base.Family_Total loop
            declare
               State : Family_LSM_State renames Value.Family_LSM (Family_Index);
            begin
               if State.Memtable_Max_Bytes = 0
                 or else State.Memtable_Max_Entries = 0
                 or else State.Maximum_L0_Runs = 0
                 or else Interfaces.Unsigned_64 (State.Run_Total)
                         > Interfaces.Unsigned_64 (State.Maximum_L0_Runs)
               then
                  return False;
               end if;
               if State.Run_Total > Natural'Last - Total_Runs then
                  return False;
               end if;
               Total_Runs := Total_Runs + State.Run_Total;
               for Run_Index in Run_Slot range 1 .. State.Run_Total loop
                  declare
                     Item : Run_Descriptor renames State.Runs (Run_Index);
                  begin
                     if not Valid_Run_Descriptor (Item)
                       or else Item.Highest_Sequence > Value.Replay_Boundary
                       or else (Run_Index > 1
                                and then State.Runs (Run_Index - 1).Highest_Sequence >= Item.Lowest_Sequence)
                     then
                        return False;
                     end if;
                     for Earlier_Family in Manifests.Family_Slot range 1 .. Family_Index loop
                        declare
                           --  Derived duplicate-scan bound: prior families use
                           --  all runs; the current family stops before Item.
                           Last_Run : constant Natural :=
                             (if Earlier_Family = Family_Index
                              then Run_Index - 1
                              else Value.Family_LSM (Earlier_Family).Run_Total);
                        begin
                           for Earlier_Run in Natural range 1 .. Last_Run loop
                              if Value.Family_LSM (Earlier_Family).Runs (Earlier_Run).Run_ID = Item.Run_ID
                              then
                                 return False;
                              end if;
                           end loop;
                        end;
                     end loop;
                  end;
               end loop;
               for Run_Index in Run_Slot loop
                  if Run_Index > State.Run_Total and then State.Runs (Run_Index) /= Empty_Run then
                     return False;
                  end if;
               end loop;
            end;
         end loop;

         for Family_Index in Manifests.Family_Slot loop
            if Family_Index > Value.Base.Family_Total and then Value.Family_LSM (Family_Index) /= Empty_Family
            then
               return False;
            end if;
         end loop;

         if Interfaces.Unsigned_64 (Total_Runs) > Interfaces.Unsigned_64 (Value.Maximum_Total_L0_Runs)
           or else (Value.Replay_Boundary = 0 and then (Total_Runs /= 0 or else Value.Identity_Total /= 0))
         then
            return False;
         end if;

         for Index in Identity_Slot range 1 .. Value.Identity_Total loop
            if Head_Policy.Is_Zero (Value.Identities (Index))
              or else (Index > 1
                       and then not Identifier_Less (Value.Identities (Index - 1), Value.Identities (Index)))
            then
               return False;
            end if;
         end loop;
         for Index in Identity_Slot loop
            if Index > Value.Identity_Total and then not Head_Policy.Is_Zero (Value.Identities (Index)) then
               return False;
            end if;
         end loop;
         return True;
      end Structurally_Valid;

      function Checkpoint_Manifest_Encoded_Length (Value : Checkpoint_Manifest) return Natural is
         --  Proof arithmetic derives these maxima from the frozen header,
         --  family/run widths, and caller-selected reference capacities. They
         --  add no format or database policy ceiling.
         Base_Length             : constant Natural :=
           Checkpoint_Manifest_Header_Length + Object_Trailer_Length;
         Maximum_Family_Length   : constant Natural :=
           Checkpoint_Family_Header_Length
           + Manifests.Max_Family_Name_Bytes
           + Maximum_Runs_Per_Family * Run_Descriptor_Length;
         Maximum_Identity_Length : constant Natural := Maximum_Identities * Head_Policy.Identifier_Length;
         Result                  : Natural := Base_Length;
      begin
         for Index in Manifests.Family_Slot range 1 .. Value.Base.Family_Total loop
            declare
               --  Exact persisted extent of this family frame: frozen prefix,
               --  actual name bytes, and actual fixed-width run descriptors.
               Family_Length : constant Natural :=
                 Checkpoint_Family_Header_Length
                 + Value.Base.Families (Index).Name_Length
                 + Value.Family_LSM (Index).Run_Total * Run_Descriptor_Length;
            begin
               pragma Assert (Family_Length <= Maximum_Family_Length);
               Result := Result + Family_Length;
            end;
            pragma Loop_Invariant (Result <= Base_Length + Natural (Index) * Maximum_Family_Length);
         end loop;
         pragma Assert (Result <= Max_Checkpoint_Manifest_Image_Length - Maximum_Identity_Length);
         return Result + Value.Identity_Total * Head_Policy.Identifier_Length;
      end Checkpoint_Manifest_Encoded_Length;

      procedure Encode_Checkpoint_Manifest
        (Value  : Checkpoint_Manifest;
         Image  : out Checkpoint_Manifest_Image;
         Length : out Natural;
         Status : out Encode_Status)
      is
         --  Cursor invariants use the same frozen-width/generic-capacity
         --  formulas as Max_Checkpoint_Manifest_Image_Length; divergence would
         --  invalidate exact extent and therefore must fail proof/qualification.
         Maximum_Family_Length   : constant Natural :=
           Checkpoint_Family_Header_Length
           + Manifests.Max_Family_Name_Bytes
           + Maximum_Runs_Per_Family * Run_Descriptor_Length;
         Maximum_Identity_Length : constant Natural := Maximum_Identities * Head_Policy.Identifier_Length;
         Cursor                  : Natural := Checkpoint_Manifest_Header_Length;
      begin
         Image := [others => 0];
         Length := 0;
         if not Structurally_Valid (Value) then
            Status := Invalid_Value;
            return;
         end if;
         Length := Checkpoint_Manifest_Encoded_Length (Value);
         if Length < Checkpoint_Manifest_Header_Length + Object_Trailer_Length or else Length > Image'Length
         then
            Image := [others => 0];
            Length := 0;
            Status := Invalid_Value;
            return;
         end if;
         --  Frozen common-envelope offsets: magic 0, version 8, kind 10,
         --  flags 11, database 12, header length 28, payload length 32, and
         --  header CRC 40. Flags and reserved fields are mandated zero.
         Image (0 .. 7) := Manifest_Magic;
         Put_U16 (Image, 8, Checkpoint_Manifest_Format_Version);
         Image (10) := Manifests.Manifest_Object_Kind;
         Image (11) := 0;
         Put_Identifier (Image, 12, Value.Base.Database_ID);
         Put_U32 (Image, 28, Interfaces.Unsigned_32 (Checkpoint_Manifest_Header_Length));
         Put_U64
           (Image,
            32,
            Interfaces.Unsigned_64 (Length - Checkpoint_Manifest_Header_Length - Object_Trailer_Length));
         --  Frozen inherited offsets: identities 44/60/76/100, transition
         --  numbers 92/116, epoch 124, registry 132, v1 counts/limits 140..188,
         --  then replay/run/identity fields 196..216. Version 3 appends exact
         --  point/range count authority at 220/224.
         Put_Identifier (Image, 44, Value.Base.Manifest_ID);
         Put_Identifier (Image, 60, Value.Base.Previous_Manifest_ID);
         Put_Identifier (Image, 76, Value.Base.Expected_Transition_ID);
         Put_U64 (Image, 92, Value.Base.Expected_Transition_Number);
         Put_Identifier (Image, 100, Value.Base.Publication_Transition_ID);
         Put_U64 (Image, 116, Value.Base.Publication_Transition_Number);
         Put_U64 (Image, 124, Value.Base.Writer_Epoch);
         Put_U64 (Image, 132, Value.Base.Registry_Revision);
         Put_U32 (Image, 140, Interfaces.Unsigned_32 (Value.Base.Family_Total));
         Put_U32 (Image, 144, Value.Base.Limits.Maximum_Column_Families);
         Put_U32 (Image, 148, Value.Base.Limits.Maximum_Manifest_History);
         Put_U32 (Image, 152, Value.Base.Limits.Maximum_Batch_History);
         Put_U32 (Image, 156, Value.Base.Limits.Maximum_Transactions_Per_Batch);
         Put_U32 (Image, 160, Value.Base.Limits.Maximum_Mutations_Per_Transaction);
         Put_U32 (Image, 164, Value.Base.Limits.Maximum_Mutations_Per_Batch);
         Put_U32 (Image, 168, Value.Base.Limits.Maximum_Live_Entries);
         Put_U64 (Image, 172, Value.Base.Limits.Maximum_Transaction_Payload_Bytes);
         Put_U64 (Image, 180, Value.Base.Limits.Maximum_Batch_Payload_Bytes);
         Put_U64 (Image, 188, Value.Base.Limits.Maximum_Live_State_Bytes);
         Put_U64 (Image, 196, Value.Replay_Boundary);
         Put_U32 (Image, 204, Value.Maximum_Total_L0_Runs);
         Put_U32 (Image, 208, Value.Maximum_Checkpoint_Identities);
         Put_U32 (Image, 212, Interfaces.Unsigned_32 (Value.Identity_Total));
         Put_U32 (Image, 216, 0);
         Put_U32 (Image, 220, Value.Maximum_Point_Reads_Per_Transaction);
         Put_U32 (Image, 224, Value.Maximum_Scan_Ranges_Per_Transaction);
         Put_U32 (Image, 40, Manifest_Header_Checksum (Image));

         for Family_Index in Manifests.Family_Slot range 1 .. Value.Base.Family_Total loop
            declare
               Base          : Manifests.Column_Family_Configuration renames
                 Value.Base.Families (Family_Index);
               State         : Family_LSM_State renames Value.Family_LSM (Family_Index);
               --  Exact family extent from the current cursor and frozen
               --  prefix/name/run fields; used only to prove image capacity.
               Family_Start  : constant Natural := Cursor;
               Family_Length : constant Natural :=
                 Checkpoint_Family_Header_Length + Base.Name_Length + State.Run_Total * Run_Descriptor_Length;
            begin
               --  Frozen family-relative offsets are 0/4/8/16/24/26 for the
               --  v1 registry frame and 28/36/40/44/48 for v2 LSM fields;
               --  flags and reserved fields stay zero for compatibility.
               pragma Assert (Family_Length <= Maximum_Family_Length);
               pragma
                 Assert
                   (Family_Start
                      <= Max_Checkpoint_Manifest_Image_Length
                         - Object_Trailer_Length
                         - Maximum_Identity_Length
                         - Family_Length);
               Put_U32 (Image, Cursor, Base.ID);
               Put_U32 (Image, Cursor + 4, 0);
               Put_U64 (Image, Cursor + 8, Base.Max_Key_Bytes);
               Put_U64 (Image, Cursor + 16, Base.Max_Value_Bytes);
               Put_U16 (Image, Cursor + 24, Interfaces.Unsigned_16 (Base.Name_Length));
               Put_U16 (Image, Cursor + 26, 0);
               Put_U64 (Image, Cursor + 28, State.Memtable_Max_Bytes);
               Put_U32 (Image, Cursor + 36, State.Memtable_Max_Entries);
               Put_U32 (Image, Cursor + 40, State.Maximum_L0_Runs);
               Put_U32 (Image, Cursor + 44, Interfaces.Unsigned_32 (State.Run_Total));
               Put_U32 (Image, Cursor + 48, 0);
               Cursor := Cursor + Checkpoint_Family_Header_Length;
               for Byte_Index in Manifests.Family_Name_Index range 1 .. Base.Name_Length loop
                  Image (Cursor + Natural (Byte_Index - Manifests.Family_Name_Index'First)) :=
                    Base.Name (Byte_Index);
               end loop;
               Cursor := Cursor + Base.Name_Length;
               for Run_Index in Run_Slot range 1 .. State.Run_Total loop
                  declare
                     Item : Run_Descriptor renames State.Runs (Run_Index);
                  begin
                     --  Frozen run-relative offsets: ID 0, sequences 16/24,
                     --  entry count 32, reserved zero 36, logical bytes 40.
                     Put_Identifier (Image, Cursor, Item.Run_ID);
                     Put_U64 (Image, Cursor + 16, Item.Lowest_Sequence);
                     Put_U64 (Image, Cursor + 24, Item.Highest_Sequence);
                     Put_U32 (Image, Cursor + 32, Item.Entry_Total);
                     Put_U32 (Image, Cursor + 36, 0);
                     Put_U64 (Image, Cursor + 40, Item.Logical_Payload_Bytes);
                     Cursor := Cursor + Run_Descriptor_Length;
                  end;
                  pragma
                    Loop_Invariant
                      (Cursor >= Checkpoint_Manifest_Header_Length
                         and then Cursor
                                  <= Family_Start
                                     + Checkpoint_Family_Header_Length
                                     + Base.Name_Length
                                     + Natural (Run_Index) * Run_Descriptor_Length);
               end loop;
            end;
            pragma
              Loop_Invariant
                (Cursor >= Checkpoint_Manifest_Header_Length
                   and then Cursor
                            <= Checkpoint_Manifest_Header_Length
                               + Natural (Family_Index) * Maximum_Family_Length);
         end loop;
         pragma
           Assert
             (Cursor
                <= Max_Checkpoint_Manifest_Image_Length - Object_Trailer_Length - Maximum_Identity_Length);
         for Index in Identity_Slot range 1 .. Value.Identity_Total loop
            Put_Identifier (Image, Cursor, Value.Identities (Index));
            Cursor := Cursor + Head_Policy.Identifier_Length;
            pragma
              Loop_Invariant
                (Cursor >= Checkpoint_Manifest_Header_Length
                   and then Cursor
                            <= Max_Checkpoint_Manifest_Image_Length
                               - Object_Trailer_Length
                               - Maximum_Identity_Length
                               + Natural (Index) * Head_Policy.Identifier_Length);
         end loop;
         pragma Assert (Cursor >= Checkpoint_Manifest_Header_Length);
         pragma Assert (Cursor <= Image'Last - 3);
         if Cursor + Object_Trailer_Length /= Length then
            Image := [others => 0];
            Length := 0;
            Status := Invalid_Value;
            return;
         end if;
         Put_U32 (Image, Cursor, Formats.CRC_32C (Image (0 .. Cursor - 1)));
         Status := Encoded;
      end Encode_Checkpoint_Manifest;

      procedure Decode_Checkpoint_Manifest
        (Image             : Formats.Byte_Array;
         Expected_Database : Head_Policy.Identifier;
         Limits            : Checkpoint_Reader_Caps;
         Value             : out Checkpoint_Manifest;
         Status            : out Decode_Status)
      is
         Fixed          : Checkpoint_Manifest_Image := [others => 0];
         Candidate      : Checkpoint_Manifest := Empty_Checkpoint_Manifest;
         Payload_Length : Interfaces.Unsigned_64;
         Payload_End    : Natural;
         --  Exact admitted manifest-v3 caller extent after frozen minimum and
         --  generic-representation maximum checks; not policy or a new cap.
         Image_Length   : Natural;
         Cursor         : Natural := Checkpoint_Manifest_Header_Length;
         Family_Wire    : Interfaces.Unsigned_32;
         Identity_Wire  : Interfaces.Unsigned_32;
      begin
         Value := Empty_Checkpoint_Manifest;
         if Image'Last < Image'First
           or else Image'Last - Image'First < Checkpoint_Manifest_Header_Length + Object_Trailer_Length - 1
         then
            Status := Invalid_Length;
            return;
         elsif Image'Last - Image'First >= Max_Checkpoint_Manifest_Image_Length then
            Status := Limit_Exceeded;
            return;
         end if;
         Image_Length := Image'Last - Image'First + 1;
         Fixed (0 .. Image_Length - 1) := Image;
         Payload_Length := Read_U64 (Fixed, 32);
         --  Authenticate common offsets 0/8/10/11/12/28/32/40 before caps;
         --  the final CRC is the four-byte trailer at the admitted extent.
         if Payload_Length
           /= Interfaces.Unsigned_64
                (Image_Length - Checkpoint_Manifest_Header_Length - Object_Trailer_Length)
         then
            Status := Invalid_Length;
            return;
         elsif Fixed (0 .. 7) /= Manifest_Magic then
            Status := Invalid_Magic;
            return;
         elsif Read_U16 (Fixed, 8) /= Checkpoint_Manifest_Format_Version then
            Status := Unsupported_Version;
            return;
         elsif Fixed (10) /= Manifests.Manifest_Object_Kind then
            Status := Invalid_Object_Kind;
            return;
         elsif Fixed (11) /= 0 then
            Status := Invalid_Flags;
            return;
         elsif Read_Identifier (Fixed, 12) /= Expected_Database then
            Status := Wrong_Database;
            return;
         elsif Read_U32 (Fixed, 28) /= Interfaces.Unsigned_32 (Checkpoint_Manifest_Header_Length) then
            Status := Invalid_Length;
            return;
         elsif Read_U32 (Fixed, 40) /= Manifest_Header_Checksum (Fixed) then
            Status := Header_Checksum_Failed;
            return;
         elsif Read_U32 (Fixed, Image_Length - Object_Trailer_Length)
           /= Formats.CRC_32C (Fixed (0 .. Image_Length - Object_Trailer_Length - 1))
         then
            Status := Object_Checksum_Failed;
            return;
         elsif Payload_Length > Interfaces.Unsigned_64 (Limits.Payload_Bytes) then
            Status := Limit_Exceeded;
            return;
         end if;

         Family_Wire := Read_U32 (Fixed, 140);
         Identity_Wire := Read_U32 (Fixed, 212);
         --  V2 retains v1 limit offsets 144..188 and adds replay/run/identity
         --  authority at 196/204/208/212 plus the zero word at 216. V3 adds
         --  point/range count authority at 220/224.
         if Family_Wire = 0 then
            Status := Invalid_Manifest_State;
            return;
         elsif Interfaces.Unsigned_64 (Family_Wire) > Interfaces.Unsigned_64 (Manifests.Max_Families)
           or else Interfaces.Unsigned_64 (Identity_Wire) > Interfaces.Unsigned_64 (Maximum_Identities)
           or else Interfaces.Unsigned_64 (Identity_Wire) > Interfaces.Unsigned_64 (Limits.Identities)
         then
            Status := Limit_Exceeded;
            return;
         elsif Read_U32 (Fixed, 216) /= 0 then
            Status := Invalid_Manifest_State;
            return;
         elsif Read_U32 (Fixed, 220) = 0 or else Read_U32 (Fixed, 224) = 0 then
            Status := Invalid_Manifest_State;
            return;
         elsif Read_U32 (Fixed, 144) > Interfaces.Unsigned_32 (Manifests.Max_Families)
           or else Read_U32 (Fixed, 148) > Interfaces.Unsigned_32 (Manifests.Max_Manifest_History)
           or else Read_U32 (Fixed, 152) > Interfaces.Unsigned_32 (Manifests.Max_Batch_History)
           or else Read_U32 (Fixed, 156) > Interfaces.Unsigned_32 (Manifests.Max_Batch_Transactions)
         then
            Status := Limit_Exceeded;
            return;
         end if;

         Candidate.Base.Database_ID := Read_Identifier (Fixed, 12);
         Candidate.Base.Manifest_ID := Read_Identifier (Fixed, 44);
         Candidate.Base.Previous_Manifest_ID := Read_Identifier (Fixed, 60);
         Candidate.Base.Expected_Transition_ID := Read_Identifier (Fixed, 76);
         Candidate.Base.Expected_Transition_Number := Read_U64 (Fixed, 92);
         Candidate.Base.Publication_Transition_ID := Read_Identifier (Fixed, 100);
         Candidate.Base.Publication_Transition_Number := Read_U64 (Fixed, 116);
         Candidate.Base.Writer_Epoch := Read_U64 (Fixed, 124);
         Candidate.Base.Registry_Revision := Read_U64 (Fixed, 132);
         Candidate.Base.Family_Total := Manifests.Family_Count (Family_Wire);
         Candidate.Base.Limits.Maximum_Column_Families := Read_U32 (Fixed, 144);
         Candidate.Base.Limits.Maximum_Manifest_History := Read_U32 (Fixed, 148);
         Candidate.Base.Limits.Maximum_Batch_History := Read_U32 (Fixed, 152);
         Candidate.Base.Limits.Maximum_Transactions_Per_Batch := Read_U32 (Fixed, 156);
         Candidate.Base.Limits.Maximum_Mutations_Per_Transaction := Read_U32 (Fixed, 160);
         Candidate.Base.Limits.Maximum_Mutations_Per_Batch := Read_U32 (Fixed, 164);
         Candidate.Base.Limits.Maximum_Live_Entries := Read_U32 (Fixed, 168);
         Candidate.Base.Limits.Maximum_Transaction_Payload_Bytes := Read_U64 (Fixed, 172);
         Candidate.Base.Limits.Maximum_Batch_Payload_Bytes := Read_U64 (Fixed, 180);
         Candidate.Base.Limits.Maximum_Live_State_Bytes := Read_U64 (Fixed, 188);
         Candidate.Replay_Boundary := Read_U64 (Fixed, 196);
         Candidate.Maximum_Total_L0_Runs := Read_U32 (Fixed, 204);
         Candidate.Maximum_Checkpoint_Identities := Read_U32 (Fixed, 208);
         Candidate.Maximum_Point_Reads_Per_Transaction := Read_U32 (Fixed, 220);
         Candidate.Maximum_Scan_Ranges_Per_Transaction := Read_U32 (Fixed, 224);
         Candidate.Identity_Total := Identity_Count (Identity_Wire);
         Payload_End := Image_Length - Object_Trailer_Length;

         for Family_Index in Manifests.Family_Slot range 1 .. Candidate.Base.Family_Total loop
            pragma Loop_Invariant (Cursor >= Checkpoint_Manifest_Header_Length);
            pragma Loop_Invariant (Cursor <= Payload_End);
            declare
               Base      : Manifests.Column_Family_Configuration;
               State     : Family_LSM_State;
               Name_Wire : Interfaces.Unsigned_16;
               Run_Wire  : Interfaces.Unsigned_32;
            begin
               --  Decode the frozen family-relative registry map 0..27 and
               --  the manifest-v2/v3 LSM extension 28..51.
               if Cursor > Payload_End or else Checkpoint_Family_Header_Length > Payload_End - Cursor then
                  Status := Invalid_Family;
                  return;
               end if;
               Base.ID := Read_U32 (Fixed, Cursor);
               Base.Max_Key_Bytes := Read_U64 (Fixed, Cursor + 8);
               Base.Max_Value_Bytes := Read_U64 (Fixed, Cursor + 16);
               Name_Wire := Read_U16 (Fixed, Cursor + 24);
               State.Memtable_Max_Bytes := Read_U64 (Fixed, Cursor + 28);
               State.Memtable_Max_Entries := Read_U32 (Fixed, Cursor + 36);
               State.Maximum_L0_Runs := Read_U32 (Fixed, Cursor + 40);
               Run_Wire := Read_U32 (Fixed, Cursor + 44);
               if Read_U32 (Fixed, Cursor + 4) /= 0
                 or else Read_U16 (Fixed, Cursor + 26) /= 0
                 or else Read_U32 (Fixed, Cursor + 48) /= 0
               then
                  Status := Invalid_Family;
                  return;
               elsif Name_Wire = 0 then
                  Status := Invalid_Family;
                  return;
               elsif Interfaces.Unsigned_64 (Name_Wire)
                 > Interfaces.Unsigned_64 (Manifests.Max_Family_Name_Bytes)
                 or else Interfaces.Unsigned_64 (Run_Wire) > Interfaces.Unsigned_64 (Maximum_Runs_Per_Family)
                 or else Interfaces.Unsigned_64 (Run_Wire) > Interfaces.Unsigned_64 (Limits.Runs_Per_Family)
               then
                  Status := Limit_Exceeded;
                  return;
               end if;
               Base.Name_Length := Manifests.Family_Name_Length (Name_Wire);
               State.Run_Total := Run_Count (Run_Wire);
               Cursor := Cursor + Checkpoint_Family_Header_Length;
               if Cursor > Payload_End or else Base.Name_Length > Payload_End - Cursor then
                  Status := Invalid_Family;
                  return;
               end if;
               for Byte_Index in Manifests.Family_Name_Index range 1 .. Base.Name_Length loop
                  Base.Name (Byte_Index) :=
                    Fixed (Cursor + Natural (Byte_Index - Manifests.Family_Name_Index'First));
               end loop;
               Cursor := Cursor + Base.Name_Length;
               Candidate.Base.Families (Family_Index) := Base;
               for Run_Index in Run_Slot range 1 .. State.Run_Total loop
                  pragma Loop_Invariant (Cursor >= Checkpoint_Manifest_Header_Length);
                  pragma Loop_Invariant (Cursor <= Payload_End);
                  if Cursor > Payload_End or else Run_Descriptor_Length > Payload_End - Cursor then
                     Status := Invalid_Run;
                     return;
                  end if;
                  --  Run-relative 0/16/24/32/36/40 are ID, sequence bounds,
                  --  entry count, reserved zero, and logical byte count.
                  State.Runs (Run_Index).Run_ID := Read_Identifier (Fixed, Cursor);
                  State.Runs (Run_Index).Lowest_Sequence := Read_U64 (Fixed, Cursor + 16);
                  State.Runs (Run_Index).Highest_Sequence := Read_U64 (Fixed, Cursor + 24);
                  State.Runs (Run_Index).Entry_Total := Read_U32 (Fixed, Cursor + 32);
                  State.Runs (Run_Index).Logical_Payload_Bytes := Read_U64 (Fixed, Cursor + 40);
                  if Read_U32 (Fixed, Cursor + 36) /= 0 then
                     Status := Invalid_Run;
                     return;
                  end if;
                  Cursor := Cursor + Run_Descriptor_Length;
               end loop;
               Candidate.Family_LSM (Family_Index) := State;
            end;
         end loop;

         for Index in Identity_Slot range 1 .. Candidate.Identity_Total loop
            pragma Loop_Invariant (Cursor >= Checkpoint_Manifest_Header_Length);
            pragma Loop_Invariant (Cursor <= Payload_End);
            if Cursor > Payload_End or else Head_Policy.Identifier_Length > Payload_End - Cursor then
               Status := Invalid_Identity;
               return;
            end if;
            Candidate.Identities (Index) := Read_Identifier (Fixed, Cursor);
            Cursor := Cursor + Head_Policy.Identifier_Length;
         end loop;
         if Cursor /= Payload_End then
            Value := Empty_Checkpoint_Manifest;
            Status := Invalid_Length;
         elsif not Structurally_Valid (Candidate) then
            Value := Empty_Checkpoint_Manifest;
            Status := Invalid_Manifest_State;
         else
            Value := Candidate;
            Status := Decoded;
         end if;
      end Decode_Checkpoint_Manifest;

      function Structurally_Valid (Value : SST) return Boolean is
         --  Valid sequences are positive, so U64'Last/0 are mathematical
         --  min/max identities only, not persisted sentinels. Logical starts
         --  at the additive identity before checked accumulation.
         Logical : Interfaces.Unsigned_64 := 0;
         Lowest  : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
         Highest : Interfaces.Unsigned_64 := 0;
      begin
         if Head_Policy.Is_Zero (Value.Database_ID)
           or else Head_Policy.Is_Zero (Value.Run_ID)
           or else Value.Family_ID = 0
           or else Value.Entry_Total = 0
           or else Value.Lowest_Sequence = 0
           or else Value.Lowest_Sequence > Value.Highest_Sequence
         then
            return False;
         end if;
         for Index in SST_Entry_Slot range 1 .. Value.Entry_Total loop
            declare
               Item         : SST_Entry renames Value.Entries (Index);
               --  Derived exactly from this entry's key and Put-value lengths;
               --  the guarded sum enforces the persisted logical-byte field.
               Item_Logical : constant Interfaces.Unsigned_64 := Entry_Logical_Bytes (Item);
            begin
               if not Valid_Entry (Item)
                 or else Item.Sequence < Value.Lowest_Sequence
                 or else Item.Sequence > Value.Highest_Sequence
                 or else (Index > 1
                          and then (if Same_Key (Value.Entries (Index - 1), Item)
                                    then Value.Entries (Index - 1).Sequence <= Item.Sequence
                                    else not Key_Less (Value.Entries (Index - 1), Item)))
               then
                  return False;
               end if;
               if Item_Logical > Interfaces.Unsigned_64'Last - Logical then
                  return False;
               end if;
               Logical := Logical + Item_Logical;
               Lowest := Interfaces.Unsigned_64'Min (Lowest, Item.Sequence);
               Highest := Interfaces.Unsigned_64'Max (Highest, Item.Sequence);
            end;
         end loop;
         for Index in SST_Entry_Slot loop
            if Index > Value.Entry_Total and then Value.Entries (Index) /= Empty_Entry then
               return False;
            end if;
         end loop;
         return
           Lowest = Value.Lowest_Sequence
           and then Highest = Value.Highest_Sequence
           and then Logical = Value.Logical_Payload_Bytes;
      end Structurally_Valid;

      function Descriptor_Matches
        (Value             : SST;
         Expected_Database : Head_Policy.Identifier;
         Expected_Family   : Interfaces.Unsigned_32;
         Descriptor        : Run_Descriptor) return Boolean
      is (Structurally_Valid (Value)
          and then Valid_Run_Descriptor (Descriptor)
          and then Value.Database_ID = Expected_Database
          and then Value.Family_ID = Expected_Family
          and then Value.Run_ID = Descriptor.Run_ID
          and then Value.Lowest_Sequence = Descriptor.Lowest_Sequence
          and then Value.Highest_Sequence = Descriptor.Highest_Sequence
          and then Interfaces.Unsigned_64 (Value.Entry_Total)
                   = Interfaces.Unsigned_64 (Descriptor.Entry_Total)
          and then Value.Logical_Payload_Bytes = Descriptor.Logical_Payload_Bytes);

      function SST_Encoded_Length (Value : SST) return Natural is
         Result : Natural := SST_Header_Length + Object_Trailer_Length;
      begin
         for Index in SST_Entry_Slot range 1 .. Value.Entry_Total loop
            Result :=
              Result
              + SST_Entry_Header_Length
              + Value.Entries (Index).Key_Byte_Total
              + Value.Entries (Index).Value_Byte_Total;
         end loop;
         return Result;
      end SST_Encoded_Length;

      procedure Encode_SST
        (Value : SST; Image : out SST_Image; Length : out Natural; Status : out Encode_Status)
      is
         --  Authority: this is the exact frozen SST-v1 entry prefix plus the
         --  caller-selected generic key/value representation, not a policy cap.
         Maximum_Entry_Length : constant Natural :=
           SST_Entry_Header_Length + Maximum_Key_Bytes + Maximum_Value_Bytes;
         Cursor               : Natural := SST_Header_Length;
      begin
         Image := [others => 0];
         Length := 0;
         if not Structurally_Valid (Value) then
            Status := Invalid_Value;
            return;
         end if;
         Length := SST_Encoded_Length (Value);
         if Length < SST_Header_Length + Object_Trailer_Length or else Length > Image'Length then
            Image := [others => 0];
            Length := 0;
            Status := Invalid_Value;
            return;
         end if;
         --  SST-v1 common offsets are 0/8/10/11/12/28/32/40; its extension
         --  stores run 44, family 60, sequences 64/72, count/reserved 80/84,
         --  and logical bytes 88. Changing them is wire-incompatible.
         Image (0 .. 7) := SST_Magic;
         Put_U16 (Image, 8, SST_Format_Version);
         Image (10) := SST_Object_Kind;
         Image (11) := 0;
         Put_Identifier (Image, 12, Value.Database_ID);
         Put_U32 (Image, 28, Interfaces.Unsigned_32 (SST_Header_Length));
         Put_U64 (Image, 32, Interfaces.Unsigned_64 (Length - SST_Header_Length - Object_Trailer_Length));
         Put_Identifier (Image, 44, Value.Run_ID);
         Put_U32 (Image, 60, Value.Family_ID);
         Put_U64 (Image, 64, Value.Lowest_Sequence);
         Put_U64 (Image, 72, Value.Highest_Sequence);
         Put_U32 (Image, 80, Interfaces.Unsigned_32 (Value.Entry_Total));
         Put_U32 (Image, 84, 0);
         Put_U64 (Image, 88, Value.Logical_Payload_Bytes);
         Put_U32 (Image, 40, SST_Header_Checksum (Image));

         for Index in SST_Entry_Slot range 1 .. Value.Entry_Total loop
            declare
               Item         : SST_Entry renames Value.Entries (Index);
               --  Exact current-entry extent from the frozen prefix and this
               --  entry's generic-representation key/value lengths.
               Entry_Start  : constant Natural := Cursor;
               Entry_Length : constant Natural :=
                 SST_Entry_Header_Length + Item.Key_Byte_Total + Item.Value_Byte_Total;
            begin
               --  Entry-relative offsets: sequence 0, operation 8, zero
               --  flags/reserved 9/10, key length 12, value length 16; key and
               --  value bytes follow the frozen 20-byte prefix.
               pragma Assert (Entry_Length <= Maximum_Entry_Length);
               pragma Assert (Entry_Start <= Max_SST_Image_Length - Object_Trailer_Length - Entry_Length);
               Put_U64 (Image, Cursor, Item.Sequence);
               Image (Cursor + 8) := Item.Operation;
               Image (Cursor + 9) := 0;
               Put_U16 (Image, Cursor + 10, 0);
               Put_U32 (Image, Cursor + 12, Interfaces.Unsigned_32 (Item.Key_Byte_Total));
               Put_U32 (Image, Cursor + 16, Interfaces.Unsigned_32 (Item.Value_Byte_Total));
               Cursor := Cursor + SST_Entry_Header_Length;
               for Byte_Index in Key_Index range 1 .. Item.Key_Byte_Total loop
                  Image (Cursor + Natural (Byte_Index - Key_Index'First)) := Item.Key (Byte_Index);
               end loop;
               Cursor := Cursor + Item.Key_Byte_Total;
               for Byte_Index in Value_Index range 1 .. Item.Value_Byte_Total loop
                  Image (Cursor + Natural (Byte_Index - Value_Index'First)) := Item.Value (Byte_Index);
               end loop;
               Cursor := Cursor + Item.Value_Byte_Total;
            end;
            pragma
              Loop_Invariant
                (Cursor >= SST_Header_Length
                   and then Cursor <= SST_Header_Length + Natural (Index) * Maximum_Entry_Length);
         end loop;
         pragma Assert (Cursor >= SST_Header_Length);
         pragma Assert (Cursor <= Image'Last - 3);
         if Cursor + Object_Trailer_Length /= Length then
            Image := [others => 0];
            Length := 0;
            Status := Invalid_Value;
            return;
         end if;
         Put_U32 (Image, Cursor, Formats.CRC_32C (Image (0 .. Cursor - 1)));
         Status := Encoded;
      end Encode_SST;

      procedure Decode_SST
        (Image             : Formats.Byte_Array;
         Expected_Database : Head_Policy.Identifier;
         Limits            : SST_Reader_Caps;
         Value             : out SST;
         Status            : out Decode_Status)
      is
         Fixed          : SST_Image := [others => 0];
         Candidate      : SST := Empty_SST;
         Payload_Length : Interfaces.Unsigned_64;
         Payload_End    : Natural;
         --  Authority: this is the exact caller image extent after the frozen
         --  SST-v1 minimum/maximum checks, not a reader policy or new cap.
         Image_Length   : Natural;
         Cursor         : Natural := SST_Header_Length;
         Entry_Wire     : Interfaces.Unsigned_32;
      begin
         Value := Empty_SST;
         if Image'Last < Image'First
           or else Image'Last - Image'First < SST_Header_Length + Object_Trailer_Length - 1
         then
            Status := Invalid_Length;
            return;
         elsif Image'Last - Image'First >= Max_SST_Image_Length then
            Status := Limit_Exceeded;
            return;
         end if;
         Image_Length := Image'Last - Image'First + 1;
         Fixed (0 .. Image_Length - 1) := Image;
         Payload_Length := Read_U64 (Fixed, 32);
         --  Authenticate frozen SST common/header offsets before caps:
         --  common 0/8/10/11/12/28/32/40 and SST 44/60/64/72/80/84/88.
         if Payload_Length
           /= Interfaces.Unsigned_64 (Image_Length - SST_Header_Length - Object_Trailer_Length)
         then
            Status := Invalid_Length;
            return;
         elsif Fixed (0 .. 7) /= SST_Magic then
            Status := Invalid_Magic;
            return;
         elsif Read_U16 (Fixed, 8) /= SST_Format_Version then
            Status := Unsupported_Version;
            return;
         elsif Fixed (10) /= SST_Object_Kind then
            Status := Invalid_Object_Kind;
            return;
         elsif Fixed (11) /= 0 then
            Status := Invalid_Flags;
            return;
         elsif Read_Identifier (Fixed, 12) /= Expected_Database then
            Status := Wrong_Database;
            return;
         elsif Read_U32 (Fixed, 28) /= Interfaces.Unsigned_32 (SST_Header_Length) then
            Status := Invalid_Length;
            return;
         elsif Read_U32 (Fixed, 40) /= SST_Header_Checksum (Fixed) then
            Status := Header_Checksum_Failed;
            return;
         elsif Read_U32 (Fixed, Image_Length - Object_Trailer_Length)
           /= Formats.CRC_32C (Fixed (0 .. Image_Length - Object_Trailer_Length - 1))
         then
            Status := Object_Checksum_Failed;
            return;
         elsif Payload_Length > Interfaces.Unsigned_64 (Limits.Payload_Bytes) then
            Status := Limit_Exceeded;
            return;
         end if;

         Entry_Wire := Read_U32 (Fixed, 80);
         if Interfaces.Unsigned_64 (Entry_Wire) > Interfaces.Unsigned_64 (Maximum_SST_Entries)
           or else Interfaces.Unsigned_64 (Entry_Wire) > Interfaces.Unsigned_64 (Limits.Entries)
         then
            Status := Limit_Exceeded;
            return;
         elsif Read_U32 (Fixed, 84) /= 0 then
            Status := Invalid_SST_State;
            return;
         end if;
         Candidate.Database_ID := Read_Identifier (Fixed, 12);
         Candidate.Run_ID := Read_Identifier (Fixed, 44);
         Candidate.Family_ID := Read_U32 (Fixed, 60);
         Candidate.Lowest_Sequence := Read_U64 (Fixed, 64);
         Candidate.Highest_Sequence := Read_U64 (Fixed, 72);
         Candidate.Entry_Total := SST_Entry_Count (Entry_Wire);
         Candidate.Logical_Payload_Bytes := Read_U64 (Fixed, 88);
         Payload_End := Image_Length - Object_Trailer_Length;

         for Index in SST_Entry_Slot range 1 .. Candidate.Entry_Total loop
            pragma Loop_Invariant (Cursor >= SST_Header_Length);
            pragma Loop_Invariant (Cursor <= Payload_End);
            declare
               Item       : SST_Entry;
               Key_Wire   : Interfaces.Unsigned_32;
               Value_Wire : Interfaces.Unsigned_32;
            begin
               --  Entry-relative 0/8/9/10/12/16 is the persisted SST-v1
               --  sequence/tag/zero-bits/key-length/value-length map.
               if Cursor > Payload_End or else SST_Entry_Header_Length > Payload_End - Cursor then
                  Status := Invalid_Entry;
                  return;
               end if;
               Item.Sequence := Read_U64 (Fixed, Cursor);
               Item.Operation := Fixed (Cursor + 8);
               Key_Wire := Read_U32 (Fixed, Cursor + 12);
               Value_Wire := Read_U32 (Fixed, Cursor + 16);
               if Fixed (Cursor + 9) /= 0 or else Read_U16 (Fixed, Cursor + 10) /= 0 then
                  Status := Invalid_Entry;
                  return;
               elsif Interfaces.Unsigned_64 (Key_Wire) > Interfaces.Unsigned_64 (Maximum_Key_Bytes)
                 or else Interfaces.Unsigned_64 (Key_Wire) > Interfaces.Unsigned_64 (Limits.Key_Bytes)
                 or else Interfaces.Unsigned_64 (Value_Wire) > Interfaces.Unsigned_64 (Maximum_Value_Bytes)
                 or else Interfaces.Unsigned_64 (Value_Wire) > Interfaces.Unsigned_64 (Limits.Value_Bytes)
               then
                  Status := Limit_Exceeded;
                  return;
               end if;
               Item.Key_Byte_Total := Key_Length (Key_Wire);
               Item.Value_Byte_Total := Value_Length (Value_Wire);
               Cursor := Cursor + SST_Entry_Header_Length;
               if Cursor > Payload_End
                 or else Item.Key_Byte_Total > Payload_End - Cursor
                 or else Item.Value_Byte_Total > Payload_End - Cursor - Item.Key_Byte_Total
               then
                  Status := Invalid_Entry;
                  return;
               end if;
               for Byte_Index in Key_Index range 1 .. Item.Key_Byte_Total loop
                  Item.Key (Byte_Index) := Fixed (Cursor + Natural (Byte_Index - Key_Index'First));
               end loop;
               Cursor := Cursor + Item.Key_Byte_Total;
               for Byte_Index in Value_Index range 1 .. Item.Value_Byte_Total loop
                  Item.Value (Byte_Index) := Fixed (Cursor + Natural (Byte_Index - Value_Index'First));
               end loop;
               Cursor := Cursor + Item.Value_Byte_Total;
               if not Valid_Entry (Item) then
                  Status := Invalid_Entry;
                  return;
               end if;
               Candidate.Entries (Index) := Item;
            end;
         end loop;
         if Cursor /= Payload_End then
            Status := Invalid_Length;
         elsif not Structurally_Valid (Candidate) then
            Status := Invalid_SST_State;
         else
            Value := Candidate;
            Status := Decoded;
         end if;
      end Decode_SST;

   end Reference;

end Flyology.DB.LSM_Formats;
