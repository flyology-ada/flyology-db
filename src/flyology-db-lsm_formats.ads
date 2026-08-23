with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Flyology.DB.Manifest_Formats;
with Interfaces;

--  Defines exact checkpoint-manifest-v2 and SST-v1 wire formats.

private package Flyology.DB.LSM_Formats
  with SPARK_Mode => On
is

   --  Generic bounds size only a reference/proof instance; persisted limits
   --  remain the authority for the later operational decoder.
   generic
      --  Reference/proof representation choices supplied by each instantiation.
      --  They are not persisted defaults or production database ceilings.
      Maximum_Runs_Per_Family : Positive;
      Maximum_Identities : Positive;
      Maximum_SST_Entries : Positive;
      Maximum_Key_Bytes : Positive;
      Maximum_Value_Bytes : Positive;
   package Reference with SPARK_Mode => On is

      package Formats renames Flyology.DB.Formats;
      package Head_Policy renames Flyology.DB.Head_Policy;
      package Manifests renames Flyology.DB.Manifest_Formats;

      use type Head_Policy.Identifier;
      use type Interfaces.Unsigned_32;
      use type Interfaces.Unsigned_64;

      --  Version 2 is the accepted first-LSM checkpoint-manifest protocol. It
      --  leaves the version-1 log-only manifest encoding unchanged and readable.
      Checkpoint_Manifest_Format_Version : constant Interfaces.Unsigned_16 := 2;

      --  Persisted-format formulas: header 220 = v1 196 + 8 + 4 + 4 + 4 + 4;
      --  family 52 = v1 28 + 8 + 4 + 4 + 4 + 4; run 48 = 16 + 8 + 8 + 4 +
      --  4 + 8. Changing any term is manifest-v2 wire-incompatible.
      Checkpoint_Manifest_Header_Length : constant := 220;
      Checkpoint_Family_Header_Length   : constant := 52;
      Run_Descriptor_Length             : constant := 48;

      --  The accepted new SST kind begins at its own version 1. Kind 4 is the
      --  next unused stable code after HEAD=1, batch=2, and manifest=3.
      SST_Format_Version : constant Interfaces.Unsigned_16 := 1;
      SST_Object_Kind    : constant Formats.Byte := 4;

      --  Persisted-format formulas: SST header 96 = common 44 + 16 + 4 + 8 +
      --  8 + 4 + 4 + 8; entry 20 = 8 + 1 + 1 + 2 + 4 + 4; trailer 4 is one
      --  U32 CRC-32C. Changing any term is SST-v1 wire-incompatible.
      SST_Header_Length       : constant := 96;
      SST_Entry_Header_Length : constant := 20;
      Object_Trailer_Length   : constant := 4;

      --  Inherited from frozen batch-v1: Put=1 and Delete=2. SST deliberately
      --  shares that operation namespace; retagging either value is persisted-
      --  format incompatible rather than a local enumeration change.
      Put_Operation    : constant Formats.Byte := 1;
      Delete_Operation : constant Formats.Byte := 2;

      subtype Run_Slot is Positive range 1 .. Maximum_Runs_Per_Family;
      subtype Run_Count is Natural range 0 .. Maximum_Runs_Per_Family;
      subtype Identity_Slot is Positive range 1 .. Maximum_Identities;
      subtype Identity_Count is Natural range 0 .. Maximum_Identities;
      subtype SST_Entry_Slot is Positive range 1 .. Maximum_SST_Entries;
      subtype SST_Entry_Count is Natural range 0 .. Maximum_SST_Entries;
      subtype Key_Length is Natural range 0 .. Maximum_Key_Bytes;
      subtype Value_Length is Natural range 0 .. Maximum_Value_Bytes;
      subtype Key_Index is Positive range 1 .. Maximum_Key_Bytes;
      subtype Value_Index is Positive range 1 .. Maximum_Value_Bytes;

      --  Zero defaults form the canonical unused run slot. A persisted run is
      --  valid only with nonzero identity, sequence interval, and entry count;
      --  changing this empty shape changes record-tail canonicalization.
      type Run_Descriptor is record
         Run_ID                : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
         Lowest_Sequence       : Interfaces.Unsigned_64 := 0;
         Highest_Sequence      : Interfaces.Unsigned_64 := 0;
         Entry_Total           : Interfaces.Unsigned_32 := 0;
         Logical_Payload_Bytes : Interfaces.Unsigned_64 := 0;
      end record;

      type Run_Array is array (Run_Slot) of Run_Descriptor;

      type Family_LSM_State is record
         --  Values are persisted column-family authority. The library supplies
         --  no default and later allocates lazily with checked arithmetic.
         --  Zero limits are invalid empty-state sentinels; Run_Total=0 is the
         --  valid empty run set and its fixed array must remain canonical.
         Memtable_Max_Bytes   : Interfaces.Unsigned_64 := 0;
         Memtable_Max_Entries : Interfaces.Unsigned_32 := 0;
         Maximum_L0_Runs      : Interfaces.Unsigned_32 := 0;
         Run_Total            : Run_Count := 0;
         Runs                 : Run_Array := [others => <>];
      end record;

      type Family_LSM_Array is array (Manifests.Family_Slot) of Family_LSM_State;
      type Identity_Array is array (Identity_Slot) of Head_Policy.Identifier;

      --  Zero/default fields form the decoder's empty failure result. A valid
      --  manifest replaces them with a valid v1 base and explicit persisted
      --  LSM limits; zero never selects a fallback policy.
      type Checkpoint_Manifest is record
         Base                          : Manifests.Manifest := Manifests.Empty_Manifest;
         Replay_Boundary               : Interfaces.Unsigned_64 := 0;
         --  Values are persisted database authority. Zero is invalid, not a
         --  library-selected fallback or convenience default.
         Maximum_Total_L0_Runs         : Interfaces.Unsigned_32 := 0;
         Maximum_Checkpoint_Identities : Interfaces.Unsigned_32 := 0;
         Identity_Total                : Identity_Count := 0;
         Family_LSM                    : Family_LSM_Array := [others => <>];
         Identities                    : Identity_Array := [others => Head_Policy.Zero_Identifier];
      end record;

      --  Canonical all-zero failure output and unused-tail state for the
      --  bounded reference representation; it is never a valid wire object.
      Empty_Checkpoint_Manifest : constant Checkpoint_Manifest := (others => <>);

      --  Derived representation maxima: every family can occupy its frozen
      --  frame, maximum name, and generic run slots; the ledger occupies its
      --  generic identity slots. Changing a field width changes image bounds.
      Max_Checkpoint_Manifest_Payload_Bytes : constant Natural :=
        Manifests.Max_Families
        * (Checkpoint_Family_Header_Length
           + Manifests.Max_Family_Name_Bytes
           + Maximum_Runs_Per_Family * Run_Descriptor_Length)
        + Maximum_Identities * Head_Policy.Identifier_Length;
      Max_Checkpoint_Manifest_Image_Length  : constant Natural :=
        Checkpoint_Manifest_Header_Length + Max_Checkpoint_Manifest_Payload_Bytes + Object_Trailer_Length;

      subtype Checkpoint_Manifest_Image_Index is Natural range 0 .. Max_Checkpoint_Manifest_Image_Length - 1;
      subtype Checkpoint_Manifest_Image is Formats.Byte_Array (Checkpoint_Manifest_Image_Index);

      --  Defaults admit the complete caller-selected generic representation;
      --  callers may only narrow them for a particular decode operation.
      type Checkpoint_Reader_Caps is record
         Runs_Per_Family : Run_Count := Run_Count'Last;
         Identities      : Identity_Count := Identity_Count'Last;
         Payload_Bytes   : Natural range 0 .. Max_Checkpoint_Manifest_Payload_Bytes :=
           Max_Checkpoint_Manifest_Payload_Bytes;
      end record;

      --  Reference-reader convenience: absent caller narrowing, admit the
      --  complete generic representation. This is not an operational default.
      Default_Checkpoint_Reader_Caps : constant Checkpoint_Reader_Caps := (others => <>);

      type Key_Bytes is array (Key_Index) of Formats.Byte;
      type Value_Bytes is array (Value_Index) of Formats.Byte;

      --  Zero defaults form one canonical unused SST-entry slot. A live entry
      --  requires a positive sequence and frozen Put/Delete tag; changing the
      --  zeroed tails changes canonical-record validation.
      type SST_Entry is record
         Sequence         : Interfaces.Unsigned_64 := 0;
         Operation        : Formats.Byte := 0;
         Key_Byte_Total   : Key_Length := 0;
         Value_Byte_Total : Value_Length := 0;
         Key              : Key_Bytes := [others => 0];
         Value            : Value_Bytes := [others => 0];
      end record;

      type SST_Entry_Array is array (SST_Entry_Slot) of SST_Entry;

      --  Zero/default header fields form Empty_SST and are deliberately
      --  structurally invalid. They are failure-output state, not implicit
      --  database, family, or run identifiers.
      type SST is record
         Database_ID           : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
         Run_ID                : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
         Family_ID             : Interfaces.Unsigned_32 := 0;
         Lowest_Sequence       : Interfaces.Unsigned_64 := 0;
         Highest_Sequence      : Interfaces.Unsigned_64 := 0;
         Entry_Total           : SST_Entry_Count := 0;
         Logical_Payload_Bytes : Interfaces.Unsigned_64 := 0;
         Entries               : SST_Entry_Array := [others => <>];
      end record;

      --  Canonical all-zero failure output and unused-entry state for the
      --  bounded reference representation; it is never a valid wire object.
      Empty_SST : constant SST := (others => <>);

      --  Derived representation maxima: each generic entry can occupy its
      --  frozen prefix plus full key/value arrays. A wire-width change must
      --  update these formulas, proof bounds, and golden fixtures together.
      Max_SST_Payload_Bytes : constant Natural :=
        Maximum_SST_Entries * (SST_Entry_Header_Length + Maximum_Key_Bytes + Maximum_Value_Bytes);
      Max_SST_Image_Length  : constant Natural :=
        SST_Header_Length + Max_SST_Payload_Bytes + Object_Trailer_Length;

      subtype SST_Image_Index is Natural range 0 .. Max_SST_Image_Length - 1;
      subtype SST_Image is Formats.Byte_Array (SST_Image_Index);

      --  Defaults admit the complete caller-selected generic representation;
      --  callers may only narrow them for a particular decode operation.
      type SST_Reader_Caps is record
         Entries       : SST_Entry_Count := SST_Entry_Count'Last;
         Key_Bytes     : Key_Length := Key_Length'Last;
         Value_Bytes   : Value_Length := Value_Length'Last;
         Payload_Bytes : Natural range 0 .. Max_SST_Payload_Bytes := Max_SST_Payload_Bytes;
      end record;

      --  Reference-reader convenience matching the full generic SST shape;
      --  persisted family/database limits remain production authority.
      Default_SST_Reader_Caps : constant SST_Reader_Caps := (others => <>);

      type Decode_Status is
        (Decoded,
         Limit_Exceeded,
         Invalid_Magic,
         Unsupported_Version,
         Invalid_Object_Kind,
         Invalid_Flags,
         Wrong_Database,
         Invalid_Length,
         Header_Checksum_Failed,
         Object_Checksum_Failed,
         Invalid_Manifest_State,
         Invalid_Family,
         Invalid_Run,
         Invalid_Identity,
         Invalid_SST_State,
         Invalid_Entry);

      type Encode_Status is (Encoded, Invalid_Value);

      --  Whether one descriptor identifies a nonempty immutable run and its
      --  exact sequence and logical-byte extent.
      function Valid_Run_Descriptor (Value : Run_Descriptor) return Boolean;

      --  Whether Value preserves a valid v1 registry/limit base and adds exact,
      --  bounded per-family run mapping plus the admitted identity ledger.
      function Structurally_Valid (Value : Checkpoint_Manifest) return Boolean;

      --  Number of meaningful bytes written by Encode_Checkpoint_Manifest.
      function Checkpoint_Manifest_Encoded_Length (Value : Checkpoint_Manifest) return Natural
      with Pre => Structurally_Valid (Value);

      --  Encode one complete immutable manifest version 2.
      procedure Encode_Checkpoint_Manifest
        (Value  : Checkpoint_Manifest;
         Image  : out Checkpoint_Manifest_Image;
         Length : out Natural;
         Status : out Encode_Status);

      --  Decode one exact manifest-v2 extent after envelope and checksum
      --  validation. Generic and reader bounds classify as Limit_Exceeded.
      procedure Decode_Checkpoint_Manifest
        (Image             : Formats.Byte_Array;
         Expected_Database : Head_Policy.Identifier;
         Limits            : Checkpoint_Reader_Caps;
         Value             : out Checkpoint_Manifest;
         Status            : out Decode_Status)
      with
        Pre  => not Head_Policy.Is_Zero (Expected_Database),
        Post =>
          (if Status = Decoded
           then Value.Base.Database_ID = Expected_Database and then Structurally_Valid (Value)
           else Value = Empty_Checkpoint_Manifest);

      --  Whether an SST is canonical: entries are ordered by key ascending and,
      --  for equal keys, sequence descending; exact key/sequence duplicates fail.
      function Structurally_Valid (Value : SST) return Boolean;

      --  Whether the SST header exactly authenticates its family mapping and
      --  the manifest descriptor stored within that family frame.
      function Descriptor_Matches
        (Value             : SST;
         Expected_Database : Head_Policy.Identifier;
         Expected_Family   : Interfaces.Unsigned_32;
         Descriptor        : Run_Descriptor) return Boolean;

      --  Number of meaningful bytes written by Encode_SST.
      function SST_Encoded_Length (Value : SST) return Natural
      with Pre => Structurally_Valid (Value);

      --  Encode one complete immutable SST version 1.
      procedure Encode_SST
        (Value : SST; Image : out SST_Image; Length : out Natural; Status : out Encode_Status);

      --  Decode one exact SST-v1 extent after envelope and checksum validation.
      procedure Decode_SST
        (Image             : Formats.Byte_Array;
         Expected_Database : Head_Policy.Identifier;
         Limits            : SST_Reader_Caps;
         Value             : out SST;
         Status            : out Decode_Status)
      with
        Pre  => not Head_Policy.Is_Zero (Expected_Database),
        Post =>
          (if Status = Decoded
           then Value.Database_ID = Expected_Database and then Structurally_Valid (Value)
           else Value = Empty_SST);

   end Reference;

end Flyology.DB.LSM_Formats;
