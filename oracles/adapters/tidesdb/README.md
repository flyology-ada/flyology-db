# TidesDB adapter

Pin upstream to `23a67a6531bc6c0b537d3696758c7879586dcfce`. The adapter uses a SHA-coupled Python `ctypes`
boundary, unified WAL/memtable mode, full sync, and no compression. It is never labeled remotely durable and rejects
serializable scan-phantom workloads. See `docs/compatibility/tidesdb.md` for the audited matrix.
