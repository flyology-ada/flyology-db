with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Interfaces;

--  Defines the bounded operational representation and wire codec for commit batches.
private package Flyology.DB.Batch_Formats
  with SPARK_Mode => On
is

   package Formats renames Flyology.DB.Formats;
   package Head_Policy renames Flyology.DB.Head_Policy;

   use type Head_Policy.Identifier;
   use type Head_Policy.Commit_Sequence;

   Batch_Header_Length : constant := 156;
   Batch_Trailer_Length : constant := 4;
   Transaction_Frame_Header_Length : constant := 32;
   Mutation_Frame_Header_Length : constant := 14;

   --  These are version-1 reader and in-memory limits, not wire-format limits.
   Max_Transactions : constant := 16;
   Max_Mutations : constant := 64;
   Max_Key_Bytes : constant := 64;
   Max_Value_Bytes : constant := 256;
   Max_Batch_Image_Length : constant :=
     Batch_Header_Length + Batch_Trailer_Length
     + Max_Transactions * Transaction_Frame_Header_Length
     + Max_Mutations * (Mutation_Frame_Header_Length + Max_Key_Bytes + Max_Value_Bytes);
   Max_Payload_Bytes : constant := Max_Batch_Image_Length - Batch_Header_Length - Batch_Trailer_Length;

   subtype Transaction_Slot is Positive range 1 .. Max_Transactions;
   subtype Mutation_Slot is Positive range 1 .. Max_Mutations;
   subtype Transaction_Count is Natural range 0 .. Max_Transactions;
   subtype Mutation_Count is Natural range 0 .. Max_Mutations;
   subtype Key_Length is Natural range 0 .. Max_Key_Bytes;
   subtype Value_Length is Natural range 0 .. Max_Value_Bytes;

   type Key_Bytes is array (Positive range 1 .. Max_Key_Bytes) of Formats.Byte;
   type Value_Bytes is array (Positive range 1 .. Max_Value_Bytes) of Formats.Byte;

   type Mutation_Kind is (Put, Delete);

   type Mutation is record
      Column_Family : Interfaces.Unsigned_32 := 0;
      Operation     : Mutation_Kind := Put;
      Key_Size      : Key_Length := 0;
      Key            : Key_Bytes := [others => 0];
      Value_Size    : Value_Length := 0;
      Value          : Value_Bytes := [others => 0];
   end record;

   type Transaction is record
      Transaction_ID : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Sequence       : Head_Policy.Commit_Sequence := 0;
      First_Mutation : Mutation_Count := 0;
      Mutations      : Mutation_Count := 0;
   end record;

   type Transaction_Array is array (Transaction_Slot) of Transaction;
   type Mutation_Array is array (Mutation_Slot) of Mutation;

   type Commit_Batch is record
      Database_ID                    : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Epoch                          : Head_Policy.Writer_Epoch := 0;
      Batch_ID                       : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Previous_Batch_ID              : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Expected_Transition_ID         : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Expected_Transition_Number     : Head_Policy.Transition_Ordinal :=
        Head_Policy.Transition_Ordinal'First;
      Publication_Transition_ID      : Head_Policy.Identifier := Head_Policy.Zero_Identifier;
      Publication_Transition_Number : Head_Policy.Transition_Ordinal :=
        Head_Policy.Transition_Ordinal'First;
      First_Sequence                 : Head_Policy.Commit_Sequence := 0;
      Last_Sequence                  : Head_Policy.Commit_Sequence := 0;
      Transaction_Total              : Transaction_Count := 0;
      Mutation_Total                 : Mutation_Count := 0;
      Transactions                   : Transaction_Array := [others => <>];
      Mutations                      : Mutation_Array := [others => <>];
   end record;

   Empty_Batch : constant Commit_Batch := (others => <>);

   subtype Batch_Image_Index is Natural range 0 .. Max_Batch_Image_Length - 1;
   subtype Batch_Image is Formats.Byte_Array (Batch_Image_Index);

   type Reader_Caps is record
      Transactions  : Transaction_Count := Transaction_Count'Last;
      Mutations     : Mutation_Count := Mutation_Count'Last;
      Key_Bytes     : Key_Length := Key_Length'Last;
      Value_Bytes   : Value_Length := Value_Length'Last;
      Payload_Bytes : Natural range 0 .. Max_Payload_Bytes := Max_Payload_Bytes;
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
      Invalid_Batch_State,
      Invalid_Transaction,
      Invalid_Mutation,
      Duplicate_Transaction,
      Duplicate_Key,
      Head_Mismatch);

   type Encode_Status is (Encoded, Invalid_Value);

   --  Whether Value has a complete, unambiguous version-1 operational shape.
   function Structurally_Valid (Value : Commit_Batch) return Boolean;

   --  Number of meaningful bytes written by Encode_Batch.
   function Encoded_Length (Value : Commit_Batch) return Natural
   with
     Pre => Structurally_Valid (Value),
     Post => Encoded_Length'Result in Batch_Header_Length + Batch_Trailer_Length
       .. Max_Batch_Image_Length;

   --  Encode Value at Image (0 .. Length - 1); bytes after Length are zero.
   procedure Encode_Batch
     (Value  : Commit_Batch;
      Image  : out Batch_Image;
      Length : out Natural;
      Status : out Encode_Status)
   with
     Post =>
       (if Status = Encoded then
          Length in Batch_Header_Length + Batch_Trailer_Length .. Max_Batch_Image_Length
        else Length = 0);

   --  Whether the referencing head publishes this exact batch and transition.
   function Published_By
     (Value            : Commit_Batch;
      Referencing_Head : Head_Policy.Head_State) return Boolean;

   --  Whether Value is the first batch in a reachable commit chain.
   function Is_First_Batch (Value : Commit_Batch) return Boolean is
     (Value.First_Sequence = 1
      and then Head_Policy.Is_Zero (Value.Previous_Batch_ID));

   --  Whether Current immediately follows Previous in the immutable batch chain.
   --  HEAD transitions may intervene; an exact ordinal edge also requires its ID.
   function Valid_Predecessor
     (Current  : Commit_Batch;
      Previous : Commit_Batch) return Boolean;

   --  Decode one exact batch without requiring a retained historical HEAD.
   --  Every non-Decoded result leaves Value equal to Empty_Batch.
   procedure Decode_Batch
     (Image             : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Limits            : Reader_Caps;
      Value             : out Commit_Batch;
      Status            : out Decode_Status)
   with
     Pre => not Head_Policy.Is_Zero (Expected_Database),
     Post =>
       (if Status = Decoded then
          Value.Database_ID = Expected_Database
          and then Structurally_Valid (Value)
        else Value = Empty_Batch);

   --  Decode the latest batch and bind it to the live HEAD that made it visible.
   --  Every non-Decoded result leaves Value equal to Empty_Batch.
   procedure Decode_Latest_Batch
     (Image             : Formats.Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Referencing_Head  : Head_Policy.Head_State;
      Limits            : Reader_Caps;
      Value             : out Commit_Batch;
      Status            : out Decode_Status)
   with
     Pre => not Head_Policy.Is_Zero (Expected_Database),
     Post =>
       (if Status = Decoded then
          Value.Database_ID = Expected_Database
          and then Structurally_Valid (Value)
          and then Published_By (Value, Referencing_Head)
        else Value = Empty_Batch);

end Flyology.DB.Batch_Formats;
