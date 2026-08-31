with GNAT.SHA256;

package Flyology_DB_Benchmark_SlateDB is

   type Flush_Profile is (Default_Flush, One_Millisecond_Flush);

   procedure Run_Local
     (Root                : String;
      Warmup              : Natural;
      Measured            : Positive;
      Key_Length          : Positive;
      Value_Length        : Positive;
      Mutations           : Positive;
      Flush               : Flush_Profile;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest);

   procedure Run_S3
     (Endpoint            : String;
      Bucket              : String;
      Prefix              : String;
      Warmup              : Natural;
      Measured            : Positive;
      Key_Length          : Positive;
      Value_Length        : Positive;
      Mutations           : Positive;
      Flush               : Flush_Profile;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest);

end Flyology_DB_Benchmark_SlateDB;
