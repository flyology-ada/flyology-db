with Ada.Streams;
with Interfaces;

procedure Copy_Probe is
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   type Byte_Array is array (Positive range <>) of Interfaces.Unsigned_8;

   procedure Copy
     (Item_Key : Byte_Array;
      Data     : Byte_Array;
      Target   : out Ada.Streams.Stream_Element_Array)
   is
   begin
      if Item_Key'Length > 0 then
         Target (1 .. Ada.Streams.Stream_Element_Offset (Item_Key'Length)) :=
           [for Value of Item_Key => Ada.Streams.Stream_Element (Value)];
      end if;
      if Data'Length > 0 then
         Target
           (Ada.Streams.Stream_Element_Offset (Item_Key'Length) + 1
            .. Ada.Streams.Stream_Element_Offset (Item_Key'Length + Data'Length)) :=
             [for Value of Data => Ada.Streams.Stream_Element (Value)];
      end if;
   end Copy;

   Key    : constant Byte_Array := [16#12#, 16#34#];
   Data   : constant Byte_Array := [16#56#, 16#78#];
   Target : Ada.Streams.Stream_Element_Array (1 .. 4);
begin
   Copy (Key, Data, Target);
   if Target (4) /= 16#78# then
      raise Program_Error;
   end if;
end Copy_Probe;
