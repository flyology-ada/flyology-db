package body Flyology.DB.Commit_Profiles
  with SPARK_Mode => On
is

   function Encode (Value : Commit_Publication_Profile) return Interfaces.Unsigned_32
   is (case Value is
         when Standard_Publication   => Standard_Profile_Code,
         when Independent_Coalescing => Independent_Coalescing_Profile_Code);

   procedure Decode
     (Code : Interfaces.Unsigned_32; Value : out Commit_Publication_Profile; Valid : out Boolean) is
   begin
      if Code = Standard_Profile_Code then
         Value := Standard_Publication;
         Valid := True;
      elsif Code = Independent_Coalescing_Profile_Code then
         Value := Independent_Coalescing;
         Valid := True;
      else
         Value := Standard_Publication;
         Valid := False;
      end if;
   end Decode;

end Flyology.DB.Commit_Profiles;
