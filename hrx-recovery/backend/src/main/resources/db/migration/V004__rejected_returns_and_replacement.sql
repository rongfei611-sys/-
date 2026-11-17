-- Recovery 0.2: retain gross receipt history and allow replacement only after approved return shipment.
ALTER TABLE hrx.supply_demand ADD COLUMN returned_qty numeric(18,4) NOT NULL DEFAULT 0;
DO $$ DECLARE c record;BEGIN
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='hrx.supply_demand'::regclass AND contype='c'
  AND pg_get_constraintdef(oid) LIKE '%received_qty%' AND pg_get_constraintdef(oid) LIKE '%accepted_qty%' LOOP
  EXECUTE format('ALTER TABLE hrx.supply_demand DROP CONSTRAINT %I',c.conname);
 END LOOP;
 FOR c IN SELECT conname FROM pg_constraint WHERE conrelid='hrx.supply_event'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%event_code%' LOOP
  EXECUTE format('ALTER TABLE hrx.supply_event DROP CONSTRAINT %I',c.conname);
 END LOOP;
END $$;
ALTER TABLE hrx.supply_demand ADD CONSTRAINT receipt_return_balance CHECK (
 received_qty>=0 AND accepted_qty>=0 AND rejected_qty>=0 AND returned_qty>=0 AND returned_qty<=rejected_qty
 AND accepted_qty+rejected_qty<=received_qty AND received_qty-returned_qty<=quantity);
ALTER TABLE hrx.supply_event ADD CONSTRAINT recovery_event_codes_v004 CHECK(event_code IN (
 'SUBMIT','OPEN_RFQ','QUOTE','APPROVE','REJECT','ISSUE_PO','PROMISE','RECEIVE','IQC','CANCEL','RETURN_REQUEST','RETURN_APPROVE','RETURN_REJECT','RETURN_SHIP'));
CREATE OR REPLACE FUNCTION hrx.guard_supply_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE d supply_demand%ROWTYPE;q supply_event%ROWTYPE;r supply_event%ROWTYPE;v_actor uuid;v_action text;v_qty numeric;v_ok numeric;v_bad numeric;v_date date;v_count integer;v_return_request supply_event%ROWTYPE;v_return_inspection supply_event%ROWTYPE;v_return_receipt supply_event%ROWTYPE;v_return_approval supply_event%ROWTYPE;
BEGIN
 SELECT * INTO d FROM supply_demand WHERE demand_id=NEW.demand_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Missing demand' USING ERRCODE='23503';END IF;
 v_actor:=hrx.current_user_id();
 IF v_actor IS DISTINCT FROM NEW.actor_user_id OR NOT hrx.allowed(d.project_id,'supply_chain','read') THEN RAISE EXCEPTION 'Identity/read denied' USING ERRCODE='42501';END IF;
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
