with Interfaces;

--  Defines the persisted selector for commit-publication semantics. Runtime
--  cohort width and admission timing are deliberately not persisted here.

private package Flyology.DB.Commit_Profiles
  with SPARK_Mode => On
is

   use type Interfaces.Unsigned_32;

   type Commit_Publication_Profile is
     (Standard_Publication, Independent_Coalescing, Aggregate_Coalescing);

   Standard_Profile_Code               : constant Interfaces.Unsigned_32 := 0;
   Independent_Coalescing_Profile_Code : constant Interfaces.Unsigned_32 := 1;
   Aggregate_Coalescing_Profile_Code   : constant Interfaces.Unsigned_32 := 2;

   function Encode (Value : Commit_Publication_Profile) return Interfaces.Unsigned_32
   with
     Post =>
       Encode'Result
       = (case Value is
            when Standard_Publication   => Standard_Profile_Code,
            when Independent_Coalescing => Independent_Coalescing_Profile_Code,
            when Aggregate_Coalescing   => Aggregate_Coalescing_Profile_Code);

   procedure Decode
     (Code : Interfaces.Unsigned_32; Value : out Commit_Publication_Profile; Valid : out Boolean)
   with
     Post =>
       Valid =
         (Code = Standard_Profile_Code
          or else Code = Independent_Coalescing_Profile_Code
          or else Code = Aggregate_Coalescing_Profile_Code)
       and then (if Valid then Encode (Value) = Code else Value = Standard_Publication);

end Flyology.DB.Commit_Profiles;
