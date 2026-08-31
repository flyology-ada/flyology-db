with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology_Bench;
with Flyology_Bench.Manual_Timing_Comparison;
with Flyology_Bench.Reporters;
with Flyology_DB_Benchmark_Flyology;
with Flyology_DB_Benchmark_SlateDB;
with Flyology_DB_Benchmark_TidesDB;
with GNAT.OS_Lib;
with GNAT.SHA256;

procedure Flyology_DB_Benchmark_Panel is
   use type Flyology_Bench.Metric_Availability;
   use type Ada.Streams.Stream_Element_Offset;

   package Fixed renames Ada.Strings.Fixed;
   package OS renames GNAT.OS_Lib;
   package Reporters renames Flyology_Bench.Reporters;

   Minimum_Arguments : constant := 8;
   Maximum_Transactions : constant := 63;
   Maximum_Key_Bytes : constant := 256;
   Maximum_Value_Bytes : constant := 64 * 1_024;
   Maximum_Mutations : constant := 256;

   Reference_Name : constant String := Ada.Command_Line.Argument (1);
   Contender_Name : constant String := Ada.Command_Line.Argument (2);
   Key_Bytes : constant Positive := Positive'Value (Ada.Command_Line.Argument (3));
   Value_Bytes : constant Positive := Positive'Value (Ada.Command_Line.Argument (4));
   Mutations : constant Positive := Positive'Value (Ada.Command_Line.Argument (5));
   Transactions_Per_Operation : constant Positive :=
     Positive'Value (Ada.Command_Line.Argument (6));
   JSON_Path : constant String := Ada.Command_Line.Argument (7);
   Metrics_Path : constant String := Ada.Command_Line.Argument (8);

   Sequence : Natural := 0;

   function Image (Value : Integer) return String is
     (Fixed.Trim (Integer'Image (Value), Ada.Strings.Both));

   function Key_For (Index : Positive) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Key_Bytes)) :=
        [others => 0];
      Remaining : Long_Long_Integer := Long_Long_Integer (Index);
   begin
      for Position in
        reverse Result'Last - Ada.Streams.Stream_Element_Offset (7) .. Result'Last
      loop
         Result (Position) := Ada.Streams.Stream_Element (Remaining mod 256);
         Remaining := Remaining / 256;
      end loop;
      return Result;
   end Key_For;

   function Value_For (Index : Positive) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value_Bytes));
   begin
      for Position in Result'Range loop
         Result (Position) :=
           Ada.Streams.Stream_Element
             ((Index + Integer (Position) * 31) mod 256);
      end loop;
      return Result;
   end Value_For;

   function Expected_SHA
     (Transactions : Positive) return GNAT.SHA256.Message_Digest
   is
      Context : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
   begin
      for Index in 1 .. Transactions * Mutations loop
         GNAT.SHA256.Update (Context, Key_For (Index));
         GNAT.SHA256.Update (Context, Value_For (Index));
      end loop;
      return GNAT.SHA256.Digest (Context);
   end Expected_SHA;

   function Scratch_Path return String is
      Root : constant String :=
        (if Ada.Environment_Variables.Exists ("FLYOLOGY_DB_BENCH_SCRATCH_ROOT")
         then Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_SCRATCH_ROOT")
         else "/tmp");
   begin
      Sequence := Sequence + 1;
      return
        Root
        & "/flyology-db-bench."
        & Image (OS.Pid_To_Integer (OS.Current_Process_Id))
        & "."
        & Image (Sequence);
   end Scratch_Path;

   procedure Run_Participant
     (Name : String;
      Iterations : Flyology_Bench.Iteration_Count;
      Elapsed : out Long_Float;
      Status : out Flyology_Bench.Metric_Availability)
   is
      Scratch : constant String := Scratch_Path;
      Root : constant String := Scratch & "/database";
      Transactions : constant Positive :=
        Positive (Iterations) * Transactions_Per_Operation;
      Verified_Keys : Positive;
      State_SHA256 : GNAT.SHA256.Message_Digest;
      Flush : Flyology_DB_Benchmark_SlateDB.Flush_Profile;
   begin
      Ada.Directories.Create_Directory (Scratch);
      if Name = "flyology-db-files" then
         Flyology_DB_Benchmark_Flyology.Run_Local
           (Root,
            1,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      elsif Name = "slatedb-default" or else Name = "slatedb-1ms" then
         Flush :=
           (if Name = "slatedb-default"
            then Flyology_DB_Benchmark_SlateDB.Default_Flush
            else Flyology_DB_Benchmark_SlateDB.One_Millisecond_Flush);
         Flyology_DB_Benchmark_SlateDB.Run_Local
           (Root,
            1,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Flush,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      elsif Name = "tidesdb-full-sync" then
         Flyology_DB_Benchmark_TidesDB.Run_Local
           (Root,
            1,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      elsif Name = "flyology-db-rustfs" then
         Flyology_DB_Benchmark_Flyology.Run_S3
           (Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_ENDPOINT"),
            Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_BUCKET"),
            Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_NAMESPACE")
            & "/"
            & Image (Sequence),
            1,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      elsif Name = "slatedb-rustfs-default" or else Name = "slatedb-rustfs-1ms" then
         Flush :=
           (if Name = "slatedb-rustfs-default"
            then Flyology_DB_Benchmark_SlateDB.Default_Flush
            else Flyology_DB_Benchmark_SlateDB.One_Millisecond_Flush);
         Flyology_DB_Benchmark_SlateDB.Run_S3
           (Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_ENDPOINT"),
            Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_BUCKET"),
            Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_NAMESPACE")
            & "/"
            & Image (Sequence),
            1,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Flush,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      else
         raise Program_Error with "unknown benchmark participant " & Name;
      end if;
      if Elapsed <= 0.0
        or else Verified_Keys /= (Transactions + 1) * Mutations
        or else State_SHA256 /= Expected_SHA (Transactions + 1)
      then
         raise Program_Error
           with "benchmark participant returned invalid evidence: " & Name;
      end if;
      Ada.Directories.Delete_Tree (Scratch);
      Status := Flyology_Bench.Metric_Collected;
   exception
      when others =>
         Status := Flyology_Bench.Probe_Failed;
         raise;
   end Run_Participant;

   procedure Reference_Batch
     (Iterations : Flyology_Bench.Iteration_Count;
      Elapsed : out Long_Float;
      Status : out Flyology_Bench.Metric_Availability) is
   begin
      Run_Participant (Reference_Name, Iterations, Elapsed, Status);
   end Reference_Batch;

   procedure Contender_Batch
     (Iterations : Flyology_Bench.Iteration_Count;
      Elapsed : out Long_Float;
      Status : out Flyology_Bench.Metric_Availability) is
   begin
      Run_Participant (Contender_Name, Iterations, Elapsed, Status);
   end Contender_Batch;

   package Compare is new
     Flyology_Bench.Manual_Timing_Comparison
       (Source_Name     => "engine_adapter_monotonic_clock",
        Unit            => "ns/op",
        Resolution      => 1.0,
        Scope           => Flyology_Bench.Caller_Defined_Window,
        Attribution     => Flyology_Bench.Shared_Process_Window,
        Reference_Batch => Reference_Batch,
        Contender_Batch => Contender_Batch);

   Config : Flyology_Bench.Configuration := Flyology_Bench.Default_Configuration;
   Result : Flyology_Bench.Comparison;
   Ignored_JSON_File : Ada.Text_IO.File_Type;
   Ignored_Metrics_File : Ada.Text_IO.File_Type;
begin
   if Ada.Command_Line.Argument_Count /= Minimum_Arguments
     or else Key_Bytes < 8
     or else Key_Bytes > Maximum_Key_Bytes
     or else Value_Bytes > Maximum_Value_Bytes
     or else Mutations > Maximum_Mutations
     or else Transactions_Per_Operation >= Maximum_Transactions
   then
      raise Program_Error with
        "usage: panel REFERENCE CONTENDER KEY_BYTES VALUE_BYTES MUTATIONS"
        & " TRANSACTIONS_PER_OPERATION JSON NDJSON";
   end if;

   Config.Warmup_Time := 0.0;
   Config.Measurement_Time := 0.250;
   Config.Maximum_Sampling_Time := 180.0;
   Config.Samples := 10;
   Config.Minimum_Sample_Time := 0.001;
   Config.Maximum_Iterations :=
     Flyology_Bench.Positive_Iteration_Count
       (Integer'Min (4, (Maximum_Transactions - 1) / Transactions_Per_Operation));
   Config.Comparison_Batching := Flyology_Bench.Shared_Iterations;
   Config.Bootstrap_Resamples := 2_000;
   Config.Random_Seed := 20_260_830;
   Config.CPU_Quiescence :=
     (Enabled                     => True,
      Maximum_Average_CPU_Percent => 25.0,
      Maximum_Core_CPU_Percent    => 60.0,
      Stable_Time                 => 2.0,
      Poll_Interval               => 0.100,
      Timeout                     => 300.0);
   Config.Host_Lock :=
     (Enabled               => True,
      Path                  => <>,
      Timeout               => 60.0,
      Poll_Interval         => 0.250,
      Require_Machine_Scope => True);
   Config.Collect_Process_Telemetry := True;

   Compare.Compare (Config, Result);
   Ada.Text_IO.Create (Ignored_JSON_File, Ada.Text_IO.Out_File, JSON_Path);
   Reporters.Put_Comparison_JSON
     (Reference_Name, Contender_Name, Result, Ignored_JSON_File);
   Ada.Text_IO.Close (Ignored_JSON_File);
   Ada.Text_IO.Create (Ignored_Metrics_File, Ada.Text_IO.Out_File, Metrics_Path);
   Reporters.Put_Comparison_Metrics_NDJSON
     (Reference_Name, Contender_Name, Result, Ignored_Metrics_File);
   Ada.Text_IO.Close (Ignored_Metrics_File);
end Flyology_DB_Benchmark_Panel;
