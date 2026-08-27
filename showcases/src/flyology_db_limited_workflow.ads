with Flyology.DB;

--  Shared public-API acceptance workflow for provider-specific showcase mains.

package Flyology_DB_Limited_Workflow is

   --  Create, mutate, checkpoint, compact, verify, and close the fixture.
   --  Context must be bound to a fresh caller-owned provider scope that
   --  outlives this call. Timeout is caller-selected and must be positive.
   procedure Seed_And_Close
     (Context : not null access Flyology.DB.Storage_Context;
      Timeout : Duration);

   --  Reopen and verify the fixture after every prior provider and DB owner
   --  has finalized. Context must be a fresh binding to the same authority.
   procedure Reopen_And_Verify
     (Context : not null access Flyology.DB.Storage_Context;
      Timeout : Duration);

end Flyology_DB_Limited_Workflow;
