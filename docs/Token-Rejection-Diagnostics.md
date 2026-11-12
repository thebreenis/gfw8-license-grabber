# VAIO token rejection and diagnostic formatting

The supplied GUI1.8.0 report reaches `stage=xbox-response` with the intended VAIO package family, title1313676123 and signed receipt GUID. This confirms the earlier local PFN/GUID guard was passed. It does not demonstrate a successful token exchange.

HTTP200 carries a SOAP Sender fault with X-Err0x8015DA87, no explanatory Reason and `tokenIssued=false`. `helperStopped`, `privateSessionRemoved` and `helperRegistrationRemoved` are all true: this report confirms cleanup. The account-name lookup failed and `accountComparison` is null, so the report does not establish receipt-account/ticket-account equality. The precise service rejection cause remains unresolved. An earlier Toshiba trace also returned0x8015DA87; that is a comparison, not proof of a common cause.

GUI1.8.1/CLI1.4.1 distinguish Xbox rejection from helper cleanup or data-preservation failure. The outer token controller now captures child stdout/stderr directly instead of passing stderr through PowerShell's native error formatter. Expected failure messages use plain stderr; detailed exception information remains in a separate private diagnostic log. No retry, account change, receipt rewrite or network behavior was added.

Offline checks cover receipt identity consistency, wrong-edition and unsigned-receipt rejection, mocked SOAP denial with successful cleanup, cleanup-failure priority, and raw child capture without NativeCommandError formatting. These tests do not resolve the service rejection or claim a successful VAIO token.
