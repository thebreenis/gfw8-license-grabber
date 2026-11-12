# Receipt identity check consistency

GUI1.8.0 and CLI1.4.0 fix a local token preflight error exposed by PAC-MAN Championship Edition DX+ for VAIO.

The receipt validator already accepts the selected catalogue edition's package family name or legacy Store GUID as its signed AppId. The token controller previously always expected the package family name. A valid GUID-based receipt therefore failed with `Wrong receipt identity` before any Xbox exchange.

The controller now reads the signed AppId without modifying the receipt, checks it against the same edition's catalogue PFN/GUID, and forwards that exact identity to the exchange driver. The driver retains its exact identity, Full-license and independent Microsoft signature checks. Other editions are rejected. Package identity, Xbox title ID, installed-game restrictions and helper cleanup behavior are unchanged.

Thirteen offline regression checks cover PFN/GUID variants, wrong-edition rejection, unchanged receipt bytes, controller arguments and mocked cleanup. An unsigned receipt with the correct GUID reaches signature validation and is rejected. No real package registration or Xbox request was performed; later service acceptance remains unverified for the friend's receipt.

Shipped runtime paths now use `backend/runtime/xbox-auth/AcquireXboxToken.ps1`, `XboxTokenWorker.ps1` and `receipt-support`, instead of research labels. The build maps existing source paths into product-facing runtime names. Source history and evidence paths remain stable. These naming changes do not conceal technical diagnostic logs or alter authentication behavior.
