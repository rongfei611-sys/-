CREATE TABLE hrx.supply_followup (
 task_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),demand_id uuid NOT NULL REFERENCES hrx.supply_demand,
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 2 AND 240),due_date date NOT NULL,
 created_by uuid NOT NULL REFERENCES hrx.user_account,assigned_to uuid NOT NULL REFERENCES hrx.user_account,
 current_status text NOT NULL DEFAULT 'OPEN' CHECK(current_status IN ('OPEN','DONE','CANCELLED')),
 revision integer NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX followup_due ON hrx.supply_followup(current_status,due_date,task_id);
CREATE INDEX followup_demand ON hrx.supply_followup(demand_id,created_at);
CREATE TABLE hrx.supply_followup_event (
 event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),task_id uuid NOT NULL REFERENCES hrx.supply_followup,
 expected_revision integer NOT NULL,event_code text NOT NULL CHECK(event_code IN ('NOTE','RESCHEDULE','COMPLETE','CANCEL')),
 note text NOT NULL CHECK(length(trim(note)) BETWEEN 2 AND 4000),due_date date,previous_due_date date,
 evidence_refs jsonb NOT NULL CHECK(hrx.valid_evidence_refs(evidence_refs)),actor_user_id uuid NOT NULL REFERENCES hrx.user_account,
 occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(task_id,expected_revision)
);
CREATE FUNCTION hrx.followup_visible(p_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM supply_followup t WHERE t.task_id=p_id AND hrx.supply_visible(t.demand_id))
$$;
ALTER TABLE hrx.supply_followup ENABLE ROW LEVEL SECURITY;
ALTER TABLE hrx.supply_followup_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY followup_read ON hrx.supply_followup FOR SELECT USING(hrx.supply_visible(demand_id));
CREATE POLICY followup_event_read ON hrx.supply_followup_event FOR SELECT USING(hrx.followup_visible(task_id));
CREATE FUNCTION hrx.create_followup(p_demand uuid,p_title text,p_due date) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE d supply_demand%ROWTYPE;a uuid:=hrx.current_user_id();v_id uuid:=gen_random_uuid();
BEGIN
 SELECT * INTO d FROM supply_demand WHERE demand_id=p_demand FOR UPDATE;
 IF NOT FOUND OR NOT hrx.supply_visible(p_demand) OR NOT hrx.allowed(d.project_id,'supply_chain','update') OR a NOT IN(d.requested_by,d.buyer_user_id) THEN RAISE EXCEPTION 'Followup owner or scope denied' USING ERRCODE='42501';END IF;
 IF d.current_status IN ('CLOSED','CANCELLED') OR p_due IS NULL OR p_title IS NULL OR length(trim(p_title)) NOT BETWEEN 2 AND 240 THEN RAISE EXCEPTION 'Followup fields or demand state invalid' USING ERRCODE='23514';END IF;
 IF NOT hrx.user_allowed(d.buyer_user_id,d.project_id,'supply_chain','read') OR NOT hrx.user_allowed(d.buyer_user_id,d.project_id,'supply_chain','update') THEN RAISE EXCEPTION 'Assigned buyer not active/authorized' USING ERRCODE='42501';END IF;
 INSERT INTO supply_followup(task_id,demand_id,title,due_date,created_by,assigned_to) VALUES(v_id,p_demand,trim(p_title),p_due,a,d.buyer_user_id);RETURN v_id;
END $$;
CREATE FUNCTION hrx.apply_followup_event(p_id uuid,p_revision integer,p_code text,p_note text,p_due date,p_refs jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE t supply_followup%ROWTYPE;d supply_demand%ROWTYPE;a uuid:=hrx.current_user_id();v_id uuid:=gen_random_uuid();
BEGIN
 SELECT * INTO t FROM supply_followup WHERE task_id=p_id FOR UPDATE;
 IF NOT FOUND OR NOT hrx.supply_visible(t.demand_id) THEN RAISE EXCEPTION 'Followup invisible' USING ERRCODE='42501';END IF;
 SELECT * INTO d FROM supply_demand WHERE demand_id=t.demand_id;
 IF NOT hrx.allowed(d.project_id,'supply_chain','update') OR a NOT IN(t.created_by,t.assigned_to) THEN RAISE EXCEPTION 'Followup actor denied' USING ERRCODE='42501';END IF;
 IF p_revision IS NULL OR p_revision<>t.revision THEN RAISE EXCEPTION 'Followup revision changed' USING ERRCODE='40001';END IF;
 IF t.current_status<>'OPEN' OR p_code IS NULL OR p_code NOT IN ('NOTE','RESCHEDULE','COMPLETE','CANCEL') OR p_note IS NULL OR length(trim(p_note)) NOT BETWEEN 2 AND 4000 OR p_refs IS NULL OR NOT hrx.valid_evidence_refs(p_refs) THEN RAISE EXCEPTION 'Followup state or fields invalid' USING ERRCODE='23514';END IF;
 IF p_code IN ('RESCHEDULE','COMPLETE') AND a<>t.assigned_to OR p_code='CANCEL' AND a<>t.created_by THEN RAISE EXCEPTION 'Followup responsible actor required' USING ERRCODE='42501';END IF;
 IF p_code='RESCHEDULE' AND p_due IS NULL OR p_code<>'RESCHEDULE' AND p_due IS NOT NULL THEN RAISE EXCEPTION 'Only rescheduling accepts a due date' USING ERRCODE='23514';END IF;
 UPDATE supply_followup SET revision=revision+1,due_date=CASE WHEN p_code='RESCHEDULE' THEN p_due ELSE due_date END,current_status=CASE p_code WHEN 'COMPLETE' THEN 'DONE' WHEN 'CANCEL' THEN 'CANCELLED' ELSE current_status END WHERE task_id=p_id;
 INSERT INTO supply_followup_event(event_id,task_id,expected_revision,event_code,note,due_date,previous_due_date,evidence_refs,actor_user_id) VALUES(v_id,p_id,p_revision,p_code,p_note,p_due,CASE WHEN p_code='RESCHEDULE' THEN t.due_date END,p_refs,a);RETURN v_id;
END $$;
GRANT SELECT ON hrx.supply_followup,hrx.supply_followup_event TO hrx_recovery_app;
REVOKE ALL ON FUNCTION hrx.followup_visible(uuid),hrx.create_followup(uuid,text,date),hrx.apply_followup_event(uuid,integer,text,text,date,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.followup_visible(uuid),hrx.create_followup(uuid,text,date),hrx.apply_followup_event(uuid,integer,text,text,date,jsonb) TO hrx_recovery_app;
