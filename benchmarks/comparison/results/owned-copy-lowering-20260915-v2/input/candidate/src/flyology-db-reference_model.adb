package body Flyology.DB.Reference_Model
  with SPARK_Mode => On
is

   use type Formats.Byte;

   function Equal (Left, Right : Key) return Boolean is
   begin
      if Left.Length /= Right.Length then
         return False;
      end if;

      for Index in Key_Byte_Index range 1 .. Left.Length loop
         if Left.Bytes (Index) /= Right.Bytes (Index) then
            return False;
         end if;
      end loop;
      return True;
   end Equal;

   function Less (Left, Right : Key) return Boolean is
      --  Derived exact common prefix; no separate comparison bound is chosen.
      Shared : constant Key_Length := Key_Length'Min (Left.Length, Right.Length);
   begin
      for Index in Key_Byte_Index range 1 .. Shared loop
         if Left.Bytes (Index) < Right.Bytes (Index) then
            return True;
         elsif Left.Bytes (Index) > Right.Bytes (Index) then
            return False;
         end if;
      end loop;
      return Left.Length < Right.Length;
   end Less;

   function Same_Key
     (Left_Family, Right_Family : Column_Family_ID;
      Left_Name, Right_Name     : Key) return Boolean
   is (Left_Family = Right_Family and then Equal (Left_Name, Right_Name));

   function Inside (Name : Key; Predicate : Scan_Range) return Boolean is
     ((not Predicate.Has_Lower or else not Less (Name, Predicate.Lower))
      and then (not Predicate.Has_Upper or else Less (Name, Predicate.Upper)));

   function Ranges_Connect (Left, Right : Scan_Range) return Boolean
   is (Left.Family = Right.Family
       and then (not Left.Has_Upper or else not Right.Has_Lower or else not Less (Left.Upper, Right.Lower))
       and then (not Right.Has_Upper or else not Left.Has_Lower or else not Less (Right.Upper, Left.Lower)));

   procedure Initialize (State : out Database_State) is
   begin
      State := (others => <>);
   end Initialize;

   procedure Begin_Transaction
     (State : Database_State;
      Mode  : Isolation_Level;
      Item  : out Transaction)
   is
   begin
      Item := (others => <>);
      Item.Active := True;
      Item.Mode := Mode;
      Item.Snapshot_At := State.Highest;
   end Begin_Transaction;

   procedure Buffer_Mutation
     (Item    : in out Transaction;
      Family  : Column_Family_ID;
      Name    : Key;
      Data    : Value;
      Deleted : Boolean;
      Result  : out Result_Code)
   is
   begin
      if not Item.Active then
         Result := Invalid_Transaction;
         return;
      end if;

      for Index in Mutation_Index range 1 .. Item.Mutation_Total loop
         if Same_Key (Item.Mutations (Index).Family, Family, Item.Mutations (Index).Name, Name) then
            Item.Mutations (Index).Data := Data;
            Item.Mutations (Index).Deleted := Deleted;
            Result := Success;
            return;
         end if;
      end loop;

      if Item.Mutation_Total = Max_Mutations then
         Result := Capacity_Exceeded;
         return;
      end if;

      Item.Mutation_Total := Item.Mutation_Total + 1;
      Item.Mutations (Item.Mutation_Total) :=
        (Family => Family, Name => Name, Data => Data, Deleted => Deleted);
      Result := Success;
   end Buffer_Mutation;

   procedure Put
     (Item   : in out Transaction;
      Family : Column_Family_ID;
      Name   : Key;
      Data   : Value;
      Result : out Result_Code)
   is
   begin
      Buffer_Mutation (Item, Family, Name, Data, False, Result);
   end Put;

   procedure Delete
     (Item   : in out Transaction;
      Family : Column_Family_ID;
      Name   : Key;
      Result : out Result_Code)
   is
   begin
      Buffer_Mutation (Item, Family, Name, (others => <>), True, Result);
   end Delete;

   procedure Record_Point
     (Item   : in out Transaction;
      Family : Column_Family_ID;
      Name   : Key;
      Result : out Result_Code)
   is
   begin
      if Item.Mode = Snapshot then
         Result := Success;
         return;
      end if;

      for Index in Point_Read_Index range 1 .. Item.Point_Total loop
         if Same_Key (Item.Point_Reads (Index).Family, Family, Item.Point_Reads (Index).Name, Name) then
            Result := Success;
            return;
         end if;
      end loop;

      if Item.Point_Total = Max_Point_Reads then
         Result := Capacity_Exceeded;
         return;
      end if;

      Item.Point_Total := Item.Point_Total + 1;
      Item.Point_Reads (Item.Point_Total) := (Family => Family, Name => Name);
      Result := Success;
   end Record_Point;

   procedure Get
     (State  : Database_State;
      Item   : in out Transaction;
      Family : Column_Family_ID;
      Name   : Key;
      Data   : out Value;
      Result : out Result_Code)
   is
      Point_Result : Result_Code;
      Found        : Boolean := False;
      Chosen       : Sequence_Number := 0;
   begin
      Data := (others => <>);
      if not Item.Active then
         Result := Invalid_Transaction;
         return;
      end if;

      if Item.Mutation_Total > 0 then
         for Index in reverse Mutation_Index range 1 .. Item.Mutation_Total loop
            if Same_Key (Item.Mutations (Index).Family, Family, Item.Mutations (Index).Name, Name) then
               if Item.Mutations (Index).Deleted then
                  Result := Not_Found;
               else
                  Data := Item.Mutations (Index).Data;
                  Result := Success;
               end if;
               return;
            end if;
         end loop;
      end if;

      Record_Point (Item, Family, Name, Point_Result);
      if Point_Result /= Success then
         Result := Point_Result;
         return;
      end if;

      for Index in Version_Index range 1 .. State.Count loop
         if State.Versions (Index).Sequence <= Item.Snapshot_At
           and then Same_Key (State.Versions (Index).Family, Family, State.Versions (Index).Name, Name)
           and then (not Found or else State.Versions (Index).Sequence > Chosen)
         then
            Found := True;
            Chosen := State.Versions (Index).Sequence;
            if State.Versions (Index).Deleted then
               Data := (others => <>);
            else
               Data := State.Versions (Index).Data;
            end if;
         end if;
      end loop;

      if not Found then
         Result := Not_Found;
      else
         for Index in reverse Version_Index range 1 .. State.Count loop
            if State.Versions (Index).Sequence = Chosen
              and then Same_Key (State.Versions (Index).Family, Family, State.Versions (Index).Name, Name)
            then
               if State.Versions (Index).Deleted then
                  Result := Not_Found;
               else
                  Data := State.Versions (Index).Data;
                  Result := Success;
               end if;
               return;
            end if;
         end loop;
         Result := Not_Found;
      end if;
   end Get;

   procedure Observe_Range
     (Item      : in out Transaction;
      Family    : Column_Family_ID;
      Has_Lower : Boolean;
      Lower     : Key;
      Has_Upper : Boolean;
      Upper     : Key;
      Result    : out Result_Code)
   is
      --  Max_Ranges passes are derived from the complete bounded oracle
      --  predicate array: every pass can add at least one previously separate
      --  component, so no independent retry or normalization policy is chosen.
      Candidate         : Scan_Range :=
        (Family => Family, Has_Lower => Has_Lower, Lower => Lower, Has_Upper => Has_Upper, Upper => Upper);
      Replacement       : Scan_Range_Array := [others => <>];
      Replacement_Total : Range_Count := 0;
      Expanded          : Boolean;
   begin
      if not Item.Active then
         Result := Invalid_Transaction;
         return;
      elsif Has_Lower and then Has_Upper and then not Less (Lower, Upper) then
         Result := Invalid_Range;
         return;
      elsif Item.Mode = Snapshot then
         Result := Success;
         return;
      end if;

      for Pass in Range_Index loop
         Expanded := False;
         for Index in Range_Index range 1 .. Item.Range_Total loop
            if Ranges_Connect (Item.Ranges (Index), Candidate) then
               if Candidate.Has_Lower and then not Item.Ranges (Index).Has_Lower then
                  Candidate.Has_Lower := False;
                  Expanded := True;
               elsif Candidate.Has_Lower
                 and then Item.Ranges (Index).Has_Lower
                 and then Less (Item.Ranges (Index).Lower, Candidate.Lower)
               then
                  Candidate.Lower := Item.Ranges (Index).Lower;
                  Expanded := True;
               end if;
               if Candidate.Has_Upper and then not Item.Ranges (Index).Has_Upper then
                  Candidate.Has_Upper := False;
                  Expanded := True;
               elsif Candidate.Has_Upper
                 and then Item.Ranges (Index).Has_Upper
                 and then Less (Candidate.Upper, Item.Ranges (Index).Upper)
               then
                  Candidate.Upper := Item.Ranges (Index).Upper;
                  Expanded := True;
               end if;
            end if;
         end loop;
         exit when not Expanded or else Pass = Range_Index'Last;
      end loop;

      for Index in Range_Index range 1 .. Item.Range_Total loop
         if not Ranges_Connect (Item.Ranges (Index), Candidate) then
            if Replacement_Total = Max_Ranges then
               Result := Capacity_Exceeded;
               return;
            end if;
            Replacement_Total := Replacement_Total + 1;
            Replacement (Replacement_Total) := Item.Ranges (Index);
         end if;
      end loop;

      if Replacement_Total = Max_Ranges then
         Result := Capacity_Exceeded;
         return;
      end if;

      Replacement_Total := Replacement_Total + 1;
      Replacement (Replacement_Total) := Candidate;
      Item.Ranges := Replacement;
      Item.Range_Total := Replacement_Total;
      Result := Success;
   end Observe_Range;

   function Conflicts
     (State : Database_State;
      Item  : Transaction) return Boolean
   is
   begin
      for Version_Position in Version_Index range 1 .. State.Count loop
         if State.Versions (Version_Position).Sequence > Item.Snapshot_At then
            for Mutation_Position in Mutation_Index range 1 .. Item.Mutation_Total loop
               if Same_Key
                    (State.Versions (Version_Position).Family,
                     Item.Mutations (Mutation_Position).Family,
                     State.Versions (Version_Position).Name,
                     Item.Mutations (Mutation_Position).Name)
               then
                  return True;
               end if;
            end loop;

            if Item.Mode = Serializable then
               for Point_Position in Point_Read_Index range 1 .. Item.Point_Total loop
                  if Same_Key
                       (State.Versions (Version_Position).Family,
                        Item.Point_Reads (Point_Position).Family,
                        State.Versions (Version_Position).Name,
                        Item.Point_Reads (Point_Position).Name)
                  then
                     return True;
                  end if;
               end loop;

               for Range_Position in Range_Index range 1 .. Item.Range_Total loop
                  if State.Versions (Version_Position).Family = Item.Ranges (Range_Position).Family
                    and then Inside
                      (State.Versions (Version_Position).Name, Item.Ranges (Range_Position))
                  then
                     return True;
                  end if;
               end loop;
            end if;
         end if;
      end loop;
      return False;
   end Conflicts;

   procedure Commit
     (State    : in out Database_State;
      Item     : in out Transaction;
      Sequence : out Sequence_Number;
      Result   : out Result_Code)
   is
   begin
      Sequence := 0;
      if not Item.Active then
         Result := Invalid_Transaction;
         return;
      elsif Conflicts (State, Item) then
         if Item.Mode = Snapshot then
            Result := Conflict;
         else
            Result := Serialization_Failure;
         end if;
         return;
      elsif Item.Mutation_Total = 0 then
         Sequence := State.Highest;
         Item := (others => <>);
         Result := Success;
         return;
      elsif State.Count > Max_Versions - Item.Mutation_Total then
         Result := Capacity_Exceeded;
         return;
      elsif State.Highest = Sequence_Number'Last then
         Result := Sequence_Exhausted;
         return;
      end if;

      Sequence := State.Highest + 1;
      for Index in Mutation_Index range 1 .. Item.Mutation_Total loop
         State.Count := State.Count + 1;
         State.Versions (State.Count) :=
           (Family   => Item.Mutations (Index).Family,
            Name     => Item.Mutations (Index).Name,
            Data     => Item.Mutations (Index).Data,
            Sequence => Sequence,
            Deleted  => Item.Mutations (Index).Deleted);
      end loop;
      State.Highest := Sequence;
      Item := (others => <>);
      Result := Success;
   end Commit;

   procedure Rollback (Item : in out Transaction; Result : out Result_Code) is
   begin
      if not Item.Active then
         Result := Invalid_Transaction;
      else
         Item := (others => <>);
         Result := Success;
      end if;
   end Rollback;

   function Highest_Sequence (State : Database_State) return Sequence_Number is
     (State.Highest);

   function Is_Active (Item : Transaction) return Boolean is (Item.Active);

end Flyology.DB.Reference_Model;
