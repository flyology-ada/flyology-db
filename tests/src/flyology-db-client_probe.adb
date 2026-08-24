with Ada.Command_Line;
with Ada.Text_IO;
with Flyology.Bytes;
with Flyology.DB.Object_Storage;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.Object_Storage.Client.Buckets;
with Flyology.Object_Storage.Client.Low_Level;

procedure Flyology.DB.Client_Probe is
   package Binding renames Flyology.DB.Object_Storage;
   package Buckets renames Flyology.Object_Storage.Client.Buckets;
   package HTTP renames Flyology.HTTP;
   package HTTP_Client renames Flyology.HTTP.Client;
   package Low_Level renames Flyology.Object_Storage.Client.Low_Level;

   use type Buckets.Create_Outcome_Kind;
   use type Byte;

   procedure Expect (Actual, Expected : Outcome_Code; Context : String) is
   begin
      if Actual /= Expected then
         raise Program_Error with Context & ": " & Outcome_Code'Image (Actual);
      end if;
   end Expect;

   function Numbered_ID (Value : Byte) return Identifier is
      Result : Identifier := [others => 0];
   begin
      Result (Result'Last) := Value;
      return Result;
   end Numbered_ID;

   function Bytes (Value : String) return Byte_Array is
      Result : Byte_Array (1 .. Value'Length);
   begin
      for Offset in Natural range 0 .. Value'Length - 1 loop
         Result (Offset + 1) := Byte (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Same (Left : Flyology.Bytes.Unbounded_Bytes; Right : Byte_Array) return Boolean is
   begin
      if Flyology.Bytes.Length (Left) /= Right'Length then
         return False;
      end if;
      for Offset in Natural range 0 .. Right'Length - 1 loop
         if Byte (Flyology.Bytes.Element (Left, Offset + 1)) /= Right (Right'First + Offset) then
            return False;
         end if;
      end loop;
      return True;
   end Same;

   function Required_Argument (Index : Positive) return String is
   begin
      if Ada.Command_Line.Argument_Count /= 4 then
         raise Program_Error with "usage: flyology-db-client-probe ENDPOINT BUCKET ACCESS_KEY SECRET_KEY";
      end if;
      return Ada.Command_Line.Argument (Index);
   end Required_Argument;

   Endpoint      : constant String := Required_Argument (1);
   Bucket        : constant String := Required_Argument (2);
   Access_Key    : constant String := Required_Argument (3);
   Secret_Key    : constant String := Required_Argument (4);
   Origin        : constant HTTP.Origin := HTTP.Parse_Origin (Endpoint);
   --  Four concurrent HTTP leases cover this serial black-box probe while
   --  matching the pinned client's already-qualified default geometry. This
   --  is test capacity, not a DB pool or connection default.
   Client        : aliased HTTP_Client.Client (Capacity => 4);
   Identity      : aliased Low_Level.Credentials := Low_Level.Make_Credentials (Access_Key, Secret_Key);
   Context       : aliased Storage_Context;
   Created       : Database;
   Reopened      : Database;
   Txn           : Transaction;
   Reader        : Transaction;
   Family        : Column_Family;
   Receipt       : Create_Receipt;
   Commit_Info   : Commit_Receipt;
   Data          : Flyology.Bytes.Unbounded_Bytes;
   Result        : Outcome_Code;
   Close_Result  : Outcome_Code;
   Bucket_Result : Buckets.Create_Outcome;

   --  The one-family remote fixture deliberately exercises unequal 20-byte
   --  key and 400-byte value authority. The remaining persisted limits admit
   --  exactly this small create/commit/reopen corpus and are not API defaults.
   Limits     : constant Database_Limits :=
     (Maximum_Column_Families           => 1,
      Maximum_Manifest_History          => 2,
      Maximum_Batch_History             => 4,
      Maximum_Transactions_Per_Batch    => 1,
      Maximum_Mutations_Per_Transaction => 4,
      Maximum_Mutations_Per_Batch       => 4,
      Maximum_Live_Entries              => 4,
      Maximum_Transaction_Payload_Bytes => 1_024,
      Maximum_Batch_Payload_Bytes       => 2_048,
      Maximum_Live_State_Bytes          => 4_096,
      Maximum_Total_L0_Runs             => 1,
      Maximum_Checkpoint_Identities     => 8);
   Families   : constant Column_Family_Configuration_Array :=
     [Configure_Column_Family
        (1,
         Bytes ("primary"),
         Max_Key_Bytes        => 20,
         Max_Value_Bytes      => 400,
         Memtable_Max_Bytes   => 1_680,
         Memtable_Max_Entries => 4,
         Maximum_L0_Runs      => 1)];
   Key_Data   : constant Byte_Array := Bytes ("client-key");
   Value_Data : constant Byte_Array := Bytes ("client-value");
begin
   HTTP_Client.Configure (Client, Origin);
   Bucket_Result :=
     Buckets.Create
       (Client,
        Origin,
        Bucket,
        Identity,
        Region  => "us-east-1",
        Style   => Low_Level.Path_Style,
        Timeout => 10.0);
   if Bucket_Result.Kind /= Buckets.Creation_Completed then
      raise Program_Error with "client probe could not create its fresh bucket";
   end if;

   --  Region/style/media selections are exact black-box fixture inputs. Empty
   --  owner and request-payer omit those optional headers; checksum mode is
   --  disabled because DB object envelopes supply the integrity assertion.
   Binding.Bind_Client
     (Context,
      Client'Access,
      Origin,
      Identity'Access,
      Bucket,
      "database",
      "us-east-1",
      Low_Level.Path_Style,
      "application/octet-stream",
      "",
      "",
      False);

   Create
     (Created,
      Context'Access,
      Database_Identifier (Numbered_ID (1)),
      Numbered_ID (2),
      Numbered_ID (3),
      Limits,
      Families,
      10.0,
      Receipt => Receipt,
      Result  => Result);
   Expect (Result, Success, "client-backed create failed");

   Begin_Transaction (Created, Transaction_Identifier (Numbered_ID (4)), Txn, Result);
   Expect (Result, Success, "client-backed transaction begin failed");
   Open_Column_Family (Created, 1, Family, Result);
   Expect (Result, Success, "client-backed family open failed");
   Put (Created, Txn, Family, Key_Data, Value_Data, Result);
   Expect (Result, Success, "client-backed put failed");
   Commit (Created, Txn, 10.0, Receipt => Commit_Info, Result => Result);
   Expect (Result, Success, "client-backed commit failed");
   Close (Created, Close_Result);
   Expect (Close_Result, Success, "client-backed close failed");

   Open (Reopened, Context'Access, Database_Identifier (Numbered_ID (1)), 10.0, Result => Result);
   Expect (Result, Success, "cacheless client-backed reopen failed");
   Begin_Transaction (Reopened, Transaction_Identifier (Numbered_ID (5)), Reader, Result);
   Expect (Result, Success, "client-backed reader begin failed");
   Open_Column_Family (Reopened, 1, Family, Result);
   Expect (Result, Success, "reopened family lookup failed");
   Get (Reopened, Reader, Family, Key_Data, Data, Result);
   Expect (Result, Success, "reopened client-backed read failed");
   if not Same (Data, Value_Data) then
      raise Program_Error with "client-backed recovery returned the wrong bytes";
   end if;
   Rollback (Reader, Result);
   Expect (Result, Success, "client-backed reader rollback failed");
   Close (Reopened, Close_Result);
   Expect (Close_Result, Success, "reopened client-backed close failed");
   Ada.Text_IO.Put_Line ("Flyology.DB client-backed create/commit/reopen passed");
exception
   when others =>
      Close (Created, Close_Result);
      Close (Reopened, Close_Result);
      raise;
end Flyology.DB.Client_Probe;
