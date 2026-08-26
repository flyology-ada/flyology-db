with Ada.Unchecked_Deallocation;

package body Flyology.DB.LSM_Runtime_Formats is

   use type Formats.Byte;
   use type Formats.Byte_Array;
   use type Head_Policy.Identifier;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  Operational array extents use Natural while frozen count/entry-length
   --  fields use U32. The qualified target's Natural is narrower; a wider
   --  Integer target must add explicit builder checks before it is compatible.
   pragma
     Compile_Time_Error
       (Interfaces.Unsigned_64 (Natural'Last) > Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last),
        "LSM runtime builders require Natural to fit the frozen U32 fields");

   --  Manifest v2/v3 intentionally retains the frozen FLYCFM01 kind magic so
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

   --  FLYSST01 identifies the SST object family; its version field selects
   --  v1 or v2. Changing it requires a compatibility decision and goldens.
   SST_Magic : constant Formats.Byte_Array (0 .. 7) :=
     [Character'Pos ('F'),
      Character'Pos ('L'),
      Character'Pos ('Y'),
      Character'Pos ('S'),
      Character'Pos ('S'),
      Character'Pos ('T'),
      Character'Pos ('0'),
      Character'Pos ('1')];

   procedure Free_Checkpoint is new
     Ada.Unchecked_Deallocation (Object => Checkpoint_Manifest, Name => Checkpoint_Manifest_Access);
   procedure Free_SST is new Ada.Unchecked_Deallocation (Object => SST, Name => SST_Access);
   procedure Free_SST_V2_Index is new
     Ada.Unchecked_Deallocation
       (Object => SST_V2_Index,
        Name   => SST_V2_Index_Access);
   procedure Free_SST_V2_Frame is new
     Ada.Unchecked_Deallocation
       (Object => SST_V2_Frame,
        Name   => SST_V2_Frame_Access);
   procedure Free_Image is new
     Ada.Unchecked_Deallocation (Object => Formats.Byte_Array, Name => Image_Access);

   function Byte_At (Image : Formats.Byte_Array; Position : Natural) return Formats.Byte
   is (Image (Image'First + Position));

   procedure Put_U16 (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_16)
   is
   begin
      Image (Image'First + Position) := Formats.Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);
      Image (Image'First + Position + 1) := Formats.Byte (Value and 16#FF#);
   end Put_U16;

   procedure Put_U32 (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_32)
   is
   begin
      for Offset in Natural range 0 .. 3 loop
         Image (Image'First + Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64 (Image : in out Formats.Byte_Array; Position : Natural; Value : Interfaces.Unsigned_64)
   is
   begin
      for Offset in Natural range 0 .. 7 loop
         Image (Image'First + Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   function Read_U16 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_16 is
   begin
      return
        Interfaces.Shift_Left (Interfaces.Unsigned_16 (Byte_At (Image, Position)), 8)
        or Interfaces.Unsigned_16 (Byte_At (Image, Position + 1));
   end Read_U16;

   function Read_U32 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_32 is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      for Offset in Natural range 0 .. 3 loop
         Result :=
           Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_32 (Byte_At (Image, Position + Offset));
      end loop;
      return Result;
   end Read_U32;

   function Read_U64 (Image : Formats.Byte_Array; Position : Natural) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Offset in Natural range 0 .. 7 loop
         Result :=
           Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_64 (Byte_At (Image, Position + Offset));
      end loop;
      return Result;
   end Read_U64;

   procedure Put_Identifier
     (Image : in out Formats.Byte_Array; Position : Natural; Value : Head_Policy.Identifier) is
   begin
      for Index in Head_Policy.Identifier_Index loop
         Image (Image'First + Position + Index - Head_Policy.Identifier_Index'First) := Value (Index);
      end loop;
   end Put_Identifier;

   function Read_Identifier (Image : Formats.Byte_Array; Position : Natural) return Head_Policy.Identifier is
      Result : Head_Policy.Identifier;
   begin
      for Index in Head_Policy.Identifier_Index loop
         Result (Index) := Byte_At (Image, Position + Index - Head_Policy.Identifier_Index'First);
      end loop;
      return Result;
   end Read_Identifier;

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

   function Valid_Run_Descriptor (Value : Run_Descriptor) return Boolean
   is (not Head_Policy.Is_Zero (Value.Run_ID)
       and then Value.Lowest_Sequence > 0
       and then Value.Lowest_Sequence <= Value.Highest_Sequence
       and then Value.Entry_Total > 0);

   function Header_Checksum
     (Header : Formats.Byte_Array; Expected_Length : Positive) return Interfaces.Unsigned_32
   is
      Fixed : Formats.Byte_Array (0 .. Expected_Length - 1) := Header;
   begin
      --  Common-envelope bytes 40..43 are the frozen header CRC field and are
      --  zeroed for calculation in every current immutable object format.
      Fixed (40 .. 43) := [others => 0];
      return Formats.CRC_32C (Fixed);
   end Header_Checksum;

   function Add_U64 (Left, Right : Interfaces.Unsigned_64; Result : out Interfaces.Unsigned_64) return Boolean
   is
   begin
      if Right > Interfaces.Unsigned_64'Last - Left then
         Result := 0;
         return False;
      end if;
      Result := Left + Right;
      return True;
   end Add_U64;

   function Multiply_U64
     (Left, Right : Interfaces.Unsigned_64; Result : out Interfaces.Unsigned_64) return Boolean is
   begin
      if Left /= 0 and then Right > Interfaces.Unsigned_64'Last / Left then
         Result := 0;
         return False;
      end if;
      Result := Left * Right;
      return True;
   end Multiply_U64;

   procedure Release (Value : in out Checkpoint_Manifest_Access) is
   begin
      Free_Checkpoint (Value);
   end Release;

   procedure Release (Value : in out SST_Access) is
   begin
      Free_SST (Value);
   end Release;

   procedure Release (Value : in out SST_V2_Index_Access) is
   begin
      Free_SST_V2_Index (Value);
   end Release;

   procedure Release (Value : in out SST_V2_Frame_Access) is
   begin
      Free_SST_V2_Frame (Value);
   end Release;

   procedure Release (Image : in out Image_Access) is
   begin
      Free_Image (Image);
   end Release;

   procedure Create_Checkpoint_Manifest
     (Family_Total   : Natural;
      Run_Total      : Natural;
      Identity_Total : Natural;
      Value          : out Checkpoint_Manifest_Access;
      Status         : out Allocation_Status) is
   begin
      Value := null;
      if Family_Total not in 1 .. Manifests.Max_Families then
         Status := Invalid_Extent;
         return;
      end if;
      Value := new Checkpoint_Manifest (Family_Total, Run_Total, Identity_Total);
      Value.Families := [others => <>];
      Value.Runs := [others => <>];
      Value.Identities := [others => Head_Policy.Zero_Identifier];
      Status := Allocated;
   exception
      when Storage_Error =>
         Release (Value);
         Status := Allocation_Failed;
   end Create_Checkpoint_Manifest;

   procedure Create_SST
     (Entry_Total        : Natural;
      Payload_Byte_Total : Natural;
      Value              : out SST_Access;
      Status             : out Allocation_Status)
   is
      Entry_Bytes : Interfaces.Unsigned_64;
      Total       : Interfaces.Unsigned_64;
   begin
      Value := null;
      if Entry_Total = 0
        or else not Multiply_U64
                      (Interfaces.Unsigned_64 (Entry_Total),
                       Interfaces.Unsigned_64 (LSM.SST_Entry_Header_Length),
                       Entry_Bytes)
      then
         Status := Invalid_Extent;
         return;
      end if;
      Total := Interfaces.Unsigned_64 (LSM.SST_Header_Length + LSM.Object_Trailer_Length);
      if not Add_U64 (Total, Entry_Bytes, Total)
        or else not Add_U64 (Total, Interfaces.Unsigned_64 (Payload_Byte_Total), Total)
        or else Total > Interfaces.Unsigned_64 (Natural'Last)
      then
         Status := Invalid_Extent;
         return;
      end if;
      Value := new SST (Entry_Total, Payload_Byte_Total);
      Value.Entries := [others => <>];
      Value.Payload := [others => 0];
      Status := Allocated;
   exception
      when Storage_Error =>
         Release (Value);
         Status := Allocation_Failed;
   end Create_SST;

   procedure Inspect_Checkpoint_Manifest_Header
     (Header            : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Object_Length     : Interfaces.Unsigned_64;
      Admission         : out Checkpoint_Header_Admission;
      Status            : out Decode_Status)
   is
      Fixed            : Formats.Byte_Array (0 .. LSM.Checkpoint_Manifest_Header_Length - 1);
      Family_Wire      : Interfaces.Unsigned_32;
      Identity_Wire    : Interfaces.Unsigned_32;
      Maximum_Runs     : Interfaces.Unsigned_32;
      Maximum_Identity : Interfaces.Unsigned_32;
      Payload_Length   : Interfaces.Unsigned_64;
      Family_Bytes     : Interfaces.Unsigned_64;
      Run_Bytes        : Interfaces.Unsigned_64;
      Identity_Bytes   : Interfaces.Unsigned_64;
      Maximum_Length   : Interfaces.Unsigned_64;
      Minimum_Length   : Interfaces.Unsigned_64;
      Term             : Interfaces.Unsigned_64;
      Version          : Interfaces.Unsigned_16;
      Selected_Header  : Natural;
      Maximum_Points   : Interfaces.Unsigned_32 := 0;
      Maximum_Ranges   : Interfaces.Unsigned_32 := 0;
   begin
      Admission := Empty_Checkpoint_Header_Admission;
      Fixed := [others => 0];
      if Header'Length < LSM.Previous_Checkpoint_Manifest_Header_Length
        or else Header'Length > LSM.Checkpoint_Manifest_Header_Length
      then
         Status := Invalid_Length;
         return;
      end if;
      for Offset in Natural range 0 .. Header'Length - 1 loop
         Fixed (Offset) := Byte_At (Header, Offset);
      end loop;
      Version := Read_U16 (Fixed, 8);
      if Version = LSM.Previous_Checkpoint_Manifest_Format_Version then
         Selected_Header := LSM.Previous_Checkpoint_Manifest_Header_Length;
      elsif Version = LSM.Checkpoint_Manifest_Format_Version then
         Selected_Header := LSM.Checkpoint_Manifest_Header_Length;
      else
         Status := Unsupported_Version;
         return;
      end if;
      --  Callers either supply the exact versioned header or the current-width
      --  recovery probe needed to discover a v2 prefix. No intermediate
      --  extent is format authority.
      if Header'Length /= Selected_Header
        and then Header'Length /= LSM.Checkpoint_Manifest_Header_Length
      then
         Status := Invalid_Length;
         return;
      end if;
      if Fixed (0 .. 7) /= Manifest_Magic then
         Status := Invalid_Magic;
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
      elsif Read_U32 (Fixed, 28) /= Interfaces.Unsigned_32 (Selected_Header) then
         Status := Invalid_Length;
         return;
      elsif Read_U32 (Fixed, 40)
        /= Header_Checksum (Fixed (0 .. Selected_Header - 1), Selected_Header)
      then
         Status := Header_Checksum_Failed;
         return;
      end if;

      if Object_Length
        < Interfaces.Unsigned_64 (Selected_Header + LSM.Object_Trailer_Length)
        or else Object_Length > Interfaces.Unsigned_64 (Natural'Last)
      then
         Status := Limit_Exceeded;
         return;
      end if;
      Payload_Length := Read_U64 (Fixed, 32);
      if Payload_Length
        /= Object_Length
           - Interfaces.Unsigned_64 (Selected_Header + LSM.Object_Trailer_Length)
      then
         Status := Invalid_Length;
         return;
      end if;

      Family_Wire := Read_U32 (Fixed, 140);
      Maximum_Runs := Read_U32 (Fixed, 204);
      Maximum_Identity := Read_U32 (Fixed, 208);
      Identity_Wire := Read_U32 (Fixed, 212);
      if Family_Wire = 0 or else Maximum_Runs = 0 or else Maximum_Identity = 0 then
         Status := Invalid_Manifest_State;
         return;
      elsif Interfaces.Unsigned_64 (Family_Wire) > Interfaces.Unsigned_64 (Manifests.Max_Families) then
         Status := Limit_Exceeded;
         return;
      elsif Identity_Wire > Maximum_Identity then
         Status := Invalid_Manifest_State;
         return;
      elsif Read_U32 (Fixed, 216) /= 0 then
         Status := Invalid_Manifest_State;
         return;
      end if;
      if Version = LSM.Checkpoint_Manifest_Format_Version then
         Maximum_Points := Read_U32 (Fixed, 220);
         Maximum_Ranges := Read_U32 (Fixed, 224);
         if Maximum_Points = 0 or else Maximum_Ranges = 0 then
            Status := Invalid_Manifest_State;
            return;
         end if;
      end if;

      --  Upper extent derives only from authenticated format fields: each
      --  family can carry its frozen prefix/name, each admitted run its frozen
      --  descriptor, and each actual ledger identity its fixed 16 bytes.
      if not Multiply_U64
               (Interfaces.Unsigned_64 (Family_Wire),
                Interfaces.Unsigned_64
                  (LSM.Checkpoint_Family_Header_Length + Manifests.Max_Family_Name_Bytes),
                Family_Bytes)
        or else not Multiply_U64
                      (Interfaces.Unsigned_64 (Maximum_Runs),
                       Interfaces.Unsigned_64 (LSM.Run_Descriptor_Length),
                       Run_Bytes)
        or else not Multiply_U64
                      (Interfaces.Unsigned_64 (Identity_Wire),
                       Interfaces.Unsigned_64 (Head_Policy.Identifier_Length),
                       Identity_Bytes)
      then
         Status := Invalid_Length;
         return;
      end if;
      Maximum_Length :=
        Interfaces.Unsigned_64 (Selected_Header + LSM.Object_Trailer_Length);
      if not Add_U64 (Maximum_Length, Family_Bytes, Maximum_Length)
        or else not Add_U64 (Maximum_Length, Run_Bytes, Maximum_Length)
        or else not Add_U64 (Maximum_Length, Identity_Bytes, Maximum_Length)
      then
         Status := Invalid_Length;
         return;
      end if;

      if not Multiply_U64
               (Interfaces.Unsigned_64 (Family_Wire),
                Interfaces.Unsigned_64 (LSM.Checkpoint_Family_Header_Length + 1),
                Term)
      then
         Status := Invalid_Length;
         return;
      end if;
      Minimum_Length :=
        Interfaces.Unsigned_64 (Selected_Header + LSM.Object_Trailer_Length);
      if not Add_U64 (Minimum_Length, Term, Minimum_Length)
        or else not Add_U64 (Minimum_Length, Identity_Bytes, Minimum_Length)
        or else Object_Length < Minimum_Length
        or else Object_Length > Maximum_Length
      then
         Status := Invalid_Length;
         return;
      end if;

      Admission :=
        (Object_Length                 => Natural (Object_Length),
         Format_Version                => Version,
         Header_Length                 => Selected_Header,
         Family_Total                  => Natural (Family_Wire),
         Identity_Total                => Natural (Identity_Wire),
         Maximum_Total_L0_Runs         => Maximum_Runs,
         Maximum_Checkpoint_Identities => Maximum_Identity,
         Maximum_Point_Reads_Per_Transaction => Maximum_Points,
         Maximum_Scan_Ranges_Per_Transaction => Maximum_Ranges,
         Maximum_Object_Length         => Maximum_Length);
      Status := Decoded;
   end Inspect_Checkpoint_Manifest_Header;

   procedure Read_Manifest_Base_Header (Image : Formats.Byte_Array; Base : out Manifests.Manifest) is
   begin
      Base := Manifests.Empty_Manifest;
      Base.Database_ID := Read_Identifier (Image, 12);
      Base.Manifest_ID := Read_Identifier (Image, 44);
      Base.Previous_Manifest_ID := Read_Identifier (Image, 60);
      Base.Expected_Transition_ID := Read_Identifier (Image, 76);
      Base.Expected_Transition_Number := Read_U64 (Image, 92);
      Base.Publication_Transition_ID := Read_Identifier (Image, 100);
      Base.Publication_Transition_Number := Read_U64 (Image, 116);
      Base.Writer_Epoch := Read_U64 (Image, 124);
      Base.Registry_Revision := Read_U64 (Image, 132);
      Base.Family_Total := Manifests.Family_Count (Read_U32 (Image, 140));
      Base.Limits.Maximum_Column_Families := Read_U32 (Image, 144);
      Base.Limits.Maximum_Manifest_History := Read_U32 (Image, 148);
      Base.Limits.Maximum_Batch_History := Read_U32 (Image, 152);
      Base.Limits.Maximum_Transactions_Per_Batch := Read_U32 (Image, 156);
      Base.Limits.Maximum_Mutations_Per_Transaction := Read_U32 (Image, 160);
      Base.Limits.Maximum_Mutations_Per_Batch := Read_U32 (Image, 164);
      Base.Limits.Maximum_Live_Entries := Read_U32 (Image, 168);
      Base.Limits.Maximum_Transaction_Payload_Bytes := Read_U64 (Image, 172);
      Base.Limits.Maximum_Batch_Payload_Bytes := Read_U64 (Image, 180);
      Base.Limits.Maximum_Live_State_Bytes := Read_U64 (Image, 188);
   end Read_Manifest_Base_Header;

   procedure Write_Manifest_Base_Header
     (Image : in out Formats.Byte_Array; Value : Checkpoint_Manifest; Length : Natural) is
   begin
      --  Frozen common-envelope offsets: magic 0, version 8, kind 10,
      --  flags 11, database 12, header length 28, payload length 32, and CRC 40.
      Image (0 .. 7) := Manifest_Magic;
      Put_U16 (Image, 8, LSM.Checkpoint_Manifest_Format_Version);
      Image (10) := Manifests.Manifest_Object_Kind;
      Image (11) := 0;
      Put_Identifier (Image, 12, Value.Base.Database_ID);
      Put_U32 (Image, 28, Interfaces.Unsigned_32 (LSM.Checkpoint_Manifest_Header_Length));
      Put_U64
        (Image,
         32,
         Interfaces.Unsigned_64 (Length - LSM.Checkpoint_Manifest_Header_Length - LSM.Object_Trailer_Length));
      --  Manifest-v2 preserves v1 identity/limit offsets 44..188 and adds the
      --  replay/run/identity authority at 196..216. Version 3 appends persisted
      --  serializable point/range count authority at 220/224.
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
   end Write_Manifest_Base_Header;

   function Structurally_Valid (Value : Checkpoint_Manifest) return Boolean is
      Next_Run : Natural := 1;
   begin
      if not Manifests.Structurally_Valid (Value.Base)
        or else Natural (Value.Base.Family_Total) /= Value.Family_Total
        or else Value.Maximum_Total_L0_Runs = 0
        or else Value.Maximum_Checkpoint_Identities = 0
        or else (Value.Maximum_Point_Reads_Per_Transaction = 0)
                  /= (Value.Maximum_Scan_Ranges_Per_Transaction = 0)
        or else Interfaces.Unsigned_64 (Value.Run_Total)
                > Interfaces.Unsigned_64 (Value.Maximum_Total_L0_Runs)
        or else Interfaces.Unsigned_64 (Value.Identity_Total)
                > Interfaces.Unsigned_64 (Value.Maximum_Checkpoint_Identities)
      then
         return False;
      end if;

      for Family_Index in Value.Families'Range loop
         declare
            Family : Family_LSM_State renames Value.Families (Family_Index);
         begin
            if Family.Memtable_Max_Bytes = 0
              or else Family.Memtable_Max_Entries = 0
              or else Family.Maximum_L0_Runs = 0
              or else Interfaces.Unsigned_64 (Family.Run_Total)
                      > Interfaces.Unsigned_64 (Family.Maximum_L0_Runs)
              or else (if Family.Run_Total = 0
                       then Family.First_Run /= 0
                       else
                         Family.First_Run /= Next_Run
                         or else Next_Run > Value.Run_Total
                         or else Family.Run_Total > Value.Run_Total - Next_Run + 1)
            then
               return False;
            end if;
            if Family.Run_Total > 0 then
               for Run_Index in Family.First_Run .. Family.First_Run + Family.Run_Total - 1 loop
                  declare
                     Item : Run_Descriptor renames Value.Runs (Run_Index);
                  begin
                     if not Valid_Run_Descriptor (Item)
                       or else Item.Highest_Sequence > Value.Replay_Boundary
                       or else (Run_Index > Family.First_Run
                                and then Value.Runs (Run_Index - 1).Highest_Sequence >= Item.Lowest_Sequence)
                     then
                        return False;
                     end if;
                     for Earlier in Positive range 1 .. Run_Index - 1 loop
                        if Value.Runs (Earlier).Run_ID = Item.Run_ID then
                           return False;
                        end if;
                     end loop;
                  end;
               end loop;
               Next_Run := Next_Run + Family.Run_Total;
            end if;
         end;
      end loop;
      if Value.Run_Total = Natural'Last
        or else Next_Run /= Value.Run_Total + 1
        or else (Value.Replay_Boundary = 0 and then (Value.Run_Total /= 0 or else Value.Identity_Total /= 0))
      then
         return False;
      end if;

      for Index in Value.Identities'Range loop
         if Head_Policy.Is_Zero (Value.Identities (Index))
           or else (Index > Value.Identities'First
                    and then not Identifier_Less (Value.Identities (Index - 1), Value.Identities (Index)))
         then
            return False;
         end if;
      end loop;
      return True;
   end Structurally_Valid;

   function Checkpoint_Encoded_Length (Value : Checkpoint_Manifest; Length : out Natural) return Boolean is
      Total : Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (LSM.Checkpoint_Manifest_Header_Length + LSM.Object_Trailer_Length);
      Term  : Interfaces.Unsigned_64;
   begin
      Length := 0;
      for Index in Value.Families'Range loop
         if not Multiply_U64
                  (Interfaces.Unsigned_64 (Value.Families (Index).Run_Total),
                   Interfaces.Unsigned_64 (LSM.Run_Descriptor_Length),
                   Term)
           or else not Add_U64
                         (Term,
                          Interfaces.Unsigned_64
                            (LSM.Checkpoint_Family_Header_Length + Value.Base.Families (Index).Name_Length),
                          Term)
           or else not Add_U64 (Total, Term, Total)
         then
            return False;
         end if;
      end loop;
      if not Multiply_U64
               (Interfaces.Unsigned_64 (Value.Identity_Total),
                Interfaces.Unsigned_64 (Head_Policy.Identifier_Length),
                Term)
        or else not Add_U64 (Total, Term, Total)
        or else Total > Interfaces.Unsigned_64 (Natural'Last)
      then
         return False;
      end if;
      Length := Natural (Total);
      return True;
   end Checkpoint_Encoded_Length;

   procedure Encode_Checkpoint_Manifest
     (Value : Checkpoint_Manifest; Image : out Image_Access; Status : out Encode_Status)
   is
      Length : Natural;
      Cursor : Natural := LSM.Checkpoint_Manifest_Header_Length;
   begin
      Image := null;
      if not Structurally_Valid (Value)
        or else Value.Maximum_Point_Reads_Per_Transaction = 0
        or else Value.Maximum_Scan_Ranges_Per_Transaction = 0
      then
         Status := Invalid_Value;
         return;
      elsif not Checkpoint_Encoded_Length (Value, Length) then
         Status := Length_Overflow;
         return;
      end if;

      Image := new Formats.Byte_Array'(0 .. Length - 1 => 0);
      Write_Manifest_Base_Header (Image.all, Value, Length);
      Put_U32
        (Image.all,
         40,
         Header_Checksum
           (Image (0 .. LSM.Checkpoint_Manifest_Header_Length - 1), LSM.Checkpoint_Manifest_Header_Length));
      for Family_Index in Value.Families'Range loop
         declare
            Base   : Manifests.Column_Family_Configuration renames Value.Base.Families (Family_Index);
            Family : Family_LSM_State renames Value.Families (Family_Index);
         begin
            Put_U32 (Image.all, Cursor, Base.ID);
            Put_U32 (Image.all, Cursor + 4, 0);
            Put_U64 (Image.all, Cursor + 8, Base.Max_Key_Bytes);
            Put_U64 (Image.all, Cursor + 16, Base.Max_Value_Bytes);
            Put_U16 (Image.all, Cursor + 24, Interfaces.Unsigned_16 (Base.Name_Length));
            Put_U16 (Image.all, Cursor + 26, 0);
            Put_U64 (Image.all, Cursor + 28, Family.Memtable_Max_Bytes);
            Put_U32 (Image.all, Cursor + 36, Family.Memtable_Max_Entries);
            Put_U32 (Image.all, Cursor + 40, Family.Maximum_L0_Runs);
            Put_U32 (Image.all, Cursor + 44, Interfaces.Unsigned_32 (Family.Run_Total));
            Put_U32 (Image.all, Cursor + 48, 0);
            Cursor := Cursor + LSM.Checkpoint_Family_Header_Length;
            for Name_Index in Manifests.Family_Name_Index range 1 .. Base.Name_Length loop
               Image (Cursor + Natural (Name_Index - Manifests.Family_Name_Index'First)) :=
                 Base.Name (Name_Index);
            end loop;
            Cursor := Cursor + Base.Name_Length;
            if Family.Run_Total > 0 then
               for Run_Index in Family.First_Run .. Family.First_Run + Family.Run_Total - 1 loop
                  declare
                     Item : Run_Descriptor renames Value.Runs (Run_Index);
                  begin
                     Put_Identifier (Image.all, Cursor, Item.Run_ID);
                     Put_U64 (Image.all, Cursor + 16, Item.Lowest_Sequence);
                     Put_U64 (Image.all, Cursor + 24, Item.Highest_Sequence);
                     Put_U32 (Image.all, Cursor + 32, Item.Entry_Total);
                     Put_U32 (Image.all, Cursor + 36, 0);
                     Put_U64 (Image.all, Cursor + 40, Item.Logical_Payload_Bytes);
                     Cursor := Cursor + LSM.Run_Descriptor_Length;
                  end;
               end loop;
            end if;
         end;
      end loop;
      for Index in Value.Identities'Range loop
         Put_Identifier (Image.all, Cursor, Value.Identities (Index));
         Cursor := Cursor + Head_Policy.Identifier_Length;
      end loop;
      if Cursor + LSM.Object_Trailer_Length /= Length then
         Release (Image);
         Status := Invalid_Value;
         return;
      end if;
      Put_U32 (Image.all, Cursor, Formats.CRC_32C (Image (0 .. Cursor - 1)));
      Status := Encoded;
   exception
      when Storage_Error =>
         Release (Image);
         Status := Allocation_Failed;
   end Encode_Checkpoint_Manifest;

   procedure Decode_Checkpoint_Manifest
     (Image             : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Value             : out Checkpoint_Manifest_Access;
      Status            : out Decode_Status)
   is
      Admission      : Checkpoint_Header_Admission;
      Candidate      : Checkpoint_Manifest_Access := null;
      Base           : Manifests.Manifest;
      Allocation     : Allocation_Status;
      Cursor         : Natural := 0;
      Payload_End    : Natural;
      Total_Runs     : Natural := 0;
      Replay         : Interfaces.Unsigned_64;
      Family_Run_Max : Interfaces.Unsigned_32;
      Previous_ID    : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Header_Probe_Length : Natural;
   begin
      Value := null;
      if Image'Length
        < LSM.Previous_Checkpoint_Manifest_Header_Length + LSM.Object_Trailer_Length
      then
         Status := Invalid_Length;
         return;
      end if;
      Header_Probe_Length :=
        (if Image'Length >= LSM.Checkpoint_Manifest_Header_Length
         then LSM.Checkpoint_Manifest_Header_Length
         else LSM.Previous_Checkpoint_Manifest_Header_Length);
      Inspect_Checkpoint_Manifest_Header
        (Image (Image'First .. Image'First + Header_Probe_Length - 1),
         Expected_Database,
         Interfaces.Unsigned_64 (Image'Length),
         Admission,
         Status);
      if Status /= Decoded then
         return;
      end if;
      Payload_End := Image'Length - LSM.Object_Trailer_Length;
      if Read_U32 (Image, Payload_End)
        /= Formats.CRC_32C (Image (Image'First .. Image'Last - LSM.Object_Trailer_Length))
      then
         Status := Object_Checksum_Failed;
         return;
      end if;

      Read_Manifest_Base_Header (Image, Base);
      Replay := Read_U64 (Image, 196);
      Cursor := Admission.Header_Length;
      for Family_Index in Positive range 1 .. Admission.Family_Total loop
         declare
            Config     : Manifests.Column_Family_Configuration := (others => <>);
            Name_Wire  : Interfaces.Unsigned_16;
            Run_Wire   : Interfaces.Unsigned_32;
            Run_Count  : Natural;
            Prior_High : Interfaces.Unsigned_64 := 0;
         begin
            if Cursor > Payload_End or else LSM.Checkpoint_Family_Header_Length > Payload_End - Cursor then
               Status := Invalid_Family;
               return;
            end if;
            Config.ID := Read_U32 (Image, Cursor);
            Config.Max_Key_Bytes := Read_U64 (Image, Cursor + 8);
            Config.Max_Value_Bytes := Read_U64 (Image, Cursor + 16);
            Name_Wire := Read_U16 (Image, Cursor + 24);
            Family_Run_Max := Read_U32 (Image, Cursor + 40);
            Run_Wire := Read_U32 (Image, Cursor + 44);
            if Read_U32 (Image, Cursor + 4) /= 0
              or else Read_U16 (Image, Cursor + 26) /= 0
              or else Read_U32 (Image, Cursor + 48) /= 0
            then
               Status := Invalid_Family;
               return;
            elsif Name_Wire = 0
              or else Read_U64 (Image, Cursor + 28) = 0
              or else Read_U32 (Image, Cursor + 36) = 0
              or else Family_Run_Max = 0
            then
               Status := Invalid_Manifest_State;
               return;
            elsif Interfaces.Unsigned_64 (Name_Wire)
              > Interfaces.Unsigned_64 (Manifests.Max_Family_Name_Bytes)
            then
               Status := Limit_Exceeded;
               return;
            elsif Run_Wire > Family_Run_Max then
               Status := Invalid_Manifest_State;
               return;
            end if;
            if Interfaces.Unsigned_64 (Run_Wire) > Interfaces.Unsigned_64 (Natural'Last) then
               Status := Limit_Exceeded;
               return;
            end if;
            Run_Count := Natural (Run_Wire);
            if Run_Count > Natural'Last - Total_Runs
              or else Interfaces.Unsigned_64 (Run_Count) + Interfaces.Unsigned_64 (Total_Runs)
                      > Interfaces.Unsigned_64 (Admission.Maximum_Total_L0_Runs)
            then
               Status := Invalid_Manifest_State;
               return;
            end if;
            Cursor := Cursor + LSM.Checkpoint_Family_Header_Length;
            Config.Name_Length := Manifests.Family_Name_Length (Name_Wire);
            if Config.Name_Length > Payload_End - Cursor then
               Status := Invalid_Family;
               return;
            end if;
            for Name_Index in Manifests.Family_Name_Index range 1 .. Config.Name_Length loop
               Config.Name (Name_Index) :=
                 Byte_At (Image, Cursor + Natural (Name_Index - Manifests.Family_Name_Index'First));
            end loop;
            Cursor := Cursor + Config.Name_Length;
            Base.Families (Family_Index) := Config;
            for Run_Index in Positive range 1 .. Run_Count loop
               declare
                  Item : Run_Descriptor;
               begin
                  if Cursor > Payload_End or else LSM.Run_Descriptor_Length > Payload_End - Cursor then
                     Status := Invalid_Run;
                     return;
                  end if;
                  Item :=
                    (Run_ID                => Read_Identifier (Image, Cursor),
                     Lowest_Sequence       => Read_U64 (Image, Cursor + 16),
                     Highest_Sequence      => Read_U64 (Image, Cursor + 24),
                     Entry_Total           => Read_U32 (Image, Cursor + 32),
                     Logical_Payload_Bytes => Read_U64 (Image, Cursor + 40));
                  if Read_U32 (Image, Cursor + 36) /= 0 or else not Valid_Run_Descriptor (Item) then
                     Status := Invalid_Run;
                     return;
                  elsif Item.Highest_Sequence > Replay
                    or else (Run_Index > 1 and then Prior_High >= Item.Lowest_Sequence)
                  then
                     Status := Invalid_Manifest_State;
                     return;
                  end if;
                  Prior_High := Item.Highest_Sequence;
                  Cursor := Cursor + LSM.Run_Descriptor_Length;
               end;
            end loop;
            Total_Runs := Total_Runs + Run_Count;
         end;
      end loop;
      if Admission.Identity_Total > (Payload_End - Cursor) / Head_Policy.Identifier_Length then
         Status := Invalid_Identity;
         return;
      end if;
      for Index in Positive range 1 .. Admission.Identity_Total loop
         declare
            Item : constant Head_Policy.Identifier := Read_Identifier (Image, Cursor);
         begin
            if Head_Policy.Is_Zero (Item) or else (Index > 1 and then not Identifier_Less (Previous_ID, Item))
            then
               Status := Invalid_Identity;
               return;
            end if;
            Previous_ID := Item;
            Cursor := Cursor + Head_Policy.Identifier_Length;
         end;
      end loop;
      if Cursor /= Payload_End then
         Status := Invalid_Length;
         return;
      elsif not Manifests.Structurally_Valid (Base) then
         Status := Invalid_Manifest_State;
         return;
      elsif not Manifests.Runtime_Compatible (Base) then
         Status := Runtime_Incompatible;
         return;
      end if;

      Create_Checkpoint_Manifest
        (Admission.Family_Total, Total_Runs, Admission.Identity_Total, Candidate, Allocation);
      if Allocation = Allocation_Failed then
         Status := Allocation_Failed;
         return;
      elsif Allocation /= Allocated then
         Status := Limit_Exceeded;
         return;
      end if;
      Candidate.Base := Base;
      Candidate.Replay_Boundary := Replay;
      Candidate.Maximum_Total_L0_Runs := Admission.Maximum_Total_L0_Runs;
      Candidate.Maximum_Checkpoint_Identities := Admission.Maximum_Checkpoint_Identities;
      Candidate.Maximum_Point_Reads_Per_Transaction :=
        Admission.Maximum_Point_Reads_Per_Transaction;
      Candidate.Maximum_Scan_Ranges_Per_Transaction :=
        Admission.Maximum_Scan_Ranges_Per_Transaction;

      Cursor := Admission.Header_Length;
      declare
         Next_Run : Natural := 1;
      begin
         for Family_Index in Candidate.Families'Range loop
            declare
               Family    : Family_LSM_State renames Candidate.Families (Family_Index);
               Name_Wire : constant Natural := Natural (Read_U16 (Image, Cursor + 24));
               Run_Count : constant Natural := Natural (Read_U32 (Image, Cursor + 44));
            begin
               Family.Memtable_Max_Bytes := Read_U64 (Image, Cursor + 28);
               Family.Memtable_Max_Entries := Read_U32 (Image, Cursor + 36);
               Family.Maximum_L0_Runs := Read_U32 (Image, Cursor + 40);
               Family.Run_Total := Run_Count;
               Family.First_Run := (if Run_Count = 0 then 0 else Next_Run);
               Cursor := Cursor + LSM.Checkpoint_Family_Header_Length + Name_Wire;
               for Index in Positive range 1 .. Run_Count loop
                  pragma Unreferenced (Index);
                  Candidate.Runs (Next_Run) :=
                    (Run_ID                => Read_Identifier (Image, Cursor),
                     Lowest_Sequence       => Read_U64 (Image, Cursor + 16),
                     Highest_Sequence      => Read_U64 (Image, Cursor + 24),
                     Entry_Total           => Read_U32 (Image, Cursor + 32),
                     Logical_Payload_Bytes => Read_U64 (Image, Cursor + 40));
                  Next_Run := Next_Run + 1;
                  Cursor := Cursor + LSM.Run_Descriptor_Length;
               end loop;
            end;
         end loop;
      end;
      for Index in Candidate.Identities'Range loop
         Candidate.Identities (Index) := Read_Identifier (Image, Cursor);
         Cursor := Cursor + Head_Policy.Identifier_Length;
      end loop;
      if Cursor /= Payload_End or else not Structurally_Valid (Candidate.all) then
         Release (Candidate);
         Status := Invalid_Manifest_State;
         return;
      end if;
      Value := Candidate;
      Status := Decoded;
   exception
      when Storage_Error =>
         Release (Candidate);
         Value := null;
         Status := Allocation_Failed;
   end Decode_Checkpoint_Manifest;

   procedure Inspect_SST_Header
     (Header              : Formats.Byte_Array;
      Expected_Database   : Head_Policy.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : Run_Descriptor;
      Object_Length       : Interfaces.Unsigned_64;
      Admission           : out SST_Header_Admission;
      Status              : out Decode_Status)
   is
      Fixed          : Formats.Byte_Array (0 .. LSM.SST_Header_Length - 1);
      Payload_Length : Interfaces.Unsigned_64;
      Entry_Bytes    : Interfaces.Unsigned_64;
      Exact_Length   : Interfaces.Unsigned_64;
      Entry_Wire     : Interfaces.Unsigned_32;
   begin
      Admission := Empty_SST_Header_Admission;
      if Header'Length /= LSM.SST_Header_Length then
         Status := Invalid_Length;
         return;
      end if;
      Fixed := Header;
      if Fixed (0 .. 7) /= SST_Magic then
         Status := Invalid_Magic;
         return;
      elsif Read_U16 (Fixed, 8) /= LSM.SST_Format_Version then
         Status := Unsupported_Version;
         return;
      elsif Fixed (10) /= LSM.SST_Object_Kind then
         Status := Invalid_Object_Kind;
         return;
      elsif Fixed (11) /= 0 then
         Status := Invalid_Flags;
         return;
      elsif Read_Identifier (Fixed, 12) /= Expected_Database then
         Status := Wrong_Database;
         return;
      elsif Read_U32 (Fixed, 28) /= Interfaces.Unsigned_32 (LSM.SST_Header_Length) then
         Status := Invalid_Length;
         return;
      elsif Read_U32 (Fixed, 40) /= Header_Checksum (Fixed, LSM.SST_Header_Length) then
         Status := Header_Checksum_Failed;
         return;
      elsif not Valid_Run_Descriptor (Expected_Descriptor) or else Expected_Family = 0 then
         Status := Invalid_SST_State;
         return;
      end if;

      Payload_Length := Read_U64 (Fixed, 32);
      if Object_Length < Interfaces.Unsigned_64 (LSM.SST_Header_Length + LSM.Object_Trailer_Length)
        or else Object_Length > Interfaces.Unsigned_64 (Natural'Last)
      then
         Status := Limit_Exceeded;
         return;
      elsif Payload_Length
        /= Object_Length - Interfaces.Unsigned_64 (LSM.SST_Header_Length + LSM.Object_Trailer_Length)
      then
         Status := Invalid_Length;
         return;
      end if;

      Entry_Wire := Read_U32 (Fixed, 80);
      if Read_U32 (Fixed, 84) /= 0 then
         Status := Invalid_SST_State;
         return;
      elsif Read_Identifier (Fixed, 44) /= Expected_Descriptor.Run_ID
        or else Read_U32 (Fixed, 60) /= Expected_Family
        or else Read_U64 (Fixed, 64) /= Expected_Descriptor.Lowest_Sequence
        or else Read_U64 (Fixed, 72) /= Expected_Descriptor.Highest_Sequence
        or else Entry_Wire /= Expected_Descriptor.Entry_Total
        or else Read_U64 (Fixed, 88) /= Expected_Descriptor.Logical_Payload_Bytes
      then
         Status := Invalid_SST_State;
         return;
      end if;

      if not Multiply_U64
               (Interfaces.Unsigned_64 (Entry_Wire),
                Interfaces.Unsigned_64 (LSM.SST_Entry_Header_Length),
                Entry_Bytes)
      then
         Status := Invalid_Length;
         return;
      end if;
      Exact_Length := Interfaces.Unsigned_64 (LSM.SST_Header_Length + LSM.Object_Trailer_Length);
      if not Add_U64 (Exact_Length, Entry_Bytes, Exact_Length)
        or else not Add_U64 (Exact_Length, Expected_Descriptor.Logical_Payload_Bytes, Exact_Length)
        or else Exact_Length /= Object_Length
      then
         Status := Invalid_Length;
         return;
      elsif Expected_Descriptor.Logical_Payload_Bytes > Interfaces.Unsigned_64 (Natural'Last) then
         Status := Limit_Exceeded;
         return;
      end if;

      Admission :=
        (Object_Length => Natural (Object_Length),
         Entry_Total   => Natural (Entry_Wire),
         Payload_Bytes => Natural (Expected_Descriptor.Logical_Payload_Bytes),
         Format_Version => LSM.SST_Format_Version,
         Header_Length  => LSM.SST_Header_Length,
         Frame_Offset   => LSM.SST_Header_Length,
         Frame_Bytes    => Natural (Payload_Length),
         Index_Offset   => 0,
         Index_Bytes    => 0);
      Status := Decoded;
   end Inspect_SST_Header;

   procedure Inspect_SST_V2_Header
     (Header              : Formats.Byte_Array;
      Expected_Database   : Head_Policy.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : Run_Descriptor;
      Object_Length       : Interfaces.Unsigned_64;
      Admission           : out SST_Header_Admission;
      Status              : out Decode_Status)
   is
      Fixed            : Formats.Byte_Array (0 .. SST_V2_Header_Length - 1);
      Payload_Length   : Interfaces.Unsigned_64;
      Entry_Wire       : Interfaces.Unsigned_32;
      Frame_Offset     : Interfaces.Unsigned_64;
      Frame_Bytes      : Interfaces.Unsigned_64;
      Index_Offset     : Interfaces.Unsigned_64;
      Index_Bytes      : Interfaces.Unsigned_64;
      Entry_Bytes      : Interfaces.Unsigned_64;
      Exact_Frame      : Interfaces.Unsigned_64;
      Index_Fixed      : Interfaces.Unsigned_64;
      Minimum_Index    : Interfaces.Unsigned_64;
      Maximum_Index    : Interfaces.Unsigned_64;
      Expected_Index   : Interfaces.Unsigned_64;
      Expected_Payload : Interfaces.Unsigned_64;
      Expected_Total   : Interfaces.Unsigned_64;
   begin
      Admission := Empty_SST_Header_Admission;
      if Header'Length /= SST_V2_Header_Length then
         Status := Invalid_Length;
         return;
      end if;
      Fixed := Header;
      if Fixed (0 .. 7) /= SST_Magic then
         Status := Invalid_Magic;
         return;
      elsif Read_U16 (Fixed, 8) /= SST_V2_Format_Version then
         Status := Unsupported_Version;
         return;
      elsif Fixed (10) /= LSM.SST_Object_Kind then
         Status := Invalid_Object_Kind;
         return;
      elsif Fixed (11) /= 0 then
         Status := Invalid_Flags;
         return;
      elsif Read_Identifier (Fixed, 12) /= Expected_Database then
         Status := Wrong_Database;
         return;
      elsif Read_U32 (Fixed, 28) /= Interfaces.Unsigned_32 (SST_V2_Header_Length) then
         Status := Invalid_Length;
         return;
      elsif Read_U32 (Fixed, 40) /= Header_Checksum (Fixed, SST_V2_Header_Length) then
         Status := Header_Checksum_Failed;
         return;
      elsif not Valid_Run_Descriptor (Expected_Descriptor) or else Expected_Family = 0 then
         Status := Invalid_SST_State;
         return;
      end if;

      Payload_Length := Read_U64 (Fixed, 32);
      Entry_Wire := Read_U32 (Fixed, 80);
      Frame_Offset := Read_U64 (Fixed, 96);
      Frame_Bytes := Read_U64 (Fixed, 104);
      Index_Offset := Read_U64 (Fixed, 112);
      Index_Bytes := Read_U64 (Fixed, 120);
      if Read_U32 (Fixed, 84) /= 0 then
         Status := Invalid_SST_State;
         return;
      elsif Read_Identifier (Fixed, 44) /= Expected_Descriptor.Run_ID
        or else Read_U32 (Fixed, 60) /= Expected_Family
        or else Read_U64 (Fixed, 64) /= Expected_Descriptor.Lowest_Sequence
        or else Read_U64 (Fixed, 72) /= Expected_Descriptor.Highest_Sequence
        or else Entry_Wire /= Expected_Descriptor.Entry_Total
        or else Read_U64 (Fixed, 88) /= Expected_Descriptor.Logical_Payload_Bytes
      then
         Status := Invalid_SST_State;
         return;
      end if;

      if not Multiply_U64
               (Interfaces.Unsigned_64 (Entry_Wire),
                Interfaces.Unsigned_64
                  (SST_V2_Frame_Header_Length + SST_V2_Frame_Trailer_Length),
                Entry_Bytes)
        or else not Add_U64
                      (Entry_Bytes, Expected_Descriptor.Logical_Payload_Bytes, Exact_Frame)
        or else not Multiply_U64
                      (Interfaces.Unsigned_64 (Entry_Wire),
                       Interfaces.Unsigned_64 (SST_V2_Index_Entry_Header_Length),
                       Index_Fixed)
        or else not Add_U64
                      (Index_Fixed,
                       Interfaces.Unsigned_64 (SST_V2_Index_Trailer_Length),
                       Minimum_Index)
        or else not Add_U64
                      (Minimum_Index,
                       Expected_Descriptor.Logical_Payload_Bytes,
                       Maximum_Index)
      then
         Status := Invalid_Length;
         return;
      end if;

      Expected_Index := Interfaces.Unsigned_64 (SST_V2_Header_Length);
      if not Add_U64 (Expected_Index, Exact_Frame, Expected_Index)
        or else not Add_U64 (Frame_Bytes, Index_Bytes, Expected_Payload)
      then
         Status := Invalid_Length;
         return;
      end if;
      Expected_Total := Expected_Index;
      if not Add_U64 (Expected_Total, Index_Bytes, Expected_Total)
        or else not Add_U64
                      (Expected_Total,
                       Interfaces.Unsigned_64 (LSM.Object_Trailer_Length),
                       Expected_Total)
      then
         Status := Invalid_Length;
         return;
      end if;

      if Object_Length < Interfaces.Unsigned_64
           (SST_V2_Header_Length + SST_V2_Index_Trailer_Length + LSM.Object_Trailer_Length)
        or else Object_Length > Interfaces.Unsigned_64 (Natural'Last)
        or else Payload_Length /= Expected_Payload
        or else Frame_Offset /= Interfaces.Unsigned_64 (SST_V2_Header_Length)
        or else Frame_Bytes /= Exact_Frame
        or else Index_Offset /= Expected_Index
        or else Index_Bytes < Minimum_Index
        or else Index_Bytes > Maximum_Index
        or else Expected_Total /= Object_Length
        or else Expected_Descriptor.Logical_Payload_Bytes
                > Interfaces.Unsigned_64 (Natural'Last)
        or else Frame_Bytes > Interfaces.Unsigned_64 (Natural'Last)
        or else Index_Offset > Interfaces.Unsigned_64 (Natural'Last)
        or else Index_Bytes > Interfaces.Unsigned_64 (Natural'Last)
      then
         Status := Invalid_Length;
         return;
      end if;

      Admission :=
        (Object_Length => Natural (Object_Length),
         Entry_Total   => Natural (Entry_Wire),
         Payload_Bytes => Natural (Expected_Descriptor.Logical_Payload_Bytes),
         Format_Version => SST_V2_Format_Version,
         Header_Length  => SST_V2_Header_Length,
         Frame_Offset   => Natural (Frame_Offset),
         Frame_Bytes    => Natural (Frame_Bytes),
         Index_Offset   => Natural (Index_Offset),
         Index_Bytes    => Natural (Index_Bytes));
      Status := Decoded;
   end Inspect_SST_V2_Header;

   function Same_Key
     (Data         : Formats.Byte_Array;
      Left_Offset  : Natural;
      Left_Length  : Natural;
      Right_Offset : Natural;
      Right_Length : Natural) return Boolean is
   begin
      if Left_Length /= Right_Length then
         return False;
      end if;
      for Offset in Natural range 1 .. Left_Length loop
         if Byte_At (Data, Left_Offset + Offset - 1) /= Byte_At (Data, Right_Offset + Offset - 1) then
            return False;
         end if;
      end loop;
      return True;
   end Same_Key;

   function Key_Less
     (Left_Data    : Formats.Byte_Array;
      Left_Offset  : Natural;
      Left_Length  : Natural;
      Right_Data   : Formats.Byte_Array;
      Right_Offset : Natural;
      Right_Length : Natural) return Boolean
   is
      Common : constant Natural := Natural'Min (Left_Length, Right_Length);
   begin
      for Offset in Natural range 1 .. Common loop
         if Byte_At (Left_Data, Left_Offset + Offset - 1)
           < Byte_At (Right_Data, Right_Offset + Offset - 1)
         then
            return True;
         elsif Byte_At (Left_Data, Left_Offset + Offset - 1)
           > Byte_At (Right_Data, Right_Offset + Offset - 1)
         then
            return False;
         end if;
      end loop;
      return Left_Length < Right_Length;
   end Key_Less;

   function Key_Less
     (Data         : Formats.Byte_Array;
      Left_Offset  : Natural;
      Left_Length  : Natural;
      Right_Offset : Natural;
      Right_Length : Natural) return Boolean
   is
   begin
      return Key_Less (Data, Left_Offset, Left_Length, Data, Right_Offset, Right_Length);
   end Key_Less;

   function Key_Admitted
     (Data            : Formats.Byte_Array;
      Key_Offset      : Natural;
      Key_Length      : Natural;
      Has_Start       : Boolean;
      Start_Key       : Formats.Byte_Array;
      Start_Inclusive : Boolean;
      Has_Upper       : Boolean;
      Upper_Key       : Formats.Byte_Array) return Boolean
   is
      Before_Start : constant Boolean :=
        Has_Start and then Key_Less (Data, Key_Offset, Key_Length, Start_Key, 0, Start_Key'Length);
      At_Start     : constant Boolean :=
        Has_Start
        and then not Before_Start
        and then not Key_Less (Start_Key, 0, Start_Key'Length, Data, Key_Offset, Key_Length);
      Before_Upper : constant Boolean :=
        not Has_Upper or else Key_Less (Data, Key_Offset, Key_Length, Upper_Key, 0, Upper_Key'Length);
   begin
      return
        (not Has_Start or else (not Before_Start and then (Start_Inclusive or else not At_Start)))
        and then Before_Upper;
   end Key_Admitted;

   function Valid_SST_V2_Index (Value : SST_V2_Index) return Boolean is
      Frame_Cursor      : Natural := Value.Frame_Offset;
      Key_Cursor        : Positive := 1;
      Lowest            : Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64'Last;
      Highest           : Interfaces.Unsigned_64 := 0;
      Logical           : Interfaces.Unsigned_64 := 0;
      Previous_Sequence : Interfaces.Unsigned_64 := 0;
   begin
      if Head_Policy.Is_Zero (Value.Database_ID)
        or else Head_Policy.Is_Zero (Value.Run_ID)
        or else Value.Family_ID = 0
        or else Value.Entry_Total = 0
        or else Value.Frame_Offset /= SST_V2_Header_Length
        or else Value.Frame_Byte_Total > Natural'Last - Value.Frame_Offset
        or else Value.Key_Byte_Total = Natural'Last
        or else Value.Lowest_Sequence = 0
        or else Value.Lowest_Sequence > Value.Highest_Sequence
      then
         return False;
      end if;
      for Position in Value.Entries'Range loop
         declare
            Item       : SST_V2_Index_Entry renames Value.Entries (Position);
            Item_Bytes : Interfaces.Unsigned_64;
         begin
            if Item.Frame_Offset /= Frame_Cursor
              or else Item.Frame_Byte_Total
                      < SST_V2_Frame_Header_Length
                        + SST_V2_Frame_Trailer_Length
              or else Item.Key_Offset /= Key_Cursor
              or else Item.Key_Byte_Total
                      > Value.Key_Byte_Total - (Key_Cursor - 1)
              or else Item.Sequence = 0
              or else Item.Sequence < Value.Lowest_Sequence
              or else Item.Sequence > Value.Highest_Sequence
              or else Item.Operation
                      not in LSM.Put_Operation | LSM.Delete_Operation
              or else (Item.Operation = LSM.Delete_Operation
                       and then Item.Value_Byte_Total /= 0)
              or else Item.Key_Byte_Total
                      > Item.Frame_Byte_Total
                        - SST_V2_Frame_Header_Length
                        - SST_V2_Frame_Trailer_Length
              or else Item.Value_Byte_Total
                      /= Item.Frame_Byte_Total
                         - SST_V2_Frame_Header_Length
                         - SST_V2_Frame_Trailer_Length
                         - Item.Key_Byte_Total
              or else Item.Frame_Byte_Total > Natural'Last - Frame_Cursor
            then
               return False;
            end if;
            if Position > Value.Entries'First then
               declare
                  Previous : SST_V2_Index_Entry renames
                    Value.Entries (Position - 1);
               begin
                  if Same_Key
                       (Value.Keys,
                        Previous.Key_Offset - 1,
                        Previous.Key_Byte_Total,
                        Item.Key_Offset - 1,
                        Item.Key_Byte_Total)
                  then
                     if Previous_Sequence <= Item.Sequence then
                        return False;
                     end if;
                  elsif not Key_Less
                              (Value.Keys,
                               Previous.Key_Offset - 1,
                               Previous.Key_Byte_Total,
                               Item.Key_Offset - 1,
                               Item.Key_Byte_Total)
                  then
                     return False;
                  end if;
               end;
            end if;
            Item_Bytes :=
              Interfaces.Unsigned_64 (Item.Key_Byte_Total)
              + Interfaces.Unsigned_64 (Item.Value_Byte_Total);
            if not Add_U64 (Logical, Item_Bytes, Logical) then
               return False;
            end if;
            Frame_Cursor := Frame_Cursor + Item.Frame_Byte_Total;
            Key_Cursor := Key_Cursor + Item.Key_Byte_Total;
            Lowest := Interfaces.Unsigned_64'Min (Lowest, Item.Sequence);
            Highest := Interfaces.Unsigned_64'Max (Highest, Item.Sequence);
            Previous_Sequence := Item.Sequence;
         end;
      end loop;
      return
        Frame_Cursor = Value.Frame_Offset + Value.Frame_Byte_Total
        and then Key_Cursor = Value.Key_Byte_Total + 1
        and then Lowest = Value.Lowest_Sequence
        and then Highest = Value.Highest_Sequence
        and then Logical = Value.Logical_Payload_Bytes;
   end Valid_SST_V2_Index;

   function Next_Visible_Position
     (Value           : SST_V2_Index;
      Snapshot_At     : Interfaces.Unsigned_64;
      Has_Start       : Boolean;
      Start_Key       : Formats.Byte_Array;
      Start_Inclusive : Boolean;
      Has_Upper       : Boolean;
      Upper_Key       : Formats.Byte_Array) return Natural is
   begin
      if Snapshot_At = 0 or else not Valid_SST_V2_Index (Value) then
         return 0;
      end if;
      for Position in Value.Entries'Range loop
         declare
            Item : SST_V2_Index_Entry renames Value.Entries (Position);
         begin
            if Has_Upper
              and then not Key_Less
                             (Value.Keys,
                              Item.Key_Offset - 1,
                              Item.Key_Byte_Total,
                              Upper_Key,
                              0,
                              Upper_Key'Length)
            then
               return 0;
            elsif Item.Sequence <= Snapshot_At
              and then Key_Admitted
                         (Value.Keys,
                          Item.Key_Offset - 1,
                          Item.Key_Byte_Total,
                          Has_Start,
                          Start_Key,
                          Start_Inclusive,
                          Has_Upper,
                          Upper_Key)
            then
               return Position;
            end if;
         end;
      end loop;
      return 0;
   end Next_Visible_Position;

   procedure Decode_SST_V2_Index
     (Image               : Formats.Byte_Array;
      Admission           : SST_Header_Admission;
      Expected_Database   : Head_Policy.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : Run_Descriptor;
      Maximum_Key_Bytes   : Interfaces.Unsigned_64;
      Maximum_Value_Bytes : Interfaces.Unsigned_64;
      Value               : out SST_V2_Index_Access;
      Status              : out Decode_Status)
   is
      Candidate         : SST_V2_Index_Access := null;
      Data_End          : Natural;
      Cursor            : Natural := 0;
      Frame_Cursor      : Natural := Admission.Frame_Offset;
      Key_Bytes         : Interfaces.Unsigned_64 := 0;
      Logical           : Interfaces.Unsigned_64 := 0;
      Lowest            : Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64'Last;
      Highest           : Interfaces.Unsigned_64 := 0;
      Previous_Key      : Natural := 0;
      Previous_Key_Size : Natural := 0;
      Previous_Sequence : Interfaces.Unsigned_64 := 0;
   begin
      Value := null;
      if Image'Length
        < SST_V2_Index_Entry_Header_Length + SST_V2_Index_Trailer_Length
        or else Admission.Format_Version /= SST_V2_Format_Version
        or else Admission.Header_Length /= SST_V2_Header_Length
        or else Admission.Entry_Total = 0
        or else Interfaces.Unsigned_64 (Admission.Entry_Total)
                /= Interfaces.Unsigned_64 (Expected_Descriptor.Entry_Total)
        or else Interfaces.Unsigned_64 (Admission.Payload_Bytes)
                /= Expected_Descriptor.Logical_Payload_Bytes
        or else Admission.Frame_Offset /= SST_V2_Header_Length
        or else Admission.Index_Offset < Admission.Frame_Offset
        or else Admission.Frame_Bytes
                /= Admission.Index_Offset - Admission.Frame_Offset
        or else Admission.Index_Bytes /= Image'Length
        or else not Valid_Run_Descriptor (Expected_Descriptor)
        or else Head_Policy.Is_Zero (Expected_Database)
        or else Expected_Family = 0
      then
         Status := Invalid_Length;
         return;
      end if;
      Data_End := Image'Length - SST_V2_Index_Trailer_Length;
      if Read_U32 (Image, Data_End)
        /= Formats.CRC_32C (Image (Image'First .. Image'First + Data_End - 1))
      then
         Status := Index_Checksum_Failed;
         return;
      end if;

      --  The authenticated index is parsed without allocation first. Its
      --  canonical contiguous frames and key order become retained authority.
      for Position in Positive range 1 .. Admission.Entry_Total loop
         declare
            Frame_Offset : Interfaces.Unsigned_64;
            Frame_Bytes  : Interfaces.Unsigned_64;
            Sequence     : Interfaces.Unsigned_64;
            Operation    : Formats.Byte;
            Key_Wire     : Interfaces.Unsigned_32;
            Value_Wire   : Interfaces.Unsigned_32;
            Key_Total    : Natural;
            Value_Total  : Natural;
            Key_Start    : Natural;
            Exact_Frame  : Interfaces.Unsigned_64;
            Item_Bytes   : Interfaces.Unsigned_64;
         begin
            if Cursor > Data_End
              or else SST_V2_Index_Entry_Header_Length > Data_End - Cursor
            then
               Status := Invalid_Entry;
               return;
            end if;
            Frame_Offset := Read_U64 (Image, Cursor);
            Frame_Bytes := Read_U64 (Image, Cursor + 8);
            Sequence := Read_U64 (Image, Cursor + 16);
            Operation := Byte_At (Image, Cursor + 24);
            Key_Wire := Read_U32 (Image, Cursor + 28);
            Value_Wire := Read_U32 (Image, Cursor + 32);
            if Byte_At (Image, Cursor + 25) /= 0
              or else Read_U16 (Image, Cursor + 26) /= 0
              or else Sequence = 0
              or else Sequence < Expected_Descriptor.Lowest_Sequence
              or else Sequence > Expected_Descriptor.Highest_Sequence
              or else Operation not in LSM.Put_Operation | LSM.Delete_Operation
              or else (Operation = LSM.Delete_Operation
                       and then Value_Wire /= 0)
            then
               Status := Invalid_Entry;
               return;
            elsif Interfaces.Unsigned_64 (Key_Wire) > Maximum_Key_Bytes
              or else Interfaces.Unsigned_64 (Value_Wire) > Maximum_Value_Bytes
            then
               Status := Limit_Exceeded;
               return;
            end if;
            Key_Total := Natural (Key_Wire);
            Value_Total := Natural (Value_Wire);
            Exact_Frame := Interfaces.Unsigned_64 (SST_V2_Frame_Header_Length);
            if not Add_U64
                     (Exact_Frame,
                      Interfaces.Unsigned_64 (Key_Total),
                      Exact_Frame)
              or else not Add_U64
                            (Exact_Frame,
                             Interfaces.Unsigned_64 (Value_Total),
                             Exact_Frame)
              or else not Add_U64
                            (Exact_Frame,
                             Interfaces.Unsigned_64
                               (SST_V2_Frame_Trailer_Length),
                             Exact_Frame)
              or else Frame_Offset /= Interfaces.Unsigned_64 (Frame_Cursor)
              or else Frame_Bytes /= Exact_Frame
              or else Frame_Bytes
                      > Interfaces.Unsigned_64 (Natural'Last - Frame_Cursor)
            then
               Status := Invalid_Entry;
               return;
            end if;
            Cursor := Cursor + SST_V2_Index_Entry_Header_Length;
            if Key_Total > Data_End - Cursor then
               Status := Invalid_Entry;
               return;
            end if;
            Key_Start := Cursor;
            if Position > 1 then
               if Same_Key
                    (Image,
                     Previous_Key,
                     Previous_Key_Size,
                     Key_Start,
                     Key_Total)
               then
                  if Previous_Sequence <= Sequence then
                     Status := Invalid_SST_State;
                     return;
                  end if;
               elsif not Key_Less
                           (Image,
                            Previous_Key,
                            Previous_Key_Size,
                            Key_Start,
                            Key_Total)
               then
                  Status := Invalid_SST_State;
                  return;
               end if;
            end if;
            Item_Bytes :=
              Interfaces.Unsigned_64 (Key_Total)
              + Interfaces.Unsigned_64 (Value_Total);
            if not Add_U64 (Logical, Item_Bytes, Logical)
              or else not Add_U64
                            (Key_Bytes,
                             Interfaces.Unsigned_64 (Key_Total),
                             Key_Bytes)
            then
               Status := Invalid_Length;
               return;
            end if;
            Cursor := Cursor + Key_Total;
            Frame_Cursor := Frame_Cursor + Natural (Frame_Bytes);
            Lowest := Interfaces.Unsigned_64'Min (Lowest, Sequence);
            Highest := Interfaces.Unsigned_64'Max (Highest, Sequence);
            Previous_Key := Key_Start;
            Previous_Key_Size := Key_Total;
            Previous_Sequence := Sequence;
         end;
      end loop;
      if Cursor /= Data_End
        or else Frame_Cursor /= Admission.Index_Offset
        or else Logical /= Expected_Descriptor.Logical_Payload_Bytes
        or else Lowest /= Expected_Descriptor.Lowest_Sequence
        or else Highest /= Expected_Descriptor.Highest_Sequence
        or else Key_Bytes >= Interfaces.Unsigned_64 (Natural'Last)
      then
         Status := Invalid_SST_State;
         return;
      end if;

      Candidate :=
        new SST_V2_Index (Admission.Entry_Total, Natural (Key_Bytes));
      Candidate.Database_ID := Expected_Database;
      Candidate.Run_ID := Expected_Descriptor.Run_ID;
      Candidate.Family_ID := Expected_Family;
      Candidate.Lowest_Sequence := Expected_Descriptor.Lowest_Sequence;
      Candidate.Highest_Sequence := Expected_Descriptor.Highest_Sequence;
      Candidate.Logical_Payload_Bytes :=
        Expected_Descriptor.Logical_Payload_Bytes;
      Candidate.Frame_Offset := Admission.Frame_Offset;
      Candidate.Frame_Byte_Total := Admission.Frame_Bytes;
      Candidate.Entries := [others => <>];
      Candidate.Keys := [others => 0];
      Cursor := 0;
      declare
         Key_Cursor : Positive := 1;
      begin
         for Item of Candidate.Entries loop
            declare
               Key_Total : constant Natural :=
                 Natural (Read_U32 (Image, Cursor + 28));
            begin
               Item.Frame_Offset := Natural (Read_U64 (Image, Cursor));
               Item.Frame_Byte_Total := Natural (Read_U64 (Image, Cursor + 8));
               Item.Sequence := Read_U64 (Image, Cursor + 16);
               Item.Operation := Byte_At (Image, Cursor + 24);
               Item.Key_Offset := Key_Cursor;
               Item.Key_Byte_Total := Key_Total;
               Item.Value_Byte_Total :=
                 Natural (Read_U32 (Image, Cursor + 32));
               Cursor := Cursor + SST_V2_Index_Entry_Header_Length;
               for Offset in Natural range 1 .. Key_Total loop
                  Candidate.Keys (Key_Cursor + Offset - 1) :=
                    Byte_At (Image, Cursor + Offset - 1);
               end loop;
               Cursor := Cursor + Key_Total;
               Key_Cursor := Key_Cursor + Key_Total;
            end;
         end loop;
      end;
      if Cursor /= Data_End or else not Valid_SST_V2_Index (Candidate.all) then
         Release (Candidate);
         Status := Invalid_SST_State;
         return;
      end if;
      Value := Candidate;
      Status := Decoded;
   exception
      when Storage_Error =>
         Release (Candidate);
         Value := null;
         Status := Allocation_Failed;
   end Decode_SST_V2_Index;

   procedure Decode_SST_V2_Frame
     (Image    : Formats.Byte_Array;
      Index    : SST_V2_Index;
      Position : Positive;
      Value    : out SST_V2_Frame_Access;
      Status   : out Decode_Status)
   is
      Candidate : SST_V2_Frame_Access := null;
      Data_End  : Natural;
   begin
      Value := null;
      if not Valid_SST_V2_Index (Index)
        or else Position not in Index.Entries'Range
      then
         Status := Invalid_SST_State;
         return;
      end if;
      declare
         Expected : SST_V2_Index_Entry renames Index.Entries (Position);
      begin
         if Image'Length /= Expected.Frame_Byte_Total
           or else Image'Length
                   < SST_V2_Frame_Header_Length + SST_V2_Frame_Trailer_Length
         then
            Status := Invalid_Length;
            return;
         end if;
         Data_End := Image'Length - SST_V2_Frame_Trailer_Length;
         if Read_U32 (Image, Data_End)
           /= Formats.CRC_32C
                (Image (Image'First .. Image'First + Data_End - 1))
         then
            Status := Frame_Checksum_Failed;
            return;
         end if;
         if Read_U64 (Image, 0) /= Expected.Sequence
           or else Byte_At (Image, 8) /= Expected.Operation
           or else Byte_At (Image, 9) /= 0
           or else Read_U16 (Image, 10) /= 0
           or else Read_U32 (Image, 12)
                   /= Interfaces.Unsigned_32 (Expected.Key_Byte_Total)
           or else Read_U32 (Image, 16)
                   /= Interfaces.Unsigned_32 (Expected.Value_Byte_Total)
           or else Data_End
                   /= SST_V2_Frame_Header_Length
                      + Expected.Key_Byte_Total
                      + Expected.Value_Byte_Total
         then
            Status := Invalid_Entry;
            return;
         end if;
         for Offset in Natural range 1 .. Expected.Key_Byte_Total loop
            if Byte_At (Image, SST_V2_Frame_Header_Length + Offset - 1)
              /= Index.Keys (Expected.Key_Offset + Offset - 1)
            then
               Status := Invalid_SST_State;
               return;
            end if;
         end loop;
         Candidate :=
           new SST_V2_Frame
                 (Expected.Key_Byte_Total + Expected.Value_Byte_Total);
         Candidate.Sequence := Expected.Sequence;
         Candidate.Operation := Expected.Operation;
         Candidate.Key_Byte_Total := Expected.Key_Byte_Total;
         Candidate.Value_Byte_Total := Expected.Value_Byte_Total;
         for Offset in Natural range 1 .. Candidate.Payload_Byte_Total loop
            Candidate.Payload (Offset) :=
              Byte_At (Image, SST_V2_Frame_Header_Length + Offset - 1);
         end loop;
      end;
      Value := Candidate;
      Status := Decoded;
   exception
      when Storage_Error =>
         Release (Candidate);
         Value := null;
         Status := Allocation_Failed;
   end Decode_SST_V2_Frame;

   function Structurally_Valid (Value : SST) return Boolean is
      Cursor  : Positive := 1;
      Lowest  : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Highest : Interfaces.Unsigned_64 := 0;
   begin
      if Head_Policy.Is_Zero (Value.Database_ID)
        or else Head_Policy.Is_Zero (Value.Run_ID)
        or else Value.Family_ID = 0
        or else Value.Entry_Total = 0
        or else Value.Payload_Byte_Total = Natural'Last
        or else Value.Lowest_Sequence = 0
        or else Value.Lowest_Sequence > Value.Highest_Sequence
        or else Value.Logical_Payload_Bytes /= Interfaces.Unsigned_64 (Value.Payload_Byte_Total)
      then
         return False;
      end if;
      for Index in Value.Entries'Range loop
         declare
            Item : SST_Entry renames Value.Entries (Index);
         begin
            if Item.Sequence = 0
              or else Item.Sequence < Value.Lowest_Sequence
              or else Item.Sequence > Value.Highest_Sequence
              or else Item.Operation not in LSM.Put_Operation | LSM.Delete_Operation
              or else (Item.Operation = LSM.Delete_Operation and then Item.Value_Byte_Total /= 0)
              or else Item.Key_Offset /= Cursor
              or else Item.Key_Byte_Total > Value.Payload_Byte_Total - (Cursor - 1)
            then
               return False;
            end if;
            Cursor := Cursor + Item.Key_Byte_Total;
            if Item.Value_Offset /= Cursor
              or else Item.Value_Byte_Total > Value.Payload_Byte_Total - (Cursor - 1)
            then
               return False;
            end if;
            Cursor := Cursor + Item.Value_Byte_Total;
            if Index > Value.Entries'First then
               declare
                  Previous : SST_Entry renames Value.Entries (Index - 1);
               begin
                  if Same_Key
                       (Value.Payload,
                        Previous.Key_Offset - 1,
                        Previous.Key_Byte_Total,
                        Item.Key_Offset - 1,
                        Item.Key_Byte_Total)
                  then
                     if Previous.Sequence <= Item.Sequence then
                        return False;
                     end if;
                  elsif not Key_Less
                              (Value.Payload,
                               Previous.Key_Offset - 1,
                               Previous.Key_Byte_Total,
                               Item.Key_Offset - 1,
                               Item.Key_Byte_Total)
                  then
                     return False;
                  end if;
               end;
            end if;
            Lowest := Interfaces.Unsigned_64'Min (Lowest, Item.Sequence);
            Highest := Interfaces.Unsigned_64'Max (Highest, Item.Sequence);
         end;
      end loop;
      return
        Cursor = Value.Payload_Byte_Total + 1
        and then Lowest = Value.Lowest_Sequence
        and then Highest = Value.Highest_Sequence;
   end Structurally_Valid;

   function Next_Visible_Position
     (Value           : SST;
      Snapshot_At     : Interfaces.Unsigned_64;
      Has_Start       : Boolean;
      Start_Key       : Formats.Byte_Array;
      Start_Inclusive : Boolean;
      Has_Upper       : Boolean;
      Upper_Key       : Formats.Byte_Array) return Natural is
   begin
      if Snapshot_At = 0 or else not Structurally_Valid (Value) then
         return 0;
      end if;
      for Position in Value.Entries'Range loop
         declare
            Item : SST_Entry renames Value.Entries (Position);
         begin
            if Has_Upper
              and then not Key_Less
                             (Value.Payload,
                              Item.Key_Offset - 1,
                              Item.Key_Byte_Total,
                              Upper_Key,
                              0,
                              Upper_Key'Length)
            then
               return 0;
            elsif Item.Sequence <= Snapshot_At
              and then Key_Admitted
                         (Value.Payload,
                          Item.Key_Offset - 1,
                          Item.Key_Byte_Total,
                          Has_Start,
                          Start_Key,
                          Start_Inclusive,
                          Has_Upper,
                          Upper_Key)
            then
               return Position;
            end if;
         end;
      end loop;
      return 0;
   end Next_Visible_Position;

   procedure Merge_Consecutive_SSTs
     (Older         : SST;
      Newer         : SST;
      Output_Run_ID : Head_Policy.Identifier;
      Value         : out SST_Access;
      Status        : out Merge_Status)
   is
      Candidate       : SST_Access := null;
      Allocation      : Allocation_Status;
      Entry_Total     : Natural;
      Payload_Total   : Natural;
      Logical_Total   : Interfaces.Unsigned_64;
      Older_Index     : Positive := Older.Entries'First;
      Newer_Index     : Positive := Newer.Entries'First;
      Older_Remaining : Natural := Older.Entry_Total;
      Newer_Remaining : Natural := Newer.Entry_Total;
      Output_Index    : Natural := 1;
      Payload_Cursor  : Natural := 1;

      procedure Append_Entry (Source : SST; Source_Index : Positive) is
         Source_Entry : SST_Entry renames Source.Entries (Source_Index);
         Target_Entry : SST_Entry renames Candidate.Entries (Output_Index);
      begin
         Target_Entry.Sequence := Source_Entry.Sequence;
         Target_Entry.Operation := Source_Entry.Operation;
         Target_Entry.Key_Offset := Payload_Cursor;
         Target_Entry.Key_Byte_Total := Source_Entry.Key_Byte_Total;
         Target_Entry.Value_Offset := Payload_Cursor + Source_Entry.Key_Byte_Total;
         Target_Entry.Value_Byte_Total := Source_Entry.Value_Byte_Total;
         for Offset in Natural range 1 .. Source_Entry.Key_Byte_Total loop
            Candidate.Payload (Payload_Cursor + Offset - 1) :=
              Source.Payload (Source_Entry.Key_Offset + Offset - 1);
         end loop;
         Payload_Cursor := Payload_Cursor + Source_Entry.Key_Byte_Total;
         for Offset in Natural range 1 .. Source_Entry.Value_Byte_Total loop
            Candidate.Payload (Payload_Cursor + Offset - 1) :=
              Source.Payload (Source_Entry.Value_Offset + Offset - 1);
         end loop;
         Payload_Cursor := Payload_Cursor + Source_Entry.Value_Byte_Total;
         Output_Index := Output_Index + 1;
      end Append_Entry;
   begin
      Value := null;
      if not Structurally_Valid (Older)
        or else not Structurally_Valid (Newer)
        or else Older.Database_ID /= Newer.Database_ID
        or else Older.Family_ID /= Newer.Family_ID
        or else Older.Highest_Sequence >= Newer.Lowest_Sequence
        or else Head_Policy.Is_Zero (Output_Run_ID)
        or else Output_Run_ID = Older.Run_ID
        or else Output_Run_ID = Newer.Run_ID
      then
         Status := Merge_Invalid_Input;
         return;
      end if;
      if Newer.Entry_Total > Natural'Last - Older.Entry_Total
        or else Newer.Payload_Byte_Total > Natural'Last - Older.Payload_Byte_Total
      then
         Status := Merge_Length_Overflow;
         return;
      end if;
      Entry_Total := Older.Entry_Total + Newer.Entry_Total;
      Payload_Total := Older.Payload_Byte_Total + Newer.Payload_Byte_Total;
      if not Add_U64 (Older.Logical_Payload_Bytes, Newer.Logical_Payload_Bytes, Logical_Total) then
         Status := Merge_Length_Overflow;
         return;
      end if;
      Create_SST (Entry_Total, Payload_Total, Candidate, Allocation);
      if Allocation = Allocation_Failed then
         Status := Merge_Allocation_Failed;
         return;
      elsif Allocation /= Allocated then
         Status := Merge_Length_Overflow;
         return;
      end if;
      Candidate.Database_ID := Older.Database_ID;
      Candidate.Run_ID := Output_Run_ID;
      Candidate.Family_ID := Older.Family_ID;
      Candidate.Lowest_Sequence := Older.Lowest_Sequence;
      Candidate.Highest_Sequence := Newer.Highest_Sequence;
      Candidate.Logical_Payload_Bytes := Logical_Total;

      while Older_Remaining > 0 or else Newer_Remaining > 0 loop
         if Older_Remaining = 0 then
            Append_Entry (Newer, Newer_Index);
            Newer_Remaining := Newer_Remaining - 1;
            if Newer_Remaining > 0 then
               Newer_Index := Newer_Index + 1;
            end if;
         elsif Newer_Remaining = 0 then
            Append_Entry (Older, Older_Index);
            Older_Remaining := Older_Remaining - 1;
            if Older_Remaining > 0 then
               Older_Index := Older_Index + 1;
            end if;
         else
            declare
               Older_Entry : SST_Entry renames Older.Entries (Older_Index);
               Newer_Entry : SST_Entry renames Newer.Entries (Newer_Index);
            begin
               if Key_Less
                    (Older.Payload,
                     Older_Entry.Key_Offset - 1,
                     Older_Entry.Key_Byte_Total,
                     Newer.Payload,
                     Newer_Entry.Key_Offset - 1,
                     Newer_Entry.Key_Byte_Total)
               then
                  Append_Entry (Older, Older_Index);
                  Older_Remaining := Older_Remaining - 1;
                  if Older_Remaining > 0 then
                     Older_Index := Older_Index + 1;
                  end if;
               else
                  --  A newer equal-key entry precedes every older version;
                  --  distinct sequence ranges make this order unambiguous.
                  Append_Entry (Newer, Newer_Index);
                  Newer_Remaining := Newer_Remaining - 1;
                  if Newer_Remaining > 0 then
                     Newer_Index := Newer_Index + 1;
                  end if;
               end if;
            end;
         end if;
      end loop;
      if Output_Index /= Entry_Total + 1
        or else Payload_Cursor /= Payload_Total + 1
        or else not Structurally_Valid (Candidate.all)
      then
         Release (Candidate);
         Status := Merge_Invalid_Input;
         return;
      end if;
      Value := Candidate;
      Status := Merge_Completed;
   exception
      when others =>
         Release (Candidate);
         Value := null;
         raise;
   end Merge_Consecutive_SSTs;

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
       and then Interfaces.Unsigned_64 (Value.Entry_Total) = Interfaces.Unsigned_64 (Descriptor.Entry_Total)
       and then Value.Logical_Payload_Bytes = Descriptor.Logical_Payload_Bytes);

   procedure Merge_Manifest_Adjacent_SSTs
     (Current       : Checkpoint_Manifest;
      Older         : SST;
      Newer         : SST;
      Output_Run_ID : Head_Policy.Identifier;
      Value         : out SST_Access;
      Status        : out Merge_Status) is
   begin
      Value := null;
      if not Structurally_Valid (Current) or else Older.Family_ID /= Newer.Family_ID then
         Status := Merge_Invalid_Input;
         return;
      end if;
      for Descriptor of Current.Runs loop
         if Descriptor.Run_ID = Output_Run_ID then
            Status := Merge_Invalid_Input;
            return;
         end if;
      end loop;
      for Family_Index in Current.Families'Range loop
         if Current.Base.Families (Family_Index).ID = Older.Family_ID then
            declare
               Family : Family_LSM_State renames Current.Families (Family_Index);
            begin
               if Family.Run_Total < 2 then
                  Status := Merge_Invalid_Input;
                  return;
               end if;
               for Run_Index in Positive range Family.First_Run .. Family.First_Run + Family.Run_Total - 2
               loop
                  if Descriptor_Matches
                       (Older, Current.Base.Database_ID, Older.Family_ID, Current.Runs (Run_Index))
                    and then Descriptor_Matches
                               (Newer,
                                Current.Base.Database_ID,
                                Newer.Family_ID,
                                Current.Runs (Run_Index + 1))
                  then
                     Merge_Consecutive_SSTs (Older, Newer, Output_Run_ID, Value, Status);
                     return;
                  end if;
               end loop;
               Status := Merge_Invalid_Input;
               return;
            end;
         end if;
      end loop;
      Status := Merge_Invalid_Input;
   end Merge_Manifest_Adjacent_SSTs;

   procedure Build_Adjacent_Merge_Successor
     (Current        : Checkpoint_Manifest;
      Successor_Base : Manifests.Manifest;
      Older          : SST;
      Newer          : SST;
      Output_Run_ID  : Head_Policy.Identifier;
      Merged          : out SST_Access;
      Successor       : out Checkpoint_Manifest_Access;
      Status          : out Merge_Status)
   is
      Candidate    : Checkpoint_Manifest_Access := null;
      Allocation   : Allocation_Status;
      Output_Index : Natural := 0;
      Replaced     : Boolean := False;
   begin
      Merged := null;
      Successor := null;
      if not Structurally_Valid (Current)
        or else not Manifests.Valid_Checkpoint_Predecessor (Successor_Base, Current.Base)
      then
         Status := Merge_Invalid_Input;
         return;
      end if;
      Merge_Manifest_Adjacent_SSTs
        (Current, Older, Newer, Output_Run_ID, Merged, Status);
      if Status /= Merge_Completed then
         return;
      end if;

      Create_Checkpoint_Manifest
        (Current.Family_Total,
         Current.Run_Total - 1,
         Current.Identity_Total,
         Candidate,
         Allocation);
      if Allocation /= Allocated then
         Release (Merged);
         Status :=
           (if Allocation = Allocation_Failed
            then Merge_Allocation_Failed
            else Merge_Length_Overflow);
         return;
      end if;
      Candidate.Base := Successor_Base;
      Candidate.Replay_Boundary := Current.Replay_Boundary;
      Candidate.Maximum_Total_L0_Runs := Current.Maximum_Total_L0_Runs;
      Candidate.Maximum_Checkpoint_Identities := Current.Maximum_Checkpoint_Identities;
      Candidate.Maximum_Point_Reads_Per_Transaction :=
        Current.Maximum_Point_Reads_Per_Transaction;
      Candidate.Maximum_Scan_Ranges_Per_Transaction :=
        Current.Maximum_Scan_Ranges_Per_Transaction;
      Candidate.Identities := Current.Identities;

      for Family_Index in Current.Families'Range loop
         declare
            Source           : Family_LSM_State renames Current.Families (Family_Index);
            Target           : Family_LSM_State renames Candidate.Families (Family_Index);
            Source_Index     : Natural := Source.First_Run;
            Source_Remaining : Natural := Source.Run_Total;
            Selected         : constant Boolean :=
              Current.Base.Families (Family_Index).ID = Older.Family_ID;
         begin
            Target := Source;
            Target.First_Run := (if Source.Run_Total = 0 then 0 else Output_Index + 1);
            if Selected then
               Target.Run_Total := Source.Run_Total - 1;
            end if;
            while Source_Remaining > 0 loop
               if Selected
                 and then not Replaced
                 and then Source_Remaining >= 2
                 and then Descriptor_Matches
                            (Older,
                             Current.Base.Database_ID,
                             Older.Family_ID,
                             Current.Runs (Source_Index))
                 and then Descriptor_Matches
                            (Newer,
                             Current.Base.Database_ID,
                             Newer.Family_ID,
                             Current.Runs (Source_Index + 1))
               then
                  Output_Index := Output_Index + 1;
                  Candidate.Runs (Output_Index) :=
                    (Run_ID                => Merged.Run_ID,
                     Lowest_Sequence       => Merged.Lowest_Sequence,
                     Highest_Sequence      => Merged.Highest_Sequence,
                     Entry_Total           => Interfaces.Unsigned_32 (Merged.Entry_Total),
                     Logical_Payload_Bytes => Merged.Logical_Payload_Bytes);
                  Source_Remaining := Source_Remaining - 2;
                  if Source_Remaining > 0 then
                     Source_Index := Source_Index + 2;
                  end if;
                  Replaced := True;
               else
                  Output_Index := Output_Index + 1;
                  Candidate.Runs (Output_Index) := Current.Runs (Source_Index);
                  Source_Remaining := Source_Remaining - 1;
                  if Source_Remaining > 0 then
                     Source_Index := Source_Index + 1;
                  end if;
               end if;
            end loop;
         end;
      end loop;
      if not Replaced
        or else Output_Index /= Candidate.Run_Total
        or else not Structurally_Valid (Candidate.all)
      then
         Release (Candidate);
         Release (Merged);
         Status := Merge_Invalid_Input;
         return;
      end if;
      Successor := Candidate;
      Status := Merge_Completed;
   exception
      when others =>
         Release (Candidate);
         Release (Merged);
         Successor := null;
         raise;
   end Build_Adjacent_Merge_Successor;

   procedure Merge_Three_Consecutive_SSTs
     (First_Run      : SST;
      Middle_Run     : SST;
      Last_Run       : SST;
      Output_Run_ID  : Head_Policy.Identifier;
      Value          : out SST_Access;
      Status         : out Merge_Status)
   is
      Candidate        : SST_Access := null;
      Allocation       : Allocation_Status;
      Entry_Total      : Natural;
      Partial_Entries  : Natural;
      Payload_Total    : Natural;
      Partial_Payload  : Natural;
      Logical_Total    : Interfaces.Unsigned_64;
      Partial_Logical  : Interfaces.Unsigned_64;
      First_Index      : Positive := First_Run.Entries'First;
      Middle_Index     : Positive := Middle_Run.Entries'First;
      Last_Index       : Positive := Last_Run.Entries'First;
      First_Remaining  : Natural := First_Run.Entry_Total;
      Middle_Remaining : Natural := Middle_Run.Entry_Total;
      Last_Remaining   : Natural := Last_Run.Entry_Total;
      Output_Index     : Natural := 1;
      Payload_Cursor   : Natural := 1;

      function Precedes
        (Left_Table  : SST;
         Left_Index  : Positive;
         Right_Table : SST;
         Right_Index : Positive) return Boolean
      is
         Left_Entry  : SST_Entry renames Left_Table.Entries (Left_Index);
         Right_Entry : SST_Entry renames Right_Table.Entries (Right_Index);
      begin
         if Key_Less
              (Left_Table.Payload,
               Left_Entry.Key_Offset - 1,
               Left_Entry.Key_Byte_Total,
               Right_Table.Payload,
               Right_Entry.Key_Offset - 1,
               Right_Entry.Key_Byte_Total)
         then
            return True;
         elsif Key_Less
                 (Right_Table.Payload,
                  Right_Entry.Key_Offset - 1,
                  Right_Entry.Key_Byte_Total,
                  Left_Table.Payload,
                  Left_Entry.Key_Offset - 1,
                  Left_Entry.Key_Byte_Total)
         then
            return False;
         else
            --  Equal keys retain descending sequence order across the three
            --  disjoint persisted sequence ranges.
            return Left_Entry.Sequence > Right_Entry.Sequence;
         end if;
      end Precedes;

      procedure Append_Entry (Source : SST; Source_Index : Positive) is
         Source_Entry : SST_Entry renames Source.Entries (Source_Index);
         Target_Entry : SST_Entry renames Candidate.Entries (Output_Index);
      begin
         Target_Entry.Sequence := Source_Entry.Sequence;
         Target_Entry.Operation := Source_Entry.Operation;
         Target_Entry.Key_Offset := Payload_Cursor;
         Target_Entry.Key_Byte_Total := Source_Entry.Key_Byte_Total;
         Target_Entry.Value_Offset := Payload_Cursor + Source_Entry.Key_Byte_Total;
         Target_Entry.Value_Byte_Total := Source_Entry.Value_Byte_Total;
         for Offset in Natural range 1 .. Source_Entry.Key_Byte_Total loop
            Candidate.Payload (Payload_Cursor + Offset - 1) :=
              Source.Payload (Source_Entry.Key_Offset + Offset - 1);
         end loop;
         Payload_Cursor := Payload_Cursor + Source_Entry.Key_Byte_Total;
         for Offset in Natural range 1 .. Source_Entry.Value_Byte_Total loop
            Candidate.Payload (Payload_Cursor + Offset - 1) :=
              Source.Payload (Source_Entry.Value_Offset + Offset - 1);
         end loop;
         Payload_Cursor := Payload_Cursor + Source_Entry.Value_Byte_Total;
         Output_Index := Output_Index + 1;
      end Append_Entry;
   begin
      Value := null;
      if not Structurally_Valid (First_Run)
        or else not Structurally_Valid (Middle_Run)
        or else not Structurally_Valid (Last_Run)
        or else First_Run.Database_ID /= Middle_Run.Database_ID
        or else First_Run.Database_ID /= Last_Run.Database_ID
        or else First_Run.Family_ID /= Middle_Run.Family_ID
        or else First_Run.Family_ID /= Last_Run.Family_ID
        or else First_Run.Highest_Sequence >= Middle_Run.Lowest_Sequence
        or else Middle_Run.Highest_Sequence >= Last_Run.Lowest_Sequence
        or else Head_Policy.Is_Zero (Output_Run_ID)
        or else Output_Run_ID = First_Run.Run_ID
        or else Output_Run_ID = Middle_Run.Run_ID
        or else Output_Run_ID = Last_Run.Run_ID
      then
         Status := Merge_Invalid_Input;
         return;
      end if;
      if Middle_Run.Entry_Total > Natural'Last - First_Run.Entry_Total then
         Status := Merge_Length_Overflow;
         return;
      end if;
      Partial_Entries := First_Run.Entry_Total + Middle_Run.Entry_Total;
      if Last_Run.Entry_Total > Natural'Last - Partial_Entries
        or else Middle_Run.Payload_Byte_Total > Natural'Last - First_Run.Payload_Byte_Total
      then
         Status := Merge_Length_Overflow;
         return;
      end if;
      Entry_Total := Partial_Entries + Last_Run.Entry_Total;
      Partial_Payload := First_Run.Payload_Byte_Total + Middle_Run.Payload_Byte_Total;
      if Last_Run.Payload_Byte_Total > Natural'Last - Partial_Payload
        or else not Add_U64
                      (First_Run.Logical_Payload_Bytes,
                       Middle_Run.Logical_Payload_Bytes,
                       Partial_Logical)
        or else not Add_U64
                      (Partial_Logical, Last_Run.Logical_Payload_Bytes, Logical_Total)
      then
         Status := Merge_Length_Overflow;
         return;
      end if;
      Payload_Total := Partial_Payload + Last_Run.Payload_Byte_Total;
      Create_SST (Entry_Total, Payload_Total, Candidate, Allocation);
      if Allocation = Allocation_Failed then
         Status := Merge_Allocation_Failed;
         return;
      elsif Allocation /= Allocated then
         Status := Merge_Length_Overflow;
         return;
      end if;
      Candidate.Database_ID := First_Run.Database_ID;
      Candidate.Run_ID := Output_Run_ID;
      Candidate.Family_ID := First_Run.Family_ID;
      Candidate.Lowest_Sequence := First_Run.Lowest_Sequence;
      Candidate.Highest_Sequence := Last_Run.Highest_Sequence;
      Candidate.Logical_Payload_Bytes := Logical_Total;

      while First_Remaining > 0 or else Middle_Remaining > 0 or else Last_Remaining > 0 loop
         declare
            Source : Natural := 0;
         begin
            if First_Remaining > 0 then
               Source := 1;
            end if;
            if Middle_Remaining > 0
              and then
                (Source = 0
                 or else Precedes (Middle_Run, Middle_Index, First_Run, First_Index))
            then
               Source := 2;
            end if;
            if Last_Remaining > 0
              and then
                (Source = 0
                 or else
                   (Source = 1
                    and then Precedes (Last_Run, Last_Index, First_Run, First_Index))
                 or else
                   (Source = 2
                    and then Precedes (Last_Run, Last_Index, Middle_Run, Middle_Index)))
            then
               Source := 3;
            end if;
            case Source is
               when 1 =>
                  Append_Entry (First_Run, First_Index);
                  First_Remaining := First_Remaining - 1;
                  if First_Remaining > 0 then
                     First_Index := First_Index + 1;
                  end if;
               when 2 =>
                  Append_Entry (Middle_Run, Middle_Index);
                  Middle_Remaining := Middle_Remaining - 1;
                  if Middle_Remaining > 0 then
                     Middle_Index := Middle_Index + 1;
                  end if;
               when 3 =>
                  Append_Entry (Last_Run, Last_Index);
                  Last_Remaining := Last_Remaining - 1;
                  if Last_Remaining > 0 then
                     Last_Index := Last_Index + 1;
                  end if;
               when others =>
                  Release (Candidate);
                  Status := Merge_Invalid_Input;
                  return;
            end case;
         end;
      end loop;
      if Output_Index /= Entry_Total + 1
        or else Payload_Cursor /= Payload_Total + 1
        or else not Structurally_Valid (Candidate.all)
      then
         Release (Candidate);
         Status := Merge_Invalid_Input;
         return;
      end if;
      Value := Candidate;
      Status := Merge_Completed;
   exception
      when others =>
         Release (Candidate);
         Value := null;
         raise;
   end Merge_Three_Consecutive_SSTs;

   procedure Merge_Manifest_Three_Adjacent_SSTs
     (Current        : Checkpoint_Manifest;
      First_Run      : SST;
      Middle_Run     : SST;
      Last_Run       : SST;
      Output_Run_ID  : Head_Policy.Identifier;
      Value          : out SST_Access;
      Status         : out Merge_Status) is
   begin
      Value := null;
      if not Structurally_Valid (Current)
        or else First_Run.Family_ID /= Middle_Run.Family_ID
        or else First_Run.Family_ID /= Last_Run.Family_ID
      then
         Status := Merge_Invalid_Input;
         return;
      end if;
      for Descriptor of Current.Runs loop
         if Descriptor.Run_ID = Output_Run_ID then
            Status := Merge_Invalid_Input;
            return;
         end if;
      end loop;
      for Family_Index in Current.Families'Range loop
         if Current.Base.Families (Family_Index).ID = First_Run.Family_ID then
            declare
               Family : Family_LSM_State renames Current.Families (Family_Index);
            begin
               if Family.Run_Total < 3 then
                  Status := Merge_Invalid_Input;
                  return;
               end if;
               for Run_Index in Positive range
                 Family.First_Run .. Family.First_Run + Family.Run_Total - 3
               loop
                  if Descriptor_Matches
                       (First_Run,
                        Current.Base.Database_ID,
                        First_Run.Family_ID,
                        Current.Runs (Run_Index))
                    and then Descriptor_Matches
                               (Middle_Run,
                                Current.Base.Database_ID,
                                Middle_Run.Family_ID,
                                Current.Runs (Run_Index + 1))
                    and then Descriptor_Matches
                               (Last_Run,
                                Current.Base.Database_ID,
                                Last_Run.Family_ID,
                                Current.Runs (Run_Index + 2))
                  then
                     Merge_Three_Consecutive_SSTs
                       (First_Run, Middle_Run, Last_Run, Output_Run_ID, Value, Status);
                     return;
                  end if;
               end loop;
               Status := Merge_Invalid_Input;
               return;
            end;
         end if;
      end loop;
      Status := Merge_Invalid_Input;
   end Merge_Manifest_Three_Adjacent_SSTs;

   procedure Build_Three_Run_Merge_Successor
     (Current        : Checkpoint_Manifest;
      Successor_Base : Manifests.Manifest;
      First_Run      : SST;
      Middle_Run     : SST;
      Last_Run       : SST;
      Output_Run_ID  : Head_Policy.Identifier;
      Merged         : out SST_Access;
      Successor      : out Checkpoint_Manifest_Access;
      Status         : out Merge_Status)
   is
      Candidate    : Checkpoint_Manifest_Access := null;
      Allocation   : Allocation_Status;
      Output_Index : Natural := 0;
      Replaced     : Boolean := False;
   begin
      Merged := null;
      Successor := null;
      if not Structurally_Valid (Current)
        or else not Manifests.Valid_Checkpoint_Predecessor (Successor_Base, Current.Base)
      then
         Status := Merge_Invalid_Input;
         return;
      end if;
      Merge_Manifest_Three_Adjacent_SSTs
        (Current, First_Run, Middle_Run, Last_Run, Output_Run_ID, Merged, Status);
      if Status /= Merge_Completed then
         return;
      end if;

      Create_Checkpoint_Manifest
        (Current.Family_Total,
         Current.Run_Total - 2,
         Current.Identity_Total,
         Candidate,
         Allocation);
      if Allocation /= Allocated then
         Release (Merged);
         Status :=
           (if Allocation = Allocation_Failed
            then Merge_Allocation_Failed
            else Merge_Length_Overflow);
         return;
      end if;
      Candidate.Base := Successor_Base;
      Candidate.Replay_Boundary := Current.Replay_Boundary;
      Candidate.Maximum_Total_L0_Runs := Current.Maximum_Total_L0_Runs;
      Candidate.Maximum_Checkpoint_Identities := Current.Maximum_Checkpoint_Identities;
      Candidate.Maximum_Point_Reads_Per_Transaction :=
        Current.Maximum_Point_Reads_Per_Transaction;
      Candidate.Maximum_Scan_Ranges_Per_Transaction :=
        Current.Maximum_Scan_Ranges_Per_Transaction;
      Candidate.Identities := Current.Identities;

      for Family_Index in Current.Families'Range loop
         declare
            Source           : Family_LSM_State renames Current.Families (Family_Index);
            Target           : Family_LSM_State renames Candidate.Families (Family_Index);
            Source_Index     : Natural := Source.First_Run;
            Source_Remaining : Natural := Source.Run_Total;
            Selected         : constant Boolean :=
              Current.Base.Families (Family_Index).ID = First_Run.Family_ID;
         begin
            Target := Source;
            Target.First_Run := (if Source.Run_Total = 0 then 0 else Output_Index + 1);
            if Selected then
               Target.Run_Total := Source.Run_Total - 2;
            end if;
            while Source_Remaining > 0 loop
               if Selected
                 and then not Replaced
                 and then Source_Remaining >= 3
                 and then Descriptor_Matches
                            (First_Run,
                             Current.Base.Database_ID,
                             First_Run.Family_ID,
                             Current.Runs (Source_Index))
                 and then Descriptor_Matches
                            (Middle_Run,
                             Current.Base.Database_ID,
                             Middle_Run.Family_ID,
                             Current.Runs (Source_Index + 1))
                 and then Descriptor_Matches
                            (Last_Run,
                             Current.Base.Database_ID,
                             Last_Run.Family_ID,
                             Current.Runs (Source_Index + 2))
               then
                  Output_Index := Output_Index + 1;
                  Candidate.Runs (Output_Index) :=
                    (Run_ID                => Merged.Run_ID,
                     Lowest_Sequence       => Merged.Lowest_Sequence,
                     Highest_Sequence      => Merged.Highest_Sequence,
                     Entry_Total           => Interfaces.Unsigned_32 (Merged.Entry_Total),
                     Logical_Payload_Bytes => Merged.Logical_Payload_Bytes);
                  Source_Remaining := Source_Remaining - 3;
                  if Source_Remaining > 0 then
                     Source_Index := Source_Index + 3;
                  end if;
                  Replaced := True;
               else
                  Output_Index := Output_Index + 1;
                  Candidate.Runs (Output_Index) := Current.Runs (Source_Index);
                  Source_Remaining := Source_Remaining - 1;
                  if Source_Remaining > 0 then
                     Source_Index := Source_Index + 1;
                  end if;
               end if;
            end loop;
         end;
      end loop;
      if not Replaced
        or else Output_Index /= Candidate.Run_Total
        or else not Structurally_Valid (Candidate.all)
      then
         Release (Candidate);
         Release (Merged);
         Status := Merge_Invalid_Input;
         return;
      end if;
      Successor := Candidate;
      Status := Merge_Completed;
   exception
      when others =>
         Release (Candidate);
         Release (Merged);
         Successor := null;
         raise;
   end Build_Three_Run_Merge_Successor;

   procedure Encode_SST (Value : SST; Image : out Image_Access; Status : out Encode_Status) is
      Entry_Bytes : Interfaces.Unsigned_64;
      Total       : Interfaces.Unsigned_64;
      Length      : Natural;
      Cursor      : Natural := LSM.SST_Header_Length;
   begin
      Image := null;
      if not Structurally_Valid (Value) then
         Status := Invalid_Value;
         return;
      end if;
      if not Multiply_U64
               (Interfaces.Unsigned_64 (Value.Entry_Total),
                Interfaces.Unsigned_64 (LSM.SST_Entry_Header_Length),
                Entry_Bytes)
      then
         Status := Length_Overflow;
         return;
      end if;
      Total := Interfaces.Unsigned_64 (LSM.SST_Header_Length + LSM.Object_Trailer_Length);
      if not Add_U64 (Total, Entry_Bytes, Total)
        or else not Add_U64 (Total, Interfaces.Unsigned_64 (Value.Payload_Byte_Total), Total)
        or else Total > Interfaces.Unsigned_64 (Natural'Last)
      then
         Status := Length_Overflow;
         return;
      end if;
      Length := Natural (Total);
      Image := new Formats.Byte_Array'(0 .. Length - 1 => 0);

      --  Frozen SST-v1 offsets are common envelope 0..43 followed by run 44,
      --  family 60, sequences 64/72, count/reserved 80/84, and logical 88.
      Image (0 .. 7) := SST_Magic;
      Put_U16 (Image.all, 8, LSM.SST_Format_Version);
      Image (10) := LSM.SST_Object_Kind;
      Image (11) := 0;
      Put_Identifier (Image.all, 12, Value.Database_ID);
      Put_U32 (Image.all, 28, Interfaces.Unsigned_32 (LSM.SST_Header_Length));
      Put_U64
        (Image.all, 32, Interfaces.Unsigned_64 (Length - LSM.SST_Header_Length - LSM.Object_Trailer_Length));
      Put_Identifier (Image.all, 44, Value.Run_ID);
      Put_U32 (Image.all, 60, Value.Family_ID);
      Put_U64 (Image.all, 64, Value.Lowest_Sequence);
      Put_U64 (Image.all, 72, Value.Highest_Sequence);
      Put_U32 (Image.all, 80, Interfaces.Unsigned_32 (Value.Entry_Total));
      Put_U32 (Image.all, 84, 0);
      Put_U64 (Image.all, 88, Value.Logical_Payload_Bytes);
      Put_U32
        (Image.all, 40, Header_Checksum (Image (0 .. LSM.SST_Header_Length - 1), LSM.SST_Header_Length));

      for Index in Value.Entries'Range loop
         declare
            Item : SST_Entry renames Value.Entries (Index);
         begin
            Put_U64 (Image.all, Cursor, Item.Sequence);
            Image (Cursor + 8) := Item.Operation;
            Image (Cursor + 9) := 0;
            Put_U16 (Image.all, Cursor + 10, 0);
            Put_U32 (Image.all, Cursor + 12, Interfaces.Unsigned_32 (Item.Key_Byte_Total));
            Put_U32 (Image.all, Cursor + 16, Interfaces.Unsigned_32 (Item.Value_Byte_Total));
            Cursor := Cursor + LSM.SST_Entry_Header_Length;
            for Offset in Natural range 1 .. Item.Key_Byte_Total loop
               Image (Cursor + Offset - 1) := Value.Payload (Item.Key_Offset + Offset - 1);
            end loop;
            Cursor := Cursor + Item.Key_Byte_Total;
            for Offset in Natural range 1 .. Item.Value_Byte_Total loop
               Image (Cursor + Offset - 1) := Value.Payload (Item.Value_Offset + Offset - 1);
            end loop;
            Cursor := Cursor + Item.Value_Byte_Total;
         end;
      end loop;
      if Cursor + LSM.Object_Trailer_Length /= Length then
         Release (Image);
         Status := Invalid_Value;
         return;
      end if;
      Put_U32 (Image.all, Cursor, Formats.CRC_32C (Image (0 .. Cursor - 1)));
      Status := Encoded;
   exception
      when Storage_Error =>
         Release (Image);
         Status := Allocation_Failed;
   end Encode_SST;

   procedure Encode_SST_V2 (Value : SST; Image : out Image_Access; Status : out Encode_Status) is
      Frame_Fixed  : Interfaces.Unsigned_64;
      Frame_Bytes  : Interfaces.Unsigned_64;
      Index_Fixed  : Interfaces.Unsigned_64;
      Index_Bytes  : Interfaces.Unsigned_64;
      Key_Bytes    : Interfaces.Unsigned_64 := 0;
      Total        : Interfaces.Unsigned_64;
      Length       : Natural;
      Frame_Cursor : Natural := SST_V2_Header_Length;
      Index_Cursor : Natural;
      Object_CRC   : Natural;
   begin
      Image := null;
      if not Structurally_Valid (Value) then
         Status := Invalid_Value;
         return;
      end if;
      for Item of Value.Entries loop
         if not Add_U64 (Key_Bytes, Interfaces.Unsigned_64 (Item.Key_Byte_Total), Key_Bytes) then
            Status := Length_Overflow;
            return;
         end if;
      end loop;
      if not Multiply_U64
               (Interfaces.Unsigned_64 (Value.Entry_Total),
                Interfaces.Unsigned_64
                  (SST_V2_Frame_Header_Length + SST_V2_Frame_Trailer_Length),
                Frame_Fixed)
        or else not Add_U64
                      (Frame_Fixed, Interfaces.Unsigned_64 (Value.Payload_Byte_Total), Frame_Bytes)
        or else not Multiply_U64
                      (Interfaces.Unsigned_64 (Value.Entry_Total),
                       Interfaces.Unsigned_64 (SST_V2_Index_Entry_Header_Length),
                       Index_Fixed)
        or else not Add_U64 (Index_Fixed, Key_Bytes, Index_Bytes)
        or else not Add_U64
                      (Index_Bytes,
                       Interfaces.Unsigned_64 (SST_V2_Index_Trailer_Length),
                       Index_Bytes)
      then
         Status := Length_Overflow;
         return;
      end if;
      Total := Interfaces.Unsigned_64 (SST_V2_Header_Length + LSM.Object_Trailer_Length);
      if not Add_U64 (Total, Frame_Bytes, Total)
        or else not Add_U64 (Total, Index_Bytes, Total)
        or else Total > Interfaces.Unsigned_64 (Natural'Last)
      then
         Status := Length_Overflow;
         return;
      end if;
      Length := Natural (Total);
      Index_Cursor := SST_V2_Header_Length + Natural (Frame_Bytes);
      Object_CRC := Length - LSM.Object_Trailer_Length;
      Image := new Formats.Byte_Array'(0 .. Length - 1 => 0);

      --  Frozen SST-v2 offsets extend the v1 authenticated descriptor prefix:
      --  frame offset/bytes are 96/104 and index offset/bytes are 112/120.
      Image (0 .. 7) := SST_Magic;
      Put_U16 (Image.all, 8, SST_V2_Format_Version);
      Image (10) := LSM.SST_Object_Kind;
      Image (11) := 0;
      Put_Identifier (Image.all, 12, Value.Database_ID);
      Put_U32 (Image.all, 28, Interfaces.Unsigned_32 (SST_V2_Header_Length));
      Put_U64 (Image.all, 32, Frame_Bytes + Index_Bytes);
      Put_Identifier (Image.all, 44, Value.Run_ID);
      Put_U32 (Image.all, 60, Value.Family_ID);
      Put_U64 (Image.all, 64, Value.Lowest_Sequence);
      Put_U64 (Image.all, 72, Value.Highest_Sequence);
      Put_U32 (Image.all, 80, Interfaces.Unsigned_32 (Value.Entry_Total));
      Put_U32 (Image.all, 84, 0);
      Put_U64 (Image.all, 88, Value.Logical_Payload_Bytes);
      Put_U64 (Image.all, 96, Interfaces.Unsigned_64 (SST_V2_Header_Length));
      Put_U64 (Image.all, 104, Frame_Bytes);
      Put_U64 (Image.all, 112, Interfaces.Unsigned_64 (Index_Cursor));
      Put_U64 (Image.all, 120, Index_Bytes);
      Put_U32
        (Image.all,
         40,
         Header_Checksum (Image (0 .. SST_V2_Header_Length - 1), SST_V2_Header_Length));

      for Item of Value.Entries loop
         declare
            Frame_Start  : constant Natural := Frame_Cursor;
            Frame_Extent : Natural;
         begin
            Put_U64 (Image.all, Frame_Cursor, Item.Sequence);
            Image (Frame_Cursor + 8) := Item.Operation;
            Image (Frame_Cursor + 9) := 0;
            Put_U16 (Image.all, Frame_Cursor + 10, 0);
            Put_U32 (Image.all, Frame_Cursor + 12, Interfaces.Unsigned_32 (Item.Key_Byte_Total));
            Put_U32
              (Image.all, Frame_Cursor + 16, Interfaces.Unsigned_32 (Item.Value_Byte_Total));
            Frame_Cursor := Frame_Cursor + SST_V2_Frame_Header_Length;
            for Offset in Natural range 1 .. Item.Key_Byte_Total loop
               Image (Frame_Cursor + Offset - 1) := Value.Payload (Item.Key_Offset + Offset - 1);
            end loop;
            Frame_Cursor := Frame_Cursor + Item.Key_Byte_Total;
            for Offset in Natural range 1 .. Item.Value_Byte_Total loop
               Image (Frame_Cursor + Offset - 1) := Value.Payload (Item.Value_Offset + Offset - 1);
            end loop;
            Frame_Cursor := Frame_Cursor + Item.Value_Byte_Total;
            Put_U32 (Image.all, Frame_Cursor, Formats.CRC_32C (Image (Frame_Start .. Frame_Cursor - 1)));
            Frame_Cursor := Frame_Cursor + SST_V2_Frame_Trailer_Length;
            Frame_Extent := Frame_Cursor - Frame_Start;

            Put_U64 (Image.all, Index_Cursor, Interfaces.Unsigned_64 (Frame_Start));
            Put_U64 (Image.all, Index_Cursor + 8, Interfaces.Unsigned_64 (Frame_Extent));
            Put_U64 (Image.all, Index_Cursor + 16, Item.Sequence);
            Image (Index_Cursor + 24) := Item.Operation;
            Image (Index_Cursor + 25) := 0;
            Put_U16 (Image.all, Index_Cursor + 26, 0);
            Put_U32 (Image.all, Index_Cursor + 28, Interfaces.Unsigned_32 (Item.Key_Byte_Total));
            Put_U32 (Image.all, Index_Cursor + 32, Interfaces.Unsigned_32 (Item.Value_Byte_Total));
            Index_Cursor := Index_Cursor + SST_V2_Index_Entry_Header_Length;
            for Offset in Natural range 1 .. Item.Key_Byte_Total loop
               Image (Index_Cursor + Offset - 1) := Value.Payload (Item.Key_Offset + Offset - 1);
            end loop;
            Index_Cursor := Index_Cursor + Item.Key_Byte_Total;
         end;
      end loop;
      if Frame_Cursor /= Natural (Read_U64 (Image.all, 112))
        or else Index_Cursor + SST_V2_Index_Trailer_Length /= Object_CRC
      then
         Release (Image);
         Status := Invalid_Value;
         return;
      end if;
      Put_U32
        (Image.all,
         Index_Cursor,
         Formats.CRC_32C
           (Image
              (Natural (Read_U64 (Image.all, 112))
               .. Index_Cursor - 1)));
      Put_U32 (Image.all, Object_CRC, Formats.CRC_32C (Image (0 .. Object_CRC - 1)));
      Status := Encoded;
   exception
      when Storage_Error =>
         Release (Image);
         Status := Allocation_Failed;
   end Encode_SST_V2;

   procedure Decode_SST
     (Image               : Formats.Byte_Array;
      Expected_Database   : Head_Policy.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : Run_Descriptor;
      Maximum_Key_Bytes   : Interfaces.Unsigned_64;
      Maximum_Value_Bytes : Interfaces.Unsigned_64;
      Value               : out SST_Access;
      Status              : out Decode_Status)
   is
      Admission          : SST_Header_Admission;
      Candidate          : SST_Access := null;
      Allocation         : Allocation_Status;
      Cursor             : Natural := LSM.SST_Header_Length;
      Payload_End        : Natural;
      Logical            : Interfaces.Unsigned_64 := 0;
      Lowest             : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Highest            : Interfaces.Unsigned_64 := 0;
      Previous_Key       : Natural := 0;
      Previous_Key_Total : Natural := 0;
      Previous_Sequence  : Interfaces.Unsigned_64 := 0;
   begin
      Value := null;
      if Image'Length < LSM.SST_Header_Length + LSM.Object_Trailer_Length then
         Status := Invalid_Length;
         return;
      end if;
      Inspect_SST_Header
        (Image (Image'First .. Image'First + LSM.SST_Header_Length - 1),
         Expected_Database,
         Expected_Family,
         Expected_Descriptor,
         Interfaces.Unsigned_64 (Image'Length),
         Admission,
         Status);
      if Status /= Decoded then
         return;
      end if;
      Payload_End := Image'Length - LSM.Object_Trailer_Length;
      if Read_U32 (Image, Payload_End)
        /= Formats.CRC_32C (Image (Image'First .. Image'Last - LSM.Object_Trailer_Length))
      then
         Status := Object_Checksum_Failed;
         return;
      end if;

      --  First pass authenticates every variable extent and ordering relation
      --  without retaining descriptors or payload bytes.
      for Index in Positive range 1 .. Admission.Entry_Total loop
         declare
            Sequence    : Interfaces.Unsigned_64;
            Operation   : Formats.Byte;
            Key_Wire    : Interfaces.Unsigned_32;
            Value_Wire  : Interfaces.Unsigned_32;
            Key_Total   : Natural;
            Value_Total : Natural;
            Key_Start   : Natural;
            Item_Bytes  : Interfaces.Unsigned_64;
         begin
            if Cursor > Payload_End or else LSM.SST_Entry_Header_Length > Payload_End - Cursor then
               Status := Invalid_Entry;
               return;
            end if;
            Sequence := Read_U64 (Image, Cursor);
            Operation := Byte_At (Image, Cursor + 8);
            Key_Wire := Read_U32 (Image, Cursor + 12);
            Value_Wire := Read_U32 (Image, Cursor + 16);
            if Byte_At (Image, Cursor + 9) /= 0 or else Read_U16 (Image, Cursor + 10) /= 0 then
               Status := Invalid_Entry;
               return;
            elsif Sequence = 0
              or else Sequence < Expected_Descriptor.Lowest_Sequence
              or else Sequence > Expected_Descriptor.Highest_Sequence
              or else Operation not in LSM.Put_Operation | LSM.Delete_Operation
              or else (Operation = LSM.Delete_Operation and then Value_Wire /= 0)
            then
               Status := Invalid_Entry;
               return;
            elsif Interfaces.Unsigned_64 (Key_Wire) > Maximum_Key_Bytes
              or else Interfaces.Unsigned_64 (Value_Wire) > Maximum_Value_Bytes
              or else Interfaces.Unsigned_64 (Key_Wire) > Interfaces.Unsigned_64 (Natural'Last)
              or else Interfaces.Unsigned_64 (Value_Wire) > Interfaces.Unsigned_64 (Natural'Last)
            then
               Status := Limit_Exceeded;
               return;
            end if;
            Key_Total := Natural (Key_Wire);
            Value_Total := Natural (Value_Wire);
            Cursor := Cursor + LSM.SST_Entry_Header_Length;
            if Key_Total > Payload_End - Cursor or else Value_Total > Payload_End - Cursor - Key_Total then
               Status := Invalid_Entry;
               return;
            end if;
            Key_Start := Cursor;
            if Index > 1 then
               if Same_Key (Image, Previous_Key, Previous_Key_Total, Key_Start, Key_Total) then
                  if Previous_Sequence <= Sequence then
                     Status := Invalid_SST_State;
                     return;
                  end if;
               elsif not Key_Less (Image, Previous_Key, Previous_Key_Total, Key_Start, Key_Total) then
                  Status := Invalid_SST_State;
                  return;
               end if;
            end if;
            Item_Bytes := Interfaces.Unsigned_64 (Key_Total) + Interfaces.Unsigned_64 (Value_Total);
            if not Add_U64 (Logical, Item_Bytes, Logical) then
               Status := Invalid_Length;
               return;
            end if;
            Lowest := Interfaces.Unsigned_64'Min (Lowest, Sequence);
            Highest := Interfaces.Unsigned_64'Max (Highest, Sequence);
            Previous_Key := Key_Start;
            Previous_Key_Total := Key_Total;
            Previous_Sequence := Sequence;
            Cursor := Cursor + Key_Total + Value_Total;
         end;
      end loop;
      if Cursor /= Payload_End then
         Status := Invalid_Length;
         return;
      elsif Logical /= Expected_Descriptor.Logical_Payload_Bytes
        or else Lowest /= Expected_Descriptor.Lowest_Sequence
        or else Highest /= Expected_Descriptor.Highest_Sequence
      then
         Status := Invalid_SST_State;
         return;
      end if;

      Create_SST (Admission.Entry_Total, Admission.Payload_Bytes, Candidate, Allocation);
      if Allocation = Allocation_Failed then
         Status := Allocation_Failed;
         return;
      elsif Allocation /= Allocated then
         Status := Limit_Exceeded;
         return;
      end if;
      Candidate.Database_ID := Expected_Database;
      Candidate.Run_ID := Expected_Descriptor.Run_ID;
      Candidate.Family_ID := Expected_Family;
      Candidate.Lowest_Sequence := Expected_Descriptor.Lowest_Sequence;
      Candidate.Highest_Sequence := Expected_Descriptor.Highest_Sequence;
      Candidate.Logical_Payload_Bytes := Expected_Descriptor.Logical_Payload_Bytes;

      Cursor := LSM.SST_Header_Length;
      declare
         Payload_Cursor : Positive := 1;
      begin
         for Index in Candidate.Entries'Range loop
            declare
               Item        : SST_Entry renames Candidate.Entries (Index);
               Key_Total   : constant Natural := Natural (Read_U32 (Image, Cursor + 12));
               Value_Total : constant Natural := Natural (Read_U32 (Image, Cursor + 16));
            begin
               Item.Sequence := Read_U64 (Image, Cursor);
               Item.Operation := Byte_At (Image, Cursor + 8);
               Item.Key_Offset := Payload_Cursor;
               Item.Key_Byte_Total := Key_Total;
               Item.Value_Offset := Payload_Cursor + Key_Total;
               Item.Value_Byte_Total := Value_Total;
               Cursor := Cursor + LSM.SST_Entry_Header_Length;
               for Offset in Natural range 1 .. Key_Total loop
                  Candidate.Payload (Payload_Cursor + Offset - 1) := Byte_At (Image, Cursor + Offset - 1);
               end loop;
               Cursor := Cursor + Key_Total;
               Payload_Cursor := Payload_Cursor + Key_Total;
               for Offset in Natural range 1 .. Value_Total loop
                  Candidate.Payload (Payload_Cursor + Offset - 1) := Byte_At (Image, Cursor + Offset - 1);
               end loop;
               Cursor := Cursor + Value_Total;
               Payload_Cursor := Payload_Cursor + Value_Total;
            end;
         end loop;
      end;
      if Cursor /= Payload_End
        or else not Structurally_Valid (Candidate.all)
        or else not Descriptor_Matches
                      (Candidate.all, Expected_Database, Expected_Family, Expected_Descriptor)
      then
         Release (Candidate);
         Status := Invalid_SST_State;
         return;
      end if;
      Value := Candidate;
      Status := Decoded;
   exception
      when Storage_Error =>
         Release (Candidate);
         Value := null;
         Status := Allocation_Failed;
   end Decode_SST;

   procedure Decode_SST_V2
     (Image               : Formats.Byte_Array;
      Expected_Database   : Head_Policy.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : Run_Descriptor;
      Maximum_Key_Bytes   : Interfaces.Unsigned_64;
      Maximum_Value_Bytes : Interfaces.Unsigned_64;
      Value               : out SST_Access;
      Status              : out Decode_Status)
   is
      Admission          : SST_Header_Admission;
      Candidate          : SST_Access := null;
      Allocation         : Allocation_Status;
      Frame_Cursor       : Natural := SST_V2_Header_Length;
      Frame_End          : Natural;
      Index_Cursor       : Natural;
      Index_Data_End     : Natural;
      Object_CRC         : Natural;
      Logical            : Interfaces.Unsigned_64 := 0;
      Lowest             : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Highest            : Interfaces.Unsigned_64 := 0;
      Previous_Key       : Natural := 0;
      Previous_Key_Total : Natural := 0;
      Previous_Sequence  : Interfaces.Unsigned_64 := 0;
   begin
      Value := null;
      if Image'Length
        < SST_V2_Header_Length + SST_V2_Index_Trailer_Length + LSM.Object_Trailer_Length
      then
         Status := Invalid_Length;
         return;
      end if;
      Inspect_SST_V2_Header
        (Image (Image'First .. Image'First + SST_V2_Header_Length - 1),
         Expected_Database,
         Expected_Family,
         Expected_Descriptor,
         Interfaces.Unsigned_64 (Image'Length),
         Admission,
         Status);
      if Status /= Decoded then
         return;
      end if;
      Object_CRC := Image'Length - LSM.Object_Trailer_Length;
      if Read_U32 (Image, Object_CRC)
        /= Formats.CRC_32C (Image (Image'First .. Image'First + Object_CRC - 1))
      then
         Status := Object_Checksum_Failed;
         return;
      end if;
      Frame_Cursor := Admission.Frame_Offset;
      Frame_End := Admission.Index_Offset;
      Index_Cursor := Admission.Index_Offset;
      Index_Data_End := Object_CRC - SST_V2_Index_Trailer_Length;
      if Read_U32 (Image, Index_Data_End)
        /= Formats.CRC_32C
             (Image
                (Image'First + Admission.Index_Offset
                 .. Image'First + Index_Data_End - 1))
      then
         Status := Index_Checksum_Failed;
         return;
      end if;

      --  First pass authenticates the whole-object, index, each independent
      --  frame, every duplicated binding fact, and canonical ordering before
      --  allocating descriptors or logical payload bytes.
      for Index in Positive range 1 .. Admission.Entry_Total loop
         declare
            Frame_Start   : constant Natural := Frame_Cursor;
            Sequence      : Interfaces.Unsigned_64;
            Operation     : Formats.Byte;
            Key_Wire      : Interfaces.Unsigned_32;
            Value_Wire    : Interfaces.Unsigned_32;
            Key_Total     : Natural;
            Value_Total   : Natural;
            Key_Start     : Natural;
            Frame_CRC     : Natural;
            Frame_Extent  : Natural;
            Index_Key     : Natural;
            Item_Bytes    : Interfaces.Unsigned_64;
         begin
            if Frame_Cursor > Frame_End
              or else
                SST_V2_Frame_Header_Length + SST_V2_Frame_Trailer_Length
                > Frame_End - Frame_Cursor
            then
               Status := Invalid_Entry;
               return;
            end if;
            Sequence := Read_U64 (Image, Frame_Cursor);
            Operation := Byte_At (Image, Frame_Cursor + 8);
            Key_Wire := Read_U32 (Image, Frame_Cursor + 12);
            Value_Wire := Read_U32 (Image, Frame_Cursor + 16);
            if Byte_At (Image, Frame_Cursor + 9) /= 0
              or else Read_U16 (Image, Frame_Cursor + 10) /= 0
              or else Sequence = 0
              or else Sequence < Expected_Descriptor.Lowest_Sequence
              or else Sequence > Expected_Descriptor.Highest_Sequence
              or else Operation not in LSM.Put_Operation | LSM.Delete_Operation
              or else (Operation = LSM.Delete_Operation and then Value_Wire /= 0)
            then
               Status := Invalid_Entry;
               return;
            elsif Interfaces.Unsigned_64 (Key_Wire) > Maximum_Key_Bytes
              or else Interfaces.Unsigned_64 (Value_Wire) > Maximum_Value_Bytes
              or else Interfaces.Unsigned_64 (Key_Wire) > Interfaces.Unsigned_64 (Natural'Last)
              or else Interfaces.Unsigned_64 (Value_Wire) > Interfaces.Unsigned_64 (Natural'Last)
            then
               Status := Limit_Exceeded;
               return;
            end if;
            Key_Total := Natural (Key_Wire);
            Value_Total := Natural (Value_Wire);
            Frame_Cursor := Frame_Cursor + SST_V2_Frame_Header_Length;
            if Key_Total > Frame_End - Frame_Cursor
              or else Value_Total > Frame_End - Frame_Cursor - Key_Total
              or else SST_V2_Frame_Trailer_Length
                      > Frame_End - Frame_Cursor - Key_Total - Value_Total
            then
               Status := Invalid_Entry;
               return;
            end if;
            Key_Start := Frame_Cursor;
            Frame_CRC := Frame_Cursor + Key_Total + Value_Total;
            if Read_U32 (Image, Frame_CRC)
              /= Formats.CRC_32C
                   (Image
                      (Image'First + Frame_Start
                       .. Image'First + Frame_CRC - 1))
            then
               Status := Frame_Checksum_Failed;
               return;
            end if;
            Frame_Cursor := Frame_CRC + SST_V2_Frame_Trailer_Length;
            Frame_Extent := Frame_Cursor - Frame_Start;

            if Index_Cursor > Index_Data_End
              or else SST_V2_Index_Entry_Header_Length > Index_Data_End - Index_Cursor
            then
               Status := Invalid_Entry;
               return;
            end if;
            if Read_U64 (Image, Index_Cursor) /= Interfaces.Unsigned_64 (Frame_Start)
              or else Read_U64 (Image, Index_Cursor + 8)
                      /= Interfaces.Unsigned_64 (Frame_Extent)
              or else Read_U64 (Image, Index_Cursor + 16) /= Sequence
              or else Byte_At (Image, Index_Cursor + 24) /= Operation
              or else Byte_At (Image, Index_Cursor + 25) /= 0
              or else Read_U16 (Image, Index_Cursor + 26) /= 0
              or else Read_U32 (Image, Index_Cursor + 28) /= Key_Wire
              or else Read_U32 (Image, Index_Cursor + 32) /= Value_Wire
            then
               Status := Invalid_SST_State;
               return;
            end if;
            Index_Cursor := Index_Cursor + SST_V2_Index_Entry_Header_Length;
            if Key_Total > Index_Data_End - Index_Cursor then
               Status := Invalid_Entry;
               return;
            end if;
            Index_Key := Index_Cursor;
            if not Same_Key (Image, Key_Start, Key_Total, Index_Key, Key_Total) then
               Status := Invalid_SST_State;
               return;
            end if;
            Index_Cursor := Index_Cursor + Key_Total;

            if Index > 1 then
               if Same_Key (Image, Previous_Key, Previous_Key_Total, Key_Start, Key_Total) then
                  if Previous_Sequence <= Sequence then
                     Status := Invalid_SST_State;
                     return;
                  end if;
               elsif not Key_Less (Image, Previous_Key, Previous_Key_Total, Key_Start, Key_Total) then
                  Status := Invalid_SST_State;
                  return;
               end if;
            end if;
            Item_Bytes := Interfaces.Unsigned_64 (Key_Total) + Interfaces.Unsigned_64 (Value_Total);
            if not Add_U64 (Logical, Item_Bytes, Logical) then
               Status := Invalid_Length;
               return;
            end if;
            Lowest := Interfaces.Unsigned_64'Min (Lowest, Sequence);
            Highest := Interfaces.Unsigned_64'Max (Highest, Sequence);
            Previous_Key := Key_Start;
            Previous_Key_Total := Key_Total;
            Previous_Sequence := Sequence;
         end;
      end loop;
      if Frame_Cursor /= Frame_End or else Index_Cursor /= Index_Data_End then
         Status := Invalid_Length;
         return;
      elsif Logical /= Expected_Descriptor.Logical_Payload_Bytes
        or else Lowest /= Expected_Descriptor.Lowest_Sequence
        or else Highest /= Expected_Descriptor.Highest_Sequence
      then
         Status := Invalid_SST_State;
         return;
      end if;

      Create_SST (Admission.Entry_Total, Admission.Payload_Bytes, Candidate, Allocation);
      if Allocation = Allocation_Failed then
         Status := Allocation_Failed;
         return;
      elsif Allocation /= Allocated then
         Status := Limit_Exceeded;
         return;
      end if;
      Candidate.Database_ID := Expected_Database;
      Candidate.Run_ID := Expected_Descriptor.Run_ID;
      Candidate.Family_ID := Expected_Family;
      Candidate.Lowest_Sequence := Expected_Descriptor.Lowest_Sequence;
      Candidate.Highest_Sequence := Expected_Descriptor.Highest_Sequence;
      Candidate.Logical_Payload_Bytes := Expected_Descriptor.Logical_Payload_Bytes;

      Frame_Cursor := Admission.Frame_Offset;
      declare
         Payload_Cursor : Positive := 1;
      begin
         for Item of Candidate.Entries loop
            declare
               Key_Total   : constant Natural := Natural (Read_U32 (Image, Frame_Cursor + 12));
               Value_Total : constant Natural := Natural (Read_U32 (Image, Frame_Cursor + 16));
            begin
               Item.Sequence := Read_U64 (Image, Frame_Cursor);
               Item.Operation := Byte_At (Image, Frame_Cursor + 8);
               Item.Key_Offset := Payload_Cursor;
               Item.Key_Byte_Total := Key_Total;
               Item.Value_Offset := Payload_Cursor + Key_Total;
               Item.Value_Byte_Total := Value_Total;
               Frame_Cursor := Frame_Cursor + SST_V2_Frame_Header_Length;
               for Offset in Natural range 1 .. Key_Total loop
                  Candidate.Payload (Payload_Cursor + Offset - 1) :=
                    Byte_At (Image, Frame_Cursor + Offset - 1);
               end loop;
               Frame_Cursor := Frame_Cursor + Key_Total;
               Payload_Cursor := Payload_Cursor + Key_Total;
               for Offset in Natural range 1 .. Value_Total loop
                  Candidate.Payload (Payload_Cursor + Offset - 1) :=
                    Byte_At (Image, Frame_Cursor + Offset - 1);
               end loop;
               Frame_Cursor := Frame_Cursor + Value_Total + SST_V2_Frame_Trailer_Length;
               Payload_Cursor := Payload_Cursor + Value_Total;
            end;
         end loop;
      end;
      if Frame_Cursor /= Frame_End
        or else not Structurally_Valid (Candidate.all)
        or else not Descriptor_Matches
                      (Candidate.all, Expected_Database, Expected_Family, Expected_Descriptor)
      then
         Release (Candidate);
         Status := Invalid_SST_State;
         return;
      end if;
      Value := Candidate;
      Status := Decoded;
   exception
      when Storage_Error =>
         Release (Candidate);
         Value := null;
         Status := Allocation_Failed;
   end Decode_SST_V2;

end Flyology.DB.LSM_Runtime_Formats;
