with Interfaces;
with Flyology.DB.Head_Policy;

--  Defines explicit, versioned persisted byte formats.
private package Flyology.DB.Formats
  with SPARK_Mode => On
is

   use type Head_Policy.Identifier;

   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (Natural range <>) of Byte;

   Head_Format_Version : constant Interfaces.Unsigned_16 := 1;
   Head_Image_Length : constant := 136;
   subtype Head_Image_Index is Natural range 0 .. Head_Image_Length - 1;
   subtype Head_Image is Byte_Array (Head_Image_Index);

   type Decode_Status is
     (Decoded,
      Invalid_Magic,
      Unsupported_Version,
      Invalid_Object_Kind,
      Invalid_Flags,
      Wrong_Database,
      Invalid_Length,
      Invalid_Head_State,
      Header_Checksum_Failed,
      Object_Checksum_Failed);

   --  CRC-32C checksum with the Castagnoli polynomial.
   function CRC_32C (Data : Byte_Array) return Interfaces.Unsigned_32;

   --  Encode one complete version-1 database-head object.
   function Encode_Head (Value : Head_Policy.Head_State) return Head_Image
   with
     Pre => Head_Policy.Structurally_Valid (Value);

   --  Decode and validate one exact version-1 database-head object.
   procedure Decode_Head
     (Image             : Byte_Array;
      Expected_Database : Head_Policy.Identifier;
      Value             : out Head_Policy.Head_State;
      Status            : out Decode_Status)
   with
     Pre => not Head_Policy.Is_Zero (Expected_Database),
     Post =>
       (if Status = Decoded then
          Value.Database_ID = Expected_Database
          and then Head_Policy.Structurally_Valid (Value));

end Flyology.DB.Formats;
