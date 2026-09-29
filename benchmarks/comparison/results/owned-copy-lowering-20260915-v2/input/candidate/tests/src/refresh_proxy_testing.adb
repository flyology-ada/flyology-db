with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.HTTP.Server;

package body Refresh_Proxy_Testing is
   package Characters renames Ada.Characters.Handling;
   package HTTP_Server renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;
   package US renames Ada.Strings.Unbounded;

   use type Ada.Streams.Stream_Element_Offset;
   use type Sockets.Port;
   use type Sockets.Selector_Status;

   CRLF                       : constant String := Character'Val (13) & Character'Val (10);
   --  The proxy accepts exactly the public Flyology.HTTP server request-head
   --  ceiling. This is a derived transport compatibility bound, not DB policy.
   Maximum_Request_Head_Bytes : constant Positive := HTTP_Server.Max_Header_Bytes;
   --  This matches the maintained Object Storage raw-socket corpus chunk. It
   --  bounds fixture relay memory only and has no product buffering meaning.
   Relay_Buffer_Bytes         : constant Positive := 4_096;
   --  The serial fixture polls only so Stop can join the Ada task promptly;
   --  this is test shutdown responsiveness, not network retry policy.
   Accept_Poll_Timeout        : constant Duration := 0.1;

   type Observed_Request_Phase is (Other_Request, Observed_Whole_Get, Observed_Head, Observed_Range_Get);

   type Proxy_Stage is
     (Starting, Idle, Reading_Request, Connecting_Upstream, Reading_Response, Holding_Request, Stopped);

   function Matches (Observed : Observed_Request_Phase; Armed : Refresh_Request_Phase) return Boolean
   is (case Observed is
         when Observed_Whole_Get => Armed = Whole_Get_Request,
         when Observed_Head      => Armed = Head_Request,
         when Observed_Range_Get => Armed = Range_Get_Request,
         when Other_Request      => False);

   function Refresh_Phase (Observed : Observed_Request_Phase) return Refresh_Request_Phase
   is (case Observed is
         when Observed_Whole_Get => Whole_Get_Request,
         when Observed_Head      => Head_Request,
         when Observed_Range_Get => Range_Get_Request,
         when Other_Request      => raise Program_Error);

   protected Controller is
      procedure Publish (Port : Sockets.Port);
      entry Wait_Ready (Port : out Sockets.Port);
      procedure Arm (Phase : Refresh_Request_Phase);
      procedure Observe (Phase : Observed_Request_Phase; Should_Block : out Boolean);
      procedure Observation_Snapshot
        (Count         : out Natural;
         Phase         : out Observed_Request_Phase;
         Armed_State   : out Boolean;
         Blocked_State : out Boolean;
         Armed_After   : out Natural;
         Stage         : out Proxy_Stage);
      procedure Set_Stage (Stage : Proxy_Stage);
      entry Wait_Blocked (Phase : out Refresh_Request_Phase);
      procedure Release_Blocked;
      entry Wait_Release;
      procedure Clear_Block;
      entry Wait_Unblocked;
      procedure Request_Stop;
      function Stopping return Boolean;
      procedure Complete (Passed : Boolean; Detail : String := "");
      entry Wait_Done (Passed : out Boolean; Detail : out US.Unbounded_String);
   private
      Ready             : Boolean := False;
      Listen_Port       : Sockets.Port := Sockets.Any_Port;
      Armed             : Boolean := False;
      Armed_Phase       : Refresh_Request_Phase := Whole_Get_Request;
      Blocked           : Boolean := False;
      Blocked_Phase     : Refresh_Request_Phase := Whole_Get_Request;
      Released          : Boolean := False;
      Stop_Requested    : Boolean := False;
      Done              : Boolean := False;
      Passed_Value      : Boolean := False;
      Detail_Value      : US.Unbounded_String;
      Observed_Count    : Natural := 0;
      Last_Observed     : Observed_Request_Phase := Other_Request;
      Armed_After_Count : Natural := 0;
      Current_Stage     : Proxy_Stage := Starting;
   end Controller;

   protected body Controller is
      procedure Publish (Port : Sockets.Port) is
      begin
         Listen_Port := Port;
         Ready := True;
      end Publish;

      entry Wait_Ready (Port : out Sockets.Port) when Ready or Done is
      begin
         if not Ready then
            raise Program_Error with "refresh proxy failed before readiness: " & US.To_String (Detail_Value);
         end if;
         Port := Listen_Port;
      end Wait_Ready;

      procedure Arm (Phase : Refresh_Request_Phase) is
      begin
         if Done then
            raise Program_Error with "refresh proxy is not running: " & US.To_String (Detail_Value);
         elsif Armed or else Blocked then
            raise Program_Error with "refresh proxy already has an armed request";
         end if;
         Armed_Phase := Phase;
         Armed := True;
         Armed_After_Count := Observed_Count;
      end Arm;

      procedure Observe (Phase : Observed_Request_Phase; Should_Block : out Boolean) is
      begin
         Observed_Count := Observed_Count + 1;
         Last_Observed := Phase;
         Should_Block := Armed and then Matches (Phase, Armed_Phase);
         if Should_Block then
            Armed := False;
            Blocked := True;
            Blocked_Phase := Refresh_Phase (Phase);
            Released := False;
            Current_Stage := Holding_Request;
         end if;
      end Observe;

      procedure Observation_Snapshot
        (Count         : out Natural;
         Phase         : out Observed_Request_Phase;
         Armed_State   : out Boolean;
         Blocked_State : out Boolean;
         Armed_After   : out Natural;
         Stage         : out Proxy_Stage) is
      begin
         Count := Observed_Count;
         Phase := Last_Observed;
         Armed_State := Armed;
         Blocked_State := Blocked;
         Armed_After := Armed_After_Count;
         Stage := Current_Stage;
      end Observation_Snapshot;

      procedure Set_Stage (Stage : Proxy_Stage) is
      begin
         Current_Stage := Stage;
      end Set_Stage;

      entry Wait_Blocked (Phase : out Refresh_Request_Phase) when Blocked or Done is
      begin
         if not Blocked then
            raise Program_Error with "refresh proxy stopped before blocking: " & US.To_String (Detail_Value);
         end if;
         Phase := Blocked_Phase;
      end Wait_Blocked;

      procedure Release_Blocked is
      begin
         if Blocked then
            Released := True;
         end if;
      end Release_Blocked;

      entry Wait_Release when Released or Stop_Requested is
      begin
         null;
      end Wait_Release;

      procedure Clear_Block is
      begin
         Blocked := False;
         Released := False;
      end Clear_Block;

      entry Wait_Unblocked when not Blocked or Done is
      begin
         if Done and then not Passed_Value then
            raise Program_Error with "refresh proxy failed while releasing: " & US.To_String (Detail_Value);
         end if;
      end Wait_Unblocked;

      procedure Request_Stop is
      begin
         Stop_Requested := True;
         Released := True;
      end Request_Stop;

      function Stopping return Boolean
      is (Stop_Requested);

      procedure Complete (Passed : Boolean; Detail : String := "") is
      begin
         Passed_Value := Passed;
         Detail_Value := US.To_Unbounded_String (Detail);
         Done := True;
         Armed := False;
         Released := True;
         Current_Stage := Stopped;
      end Complete;

      entry Wait_Done (Passed : out Boolean; Detail : out US.Unbounded_String) when Done is
      begin
         Passed := Passed_Value;
         Detail := Detail_Value;
      end Wait_Done;
   end Controller;

   Configured_Upstream : Sockets.Port := Sockets.Any_Port;
   Configured_Timeout  : Duration := 0.0;

   task type Proxy_Task is
      pragma Task_Info (Flyology.Native_Task);
   end Proxy_Task;

   type Proxy_Task_Access is access Proxy_Task;
   procedure Free_Proxy_Task is new Ada.Unchecked_Deallocation (Proxy_Task, Proxy_Task_Access);
   Worker     : Proxy_Task_Access := null;
   Is_Started : Boolean := False;

   function Bytes (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Value'Length));
   begin
      for Offset in Natural range 0 .. Value'Length - 1 loop
         Result (Result'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Ada.Streams.Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Text
     (Value : Ada.Streams.Stream_Element_Array; Last : Ada.Streams.Stream_Element_Offset) return String
   is
      Result : String (1 .. Natural (Last - Value'First + 1));
   begin
      for Offset in Result'Range loop
         Result (Offset) :=
           Character'Val (Value (Value'First + Ada.Streams.Stream_Element_Offset (Offset - 1)));
      end loop;
      return Result;
   end Text;

   function Content_Length (Header : String) return Natural is
      Lower    : constant String := Characters.To_Lower (Header);
      Marker   : constant String := CRLF & "content-length:";
      Position : constant Natural := Ada.Strings.Fixed.Index (Lower, Marker);
      First    : Natural;
      Last     : Natural;
   begin
      if Position = 0 then
         return 0;
      end if;
      First := Position + Marker'Length;
      Last := Ada.Strings.Fixed.Index (Lower, CRLF, From => First) - 1;
      if Last < First then
         raise Program_Error with "refresh proxy received malformed Content-Length";
      end if;
      return Natural'Value (Ada.Strings.Fixed.Trim (Header (First .. Last), Ada.Strings.Both));
   end Content_Length;

   function With_Connection_Close (Header : String) return String is
      Result   : US.Unbounded_String;
      Position : Natural := Header'First;
      Line_End : Natural;
   begin
      loop
         Line_End := Ada.Strings.Fixed.Index (Header, CRLF, From => Position);
         if Line_End = 0 then
            raise Program_Error with "refresh proxy received an unterminated HTTP head";
         elsif Line_End = Position then
            exit;
         end if;
         declare
            Line : constant String := Header (Position .. Line_End - 1);
         begin
            if Ada.Strings.Fixed.Index (Characters.To_Lower (Line), "connection:") /= Line'First then
               US.Append (Result, Line);
               US.Append (Result, CRLF);
            end if;
         end;
         Position := Line_End + CRLF'Length;
      end loop;
      US.Append (Result, "Connection: close" & CRLF & CRLF);
      return US.To_String (Result);
   end With_Connection_Close;

   function Classify (Header : String) return Observed_Request_Phase is
      Lower : constant String := Characters.To_Lower (Header);
   begin
      if Ada.Strings.Fixed.Index (Lower, "head ") = Header'First then
         return Observed_Head;
      elsif Ada.Strings.Fixed.Index (Lower, "get ") = Header'First
        and then Ada.Strings.Fixed.Index (Lower, CRLF & "range:") /= 0
      then
         return Observed_Range_Get;
      elsif Ada.Strings.Fixed.Index (Lower, "get ") = Header'First then
         return Observed_Whole_Get;
      else
         return Other_Request;
      end if;
   end Classify;

   procedure Close_Quietly (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_Quietly;

   task body Proxy_Task is
      Listener : Sockets.Socket_Type;

      procedure Relay (Peer : in out Sockets.Socket_Type) is
         Upstream      : Sockets.Socket_Type;
         Head          :
           Ada.Streams.Stream_Element_Array
             (1 .. Ada.Streams.Stream_Element_Offset (Maximum_Request_Head_Bytes));
         Chunk         :
           Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Relay_Buffer_Bytes));
         Head_Last     : Ada.Streams.Stream_Element_Offset := Head'First - 1;
         Received_Last : Ada.Streams.Stream_Element_Offset;
         Separator     : Natural := 0;
         Should_Block  : Boolean;
      begin
         Controller.Set_Stage (Reading_Request);
         loop
            if Head_Last = Head'Last then
               raise Program_Error with "refresh proxy request head exceeds the HTTP bound";
            end if;
            Sockets.Receive
              (Peer, Head (Head_Last + 1 .. Head'Last), Received_Last, Timeout => Configured_Timeout);
            if Received_Last < Head_Last + 1 then
               raise Program_Error with "refresh proxy peer closed before request head";
            end if;
            Head_Last := Received_Last;
            Separator := Ada.Strings.Fixed.Index (Text (Head, Head_Last), CRLF & CRLF);
            exit when Separator /= 0;
         end loop;

         declare
            Request_Text : constant String := Text (Head, Head_Last);
            Header_Last  : constant Natural := Separator + 3;
            Header       : constant String := Request_Text (Request_Text'First .. Header_Last);
            Body_Length  : constant Natural := Content_Length (Header);
            Extra_First  : constant Natural := Header_Last + 1;
            Extra_Length : constant Natural := Request_Text'Last - Header_Last;
            Phase        : constant Observed_Request_Phase := Classify (Header);
         begin
            if Ada.Strings.Fixed.Index (Characters.To_Lower (Header), CRLF & "transfer-encoding:") /= 0 then
               raise Program_Error with "refresh proxy does not admit chunked request bodies";
            elsif Extra_Length > Body_Length then
               raise Program_Error with "refresh proxy received pipelined request bytes";
            end if;

            Controller.Observe (Phase, Should_Block);
            if Should_Block then
               Controller.Wait_Release;
               Controller.Clear_Block;
               return;
            end if;

            Controller.Set_Stage (Connecting_Upstream);
            Sockets.Create_Socket (Upstream);
            Sockets.Connect_Socket
              (Upstream, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Configured_Upstream));

            Sockets.Send_All
              (Upstream, Bytes (With_Connection_Close (Header)), Timeout => Configured_Timeout);

            if Extra_Length > 0 then
               Sockets.Send_All
                 (Upstream,
                  Head (Head'First + Ada.Streams.Stream_Element_Offset (Extra_First - 1) .. Head_Last),
                  Timeout => Configured_Timeout);
            end if;

            declare
               Remaining : Natural := Body_Length - Extra_Length;
            begin
               while Remaining > 0 loop
                  declare
                     Count : constant Positive := Positive'Min (Remaining, Relay_Buffer_Bytes);
                  begin
                     Sockets.Receive
                       (Peer,
                        Chunk (Chunk'First .. Chunk'First + Ada.Streams.Stream_Element_Offset (Count - 1)),
                        Received_Last,
                        Timeout => Configured_Timeout);
                     if Received_Last < Chunk'First then
                        raise Program_Error with "refresh proxy peer closed during request body";
                     end if;
                     Sockets.Send_All
                       (Upstream, Chunk (Chunk'First .. Received_Last), Timeout => Configured_Timeout);
                     Remaining := Remaining - Natural (Received_Last - Chunk'First + 1);
                  end;
               end loop;
            end;

            Controller.Set_Stage (Reading_Response);
            Head_Last := Head'First - 1;
            Separator := 0;
            loop
               if Head_Last = Head'Last then
                  raise Program_Error with "refresh proxy response head exceeds the HTTP bound";
               end if;
               Sockets.Receive
                 (Upstream, Head (Head_Last + 1 .. Head'Last), Received_Last, Timeout => Configured_Timeout);
               if Received_Last < Head_Last + 1 then
                  raise Program_Error with "refresh proxy upstream closed before response head";
               end if;
               Head_Last := Received_Last;
               Separator := Ada.Strings.Fixed.Index (Text (Head, Head_Last), CRLF & CRLF);
               exit when Separator /= 0;
            end loop;

            declare
               Response_Text : constant String := Text (Head, Head_Last);
               Header_Last   : constant Natural := Separator + 3;
               Header        : constant String := Response_Text (Response_Text'First .. Header_Last);
               Lower_Header  : constant String := Characters.To_Lower (Header);
               No_Body       : constant Boolean :=
                 Phase = Observed_Head
                 or else Ada.Strings.Fixed.Index (Lower_Header, "http/1.1 1") = Header'First
                 or else Ada.Strings.Fixed.Index (Lower_Header, "http/1.1 204 ") = Header'First
                 or else Ada.Strings.Fixed.Index (Lower_Header, "http/1.1 304 ") = Header'First;
               Body_Length   : constant Natural := (if No_Body then 0 else Content_Length (Header));
               Extra_First   : constant Natural := Header_Last + 1;
               Extra_Length  : constant Natural := Response_Text'Last - Header_Last;
            begin
               if Ada.Strings.Fixed.Index (Lower_Header, CRLF & "transfer-encoding:") /= 0 then
                  raise Program_Error with "refresh proxy does not admit chunked responses";
               elsif Extra_Length > Body_Length then
                  raise Program_Error with "refresh proxy received bytes beyond the response body";
               end if;

               Sockets.Send_All (Peer, Bytes (With_Connection_Close (Header)), Timeout => Configured_Timeout);

               if Extra_Length > 0 then
                  Sockets.Send_All
                    (Peer,
                     Head (Head'First + Ada.Streams.Stream_Element_Offset (Extra_First - 1) .. Head_Last),
                     Timeout => Configured_Timeout);
               end if;

               declare
                  Remaining : Natural := Body_Length - Extra_Length;
               begin
                  while Remaining > 0 loop
                     declare
                        Count : constant Positive := Positive'Min (Remaining, Relay_Buffer_Bytes);
                     begin
                        Sockets.Receive
                          (Upstream,
                           Chunk (Chunk'First .. Chunk'First + Ada.Streams.Stream_Element_Offset (Count - 1)),
                           Received_Last,
                           Timeout => Configured_Timeout);
                        if Received_Last < Chunk'First then
                           raise Program_Error with "refresh proxy upstream closed during response body";
                        end if;
                        Sockets.Send_All
                          (Peer, Chunk (Chunk'First .. Received_Last), Timeout => Configured_Timeout);
                        Remaining := Remaining - Natural (Received_Last - Chunk'First + 1);
                     end;
                  end loop;
               end;
            end;
            Controller.Set_Stage (Idle);
         end;
         Close_Quietly (Upstream);
      exception
         when others =>
            Close_Quietly (Upstream);
            raise;
      end Relay;

      Peer    : Sockets.Socket_Type;
      Address : Sockets.Endpoint;
      Status  : Sockets.Selector_Status;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      --  One pending connection is the exact geometry of the serial client
      --  probe; this backlog is not a server or DB capacity recommendation.
      Sockets.Listen_Socket (Listener, Length => 1);
      Controller.Publish (Sockets.Get_Socket_Name (Listener).Port);
      Controller.Set_Stage (Idle);

      while not Controller.Stopping loop
         Sockets.Accept_Socket
           (Listener,
            Peer,
            Address,
            Timeout => Duration'Min (Accept_Poll_Timeout, Configured_Timeout),
            Status  => Status);
         if Status = Sockets.Completed then
            begin
               Relay (Peer);
            exception
               when Error : others =>
                  Close_Quietly (Peer);
                  raise Program_Error with Ada.Exceptions.Exception_Information (Error);
            end;
            Close_Quietly (Peer);
         end if;
      end loop;
      Close_Quietly (Listener);
      Controller.Complete (True);
   exception
      when Error : others =>
         Close_Quietly (Peer);
         Close_Quietly (Listener);
         Controller.Complete (False, Ada.Exceptions.Exception_Information (Error));
   end Proxy_Task;

   procedure Start (Upstream_Port : Sockets.Port; Failure_Timeout : Duration; Listen_Port : out Sockets.Port)
   is
   begin
      if Is_Started then
         raise Program_Error with "refresh proxy is already started";
      elsif Upstream_Port = Sockets.Any_Port then
         raise Constraint_Error with "refresh proxy upstream port must be nonzero";
      elsif Failure_Timeout <= 0.0 then
         raise Constraint_Error with "refresh proxy failure timeout must be positive";
      end if;
      Configured_Upstream := Upstream_Port;
      Configured_Timeout := Failure_Timeout;
      Is_Started := True;
      Worker := new Proxy_Task;
      Controller.Wait_Ready (Listen_Port);
   exception
      when others =>
         if Worker = null then
            Is_Started := False;
         end if;
         raise;
   end Start;

   procedure Arm (Phase : Refresh_Request_Phase) is
   begin
      if not Is_Started then
         raise Program_Error with "refresh proxy is not started";
      end if;
      Controller.Arm (Phase);
   end Arm;

   procedure Wait_Blocked (Phase : Refresh_Request_Phase; Timeout : Duration) is
      Actual      : Refresh_Request_Phase;
      Count       : Natural;
      Last        : Observed_Request_Phase;
      Armed       : Boolean;
      Blocked     : Boolean;
      Armed_After : Natural;
      Stage       : Proxy_Stage;
   begin
      if Timeout <= 0.0 then
         raise Constraint_Error with "refresh proxy wait timeout must be positive";
      end if;
      select
         Controller.Wait_Blocked (Actual);
      or
         delay Timeout;
         Controller.Observation_Snapshot (Count, Last, Armed, Blocked, Armed_After, Stage);
         raise Program_Error
           with
             "refresh proxy did not observe "
             & Refresh_Request_Phase'Image (Phase)
             & "; observed"
             & Natural'Image (Count)
             & " requests, last="
             & Observed_Request_Phase'Image (Last)
             & ", armed="
             & Boolean'Image (Armed)
             & ", blocked="
             & Boolean'Image (Blocked)
             & ", arm-after="
             & Natural'Image (Armed_After)
             & ", stage="
             & Proxy_Stage'Image (Stage);
      end select;
      if Actual /= Phase then
         raise Program_Error with "refresh proxy blocked the wrong request phase";
      end if;
   end Wait_Blocked;

   procedure Release_Blocked is
   begin
      if Is_Started then
         Controller.Release_Blocked;
         select
            Controller.Wait_Unblocked;
         or
            delay Configured_Timeout;
            raise Program_Error with "refresh proxy did not release the blocked request";
         end select;
      end if;
   end Release_Blocked;

   procedure Stop is
      Passed : Boolean;
      Detail : US.Unbounded_String;
   begin
      if not Is_Started then
         return;
      end if;
      Controller.Request_Stop;
      select
         Controller.Wait_Done (Passed, Detail);
      or
         delay Configured_Timeout;
         raise Program_Error with "refresh proxy task did not stop";
      end select;
      Is_Started := False;
      Free_Proxy_Task (Worker);
      if not Passed then
         raise Program_Error with "refresh proxy failed: " & US.To_String (Detail);
      end if;
   end Stop;

end Refresh_Proxy_Testing;
