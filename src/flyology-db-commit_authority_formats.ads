with Flyology.DB.Head_Policy;

--  Defines the private versioned envelope used to retain exact commit
--  reconciliation authority outside one process. The embedded batch remains
--  the existing batch-v1 image; this package adds no operational batch bound.

private package Flyology.DB.Commit_Authority_Formats
  with SPARK_Mode => On
is

   package Heads renames Flyology.DB.Head_Policy;

   use type Heads.Commit_Sequence;
   use type Heads.Identifier;

   --  Frozen authority-v1 envelope: 360-byte header, exact batch bytes, and
   --  one four-byte object CRC. A format change requires a new version.
   Authority_Header_Length  : constant := 360;
   Authority_Trailer_Length : constant := 4;

   type Authority_Metadata is record
      Transaction_ID    : Heads.Identifier := Heads.Zero_Identifier;
      Assigned_Sequence : Heads.Commit_Sequence := 0;
      Batch_ID          : Heads.Identifier := Heads.Zero_Identifier;
      Expected_Head     : Heads.Head_State;
      Attempted_Head    : Heads.Head_State;
   end record;

   Empty_Authority : constant Authority_Metadata := (others => <>);

   type Encode_Status is (Encoded, Invalid_Value, Invalid_Length);
   type Decode_Status is
     (Decoded,
      Invalid_Magic,
      Unsupported_Version,
      Invalid_Object_Kind,
      Invalid_Flags,
      Wrong_Database,
      Invalid_Length,
      Header_Checksum_Failed,
      Object_Checksum_Failed,
      Invalid_Authority_State);

   --  Whether the scalar authority describes one member of the exact commit
   --  transition. Batch member identity and bytes are validated by the caller's
   --  operational batch decoder after envelope decoding.
   function Structurally_Valid (Value : Authority_Metadata) return Boolean
   with
     Post =>
       (if Structurally_Valid'Result
        then
          Heads.Structurally_Valid (Value.Expected_Head)
          and then Heads.Structurally_Valid (Value.Attempted_Head));

   --  Nonallocating authentication of the retained operational batch envelope
   --  and its exact member. It imposes no reference-codec maximum; the caller
   --  still performs the full operational decode under persisted limits.
   function Batch_Member_Valid (Value : Authority_Metadata; Batch : Byte_Array) return Boolean;

   --  The runtime instantiates this accessor form for its retained unbounded
   --  image. It performs the same scan and CRC checks without copying that
   --  image or writing the caller's export buffer.
   generic
      type Source_Type is private;
      with function Source_Length (Source : Source_Type) return Natural;
      with
        function Source_Element (Source : Source_Type; Index : Positive) return Byte
        with Pre => Index <= Source_Length (Source);
   function Source_Batch_Member_Valid (Value : Authority_Metadata; Source : Source_Type) return Boolean;

   --  Exact envelope extent, or zero when a nonempty batch cannot fit Natural.
   function Encoded_Length (Batch_Length : Natural) return Natural
   with
     Post =>
       (if Encoded_Length'Result /= 0
        then
          Batch_Length > 0
          and then Encoded_Length'Result = Authority_Header_Length + Batch_Length + Authority_Trailer_Length);

   --  Initialize the complete fixed header and zero the caller-sized image.
   --  The caller copies the retained batch at Batch_First and then calls Seal.
   procedure Encode_Header
     (Value : Authority_Metadata; Batch_Length : Natural; Image : out Byte_Array; Status : out Encode_Status)
   with
     Post =>
       (if Status = Encoded
        then Encoded_Length (Batch_Length) = Image'Length
        else Image = [Image'Range => 0]);

   --  First caller-array index reserved for the exact embedded batch.
   function Batch_First (Image : Byte_Array) return Positive
   with
     Pre  => Image'Length >= Authority_Header_Length + Authority_Trailer_Length,
     Post => Batch_First'Result = Image'First + Authority_Header_Length;

   --  Seal a header-plus-batch image with its trailing object CRC.
   procedure Seal (Image : in out Byte_Array)
   with Pre => Image'Length >= Authority_Header_Length + Authority_Trailer_Length;

   --  Decode and validate only the authority envelope. The returned batch
   --  extent is then authenticated by the operational batch decoder under the
   --  open database's persisted limits. Every failure returns empty outputs.
   procedure Decode
     (Image             : Byte_Array;
      Expected_Database : Heads.Identifier;
      Value             : out Authority_Metadata;
      Batch_Start       : out Positive;
      Batch_Length      : out Natural;
      Status            : out Decode_Status)
   with
     Pre  => not Heads.Is_Zero (Expected_Database),
     Post =>
       (if Status = Decoded
        then
          Structurally_Valid (Value)
          and then Value.Expected_Head.Database_ID = Expected_Database
          and then Batch_Length > 0
          and then Batch_Start = Image'First + Authority_Header_Length
          and then Batch_Start + Batch_Length - 1 = Image'Last - Authority_Trailer_Length
        else Value = Empty_Authority and then Batch_Length = 0);

   --  Fixed reference wrapper used only to make GNATprove analyze copy and
   --  sealing bounds. Its actual is a proof dimension, never runtime policy.
   generic
      Maximum_Batch_Length : Positive;
   package Reference with SPARK_Mode => On is
      subtype Reference_Batch is Byte_Array (1 .. Maximum_Batch_Length);
      subtype Reference_Image is
        Byte_Array (1 .. Authority_Header_Length + Maximum_Batch_Length + Authority_Trailer_Length);

      procedure Encode
        (Value  : Authority_Metadata;
         Batch  : Reference_Batch;
         Image  : out Reference_Image;
         Status : out Encode_Status);
   end Reference;

end Flyology.DB.Commit_Authority_Formats;
