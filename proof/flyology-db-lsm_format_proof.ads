with Flyology.DB.LSM_Formats;

--  Instantiates the generic reference codec so GNATprove generates checks for
--  its body. These capacities are proof dimensions, not database policy.

private package Flyology.DB.LSM_Format_Proof
  with SPARK_Mode => On
is

   --  Two run slots expose ordering/nonoverlap; four identities and entries
   --  expose exact and over-cap states; eight-byte arrays expose canonical
   --  tails. These are proof dimensions, never product defaults or ceilings.
   package Instance is new
     Flyology.DB.LSM_Formats.Reference
       (Maximum_Runs_Per_Family => 2,
        Maximum_Identities      => 4,
        Maximum_SST_Entries     => 4,
        Maximum_Key_Bytes       => 8,
        Maximum_Value_Bytes     => 8);

end Flyology.DB.LSM_Format_Proof;
