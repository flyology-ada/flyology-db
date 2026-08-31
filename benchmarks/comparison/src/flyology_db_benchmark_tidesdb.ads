with GNAT.SHA256;

package Flyology_DB_Benchmark_TidesDB is

   procedure Run_Local
     (Root                : String;
      Warmup              : Natural;
      Measured            : Positive;
      Key_Length          : Positive;
      Value_Length        : Positive;
      Mutations           : Positive;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest);

end Flyology_DB_Benchmark_TidesDB;
