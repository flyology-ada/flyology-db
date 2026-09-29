--  Exercises the frozen version-1 commit-batch codec and publication predicates.

private package Flyology.DB.Batch_Format_Tests is

   --  Independent frozen v1 image shared with the operational-runtime parity gate.
   function Frozen_Golden return Byte_Array;

   procedure Run;

end Flyology.DB.Batch_Format_Tests;
