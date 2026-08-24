with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.Object_Storage.Backends;
with Flyology.Object_Storage.Client.Low_Level;

--  Binds Flyology.DB storage contexts to provider-neutral backends or authenticated clients.

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

   --  Bind an unused context to caller-owned HTTP/SigV4 state. Client and
   --  Identity must outlive every database opened with Item. Origin, Region,
   --  Style, Content_Type, Expected_Bucket_Owner, Request_Payer, and
   --  Checksum_Mode are copied exactly; the DB adds no endpoint, wire,
   --  credential, or retry policy.
   --  Conditional writes and whole/range reads use the buffer-owned Object
   --  Storage calls, which wait on the same caller-composable Scoped state
   --  machines and preserve their publication certainty. Rebinding is
   --  rejected.
   --  @param Item Context to bind exactly once
   --  @param Client Configured caller-owned HTTP client
   --  @param Origin Origin value matching Client configuration
   --  @param Identity Caller-owned signing credentials
   --  @param Bucket Existing bucket; Flyology.DB never creates it
   --  @param Prefix Validated database-root prefix within Bucket
   --  @param Region Exact SigV4 signing region
   --  @param Style Exact S3 addressing style
   --  @param Content_Type Exact immutable-object content type, empty to omit
   --  @param Expected_Bucket_Owner Optional owner precondition, empty to omit
   --  @param Request_Payer Exact requester-pays setting, empty to omit
   --  @param Checksum_Mode Whether reads request provider checksum headers
   --  @exception Program_Error Item is bound or Bucket or Prefix is invalid
   procedure Bind_Client
     (Item                  : in out Storage_Context;
      Client                : not null access Flyology.HTTP.Client.Client;
      Origin                : Flyology.HTTP.Origin;
      Identity              : not null access Flyology.Object_Storage.Client.Low_Level.Credentials;
      Bucket                : String;
      Prefix                : String;
      Region                : String;
      Style                 : Flyology.Object_Storage.Client.Low_Level.Addressing_Style;
      Content_Type          : String;
      Expected_Bucket_Owner : String;
      Request_Payer         : String;
      Checksum_Mode         : Boolean);

end Flyology.DB.Object_Storage;
