with Ada.Strings.Unbounded;
with Flyology.Object_Storage;

package body Flyology.DB.Object_Storage is

   procedure Bind
     (Item    : in out Storage_Context;
      Backend : not null access Flyology.Object_Storage.Backends.Backend'Class;
      Bucket  : String;
      Prefix  : String)
   is
      Previous_Was_Slash : Boolean := False;
   begin
      if Item.Backend /= null then
         raise Program_Error with "storage context is already bound";
      elsif not Flyology.Object_Storage.Valid_Bucket_Name (Bucket) then
         raise Program_Error with "invalid object-storage bucket";
      elsif Prefix'Length = 0 or else Prefix (Prefix'First) = '/' or else Prefix (Prefix'Last) = '/' then
         raise Program_Error with "invalid database object prefix";
      end if;
      for Character of Prefix loop
         if Character = ASCII.NUL or else (Character = '/' and then Previous_Was_Slash) then
            raise Program_Error with "invalid database object prefix";
         end if;
         Previous_Was_Slash := Character = '/';
      end loop;
      declare
         Component_First : Positive := Prefix'First;
      begin
         for Index in Prefix'Range loop
            if Prefix (Index) = '/' then
               if Prefix (Component_First .. Index - 1) in "." | ".." then
                  raise Program_Error with "invalid database object prefix";
               end if;
               Component_First := Index + 1;
            end if;
         end loop;
         if Prefix (Component_First .. Prefix'Last) in "." | ".." then
            raise Program_Error with "invalid database object prefix";
         end if;
      end;
      if not Flyology.Object_Storage.Valid_Object_Key (Prefix & "/meta/HEAD")
        or else not Flyology.Object_Storage.Valid_Object_Key
                      (Prefix & "/commits/0123456789abcdef0123456789abcdef")
        or else not Flyology.Object_Storage.Valid_Object_Key
                      (Prefix & "/manifests/0123456789abcdef0123456789abcdef")
        or else not Flyology.Object_Storage.Valid_Object_Key
                      (Prefix & "/runs/0123456789abcdef0123456789abcdef")
      then
         raise Program_Error with "database object prefix is too long";
      end if;
      --  Bind records a caller-owned borrow; the public contract requires the
      --  backend to outlive every database using the context.
      Item.Backend := Backend.all'Unchecked_Access;
      Item.Bucket := Ada.Strings.Unbounded.To_Unbounded_String (Bucket);
      Item.Prefix := Ada.Strings.Unbounded.To_Unbounded_String (Prefix);
   end Bind;

end Flyology.DB.Object_Storage;
