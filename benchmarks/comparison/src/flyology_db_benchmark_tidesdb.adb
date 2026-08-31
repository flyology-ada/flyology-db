with Ada.Directories;
with Ada.Real_Time;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;

package body Flyology_DB_Benchmark_TidesDB is
   package C renames Interfaces.C;
   package C_Strings renames Interfaces.C.Strings;
   package Byte_Pointers is new
     System.Address_To_Access_Conversions (Interfaces.Unsigned_8);

   use type Ada.Real_Time.Time;
   use type C.int;
   use type C.size_t;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type System.Storage_Elements.Storage_Offset;

   type Byte_Array is
     array (Positive range <>) of aliased Interfaces.Unsigned_8;

   Success              : constant C.int := 0;
   Snapshot_Isolation   : constant C.int := 3;
   Maximum_Operations   : constant := 63;
   Maximum_Key_Bytes    : constant := 256;
   Maximum_Value_Bytes  : constant := 64 * 1_024;
   Maximum_Mutations    : constant := 256;
   Expected_SHA         : constant String :=
     "23a67a6531bc6c0b537d3696758c7879586dcfce";
   Expected_Version     : constant String := "9.3.14";
   Family_Name          : constant String := "data";

   function Expected_Source_SHA return C_Strings.chars_ptr
     with Import,
          Convention    => C,
          External_Name => "flyology_tidesdb_expected_sha";

   function Header_Version return C_Strings.chars_ptr
     with Import,
          Convention    => C,
          External_Name => "flyology_tidesdb_header_version";

   function Open_Database_C
     (Path : C_Strings.chars_ptr; Database : access System.Address)
      return C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_tidesdb_open";

   function Create_Column_Family
     (Database : System.Address; Name : C_Strings.chars_ptr) return C.int
     with Import,
          Convention    => C,
          External_Name => "flyology_tidesdb_create_column_family";

   function Close_Database (Database : System.Address) return C.int
     with Import,
          Convention    => C,
          External_Name => "tidesdb_close";

   function Get_Column_Family
     (Database : System.Address; Name : C_Strings.chars_ptr)
      return System.Address
     with Import,
          Convention    => C,
          External_Name => "tidesdb_get_column_family";

   function Begin_Transaction
     (Database  : System.Address;
      Isolation : C.int;
      Transaction : access System.Address) return C.int
     with Import,
          Convention    => C,
          External_Name => "tidesdb_txn_begin_with_isolation";

   function Put
     (Transaction : System.Address;
      Family      : System.Address;
      Key         : System.Address;
      Key_Size    : C.size_t;
      Value       : System.Address;
      Value_Size  : C.size_t;
      TTL         : C.long) return C.int
     with Import,
          Convention    => C,
          External_Name => "tidesdb_txn_put";

   function Get
     (Transaction : System.Address;
      Family      : System.Address;
      Key         : System.Address;
      Key_Size    : C.size_t;
      Value       : access System.Address;
      Value_Size  : access C.size_t) return C.int
     with Import,
          Convention    => C,
          External_Name => "tidesdb_txn_get";

   function Commit (Transaction : System.Address) return C.int
     with Import,
          Convention    => C,
          External_Name => "tidesdb_txn_commit";

   function Rollback (Transaction : System.Address) return C.int
     with Import,
          Convention    => C,
          External_Name => "tidesdb_txn_rollback";

   procedure Free_Transaction (Transaction : System.Address)
     with Import,
          Convention    => C,
          External_Name => "tidesdb_txn_free";

   procedure Free (Value : System.Address)
     with Import,
          Convention    => C,
          External_Name => "tidesdb_free";

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Require_Success (Code : C.int; Context : String) is
   begin
      if Code /= Success then
         raise Program_Error
           with Context & " failed with TidesDB code" & C.int'Image (Code);
      end if;
   end Require_Success;

   function Key_For (Index : Positive; Length : Positive) return Byte_Array is
      Result    : Byte_Array (1 .. Length) := [others => 0];
      Remaining : Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Index);
   begin
      for Position in reverse Result'Last - 7 .. Result'Last loop
         Result (Position) := Interfaces.Unsigned_8 (Remaining mod 256);
         Remaining := Remaining / 256;
      end loop;
      return Result;
   end Key_For;

   function Value_For
     (Index : Positive; Length : Positive) return Byte_Array
   is
      Result : Byte_Array (1 .. Length);
   begin
      for Position in Result'Range loop
         Result (Position) :=
           Interfaces.Unsigned_8 ((Index + Position * 31) mod 256);
      end loop;
      return Result;
   end Value_For;

   procedure Update
     (Digest : in out GNAT.SHA256.Context; Data : Byte_Array)
   is
      Value : String (1 .. Data'Length);
   begin
      for Index in Data'Range loop
         Value (Index - Data'First + 1) := Character'Val (Data (Index));
      end loop;
      GNAT.SHA256.Update (Digest, Value);
   end Update;

   procedure Check_Pinned_Library is
   begin
      Require
        (C_Strings.Value (Expected_Source_SHA) = Expected_SHA,
         "TidesDB source identity differs from the benchmark pin");
      Require
        (C_Strings.Value (Header_Version) = Expected_Version,
         "TidesDB header version differs from the benchmark pin");
   end Check_Pinned_Library;

   procedure Open_Database
     (Root     : String;
      Create   : Boolean;
      Database : out System.Address;
      Family   : out System.Address)
   is
      Root_Name : C_Strings.chars_ptr := C_Strings.New_String (Root);
      Name      : C_Strings.chars_ptr :=
        C_Strings.New_String (Family_Name);
      Handle    : aliased System.Address := System.Null_Address;
   begin
      if Create then
         Ada.Directories.Create_Directory (Root);
      end if;
      Require_Success
        (Open_Database_C (Root_Name, Handle'Access), "open database");
      Database := Handle;
      Family := Get_Column_Family (Database, Name);
      if Family = System.Null_Address and then Create then
         Require_Success
           (Create_Column_Family (Database, Name), "create column family");
         Family := Get_Column_Family (Database, Name);
      end if;
      Require
        (Family /= System.Null_Address, "TidesDB data family is absent");
      C_Strings.Free (Root_Name);
      C_Strings.Free (Name);
   exception
      when others =>
         C_Strings.Free (Root_Name);
         C_Strings.Free (Name);
         if Handle /= System.Null_Address then
            declare
               Ignored : constant C.int := Close_Database (Handle);
            begin
               null;
            end;
         end if;
         raise;
   end Open_Database;

   --  website-benchmark:start tidesdb-durable-transaction
   procedure Put_Transaction
     (Database     : System.Address;
      Family       : System.Address;
      Index        : Positive;
      Key_Length   : Positive;
      Value_Length : Positive;
      Mutations    : Positive)
   is
      Transaction : aliased System.Address := System.Null_Address;
   begin
      Require_Success
        (Begin_Transaction
           (Database, Snapshot_Isolation, Transaction'Access),
         "begin transaction");
      for Mutation in 1 .. Mutations loop
         declare
            Key_Index : constant Positive :=
              (Index - 1) * Mutations + Mutation;
            Key       : aliased Byte_Array :=
              Key_For (Key_Index, Key_Length);
            Value     : aliased Byte_Array :=
              Value_For (Key_Index, Value_Length);
         begin
            Require_Success
              (Put
                 (Transaction,
                  Family,
                  Key (Key'First)'Address,
                  C.size_t (Key'Length),
                  Value (Value'First)'Address,
                  C.size_t (Value'Length),
                  0),
               "put");
         end;
      end loop;
      Require_Success (Commit (Transaction), "durable commit");
      Free_Transaction (Transaction);
   exception
      when others =>
         if Transaction /= System.Null_Address then
            declare
               Ignored : constant C.int := Rollback (Transaction);
            begin
               Free_Transaction (Transaction);
            end;
         end if;
         raise;
   end Put_Transaction;
   --  website-benchmark:end tidesdb-durable-transaction

   procedure Verify_One
     (Database     : System.Address;
      Family       : System.Address;
      Index        : Positive;
      Key_Length   : Positive;
      Value_Length : Positive;
      Digest       : in out GNAT.SHA256.Context)
   is
      Transaction : aliased System.Address := System.Null_Address;
      Value       : aliased System.Address := System.Null_Address;
      Value_Size  : aliased C.size_t := 0;
      Key         : aliased Byte_Array := Key_For (Index, Key_Length);
      Expected    : constant Byte_Array := Value_For (Index, Value_Length);
   begin
      Require_Success
        (Begin_Transaction
           (Database, Snapshot_Isolation, Transaction'Access),
         "verification begin");
      Require_Success
        (Get
           (Transaction,
            Family,
            Key (Key'First)'Address,
            C.size_t (Key'Length),
            Value'Access,
            Value_Size'Access),
         "verification get");
      Require
        (Value_Size = C.size_t (Expected'Length),
         "TidesDB value length differs after reopen");
      for Offset in 0 .. Expected'Length - 1 loop
         declare
            Address : constant System.Address :=
              Value + System.Storage_Elements.Storage_Offset (Offset);
         begin
            Require
              (Byte_Pointers.To_Pointer (Address).all
               = Expected (Expected'First + Offset),
               "TidesDB value differs after reopen");
         end;
      end loop;
      Update (Digest, Key);
      Update (Digest, Expected);
      Require_Success (Rollback (Transaction), "verification rollback");
      Free (Value);
      Free_Transaction (Transaction);
   exception
      when others =>
         if Value /= System.Null_Address then
            Free (Value);
         end if;
         if Transaction /= System.Null_Address then
            declare
               Ignored : constant C.int := Rollback (Transaction);
            begin
               Free_Transaction (Transaction);
            end;
         end if;
         raise;
   end Verify_One;

   procedure Run_Local
     (Root                : String;
      Warmup              : Natural;
      Measured            : Positive;
      Key_Length          : Positive;
      Value_Length        : Positive;
      Mutations           : Positive;
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest)
   is
      Total_Transactions : constant Positive := Warmup + Measured;
      Total_Keys         : constant Positive :=
        Total_Transactions * Mutations;
      Database           : System.Address := System.Null_Address;
      Family             : System.Address := System.Null_Address;
      Started            : Ada.Real_Time.Time;
      Finished           : Ada.Real_Time.Time;
      Digest             : GNAT.SHA256.Context :=
        GNAT.SHA256.Initial_Context;
   begin
      Require
        (Total_Transactions <= Maximum_Operations,
         "operation count exceeds TidesDB benchmark fixture limit");
      Require
        (Key_Length in 8 .. Maximum_Key_Bytes,
         "key length is outside the TidesDB benchmark fixture limit");
      Require
        (Value_Length <= Maximum_Value_Bytes,
         "value length exceeds the TidesDB benchmark fixture limit");
      Require
        (Mutations <= Maximum_Mutations,
         "mutation count exceeds the TidesDB benchmark fixture limit");
      Check_Pinned_Library;
      Open_Database (Root, True, Database, Family);
      for Index in 1 .. Warmup loop
         Put_Transaction
           (Database,
            Family,
            Index,
            Key_Length,
            Value_Length,
            Mutations);
      end loop;
      Started := Ada.Real_Time.Clock;
      for Index in Warmup + 1 .. Total_Transactions loop
         Put_Transaction
           (Database,
            Family,
            Index,
            Key_Length,
            Value_Length,
            Mutations);
      end loop;
      Finished := Ada.Real_Time.Clock;
      Require_Success (Close_Database (Database), "close database");
      Database := System.Null_Address;
      Open_Database (Root, False, Database, Family);
      for Index in 1 .. Total_Keys loop
         Verify_One
           (Database, Family, Index, Key_Length, Value_Length, Digest);
      end loop;
      Require_Success
        (Close_Database (Database), "close reopened database");
      Database := System.Null_Address;

      Elapsed_Nanoseconds :=
        Long_Float
          (Ada.Real_Time.To_Duration (Finished - Started)
           * 1_000_000_000.0);
      Require
        (Elapsed_Nanoseconds > 0.0,
         "timer resolution was insufficient");
      Verified_Keys := Total_Keys;
      State_SHA256 := GNAT.SHA256.Digest (Digest);
   exception
      when others =>
         if Database /= System.Null_Address then
            declare
               Ignored : constant C.int := Close_Database (Database);
            begin
               null;
            end;
         end if;
         raise;
   end Run_Local;

end Flyology_DB_Benchmark_TidesDB;
