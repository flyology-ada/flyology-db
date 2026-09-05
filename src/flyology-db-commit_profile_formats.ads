with Flyology.DB.Commit_Profiles;
with Flyology.DB.LSM_Formats;
with Interfaces;

--  Selects the exact manifest version and header width for each persisted
--  commit-publication profile. It defines no runtime cohort geometry.

private package Flyology.DB.Commit_Profile_Formats
  with SPARK_Mode => On
is

   package Commit_Profiles renames Flyology.DB.Commit_Profiles;
   package LSM renames Flyology.DB.LSM_Formats;

   use type Commit_Profiles.Commit_Publication_Profile;
   use type Interfaces.Unsigned_16;

   Experimental_Manifest_Format_Version : constant Interfaces.Unsigned_16 := 4;
   Experimental_Manifest_Header_Length  : constant := LSM.Checkpoint_Manifest_Header_Length + 4;

   function Manifest_Format_Version
     (Profile : Commit_Profiles.Commit_Publication_Profile) return Interfaces.Unsigned_16
   with
     Post =>
       (if Profile = Commit_Profiles.Standard_Publication
        then Manifest_Format_Version'Result = LSM.Checkpoint_Manifest_Format_Version
        else Manifest_Format_Version'Result = Experimental_Manifest_Format_Version);

   function Manifest_Header_Length (Profile : Commit_Profiles.Commit_Publication_Profile) return Natural
   with
     Post =>
       (if Profile = Commit_Profiles.Standard_Publication
        then Manifest_Header_Length'Result = LSM.Checkpoint_Manifest_Header_Length
        else Manifest_Header_Length'Result = Experimental_Manifest_Header_Length);

end Flyology.DB.Commit_Profile_Formats;
