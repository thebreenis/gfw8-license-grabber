# Helper cleanup and game-data verification

GUI1.8.2/CLI1.4.2 log cleanup explicitly after token attempts. A confirmed result reads:

> Helper cleanup: complete (process stopped; session removed; temporary registration removed).

An unconfirmed result lists which component is unconfirmed. Missing token diagnostics produce an explicit unconfirmed status. These messages reach the GUI Activity stream and CLI activity output, including rejected token requests.

Game-data verification is a separate result. A supplied VAIO failure showed all helper cleanup flags true, but the pre-existing settings.dat differed from its pre-run snapshot. Version1.8.1 incorrectly grouped that data-preservation error with cleanup. Version1.8.2 separates registration cleanup from data verification in the lifecycle metadata and reports the data change independently.

When data verification fails, the app preserves current files alongside the existing before-copy even if Xbox did not issue a token. It does not automatically restore or overwrite game data. Failure to preserve the after-copy is reported explicitly. A successful token with a data alert remains distinct from an Xbox rejection or real cleanup failure.

Regression checks exercise a mocked SOAP rejection with successful cleanup, a separate simulated settings change, actual cleanup failure priority and delivery of cleanup status into the GUI Activity event stream. No live authentication or registration is required by these tests.
