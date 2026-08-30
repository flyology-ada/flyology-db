package body Flyology.DB.Commit_Authority_Proof
  with SPARK_Mode => On
is

   function Proof_Length (Source : Instance.Reference_Batch) return Natural is
      pragma Unreferenced (Source);
   begin
      return Instance.Reference_Batch'Length;
   end Proof_Length;

end Flyology.DB.Commit_Authority_Proof;
