with Flyology.IO.Sockets;

--  Provides a bounded task-based TCP proxy for deterministic replica-refresh
--  cancellation and deadline tests. It is linked only into the test crate.

package Refresh_Proxy_Testing is

   --  Provider request phase that the proxy can hold before forwarding.
   type Refresh_Request_Phase is (Whole_Get_Request, Head_Request, Range_Get_Request);

   --  Start one serial loopback proxy to Upstream_Port. Failure_Timeout bounds
   --  every fixture socket operation and coordination wait.
   procedure Start
     (Upstream_Port   : Flyology.IO.Sockets.Port;
      Failure_Timeout : Duration;
      Listen_Port     : out Flyology.IO.Sockets.Port);

   --  Arm the next request whose method/header shape identifies Phase.
   procedure Arm (Phase : Refresh_Request_Phase);

   --  Wait until the armed request has reached the proxy and is held there.
   procedure Wait_Blocked (Phase : Refresh_Request_Phase; Timeout : Duration);

   --  Release and close the currently held request. This is idempotent when
   --  no request is held so exception cleanup can call it safely.
   procedure Release_Blocked;

   --  Stop the proxy and wait for its sole Ada task to terminate.
   procedure Stop;

end Refresh_Proxy_Testing;
