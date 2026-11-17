-- Read models only: underlying demand RLS remains authoritative.
CREATE VIEW hrx.supply_progress WITH (security_invoker=true) AS
 SELECT d.*,(quantity-accepted_qty) shortage_qty,(received_qty-accepted_qty-rejected_qty) pending_iqc_qty,
 (rejected_qty-returned_qty) outstanding_rejected_qty,(quantity-received_qty+returned_qty) receivable_qty,
 current_status<>'CANCELLED' AND accepted_qty<quantity AND required_date<current_date AS overdue,
 current_status IN ('ORDERED','PART_RECEIVED','RECEIVED') AND accepted_qty<quantity AND promised_date IS NULL AS promise_missing,
 current_status<>'CANCELLED' AND accepted_qty<quantity AND promised_date>required_date AS promise_late,
 current_status<>'CANCELLED' AND returned_qty>0 AND received_qty-returned_qty<quantity AS replacement_pending,
 CASE WHEN current_status='CANCELLED' THEN 'CANCELLED' WHEN accepted_qty=quantity THEN 'READY' WHEN rejected_qty>returned_qty THEN 'IQC_REJECTED'
 WHEN required_date<current_date THEN 'OVERDUE' WHEN returned_qty>0 AND received_qty-returned_qty<quantity THEN 'REPLACEMENT_PENDING'
 WHEN current_status IN ('ORDERED','PART_RECEIVED','RECEIVED') AND promised_date IS NULL THEN 'PROMISE_MISSING'
 WHEN promised_date>required_date THEN 'PROMISE_LATE' WHEN current_status IN ('DRAFT','SUBMITTED','SOURCING','APPROVED') AND current_date>=required_date-lead_time_days THEN 'LEAD_TIME_RISK'
 WHEN received_qty>accepted_qty+rejected_qty THEN 'IQC_PENDING' ELSE 'IN_PROGRESS' END risk_code
 FROM hrx.supply_demand d;
GRANT SELECT ON hrx.supply_progress TO hrx_recovery_app;

-- Rejected/cancelled orders must never acquire a replacement order's delivery history.
CREATE FUNCTION hrx.purchase_order_fulfillment(p_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 WITH header AS (SELECT * FROM purchase_order p WHERE p.order_id=p_id AND hrx.po_visible(p_id)),
 lines AS (
  SELECT l.line_no,l.demand_id,l.bom_line,l.material_code,l.description,l.unit,l.quantity::text quantity,
   p.current_status='ISSUED' AND EXISTS(SELECT 1 FROM supply_event e WHERE e.demand_id=l.demand_id AND e.event_code='ISSUE_PO' AND e.payload->>'purchaseOrderId'=p_id::text) AS linked,
   d.current_status demand_status,d.revision demand_revision,d.required_date,d.promised_date,
   d.received_qty::text received_qty,d.returned_qty::text returned_qty,(d.received_qty-d.returned_qty)::text net_received_qty,d.accepted_qty::text accepted_qty,d.rejected_qty::text rejected_qty,
   d.shortage_qty::text shortage_qty,d.pending_iqc_qty::text pending_iqc_qty,d.outstanding_rejected_qty::text outstanding_rejected_qty,d.receivable_qty::text receivable_qty,
   d.risk_code,d.overdue,d.promise_missing,d.promise_late,d.replacement_pending
  FROM header p JOIN purchase_order_line l ON l.order_id=p.order_id JOIN supply_progress d ON d.demand_id=l.demand_id
  WHERE hrx.supply_visible(d.demand_id)
 ), projected AS (
  SELECT jsonb_build_object('line_no',line_no,'demand_id',demand_id,'bom_line',bom_line,'material_code',material_code,'description',description,'unit',unit,'quantity',quantity,
   'linked',linked,'demand_status',CASE WHEN linked THEN demand_status END,'demand_revision',CASE WHEN linked THEN demand_revision END,
   'required_date',required_date,'promised_date',CASE WHEN linked THEN promised_date END,
   'received_qty',CASE WHEN linked THEN received_qty END,'returned_qty',CASE WHEN linked THEN returned_qty END,'net_received_qty',CASE WHEN linked THEN net_received_qty END,
   'accepted_qty',CASE WHEN linked THEN accepted_qty END,'rejected_qty',CASE WHEN linked THEN rejected_qty END,'shortage_qty',CASE WHEN linked THEN shortage_qty END,
   'pending_iqc_qty',CASE WHEN linked THEN pending_iqc_qty END,'outstanding_rejected_qty',CASE WHEN linked THEN outstanding_rejected_qty END,'receivable_qty',CASE WHEN linked THEN receivable_qty END,
   'risk_code',CASE WHEN linked THEN risk_code ELSE 'NOT_ISSUED' END,'overdue',linked AND overdue,'promise_missing',linked AND promise_missing,'promise_late',linked AND COALESCE(promise_late,false),'replacement_pending',linked AND replacement_pending) item,
   line_no,linked,demand_status,overdue,promise_missing,promise_late,replacement_pending,pending_iqc_qty::numeric pending_iqc_qty,outstanding_rejected_qty::numeric outstanding_rejected_qty
  FROM lines
 )
 SELECT jsonb_build_object('order_id',p_id,'order_status',p.current_status,'as_of',statement_timestamp(),'business_date',current_date,
  'summary',(SELECT jsonb_build_object('line_count',count(*),'linked_lines',count(*) FILTER(WHERE linked),
   'ready_lines',count(*) FILTER(WHERE linked AND demand_status='CLOSED'),'overdue_lines',count(*) FILTER(WHERE linked AND overdue),
   'promise_missing_lines',count(*) FILTER(WHERE linked AND promise_missing),'promise_late_lines',count(*) FILTER(WHERE linked AND promise_late),
   'pending_iqc_lines',count(*) FILTER(WHERE linked AND pending_iqc_qty>0),'rejected_lines',count(*) FILTER(WHERE linked AND outstanding_rejected_qty>0),
   'replacement_lines',count(*) FILTER(WHERE linked AND replacement_pending),
   'delivery_status',CASE WHEN p.current_status<>'ISSUED' THEN 'NOT_ISSUED' WHEN count(*) FILTER(WHERE linked)=count(*) AND count(*) FILTER(WHERE demand_status='CLOSED')=count(*) AND count(*)>0 THEN 'READY' ELSE 'IN_PROGRESS' END) FROM projected),
  'lines',COALESCE((SELECT jsonb_agg(item ORDER BY line_no) FROM projected),'[]'::jsonb))
 FROM header p
$$;
REVOKE ALL ON FUNCTION hrx.purchase_order_fulfillment(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.purchase_order_fulfillment(uuid) TO hrx_recovery_app;
