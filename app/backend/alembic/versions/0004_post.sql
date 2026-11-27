SET ROLE sjv_owner;

GRANT UPDATE (status)
ON ingest_receipts
TO sjv_collector;

RESET ROLE;
