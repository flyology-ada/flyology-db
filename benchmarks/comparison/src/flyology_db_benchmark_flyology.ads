with GNAT.SHA256;

package Flyology_DB_Benchmark_Flyology is

   function Last_Run_Configuration_NDJSON
     (Participant : String; Execution_Ordinal : Natural; Transactions : Positive) return String;

   function Last_Run_Diagnostics_NDJSON
     (Execution_Ordinal : Natural; Transactions : Positive) return String;

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

   procedure Run_S3
     (Endpoint            : String;
      Bucket              : String;
      Prefix              : String;
      Warmup              : Natural;
      Measured            : Positive;
      Key_Length          : Positive;
      Value_Length        : Positive;
      Mutations           : Positive;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest);

end Flyology_DB_Benchmark_Flyology;
