with Interfaces;
with Flyology.DB.Identity_Partition_Policy;

--  Instantiates the runtime identity-partition policy so GNATprove generates
--  checks for the generic body. Array extents remain caller-selected and add
--  no proof-only product capacity or default.

private package Flyology.DB.Identity_Partition_Proof
  with SPARK_Mode => On
is

   type Proof_Identity_Array is
     array (Positive range <>) of Interfaces.Unsigned_64;
   type Proof_Batch_Index_Array is array (Positive range <>) of Natural;

   package Instance is new
     Flyology.DB.Identity_Partition_Policy
       (Identity          => Interfaces.Unsigned_64,
        Zero              => 0,
        Identity_Array    => Proof_Identity_Array,
        Batch_Index_Array => Proof_Batch_Index_Array);

end Flyology.DB.Identity_Partition_Proof;
