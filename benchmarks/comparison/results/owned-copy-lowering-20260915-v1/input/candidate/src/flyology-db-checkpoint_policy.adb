package body Flyology.DB.Checkpoint_Policy
  with SPARK_Mode => On
is

   function Decide
     (Current_Runs       : Run_Count_Array;
      Maximum_Runs       : Run_Count_Array;
      Changed            : Family_Flag_Array;
      Nonempty           : Family_Flag_Array;
      Checkpoint_Dirty   : Boolean;
      Maximum_Total_Runs : Interfaces.Unsigned_32) return Selection
   is
      use type Interfaces.Unsigned_32;
      use type Interfaces.Unsigned_64;

      Current_Total  : Interfaces.Unsigned_64 := 0;
      Changed_Total  : Interfaces.Unsigned_64 := 0;
      Nonempty_Total : Interfaces.Unsigned_64 := 0;
      Valid          : Boolean := Maximum_Total_Runs /= 0;
      Additive_Fits  : Boolean := True;
   begin
      for Index in Current_Runs'Range loop
         if Maximum_Runs (Index) = 0 or else Current_Runs (Index) > Maximum_Runs (Index) then
            Valid := False;
         end if;

         if Current_Total > Interfaces.Unsigned_64'Last - Interfaces.Unsigned_64 (Current_Runs (Index)) then
            Valid := False;
         else
            Current_Total := Current_Total + Interfaces.Unsigned_64 (Current_Runs (Index));
         end if;

         if Changed (Index) then
            if Changed_Total = Interfaces.Unsigned_64'Last then
               Valid := False;
            else
               Changed_Total := Changed_Total + 1;
            end if;
            if Current_Runs (Index) >= Maximum_Runs (Index) then
               Additive_Fits := False;
            end if;
         end if;

         if Nonempty (Index) then
            if Nonempty_Total = Interfaces.Unsigned_64'Last then
               Valid := False;
            else
               Nonempty_Total := Nonempty_Total + 1;
            end if;
         end if;
      end loop;

      if Current_Total > Interfaces.Unsigned_64 (Maximum_Total_Runs) then
         Valid := False;
      end if;

      if not Valid then
         return Invalid_Authority;
      elsif not Checkpoint_Dirty then
         return No_Work;
      end if;

      Additive_Fits :=
        Additive_Fits and then Changed_Total <= Interfaces.Unsigned_64 (Maximum_Total_Runs) - Current_Total;
      if Additive_Fits then
         return Additive_Flush;
      elsif Nonempty_Total <= Interfaces.Unsigned_64 (Maximum_Total_Runs) then
         return Complete_Compaction;
      else
         return No_Admissible_Checkpoint;
      end if;
   end Decide;

end Flyology.DB.Checkpoint_Policy;
