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
with Interfaces;

procedure Flyology_DB_Benchmark_Panel is
   use type Flyology_Bench.Metric_Availability;
   use type Flyology_Bench.Iteration_Count;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;

   package Fixed renames Ada.Strings.Fixed;
   package OS renames GNAT.OS_Lib;
   package Reporters renames Flyology_Bench.Reporters;

   Minimum_Arguments : constant := 8;
   Maximum_Transactions : constant := 63;
   Maximum_Key_Bytes : constant := 256;
   Maximum_Value_Bytes : constant := 64 * 1_024;
   Maximum_Mutations : constant := 256;

   Flyology_Singleton_Prefix : constant String := "flyology-db-files-singleton-depth";
   Flyology_Group_Prefix : constant String := "flyology-db-files-explicit-group";
   Flyology_Cohort_Prefix : constant String := "flyology-db-files-independent-cohort-width";
   Flyology_Aggregate_Prefix : constant String :=
     "flyology-db-files-aggregate-cohort-width";
   Flyology_Adaptive_Prefix : constant String :=
     "flyology-db-files-adaptive-cohort-members";
   SlateDB_Depth_Prefix : constant String := "slatedb-1ms-depth";
   Waves_Suffix : constant String := "-waves";

   Reference_Name : constant String := Ada.Command_Line.Argument (1);
   Contender_Name : constant String := Ada.Command_Line.Argument (2);
   Key_Bytes : constant Positive := Positive'Value (Ada.Command_Line.Argument (3));
   Value_Bytes : constant Positive := Positive'Value (Ada.Command_Line.Argument (4));
   Mutations : constant Positive := Positive'Value (Ada.Command_Line.Argument (5));
   Transactions_Per_Operation : constant Positive :=
     Positive'Value (Ada.Command_Line.Argument (6));
   JSON_Path : constant String := Ada.Command_Line.Argument (7);
   Metrics_Path : constant String := Ada.Command_Line.Argument (8);
   Warmup_Transactions : constant Natural :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_DB_BENCH_WARMUP")
      then Natural'Value (Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_WARMUP"))
      else 1);

   Sequence : Natural := 0;
   Execution_Ordinal : Natural := 0;
   Execution_Axis : Flyology_Bench.Custom_Metric_Index := Flyology_Bench.Custom_Metric_Index'First;

   function Image (Value : Integer) return String is
     (Fixed.Trim (Integer'Image (Value), Ada.Strings.Both));

   function Has_Profile_Prefix (Name : String; Prefix : String) return Boolean is
     (Name'Length > Prefix'Length
      and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix);

   function Uses_Wave_Scheduling (Name : String) return Boolean is
     (Name'Length > Waves_Suffix'Length
      and then Name (Name'Last - Waves_Suffix'Length + 1 .. Name'Last) = Waves_Suffix);

   function Scheduling_Profile (Name : String) return String is
     (if Uses_Wave_Scheduling (Name)
      then Name (Name'First .. Name'Last - Waves_Suffix'Length)
      else Name);

   function Profile_Value (Text : String; Context : String) return Positive is
      Value : constant Positive := Positive'Value (Text);
   begin
      if Text /= Image (Value) or else Value > 8 then
         raise Program_Error with Context & " must be a canonical integer from 1 through 8";
      end if;
      return Value;
   exception
      when Constraint_Error =>
         raise Program_Error with Context & " must be a canonical integer from 1 through 8";
   end Profile_Value;

   function Profile_Unsigned_64 (Text : String; Context : String) return Interfaces.Unsigned_64 is
      Value : constant Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Value (Text);
   begin
      if Value = 0
        or else Text /= Fixed.Trim (Interfaces.Unsigned_64'Image (Value), Ada.Strings.Both)
      then
         raise Program_Error with Context & " must be a canonical positive integer";
      end if;
      return Value;
   exception
      when Constraint_Error =>
         raise Program_Error with Context & " must be a canonical positive integer";
   end Profile_Unsigned_64;

   procedure Configure_Flyology_Profile (Name : String; Wave_Scheduling : Boolean := False) is
   begin
      --  Every named panel profile defines the complete scheduling shape so
      --  an ambient experimental setting cannot silently relabel a result.
      Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_INDEPENDENT_COHORT_WIDTH", "0");
      Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_AGGREGATE_COHORT_WIDTH", "0");
      Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_AGGREGATE_FIRST_BATCH_ORDINAL", "0");
      Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_MEMBERS", "0");
      Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_ENCODED_BYTES", "0");
      Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_WAIT_US", "0");
      Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_ADAPTIVE_ADMISSION_DEPTH", "0");
      Ada.Environment_Variables.Set
        ("FLYOLOGY_DB_BENCH_PIPELINE_SCHEDULE",
         (if Wave_Scheduling then "waves" else "rolling"));
      if Name = "flyology-db-files" then
         Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_EXPLICIT_GROUP", "0");
         Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_GROUP_SIZE", "1");
         Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_PIPELINE_DEPTH", "1");
      elsif Has_Profile_Prefix (Name, Flyology_Singleton_Prefix) then
         declare
            Depth_Text : constant String :=
              Name (Name'First + Flyology_Singleton_Prefix'Length .. Name'Last);
            Depth : constant Positive := Profile_Value (Depth_Text, "Flyology singleton depth");
         begin
            Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_EXPLICIT_GROUP", "0");
            Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_GROUP_SIZE", "1");
            Ada.Environment_Variables.Set
              ("FLYOLOGY_DB_BENCH_PIPELINE_DEPTH", Image (Depth));
         end;
      elsif Has_Profile_Prefix (Name, Flyology_Group_Prefix) then
         declare
            Profile : constant String :=
              Name (Name'First + Flyology_Group_Prefix'Length .. Name'Last);
            Separator : constant Natural := Fixed.Index (Profile, "-depth");
         begin
            if Separator = 0
              or else Separator = Profile'First
              or else Separator + 6 > Profile'Last
            then
               raise Program_Error with "invalid Flyology explicit-group benchmark profile " & Name;
            end if;
            declare
               Group_Text : constant String := Profile (Profile'First .. Separator - 1);
               Depth_Text : constant String := Profile (Separator + 6 .. Profile'Last);
               Group_Size : constant Positive := Profile_Value (Group_Text, "Flyology group size");
               Depth : constant Positive := Profile_Value (Depth_Text, "Flyology group depth");
            begin
               Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_EXPLICIT_GROUP", "1");
               Ada.Environment_Variables.Set
                 ("FLYOLOGY_DB_BENCH_GROUP_SIZE", Image (Group_Size));
               Ada.Environment_Variables.Set
                 ("FLYOLOGY_DB_BENCH_PIPELINE_DEPTH", Image (Depth));
            end;
         end;
      elsif Has_Profile_Prefix (Name, Flyology_Cohort_Prefix) then
         declare
            Width_Text : constant String :=
              Name (Name'First + Flyology_Cohort_Prefix'Length .. Name'Last);
            Width : constant Positive := Profile_Value (Width_Text, "Flyology cohort width");
         begin
            Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_EXPLICIT_GROUP", "0");
            Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_GROUP_SIZE", "1");
            Ada.Environment_Variables.Set
              ("FLYOLOGY_DB_BENCH_PIPELINE_DEPTH", Image (Width));
            Ada.Environment_Variables.Set
              ("FLYOLOGY_DB_BENCH_INDEPENDENT_COHORT_WIDTH", Image (Width));
         end;
      elsif Has_Profile_Prefix (Name, Flyology_Adaptive_Prefix) then
         declare
            Profile : constant String :=
              Name (Name'First + Flyology_Adaptive_Prefix'Length .. Name'Last);
            Bytes_Marker : constant Natural := Fixed.Index (Profile, "-bytes");
            Wait_Marker : constant Natural := Fixed.Index (Profile, "-wait-us");
            Depth_Marker : constant Natural := Fixed.Index (Profile, "-depth");
         begin
            if Bytes_Marker = 0
              or else Bytes_Marker = Profile'First
              or else Wait_Marker <= Bytes_Marker + 6
              or else Depth_Marker <= Wait_Marker + 8
              or else Depth_Marker + 6 > Profile'Last
            then
               raise Program_Error with "invalid Flyology adaptive-cohort benchmark profile " & Name;
            end if;
            declare
               Members_Text : constant String := Profile (Profile'First .. Bytes_Marker - 1);
               Bytes_Text : constant String := Profile (Bytes_Marker + 6 .. Wait_Marker - 1);
               Wait_Text : constant String := Profile (Wait_Marker + 8 .. Depth_Marker - 1);
               Depth_Text : constant String := Profile (Depth_Marker + 6 .. Profile'Last);
               Members : constant Positive := Profile_Value (Members_Text, "Flyology adaptive members");
               Bytes : constant Interfaces.Unsigned_64 :=
                 Profile_Unsigned_64 (Bytes_Text, "Flyology adaptive byte target");
               Wait_Microseconds : constant Interfaces.Unsigned_64 :=
                 Profile_Unsigned_64 (Wait_Text, "Flyology adaptive wait");
               Depth : constant Positive := Profile_Value (Depth_Text, "Flyology adaptive depth");
            begin
               if Depth < Members then
                  raise Program_Error with
                    "Flyology adaptive depth must be at least its maximum member count";
               end if;
               Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_EXPLICIT_GROUP", "0");
               Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_GROUP_SIZE", "1");
               Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_PIPELINE_DEPTH", Image (Depth));
               Ada.Environment_Variables.Set
                 ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_MEMBERS", Image (Members));
               Ada.Environment_Variables.Set
                 ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_ENCODED_BYTES",
                  Fixed.Trim (Interfaces.Unsigned_64'Image (Bytes), Ada.Strings.Both));
               Ada.Environment_Variables.Set
                 ("FLYOLOGY_DB_BENCH_ADAPTIVE_MAXIMUM_WAIT_US",
                  Fixed.Trim (Interfaces.Unsigned_64'Image (Wait_Microseconds), Ada.Strings.Both));
               Ada.Environment_Variables.Set
                 ("FLYOLOGY_DB_BENCH_ADAPTIVE_ADMISSION_DEPTH", Image (Depth));
            end;
         end;
      else
         declare
            Profile : constant String :=
              Name (Name'First + Flyology_Aggregate_Prefix'Length .. Name'Last);
            Separator : constant Natural := Fixed.Index (Profile, "-depth");
         begin
            if Separator = 0
              or else Separator = Profile'First
              or else Separator + 6 > Profile'Last
            then
               raise Program_Error with
                 "invalid Flyology aggregate-cohort benchmark profile " & Name;
            end if;
            declare
               Width_Text : constant String := Profile (Profile'First .. Separator - 1);
               Depth_Text : constant String := Profile (Separator + 6 .. Profile'Last);
               Width : constant Positive := Profile_Value (Width_Text, "Flyology aggregate width");
               Depth : constant Positive := Profile_Value (Depth_Text, "Flyology aggregate depth");
            begin
               if Depth mod Width /= 0 then
                  raise Program_Error with "Flyology aggregate depth must be a multiple of its width";
               end if;
               Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_EXPLICIT_GROUP", "0");
               Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_GROUP_SIZE", "1");
               Ada.Environment_Variables.Set ("FLYOLOGY_DB_BENCH_PIPELINE_DEPTH", Image (Depth));
               Ada.Environment_Variables.Set
                 ("FLYOLOGY_DB_BENCH_AGGREGATE_COHORT_WIDTH", Image (Width));
               Ada.Environment_Variables.Set
                 ("FLYOLOGY_DB_BENCH_AGGREGATE_FIRST_BATCH_ORDINAL", "1");
            end;
         end;
      end if;
   end Configure_Flyology_Profile;

   procedure Execution_Probe (Snapshot : in out Flyology_Bench.Custom_Snapshot) is
   begin
      Snapshot (Execution_Axis) :=
        (Status        => Flyology_Bench.Metric_Collected,
         Counter_Value => 0,
         Sample_Value  => Long_Float (Execution_Ordinal));
   end Execution_Probe;

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
      Profile : constant String := Scheduling_Profile (Name);
      Wave_Scheduling : constant Boolean := Uses_Wave_Scheduling (Name);
      Root : constant String := Scratch & "/database";
      Transactions : constant Positive :=
        Positive (Iterations) * Transactions_Per_Operation;
      Verified_Keys : Positive;
      State_SHA256 : GNAT.SHA256.Message_Digest;
      Flush : Flyology_DB_Benchmark_SlateDB.Flush_Profile;
   begin
      Execution_Ordinal := Sequence;
      Ada.Directories.Create_Directory (Scratch);
      if Wave_Scheduling
        and then not
          (Has_Profile_Prefix (Profile, Flyology_Singleton_Prefix)
           or else Has_Profile_Prefix (Profile, Flyology_Aggregate_Prefix)
           or else Has_Profile_Prefix (Profile, Flyology_Adaptive_Prefix)
           or else Has_Profile_Prefix (Profile, SlateDB_Depth_Prefix))
      then
         raise Program_Error with "wave scheduling is not supported by benchmark participant " & Name;
      end if;
      if Profile = "flyology-db-files"
        or else Has_Profile_Prefix (Profile, Flyology_Singleton_Prefix)
        or else Has_Profile_Prefix (Profile, Flyology_Group_Prefix)
        or else Has_Profile_Prefix (Profile, Flyology_Cohort_Prefix)
        or else Has_Profile_Prefix (Profile, Flyology_Aggregate_Prefix)
        or else Has_Profile_Prefix (Profile, Flyology_Adaptive_Prefix)
      then
         Configure_Flyology_Profile (Profile, Wave_Scheduling);
         Flyology_DB_Benchmark_Flyology.Run_Local
           (Root,
            Warmup_Transactions,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      elsif Profile = "slatedb-default"
        or else Profile = "slatedb-1ms"
        or else Has_Profile_Prefix (Profile, SlateDB_Depth_Prefix)
      then
         Ada.Environment_Variables.Set
           ("FLYOLOGY_DB_SLATE_PIPELINE_DEPTH",
            (if Has_Profile_Prefix (Profile, SlateDB_Depth_Prefix)
             then Image
               (Profile_Value
                  (Profile
                     (Profile'First + SlateDB_Depth_Prefix'Length .. Profile'Last),
                   "SlateDB pipeline depth"))
             else "1"));
         Flush :=
           (if Profile = "slatedb-default"
            then Flyology_DB_Benchmark_SlateDB.Default_Flush
            else Flyology_DB_Benchmark_SlateDB.One_Millisecond_Flush);
         Flyology_DB_Benchmark_SlateDB.Run_Local
           (Root,
            Warmup_Transactions,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Flush,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      elsif Profile = "tidesdb-full-sync" then
         Flyology_DB_Benchmark_TidesDB.Run_Local
           (Root,
            Warmup_Transactions,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      elsif Profile = "flyology-db-rustfs" then
         Configure_Flyology_Profile ("flyology-db-files");
         Flyology_DB_Benchmark_Flyology.Run_S3
           (Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_ENDPOINT"),
            Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_BUCKET"),
            Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_NAMESPACE")
            & "/"
            & Image (Sequence),
            Warmup_Transactions,
            Transactions,
            Key_Bytes,
            Value_Bytes,
            Mutations,
            Elapsed,
            Verified_Keys,
            State_SHA256);
      elsif Profile = "slatedb-rustfs-default" or else Profile = "slatedb-rustfs-1ms" then
         Flush :=
           (if Profile = "slatedb-rustfs-default"
            then Flyology_DB_Benchmark_SlateDB.Default_Flush
            else Flyology_DB_Benchmark_SlateDB.One_Millisecond_Flush);
         Flyology_DB_Benchmark_SlateDB.Run_S3
           (Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_ENDPOINT"),
            Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_BUCKET"),
            Ada.Environment_Variables.Value ("FLYOLOGY_DB_BENCH_NAMESPACE")
            & "/"
            & Image (Sequence),
            Warmup_Transactions,
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
        or else Verified_Keys /= (Transactions + Warmup_Transactions) * Mutations
        or else State_SHA256 /= Expected_SHA (Transactions + Warmup_Transactions)
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

   procedure Put_Paired_Primary_Samples
     (Result : Flyology_Bench.Comparison;
      File   : Ada.Text_IO.File_Type)
   is
      Reference : constant Flyology_Bench.Measurement := Flyology_Bench.Reference_Measurement (Result);
      Contender : constant Flyology_Bench.Measurement := Flyology_Bench.Contender_Measurement (Result);
      Reference_Primary : constant Flyology_Bench.Custom_Metric_Count :=
        Flyology_Bench.Primary_Timing_Axis (Reference);
      Contender_Primary : constant Flyology_Bench.Custom_Metric_Count :=
        Flyology_Bench.Primary_Timing_Axis (Contender);
      Reference_Iterations : constant Flyology_Bench.Iteration_Count :=
        Flyology_Bench.Iterations_Per_Sample (Reference);
      Contender_Iterations : constant Flyology_Bench.Iteration_Count :=
        Flyology_Bench.Iterations_Per_Sample (Contender);
      Reference_First : Natural := 0;
      Contender_First : Natural := 0;
      Last_Ordinal : Natural := 0;

      function Number (Value : Long_Float) return String is
        (Fixed.Trim (Long_Float'Image (Value), Ada.Strings.Both));
   begin
      if Reference_Primary = 0
        or else Contender_Primary = 0
        or else Flyology_Bench.Samples (Reference) /= Flyology_Bench.Samples (Contender)
        or else Reference_Iterations = 0
        or else Contender_Iterations = 0
        or else Reference_Iterations /= Contender_Iterations
        or else Flyology_Bench.Custom_Metric_Name
          (Reference, Flyology_Bench.Custom_Metric_Index (Reference_Primary))
          /= "primary_time"
        or else Flyology_Bench.Custom_Metric_Name
          (Contender, Flyology_Bench.Custom_Metric_Index (Contender_Primary))
          /= "primary_time"
        or else Flyology_Bench.Custom_Metric_Unit
          (Reference, Flyology_Bench.Custom_Metric_Index (Reference_Primary))
          /= "ns/op"
        or else Flyology_Bench.Custom_Metric_Unit
          (Contender, Flyology_Bench.Custom_Metric_Index (Contender_Primary))
          /= "ns/op"
        or else Flyology_Bench.Custom_Metric_Timing_Source
          (Reference, Flyology_Bench.Custom_Metric_Index (Reference_Primary))
          /= "engine_adapter_monotonic_clock"
        or else Flyology_Bench.Custom_Metric_Timing_Source
          (Contender, Flyology_Bench.Custom_Metric_Index (Contender_Primary))
          /= "engine_adapter_monotonic_clock"
        or else Flyology_Bench.Custom_Metric_Name (Reference, Execution_Axis)
          /= "execution_ordinal"
        or else Flyology_Bench.Custom_Metric_Name (Contender, Execution_Axis)
          /= "execution_ordinal"
      then
         raise Program_Error with "paired primary benchmark evidence is incomplete";
      end if;
      for Index in 1 .. Flyology_Bench.Samples (Reference) loop
         declare
            Sample : constant Flyology_Bench.Sample_Index := Flyology_Bench.Sample_Index (Index);
            Reference_Time : constant Long_Float :=
              Flyology_Bench.Custom_Metric_Sample
                (Reference, Flyology_Bench.Custom_Metric_Index (Reference_Primary), Sample);
            Contender_Time : constant Long_Float :=
              Flyology_Bench.Custom_Metric_Sample
                (Contender, Flyology_Bench.Custom_Metric_Index (Contender_Primary), Sample);
            Reference_Order : constant Long_Float :=
              Flyology_Bench.Custom_Metric_Sample (Reference, Execution_Axis, Sample);
            Contender_Order : constant Long_Float :=
              Flyology_Bench.Custom_Metric_Sample (Contender, Execution_Axis, Sample);
         begin
            if Flyology_Bench.Custom_Metric_Sample_Status
                 (Reference, Flyology_Bench.Custom_Metric_Index (Reference_Primary), Sample)
                 /= Flyology_Bench.Metric_Collected
              or else Flyology_Bench.Custom_Metric_Sample_Status
                (Contender, Flyology_Bench.Custom_Metric_Index (Contender_Primary), Sample)
                /= Flyology_Bench.Metric_Collected
              or else Flyology_Bench.Custom_Metric_Sample_Status (Reference, Execution_Axis, Sample)
                /= Flyology_Bench.Metric_Collected
              or else Flyology_Bench.Custom_Metric_Sample_Status (Contender, Execution_Axis, Sample)
                /= Flyology_Bench.Metric_Collected
              or else Reference_Time /= Reference_Time
              or else Contender_Time /= Contender_Time
              or else Reference_Time <= 0.0
              or else Contender_Time <= 0.0
              or else Reference_Order <= 0.0
              or else Contender_Order <= 0.0
              or else abs (Reference_Order - Contender_Order) /= 1.0
              or else Reference_Order /= Long_Float (Natural (Reference_Order))
              or else Contender_Order /= Long_Float (Natural (Contender_Order))
              or else Natural'Min (Natural (Reference_Order), Natural (Contender_Order))
                <= Last_Ordinal
            then
               raise Program_Error with "paired primary benchmark sample is invalid";
            end if;
            Last_Ordinal := Natural'Max (Natural (Reference_Order), Natural (Contender_Order));
            if Reference_Order < Contender_Order then
               Reference_First := Reference_First + 1;
            else
               Contender_First := Contender_First + 1;
            end if;
            Ada.Text_IO.Put_Line
              (File,
               "{""schema"":""flyology.db.benchmark.paired_primary_sample.v1"""
               & ",""sample"":" & Image (Index)
               & ",""reference"":""" & Reference_Name & """"
               & ",""contender"":""" & Contender_Name & """"
               & ",""reference_primary_ns_per_operation"":" & Number (Reference_Time)
               & ",""contender_primary_ns_per_operation"":" & Number (Contender_Time)
               & ",""reference_execution_ordinal"":" & Number (Reference_Order)
               & ",""contender_execution_ordinal"":" & Number (Contender_Order)
               & ",""reference_iterations"":" & Image (Integer (Reference_Iterations))
               & ",""contender_iterations"":" & Image (Integer (Contender_Iterations))
               & ",""transactions_per_operation"":" & Image (Transactions_Per_Operation)
               & ",""first"":"""
               & (if Reference_Order < Contender_Order then "reference" else "contender")
               & """}");
         end;
      end loop;
      if Reference_First /= Flyology_Bench.Reference_First_Samples (Result)
        or else Contender_First /= Flyology_Bench.Contender_First_Samples (Result)
      then
         raise Program_Error with "paired primary benchmark order summary is inconsistent";
      end if;
   end Put_Paired_Primary_Samples;

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
     or else Warmup_Transactions >= Maximum_Transactions
     or else Transactions_Per_Operation > Maximum_Transactions - Warmup_Transactions
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
       (Integer'Min
          (4,
           (Maximum_Transactions - Warmup_Transactions)
           / Transactions_Per_Operation));
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

   Flyology_Bench.Register_Custom_Metric
     (Config.Custom_Metrics,
      Name          => "execution_ordinal",
      Unit          => "ordinal",
      Scope         => Flyology_Bench.Caller_Defined_Window,
      Attribution   => Flyology_Bench.Exact_Window,
      Direction     => Flyology_Bench.Diagnostic,
      Semantics     => Flyology_Bench.Absolute_Sample,
      Normalization => Flyology_Bench.Per_Batch,
      Comparison    => Flyology_Bench.Absolute);
   Execution_Axis :=
     Flyology_Bench.Custom_Metric_Index
       (Flyology_Bench.Custom_Metrics (Config.Custom_Metrics));
   Flyology_Bench.Set_Custom_Probe
     (Config.Custom_Metrics, Execution_Probe'Unrestricted_Access);

   Compare.Compare (Config, Result);
   Ada.Text_IO.Create (Ignored_JSON_File, Ada.Text_IO.Out_File, JSON_Path);
   Reporters.Put_Comparison_JSON
     (Reference_Name, Contender_Name, Result, Ignored_JSON_File);
   Ada.Text_IO.Close (Ignored_JSON_File);
   Ada.Text_IO.Create (Ignored_Metrics_File, Ada.Text_IO.Out_File, Metrics_Path);
   Reporters.Put_Comparison_Metrics_NDJSON
     (Reference_Name, Contender_Name, Result, Ignored_Metrics_File);
   Put_Paired_Primary_Samples (Result, Ignored_Metrics_File);
   Ada.Text_IO.Close (Ignored_Metrics_File);
end Flyology_DB_Benchmark_Panel;
