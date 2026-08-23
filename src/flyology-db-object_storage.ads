with Flyology.Object_Storage.Backends;

--  Binds Flyology.DB storage contexts to provider-neutral Object Storage backends.

package Flyology.DB.Object_Storage is

   --  Bind an unused context to a caller-owned backend and database prefix.
   --  Backend must outlive every database opened with Item. Rebinding is rejected.
   --  @param Item Context to bind exactly once
   --  @param Backend Caller-owned provider-neutral backend
   --  @param Bucket Existing bucket; Flyology.DB never creates it
   --  @param Prefix Validated database-root prefix within Bucket
   --  @exception Program_Error Item is bound or Bucket or Prefix is invalid
   procedure Bind
     (Item    : in out Storage_Context;
      Backend : not null access Flyology.Object_Storage.Backends.Backend'Class;
      Bucket  : String;
      Prefix  : String);

end Flyology.DB.Object_Storage;
