with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Flyology.DB.LSM_Formats;
with Flyology.DB.Manifest_Formats;
with Interfaces;

--  Provides the operational checkpoint-manifest-v2 and SST-v1 codec. Unlike
--  the bounded proof oracle, retained arrays are sized exactly from validated
--  persisted state and no library-selected key, value, run, or ledger ceiling
--  is introduced.

private package Flyology.DB.LSM_Runtime_Formats is

   package Formats renames Flyology.DB.Formats;
   package Head_Policy renames Flyology.DB.Head_Policy;
   package LSM renames Flyology.DB.LSM_Formats;
   package Manifests renames Flyology.DB.Manifest_Formats;

   subtype Run_Descriptor is LSM.Run_Descriptor;

   type Allocation_Status is (Allocated, Invalid_Extent, Allocation_Failed);

   type Decode_Status is
     (Decoded,
      Limit_Exceeded,
      Allocation_Failed,
      Invalid_Magic,
      Unsupported_Version,
      Invalid_Object_Kind,
      Invalid_Flags,
      Wrong_Database,
      Invalid_Length,
      Header_Checksum_Failed,
      Object_Checksum_Failed,
      Invalid_Manifest_State,
      Runtime_Incompatible,
      Invalid_Family,
      Invalid_Run,
      Invalid_Identity,
      Invalid_SST_State,
      Invalid_Entry);

   type Encode_Status is (Encoded, Invalid_Value, Length_Overflow, Allocation_Failed);

   type Image_Access is access all Formats.Byte_Array;

   --  Header-only admission result. Object_Length is the exact retained extent;
   --  Maximum_Object_Length is derived from the authenticated family count,
   --  database run ceiling, actual identity count, and frozen field widths.
   type Checkpoint_Header_Admission is record
      Object_Length                 : Natural := 0;
      Family_Total                  : Natural := 0;
      Identity_Total                : Natural := 0;
      Maximum_Total_L0_Runs         : Interfaces.Unsigned_32 := 0;
      Maximum_Checkpoint_Identities : Interfaces.Unsigned_32 := 0;
      Maximum_Object_Length         : Interfaces.Unsigned_64 := 0;
   end record;

   --  Canonical no-admission output. Zero fields never authorize a read or a
   --  fallback allocation and therefore have no compatibility meaning.
   Empty_Checkpoint_Header_Admission : constant Checkpoint_Header_Admission := (others => <>);

   --  Validate the exact frozen manifest header and authenticate a transport-
   --  reported whole-object length before the caller retains that whole object.
   --  The maximum is a formula consequence, not an allocation request.
   procedure Inspect_Checkpoint_Manifest_Header
     (Header            : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Object_Length     : Interfaces.Unsigned_64;
      Admission         : out Checkpoint_Header_Admission;
      Status            : out Decode_Status);

   type Family_LSM_State is record
      --  Persisted per-family allocation and backpressure authority. Zero is
      --  invalid and never selects a library fallback.
      Memtable_Max_Bytes   : Interfaces.Unsigned_64 := 0;
      Memtable_Max_Entries : Interfaces.Unsigned_32 := 0;
      Maximum_L0_Runs      : Interfaces.Unsigned_32 := 0;
      --  Exact slice into the enclosing flat run array. A runless family uses
      --  First_Run=0, Run_Total=0; no unused run slots are retained.
      First_Run            : Natural := 0;
      Run_Total            : Natural := 0;
   end record;

   type Family_LSM_Array is array (Positive range <>) of Family_LSM_State;
   type Run_Array is array (Positive range <>) of Run_Descriptor;
   type Identity_Array is array (Positive range <>) of Head_Policy.Identifier;

   --  One exact heap object retains only actual family/run/identity extents.
   --  The fixed Base registry is the current public 64-family compatibility
   --  boundary; all LSM collections themselves are dynamically sized.
   type Checkpoint_Manifest (Family_Total, Run_Total, Identity_Total : Natural) is record
      Base                          : Manifests.Manifest := Manifests.Empty_Manifest;
      Replay_Boundary               : Interfaces.Unsigned_64 := 0;
      Maximum_Total_L0_Runs         : Interfaces.Unsigned_32 := 0;
      Maximum_Checkpoint_Identities : Interfaces.Unsigned_32 := 0;
      Families                      : Family_LSM_Array (1 .. Family_Total);
      Runs                          : Run_Array (1 .. Run_Total);
      Identities                    : Identity_Array (1 .. Identity_Total);
   end record;

   type Checkpoint_Manifest_Access is access all Checkpoint_Manifest;

   --  Allocate one exact builder shape. Invalid representational extents and
   --  storage exhaustion are typed and Value remains null on every failure.
   procedure Create_Checkpoint_Manifest
     (Family_Total   : Natural;
      Run_Total      : Natural;
      Identity_Total : Natural;
      Value          : out Checkpoint_Manifest_Access;
      Status         : out Allocation_Status);

   procedure Release (Value : in out Checkpoint_Manifest_Access);

   function Structurally_Valid (Value : Checkpoint_Manifest) return Boolean;

   --  Encode/decode exact immutable manifest-v2 objects. Decode performs a
   --  nonallocating structural pass first and publishes Value only after the
   --  exact allocation has been populated and revalidated.
   procedure Encode_Checkpoint_Manifest
     (Value : Checkpoint_Manifest; Image : out Image_Access; Status : out Encode_Status);

   procedure Decode_Checkpoint_Manifest
     (Image             : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Value             : out Checkpoint_Manifest_Access;
      Status            : out Decode_Status);

   type SST_Header_Admission is record
      --  Exact extent follows from the authenticated header and the manifest's
      --  exact descriptor; it is the only whole-object allocation authority.
      Object_Length : Natural := 0;
      Entry_Total   : Natural := 0;
      Payload_Bytes : Natural := 0;
   end record;

   --  Canonical no-admission output. Zero fields never authorize a retained
   --  SST extent and are not persisted defaults.
   Empty_SST_Header_Admission : constant SST_Header_Admission := (others => <>);

   procedure Inspect_SST_Header
     (Header              : Formats.Byte_Array;
      Expected_Database   : Head_Policy.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : Run_Descriptor;
      Object_Length       : Interfaces.Unsigned_64;
      Admission           : out SST_Header_Admission;
      Status              : out Decode_Status);

   type SST_Entry is record
      Sequence         : Interfaces.Unsigned_64 := 0;
      Operation        : Formats.Byte := 0;
      Key_Offset       : Natural := 0;
      Key_Byte_Total   : Natural := 0;
      Value_Offset     : Natural := 0;
      Value_Byte_Total : Natural := 0;
   end record;

   type SST_Entry_Array is array (Positive range <>) of SST_Entry;

   --  Entry offsets describe one canonical compact key/value payload. The
   --  discriminants allocate only actual descriptors and logical bytes.
   type SST (Entry_Total, Payload_Byte_Total : Natural) is record
      Database_ID           : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Run_ID                : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Family_ID             : Interfaces.Unsigned_32 := 0;
      Lowest_Sequence       : Interfaces.Unsigned_64 := 0;
      Highest_Sequence      : Interfaces.Unsigned_64 := 0;
      Logical_Payload_Bytes : Interfaces.Unsigned_64 := 0;
      Entries               : SST_Entry_Array (1 .. Entry_Total);
      Payload               : Formats.Byte_Array (1 .. Payload_Byte_Total);
   end record;

   type SST_Access is access all SST;

   procedure Create_SST
     (Entry_Total        : Natural;
      Payload_Byte_Total : Natural;
      Value              : out SST_Access;
      Status             : out Allocation_Status);

   procedure Release (Value : in out SST_Access);

   function Structurally_Valid (Value : SST) return Boolean;

   function Descriptor_Matches
     (Value             : SST;
      Expected_Database : Head_Policy.Identifier;
      Expected_Family   : Interfaces.Unsigned_32;
      Descriptor        : Run_Descriptor) return Boolean;

   procedure Encode_SST (Value : SST; Image : out Image_Access; Status : out Encode_Status);

   procedure Decode_SST
     (Image               : Formats.Byte_Array;
      Expected_Database   : Head_Policy.Identifier;
      Expected_Family     : Interfaces.Unsigned_32;
      Expected_Descriptor : Run_Descriptor;
      Maximum_Key_Bytes   : Interfaces.Unsigned_64;
      Maximum_Value_Bytes : Interfaces.Unsigned_64;
      Value               : out SST_Access;
      Status              : out Decode_Status);

   --  Release an exact encoded image returned by either encoder.
   procedure Release (Image : in out Image_Access);

end Flyology.DB.LSM_Runtime_Formats;
