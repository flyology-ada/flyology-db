package body Flyology.DB.Identity_Partition_Policy
  with SPARK_Mode => On
is

   function Contains (Values : Identity_Array; Item : Identity) return Boolean is
   begin
      for Value of Values loop
         if Value = Item then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   function Pairwise_Distinct (Values : Identity_Array) return Boolean is
   begin
      for Left in Values'Range loop
         for Right in Values'Range loop
            if Left < Right and then Values (Left) = Values (Right) then
               return False;
            end if;
         end loop;
      end loop;
      return True;
   end Pairwise_Distinct;

   function Valid_Partition
     (Reserved       : Identity_Array;
      Checkpoint     : Identity_Array;
      Batch_IDs      : Identity_Array;
      Member_IDs     : Identity_Array;
      Member_Batches : Batch_Index_Array;
      Allow_Aggregate_Leader_Alias : Boolean) return Boolean
   is
      --  Exactness distinguishes one from every malformed alternative;
      --  saturation at two avoids arithmetic overflow on corrupt input.
      function Recorded (Count : Natural) return Natural
      is (if Count < 2 then Count + 1 else Count);
   begin
      if not Pairwise_Distinct (Reserved) then
         return False;
      end if;
      for Item of Reserved loop
         if Item = Zero then
            return False;
         end if;
      end loop;

      if not Pairwise_Distinct (Checkpoint) then
         return False;
      end if;
      for Item of Checkpoint loop
         if Item = Zero or else not Contains (Reserved, Item) then
            return False;
         end if;
      end loop;

      for Batch_Index in Batch_IDs'Range loop
         declare
            Member_Total : Natural := 0;
            First_Member : Identity := Zero;
         begin
            if Batch_IDs (Batch_Index) = Zero or else not Contains (Reserved, Batch_IDs (Batch_Index)) then
               return False;
            end if;
            for Member_Index in Member_IDs'Range loop
               if Member_Batches (Member_Index) = Natural (Batch_Index) then
                  if Member_IDs (Member_Index) = Zero
                    or else not Contains (Reserved, Member_IDs (Member_Index))
                  then
                     return False;
                  elsif Member_Total = Natural'Last then
                     return False;
                  end if;
                  if Member_Total = 0 then
                     First_Member := Member_IDs (Member_Index);
                  end if;
                  Member_Total := Member_Total + 1;
               end if;
            end loop;
            if Member_Total = 0 then
               return False;
            elsif Member_Total = 1 then
               if Batch_IDs (Batch_Index) /= First_Member then
                  return False;
               end if;
            else
               for Member_Index in Member_IDs'Range loop
                  if Member_Batches (Member_Index) = Natural (Batch_Index)
                    and then Member_IDs (Member_Index) = Batch_IDs (Batch_Index)
                    and then
                      (not Allow_Aggregate_Leader_Alias
                       or else Member_IDs (Member_Index) /= First_Member)
                  then
                     return False;
                  end if;
               end loop;
            end if;
         end;
      end loop;

      for Member_Index in Member_IDs'Range loop
         if Member_Batches (Member_Index) not in Batch_IDs'Range then
            return False;
         end if;
      end loop;

      for Item of Reserved loop
         declare
            Occurrences : Natural := 0;
         begin
            for Checkpoint_Item of Checkpoint loop
               if Checkpoint_Item = Item then
                  Occurrences := Recorded (Occurrences);
               end if;
            end loop;
            for Batch_Index in Batch_IDs'Range loop
               declare
                  Member_Total : Natural := 0;
                  First_Member : Identity := Zero;
               begin
                  for Member_Index in Member_IDs'Range loop
                     if Member_Batches (Member_Index) = Natural (Batch_Index) then
                        if Member_Total < Natural'Last then
                           Member_Total := Member_Total + 1;
                        end if;
                        if First_Member = Zero then
                           First_Member := Member_IDs (Member_Index);
                        end if;
                     end if;
                  end loop;
                  if Batch_IDs (Batch_Index) = First_Member
                    and then
                      (Member_Total = 1 or else Allow_Aggregate_Leader_Alias)
                  then
                     for Member_Index in Member_IDs'Range loop
                        if Member_Batches (Member_Index) = Natural (Batch_Index)
                          and then Member_IDs (Member_Index) = Item
                        then
                           Occurrences := Recorded (Occurrences);
                        end if;
                     end loop;
                  else
                     if Batch_IDs (Batch_Index) = Item then
                        Occurrences := Recorded (Occurrences);
                     end if;
                     for Member_Index in Member_IDs'Range loop
                        if Member_Batches (Member_Index) = Natural (Batch_Index)
                          and then Member_IDs (Member_Index) = Item
                        then
                           Occurrences := Recorded (Occurrences);
                        end if;
                     end loop;
                  end if;
               end;
            end loop;
            if Occurrences /= 1 then
               return False;
            end if;
         end;
      end loop;

      return True;
   end Valid_Partition;

end Flyology.DB.Identity_Partition_Policy;
