package body Flyology.DB.Manifest_Formats
  with SPARK_Mode => On
is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Formats.Byte_Array;
   use type Head_Policy.Commit_Sequence;
   use type Head_Policy.Format_Version;
   use type Head_Policy.Transition_Ordinal;
   use type Head_Policy.Writer_Epoch;

   --  Frozen persisted manifest magic `FLYCFM01`; v2 deliberately reuses it and
   --  advances the independent version. Changing it breaks both versions.
   Magic : constant Formats.Byte_Array (0 .. 7) :=
     [Character'Pos ('F'),
      Character'Pos ('L'),
      Character'Pos ('Y'),
      Character'Pos ('C'),
      Character'Pos ('F'),
      Character'Pos ('M'),
      Character'Pos ('0'),
      Character'Pos ('1')];

   procedure Put_U16
     (Image : in out Manifest_Image; Position : Manifest_Image_Index; Value : Interfaces.Unsigned_16)
   with Pre => Position <= Manifest_Image_Index'Last - 1;

   procedure Put_U32
     (Image : in out Manifest_Image; Position : Manifest_Image_Index; Value : Interfaces.Unsigned_32)
   with Pre => Position <= Manifest_Image_Index'Last - 3;

   procedure Put_U64
     (Image : in out Manifest_Image; Position : Manifest_Image_Index; Value : Interfaces.Unsigned_64)
   with Pre => Position <= Manifest_Image_Index'Last - 7;

   function Read_U16 (Image : Manifest_Image; Position : Manifest_Image_Index) return Interfaces.Unsigned_16
   with Pre => Position <= Manifest_Image_Index'Last - 1;

   function Read_U32 (Image : Manifest_Image; Position : Manifest_Image_Index) return Interfaces.Unsigned_32
   with Pre => Position <= Manifest_Image_Index'Last - 3;

   function Read_U64 (Image : Manifest_Image; Position : Manifest_Image_Index) return Interfaces.Unsigned_64
   with Pre => Position <= Manifest_Image_Index'Last - 7;

   procedure Put_Identifier
     (Image : in out Manifest_Image; Position : Manifest_Image_Index; Value : Head_Policy.Identifier)
   with Pre => Position <= Manifest_Image_Index'Last - Head_Policy.Identifier_Length + 1;

   function Read_Identifier
     (Image : Manifest_Image; Position : Manifest_Image_Index) return Head_Policy.Identifier
   with Pre => Position <= Manifest_Image_Index'Last - Head_Policy.Identifier_Length + 1;

   function Header_Checksum (Image : Manifest_Image) return Interfaces.Unsigned_32;

   function Valid_UTF8_Name (Item : Column_Family_Configuration) return Boolean;

   function Canonical_Name_Tail (Item : Column_Family_Configuration) return Boolean is
   begin
      for Index in Item.Name'Range loop
         if Index > Item.Name_Length and then Item.Name (Index) /= 0 then
            return False;
         end if;
      end loop;
      return True;
   end Canonical_Name_Tail;

   function Same_Name (Left, Right : Column_Family_Configuration) return Boolean
   is (Left.Name_Length = Right.Name_Length
       and then Left.Name_Length > 0
       and then Left.Name (1 .. Left.Name_Length) = Right.Name (1 .. Right.Name_Length));

   function Valid_Limits (Value : Database_Limits; Families : Family_Count) return Boolean
   is (Value.Maximum_Column_Families in 1 .. Interfaces.Unsigned_32 (Max_Families)
       and then Interfaces.Unsigned_32 (Families) <= Value.Maximum_Column_Families
       and then Value.Maximum_Manifest_History in 1 .. Interfaces.Unsigned_32 (Max_Manifest_History)
       and then Value.Maximum_Batch_History in 1 .. Interfaces.Unsigned_32 (Max_Batch_History)
       and then Value.Maximum_Transactions_Per_Batch in 1 .. Interfaces.Unsigned_32 (Max_Batch_Transactions)
       and then Value.Maximum_Mutations_Per_Transaction > 0
       and then Value.Maximum_Mutations_Per_Batch > 0
       and then Value.Maximum_Transactions_Per_Batch <= Value.Maximum_Mutations_Per_Batch
       and then Value.Maximum_Mutations_Per_Transaction <= Value.Maximum_Mutations_Per_Batch
       and then Value.Maximum_Live_Entries > 0
       and then Value.Maximum_Transaction_Payload_Bytes > 0
       and then Value.Maximum_Batch_Payload_Bytes >= Value.Maximum_Transaction_Payload_Bytes
       and then Value.Maximum_Live_State_Bytes > 0);

   procedure Put_U16
     (Image : in out Manifest_Image; Position : Manifest_Image_Index; Value : Interfaces.Unsigned_16) is
   begin
      Image (Position) := Formats.Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#);
      Image (Position + 1) := Formats.Byte (Value and 16#FF#);
   end Put_U16;

   procedure Put_U32
     (Image : in out Manifest_Image; Position : Manifest_Image_Index; Value : Interfaces.Unsigned_32) is
   begin
      for Offset in Natural range 0 .. 3 loop
         Image (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Put_U64
     (Image : in out Manifest_Image; Position : Manifest_Image_Index; Value : Interfaces.Unsigned_64) is
   begin
      for Offset in Natural range 0 .. 7 loop
         Image (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (7 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U64;

   function Read_U16 (Image : Manifest_Image; Position : Manifest_Image_Index) return Interfaces.Unsigned_16
   is
   begin
      return
        Interfaces.Shift_Left (Interfaces.Unsigned_16 (Image (Position)), 8)
        or Interfaces.Unsigned_16 (Image (Position + 1));
   end Read_U16;

   function Read_U32 (Image : Manifest_Image; Position : Manifest_Image_Index) return Interfaces.Unsigned_32
   is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      for Offset in Natural range 0 .. 3 loop
         Result := Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_32 (Image (Position + Offset));
      end loop;
      return Result;
   end Read_U32;

   function Read_U64 (Image : Manifest_Image; Position : Manifest_Image_Index) return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Offset in Natural range 0 .. 7 loop
         Result := Interfaces.Shift_Left (Result, 8) or Interfaces.Unsigned_64 (Image (Position + Offset));
      end loop;
      return Result;
   end Read_U64;

   procedure Put_Identifier
     (Image : in out Manifest_Image; Position : Manifest_Image_Index; Value : Head_Policy.Identifier) is
   begin
      for Index in Head_Policy.Identifier_Index loop
         Image (Position + Index - Head_Policy.Identifier_Index'First) := Value (Index);
      end loop;
   end Put_Identifier;

   function Read_Identifier
     (Image : Manifest_Image; Position : Manifest_Image_Index) return Head_Policy.Identifier
   is
      Result : Head_Policy.Identifier;
   begin
      for Index in Head_Policy.Identifier_Index loop
         Result (Index) := Image (Position + Index - Head_Policy.Identifier_Index'First);
      end loop;
      return Result;
   end Read_Identifier;

   function Header_Checksum (Image : Manifest_Image) return Interfaces.Unsigned_32 is
      Header : Formats.Byte_Array (0 .. Manifest_Header_Length - 1) :=
        Image (0 .. Manifest_Header_Length - 1);
   begin
      --  Common-envelope bytes 40..43 are the frozen header CRC field and are
      --  zeroed while calculating the exact v1 header checksum.
      Header (40 .. 43) := [others => 0];
      return Formats.CRC_32C (Header);
   end Header_Checksum;

   function Valid_UTF8_Name (Item : Column_Family_Configuration) return Boolean is
      Cursor : Natural := 1;
      First  : Formats.Byte;
      Second : Formats.Byte;
   begin
      --  Byte ranges below implement externally fixed UTF-8 validity: exclude
      --  overlong sequences, surrogates, and values above U+10FFFF. Relaxing
      --  them would change persisted family-name compatibility.
      if Item.Name_Length = 0 then
         return False;
      end if;
      while Cursor <= Item.Name_Length loop
         pragma Loop_Invariant (Cursor in 1 .. Item.Name_Length);
         pragma Loop_Variant (Increases => Cursor);
         First := Item.Name (Cursor);
         if First in 1 .. 16#7F# then
            Cursor := Cursor + 1;
         elsif First in 16#C2# .. 16#DF# then
            if Cursor > Item.Name_Length - 1 or else Item.Name (Cursor + 1) not in 16#80# .. 16#BF# then
               return False;
            end if;
            Cursor := Cursor + 2;
         elsif First in 16#E0# .. 16#EF# then
            if Cursor > Item.Name_Length - 2 then
               return False;
            end if;
            Second := Item.Name (Cursor + 1);
            if Item.Name (Cursor + 2) not in 16#80# .. 16#BF#
              or else (First = 16#E0# and then Second not in 16#A0# .. 16#BF#)
              or else (First = 16#ED# and then Second not in 16#80# .. 16#9F#)
              or else (First not in 16#E0# | 16#ED# and then Second not in 16#80# .. 16#BF#)
            then
               return False;
            end if;
            Cursor := Cursor + 3;
         elsif First in 16#F0# .. 16#F4# then
            if Cursor > Item.Name_Length - 3 then
               return False;
            end if;
            Second := Item.Name (Cursor + 1);
            if Item.Name (Cursor + 2) not in 16#80# .. 16#BF#
              or else Item.Name (Cursor + 3) not in 16#80# .. 16#BF#
              or else (First = 16#F0# and then Second not in 16#90# .. 16#BF#)
              or else (First = 16#F4# and then Second not in 16#80# .. 16#8F#)
              or else (First in 16#F1# .. 16#F3# and then Second not in 16#80# .. 16#BF#)
            then
               return False;
            end if;
            Cursor := Cursor + 4;
         else
            return False;
         end if;
      end loop;
      return Cursor = Item.Name_Length + 1;
   end Valid_UTF8_Name;

   function Valid_Configuration (Value : Column_Family_Configuration) return Boolean
   is (Value.ID /= 0
       and then Value.Max_Key_Bytes > 0
       and then Value.Max_Value_Bytes > 0
       and then Valid_UTF8_Name (Value)
       and then Canonical_Name_Tail (Value));

   function Is_Root (Value : Manifest) return Boolean
   is (Head_Policy.Is_Zero (Value.Previous_Manifest_ID)
       and then Head_Policy.Is_Zero (Value.Expected_Transition_ID)
       and then Value.Expected_Transition_Number = 0
       and then Value.Publication_Transition_Number = 1
       and then Value.Writer_Epoch = 1
       and then Value.Registry_Revision = 1);

   function Structurally_Valid (Value : Manifest) return Boolean is
   begin
      if Head_Policy.Is_Zero (Value.Database_ID)
        or else Head_Policy.Is_Zero (Value.Manifest_ID)
        or else Head_Policy.Is_Zero (Value.Publication_Transition_ID)
        or else Value.Family_Total = 0
        or else not Valid_Limits (Value.Limits, Value.Family_Total)
        or else (if Is_Root (Value)
                 then False
                 elsif Head_Policy.Is_Zero (Value.Previous_Manifest_ID)
                   or else Value.Manifest_ID = Value.Previous_Manifest_ID
                   or else Head_Policy.Is_Zero (Value.Expected_Transition_ID)
                   or else Value.Expected_Transition_Number = 0
                   or else Value.Expected_Transition_Number = Interfaces.Unsigned_64'Last
                   or else Value.Writer_Epoch > Value.Expected_Transition_Number
                   or else Value.Publication_Transition_Number /= Value.Expected_Transition_Number + 1
                   or else Value.Publication_Transition_ID = Value.Expected_Transition_ID
                   or else Value.Writer_Epoch = 0
                   or else Value.Registry_Revision <= 1
                 then True
                 else False)
      then
         return False;
      end if;

      for Index in Family_Slot range 1 .. Value.Family_Total loop
         declare
            Item : Column_Family_Configuration renames Value.Families (Index);
         begin
            if not Valid_Configuration (Item)
              or else Item.Max_Key_Bytes > Value.Limits.Maximum_Transaction_Payload_Bytes
              or else Item.Max_Value_Bytes > Value.Limits.Maximum_Transaction_Payload_Bytes
              or else Item.Max_Key_Bytes
                      > Value.Limits.Maximum_Transaction_Payload_Bytes - Item.Max_Value_Bytes
              or else Item.Max_Key_Bytes > Value.Limits.Maximum_Live_State_Bytes
              or else Item.Max_Value_Bytes > Value.Limits.Maximum_Live_State_Bytes
              or else Item.Max_Key_Bytes > Value.Limits.Maximum_Live_State_Bytes - Item.Max_Value_Bytes
              or else (Index > 1 and then Value.Families (Index - 1).ID >= Item.ID)
            then
               return False;
            end if;
            for Earlier in Family_Slot range 1 .. Index - 1 loop
               if Same_Name (Value.Families (Earlier), Item) then
                  return False;
               end if;
            end loop;
         end;
      end loop;
      return True;
   end Structurally_Valid;

   function Runtime_Compatible (Value : Manifest) return Boolean is
   begin
      --  The persisted U32 format/history/group ceilings are structural. U64
      --  byte budgets are policy authority, not eager allocation requests:
      --  each actual arena/image performs checked Natural conversion before
      --  lazy allocation, so a theoretical maximum is not itself incompatible.
      return
        Value.Limits.Maximum_Column_Families <= Maximum_Initial_Column_Families
        and then Value.Limits.Maximum_Manifest_History <= Maximum_History_Batches
        and then Value.Limits.Maximum_Batch_History <= Maximum_History_Batches
        and then Value.Limits.Maximum_Transactions_Per_Batch <= Maximum_Group_Transactions;
   end Runtime_Compatible;

   function Valid_Predecessor (Current, Previous : Manifest) return Boolean is
   begin
      if not Structurally_Valid (Current)
        or else not Structurally_Valid (Previous)
        or else Is_Root (Current)
        or else Current.Database_ID /= Previous.Database_ID
        or else Current.Previous_Manifest_ID /= Previous.Manifest_ID
        or else Current.Limits /= Previous.Limits
        or else Previous.Family_Total = 0
        or else Previous.Registry_Revision = Interfaces.Unsigned_64'Last
        or else Current.Registry_Revision /= Previous.Registry_Revision + 1
        or else Previous.Family_Total = Family_Count'Last
        or else Current.Family_Total /= Previous.Family_Total + 1
        or else Current.Writer_Epoch < Previous.Writer_Epoch
        or else Current.Expected_Transition_Number < Previous.Publication_Transition_Number
      then
         return False;
      end if;
      for Index in Family_Slot range 1 .. Previous.Family_Total loop
         if Current.Families (Index) /= Previous.Families (Index) then
            return False;
         end if;
      end loop;
      if Current.Families (Current.Family_Total).ID <= Previous.Families (Previous.Family_Total).ID then
         return False;
      end if;
      declare
         --  Derived reachability distances from exact persisted transition
         --  ordinals/epochs; zero and one select identity-binding cases and are
         --  not configurable thresholds.
         Ordinal_Gap : constant Interfaces.Unsigned_64 :=
           Current.Expected_Transition_Number - Previous.Publication_Transition_Number;
         Epoch_Gap   : constant Interfaces.Unsigned_64 := Current.Writer_Epoch - Previous.Writer_Epoch;
      begin
         return
           Epoch_Gap <= Ordinal_Gap
           and then (if Ordinal_Gap = 0
                     then Current.Expected_Transition_ID = Previous.Publication_Transition_ID
                     elsif Ordinal_Gap = 1
                     then Current.Expected_Transition_ID /= Previous.Publication_Transition_ID);
      end;
   end Valid_Predecessor;

   function Valid_Checkpoint_Predecessor (Current, Previous : Manifest) return Boolean is
   begin
      if not Structurally_Valid (Current)
        or else not Structurally_Valid (Previous)
        or else Is_Root (Current)
        or else Current.Database_ID /= Previous.Database_ID
        or else Current.Previous_Manifest_ID /= Previous.Manifest_ID
        or else Current.Limits /= Previous.Limits
        or else Current.Family_Total /= Previous.Family_Total
        or else Previous.Registry_Revision = Interfaces.Unsigned_64'Last
        or else Current.Registry_Revision /= Previous.Registry_Revision + 1
        or else Current.Writer_Epoch < Previous.Writer_Epoch
        or else Current.Expected_Transition_Number < Previous.Publication_Transition_Number
      then
         return False;
      end if;
      for Index in Family_Slot range 1 .. Previous.Family_Total loop
         if Current.Families (Index) /= Previous.Families (Index) then
            return False;
         end if;
      end loop;
      declare
         --  Persisted transition ordinals and epochs derive the exact
         --  reachability gaps. Zero binds the same transition; one requires
         --  the immediate next identity. Neither value is a retry threshold.
         Ordinal_Gap : constant Interfaces.Unsigned_64 :=
           Current.Expected_Transition_Number - Previous.Publication_Transition_Number;
         Epoch_Gap   : constant Interfaces.Unsigned_64 := Current.Writer_Epoch - Previous.Writer_Epoch;
      begin
         return
           Epoch_Gap <= Ordinal_Gap
           and then (if Ordinal_Gap = 0
                     then Current.Expected_Transition_ID = Previous.Publication_Transition_ID
                     elsif Ordinal_Gap = 1
                     then Current.Expected_Transition_ID /= Previous.Publication_Transition_ID);
      end;
   end Valid_Checkpoint_Predecessor;

   function Valid_Checkpoint_Chain_Predecessor (Current, Previous : Manifest) return Boolean
   is (Valid_Checkpoint_Predecessor (Current, Previous) or else Valid_Predecessor (Current, Previous));

   function Manifest_Head_Structurally_Valid (Candidate : Head_Policy.Head_State) return Boolean is
   begin
      return Candidate.Version = Manifest_Head_Format and then Head_Policy.Structurally_Valid_V2 (Candidate);
   end Manifest_Head_Structurally_Valid;

   function Valid_Root_Publication (Candidate : Head_Policy.Head_State; Value : Manifest) return Boolean is
   begin
      return
        Manifest_Head_Structurally_Valid (Candidate)
        and then Structurally_Valid (Value)
        and then Is_Root (Value)
        and then Candidate.Database_ID = Value.Database_ID
        and then Candidate.Version = Manifest_Head_Format
        and then Interfaces.Unsigned_64 (Candidate.Epoch) = Value.Writer_Epoch
        and then Candidate.Highest_Visible = 0
        and then Head_Policy.Is_Zero (Candidate.Latest_Batch)
        and then Candidate.Latest_Manifest = Value.Manifest_ID
        and then Candidate.Transition_ID = Value.Publication_Transition_ID
        and then Head_Policy.Is_Zero (Candidate.Predecessor_Transition)
        and then Interfaces.Unsigned_64 (Candidate.Transition_Number) = Value.Publication_Transition_Number;
   end Valid_Root_Publication;

   function Valid_Publication (Current, Candidate : Head_Policy.Head_State; Value : Manifest) return Boolean
   is
   begin
      return
        Manifest_Head_Structurally_Valid (Current)
        and then Manifest_Head_Structurally_Valid (Candidate)
        and then Structurally_Valid (Value)
        and then not Is_Root (Value)
        and then Current.Database_ID = Value.Database_ID
        and then Candidate.Database_ID = Current.Database_ID
        and then Current.Version = Manifest_Head_Format
        and then Candidate.Version = Current.Version
        and then Interfaces.Unsigned_64 (Current.Epoch) = Value.Writer_Epoch
        and then Candidate.Epoch = Current.Epoch
        and then Candidate.Highest_Visible = Current.Highest_Visible
        and then Candidate.Latest_Batch = Current.Latest_Batch
        and then Current.Latest_Manifest = Value.Previous_Manifest_ID
        and then Candidate.Latest_Manifest = Value.Manifest_ID
        and then Current.Transition_ID = Value.Expected_Transition_ID
        and then Interfaces.Unsigned_64 (Current.Transition_Number) = Value.Expected_Transition_Number
        and then Candidate.Predecessor_Transition = Current.Transition_ID
        and then Candidate.Transition_ID = Value.Publication_Transition_ID
        and then Candidate.Transition_ID /= Current.Transition_ID
        and then Interfaces.Unsigned_64 (Candidate.Transition_Number) = Value.Publication_Transition_Number
        and then Current.Transition_Number < Head_Policy.Transition_Ordinal'Last
        and then Candidate.Transition_Number = Current.Transition_Number + 1;
   end Valid_Publication;

   function Referenced_By (Value : Manifest; Referencing_Head : Head_Policy.Head_State) return Boolean is
   begin
      if not Structurally_Valid (Value)
        or else not Manifest_Head_Structurally_Valid (Referencing_Head)
        or else Referencing_Head.Database_ID /= Value.Database_ID
        or else Referencing_Head.Latest_Manifest /= Value.Manifest_ID
        or else Interfaces.Unsigned_64 (Referencing_Head.Epoch) < Value.Writer_Epoch
        or else Interfaces.Unsigned_64 (Referencing_Head.Transition_Number)
                < Value.Publication_Transition_Number
      then
         return False;
      end if;
      declare
         --  Derived reachability distances between this manifest publication
         --  and the referencing HEAD; zero/one are exact identity-binding cases,
         --  not policy tolerances.
         Ordinal_Gap : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Referencing_Head.Transition_Number) - Value.Publication_Transition_Number;
         Epoch_Gap   : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Referencing_Head.Epoch) - Value.Writer_Epoch;
      begin
         return
           Epoch_Gap <= Ordinal_Gap
           and then (if Ordinal_Gap = 0
                     then
                       Referencing_Head.Transition_ID = Value.Publication_Transition_ID
                       and then Referencing_Head.Predecessor_Transition = Value.Expected_Transition_ID
                     elsif Ordinal_Gap = 1
                     then
                       Referencing_Head.Transition_ID /= Value.Publication_Transition_ID
                       and then Referencing_Head.Predecessor_Transition = Value.Publication_Transition_ID);
      end;
   end Referenced_By;

   function Encoded_Length (Value : Manifest) return Natural is
      Result : Natural := Manifest_Header_Length + Manifest_Trailer_Length;
   begin
      for Index in Family_Slot range 1 .. Value.Family_Total loop
         pragma Loop_Invariant (Result >= Manifest_Header_Length + Manifest_Trailer_Length);
         pragma
           Loop_Invariant
             (Result
                <= Manifest_Header_Length
                   + Manifest_Trailer_Length
                   + (Index - 1) * (Family_Frame_Header_Length + Max_Family_Name_Bytes));
         Result := Result + Family_Frame_Header_Length + Value.Families (Index).Name_Length;
      end loop;
      return Result;
   end Encoded_Length;

   procedure Encode_Manifest
     (Value : Manifest; Image : out Manifest_Image; Length : out Natural; Status : out Encode_Status)
   is
      Cursor : Natural := Manifest_Header_Length;
   begin
      Image := [others => 0];
      Length := 0;
      if not Structurally_Valid (Value) then
         Status := Invalid_Value;
         return;
      end if;
      Length := Encoded_Length (Value);
      --  Normative manifest-v1 offsets: common 0/8/10/11/12/28/32/40; IDs
      --  44/60/76/100, ordinals 92/116, epoch/registry 124/132, counts/limits
      --  140..188. Zero flags/reserved fields are frozen and incompatible to move.
      Image (0 .. 7) := Magic;
      Put_U16 (Image, 8, Manifest_Format_Version);
      Image (10) := Manifest_Object_Kind;
      Image (11) := 0;
      Put_Identifier (Image, 12, Value.Database_ID);
      Put_U32 (Image, 28, Manifest_Header_Length);
      Put_U64 (Image, 32, Interfaces.Unsigned_64 (Length - Manifest_Header_Length - Manifest_Trailer_Length));
      Put_Identifier (Image, 44, Value.Manifest_ID);
      Put_Identifier (Image, 60, Value.Previous_Manifest_ID);
      Put_Identifier (Image, 76, Value.Expected_Transition_ID);
      Put_U64 (Image, 92, Value.Expected_Transition_Number);
      Put_Identifier (Image, 100, Value.Publication_Transition_ID);
      Put_U64 (Image, 116, Value.Publication_Transition_Number);
      Put_U64 (Image, 124, Value.Writer_Epoch);
      Put_U64 (Image, 132, Value.Registry_Revision);
      Put_U32 (Image, 140, Interfaces.Unsigned_32 (Value.Family_Total));
      Put_U32 (Image, 144, Value.Limits.Maximum_Column_Families);
      Put_U32 (Image, 148, Value.Limits.Maximum_Manifest_History);
      Put_U32 (Image, 152, Value.Limits.Maximum_Batch_History);
      Put_U32 (Image, 156, Value.Limits.Maximum_Transactions_Per_Batch);
      Put_U32 (Image, 160, Value.Limits.Maximum_Mutations_Per_Transaction);
      Put_U32 (Image, 164, Value.Limits.Maximum_Mutations_Per_Batch);
      Put_U32 (Image, 168, Value.Limits.Maximum_Live_Entries);
      Put_U64 (Image, 172, Value.Limits.Maximum_Transaction_Payload_Bytes);
      Put_U64 (Image, 180, Value.Limits.Maximum_Batch_Payload_Bytes);
      Put_U64 (Image, 188, Value.Limits.Maximum_Live_State_Bytes);
      Put_U32 (Image, 40, Header_Checksum (Image));

      for Index in Family_Slot range 1 .. Value.Family_Total loop
         pragma Loop_Invariant (Cursor >= Manifest_Header_Length);
         pragma
           Loop_Invariant
             (Cursor
                <= Manifest_Header_Length
                   + (Index - 1) * (Family_Frame_Header_Length + Max_Family_Name_Bytes));
         declare
            Item : Column_Family_Configuration renames Value.Families (Index);
         begin
            Put_U32 (Image, Manifest_Image_Index (Cursor), Item.ID);
            Put_U32 (Image, Manifest_Image_Index (Cursor + 4), 0);
            Put_U64 (Image, Manifest_Image_Index (Cursor + 8), Item.Max_Key_Bytes);
            Put_U64 (Image, Manifest_Image_Index (Cursor + 16), Item.Max_Value_Bytes);
            Put_U16 (Image, Manifest_Image_Index (Cursor + 24), Interfaces.Unsigned_16 (Item.Name_Length));
            Put_U16 (Image, Manifest_Image_Index (Cursor + 26), 0);
            Cursor := Cursor + Family_Frame_Header_Length;
            for Byte_Index in Family_Name_Index range 1 .. Item.Name_Length loop
               Image (Cursor + Byte_Index - 1) := Item.Name (Byte_Index);
            end loop;
            Cursor := Cursor + Item.Name_Length;
         end;
      end loop;
      if Cursor + Manifest_Trailer_Length /= Length then
         Image := [others => 0];
         Length := 0;
         Status := Invalid_Value;
         return;
      end if;
      Put_U32 (Image, Manifest_Image_Index (Cursor), Formats.CRC_32C (Image (0 .. Cursor - 1)));
      Status := Encoded;
   end Encode_Manifest;

   procedure Decode_Manifest
     (Image             : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Limits            : Reader_Caps;
      Value             : out Manifest;
      Status            : out Decode_Status)
   is
      Fixed          : Manifest_Image := [others => 0];
      Candidate      : Manifest := Empty_Manifest;
      Payload_Length : Interfaces.Unsigned_64;
      Payload_End    : Natural;
      Cursor         : Natural := Manifest_Header_Length;
      Family_Wire    : Interfaces.Unsigned_32;
   begin
      Value := Empty_Manifest;
      if Image'Length < Manifest_Header_Length + Manifest_Trailer_Length then
         Status := Invalid_Length;
         return;
      elsif Image'Length > Max_Manifest_Image_Length then
         Status := Limit_Exceeded;
         return;
      end if;
      Fixed (0 .. Image'Length - 1) := Image;
      Payload_Length := Read_U64 (Fixed, 32);
      --  Authenticate the same frozen common/header map and checksum coverage
      --  before applying bounded reference-reader caps.
      if Payload_Length
        /= Interfaces.Unsigned_64 (Image'Length - Manifest_Header_Length - Manifest_Trailer_Length)
      then
         Status := Invalid_Length;
         return;
      elsif Fixed (0 .. 7) /= Magic then
         Status := Invalid_Magic;
         return;
      elsif Read_U16 (Fixed, 8) /= Manifest_Format_Version then
         Status := Unsupported_Version;
         return;
      elsif Fixed (10) /= Manifest_Object_Kind then
         Status := Invalid_Object_Kind;
         return;
      elsif Fixed (11) /= 0 then
         Status := Invalid_Flags;
         return;
      elsif Read_Identifier (Fixed, 12) /= Expected_Database then
         Status := Wrong_Database;
         return;
      elsif Read_U32 (Fixed, 28) /= Manifest_Header_Length then
         Status := Invalid_Length;
         return;
      elsif Read_U32 (Fixed, 40) /= Header_Checksum (Fixed) then
         Status := Header_Checksum_Failed;
         return;
      elsif Read_U32 (Fixed, Manifest_Image_Index (Image'Length - Manifest_Trailer_Length))
        /= Formats.CRC_32C (Fixed (0 .. Image'Length - Manifest_Trailer_Length - 1))
      then
         Status := Object_Checksum_Failed;
         return;
      elsif Payload_Length > Interfaces.Unsigned_64 (Limits.Payload_Bytes) then
         Status := Limit_Exceeded;
         return;
      end if;

      Family_Wire := Read_U32 (Fixed, 140);
      if Family_Wire = 0 then
         Status := Invalid_Manifest_State;
         return;
      elsif Family_Wire > Interfaces.Unsigned_32 (Max_Families)
        or else Family_Wire > Interfaces.Unsigned_32 (Limits.Families)
      then
         Status := Limit_Exceeded;
         return;
      end if;
      Candidate.Database_ID := Read_Identifier (Fixed, 12);
      Candidate.Manifest_ID := Read_Identifier (Fixed, 44);
      Candidate.Previous_Manifest_ID := Read_Identifier (Fixed, 60);
      Candidate.Expected_Transition_ID := Read_Identifier (Fixed, 76);
      Candidate.Expected_Transition_Number := Read_U64 (Fixed, 92);
      Candidate.Publication_Transition_ID := Read_Identifier (Fixed, 100);
      Candidate.Publication_Transition_Number := Read_U64 (Fixed, 116);
      Candidate.Writer_Epoch := Read_U64 (Fixed, 124);
      Candidate.Registry_Revision := Read_U64 (Fixed, 132);
      Candidate.Family_Total := Family_Count (Family_Wire);
      Candidate.Limits.Maximum_Column_Families := Read_U32 (Fixed, 144);
      Candidate.Limits.Maximum_Manifest_History := Read_U32 (Fixed, 148);
      Candidate.Limits.Maximum_Batch_History := Read_U32 (Fixed, 152);
      Candidate.Limits.Maximum_Transactions_Per_Batch := Read_U32 (Fixed, 156);
      Candidate.Limits.Maximum_Mutations_Per_Transaction := Read_U32 (Fixed, 160);
      Candidate.Limits.Maximum_Mutations_Per_Batch := Read_U32 (Fixed, 164);
      Candidate.Limits.Maximum_Live_Entries := Read_U32 (Fixed, 168);
      Candidate.Limits.Maximum_Transaction_Payload_Bytes := Read_U64 (Fixed, 172);
      Candidate.Limits.Maximum_Batch_Payload_Bytes := Read_U64 (Fixed, 180);
      Candidate.Limits.Maximum_Live_State_Bytes := Read_U64 (Fixed, 188);
      if Candidate.Limits.Maximum_Column_Families > Interfaces.Unsigned_32 (Max_Families)
        or else Candidate.Limits.Maximum_Manifest_History > Interfaces.Unsigned_32 (Max_Manifest_History)
        or else Candidate.Limits.Maximum_Batch_History > Interfaces.Unsigned_32 (Max_Batch_History)
        or else Candidate.Limits.Maximum_Transactions_Per_Batch
                > Interfaces.Unsigned_32 (Max_Batch_Transactions)
      then
         Status := Limit_Exceeded;
         return;
      elsif not Valid_Limits (Candidate.Limits, Candidate.Family_Total) then
         Status := Invalid_Limits;
         return;
      end if;

      Payload_End := Image'Length - Manifest_Trailer_Length;
      for Index in Family_Slot range 1 .. Candidate.Family_Total loop
         pragma Loop_Invariant (Cursor >= Manifest_Header_Length);
         pragma Loop_Invariant (Cursor <= Payload_End);
         declare
            Name_Wire : Interfaces.Unsigned_16;
            Item      : Column_Family_Configuration;
         begin
            if Cursor > Payload_End or else Family_Frame_Header_Length > Payload_End - Cursor then
               Status := Invalid_Family;
               return;
            end if;
            Item.ID := Read_U32 (Fixed, Manifest_Image_Index (Cursor));
            if Read_U32 (Fixed, Manifest_Image_Index (Cursor + 4)) /= 0
              or else Read_U16 (Fixed, Manifest_Image_Index (Cursor + 26)) /= 0
            then
               Status := Invalid_Family;
               return;
            end if;
            Item.Max_Key_Bytes := Read_U64 (Fixed, Manifest_Image_Index (Cursor + 8));
            Item.Max_Value_Bytes := Read_U64 (Fixed, Manifest_Image_Index (Cursor + 16));
            Name_Wire := Read_U16 (Fixed, Manifest_Image_Index (Cursor + 24));
            Cursor := Cursor + Family_Frame_Header_Length;
            if Name_Wire = 0 then
               Status := Invalid_Name;
               return;
            elsif Name_Wire > Interfaces.Unsigned_16 (Max_Family_Name_Bytes)
              or else Name_Wire > Interfaces.Unsigned_16 (Limits.Name_Bytes)
            then
               Status := Limit_Exceeded;
               return;
            end if;
            Item.Name_Length := Family_Name_Length (Name_Wire);
            if Cursor > Payload_End or else Item.Name_Length > Payload_End - Cursor then
               Status := Invalid_Family;
               return;
            elsif Item.Max_Key_Bytes > Limits.Key_Bytes or else Item.Max_Value_Bytes > Limits.Value_Bytes then
               Status := Limit_Exceeded;
               return;
            end if;
            for Byte_Index in Family_Name_Index range 1 .. Item.Name_Length loop
               Item.Name (Byte_Index) := Fixed (Cursor + Byte_Index - 1);
            end loop;
            Cursor := Cursor + Item.Name_Length;
            Candidate.Families (Index) := Item;
            if Item.ID = 0 or else Item.Max_Key_Bytes = 0 or else Item.Max_Value_Bytes = 0 then
               Status := Invalid_Family;
               return;
            elsif not Valid_UTF8_Name (Item) then
               Status := Invalid_Name;
               return;
            elsif Index > 1 and then Candidate.Families (Index - 1).ID >= Item.ID then
               Status := Invalid_Family;
               return;
            end if;
            for Earlier in Family_Slot range 1 .. Index - 1 loop
               if Same_Name (Candidate.Families (Earlier), Item) then
                  Status := Duplicate_Name;
                  return;
               end if;
            end loop;
         end;
      end loop;
      if Cursor /= Payload_End then
         Status := Invalid_Length;
      elsif not Structurally_Valid (Candidate) then
         Status := Invalid_Manifest_State;
      else
         Value := Candidate;
         Status := Decoded;
      end if;
   end Decode_Manifest;

end Flyology.DB.Manifest_Formats;
