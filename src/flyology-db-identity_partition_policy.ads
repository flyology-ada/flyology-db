--  Proves the exact partition between checkpoint and live-suffix identities.

private generic
   type Identity is private;
   Zero : Identity;
   type Identity_Array is array (Positive range <>) of Identity;
   type Batch_Index_Array is array (Positive range <>) of Natural;
package Flyology.DB.Identity_Partition_Policy with SPARK_Mode => On is

   --  Reserved is the authenticated complete identity ledger. Checkpoint is
   --  its retained-checkpoint portion. Batch_IDs and Member_IDs describe the
   --  post-checkpoint suffix; Member_Batches maps every member to one batch.
   --  A singleton aliases its batch and member identity and therefore counts
   --  once. A multi-member group requires a distinct batch identity.
   function Valid_Partition
     (Reserved       : Identity_Array;
      Checkpoint     : Identity_Array;
      Batch_IDs      : Identity_Array;
      Member_IDs     : Identity_Array;
      Member_Batches : Batch_Index_Array) return Boolean
   with Pre => Member_IDs'First = Member_Batches'First and then Member_IDs'Last = Member_Batches'Last;

end Flyology.DB.Identity_Partition_Policy;
