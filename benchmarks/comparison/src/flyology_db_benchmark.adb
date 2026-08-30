with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.DB;
with Flyology.DB.Object_Storage;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Files;
with Flyology.Object_Storage.Client.Low_Level;
with Interfaces;

procedure Flyology_DB_Benchmark is
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

   --  Manifest-v1 admits 64 batch-history entries; the fixture keeps one spare.
   Maximum_Operations : constant := 63;
   Key_Length         : constant := 16;
   Value_Length       : constant := 1_024;
   Timeout            : constant Duration := 30.0;
   Local_Bucket       : constant String := "flyology-db-benchmark";
   Local_Prefix       : constant String := "database";

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

   function Required_Environment (Name : String) return String is
   begin
      if not Ada.Environment_Variables.Exists (Name)
        or else Ada.Environment_Variables.Value (Name)'Length = 0
      then
         raise Program_Error with "required environment variable is absent: " & Name;
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

   function Key_For (Index : Positive) return DB.Byte_Array
   is (DB.Byte_Array (Numbered_ID (Interfaces.Unsigned_64 (Index))));

   function Value_For (Index : Positive) return DB.Byte_Array is
      Result : DB.Byte_Array (1 .. Value_Length);
   begin
      for Position in Result'Range loop
         Result (Position) := DB.Byte ((Index + Position * 31) mod 256);
      end loop;
      return Result;
   end Value_For;

   function Same
     (Left : Flyology.Bytes.Unbounded_Bytes; Right : DB.Byte_Array)
      return Boolean is
   begin
      if Flyology.Bytes.Length (Left) /= Right'Length then
         return False;
      end if;
      for Position in Right'Range loop
         if DB.Byte (Flyology.Bytes.Element (Left, Position - Right'First + 1))
           /= Right (Position)
         then
            return False;
         end if;
      end loop;
      return True;
   end Same;

   procedure Put_One
     (Item : in out DB.Database; Family : DB.Column_Family; Index : Positive)
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
      DB.Put
        (Item,
         Transaction,
         Family,
         Key_For (Index),
         Value_For (Index),
         Result);
      Expect (Result, "put failed");
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
   end Put_One;

   procedure Verify_All (Item : in out DB.Database; Total : Positive) is
      Reader : DB.Transaction;
      Family : DB.Column_Family;
      Data   : Flyology.Bytes.Unbounded_Bytes;
      Result : DB.Outcome_Code;
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
         DB.Get (Item, Reader, Family, Key_For (Index), Data, Result);
         Expect (Result, "verification get failed");
         Require
           (Same (Data, Value_For (Index)), "verification value mismatch");
      end loop;
      DB.Rollback (Reader, Result);
      Expect (Result, "verification rollback failed");
   exception
      when others =>
         DB.Rollback (Reader, Result);
         raise;
   end Verify_All;

   procedure Run
     (Storage  : not null access DB.Storage_Context;
      Warmup   : Natural;
      Measured : Positive)
   is
      Total    : constant Positive := Warmup + Measured;

      Live_Bytes : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Total) * 4_096;
      Limits     : constant DB.Database_Limits :=
        (Maximum_Column_Families             => 1,
         Maximum_Manifest_History            => 2,
         Maximum_Batch_History               =>
           Interfaces.Unsigned_32 (Total + 1),
         Maximum_Transactions_Per_Batch      => 1,
         Maximum_Mutations_Per_Transaction   => 1,
         Maximum_Mutations_Per_Batch         => 1,
         Maximum_Live_Entries                => Interfaces.Unsigned_32 (Total),
         Maximum_Transaction_Payload_Bytes   => 2_048,
         Maximum_Batch_Payload_Bytes         => 2_048,
         Maximum_Live_State_Bytes            => Live_Bytes,
         Maximum_Total_L0_Runs               => 1,
         Maximum_Checkpoint_Identities       =>
           Interfaces.Unsigned_32 (Total * 2 + 4),
         Maximum_Point_Reads_Per_Transaction => 1,
         Maximum_Scan_Ranges_Per_Transaction => 1);
      Families   : constant DB.Column_Family_Configuration_Array :=
        [DB.Configure_Column_Family
           (ID                   => 1,
            Name                 =>
              [DB.Byte (Character'Pos ('d')),
               DB.Byte (Character'Pos ('a')),
               DB.Byte (Character'Pos ('t')),
               DB.Byte (Character'Pos ('a'))],
            Max_Key_Bytes        => Key_Length,
            Max_Value_Bytes      => Value_Length,
            Memtable_Max_Bytes   => Live_Bytes,
            Memtable_Max_Entries => Interfaces.Unsigned_32 (Total),
            Maximum_L0_Runs      => 1)];

      Item        : DB.Database;
      Family      : DB.Column_Family;
      Create_Info : DB.Create_Receipt;
      Result      : DB.Outcome_Code;
      Started     : Ada.Real_Time.Time;
      Finished    : Ada.Real_Time.Time;
      Nanoseconds : Long_Long_Integer;
   begin
      Require
        (Total <= Maximum_Operations,
         "operation count exceeds benchmark fixture limit");
      DB.Create
        (Item,
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
         DB.Resolve_Create (Item, Storage, Create_Info, Timeout, Result => Result);
      end if;
      Expect (Result, "create failed");
      DB.Open_Column_Family (Item, 1, Family, Result);
      Expect (Result, "family open failed");

      for Index in 1 .. Warmup loop
         Put_One (Item, Family, Index);
      end loop;
      Started := Ada.Real_Time.Clock;
      for Index in Warmup + 1 .. Total loop
         Put_One (Item, Family, Index);
      end loop;
      Finished := Ada.Real_Time.Clock;

      DB.Close (Item, Result);
      Expect (Result, "close failed");
      DB.Open
        (Item,
         Storage,
         DB.Database_Identifier (Numbered_ID (1)),
         Timeout,
         Result => Result);
      Expect (Result, "reopen failed");
      Verify_All (Item, Total);
      DB.Close (Item, Result);
      Expect (Result, "verification close failed");

      Nanoseconds :=
        Long_Long_Integer
          (Ada.Real_Time.To_Duration (Finished - Started) * 1_000_000_000.0);
      Require (Nanoseconds > 0, "timer resolution was insufficient");
      Ada.Text_IO.Put_Line
        ("elapsed_nanoseconds=" & Long_Long_Integer'Image (Nanoseconds));
      Ada.Text_IO.Put_Line ("verified_keys=" & Positive'Image (Total));
   end Run;

begin
   if Ada.Command_Line.Argument_Count = 4
     and then Ada.Command_Line.Argument (1) = "local"
   then
      declare
         Root         : constant String := Ada.Command_Line.Argument (2);
         Warmup       : constant Natural :=
           Nonnegative_Argument (3, "warmup operations");
         Measured     : constant Positive :=
           Positive_Argument (4, "measured operations");
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
            Deadline => Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout),
            Result   => Store_Result);
         Require (Store_Result = OS.Success, "files bucket creation failed");
         Binding.Bind (Storage, Store'Access, Local_Bucket, Local_Prefix);
         Run (Storage'Access, Warmup, Measured);
      end;
   elsif Ada.Command_Line.Argument_Count = 6
     and then Ada.Command_Line.Argument (1) = "s3"
   then
      declare
         Endpoint : constant String := Ada.Command_Line.Argument (2);
         Bucket   : constant String := Ada.Command_Line.Argument (3);
         Prefix   : constant String := Ada.Command_Line.Argument (4);
         Warmup   : constant Natural :=
           Nonnegative_Argument (5, "warmup operations");
         Measured : constant Positive :=
           Positive_Argument (6, "measured operations");
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
         Run (Storage'Access, Warmup, Measured);
      end;
   else
      raise Program_Error
        with
          "usage: flyology_db_benchmark local FRESH_ROOT WARMUP MEASURED"
          & " or flyology_db_benchmark s3 ENDPOINT BUCKET FRESH_PREFIX WARMUP MEASURED";
   end if;
end Flyology_DB_Benchmark;
