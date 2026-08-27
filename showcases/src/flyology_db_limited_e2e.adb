with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.DB;
with Flyology.DB.Object_Storage;
with Flyology.Object_Storage;
with Flyology.Object_Storage.Backends.Files;
with Flyology_DB_Limited_Workflow;

procedure Flyology_DB_Limited_E2E is
   package DB renames Flyology.DB;
   package Binding renames Flyology.DB.Object_Storage;
   package Files renames Flyology.Object_Storage.Backends.Files;
   package OS renames Flyology.Object_Storage;
   package Workflow renames Flyology_DB_Limited_Workflow;

   use type OS.Status;
   use type Ada.Real_Time.Time;

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   function Root_Argument return String is
   begin
      if Ada.Command_Line.Argument_Count /= 1 then
         raise Program_Error with "usage: flyology_db_limited_e2e FILES_ROOT";
      end if;
      return Ada.Command_Line.Argument (1);
   end Root_Argument;

   Root : constant String := Root_Argument;

   --  This files-backend request ceiling exceeds every object admitted by the
   --  fixture's persisted 4-KiB live-state bound. It is showcase geometry, not
   --  a DB or provider default.
   Maximum_Object_Size : constant OS.Byte_Count := 65_536;

   --  Names isolate the temporary showcase namespace. They are not DB object
   --  naming defaults and are discarded with the runner-owned temporary root.
   Bucket : constant String := "flyology-db-limited-e2e";
   Prefix : constant String := "database";
   --  Ten seconds bounds each local synchronous operation in this executable.
   --  It is fixture stability geometry, not a library timeout or retry budget.
   Timeout : constant Duration := 10.0;

   procedure Seed_And_Close is
      --  The handle and binding are phase-local. Their finalization before
      --  Reopen loses all process-local provider and DB adapter state.
      Store   : aliased Files.Store :=
        Files.Open (Root, Maximum_Object_Size => Maximum_Object_Size, Commit => Files.Power_Loss_Durable);
      Context : aliased DB.Storage_Context;
   begin
      Binding.Bind (Context, Store'Access, Bucket, Prefix);
      Workflow.Seed_And_Close (Context'Access, Timeout);
   end Seed_And_Close;

   procedure Reopen_And_Verify is
      --  Only durable files cross the phase boundary; both owners are fresh.
      Store   : aliased Files.Store :=
        Files.Open (Root, Maximum_Object_Size => Maximum_Object_Size, Commit => Files.Power_Loss_Durable);
      Context : aliased DB.Storage_Context;
   begin
      Binding.Bind (Context, Store'Access, Bucket, Prefix);
      Workflow.Reopen_And_Verify (Context'Access, Timeout);
   end Reopen_And_Verify;

begin
   declare
      --  Bucket setup has its own provider lifetime too; no live provider
      --  object crosses into either database phase.
      Store           : Files.Store :=
        Files.Open (Root, Maximum_Object_Size => Maximum_Object_Size, Commit => Files.Power_Loss_Durable);
      Provider_Result : OS.Status;
   begin
      Store.Create_Bucket
        (Bucket, null, Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout), Provider_Result);
      Require (Provider_Result = OS.Success, "files bucket creation failed");
   end;

   Seed_And_Close;
   Reopen_And_Verify;

   Ada.Text_IO.Put_Line ("Flyology.DB limited end-to-end profile: OK");
end Flyology_DB_Limited_E2E;
