CREATE TABLE hrx.controlled_file (
 file_id uuid PRIMARY KEY,document_id uuid NOT NULL,version integer NOT NULL CHECK(version>0),
 demand_id uuid NOT NULL REFERENCES hrx.supply_demand,original_name text NOT NULL CHECK(length(original_name) BETWEEN 1 AND 240),
 byte_size bigint NOT NULL CHECK(byte_size BETWEEN 0 AND 10485760),sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'),
 scan_status text NOT NULL CHECK(scan_status IN ('CLEAN','INFECTED','SCAN_FAILED')),scanner_revision text NOT NULL,
 uploaded_by uuid NOT NULL REFERENCES hrx.user_account,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(document_id,version)
);
CREATE FUNCTION hrx.file_allowed(p_demand uuid,p_action text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM supply_demand d WHERE d.demand_id=p_demand AND hrx.allowed(d.project_id,'supply_chain','read') AND hrx.allowed(d.project_id,'controlled_file',p_action))
$$;
CREATE FUNCTION hrx.guard_file() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE previous controlled_file%ROWTYPE;
BEGIN
 IF NEW.uploaded_by IS DISTINCT FROM hrx.current_user_id() OR NOT hrx.file_allowed(NEW.demand_id,'create') THEN RAISE EXCEPTION 'File upload denied' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(NEW.document_id::text||':version',0));
 SELECT * INTO previous FROM controlled_file WHERE document_id=NEW.document_id ORDER BY version DESC LIMIT 1;
 IF NEW.version<>COALESCE(previous.version,0)+1 THEN RAISE EXCEPTION 'File version changed' USING ERRCODE='40001';END IF;
 IF previous.file_id IS NOT NULL AND previous.demand_id<>NEW.demand_id THEN RAISE EXCEPTION 'Cannot move a file to another object' USING ERRCODE='42501';END IF;
 NEW.created_at:=clock_timestamp();RETURN NEW;
END $$;
CREATE TRIGGER file_create BEFORE INSERT ON hrx.controlled_file FOR EACH ROW EXECUTE FUNCTION hrx.guard_file();
ALTER TABLE hrx.controlled_file ENABLE ROW LEVEL SECURITY;
CREATE POLICY file_read ON hrx.controlled_file FOR SELECT USING(hrx.file_allowed(demand_id,'read'));
CREATE POLICY file_append ON hrx.controlled_file FOR INSERT WITH CHECK(uploaded_by=hrx.current_user_id() AND hrx.file_allowed(demand_id,'create'));
REVOKE ALL ON FUNCTION hrx.file_allowed(uuid,text),hrx.guard_file() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.file_allowed(uuid,text) TO hrx_recovery_app;
GRANT SELECT,INSERT ON hrx.controlled_file TO hrx_recovery_app;
