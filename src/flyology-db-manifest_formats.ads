with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Interfaces;

--  Defines the bounded version-1 column-family manifest codec and transition policy.

private package Flyology.DB.Manifest_Formats
  with SPARK_Mode => On
is

   package Formats renames Flyology.DB.Formats;
   package Head_Policy renames Flyology.DB.Head_Policy;

   use type Head_Policy.Identifier;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Manifest_Format_Version    : constant Interfaces.Unsigned_16 := 1;
   Manifest_Head_Format       : constant Head_Policy.Format_Version := 2;
   Manifest_Object_Kind       : constant Formats.Byte := 3;
   Manifest_Header_Length     : constant := 196;
   Manifest_Trailer_Length    : constant := 4;
   Family_Frame_Header_Length : constant := 28;

   Max_Families               : constant := 64;
   Max_Family_Name_Bytes      : constant := 255;
   Max_Manifest_History       : constant := 64;
   Max_Batch_History          : constant := 64;
   --  Fixed reference-instance values used by golden and proof campaigns. The
   --  persisted U32 mutation/live budgets are operational resource authority
   --  and are not narrowed to these values by the production decoder.
   Max_Batch_Transactions     : constant := 16;
   Max_Transaction_Mutations  : constant := 64;
   Max_Batch_Mutations        : constant := 64;
   Max_Live_Entries           : constant := 4_096;
   Max_Manifest_Payload_Bytes : constant :=
     Max_Families * (Family_Frame_Header_Length + Max_Family_Name_Bytes);
   Max_Manifest_Image_Length  : constant :=
     Manifest_Header_Length + Max_Manifest_Payload_Bytes + Manifest_Trailer_Length;

   subtype Family_Slot is Positive range 1 .. Max_Families;
   subtype Family_Count is Natural range 0 .. Max_Families;
   subtype Family_Name_Length is Natural range 0 .. Max_Family_Name_Bytes;
   subtype Family_Name_Index is Positive range 1 .. Max_Family_Name_Bytes;
   type Family_Name_Bytes is array (Family_Name_Index) of Formats.Byte;

   type Column_Family_Configuration is record
      ID              : Interfaces.Unsigned_32 := 0;
      Max_Key_Bytes   : Interfaces.Unsigned_64 := 0;
      Max_Value_Bytes : Interfaces.Unsigned_64 := 0;
      Name_Length     : Family_Name_Length := 0;
      Name            : Family_Name_Bytes := [others => 0];
   end record;

   type Family_Array is array (Family_Slot) of Column_Family_Configuration;

   type Database_Limits is record
      Maximum_Column_Families           : Interfaces.Unsigned_32 := 0;
      Maximum_Manifest_History          : Interfaces.Unsigned_32 := 0;
      Maximum_Batch_History             : Interfaces.Unsigned_32 := 0;
      Maximum_Transactions_Per_Batch    : Interfaces.Unsigned_32 := 0;
      Maximum_Mutations_Per_Transaction : Interfaces.Unsigned_32 := 0;
      Maximum_Mutations_Per_Batch       : Interfaces.Unsigned_32 := 0;
      Maximum_Live_Entries              : Interfaces.Unsigned_32 := 0;
      --  Logical payload budgets count exact key plus Put-value bytes. Fixed
      --  wire-frame overhead is bounded independently by count ceilings.
      Maximum_Transaction_Payload_Bytes : Interfaces.Unsigned_64 := 0;
      Maximum_Batch_Payload_Bytes       : Interfaces.Unsigned_64 := 0;
      Maximum_Live_State_Bytes          : Interfaces.Unsigned_64 := 0;
   end record;

   type Manifest is record
      Database_ID                   : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Manifest_ID                   : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Previous_Manifest_ID          : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Expected_Transition_ID        : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Expected_Transition_Number    : Interfaces.Unsigned_64 := 0;
      Publication_Transition_ID     : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Publication_Transition_Number : Interfaces.Unsigned_64 := 0;
      Writer_Epoch                  : Interfaces.Unsigned_64 := 0;
      Registry_Revision             : Interfaces.Unsigned_64 := 0;
      Family_Total                  : Family_Count := 0;
      Limits                        : Database_Limits;
      Families                      : Family_Array := [others => <>];
   end record;

   Empty_Manifest : constant Manifest := (others => <>);

   subtype Manifest_Image_Index is Natural range 0 .. Max_Manifest_Image_Length - 1;
   subtype Manifest_Image is Formats.Byte_Array (Manifest_Image_Index);

   type Reader_Caps is record
      Families      : Family_Count := Family_Count'Last;
      Name_Bytes    : Family_Name_Length := Family_Name_Length'Last;
      Payload_Bytes : Natural range 0 .. Max_Manifest_Payload_Bytes := Max_Manifest_Payload_Bytes;
      Key_Bytes     : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Value_Bytes   : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
   end record;

   Default_Reader_Caps : constant Reader_Caps := (others => <>);

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
      Invalid_Limits,
      Invalid_Family,
      Invalid_Name,
      Duplicate_Name);

   type Encode_Status is (Encoded, Invalid_Value);

   --  Whether one definite family record has a canonical, valid identity/name
   --  and nonzero semantic key/value limits, independent of database budgets.
   function Valid_Configuration (Value : Column_Family_Configuration) return Boolean;

   --  Whether Value is a complete root or successor manifest with valid limits
   --  and a strictly ID-ordered, uniquely named UTF-8 family registry.
   function Structurally_Valid (Value : Manifest) return Boolean;

   --  Whether one structurally valid manifest fits this address space and the
   --  synchronous public group surface. Persisted byte limits, rather than
   --  fixed key/value arrays, are the operational allocation authority.
   function Runtime_Compatible (Value : Manifest) return Boolean
   with Pre => Structurally_Valid (Value);

   --  Whether Value is the first immutable registry published with initial HEAD.
   function Is_Root (Value : Manifest) return Boolean;

   --  Whether Current is one append-only registry successor of Previous.
   function Valid_Predecessor (Current, Previous : Manifest) return Boolean;

   --  Whether Candidate has a reachable manifest-bearing HEAD-v2 shape.
   function Manifest_Head_Structurally_Valid (Candidate : Head_Policy.Head_State) return Boolean;

   --  Whether Candidate is the initial manifest-bearing HEAD. This additive
   --  predicate models future HEAD v2 without changing current HEAD-v1 validity.
   function Valid_Root_Publication (Candidate : Head_Policy.Head_State; Value : Manifest) return Boolean;

   --  Whether Candidate publishes a successor manifest from exact Current.
   --  The transition preserves sequence and latest batch, and advances only the
   --  manifest reference and exact HEAD transition identity.
   function Valid_Publication (Current, Candidate : Head_Policy.Head_State; Value : Manifest) return Boolean;

   --  Whether a current or later HEAD still references Value as its latest
   --  manifest. Exact and immediate-successor references bind the HEAD predecessor;
   --  later references retain only the reachable ordinal/epoch rule. This is a
   --  recovery binding, not transition-publication proof.
   function Referenced_By (Value : Manifest; Referencing_Head : Head_Policy.Head_State) return Boolean;

   --  Number of meaningful bytes written by Encode_Manifest.
   function Encoded_Length (Value : Manifest) return Natural
   with
     Pre  => Structurally_Valid (Value),
     Post =>
       Encoded_Length'Result in Manifest_Header_Length + Manifest_Trailer_Length .. Max_Manifest_Image_Length;

   --  Encode one complete version-1 immutable family manifest.
   procedure Encode_Manifest
     (Value : Manifest; Image : out Manifest_Image; Length : out Natural; Status : out Encode_Status)
   with
     Post =>
       (if Status = Encoded
        then Length in Manifest_Header_Length + Manifest_Trailer_Length .. Max_Manifest_Image_Length
        else Length = 0);

   --  Decode one exact manifest extent. Total representation admission is checked
   --  first. For admitted images, envelope integrity and database identity precede
   --  declared reader-cap checks; Limit_Exceeded does not certify skipped frames.
   procedure Decode_Manifest
     (Image             : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Limits            : Reader_Caps;
      Value             : out Manifest;
      Status            : out Decode_Status)
   with
     Pre  => not Head_Policy.Is_Zero (Expected_Database),
     Post =>
       (if Status = Decoded
        then Value.Database_ID = Expected_Database and then Structurally_Valid (Value)
        else Value = Empty_Manifest);

end Flyology.DB.Manifest_Formats;
