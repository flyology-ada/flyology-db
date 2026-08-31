with Ada.Command_Line;
with Ada.Text_IO;
with Flyology_DB_Benchmark_Flyology;
with GNAT.SHA256;

procedure Flyology_DB_Benchmark is
   package Participant renames Flyology_DB_Benchmark_Flyology;

   Default_Key_Length   : constant := 16;
   Default_Value_Length : constant := 1_024;
   Default_Mutations    : constant := 1;

   function Positive_Argument
     (Position : Positive; Name : String) return Positive
   is
      Value : Integer;
   begin
      Value := Integer'Value (Ada.Command_Line.Argument (Position));
      if Value <= 0 then
         raise Program_Error with Name & " must be positive";
      end if;
      return Positive (Value);
   exception
      when Constraint_Error =>
         raise Program_Error with Name & " must be a positive integer";
   end Positive_Argument;

   function Nonnegative_Argument
     (Position : Positive; Name : String) return Natural
   is
      Value : Integer;
   begin
      Value := Integer'Value (Ada.Command_Line.Argument (Position));
      if Value < 0 then
         raise Program_Error with Name & " must be nonnegative";
      end if;
      return Natural (Value);
   exception
      when Constraint_Error =>
         raise Program_Error with Name & " must be a nonnegative integer";
   end Nonnegative_Argument;

   procedure Put_Report
     (Elapsed_Nanoseconds : Long_Float;
      Verified_Keys       : Positive;
      State_SHA256        : GNAT.SHA256.Message_Digest) is
   begin
      Ada.Text_IO.Put_Line
        ("elapsed_nanoseconds=" & Long_Long_Integer'Image
           (Long_Long_Integer (Elapsed_Nanoseconds)));
      Ada.Text_IO.Put_Line
        ("verified_keys=" & Positive'Image (Verified_Keys));
      Ada.Text_IO.Put_Line ("state_sha256=" & State_SHA256);
   end Put_Report;

   Elapsed_Nanoseconds : Long_Float;
   Verified_Keys       : Positive;
   State_SHA256        : GNAT.SHA256.Message_Digest;
begin
   if Ada.Command_Line.Argument_Count in 4 | 7
     and then Ada.Command_Line.Argument (1) = "local"
   then
      Participant.Run_Local
        (Root                => Ada.Command_Line.Argument (2),
         Warmup              => Nonnegative_Argument (3, "warmup operations"),
         Measured            => Positive_Argument (4, "measured operations"),
         Key_Length          =>
           (if Ada.Command_Line.Argument_Count = 7
            then Positive_Argument (5, "key bytes")
            else Default_Key_Length),
         Value_Length        =>
           (if Ada.Command_Line.Argument_Count = 7
            then Positive_Argument (6, "value bytes")
            else Default_Value_Length),
         Mutations           =>
           (if Ada.Command_Line.Argument_Count = 7
            then Positive_Argument (7, "mutations per transaction")
            else Default_Mutations),
         Elapsed_Nanoseconds => Elapsed_Nanoseconds,
         Verified_Keys       => Verified_Keys,
         State_SHA256        => State_SHA256);
   elsif Ada.Command_Line.Argument_Count in 6 | 9
     and then Ada.Command_Line.Argument (1) = "s3"
   then
      Participant.Run_S3
        (Endpoint            => Ada.Command_Line.Argument (2),
         Bucket              => Ada.Command_Line.Argument (3),
         Prefix              => Ada.Command_Line.Argument (4),
         Warmup              => Nonnegative_Argument (5, "warmup operations"),
         Measured            => Positive_Argument (6, "measured operations"),
         Key_Length          =>
           (if Ada.Command_Line.Argument_Count = 9
            then Positive_Argument (7, "key bytes")
            else Default_Key_Length),
         Value_Length        =>
           (if Ada.Command_Line.Argument_Count = 9
            then Positive_Argument (8, "value bytes")
            else Default_Value_Length),
         Mutations           =>
           (if Ada.Command_Line.Argument_Count = 9
            then Positive_Argument (9, "mutations per transaction")
            else Default_Mutations),
         Elapsed_Nanoseconds => Elapsed_Nanoseconds,
         Verified_Keys       => Verified_Keys,
         State_SHA256        => State_SHA256);
   else
      raise Program_Error
        with
          "usage: flyology_db_benchmark local FRESH_ROOT WARMUP MEASURED"
          & " [KEY_BYTES VALUE_BYTES MUTATIONS]"
          & " or flyology_db_benchmark s3 ENDPOINT BUCKET FRESH_PREFIX"
          & " WARMUP MEASURED [KEY_BYTES VALUE_BYTES MUTATIONS]";
   end if;
   Put_Report (Elapsed_Nanoseconds, Verified_Keys, State_SHA256);
end Flyology_DB_Benchmark;
