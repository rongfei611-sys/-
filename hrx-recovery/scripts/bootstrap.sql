-- DBA only, a NEW disposable/recovery database. Never run against the lost baseline.
CREATE ROLE hrx_recovery_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE hrx_recovery_migrator LOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE hrx_recovery_app LOGIN NOSUPERUSER NOBYPASSRLS;
GRANT hrx_recovery_owner TO hrx_recovery_migrator;
DO $$ BEGIN EXECUTE format('GRANT CREATE ON DATABASE %I TO hrx_recovery_owner',current_database()); END $$;
