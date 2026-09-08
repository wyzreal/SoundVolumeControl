# Legacy transport regressions

These fixtures preserve coverage for Darwin POSIX shared-memory initialization
and cross-process audio bugs found before the authenticated transport.
`make ipc-test` builds them with `SVC_IPC_TESTING` and an isolated mapping name.
They are not linked into the production driver, helper, or broker.
Production IPC coverage lives in the `secure-*` tests in the parent directory.
