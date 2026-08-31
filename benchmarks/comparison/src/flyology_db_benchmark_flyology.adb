with Ada.Environment_Variables;
with Ada.Real_Time;
with Flyology.Bytes;
with Flyology.DB;
with Flyology.DB.Object_Storage;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Files;
with Flyology.Object_Storage.Client.Low_Level;
with Interfaces;

package body Flyology_DB_Benchmark_Flyology is
   package DB renames Flyology.DB;
   package Binding renames Flyology.DB.Object_Storage;
   package Files renames Flyology.Object_Storage.Backends.Files;
   package HTTP renames Flyology.HTTP;
   package HTTP_Client renames Flyology.HTTP.Client;
   package Low_Level renames Flyology.Object_Storage.Client.Low_Level;
   package OS renames Flyology.Object_Storage;

   use type Ada.Real_Time.Time;
   use type DB.Byte;
   use type DB.Outcome_Code;
   use type OS.Status;
   use type Interfaces.Unsigned_64;

   Maximum_Operations          : constant := 63;
   Maximum_Key_Length          : constant := 256;
   Maximum_Value_Length        : constant := 64 * 1_024;
   Maximum_Mutations_Per_Batch : constant := 256;
   Timeout                     : constant Duration := 30.0;
   Local_Bucket                : constant String := "flyology-db-benchmark";
   Local_Prefix                : constant String := "database";

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Expect (Actual : DB.Outcome_Code; Context : String) is
   begin
      if Actual /= DB.Success then
         raise Program_Error
           with Context & ": " & DB.Outcome_Code'Image (Actual);
      end if;
   end Expect;

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

   function Optional_Environment (Name : String) return String is
     (if Ada.Environment_Variables.Exists (Name)
      then Ada.Environment_Variables.Value (Name)
      else "");

   function Numbered_ID (Value : Interfaces.Unsigned_64) return DB.Identifier
   is
      Result    : DB.Identifier := [others => 0];
      Remaining : Interfaces.Unsigned_64 := Value;
   begin
      for Position in reverse Result'Last - 7 .. Result'Last loop
         Result (Position) := DB.Byte (Remaining mod 256);
         Remaining := Remaining / 256;
      end loop;
      return Result;
   end Numbered_ID;

   function Key_For (Index : Positive; Length : Positive) return DB.Byte_Array
   is
      Result    : DB.Byte_Array (1 .. Length) := [others => 0];
      Remaining : Interfaces.Unsigned_64 := Interfaces.Unsigned_64 (Index);
   begin
      for Position in reverse Result'Last - 7 .. Result'Last loop
         Result (Position) := DB.Byte (Remaining mod 256);
         Remaining := Remaining / 256;
      end loop;
      return Result;
   end Key_For;

   function Value_For
     (Index : Positive; Length : Positive) return DB.Byte_Array
   is
      Result : DB.Byte_Array (1 .. Length);
   begin
      for Position in Result'Range loop
         Result (Position) := DB.Byte ((Index + Position * 31) mod 256);
      end loop;
      return Result;
   end Value_For;

   function Byte_String (Data : DB.Byte_Array) return String is
      Result : String (1 .. Data'Length);
   begin
      for Offset in 0 .. Data'Length - 1 loop
         Result (Result'First + Offset) :=
           Character'Val (Data (Data'First + Offset));
      end loop;
      return Result;
   end Byte_String;

   function Same
     (Left : Flyology.Bytes.Unbounded_Bytes; Right : DB.Byte_Array)
      return Boolean is
   begin
      if Flyology.Bytes.Length (Left) /= Right'Length then
         return False;
      end if;
      for Position in Right'Range loop
         if DB.Byte
              (Flyology.Bytes.Element (Left, Position - Right'First + 1))
           /= Right (Position)
         then
            return False;
         end if;
      end loop;
      return True;
   end Same;

   --  website-benchmark:start flyology-durable-transaction
   procedure Put_Transaction
     (Item         : in out DB.Database;
      Family       : DB.Column_Family;
      Index        : Positive;
      Mutations    : Positive;
      Key_Length   : Positive;
      Value_Length : Positive)
   is
      Transaction : DB.Transaction;
      Receipt     : DB.Commit_Receipt;
      Result      : DB.Outcome_Code;
   begin
      DB.Begin_Transaction
        (Item,
         DB.Transaction_Identifier
           (Numbered_ID (Interfaces.Unsigned_64 (1_000 + Index))),
         DB.Snapshot,
         Transaction,
         Result);
      Expect (Result, "begin failed");
      for Mutation in 1 .. Mutations loop
         declare
            Key_Index : constant Positive :=
              (Index - 1) * Mutations + Mutation;
         begin
            DB.Put
              (Item,
               Transaction,
               Family,
               Key_For (Key_Index, Key_Length),
               Value_For (Key_Index, Value_Length),
               Result);
            Expect (Result, "put failed");
         end;
      end loop;
      DB.Commit
        (Item, Transaction, Timeout, Receipt => Receipt, Result => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve (Item, Receipt, Timeout, Result => Result);
      end if;
      Expect (Result, "durable commit failed");
   exception
      when others =>
         DB.Rollback (Transaction, Result);
         raise;
   end Put_Transaction;
   --  website-benchmark:end flyology-durable-transaction

   function Verify_All
     (Item         : in out DB.Database;
      Total        : Positive;
      Key_Length   : Positive;
      Value_Length : Positive) return GNAT.SHA256.Message_Digest
   is
      Reader : DB.Transaction;
      Family : DB.Column_Family;
      Data   : Flyology.Bytes.Unbounded_Bytes;
      Result : DB.Outcome_Code;
      Digest : GNAT.SHA256.Context := GNAT.SHA256.Initial_Context;
   begin
      DB.Begin_Transaction
        (Item,
         DB.Transaction_Identifier (Numbered_ID (9_000_000)),
         DB.Snapshot,
         Reader,
         Result);
      Expect (Result, "verification begin failed");
      DB.Open_Column_Family (Item, 1, Family, Result);
      Expect (Result, "verification family open failed");
      for Index in 1 .. Total loop
         declare
            Key : constant DB.Byte_Array := Key_For (Index, Key_Length);
         begin
            DB.Get (Item, Reader, Family, Key, Data, Result);
            GNAT.SHA256.Update (Digest, Byte_String (Key));
         end;
         Expect (Result, "verification get failed");
         Require
           (Same (Data, Value_For (Index, Value_Length)),
            "verification value mismatch");
         GNAT.SHA256.Update (Digest, Flyology.Bytes.To_Array (Data));
      end loop;
      DB.Rollback (Reader, Result);
      Expect (Result, "verification rollback failed");
      return GNAT.SHA256.Digest (Digest);
   exception
      when others =>
         DB.Rollback (Reader, Result);
         raise;
   end Verify_All;

   procedure Run
     (Storage             : not null access DB.Storage_Context;
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
      Live_Bytes         : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Total_Keys)
        * Interfaces.Unsigned_64 (Key_Length + Value_Length + 256);
      Batch_Bytes        : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Mutations)
        * Interfaces.Unsigned_64 (Key_Length + Value_Length + 256);
      Limits             : constant DB.Database_Limits :=
        (Maximum_Column_Families             => 1,
         Maximum_Manifest_History            => 2,
         Maximum_Batch_History               =>
           Interfaces.Unsigned_32 (Total_Transactions + 1),
         Maximum_Transactions_Per_Batch      => 1,
         Maximum_Mutations_Per_Transaction   =>
           Interfaces.Unsigned_32 (Mutations),
         Maximum_Mutations_Per_Batch         =>
           Interfaces.Unsigned_32 (Mutations),
         Maximum_Live_Entries                =>
           Interfaces.Unsigned_32 (Total_Keys),
         Maximum_Transaction_Payload_Bytes   => Batch_Bytes,
         Maximum_Batch_Payload_Bytes         => Batch_Bytes,
         Maximum_Live_State_Bytes            => Live_Bytes,
         Maximum_Total_L0_Runs               => 1,
         Maximum_Checkpoint_Identities       =>
           Interfaces.Unsigned_32 (Total_Transactions * 2 + 4),
         Maximum_Point_Reads_Per_Transaction => 1,
         Maximum_Scan_Ranges_Per_Transaction => 1);
      Families           : constant DB.Column_Family_Configuration_Array :=
        [DB.Configure_Column_Family
           (ID                   => 1,
            Name                 =>
              [DB.Byte (Character'Pos ('d')),
               DB.Byte (Character'Pos ('a')),
               DB.Byte (Character'Pos ('t')),
               DB.Byte (Character'Pos ('a'))],
            Max_Key_Bytes        => Interfaces.Unsigned_64 (Key_Length),
            Max_Value_Bytes      => Interfaces.Unsigned_64 (Value_Length),
            Memtable_Max_Bytes   => Live_Bytes,
            Memtable_Max_Entries => Interfaces.Unsigned_32 (Total_Keys),
            Maximum_L0_Runs      => 1)];
      Ignored_Item        : DB.Database;
      Family              : DB.Column_Family;
      Create_Info         : DB.Create_Receipt;
      Result              : DB.Outcome_Code;
      Started             : Ada.Real_Time.Time;
      Finished            : Ada.Real_Time.Time;
   begin
      Require
        (Total_Transactions <= Maximum_Operations,
         "operation count exceeds benchmark fixture limit");
      Require
        (Key_Length in 8 .. Maximum_Key_Length,
         "key length is outside the benchmark fixture limit");
      Require
        (Value_Length <= Maximum_Value_Length,
         "value length exceeds the benchmark fixture limit");
      Require
        (Mutations <= Maximum_Mutations_Per_Batch,
         "mutation count exceeds the benchmark fixture limit");
      DB.Create
        (Ignored_Item,
         Storage,
         DB.Database_Identifier (Numbered_ID (1)),
         Numbered_ID (2),
         Numbered_ID (3),
         Limits,
         Families,
         Timeout,
         Receipt => Create_Info,
         Result  => Result);
      if Result = DB.Outcome_Unknown then
         DB.Resolve_Create
           (Ignored_Item, Storage, Create_Info, Timeout, Result => Result);
      end if;
      Expect (Result, "create failed");
      DB.Open_Column_Family (Ignored_Item, 1, Family, Result);
      Expect (Result, "family open failed");

      for Index in 1 .. Warmup loop
         Put_Transaction
           (Ignored_Item, Family, Index, Mutations, Key_Length, Value_Length);
      end loop;
      Started := Ada.Real_Time.Clock;
      for Index in Warmup + 1 .. Total_Transactions loop
         Put_Transaction
           (Ignored_Item, Family, Index, Mutations, Key_Length, Value_Length);
      end loop;
      Finished := Ada.Real_Time.Clock;

      DB.Close (Ignored_Item, Result);
      Expect (Result, "close failed");
      DB.Open
        (Ignored_Item,
         Storage,
         DB.Database_Identifier (Numbered_ID (1)),
         Timeout,
         Result => Result);
      Expect (Result, "reopen failed");
      State_SHA256 :=
        Verify_All (Ignored_Item, Total_Keys, Key_Length, Value_Length);
      DB.Close (Ignored_Item, Result);
      Expect (Result, "verification close failed");

      Elapsed_Nanoseconds :=
        Long_Float
          (Ada.Real_Time.To_Duration (Finished - Started)
           * 1_000_000_000.0);
      Require
        (Elapsed_Nanoseconds > 0.0,
         "timer resolution was insufficient");
      Verified_Keys := Total_Keys;
   end Run;

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
      Store        : aliased Files.Store :=
        Files.Open
          (Root,
           Maximum_Object_Size => 256 * 1_024 * 1_024,
           Commit              => Files.Power_Loss_Durable);
      Storage      : aliased DB.Storage_Context;
      Store_Result : OS.Status;
   begin
      Store.Create_Bucket
        (Local_Bucket,
         Token    => null,
         Deadline => Ada.Real_Time.Clock
           + Ada.Real_Time.To_Time_Span (Timeout),
         Result   => Store_Result);
      Require (Store_Result = OS.Success, "files bucket creation failed");
      Binding.Bind (Storage, Store'Access, Local_Bucket, Local_Prefix);
      Run
        (Storage'Access,
         Warmup,
         Measured,
         Key_Length,
         Value_Length,
         Mutations,
         Elapsed_Nanoseconds,
         Verified_Keys,
         State_SHA256);
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
      Elapsed_Nanoseconds : out Long_Float;
      Verified_Keys       : out Positive;
      State_SHA256        : out GNAT.SHA256.Message_Digest)
   is
      Origin   : constant HTTP.Origin := HTTP.Parse_Origin (Endpoint);
      Client   : aliased HTTP_Client.Client (Capacity => 4);
      Identity : aliased Low_Level.Credentials :=
        Low_Level.Make_Credentials
          (Required_Environment ("AWS_ACCESS_KEY_ID"),
           Required_Environment ("AWS_SECRET_ACCESS_KEY"),
           Optional_Environment ("AWS_SESSION_TOKEN"));
      Storage  : aliased DB.Storage_Context;
   begin
      HTTP_Client.Configure (Client, Origin);
      Binding.Bind_Client
        (Storage,
         Client'Access,
         Origin,
         Identity'Access,
         Bucket,
         Prefix,
         "us-east-1",
         Low_Level.Path_Style,
         "application/octet-stream",
         "",
         "",
         False);
      Run
        (Storage'Access,
         Warmup,
         Measured,
         Key_Length,
         Value_Length,
         Mutations,
         Elapsed_Nanoseconds,
         Verified_Keys,
         State_SHA256);
   end Run_S3;

end Flyology_DB_Benchmark_Flyology;
