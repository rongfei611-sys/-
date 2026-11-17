-- NEW recovery schema, not a replacement for the missing original V001.
CREATE SCHEMA IF NOT EXISTS hrx AUTHORIZATION hrx_recovery_owner;
REVOKE ALL ON SCHEMA hrx FROM PUBLIC;
GRANT USAGE ON SCHEMA hrx TO hrx_recovery_app;
CREATE TABLE hrx.user_account (
 user_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),idp_subject text NOT NULL UNIQUE,
 display_name text NOT NULL,org_unit_code text,job_title text,
 active boolean NOT NULL DEFAULT false
);
CREATE TABLE hrx.business_project (
 project_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),project_code text NOT NULL UNIQUE,
 project_name text NOT NULL,org_unit_code text NOT NULL
);
CREATE TABLE hrx.capability_grant (
 grant_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid NOT NULL REFERENCES hrx.user_account,
 project_id uuid NOT NULL REFERENCES hrx.business_project,resource_type text NOT NULL,action_code text NOT NULL,
 enabled boolean NOT NULL DEFAULT false,approved_by uuid REFERENCES hrx.user_account,approved_at timestamptz,
 valid_from timestamptz NOT NULL DEFAULT now(),valid_until timestamptz,
 CHECK(approved_by IS NULL OR approved_by<>user_id),
 CHECK(NOT enabled OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
 CHECK(valid_until IS NULL OR valid_until>valid_from)
);
CREATE FUNCTION hrx.current_user_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT user_id FROM user_account WHERE active AND idp_subject=NULLIF(current_setting('hrx.oidc_subject',true),'')
$$;
CREATE FUNCTION hrx.user_allowed(p_user uuid,p_project uuid,p_resource text,p_action text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM capability_grant g JOIN user_account u ON u.user_id=g.user_id AND u.active
 WHERE g.user_id=p_user AND g.project_id=p_project AND g.resource_type=p_resource AND g.action_code=p_action
 AND g.enabled AND g.approved_by IS NOT NULL AND g.approved_at IS NOT NULL AND g.valid_from<=now() AND (g.valid_until IS NULL OR g.valid_until>now()))
$$;
REVOKE ALL ON FUNCTION hrx.user_allowed(uuid,uuid,text,text) FROM PUBLIC;
CREATE FUNCTION hrx.allowed(p_project uuid,p_resource text,p_action text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$ SELECT hrx.user_allowed(hrx.current_user_id(),p_project,p_resource,p_action) $$;
CREATE FUNCTION hrx.capabilities() RETURNS TABLE(resource_type text,action_code text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT DISTINCT g.resource_type,g.action_code FROM capability_grant g WHERE hrx.user_allowed(hrx.current_user_id(),g.project_id,g.resource_type,g.action_code) AND g.user_id=hrx.current_user_id()
$$;
ALTER TABLE hrx.user_account ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_self ON hrx.user_account FOR SELECT USING(user_id=hrx.current_user_id());
ALTER TABLE hrx.business_project ENABLE ROW LEVEL SECURITY;
CREATE POLICY project_reference ON hrx.business_project FOR SELECT USING(hrx.allowed(project_id,'supply_chain','read') OR hrx.allowed(project_id,'supply_chain','create'));
ALTER TABLE hrx.capability_grant ENABLE ROW LEVEL SECURITY;
CREATE POLICY grant_self ON hrx.capability_grant FOR SELECT USING(user_id=hrx.current_user_id());
CREATE TABLE hrx.audit_event (
 event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),actor_user_id uuid NOT NULL REFERENCES hrx.user_account,
 action_code text NOT NULL,resource_id uuid NOT NULL,metadata jsonb NOT NULL DEFAULT '{}',occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE hrx.audit_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_append ON hrx.audit_event FOR INSERT WITH CHECK(actor_user_id=hrx.current_user_id());
CREATE TABLE hrx.api_idempotency (
 actor_user_id uuid NOT NULL REFERENCES hrx.user_account,operation text NOT NULL,idempotency_key text NOT NULL,
 request_hash text NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),response_body jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(actor_user_id,operation,idempotency_key)
);
ALTER TABLE hrx.api_idempotency ENABLE ROW LEVEL SECURITY;
CREATE POLICY retry_read ON hrx.api_idempotency FOR SELECT USING(actor_user_id=hrx.current_user_id());
CREATE POLICY retry_append ON hrx.api_idempotency FOR INSERT WITH CHECK(actor_user_id=hrx.current_user_id());
CREATE FUNCTION hrx.valid_evidence_refs(p_refs jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN jsonb_typeof(p_refs)='array' THEN jsonb_array_length(p_refs)<=50 AND NOT EXISTS(
 SELECT 1 FROM jsonb_array_elements(p_refs) e WHERE jsonb_typeof(e)<>'string' OR length(e#>>'{}') NOT BETWEEN 10 AND 510 OR (e#>>'{}') !~ '^hrx-file:[A-Za-z0-9][A-Za-z0-9/_-]*$') ELSE false END
$$;
CREATE TABLE hrx.supply_demand (
 demand_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),project_id uuid NOT NULL REFERENCES hrx.business_project,
 bom_line text NOT NULL CHECK(length(trim(bom_line)) BETWEEN 1 AND 80),material_code text NOT NULL CHECK(length(trim(material_code)) BETWEEN 1 AND 120),
 description text NOT NULL CHECK(length(trim(description)) BETWEEN 2 AND 1000),unit text NOT NULL CHECK(length(trim(unit)) BETWEEN 1 AND 20),
 quantity numeric(18,4) NOT NULL CHECK(quantity>0),required_date date NOT NULL,lead_time_days integer NOT NULL CHECK(lead_time_days BETWEEN 0 AND 3650),critical_path boolean NOT NULL DEFAULT false,
 requested_by uuid NOT NULL REFERENCES hrx.user_account,buyer_user_id uuid NOT NULL REFERENCES hrx.user_account,
 revision integer NOT NULL DEFAULT 0,current_status text NOT NULL DEFAULT 'DRAFT',sourcing_round integer NOT NULL DEFAULT 0,
 approved_quote_id uuid,po_number text,promised_date date,
 received_qty numeric(18,4) NOT NULL DEFAULT 0,accepted_qty numeric(18,4) NOT NULL DEFAULT 0,rejected_qty numeric(18,4) NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(project_id,bom_line),
 CHECK(current_status IN ('DRAFT','SUBMITTED','SOURCING','APPROVED','ORDERED','PART_RECEIVED','RECEIVED','CLOSED','CANCELLED')),
 CHECK(received_qty BETWEEN 0 AND quantity AND accepted_qty>=0 AND rejected_qty>=0 AND accepted_qty+rejected_qty<=received_qty)
);
CREATE TABLE hrx.supply_event (
 event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),demand_id uuid NOT NULL REFERENCES hrx.supply_demand,
 expected_revision integer NOT NULL CHECK(expected_revision>=0),event_code text NOT NULL CHECK(event_code IN ('SUBMIT','OPEN_RFQ','QUOTE','APPROVE','REJECT','ISSUE_PO','PROMISE','RECEIVE','IQC','CANCEL')),
 sourcing_round integer NOT NULL DEFAULT 0,note text NOT NULL CHECK(length(trim(note)) BETWEEN 2 AND 4000),
 payload jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(payload)='object' AND octet_length(payload::text)<=16000),
 evidence_refs jsonb NOT NULL DEFAULT '[]' CHECK(hrx.valid_evidence_refs(evidence_refs)),actor_user_id uuid NOT NULL REFERENCES hrx.user_account,
 occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(demand_id,expected_revision)
);
ALTER TABLE hrx.supply_demand ADD FOREIGN KEY(approved_quote_id) REFERENCES hrx.supply_event;
CREATE INDEX supply_due ON hrx.supply_demand(project_id,required_date,demand_id);
CREATE INDEX supply_history ON hrx.supply_event(demand_id,expected_revision);
CREATE FUNCTION hrx.supply_visible(p_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM supply_demand d WHERE d.demand_id=p_id AND hrx.allowed(d.project_id,'supply_chain','read'))
$$;
CREATE FUNCTION hrx.supply_buyers(p_project uuid) RETURNS TABLE(user_id uuid,display_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
BEGIN
 IF NOT hrx.allowed(p_project,'supply_chain','create') THEN RAISE EXCEPTION 'Create denied' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT u.user_id,u.display_name FROM user_account u WHERE hrx.user_allowed(u.user_id,p_project,'supply_chain','update') ORDER BY u.display_name;
END $$;
CREATE FUNCTION hrx.guard_demand_create() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
BEGIN
 IF NEW.requested_by IS DISTINCT FROM hrx.current_user_id() OR NOT hrx.allowed(NEW.project_id,'supply_chain','create') OR NOT hrx.user_allowed(NEW.buyer_user_id,NEW.project_id,'supply_chain','update') THEN RAISE EXCEPTION 'Create or buyer denied' USING ERRCODE='42501'; END IF;
 IF NEW.revision<>0 OR NEW.current_status<>'DRAFT' OR NEW.sourcing_round<>0 OR NEW.approved_quote_id IS NOT NULL OR NEW.po_number IS NOT NULL OR NEW.promised_date IS NOT NULL OR NEW.received_qty<>0 OR NEW.accepted_qty<>0 OR NEW.rejected_qty<>0 THEN RAISE EXCEPTION 'Invalid initial state' USING ERRCODE='23514'; END IF;
 NEW.created_at:=clock_timestamp();RETURN NEW;
END $$;
CREATE TRIGGER demand_create BEFORE INSERT ON hrx.supply_demand FOR EACH ROW EXECUTE FUNCTION hrx.guard_demand_create();
CREATE FUNCTION hrx.guard_supply_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE d supply_demand%ROWTYPE;q supply_event%ROWTYPE;r supply_event%ROWTYPE;v_actor uuid;v_action text;v_qty numeric;v_ok numeric;v_bad numeric;v_date date;v_count integer;
BEGIN
 SELECT * INTO d FROM supply_demand WHERE demand_id=NEW.demand_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Missing demand' USING ERRCODE='23503';END IF;
 v_actor:=hrx.current_user_id();
 IF v_actor IS DISTINCT FROM NEW.actor_user_id OR NOT hrx.allowed(d.project_id,'supply_chain','read') THEN RAISE EXCEPTION 'Identity/read denied' USING ERRCODE='42501';END IF;
 IF NEW.expected_revision<>d.revision THEN RAISE EXCEPTION 'Revision changed' USING ERRCODE='40001';END IF;
 IF d.current_status IN ('CLOSED','CANCELLED') THEN RAISE EXCEPTION 'Terminal demand' USING ERRCODE='23514';END IF;
 v_action:=CASE WHEN NEW.event_code IN ('APPROVE','REJECT') OR (NEW.event_code='CANCEL' AND d.current_status IN ('APPROVED','ORDERED')) THEN 'approve' WHEN NEW.event_code='RECEIVE' THEN 'receive' WHEN NEW.event_code='IQC' THEN 'inspect' ELSE 'update' END;
 IF NOT hrx.allowed(d.project_id,'supply_chain',v_action) THEN RAISE EXCEPTION 'Action denied' USING ERRCODE='42501';END IF;
 IF v_action IN ('approve','receive','inspect') AND v_actor IN(d.requested_by,d.buyer_user_id) THEN RAISE EXCEPTION 'Independent actor required' USING ERRCODE='42501';END IF;
 IF v_action='update' AND v_actor NOT IN(d.requested_by,d.buyer_user_id) THEN RAISE EXCEPTION 'Owner required' USING ERRCODE='42501';END IF;
 IF NEW.event_code IN ('QUOTE','APPROVE') AND NOT hrx.allowed(d.project_id,'supply_chain','read_price') THEN RAISE EXCEPTION 'Confidential price denied' USING ERRCODE='42501';END IF;
 NEW.sourcing_round:=d.sourcing_round;NEW.occurred_at:=clock_timestamp();
 CASE NEW.event_code
 WHEN 'SUBMIT' THEN
  IF d.current_status<>'DRAFT' THEN RAISE EXCEPTION 'Draft required' USING ERRCODE='23514';END IF;d.current_status:='SUBMITTED';
 WHEN 'OPEN_RFQ' THEN
  IF d.current_status<>'SUBMITTED' THEN RAISE EXCEPTION 'Submitted required' USING ERRCODE='23514';END IF;d.current_status:='SOURCING';d.sourcing_round:=d.sourcing_round+1;NEW.sourcing_round:=d.sourcing_round;
 WHEN 'QUOTE' THEN
  IF d.current_status<>'SOURCING' OR length(trim(COALESCE(NEW.payload->>'supplier','')))=0 OR length(NEW.payload->>'supplier')>240
   OR COALESCE(NEW.payload->>'currency','') !~ '^[A-Z]{3}$' OR NEW.payload->>'unitPrice' IS NULL OR (NEW.payload->>'unitPrice')::numeric<=0 OR (NEW.payload->>'unitPrice')::numeric>=100000000000000 OR jsonb_array_length(NEW.evidence_refs)=0 THEN RAISE EXCEPTION 'Quote details/evidence required' USING ERRCODE='23514';END IF;
  IF EXISTS(SELECT 1 FROM supply_event e WHERE e.demand_id=d.demand_id AND e.sourcing_round=d.sourcing_round AND e.event_code='QUOTE' AND e.payload->>'currency'<>NEW.payload->>'currency') THEN RAISE EXCEPTION 'Currency mismatch' USING ERRCODE='23514';END IF;
 WHEN 'APPROVE' THEN
  SELECT * INTO q FROM supply_event WHERE event_id=(NEW.payload->>'quoteId')::uuid AND demand_id=d.demand_id AND event_code='QUOTE' AND sourcing_round=d.sourcing_round;
  SELECT count(DISTINCT lower(trim(payload->>'supplier'))) INTO v_count FROM supply_event WHERE demand_id=d.demand_id AND sourcing_round=d.sourcing_round AND event_code='QUOTE';
  IF d.current_status<>'SOURCING' OR q.event_id IS NULL OR (v_count<2 AND length(trim(COALESCE(NEW.payload->>'singleSourceReason','')))<10) THEN RAISE EXCEPTION 'Current quote/comparison or reason required' USING ERRCODE='23514';END IF;
  IF EXISTS(SELECT 1 FROM supply_event WHERE demand_id=d.demand_id AND sourcing_round=d.sourcing_round AND event_code='QUOTE' AND actor_user_id=v_actor) THEN RAISE EXCEPTION 'Quote author cannot approve' USING ERRCODE='42501';END IF;
  d.approved_quote_id:=q.event_id;d.current_status:='APPROVED';
 WHEN 'REJECT' THEN
  IF d.current_status<>'SOURCING' THEN RAISE EXCEPTION 'Sourcing required' USING ERRCODE='23514';END IF;d.current_status:='DRAFT';d.approved_quote_id:=NULL;
 WHEN 'ISSUE_PO' THEN
  IF d.current_status<>'APPROVED' OR length(trim(COALESCE(NEW.payload->>'poNumber','')))=0 OR length(NEW.payload->>'poNumber')>100 OR jsonb_array_length(NEW.evidence_refs)=0 THEN RAISE EXCEPTION 'PO/evidence required' USING ERRCODE='23514';END IF;
  d.po_number:=trim(NEW.payload->>'poNumber');d.current_status:='ORDERED';
 WHEN 'PROMISE' THEN
  IF d.current_status NOT IN ('ORDERED','PART_RECEIVED') OR NEW.payload->>'promisedDate' IS NULL OR jsonb_array_length(NEW.evidence_refs)=0 THEN RAISE EXCEPTION 'Promise required' USING ERRCODE='23514';END IF;d.promised_date:=(NEW.payload->>'promisedDate')::date;
 WHEN 'RECEIVE' THEN
  v_qty:=(NEW.payload->>'quantity')::numeric;v_date:=(NEW.payload->>'receivedDate')::date;
  IF d.current_status NOT IN ('ORDERED','PART_RECEIVED') OR v_qty IS NULL OR v_qty<=0 OR scale(v_qty)>4 OR d.received_qty+v_qty>d.quantity OR v_date IS NULL OR v_date>current_date OR length(trim(COALESCE(NEW.payload->>'batch','')))=0 OR jsonb_array_length(NEW.evidence_refs)=0 THEN RAISE EXCEPTION 'Receipt quantity/date/batch/evidence invalid' USING ERRCODE='23514';END IF;
  NEW.payload:=NEW.payload||jsonb_build_object('promiseAtReceipt',d.promised_date);d.received_qty:=d.received_qty+v_qty;d.current_status:=CASE WHEN d.received_qty=d.quantity THEN 'RECEIVED' ELSE 'PART_RECEIVED' END;
 WHEN 'IQC' THEN
  SELECT * INTO r FROM supply_event WHERE event_id=(NEW.payload->>'receiptId')::uuid AND demand_id=d.demand_id AND event_code='RECEIVE';v_ok:=(NEW.payload->>'acceptedQty')::numeric;v_bad:=(NEW.payload->>'rejectedQty')::numeric;
  IF d.current_status NOT IN ('PART_RECEIVED','RECEIVED') OR r.event_id IS NULL OR v_ok IS NULL OR v_bad IS NULL OR v_ok<0 OR v_bad<0 OR scale(v_ok)>4 OR scale(v_bad)>4 OR v_ok+v_bad<>(r.payload->>'quantity')::numeric OR jsonb_array_length(NEW.evidence_refs)=0
   OR EXISTS(SELECT 1 FROM supply_event WHERE demand_id=d.demand_id AND event_code='IQC' AND payload->>'receiptId'=r.event_id::text) THEN RAISE EXCEPTION 'IQC quantity/reference invalid' USING ERRCODE='23514';END IF;
  IF v_actor=r.actor_user_id THEN RAISE EXCEPTION 'Receiver cannot inspect' USING ERRCODE='42501';END IF;
  d.accepted_qty:=d.accepted_qty+v_ok;d.rejected_qty:=d.rejected_qty+v_bad;IF d.accepted_qty=d.quantity THEN d.current_status:='CLOSED';END IF;
 WHEN 'CANCEL' THEN
  IF d.received_qty>0 THEN RAISE EXCEPTION 'Return workflow required' USING ERRCODE='23514';END IF;d.current_status:='CANCELLED';
 END CASE;
 UPDATE supply_demand SET revision=revision+1,current_status=d.current_status,sourcing_round=d.sourcing_round,approved_quote_id=d.approved_quote_id,po_number=d.po_number,promised_date=d.promised_date,received_qty=d.received_qty,accepted_qty=d.accepted_qty,rejected_qty=d.rejected_qty WHERE demand_id=d.demand_id;
 RETURN NEW;
END $$;
CREATE TRIGGER event_guard BEFORE INSERT ON hrx.supply_event FOR EACH ROW EXECUTE FUNCTION hrx.guard_supply_event();
ALTER TABLE hrx.supply_demand ENABLE ROW LEVEL SECURITY;
ALTER TABLE hrx.supply_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY demand_read ON hrx.supply_demand FOR SELECT USING(hrx.allowed(project_id,'supply_chain','read'));
CREATE POLICY demand_append ON hrx.supply_demand FOR INSERT WITH CHECK(requested_by=hrx.current_user_id() AND hrx.allowed(project_id,'supply_chain','create'));
CREATE POLICY event_read ON hrx.supply_event FOR SELECT USING(hrx.supply_visible(demand_id));
CREATE POLICY event_append ON hrx.supply_event FOR INSERT WITH CHECK(actor_user_id=hrx.current_user_id() AND hrx.supply_visible(demand_id));
CREATE FUNCTION hrx.supply_events(p_id uuid) RETURNS TABLE(event_id uuid,event_code text,expected_revision integer,sourcing_round integer,note text,payload text,evidence_refs text,actor_user_id uuid,occurred_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE p_project uuid;
BEGIN
 SELECT project_id INTO p_project FROM supply_demand WHERE demand_id=p_id;
 IF NOT hrx.supply_visible(p_id) THEN RAISE EXCEPTION 'Read denied' USING ERRCODE='42501';END IF;
 RETURN QUERY SELECT e.event_id,e.event_code,e.expected_revision,e.sourcing_round,e.note,(CASE WHEN hrx.allowed(p_project,'supply_chain','read_price') THEN e.payload ELSE e.payload-'unitPrice' END)::text,e.evidence_refs::text,e.actor_user_id,e.occurred_at FROM supply_event e WHERE e.demand_id=p_id ORDER BY e.expected_revision;
END $$;
CREATE FUNCTION hrx.supplier_delivery() RETURNS TABLE(supplier text,receipt_samples bigint,promised_samples bigint,on_time_samples bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT q.payload->>'supplier',count(*),count(*) FILTER(WHERE e.payload->>'promiseAtReceipt' IS NOT NULL),count(*) FILTER(WHERE (e.payload->>'receivedDate')::date<=(e.payload->>'promiseAtReceipt')::date)
 FROM supply_event e JOIN supply_demand d ON d.demand_id=e.demand_id JOIN supply_event q ON q.event_id=d.approved_quote_id WHERE e.event_code='RECEIVE' AND hrx.allowed(d.project_id,'supply_chain','read') GROUP BY 1
$$;
-- Revoke all default public function access, then grant the current-identity API only.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA hrx FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.current_user_id(),hrx.allowed(uuid,text,text),hrx.capabilities(),hrx.supply_visible(uuid),hrx.supply_buyers(uuid),hrx.supply_events(uuid),hrx.supplier_delivery(),hrx.valid_evidence_refs(jsonb) TO hrx_recovery_app;
GRANT SELECT ON hrx.user_account,hrx.business_project,hrx.capability_grant,hrx.supply_demand TO hrx_recovery_app;
GRANT INSERT ON hrx.supply_demand,hrx.supply_event,hrx.audit_event TO hrx_recovery_app;
GRANT SELECT,INSERT ON hrx.api_idempotency TO hrx_recovery_app;
GRANT SELECT(event_id,demand_id,expected_revision,event_code,sourcing_round,note,evidence_refs,actor_user_id,occurred_at) ON hrx.supply_event TO hrx_recovery_app;
