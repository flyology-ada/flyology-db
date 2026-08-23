with Ada.Text_IO;
with Flyology.DB.Batch_Format_Tests;
with Flyology.DB.Engine_Tests;
with Flyology.DB.Formats;
with Flyology.DB.Head_Policy;
with Flyology.DB.Reference_Model;
with Interfaces;

procedure Flyology.DB.Tests is
   use type Flyology.DB.Formats.Decode_Status;
   use type Flyology.DB.Formats.Byte_Array;
   use type Flyology.DB.Head_Policy.Reconciliation_Result;
   use type Flyology.DB.Head_Policy.Head_State;
   use type Flyology.DB.Head_Policy.Transition_Ordinal;
   use type Flyology.DB.Reference_Model.Result_Code;
   use type Flyology.DB.Reference_Model.Sequence_Number;
   use type Flyology.DB.Reference_Model.Value;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;

   package Head renames Flyology.DB.Head_Policy;
   package Formats renames Flyology.DB.Formats;
   package Model renames Flyology.DB.Reference_Model;

   function Model_Key (Text : String) return Model.Key is
      Result : Model.Key;
   begin
      if Text'Length > Model.Max_Key_Bytes then
         raise Constraint_Error with "reference-model key is too long";
      end if;
      Result.Length := Text'Length;
      for Offset in 0 .. Text'Length - 1 loop
         Result.Bytes (Model.Key_Byte_Index (Offset + 1)) :=
           Formats.Byte (Character'Pos (Text (Text'First + Offset)));
      end loop;
      return Result;
   end Model_Key;

   function Model_Value (Text : String) return Model.Value is
      Result : Model.Value;
   begin
      if Text'Length > Model.Max_Value_Bytes then
         raise Constraint_Error with "reference-model value is too long";
      end if;
      Result.Length := Text'Length;
      for Offset in 0 .. Text'Length - 1 loop
         Result.Bytes (Model.Value_Byte_Index (Offset + 1)) :=
           Formats.Byte (Character'Pos (Text (Text'First + Offset)));
      end loop;
      return Result;
   end Model_Value;

   procedure Expect
     (Actual   : Model.Result_Code;
      Expected : Model.Result_Code;
      Context  : String)
   is
   begin
      if Actual /= Expected then
         raise Program_Error with Context;
      end if;
   end Expect;

   procedure Test_Reference_Model is
      Family_One : constant Model.Column_Family_ID := 1;
      Family_Two : constant Model.Column_Family_ID := 2;
      Key_A      : constant Model.Key := Model_Key ("a");
      Key_B      : constant Model.Key := Model_Key ("b");
      Key_C      : constant Model.Key := Model_Key ("c");
      Key_D      : constant Model.Key := Model_Key ("d");
      Key_Z      : constant Model.Key := Model_Key ("z");
      Value_One  : constant Model.Value := Model_Value ("one");
      Value_Two  : constant Model.Value := Model_Value ("two");
      Value_Three : constant Model.Value := Model_Value ("three");

      State       : Model.Database_State;
      First       : Model.Transaction;
      Second      : Model.Transaction;
      Reader      : Model.Transaction;
      Writer      : Model.Transaction;
      Data        : Model.Value;
      Result      : Model.Result_Code;
      Sequence    : Model.Sequence_Number;
   begin
      Model.Initialize (State);

      Model.Begin_Transaction (State, Model.Snapshot, First);
      Model.Put (First, Family_One, Key_A, Value_One, Result);
      Expect (Result, Model.Success, "initial put failed");
      Model.Get (State, First, Family_One, Key_A, Data, Result);
      Expect (Result, Model.Success, "transaction did not read its own write");
      if Data /= Value_One then
         raise Program_Error with "transaction returned the wrong buffered value";
      end if;
      Model.Commit (State, First, Sequence, Result);
      Expect (Result, Model.Success, "initial commit failed");
      if Sequence /= 1 or else Model.Highest_Sequence (State) /= 1 then
         raise Program_Error with "initial commit used the wrong sequence";
      end if;

      Model.Begin_Transaction (State, Model.Snapshot, Reader);
      Model.Begin_Transaction (State, Model.Snapshot, Writer);
      Model.Put (Writer, Family_One, Key_A, Value_Two, Result);
      Expect (Result, Model.Success, "snapshot writer put failed");
      Model.Commit (State, Writer, Sequence, Result);
      Expect (Result, Model.Success, "snapshot writer commit failed");
      Model.Get (State, Reader, Family_One, Key_A, Data, Result);
      Expect (Result, Model.Success, "fixed snapshot lost the old value");
      if Data /= Value_One then
         raise Program_Error with "fixed snapshot observed a later commit";
      end if;
      Model.Rollback (Reader, Result);
      Expect (Result, Model.Success, "fixed snapshot rollback failed");

      Model.Begin_Transaction (State, Model.Snapshot, First);
      Model.Begin_Transaction (State, Model.Snapshot, Second);
      Model.Put (First, Family_One, Key_B, Value_One, Result);
      Expect (Result, Model.Success, "first conflicting put failed");
      Model.Put (Second, Family_One, Key_B, Value_Two, Result);
      Expect (Result, Model.Success, "second conflicting put failed");
      Model.Commit (State, First, Sequence, Result);
      Expect (Result, Model.Success, "first conflicting commit failed");
      Model.Commit (State, Second, Sequence, Result);
      Expect (Result, Model.Conflict, "snapshot write/write conflict was accepted");
      if not Model.Is_Active (Second) then
         raise Program_Error with "conflicted transaction was consumed";
      end if;
      Model.Rollback (Second, Result);
      Expect (Result, Model.Success, "conflicted transaction rollback failed");

      Model.Begin_Transaction (State, Model.Serializable, Reader);
      Model.Get (State, Reader, Family_One, Key_C, Data, Result);
      Expect (Result, Model.Not_Found, "absent serializable point read was present");
      Model.Begin_Transaction (State, Model.Snapshot, Writer);
      Model.Put (Writer, Family_One, Key_C, Value_Three, Result);
      Expect (Result, Model.Success, "point-conflict writer put failed");
      Model.Commit (State, Writer, Sequence, Result);
      Expect (Result, Model.Success, "point-conflict writer commit failed");
      Model.Commit (State, Reader, Sequence, Result);
      Expect
        (Result, Model.Serialization_Failure,
         "serializable absent point read did not conflict with insertion");
      Model.Rollback (Reader, Result);
      Expect (Result, Model.Success, "point-conflicted transaction rollback failed");

      Model.Begin_Transaction (State, Model.Serializable, Reader);
      for Digit in Character range '0' .. '7' loop
         Model.Get (State, Reader, Family_One, Model_Key ("read-" & Digit), Data, Result);
         Expect (Result, Model.Not_Found, "serializable read-set fill unexpectedly found a key");
      end loop;
      Model.Put (Reader, Family_One, Model_Key ("own"), Value_Three, Result);
      Expect (Result, Model.Success, "serializable own-write put failed at read capacity");
      Model.Get (State, Reader, Family_One, Model_Key ("own"), Data, Result);
      Expect (Result, Model.Success, "read-set capacity prevented reading an own write");
      if Data /= Value_Three then
         raise Program_Error with "serializable own write returned the wrong value";
      end if;
      Model.Rollback (Reader, Result);
      Expect (Result, Model.Success, "own-write capacity transaction rollback failed");

      Model.Begin_Transaction (State, Model.Serializable, Reader);
      Model.Observe_Range
        (Reader, Family_One, True, Key_B, True, Key_D, Result);
      Expect (Result, Model.Success, "serializable range observation failed");
      Model.Begin_Transaction (State, Model.Snapshot, Writer);
      Model.Put (Writer, Family_One, Model_Key ("cc"), Value_One, Result);
      Expect (Result, Model.Success, "phantom writer put failed");
      Model.Commit (State, Writer, Sequence, Result);
      Expect (Result, Model.Success, "phantom writer commit failed");
      Model.Commit (State, Reader, Sequence, Result);
      Expect
        (Result, Model.Serialization_Failure,
         "serializable range did not conflict with an inserted phantom");
      Model.Rollback (Reader, Result);
      Expect (Result, Model.Success, "range-conflicted transaction rollback failed");

      Model.Begin_Transaction (State, Model.Serializable, Reader);
      Model.Observe_Range (Reader, Family_One, True, Key_B, True, Key_D, Result);
      Expect (Result, Model.Success, "first duplicate-range observation failed");
      Model.Observe_Range (Reader, Family_One, True, Key_B, True, Key_D, Result);
      Expect (Result, Model.Success, "duplicate range consumed capacity");
      Model.Observe_Range (Reader, Family_One, True, Key_A, True, Key_B, Result);
      Expect (Result, Model.Success, "second distinct range failed");
      Model.Observe_Range (Reader, Family_One, True, Key_D, True, Key_Z, Result);
      Expect (Result, Model.Success, "third distinct range failed");
      Model.Observe_Range (Reader, Family_One, False, Key_A, True, Key_A, Result);
      Expect (Result, Model.Success, "fourth distinct range failed");
      Model.Observe_Range (Reader, Family_One, True, Key_Z, False, Key_Z, Result);
      Expect (Result, Model.Capacity_Exceeded, "fifth distinct range exceeded no capacity");
      Model.Rollback (Reader, Result);
      Expect (Result, Model.Success, "range-capacity transaction rollback failed");

      Model.Begin_Transaction (State, Model.Serializable, Reader);
      Model.Observe_Range
        (Reader, Family_One, True, Key_B, True, Key_D, Result);
      Expect (Result, Model.Success, "independent range observation failed");
      Model.Begin_Transaction (State, Model.Snapshot, Writer);
      Model.Put (Writer, Family_One, Key_Z, Value_One, Result);
      Expect (Result, Model.Success, "outside-range writer put failed");
      Model.Commit (State, Writer, Sequence, Result);
      Expect (Result, Model.Success, "outside-range writer commit failed");
      Model.Commit (State, Reader, Sequence, Result);
      Expect (Result, Model.Success, "outside-range write caused a false conflict");

      Model.Begin_Transaction (State, Model.Snapshot, Writer);
      Model.Put (Writer, Family_Two, Key_A, Value_Three, Result);
      Expect (Result, Model.Success, "second-family put failed");
      Model.Delete (Writer, Family_One, Key_A, Result);
      Expect (Result, Model.Success, "delete failed");
      Model.Get (State, Writer, Family_One, Key_A, Data, Result);
      Expect (Result, Model.Not_Found, "transaction did not read its own tombstone");
      Model.Commit (State, Writer, Sequence, Result);
      Expect (Result, Model.Success, "cross-family commit failed");

      Model.Begin_Transaction (State, Model.Snapshot, Reader);
      Model.Get (State, Reader, Family_One, Key_A, Data, Result);
      Expect (Result, Model.Not_Found, "committed tombstone was ignored");
      Model.Get (State, Reader, Family_Two, Key_A, Data, Result);
      Expect (Result, Model.Success, "second-family value was not committed atomically");
      if Data /= Value_Three then
         raise Program_Error with "second-family value was corrupted";
      end if;
      Model.Rollback (Reader, Result);
      Expect (Result, Model.Success, "final reader rollback failed");
   end Test_Reference_Model;

   function ID (Last : Interfaces.Unsigned_8) return Head.Identifier is
      Result : Head.Identifier := [others => 0];
   begin
      Result (Result'Last) := Last;
      return Result;
   end ID;

   Initial : constant Head.Head_State :=
     (Database_ID            => ID (1),
      Version                => Head.Current_Format,
      Epoch                  => 1,
      Highest_Visible        => 0,
      Latest_Batch           => Head.Zero_Identifier,
      Latest_Manifest        => Head.Zero_Identifier,
      Transition_ID          => ID (2),
      Predecessor_Transition => Head.Zero_Identifier,
      Transition_Number      => 1);

   Committed : constant Head.Head_State :=
     (Database_ID            => Initial.Database_ID,
      Version                => Initial.Version,
      Epoch                  => Initial.Epoch,
      Highest_Visible        => 2,
      Latest_Batch           => ID (3),
      Latest_Manifest        => Initial.Latest_Manifest,
      Transition_ID          => ID (4),
      Predecessor_Transition => Initial.Transition_ID,
      Transition_Number      => 2);

   Acquired : constant Head.Head_State :=
     (Database_ID            => Initial.Database_ID,
      Version                => Initial.Version,
      Epoch                  => 2,
      Highest_Visible        => 0,
      Latest_Batch           => Head.Zero_Identifier,
      Latest_Manifest        => Initial.Latest_Manifest,
      Transition_ID          => ID (5),
      Predecessor_Transition => Initial.Transition_ID,
      Transition_Number      => 2);

   CRC_Vector : constant Formats.Byte_Array (0 .. 8) :=
     [Character'Pos ('1'), Character'Pos ('2'), Character'Pos ('3'),
      Character'Pos ('4'), Character'Pos ('5'), Character'Pos ('6'),
      Character'Pos ('7'), Character'Pos ('8'), Character'Pos ('9')];

   Image          : constant Formats.Head_Image := Formats.Encode_Head (Committed);
   Acquired_Image : constant Formats.Head_Image := Formats.Encode_Head (Acquired);
   Corrupt     : Formats.Head_Image := Image;
   Decoded     : Head.Head_State;
   Decode_Code : Formats.Decode_Status;

   Golden : constant Formats.Head_Image :=
     [16#46#, 16#4C#, 16#59#, 16#48#, 16#45#, 16#41#, 16#44#, 16#31#,
      16#00#, 16#01#, 16#01#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#01#, 16#00#, 16#00#, 16#00#, 16#84#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#41#, 16#72#, 16#F4#, 16#64#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#01#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#02#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#03#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#04#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#02#, 16#00#, 16#00#, 16#00#, 16#00#,
      16#00#, 16#00#, 16#00#, 16#02#, 16#5C#, 16#C0#, 16#62#, 16#B9#];

   procedure Put_U32
     (Item     : in out Formats.Head_Image;
      Position : Formats.Head_Image_Index;
      Value    : Interfaces.Unsigned_32)
   is
   begin
      for Offset in Natural range 0 .. 3 loop
         Item (Position + Offset) :=
           Formats.Byte (Interfaces.Shift_Right (Value, (3 - Offset) * 8) and 16#FF#);
      end loop;
   end Put_U32;

   procedure Repair_Checksums (Item : in out Formats.Head_Image) is
   begin
      Item (40 .. 43) := [others => 0];
      Put_U32 (Item, 40, Formats.CRC_32C (Item (0 .. 131)));
      Put_U32 (Item, 132, Formats.CRC_32C (Item (0 .. 131)));
   end Repair_Checksums;

   procedure Expect_Decode
     (Item     : Formats.Byte_Array;
      Expected : Formats.Decode_Status;
      Context  : String)
   is
      Value  : Head.Head_State;
      Status : Formats.Decode_Status;
   begin
      Formats.Decode_Head (Item, Initial.Database_ID, Value, Status);
      if Status /= Expected then
         raise Program_Error with Context;
      end if;
   end Expect_Decode;
begin
   if not Flyology.DB.Experimental then
      raise Program_Error with "Flyology.DB experimental identity is false";
   end if;

   if not Head.Valid_Initial (Initial) then
      raise Program_Error with "initial head was rejected";
   end if;

   if not Head.Valid_Commit (Initial, Committed, ID (3), 2) then
      raise Program_Error with "valid commit transition was rejected";
   end if;

   if not Head.Valid_Writer_Acquisition (Initial, Acquired) then
      raise Program_Error with "valid writer acquisition was rejected";
   end if;

   if Image /= Golden then
      raise Program_Error with "head encoding differs from the independent golden image";
   end if;

   if Head.Reconcile (Initial.Transition_ID, Committed.Transition_ID,
                      Committed.Transition_Number, True,
                      Committed.Transition_ID, Initial.Transition_ID,
                      Committed.Transition_Number)
     /= Head.Publication_Confirmed
   then
      raise Program_Error with "exact attempted transition was not confirmed";
   end if;

   if Head.Reconcile (Initial.Transition_ID, Committed.Transition_ID,
                      Committed.Transition_Number, True, ID (5),
                      Initial.Transition_ID, Committed.Transition_Number)
     /= Head.Precondition_Lost
   then
      raise Program_Error with "sibling transition did not lose the precondition";
   end if;

   if Head.Reconcile (Initial.Transition_ID, Committed.Transition_ID,
                      Committed.Transition_Number, False,
                      Head.Zero_Identifier, Head.Zero_Identifier, Committed.Transition_Number)
     /= Head.Outcome_Unknown
   then
      raise Program_Error with "unavailable inspection did not remain unknown";
   end if;

   if Head.Reconcile (Initial.Transition_ID, Committed.Transition_ID,
                      Committed.Transition_Number, True,
                      Committed.Transition_ID, ID (9), Committed.Transition_Number + 1)
     /= Head.Outcome_Unknown
   then
      raise Program_Error with "a reused transition ID at another ordinal was falsely confirmed";
   end if;

   if Head.Reconcile (Initial.Transition_ID, Committed.Transition_ID,
                      Committed.Transition_Number, True,
                      ID (9), Committed.Transition_ID, Committed.Transition_Number + 1)
     /= Head.Publication_Confirmed
   then
      raise Program_Error with "an exact successor did not confirm publication";
   end if;

   if Formats.CRC_32C (CRC_Vector) /= 16#E306_9283# then
      raise Program_Error with "CRC-32C check vector failed";
   end if;

   Formats.Decode_Head (Image, Initial.Database_ID, Decoded, Decode_Code);
   if Decode_Code /= Formats.Decoded or else Decoded /= Committed then
      raise Program_Error with "encoded head did not round-trip";
   end if;

   Formats.Decode_Head (Acquired_Image, Initial.Database_ID, Decoded, Decode_Code);
   if Decode_Code /= Formats.Decoded or else Decoded /= Acquired then
      raise Program_Error with "writer-acquisition head did not round-trip";
   end if;

   for Length in Natural range 0 .. Formats.Head_Image_Length - 1 loop
      declare
         Short : Formats.Byte_Array (1 .. Length);
      begin
         for Offset in Natural range 0 .. Length - 1 loop
            Short (Offset + 1) := Image (Offset);
         end loop;
         Expect_Decode (Short, Formats.Invalid_Length, "truncated head was not rejected");
      end;
   end loop;

   declare
      Long : Formats.Byte_Array (0 .. Formats.Head_Image_Length) := [others => 0];
   begin
      Long (0 .. Image'Last) := Image;
      Expect_Decode (Long, Formats.Invalid_Length, "head with trailing bytes was not rejected");
   end;

   Corrupt := Image;
   Corrupt (0) := Corrupt (0) xor 1;
   Expect_Decode (Corrupt, Formats.Invalid_Magic, "invalid magic was not rejected");

   Corrupt := Image;
   Corrupt (9) := 2;
   Expect_Decode (Corrupt, Formats.Unsupported_Version, "unknown version was not rejected");

   Corrupt := Image;
   Corrupt (10) := 2;
   Expect_Decode (Corrupt, Formats.Invalid_Object_Kind, "wrong object kind was not rejected");

   Corrupt := Image;
   Corrupt (11) := 1;
   Expect_Decode (Corrupt, Formats.Invalid_Flags, "unknown flags were not rejected");

   Corrupt := Image;
   Corrupt (31) := Corrupt (31) xor 1;
   Expect_Decode (Corrupt, Formats.Invalid_Length, "wrong header length was not rejected");

   Corrupt := Image;
   Corrupt (39) := 1;
   Expect_Decode (Corrupt, Formats.Invalid_Length, "nonzero payload length was not rejected");

   Corrupt := Image;
   Corrupt (40) := Corrupt (40) xor 1;
   Expect_Decode (Corrupt, Formats.Header_Checksum_Failed, "bad header checksum was not rejected");

   Corrupt (52) := Corrupt (52) xor 1;
   Formats.Decode_Head (Corrupt, Initial.Database_ID, Decoded, Decode_Code);
   if Decode_Code /= Formats.Header_Checksum_Failed then
      raise Program_Error with "header corruption was not rejected";
   end if;

   Corrupt := Image;
   Corrupt (Corrupt'Last) := Corrupt (Corrupt'Last) xor 1;
   Formats.Decode_Head (Corrupt, Initial.Database_ID, Decoded, Decode_Code);
   if Decode_Code /= Formats.Object_Checksum_Failed then
      raise Program_Error with "object checksum corruption was not rejected";
   end if;

   Corrupt := Image;
   Corrupt (44 .. 51) := [others => 0];
   Repair_Checksums (Corrupt);
   Expect_Decode (Corrupt, Formats.Invalid_Head_State, "zero writer epoch was not rejected");

   Corrupt := Image;
   Corrupt (108 .. 123) := [others => 0];
   Repair_Checksums (Corrupt);
   Expect_Decode (Corrupt, Formats.Invalid_Head_State, "noninitial zero predecessor was not rejected");

   Corrupt := Image;
   Corrupt (92 .. 107) := Corrupt (108 .. 123);
   Repair_Checksums (Corrupt);
   Expect_Decode (Corrupt, Formats.Invalid_Head_State, "transition reused its predecessor identity");

   Corrupt := Image;
   Corrupt (124 .. 131) := [others => 0];
   Repair_Checksums (Corrupt);
   Expect_Decode (Corrupt, Formats.Invalid_Head_State, "zero transition ordinal was not rejected");

   Corrupt := Image;
   Corrupt (131) := 1;
   Repair_Checksums (Corrupt);
   Expect_Decode (Corrupt, Formats.Invalid_Head_State, "noninitial head used the initial ordinal");

   Corrupt := Image;
   Corrupt (52 .. 59) := [others => 0];
   Repair_Checksums (Corrupt);
   Expect_Decode (Corrupt, Formats.Invalid_Head_State, "zero sequence retained a batch reference");

   Corrupt := Image;
   Corrupt (60 .. 75) := [others => 0];
   Repair_Checksums (Corrupt);
   Expect_Decode (Corrupt, Formats.Invalid_Head_State, "nonzero sequence lost its batch reference");

   Formats.Decode_Head (Image, ID (9), Decoded, Decode_Code);
   if Decode_Code /= Formats.Wrong_Database then
      raise Program_Error with "wrong database identity was not rejected";
   end if;

   Test_Reference_Model;
   Flyology.DB.Batch_Format_Tests.Run;
   Flyology.DB.Engine_Tests.Run;

   Ada.Text_IO.Put_Line ("Flyology.DB formats, policy, model, and local log engine: OK");
end Flyology.DB.Tests;
