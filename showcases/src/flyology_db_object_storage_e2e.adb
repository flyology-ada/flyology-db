with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology.DB;
with Flyology.DB.Object_Storage;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.Object_Storage.Client.Low_Level;
with Flyology_DB_Limited_Workflow;

procedure Flyology_DB_Object_Storage_E2E is
   package DB renames Flyology.DB;
   package Binding renames Flyology.DB.Object_Storage;
   package HTTP renames Flyology.HTTP;
   package HTTP_Client renames Flyology.HTTP.Client;
   package Low_Level renames Flyology.Object_Storage.Client.Low_Level;
   package Workflow renames Flyology_DB_Limited_Workflow;

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

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
   Client_Capacity : constant := 4;

   --  These exact binding values preserve the qualified limited profile. They
   --  select no provider retry, owner, payer, checksum, or content policy for
   --  library callers.
   Content_Type          : constant String := "application/octet-stream";
   Expected_Bucket_Owner : constant String := "";
   Request_Payer         : constant String := "";
   Checksum_Mode         : constant Boolean := False;

   procedure Seed_And_Close is
      --  The client, credentials, and binding are phase-local. Their complete
      --  finalization before Reopen drops the HTTP pool and adapter state.
      Client   : aliased HTTP_Client.Client (Capacity => Client_Capacity);
      Identity : aliased Low_Level.Credentials :=
        Low_Level.Make_Credentials (Access_Key, Secret_Key, Session_Token);
      Context  : aliased DB.Storage_Context;
   begin
      HTTP_Client.Configure (Client, Origin);
      Binding.Bind_Client
        (Context,
         Client'Access,
         Origin,
         Identity'Access,
         Bucket,
         Prefix,
         Region,
         Style,
         Content_Type,
         Expected_Bucket_Owner,
         Request_Payer,
         Checksum_Mode);
      Workflow.Seed_And_Close (Context'Access, Timeout);
   end Seed_And_Close;

   procedure Reopen_And_Verify is
      --  Only the caller-owned bucket/prefix authority crosses this boundary;
      --  the HTTP pool, credentials value, binding, and DB are reconstructed.
      Client   : aliased HTTP_Client.Client (Capacity => Client_Capacity);
      Identity : aliased Low_Level.Credentials :=
        Low_Level.Make_Credentials (Access_Key, Secret_Key, Session_Token);
      Context  : aliased DB.Storage_Context;
   begin
      HTTP_Client.Configure (Client, Origin);
      Binding.Bind_Client
        (Context,
         Client'Access,
         Origin,
         Identity'Access,
         Bucket,
         Prefix,
         Region,
         Style,
         Content_Type,
         Expected_Bucket_Owner,
         Request_Payer,
         Checksum_Mode);
      Workflow.Reopen_And_Verify (Context'Access, Timeout);
   end Reopen_And_Verify;

begin
   Require (Timeout > 0.0, "TIMEOUT_SECONDS must be positive");
   --  The caller supplies an existing bucket and a fresh dedicated prefix.
   --  Neither phase manages the bucket, retries a mutation, or chooses object
   --  retention or cleanup policy.
   Seed_And_Close;
   Reopen_And_Verify;

   Ada.Text_IO.Put_Line ("Flyology.DB authenticated full limited workflow passed");
end Flyology_DB_Object_Storage_E2E;
