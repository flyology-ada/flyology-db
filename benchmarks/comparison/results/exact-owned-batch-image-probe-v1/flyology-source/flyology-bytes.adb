with Ada.Containers;

package body Flyology.Bytes is

   use type Ada.Containers.Count_Type;
   use type Ada.Streams.Stream_Element_Offset;

   function Length (Data : Unbounded_Bytes) return Natural is
   begin
      return Natural (Data.Value.Length);
   end Length;

   function Element (Data : Unbounded_Bytes; Index : Positive) return Ada.Streams.Stream_Element
   is (Data.Value.Element (Index));

   procedure Copy
     (Data          : Unbounded_Bytes;
      Source_Offset : Natural;
      Target        : out Ada.Streams.Stream_Element_Array)
   is
   begin
      if Target'Length = 0 then
         return;
      elsif Source_Offset > Length (Data)
        or else Target'Length > Length (Data) - Source_Offset
      then
         raise Constraint_Error with "byte copy range exceeds source length";
      end if;
      for Offset in Natural range 0 .. Target'Length - 1 loop
         Target (Target'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Data.Value.Element (Source_Offset + Offset + 1);
      end loop;
   end Copy;

   procedure Append (Data : in out Unbounded_Bytes; Value : Ada.Streams.Stream_Element_Array) is
      New_Length : constant Ada.Containers.Count_Type :=
        Data.Value.Length + Ada.Containers.Count_Type (Value'Length);
   begin
      Data.Value.Reserve_Capacity (New_Length);
      for Element of Value loop
         Data.Value.Append (Element);
      end loop;
   end Append;

   procedure Append (Data : in out Unbounded_Bytes; Value : Unbounded_Bytes) is
   begin
      Data.Value.Append_Vector (Value.Value);
   end Append;

   procedure Append (Data : in out Unbounded_Bytes; Value : Ada.Streams.Stream_Element) is
   begin
      Data.Value.Append (Value);
   end Append;

   procedure Reserve_Capacity (Data : in out Unbounded_Bytes; Capacity : Natural) is
   begin
      Data.Value.Reserve_Capacity (Ada.Containers.Count_Type (Capacity));
   end Reserve_Capacity;

   procedure Append_Byte_String (Data : in out Unbounded_Bytes; Value : String) is
      New_Length : constant Ada.Containers.Count_Type :=
        Data.Value.Length + Ada.Containers.Count_Type (Value'Length);
   begin
      Data.Value.Reserve_Capacity (New_Length);
      for Index in Value'Range loop
         Data.Value.Append (Ada.Streams.Stream_Element (Character'Pos (Value (Index))));
      end loop;
   end Append_Byte_String;

   function To_Unbounded_Bytes (Data : Ada.Streams.Stream_Element_Array) return Unbounded_Bytes is
      Result : Unbounded_Bytes;
   begin
      Append (Result, Data);
      return Result;
   end To_Unbounded_Bytes;

   function From_Byte_String (Data : String) return Unbounded_Bytes is
      Result : Unbounded_Bytes;
   begin
      Append_Byte_String (Result, Data);
      return Result;
   end From_Byte_String;

   function To_Array (Data : Unbounded_Bytes) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Length (Data)));
      Cursor : Ada.Streams.Stream_Element_Offset := 0;
   begin
      for Element of Data.Value loop
         Cursor := Ada.Streams.Stream_Element_Offset'Succ (Cursor);
         Result (Cursor) := Element;
      end loop;
      return Result;
   end To_Array;

   function To_Byte_String (Data : Unbounded_Bytes) return String is
      Result : String (1 .. Length (Data));
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val (Data.Value.Element (Index));
      end loop;
      return Result;
   end To_Byte_String;

   procedure Clear (Data : in out Unbounded_Bytes) is
      Replacement : Storage.Vector;
   begin
      Storage.Move (Target => Data.Value, Source => Replacement);
   end Clear;

   procedure Move (Target : in out Unbounded_Bytes; Source : in out Unbounded_Bytes) is
   begin
      Storage.Move (Target => Target.Value, Source => Source.Value);
   end Move;

end Flyology.Bytes;
