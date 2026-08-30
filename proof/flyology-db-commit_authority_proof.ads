with Flyology.DB.Batch_Formats;
with Flyology.DB.Commit_Authority_Formats;

--  Instantiates the authority copy/sealing wrapper so GNATprove analyzes its
--  bounds at the maintained batch-format proof dimension, not as runtime policy.

private package Flyology.DB.Commit_Authority_Proof
  with SPARK_Mode => On
is

   package Instance is new
     Flyology.DB.Commit_Authority_Formats.Reference
       (Maximum_Batch_Length =>
          Flyology.DB.Batch_Formats.Max_Batch_Image_Length);

   function Proof_Length (Source : Instance.Reference_Batch) return Natural
   with Post => Proof_Length'Result = Instance.Reference_Batch'Length;

   function Proof_Element
     (Source : Instance.Reference_Batch; Index : Positive)
      return Flyology.DB.Byte
   is (Source (Index))
   with Pre => Index <= Proof_Length (Source);

   function Validate_Member is new
     Flyology.DB.Commit_Authority_Formats.Source_Batch_Member_Valid
       (Source_Type    => Instance.Reference_Batch,
        Source_Length  => Proof_Length,
        Source_Element => Proof_Element);

end Flyology.DB.Commit_Authority_Proof;
