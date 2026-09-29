with Ada.Environment_Variables;
with Ada.Strings;
with Ada.Strings.Fixed;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

package body Flyology_DB_Benchmark_SlateDB is
   package C renames Interfaces.C;
   package C_Strings renames Interfaces.C.Strings;

   use type C.int;
   use type C.size_t;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;

   type Digest_Array is array (C.size_t range 0 .. 31) of Interfaces.Unsigned_8
     with Convention => C;

   type Benchmark_Report is record
      Elapsed_Nanoseconds : Interfaces.Unsigned_64;
      Verified_Keys       : Interfaces.Unsigned_64;
      State_SHA256        : Digest_Array;
   end record
     with Convention => C;

   type Preparation_Diagnostic_Report is record
      Transactions               : Interfaces.Unsigned_64;
      Mutations                  : Interfaces.Unsigned_64;
      Total_Nanoseconds          : Interfaces.Unsigned_64;
      Fixture_Generation_Nanoseconds : Interfaces.Unsigned_64;
      Begin_Nanoseconds          : Interfaces.Unsigned_64;
      Mutation_Put_Nanoseconds   : Interfaces.Unsigned_64;
   end record
     with Convention => C;

   Latest_Preparation : Preparation_Diagnostic_Report;
   Latest_Preparation_Available : Boolean := False;

   function Run_Local_C
     (Root                : C_Strings.chars_ptr;
      Database_Path       : C_Strings.chars_ptr;
      Warmup              : Interfaces.Unsigned_64;
      Measured            : Interfaces.Unsigned_64;
      Key_Bytes           : Interfaces.Unsigned_64;
      Value_Bytes         : Interfaces.Unsigned_64;
      Mutations           : Interfaces.Unsigned_64;
      Flush_Interval_Ms   : Interfaces.Unsigned_64;
      Use_Default_Flush   : Interfaces.Unsigned_8;
      Report              : access Benchmark_Report;
      Error               : System.Address;
      Error_Capacity      : C.size_t) return C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_slatedb_benchmark_local";

   function Run_Local_Diagnostics_C
     (Root                : C_Strings.chars_ptr;
      Database_Path       : C_Strings.chars_ptr;
      Warmup              : Interfaces.Unsigned_64;
      Measured            : Interfaces.Unsigned_64;
      Key_Bytes           : Interfaces.Unsigned_64;
      Value_Bytes         : Interfaces.Unsigned_64;
      Mutations           : Interfaces.Unsigned_64;
      Flush_Interval_Ms   : Interfaces.Unsigned_64;
      Use_Default_Flush   : Interfaces.Unsigned_8;
      Report              : access Benchmark_Report;
      Diagnostics         : access Preparation_Diagnostic_Report;
      Error               : System.Address;
      Error_Capacity      : C.size_t) return C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_slatedb_benchmark_local_diagnostics_v1";

   function Run_S3_C
     (Endpoint            : C_Strings.chars_ptr;
      Bucket              : C_Strings.chars_ptr;
      Access_Key          : C_Strings.chars_ptr;
      Secret_Key          : C_Strings.chars_ptr;
      Database_Path       : C_Strings.chars_ptr;
      Warmup              : Interfaces.Unsigned_64;
      Measured            : Interfaces.Unsigned_64;
      Key_Bytes           : Interfaces.Unsigned_64;
      Value_Bytes         : Interfaces.Unsigned_64;
      Mutations           : Interfaces.Unsigned_64;
      Flush_Interval_Ms   : Interfaces.Unsigned_64;
      Use_Default_Flush   : Interfaces.Unsigned_8;
      Report              : access Benchmark_Report;
      Error               : System.Address;
      Error_Capacity      : C.size_t) return C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_slatedb_benchmark_s3";

   Error_Capacity : constant := 1_024;
   Database_Path  : constant String := "database";

   function Collect_Preparation_Diagnostics return Boolean is
      Name : constant String := "FLYOLOGY_DB_SLATE_PREPARATION_DIAGNOSTICS";
   begin
      if not Ada.Environment_Variables.Exists (Name) then
         return False;
      elsif Ada.Environment_Variables.Value (Name) = "1" then
         return True;
      elsif Ada.Environment_Variables.Value (Name) = "0" then
         return False;
      end if;
      raise Program_Error with Name & " must be 0 or 1";
   end Collect_Preparation_Diagnostics;

   function Image (Value : Interfaces.Unsigned_64) return String is
     (Ada.Strings.Fixed.Trim (Interfaces.Unsigned_64'Image (Value), Ada.Strings.Both));

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Last_Run_Preparation_Diagnostics_NDJSON
     (Execution_Ordinal : Natural; Transactions : Positive) return String is
   begin
      if not Latest_Preparation_Available then
         return "";
      end if;
      return
        "{""schema"":""flyology.db.benchmark.preparation_diagnostics.v1"""
        & ",""kind"":""slatedb_preparation_diagnostics"""
        & ",""semantics"":""elapsed_wall_spans_nonexclusive_with_primary_window"""
        & ",""mutation_put_boundary"":""includes_owned_buffer_teardown_in_call"""
        & ",""execution_ordinal"":" & Image (Execution_Ordinal)
        & ",""transactions"":" & Image (Transactions)
        & ",""measured_transactions"":" & Image (Latest_Preparation.Transactions)
        & ",""measured_mutations"":" & Image (Latest_Preparation.Mutations)
        & ",""caller_preparation_ns"":" & Image (Latest_Preparation.Total_Nanoseconds)
        & ",""caller_fixture_generation_ns"":"
        & Image (Latest_Preparation.Fixture_Generation_Nanoseconds)
        & ",""caller_begin_ns"":" & Image (Latest_Preparation.Begin_Nanoseconds)
        & ",""caller_mutation_put_ns"":" & Image (Latest_Preparation.Mutation_Put_Nanoseconds)
        & "}";
   end Last_Run_Preparation_Diagnostics_NDJSON;

   function Required_Environment (Name : String) return String is
   begin
      if not Ada.Environment_Variables.Exists (Name)
        or else Ada.Environment_Variables.Value (Name)'Length = 0
      then
         raise Program_Error
           with "required environment variable is absent: " & Name;
      end if;
      return Ada.Environment_Variables.Value (Name);
   end Required_Environment;

   function Hex_Digit (Value : Interfaces.Unsigned_8) return Character is
     (if Value < 10
      then Character'Val (Character'Pos ('0') + Integer (Value))
      else Character'Val (Character'Pos ('a') + Integer (Value - 10)));

   function Digest_Image
     (Value : Digest_Array) return GNAT.SHA256.Message_Digest
   is
      Result : GNAT.SHA256.Message_Digest;
      Cursor : Positive := Result'First;
   begin
      for Byte of Value loop
         Result (Cursor) := Hex_Digit (Byte / 16);
         Result (Cursor + 1) := Hex_Digit (Byte mod 16);
         Cursor := Cursor + 2;
      end loop;
      return Result;
   end Digest_Image;

   procedure Require_Success
     (Code   : C.int;
      Error  : C.char_array;
      Report : Benchmark_Report;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest) is
   begin
      if Code /= 0 then
         raise Program_Error
           with "SlateDB benchmark failed: " & C.To_Ada (Error);
      end if;
      if Report.Elapsed_Nanoseconds = 0
        or else Report.Verified_Keys = 0
        or else Report.Verified_Keys
          > Interfaces.Unsigned_64 (Positive'Last)
      then
         raise Program_Error with "SlateDB benchmark report is invalid";
      end if;
      Elapsed_Nanoseconds := Long_Float (Report.Elapsed_Nanoseconds);
      Verified_Keys := Positive (Report.Verified_Keys);
      State_SHA256 := Digest_Image (Report.State_SHA256);
   end Require_Success;

   function Default_Flag (Flush : Flush_Profile) return Interfaces.Unsigned_8
   is
     (if Flush = Default_Flush then 1 else 0);

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
      State_SHA256        : out GNAT.SHA256.Message_Digest)
   is
      Root_Value     : C_Strings.chars_ptr := C_Strings.New_String (Root);
      Database_Value : C_Strings.chars_ptr :=
        C_Strings.New_String (Database_Path);
      Report         : aliased Benchmark_Report;
      Diagnostics    : aliased Preparation_Diagnostic_Report;
      Error          : aliased C.char_array (0 .. Error_Capacity - 1) :=
        [others => C.nul];
      Code           : C.int;
      Collect        : constant Boolean := Collect_Preparation_Diagnostics;
   begin
      Latest_Preparation_Available := False;
      if Collect then
         if Diagnostics'Size /= 48 * System.Storage_Unit
           or else Diagnostics'Alignment /= 8
           or else Diagnostics.Transactions'Position /= 0
           or else Diagnostics.Mutations'Position /= 8
           or else Diagnostics.Total_Nanoseconds'Position /= 16
           or else Diagnostics.Fixture_Generation_Nanoseconds'Position /= 24
           or else Diagnostics.Begin_Nanoseconds'Position /= 32
           or else Diagnostics.Mutation_Put_Nanoseconds'Position /= 40
         then
            raise Program_Error with "SlateDB diagnostic ABI layout mismatch";
         end if;
         Code :=
           Run_Local_Diagnostics_C
             (Root_Value,
              Database_Value,
              Interfaces.Unsigned_64 (Warmup),
              Interfaces.Unsigned_64 (Measured),
              Interfaces.Unsigned_64 (Key_Length),
              Interfaces.Unsigned_64 (Value_Length),
              Interfaces.Unsigned_64 (Mutations),
              1,
              Default_Flag (Flush),
              Report'Access,
              Diagnostics'Access,
              Error (Error'First)'Address,
              C.size_t (Error'Length));
      else
         Code :=
           Run_Local_C
             (Root_Value,
              Database_Value,
              Interfaces.Unsigned_64 (Warmup),
              Interfaces.Unsigned_64 (Measured),
              Interfaces.Unsigned_64 (Key_Length),
              Interfaces.Unsigned_64 (Value_Length),
              Interfaces.Unsigned_64 (Mutations),
              1,
              Default_Flag (Flush),
              Report'Access,
              Error (Error'First)'Address,
              C.size_t (Error'Length));
      end if;
      Require_Success
        (Code,
         Error,
         Report,
         Elapsed_Nanoseconds,
         Verified_Keys,
         State_SHA256);
      if Collect then
         if Diagnostics.Transactions /= Interfaces.Unsigned_64 (Measured)
           or else Diagnostics.Mutations /= Interfaces.Unsigned_64 (Measured * Mutations)
           or else Diagnostics.Total_Nanoseconds > Report.Elapsed_Nanoseconds
           or else Diagnostics.Fixture_Generation_Nanoseconds
                     > Diagnostics.Total_Nanoseconds
           or else Diagnostics.Begin_Nanoseconds
                     > Diagnostics.Total_Nanoseconds
                       - Diagnostics.Fixture_Generation_Nanoseconds
           or else Diagnostics.Mutation_Put_Nanoseconds
                     > Diagnostics.Total_Nanoseconds
                       - Diagnostics.Fixture_Generation_Nanoseconds
                       - Diagnostics.Begin_Nanoseconds
         then
            raise Program_Error with "SlateDB preparation diagnostics are inconsistent";
         end if;
         Latest_Preparation := Diagnostics;
         Latest_Preparation_Available := True;
      end if;
      C_Strings.Free (Root_Value);
      C_Strings.Free (Database_Value);
   exception
      when others =>
         C_Strings.Free (Root_Value);
         C_Strings.Free (Database_Value);
         raise;
   end Run_Local;

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
      State_SHA256        : out GNAT.SHA256.Message_Digest)
   is
      Endpoint_Value : C_Strings.chars_ptr :=
        C_Strings.New_String (Endpoint);
      Bucket_Value   : C_Strings.chars_ptr := C_Strings.New_String (Bucket);
      Access_Value   : C_Strings.chars_ptr :=
        C_Strings.New_String (Required_Environment ("AWS_ACCESS_KEY_ID"));
      Secret_Value   : C_Strings.chars_ptr :=
        C_Strings.New_String (Required_Environment ("AWS_SECRET_ACCESS_KEY"));
      Prefix_Value   : C_Strings.chars_ptr := C_Strings.New_String (Prefix);
      Report         : aliased Benchmark_Report;
      Error          : aliased C.char_array (0 .. Error_Capacity - 1) :=
        [others => C.nul];
      Code           : C.int;
   begin
      Latest_Preparation_Available := False;
      Code :=
        Run_S3_C
          (Endpoint_Value,
           Bucket_Value,
           Access_Value,
           Secret_Value,
           Prefix_Value,
           Interfaces.Unsigned_64 (Warmup),
           Interfaces.Unsigned_64 (Measured),
           Interfaces.Unsigned_64 (Key_Length),
           Interfaces.Unsigned_64 (Value_Length),
           Interfaces.Unsigned_64 (Mutations),
           1,
           Default_Flag (Flush),
           Report'Access,
           Error (Error'First)'Address,
           C.size_t (Error'Length));
      Require_Success
        (Code,
         Error,
         Report,
         Elapsed_Nanoseconds,
         Verified_Keys,
         State_SHA256);
      C_Strings.Free (Endpoint_Value);
      C_Strings.Free (Bucket_Value);
      C_Strings.Free (Access_Value);
      C_Strings.Free (Secret_Value);
      C_Strings.Free (Prefix_Value);
   exception
      when others =>
         C_Strings.Free (Endpoint_Value);
         C_Strings.Free (Bucket_Value);
         C_Strings.Free (Access_Value);
         C_Strings.Free (Secret_Value);
         C_Strings.Free (Prefix_Value);
         raise;
   end Run_S3;

end Flyology_DB_Benchmark_SlateDB;
