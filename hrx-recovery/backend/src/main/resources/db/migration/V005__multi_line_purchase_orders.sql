CREATE TABLE hrx.purchase_order (
 order_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_no text NOT NULL UNIQUE CHECK(length(trim(order_no)) BETWEEN 1 AND 100),
 project_id uuid NOT NULL REFERENCES hrx.business_project,supplier text NOT NULL,currency text NOT NULL,
 created_by uuid NOT NULL REFERENCES hrx.user_account,note text NOT NULL CHECK(length(trim(note)) BETWEEN 2 AND 4000),
 current_status text NOT NULL DEFAULT 'PENDING_APPROVAL' CHECK(current_status IN ('PENDING_APPROVAL','APPROVED','ISSUED','REJECTED','CANCELLED')),
 revision integer NOT NULL DEFAULT 0,approved_by uuid REFERENCES hrx.user_account,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE hrx.purchase_order_line (
 order_id uuid NOT NULL REFERENCES hrx.purchase_order,line_no integer NOT NULL,demand_id uuid NOT NULL REFERENCES hrx.supply_demand,
 demand_revision integer NOT NULL,quote_id uuid NOT NULL REFERENCES hrx.supply_event,bom_line text NOT NULL,material_code text NOT NULL,description text NOT NULL,
 unit text NOT NULL,quantity numeric(18,4) NOT NULL,unit_price numeric NOT NULL CHECK(unit_price>0 AND unit_price<100000000000000),
 reservation_active boolean NOT NULL DEFAULT true,PRIMARY KEY(order_id,line_no),UNIQUE(order_id,demand_id)
);
CREATE UNIQUE INDEX po_active_demand ON hrx.purchase_order_line(demand_id) WHERE reservation_active;
CREATE TABLE hrx.purchase_order_event (
 event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),order_id uuid NOT NULL REFERENCES hrx.purchase_order,
 expected_revision integer NOT NULL,event_code text NOT NULL CHECK(event_code IN ('APPROVED','REJECTED','ISSUED','CANCELLED')),
 note text NOT NULL CHECK(length(trim(note)) BETWEEN 2 AND 4000),evidence_refs jsonb NOT NULL CHECK(hrx.valid_evidence_refs(evidence_refs)),
 actor_user_id uuid NOT NULL REFERENCES hrx.user_account,occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(order_id,expected_revision)
);
CREATE FUNCTION hrx.po_visible(p_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM purchase_order p WHERE p.order_id=p_id AND hrx.allowed(p.project_id,'purchase_order','read') AND hrx.allowed(p.project_id,'supply_chain','read'))
$$;
CREATE FUNCTION hrx.po_reservation(p_demand uuid) RETURNS TABLE(reserved_purchase_order_id uuid,reserved_order_no text,reserved_order_status text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT p.order_id,p.order_no,p.current_status FROM purchase_order_line l JOIN purchase_order p ON p.order_id=l.order_id
 WHERE l.demand_id=p_demand AND l.reservation_active AND hrx.supply_visible(p_demand)
$$;
CREATE FUNCTION hrx.create_purchase_order(p_no text,p_note text,p_lines jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE a uuid:=hrx.current_user_id();r record;d supply_demand%ROWTYPE;q supply_event%ROWTYPE;v_project uuid;v_supplier text;v_currency text;v_order_id uuid:=gen_random_uuid();
BEGIN
 IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Order lines must be an array' USING ERRCODE='23514';END IF;
 IF jsonb_array_length(p_lines) NOT BETWEEN 1 AND 100 OR length(trim(p_no)) NOT BETWEEN 1 AND 100 OR length(trim(p_note)) NOT BETWEEN 2 AND 4000 THEN RAISE EXCEPTION 'Order fields invalid' USING ERRCODE='23514';END IF;
 IF (SELECT count(DISTINCT (e->>'demandId')::uuid) FROM jsonb_array_elements(p_lines) e)<>jsonb_array_length(p_lines) THEN RAISE EXCEPTION 'Duplicate/missing order demands' USING ERRCODE='23514';END IF;
 FOR r IN SELECT (e->>'demandId')::uuid id,(e->>'expectedRevision')::integer revision FROM jsonb_array_elements(p_lines) e ORDER BY id LOOP
  SELECT * INTO d FROM supply_demand WHERE demand_id=r.id FOR UPDATE;
  IF NOT FOUND OR NOT hrx.allowed(d.project_id,'purchase_order','read') OR NOT hrx.allowed(d.project_id,'purchase_order','create')
   OR NOT hrx.allowed(d.project_id,'supply_chain','read') OR NOT hrx.allowed(d.project_id,'supply_chain','read_price') OR NOT hrx.allowed(d.project_id,'supply_chain','update') OR a IS DISTINCT FROM d.buyer_user_id THEN RAISE EXCEPTION 'Order buyer or scope denied' USING ERRCODE='42501';END IF;
  IF r.revision IS NULL OR r.revision<>d.revision THEN RAISE EXCEPTION 'Demand revision changed' USING ERRCODE='40001';END IF;
  IF d.current_status<>'APPROVED' OR EXISTS(SELECT 1 FROM purchase_order_line l WHERE l.demand_id=d.demand_id AND l.reservation_active) THEN RAISE EXCEPTION 'Demand unavailable for order' USING ERRCODE='40001';END IF;
  SELECT * INTO q FROM supply_event WHERE event_id=d.approved_quote_id AND demand_id=d.demand_id AND event_code='QUOTE';
  IF q.event_id IS NULL THEN RAISE EXCEPTION 'Approved quote missing' USING ERRCODE='23514';END IF;
  IF v_project IS NULL THEN v_project:=d.project_id;v_supplier:=trim(q.payload->>'supplier');v_currency:=q.payload->>'currency';
  ELSIF v_project<>d.project_id OR lower(v_supplier)<>lower(trim(q.payload->>'supplier')) OR v_currency<>q.payload->>'currency' THEN RAISE EXCEPTION 'Order project/supplier/currency mismatch' USING ERRCODE='23514';END IF;
 END LOOP;
 INSERT INTO purchase_order(order_id,order_no,project_id,supplier,currency,created_by,note) VALUES(v_order_id,trim(p_no),v_project,v_supplier,v_currency,a,p_note);
 INSERT INTO purchase_order_line(order_id,line_no,demand_id,demand_revision,quote_id,bom_line,material_code,description,unit,quantity,unit_price)
 SELECT v_order_id,e.n::integer,src.demand_id,src.revision,src.approved_quote_id,src.bom_line,src.material_code,src.description,src.unit,src.quantity,(quote.payload->>'unitPrice')::numeric
 FROM jsonb_array_elements(p_lines) WITH ORDINALITY e(value,n) JOIN supply_demand src ON src.demand_id=(e.value->>'demandId')::uuid JOIN supply_event quote ON quote.event_id=src.approved_quote_id;
 RETURN v_order_id;
END $$;
CREATE FUNCTION hrx.apply_purchase_order_event(p_id uuid,p_revision integer,p_event text,p_note text,p_refs jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE p purchase_order%ROWTYPE;d supply_demand%ROWTYPE;l record;a uuid:=hrx.current_user_id();id uuid:=gen_random_uuid();v_action text;v_supply_event uuid;
BEGIN
 SELECT * INTO p FROM purchase_order WHERE order_id=p_id FOR UPDATE;
 IF NOT FOUND OR NOT hrx.po_visible(p_id) THEN RAISE EXCEPTION 'Order read denied' USING ERRCODE='42501';END IF;
 IF p_revision IS NULL OR p.revision<>p_revision THEN RAISE EXCEPTION 'Order revision changed' USING ERRCODE='40001';END IF;
 v_action:=CASE p_event WHEN 'APPROVED' THEN 'approve' WHEN 'REJECTED' THEN 'approve' WHEN 'ISSUED' THEN 'issue' WHEN 'CANCELLED' THEN 'cancel' ELSE NULL END;
 IF v_action IS NULL OR NOT hrx.allowed(p.project_id,'purchase_order',v_action) THEN RAISE EXCEPTION 'Order action denied' USING ERRCODE='42501';END IF;
 IF length(trim(p_note)) NOT BETWEEN 2 AND 4000 OR NOT hrx.valid_evidence_refs(p_refs) THEN RAISE EXCEPTION 'Order note/evidence invalid' USING ERRCODE='23514';END IF;
 IF p_event IN ('APPROVED','ISSUED') AND jsonb_array_length(p_refs)=0 THEN RAISE EXCEPTION 'Order evidence required' USING ERRCODE='23514';END IF;
 IF p_event IN ('APPROVED','REJECTED') AND p.current_status<>'PENDING_APPROVAL'
 OR p_event='ISSUED' AND p.current_status<>'APPROVED'
 OR p_event='CANCELLED' AND p.current_status NOT IN ('PENDING_APPROVAL','APPROVED') THEN RAISE EXCEPTION 'Order state invalid' USING ERRCODE='23514';END IF;
 IF p_event IN ('APPROVED','REJECTED','CANCELLED') THEN
  IF a=p.created_by OR EXISTS(SELECT 1 FROM purchase_order_line x JOIN supply_demand s ON s.demand_id=x.demand_id WHERE x.order_id=p_id AND a IN (s.requested_by,s.buyer_user_id)) THEN RAISE EXCEPTION 'Independent order decision required' USING ERRCODE='42501';END IF;
  IF p_event IN ('APPROVED','REJECTED') AND (NOT hrx.allowed(p.project_id,'supply_chain','read_price') OR EXISTS(
   SELECT 1 FROM purchase_order_line x JOIN supply_demand s ON s.demand_id=x.demand_id JOIN supply_event e ON e.demand_id=s.demand_id AND e.sourcing_round=s.sourcing_round
   WHERE x.order_id=p_id AND e.event_code='QUOTE' AND e.actor_user_id=a)) THEN RAISE EXCEPTION 'Order price access and independent reviewer required' USING ERRCODE='42501';END IF;
 ELSE
  IF a<>p.created_by OR a=p.approved_by OR NOT hrx.allowed(p.project_id,'supply_chain','update') THEN RAISE EXCEPTION 'Approved order buyer must issue' USING ERRCODE='42501';END IF;
 END IF;
 FOR l IN SELECT * FROM purchase_order_line WHERE order_id=p_id ORDER BY demand_id LOOP
  SELECT * INTO d FROM supply_demand WHERE demand_id=l.demand_id FOR UPDATE;
  IF NOT l.reservation_active OR d.current_status<>'APPROVED' OR d.revision<>l.demand_revision OR d.approved_quote_id IS DISTINCT FROM l.quote_id THEN RAISE EXCEPTION 'Reserved demand changed' USING ERRCODE='40001';END IF;
 END LOOP;
 UPDATE purchase_order SET current_status=p_event,revision=revision+1,approved_by=CASE WHEN p_event='APPROVED' THEN a ELSE approved_by END WHERE order_id=p_id;
 IF p_event='ISSUED' THEN
  FOR l IN SELECT * FROM purchase_order_line WHERE order_id=p_id ORDER BY demand_id LOOP
   INSERT INTO supply_event(demand_id,expected_revision,event_code,note,payload,evidence_refs,actor_user_id)
   VALUES(l.demand_id,l.demand_revision,'ISSUE_PO',p_note,jsonb_build_object('poNumber',p.order_no,'purchaseOrderId',p_id),p_refs,a) RETURNING event_id INTO v_supply_event;
   INSERT INTO audit_event(actor_user_id,action_code,resource_id,metadata) VALUES(a,'ISSUE_PO',l.demand_id,jsonb_build_object('purchaseOrderId',p_id,'eventId',v_supply_event));
  END LOOP;
 ELSIF p_event IN ('REJECTED','CANCELLED') THEN UPDATE purchase_order_line SET reservation_active=false WHERE order_id=p_id;
 END IF;
 INSERT INTO purchase_order_event(event_id,order_id,expected_revision,event_code,note,evidence_refs,actor_user_id) VALUES(id,p_id,p_revision,p_event,p_note,p_refs,a);
 RETURN id;
END $$;
CREATE FUNCTION hrx.purchase_orders() RETURNS TABLE(order_id uuid,order_no text,project_id uuid,project_code text,project_name text,supplier text,currency text,current_status text,revision integer,created_by uuid,approved_by uuid,note text,created_at timestamptz,line_count bigint,total_amount text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT p.order_id,p.order_no,p.project_id,b.project_code,b.project_name,p.supplier,p.currency,p.current_status,p.revision,p.created_by,p.approved_by,p.note,p.created_at,
 (SELECT count(*) FROM purchase_order_line l WHERE l.order_id=p.order_id),CASE WHEN hrx.allowed(p.project_id,'supply_chain','read_price') THEN (SELECT sum(l.quantity*l.unit_price)::text FROM purchase_order_line l WHERE l.order_id=p.order_id) ELSE NULL END
 FROM purchase_order p JOIN business_project b ON b.project_id=p.project_id WHERE hrx.po_visible(p.order_id)
$$;
CREATE FUNCTION hrx.purchase_order_lines(p_id uuid) RETURNS TABLE(line_no integer,demand_id uuid,bom_line text,material_code text,description text,unit text,quantity numeric,quote_id uuid,unit_price text,line_amount text,reservation_active boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT l.line_no,l.demand_id,l.bom_line,l.material_code,l.description,l.unit,l.quantity,l.quote_id,
 CASE WHEN hrx.allowed(p.project_id,'supply_chain','read_price') THEN l.unit_price::text ELSE NULL END,
 CASE WHEN hrx.allowed(p.project_id,'supply_chain','read_price') THEN (l.unit_price*l.quantity)::text ELSE NULL END,l.reservation_active
 FROM purchase_order_line l JOIN purchase_order p ON p.order_id=l.order_id WHERE p.order_id=p_id AND hrx.po_visible(p_id) ORDER BY l.line_no
$$;
CREATE FUNCTION hrx.purchase_order_candidates() RETURNS TABLE(demand_id uuid,revision integer,project_id uuid,project_code text,bom_line text,material_code text,description text,unit text,quantity numeric,supplier text,currency text,unit_price text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT d.demand_id,d.revision,d.project_id,b.project_code,d.bom_line,d.material_code,d.description,d.unit,d.quantity,trim(q.payload->>'supplier'),q.payload->>'currency',q.payload->>'unitPrice'
 FROM supply_demand d JOIN business_project b ON b.project_id=d.project_id JOIN supply_event q ON q.event_id=d.approved_quote_id
 WHERE d.current_status='APPROVED' AND d.buyer_user_id=hrx.current_user_id() AND hrx.allowed(d.project_id,'purchase_order','read') AND hrx.allowed(d.project_id,'purchase_order','create')
 AND hrx.allowed(d.project_id,'supply_chain','read') AND hrx.allowed(d.project_id,'supply_chain','update') AND hrx.allowed(d.project_id,'supply_chain','read_price')
 AND NOT EXISTS(SELECT 1 FROM purchase_order_line l WHERE l.demand_id=d.demand_id AND l.reservation_active) ORDER BY d.required_date,d.demand_id LIMIT 300
$$;
ALTER TABLE hrx.purchase_order ENABLE ROW LEVEL SECURITY;
ALTER TABLE hrx.purchase_order_line ENABLE ROW LEVEL SECURITY;
ALTER TABLE hrx.purchase_order_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY po_read ON hrx.purchase_order FOR SELECT USING(hrx.po_visible(order_id));
CREATE POLICY po_line_read ON hrx.purchase_order_line FOR SELECT USING(hrx.po_visible(order_id));
CREATE POLICY po_event_read ON hrx.purchase_order_event FOR SELECT USING(hrx.po_visible(order_id));
REVOKE ALL ON FUNCTION hrx.po_visible(uuid),hrx.po_reservation(uuid),hrx.create_purchase_order(text,text,jsonb),hrx.apply_purchase_order_event(uuid,integer,text,text,jsonb),hrx.purchase_orders(),hrx.purchase_order_lines(uuid),hrx.purchase_order_candidates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.po_visible(uuid),hrx.po_reservation(uuid),hrx.create_purchase_order(text,text,jsonb),hrx.apply_purchase_order_event(uuid,integer,text,text,jsonb),hrx.purchase_orders(),hrx.purchase_order_lines(uuid),hrx.purchase_order_candidates() TO hrx_recovery_app;
GRANT SELECT ON hrx.purchase_order,hrx.purchase_order_event TO hrx_recovery_app;
GRANT SELECT(order_id,line_no,demand_id,demand_revision,quote_id,bom_line,material_code,description,unit,quantity,reservation_active) ON hrx.purchase_order_line TO hrx_recovery_app;

-- Private files may belong to either one demand or one PO, never both.
ALTER TABLE hrx.controlled_file ALTER COLUMN demand_id DROP NOT NULL;
ALTER TABLE hrx.controlled_file ADD COLUMN purchase_order_id uuid REFERENCES hrx.purchase_order;
ALTER TABLE hrx.controlled_file ADD CONSTRAINT one_file_parent CHECK((demand_id IS NOT NULL)<>(purchase_order_id IS NOT NULL));
CREATE FUNCTION hrx.po_file_allowed(p_order uuid,p_action text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM purchase_order p WHERE p.order_id=p_order AND hrx.po_visible(p_order) AND hrx.allowed(p.project_id,'controlled_file',p_action))
$$;
CREATE OR REPLACE FUNCTION hrx.guard_file() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE previous controlled_file%ROWTYPE;
BEGIN
 IF NEW.uploaded_by IS DISTINCT FROM hrx.current_user_id() OR (NEW.demand_id IS NULL)=(NEW.purchase_order_id IS NULL)
  OR (NEW.demand_id IS NOT NULL AND NOT hrx.file_allowed(NEW.demand_id,'create')) OR (NEW.purchase_order_id IS NOT NULL AND NOT hrx.po_file_allowed(NEW.purchase_order_id,'create')) THEN RAISE EXCEPTION 'File upload denied' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(NEW.document_id::text||':version',0));
 SELECT * INTO previous FROM controlled_file WHERE document_id=NEW.document_id ORDER BY version DESC LIMIT 1;
 IF NEW.version<>COALESCE(previous.version,0)+1 THEN RAISE EXCEPTION 'File version changed' USING ERRCODE='40001';END IF;
 IF previous.file_id IS NOT NULL AND (previous.demand_id IS DISTINCT FROM NEW.demand_id OR previous.purchase_order_id IS DISTINCT FROM NEW.purchase_order_id) THEN RAISE EXCEPTION 'Cannot move a file between objects' USING ERRCODE='42501';END IF;
 NEW.created_at:=clock_timestamp();RETURN NEW;
END $$;
ALTER POLICY file_read ON hrx.controlled_file USING((demand_id IS NOT NULL AND hrx.file_allowed(demand_id,'read')) OR (purchase_order_id IS NOT NULL AND hrx.po_file_allowed(purchase_order_id,'read')));
ALTER POLICY file_append ON hrx.controlled_file WITH CHECK(uploaded_by=hrx.current_user_id() AND ((demand_id IS NOT NULL AND hrx.file_allowed(demand_id,'create')) OR (purchase_order_id IS NOT NULL AND hrx.po_file_allowed(purchase_order_id,'create'))));
REVOKE ALL ON FUNCTION hrx.po_file_allowed(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.po_file_allowed(uuid,text) TO hrx_recovery_app;

CREATE OR REPLACE FUNCTION hrx.guard_supply_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE d supply_demand%ROWTYPE;q supply_event%ROWTYPE;r supply_event%ROWTYPE;v_actor uuid;v_action text;v_qty numeric;v_ok numeric;v_bad numeric;v_date date;v_count integer;v_return_request supply_event%ROWTYPE;v_return_inspection supply_event%ROWTYPE;v_return_receipt supply_event%ROWTYPE;v_return_approval supply_event%ROWTYPE;
BEGIN
 SELECT * INTO d FROM supply_demand WHERE demand_id=NEW.demand_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Missing demand' USING ERRCODE='23503';END IF;
 v_actor:=hrx.current_user_id();
 IF v_actor IS DISTINCT FROM NEW.actor_user_id OR NOT hrx.allowed(d.project_id,'supply_chain','read') THEN RAISE EXCEPTION 'Identity/read denied' USING ERRCODE='42501';END IF;
 IF NEW.event_code IN ('ISSUE_PO','CANCEL') AND EXISTS(SELECT 1 FROM purchase_order_line l WHERE l.demand_id=d.demand_id AND l.reservation_active) THEN
  IF NEW.event_code='CANCEL' OR NOT EXISTS(SELECT 1 FROM purchase_order_line l JOIN purchase_order p ON p.order_id=l.order_id
   WHERE l.demand_id=d.demand_id AND l.reservation_active AND p.current_status='ISSUED' AND p.order_id=(NEW.payload->>'purchaseOrderId')::uuid AND p.order_no=NEW.payload->>'poNumber') THEN
   RAISE EXCEPTION 'Demand reserved by purchase order' USING ERRCODE='40001';END IF;
 END IF;
 IF NEW.expected_revision<>d.revision THEN RAISE EXCEPTION 'Revision changed' USING ERRCODE='40001';END IF;
 IF d.current_status IN ('CLOSED','CANCELLED') THEN RAISE EXCEPTION 'Terminal demand' USING ERRCODE='23514';END IF;
 v_action:=CASE WHEN NEW.event_code IN ('APPROVE','REJECT','RETURN_APPROVE','RETURN_REJECT') OR (NEW.event_code='CANCEL' AND d.current_status IN ('APPROVED','ORDERED')) THEN 'approve' WHEN NEW.event_code IN ('RECEIVE','RETURN_REQUEST','RETURN_SHIP') THEN 'receive' WHEN NEW.event_code='IQC' THEN 'inspect' ELSE 'update' END;
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
  IF d.current_status NOT IN ('ORDERED','PART_RECEIVED') OR v_qty IS NULL OR v_qty<=0 OR scale(v_qty)>4 OR d.received_qty-d.returned_qty+v_qty>d.quantity OR v_date IS NULL OR v_date>current_date OR length(trim(COALESCE(NEW.payload->>'batch','')))=0 OR jsonb_array_length(NEW.evidence_refs)=0 THEN RAISE EXCEPTION 'Receipt quantity/date/batch/evidence invalid' USING ERRCODE='23514';END IF;
  NEW.payload:=NEW.payload||jsonb_build_object('promiseAtReceipt',d.promised_date);d.received_qty:=d.received_qty+v_qty;d.current_status:=CASE WHEN d.received_qty-d.returned_qty=d.quantity THEN 'RECEIVED' ELSE 'PART_RECEIVED' END;
 WHEN 'IQC' THEN
  SELECT * INTO r FROM supply_event WHERE event_id=(NEW.payload->>'receiptId')::uuid AND demand_id=d.demand_id AND event_code='RECEIVE';v_ok:=(NEW.payload->>'acceptedQty')::numeric;v_bad:=(NEW.payload->>'rejectedQty')::numeric;
  IF d.current_status NOT IN ('PART_RECEIVED','RECEIVED') OR r.event_id IS NULL OR v_ok IS NULL OR v_bad IS NULL OR v_ok<0 OR v_bad<0 OR scale(v_ok)>4 OR scale(v_bad)>4 OR v_ok+v_bad<>(r.payload->>'quantity')::numeric OR jsonb_array_length(NEW.evidence_refs)=0
   OR EXISTS(SELECT 1 FROM supply_event WHERE demand_id=d.demand_id AND event_code='IQC' AND (payload->>'receiptId')::uuid=r.event_id) THEN RAISE EXCEPTION 'IQC quantity/reference invalid' USING ERRCODE='23514';END IF;
  IF v_actor=r.actor_user_id THEN RAISE EXCEPTION 'Receiver cannot inspect' USING ERRCODE='42501';END IF;
  NEW.payload:=NEW.payload||jsonb_build_object('receiptId',r.event_id);
  d.accepted_qty:=d.accepted_qty+v_ok;d.rejected_qty:=d.rejected_qty+v_bad;IF d.accepted_qty=d.quantity THEN d.current_status:='CLOSED';END IF;
 WHEN 'RETURN_REQUEST' THEN
  SELECT * INTO v_return_inspection FROM supply_event WHERE event_id=(NEW.payload->>'inspectionId')::uuid AND demand_id=d.demand_id AND event_code='IQC';
  SELECT * INTO v_return_receipt FROM supply_event WHERE event_id=(v_return_inspection.payload->>'receiptId')::uuid AND demand_id=d.demand_id AND event_code='RECEIVE';
  IF d.current_status NOT IN ('PART_RECEIVED','RECEIVED') OR v_return_inspection.event_id IS NULL OR v_return_receipt.event_id IS NULL
   OR (v_return_inspection.payload->>'rejectedQty')::numeric<=0 OR jsonb_array_length(NEW.evidence_refs)=0 THEN RAISE EXCEPTION 'Rejected inspection and return evidence required' USING ERRCODE='23514';END IF;
  IF v_actor=v_return_inspection.actor_user_id THEN RAISE EXCEPTION 'Inspector cannot request own return shipment' USING ERRCODE='42501';END IF;
  IF EXISTS(SELECT 1 FROM supply_event rr WHERE rr.demand_id=d.demand_id AND rr.event_code='RETURN_REQUEST' AND rr.payload->>'inspectionId'=v_return_inspection.event_id::text
   AND NOT EXISTS(SELECT 1 FROM supply_event rejected WHERE rejected.demand_id=d.demand_id AND rejected.event_code='RETURN_REJECT' AND rejected.payload->>'returnRequestId'=rr.event_id::text)) THEN
   RAISE EXCEPTION 'Inspection already has an active or shipped return' USING ERRCODE='23514';END IF;
  NEW.payload:=NEW.payload||jsonb_build_object('inspectionId',v_return_inspection.event_id,'receiptId',v_return_receipt.event_id,'returnQuantity',(v_return_inspection.payload->>'rejectedQty')::numeric);
 WHEN 'RETURN_APPROVE','RETURN_REJECT' THEN
  SELECT * INTO v_return_request FROM supply_event WHERE event_id=(NEW.payload->>'returnRequestId')::uuid AND demand_id=d.demand_id AND event_code='RETURN_REQUEST';
  SELECT * INTO v_return_inspection FROM supply_event WHERE event_id=(v_return_request.payload->>'inspectionId')::uuid AND demand_id=d.demand_id AND event_code='IQC';
  SELECT * INTO v_return_receipt FROM supply_event WHERE event_id=(v_return_request.payload->>'receiptId')::uuid AND demand_id=d.demand_id AND event_code='RECEIVE';
  IF d.current_status NOT IN ('PART_RECEIVED','RECEIVED') OR v_return_request.event_id IS NULL
   OR EXISTS(SELECT 1 FROM supply_event e WHERE e.demand_id=d.demand_id AND e.event_code IN ('RETURN_APPROVE','RETURN_REJECT','RETURN_SHIP') AND e.payload->>'returnRequestId'=v_return_request.event_id::text)
   OR (NEW.event_code='RETURN_APPROVE' AND jsonb_array_length(NEW.evidence_refs)=0) THEN RAISE EXCEPTION 'Pending return and approval evidence required' USING ERRCODE='23514';END IF;
  IF v_actor IN (v_return_request.actor_user_id,v_return_inspection.actor_user_id,v_return_receipt.actor_user_id) THEN RAISE EXCEPTION 'Independent return approver required' USING ERRCODE='42501';END IF;
  NEW.payload:=NEW.payload||jsonb_build_object('returnRequestId',v_return_request.event_id);
 WHEN 'RETURN_SHIP' THEN
  SELECT * INTO v_return_request FROM supply_event WHERE event_id=(NEW.payload->>'returnRequestId')::uuid AND demand_id=d.demand_id AND event_code='RETURN_REQUEST';
  SELECT * INTO v_return_inspection FROM supply_event WHERE event_id=(v_return_request.payload->>'inspectionId')::uuid AND demand_id=d.demand_id AND event_code='IQC';
  SELECT * INTO v_return_receipt FROM supply_event WHERE event_id=(v_return_request.payload->>'receiptId')::uuid AND demand_id=d.demand_id AND event_code='RECEIVE';
  SELECT * INTO v_return_approval FROM supply_event WHERE demand_id=d.demand_id AND event_code='RETURN_APPROVE' AND payload->>'returnRequestId'=v_return_request.event_id::text;
  v_date:=(NEW.payload->>'shippedDate')::date;
  IF d.current_status NOT IN ('PART_RECEIVED','RECEIVED') OR v_return_request.event_id IS NULL OR v_return_approval.event_id IS NULL
   OR v_date IS NULL OR v_date>current_date OR v_date<(v_return_receipt.payload->>'receivedDate')::date OR length(trim(COALESCE(NEW.payload->>'shipmentNo','')))=0 OR length(NEW.payload->>'shipmentNo')>100
   OR jsonb_array_length(NEW.evidence_refs)=0 OR EXISTS(SELECT 1 FROM supply_event e WHERE e.demand_id=d.demand_id AND e.event_code='RETURN_SHIP' AND e.payload->>'returnRequestId'=v_return_request.event_id::text) THEN RAISE EXCEPTION 'Approved, unshipped return and shipment evidence required' USING ERRCODE='23514';END IF;
  IF v_actor<>v_return_request.actor_user_id OR v_actor IN (v_return_approval.actor_user_id,v_return_inspection.actor_user_id) THEN RAISE EXCEPTION 'Original return requester must ship independently' USING ERRCODE='42501';END IF;
  d.returned_qty:=d.returned_qty+(v_return_request.payload->>'returnQuantity')::numeric;
  NEW.payload:=NEW.payload||jsonb_build_object('returnRequestId',v_return_request.event_id,'returnQuantity',(v_return_request.payload->>'returnQuantity')::numeric);
  d.current_status:=CASE WHEN d.received_qty-d.returned_qty=d.quantity THEN 'RECEIVED' ELSE 'PART_RECEIVED' END;
 WHEN 'CANCEL' THEN
  IF d.received_qty>0 THEN RAISE EXCEPTION 'Return workflow required' USING ERRCODE='23514';END IF;d.current_status:='CANCELLED';
 END CASE;
 UPDATE supply_demand SET revision=revision+1,current_status=d.current_status,sourcing_round=d.sourcing_round,approved_quote_id=d.approved_quote_id,po_number=d.po_number,promised_date=d.promised_date,received_qty=d.received_qty,accepted_qty=d.accepted_qty,rejected_qty=d.rejected_qty,returned_qty=d.returned_qty WHERE demand_id=d.demand_id;
 RETURN NEW;
END $$;

-- UI hints use the same current identity and project scope; writes revalidate under locks.
CREATE FUNCTION hrx.purchase_order_actions(p_id uuid) RETURNS TABLE(event_code text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT v.code FROM purchase_order p CROSS JOIN (VALUES('APPROVED','approve'),('REJECTED','approve'),('ISSUED','issue'),('CANCELLED','cancel')) v(code,action)
 WHERE p.order_id=p_id AND hrx.po_visible(p_id) AND hrx.allowed(p.project_id,'purchase_order',v.action)
 AND CASE WHEN v.code='ISSUED' THEN p.current_status='APPROVED' AND p.created_by=hrx.current_user_id() AND p.approved_by<>hrx.current_user_id() AND hrx.allowed(p.project_id,'supply_chain','update')
 ELSE p.current_status IN ('PENDING_APPROVAL','APPROVED') AND (v.code='CANCELLED' OR p.current_status='PENDING_APPROVAL')
 AND p.created_by<>hrx.current_user_id() AND NOT EXISTS(SELECT 1 FROM purchase_order_line l JOIN supply_demand d ON d.demand_id=l.demand_id WHERE l.order_id=p_id AND hrx.current_user_id() IN (d.requested_by,d.buyer_user_id))
 AND (v.code='CANCELLED' OR hrx.allowed(p.project_id,'supply_chain','read_price') AND NOT EXISTS(SELECT 1 FROM purchase_order_line l JOIN supply_demand d ON d.demand_id=l.demand_id JOIN supply_event e ON e.demand_id=d.demand_id AND e.sourcing_round=d.sourcing_round WHERE l.order_id=p_id AND e.event_code='QUOTE' AND e.actor_user_id=hrx.current_user_id())) END
 ORDER BY v.code
$$;
REVOKE ALL ON FUNCTION hrx.purchase_order_actions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.purchase_order_actions(uuid) TO hrx_recovery_app;
