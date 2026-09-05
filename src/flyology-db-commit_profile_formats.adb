package body Flyology.DB.Commit_Profile_Formats
  with SPARK_Mode => On
is

   function Manifest_Format_Version
     (Profile : Commit_Profiles.Commit_Publication_Profile) return Interfaces.Unsigned_16
   is (if Profile = Commit_Profiles.Standard_Publication
       then LSM.Checkpoint_Manifest_Format_Version
       else Experimental_Manifest_Format_Version);

   function Manifest_Header_Length (Profile : Commit_Profiles.Commit_Publication_Profile) return Natural
   is (if Profile = Commit_Profiles.Standard_Publication
       then LSM.Checkpoint_Manifest_Header_Length
       else Experimental_Manifest_Header_Length);

end Flyology.DB.Commit_Profile_Formats;
