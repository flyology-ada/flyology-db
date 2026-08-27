with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.DB;
with Flyology.DB.Object_Storage;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.Object_Storage.Client.Low_Level;

procedure Flyology_DB_Object_Storage_E2E is
   package DB renames Flyology.DB;
   package Binding renames Flyology.DB.Object_Storage;
   package HTTP renames Flyology.HTTP;
   package HTTP_Client renames Flyology.HTTP.Client;
   package Low_Level renames Flyology.Object_Storage.Client.Low_Level;

   use type DB.Byte;
   use type DB.Outcome_Code;

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   procedure Expect (Actual, Expected : DB.Outcome_Code; Context : String) is
   begin
      if Actual /= Expected then
         raise Program_Error with Context & ": " & DB.Outcome_Code'Image (Actual);
      end if;
   end Expect;

   function Required_Argument (Index : Positive) return String is
   begin
      if Ada.Command_Line.Argument_Count /= 6 then
         raise Program_Error with
           "usage: flyology_db_object_storage_e2e ENDPOINT BUCKET FRESH_PREFIX REGION "
           & "path|virtual-hosted TIMEOUT_SECONDS";
      end if;
      return Ada.Command_Line.Argument (Index);
   end Required_Argument;

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
     (if Ada.Environment_Variables.Exists (Name) then Ada.Environment_Variables.Value (Name) else "");

   function Bytes (Value : String) return DB.Byte_Array is
      Result : DB.Byte_Array (1 .. Value'Length);
   begin
      for Offset in Natural range 0 .. Value'Length - 1 loop
         Result (Offset + 1) := DB.Byte (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Same (Left : Flyology.Bytes.Unbounded_Bytes; Right : DB.Byte_Array) return Boolean is
   begin
      if Flyology.Bytes.Length (Left) /= Right'Length then
         return False;
      end if;
      for Offset in Natural range 0 .. Right'Length - 1 loop
         if DB.Byte (Flyology.Bytes.Element (Left, Offset + 1)) /= Right (Right'First + Offset) then
            return False;
         end if;
      end loop;
      return True;
   end Same;

   function Numbered_ID (Value : DB.Byte) return DB.Identifier is
      Result : DB.Identifier := [others => 0];
   begin
      Result (Result'Last) := Value;
      return Result;
   end Numbered_ID;

   function Database_ID (Value : DB.Byte) return DB.Database_Identifier
   is (DB.Database_Identifier (Numbered_ID (Value)));

   function Transaction_ID (Value : DB.Byte) return DB.Transaction_Identifier
   is (DB.Transaction_Identifier (Numbered_ID (Value)));

   function Parse_Style (Value : String) return Low_Level.Addressing_Style is
   begin
      if Value = "path" then
         return Low_Level.Path_Style;
      elsif Value = "virtual-hosted" then
         return Low_Level.Virtual_Hosted_Style;
      else
         raise Program_Error with "addressing style must be path or virtual-hosted";
      end if;
   end Parse_Style;

   Endpoint : constant String := Required_Argument (1);
   Bucket   : constant String := Required_Argument (2);
   Prefix   : constant String := Required_Argument (3);
   Region   : constant String := Required_Argument (4);
   Style    : constant Low_Level.Addressing_Style := Parse_Style (Required_Argument (5));
   Timeout  : constant Duration := Duration'Value (Required_Argument (6));
   Origin   : constant HTTP.Origin := HTTP.Parse_Origin (Endpoint);

   Access_Key    : constant String := Required_Environment ("AWS_ACCESS_KEY_ID");
   Secret_Key    : constant String := Required_Environment ("AWS_SECRET_ACCESS_KEY");
   Session_Token : constant String := Optional_Environment ("AWS_SESSION_TOKEN");

   --  Four HTTP leases match the established authenticated qualification
   --  geometry and exceed this serial walkthrough's one visible operation.
   --  This is executable-local capacity, not a DB or HTTP library default.
   Client   : aliased HTTP_Client.Client (Capacity => 4);
   Identity : aliased Low_Level.Credentials :=
     Low_Level.Make_Credentials (Access_Key, Secret_Key, Session_Token);
   Context  : aliased DB.Storage_Context;

   --  The walkthrough publishes one root, one one-mutation batch, and one
   --  one-family Flush. These exact persisted limits are fixture authority,
   --  not defaults or recommendations for an application database.
   Limits : constant DB.Database_Limits :=
     (Maximum_Column_Families             => 1,
      Maximum_Manifest_History            => 2,
      Maximum_Batch_History               => 1,
      Maximum_Transactions_Per_Batch      => 1,
      Maximum_Mutations_Per_Transaction   => 1,
      Maximum_Mutations_Per_Batch         => 1,
      Maximum_Live_Entries                => 1,
      Maximum_Transaction_Payload_Bytes   => 128,
      Maximum_Batch_Payload_Bytes         => 128,
      Maximum_Live_State_Bytes            => 256,
      Maximum_Total_L0_Runs               => 1,
      Maximum_Checkpoint_Identities       => 3,
      Maximum_Point_Reads_Per_Transaction => 1,
      Maximum_Scan_Ranges_Per_Transaction => 1);
   Families : constant DB.Column_Family_Configuration_Array :=
     [DB.Configure_Column_Family
        (1,
         Bytes ("records"),
         Max_Key_Bytes        => 32,
         Max_Value_Bytes      => 64,
         Memtable_Max_Bytes   => 256,
         Memtable_Max_Entries => 1,
         Maximum_L0_Runs      => 1)];

   Runs : constant DB.Checkpoint_Run_Identity_Array :=
     [DB.Configure_Checkpoint_Run (1, Numbered_ID (5))];
   Key_Data   : constant DB.Byte_Array := Bytes ("hello");
   Value_Data : constant DB.Byte_Array := Bytes ("object-storage");

   Created        : DB.Database;
   Reopened       : DB.Database;
   Txn            : DB.Transaction;
   Family         : DB.Column_Family;
   Create_Info    : DB.Create_Receipt;
   Commit_Info    : DB.Commit_Receipt;
   Flush_Info     : DB.Flush_Receipt;
   Data           : Flyology.Bytes.Unbounded_Bytes;
   Result         : DB.Outcome_Code;
   Close_Result   : DB.Outcome_Code;
   Created_Open   : Boolean := False;
   Reopened_Open  : Boolean := False;
   Txn_Active     : Boolean := False;
begin
   Require (Timeout > 0.0, "TIMEOUT_SECONDS must be positive");
   HTTP_Client.Configure (Client, Origin);
   --  The caller supplies an existing bucket and a fresh dedicated prefix.
   --  Binary content type and omitted owner/payer/checksum options match the
   --  currently qualified limited profile; no provider policy is inferred.
   Binding.Bind_Client
     (Context,
      Client'Access,
      Origin,
      Identity'Access,
      Bucket,
      Prefix,
      Region,
      Style,
      "application/octet-stream",
      "",
      "",
      False);

   DB.Create
     (Created,
      Context'Access,
      Database_ID (1),
      Numbered_ID (2),
      Numbered_ID (3),
      Limits,
      Families,
      Timeout,
      Receipt => Create_Info,
      Result  => Result);
   Expect (Result, DB.Success, "authenticated database create failed; the prefix must be fresh");
   Created_Open := True;
   DB.Open_Column_Family (Created, 1, Family, Result);
   Expect (Result, DB.Success, "root family open failed");
   DB.Begin_Transaction (Created, Transaction_ID (4), DB.Snapshot, Txn, Result);
   Expect (Result, DB.Success, "transaction begin failed");
   Txn_Active := True;
   DB.Put (Created, Txn, Family, Key_Data, Value_Data, Result);
   Expect (Result, DB.Success, "transaction Put failed");
   DB.Commit (Created, Txn, Timeout, Receipt => Commit_Info, Result => Result);
   Expect (Result, DB.Success, "transaction commit failed");
   Txn_Active := False;
   DB.Flush
     (Created,
      Runs,
      Numbered_ID (6),
      Numbered_ID (7),
      Timeout,
      Receipt => Flush_Info,
      Result  => Result);
   Expect (Result, DB.Success, "checkpoint Flush failed");
   DB.Close (Created, Close_Result);
   Expect (Close_Result, DB.Success, "created database close failed");
   Created_Open := False;

   DB.Open (Reopened, Context'Access, Database_ID (1), Timeout, Result => Result);
   Expect (Result, DB.Success, "cacheless authoritative reopen failed");
   Reopened_Open := True;
   DB.Open_Column_Family (Reopened, 1, Family, Result);
   Expect (Result, DB.Success, "reopened family lookup failed");
   DB.Begin_Transaction (Reopened, Transaction_ID (8), DB.Snapshot, Txn, Result);
   Expect (Result, DB.Success, "reopened reader begin failed");
   Txn_Active := True;
   DB.Get (Reopened, Txn, Family, Key_Data, Data, Result);
   Expect (Result, DB.Success, "reopened value read failed");
   Require (Same (Data, Value_Data), "reopened value bytes differ from the committed value");
   DB.Rollback (Txn, Result);
   Expect (Result, DB.Success, "reopened reader rollback failed");
   Txn_Active := False;
   DB.Close (Reopened, Close_Result);
   Expect (Close_Result, DB.Success, "reopened database close failed");
   Reopened_Open := False;

   Ada.Text_IO.Put_Line
     ("Flyology.DB authenticated create/commit/Flush/cacheless-reopen walkthrough passed");
exception
   when others =>
      if Txn_Active then
         DB.Rollback (Txn, Result);
      end if;
      if Created_Open then
         DB.Close (Created, Close_Result);
      end if;
      if Reopened_Open then
         DB.Close (Reopened, Close_Result);
      end if;
      raise;
end Flyology_DB_Object_Storage_E2E;
