-- Additional recovery guards; not the missing historical V003.
ALTER TABLE hrx.api_idempotency ADD CONSTRAINT safe_operation CHECK(operation ~ '^[a-z][a-z0-9_.:-]{2,95}$');
ALTER TABLE hrx.api_idempotency ADD CONSTRAINT safe_retry_key CHECK(idempotency_key ~ '^[A-Za-z0-9._:-]{8,128}$');
ALTER TABLE hrx.api_idempotency ADD CONSTRAINT object_response CHECK(jsonb_typeof(response_body)='object');
ALTER TABLE hrx.supply_demand ADD CONSTRAINT finite_demand_quantity CHECK(quantity<100000000000000);
ALTER TABLE hrx.controlled_file ADD CONSTRAINT recorded_scanner_revision CHECK(length(trim(scanner_revision)) BETWEEN 1 AND 240);
