-- Independent recovery project delivery records; no production/quality release.
ALTER POLICY project_reference ON hrx.business_project USING(hrx.allowed(project_id,'supply_chain','read') OR hrx.allowed(project_id,'supply_chain','create') OR hrx.allowed(project_id,'project_delivery','read'));
CREATE TABLE hrx.delivery_milestone (
 milestone_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),project_id uuid NOT NULL REFERENCES hrx.business_project,
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 2 AND 240),planned_date date NOT NULL,
 responsible_user_id uuid NOT NULL REFERENCES hrx.user_account,created_by uuid NOT NULL REFERENCES hrx.user_account,
 current_status text NOT NULL DEFAULT 'PLANNED' CHECK(current_status IN ('PLANNED','IN_PROGRESS','SUBMITTED','CONFIRMED','CANCELLED')),
 revision integer NOT NULL DEFAULT 0,submitted_by uuid REFERENCES hrx.user_account,confirmed_by uuid REFERENCES hrx.user_account,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX milestone_project_due ON hrx.delivery_milestone(project_id,planned_date,milestone_id);
CREATE TABLE hrx.delivery_milestone_event (
 event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),milestone_id uuid NOT NULL REFERENCES hrx.delivery_milestone,
 expected_revision integer NOT NULL,event_code text NOT NULL CHECK(event_code IN ('START','NOTE','RESCHEDULE','SUBMIT','CONFIRM','RETURN','CANCEL')),
 note text NOT NULL CHECK(length(trim(note)) BETWEEN 2 AND 4000),planned_date date,previous_planned_date date,
 evidence_refs jsonb NOT NULL CHECK(hrx.valid_evidence_refs(evidence_refs)),actor_user_id uuid NOT NULL REFERENCES hrx.user_account,
 occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(milestone_id,expected_revision)
);
CREATE FUNCTION hrx.milestone_visible(p_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM delivery_milestone m WHERE m.milestone_id=p_id AND hrx.allowed(m.project_id,'project_delivery','read'))
$$;
ALTER TABLE hrx.delivery_milestone ENABLE ROW LEVEL SECURITY;
ALTER TABLE hrx.delivery_milestone_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY milestone_read ON hrx.delivery_milestone FOR SELECT USING(hrx.allowed(project_id,'project_delivery','read'));
CREATE POLICY milestone_event_read ON hrx.delivery_milestone_event FOR SELECT USING(hrx.milestone_visible(milestone_id));
CREATE FUNCTION hrx.delivery_participants(p_project uuid) RETURNS TABLE(user_id uuid,display_name text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT u.user_id,u.display_name FROM user_account u WHERE hrx.allowed(p_project,'project_delivery','read') AND hrx.user_allowed(u.user_id,p_project,'project_delivery','read') AND hrx.user_allowed(u.user_id,p_project,'project_delivery','update') ORDER BY u.display_name,u.user_id LIMIT 300
$$;
CREATE FUNCTION hrx.create_milestone(p_project uuid,p_title text,p_date date,p_owner uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE a uuid:=hrx.current_user_id();v_id uuid:=gen_random_uuid();
BEGIN
 IF NOT hrx.allowed(p_project,'project_delivery','read') OR NOT hrx.allowed(p_project,'project_delivery','create') THEN RAISE EXCEPTION 'Milestone create scope denied' USING ERRCODE='42501';END IF;
 IF p_date IS NULL OR p_title IS NULL OR length(trim(p_title)) NOT BETWEEN 2 AND 240 THEN RAISE EXCEPTION 'Milestone fields invalid' USING ERRCODE='23514';END IF;
 IF p_owner IS NULL OR NOT hrx.user_allowed(p_owner,p_project,'project_delivery','read') OR NOT hrx.user_allowed(p_owner,p_project,'project_delivery','update') THEN RAISE EXCEPTION 'Milestone responsible employee denied' USING ERRCODE='42501';END IF;
 INSERT INTO delivery_milestone(milestone_id,project_id,title,planned_date,responsible_user_id,created_by) VALUES(v_id,p_project,trim(p_title),p_date,p_owner,a);RETURN v_id;
END $$;
CREATE FUNCTION hrx.apply_milestone_event(p_id uuid,p_revision integer,p_code text,p_note text,p_date date,p_refs jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE m delivery_milestone%ROWTYPE;a uuid:=hrx.current_user_id();v_id uuid:=gen_random_uuid();v_status text;
BEGIN
 SELECT * INTO m FROM delivery_milestone WHERE milestone_id=p_id FOR UPDATE;
 IF NOT FOUND OR NOT hrx.allowed(m.project_id,'project_delivery','read') THEN RAISE EXCEPTION 'Milestone invisible' USING ERRCODE='42501';END IF;
 IF p_revision IS NULL OR p_revision<>m.revision THEN RAISE EXCEPTION 'Milestone revision changed' USING ERRCODE='40001';END IF;
 IF p_code IN ('CONFIRM','RETURN') THEN
  IF NOT hrx.allowed(m.project_id,'project_delivery','verify') OR a IN(m.created_by,m.responsible_user_id) OR a IS NOT DISTINCT FROM m.submitted_by THEN RAISE EXCEPTION 'Independent milestone reviewer required' USING ERRCODE='42501';END IF;
 ELSE
  IF NOT hrx.allowed(m.project_id,'project_delivery','update') OR a NOT IN(m.created_by,m.responsible_user_id) OR p_code IN('START','RESCHEDULE','SUBMIT') AND a<>m.responsible_user_id OR p_code='CANCEL' AND a<>m.created_by THEN RAISE EXCEPTION 'Milestone actor denied' USING ERRCODE='42501';END IF;
 END IF;
 IF m.current_status IN ('CONFIRMED','CANCELLED') OR p_note IS NULL OR length(trim(p_note)) NOT BETWEEN 2 AND 4000 OR p_refs IS NULL OR NOT hrx.valid_evidence_refs(p_refs) THEN RAISE EXCEPTION 'Milestone state or fields invalid' USING ERRCODE='23514';END IF;
 IF p_code IN('SUBMIT','CONFIRM') AND jsonb_array_length(p_refs)=0 THEN RAISE EXCEPTION 'Milestone evidence required' USING ERRCODE='23514';END IF;
 IF p_code='RESCHEDULE' AND p_date IS NULL OR p_code<>'RESCHEDULE' AND p_date IS NOT NULL THEN RAISE EXCEPTION 'Only rescheduling accepts planned date' USING ERRCODE='23514';END IF;
 v_status:=CASE p_code
 WHEN 'START' THEN CASE WHEN m.current_status='PLANNED' THEN 'IN_PROGRESS' END
 WHEN 'NOTE' THEN CASE WHEN m.current_status IN('PLANNED','IN_PROGRESS') THEN m.current_status END
 WHEN 'RESCHEDULE' THEN CASE WHEN m.current_status IN('PLANNED','IN_PROGRESS') THEN m.current_status END
 WHEN 'SUBMIT' THEN CASE WHEN m.current_status='IN_PROGRESS' THEN 'SUBMITTED' END
 WHEN 'CONFIRM' THEN CASE WHEN m.current_status='SUBMITTED' THEN 'CONFIRMED' END
 WHEN 'RETURN' THEN CASE WHEN m.current_status='SUBMITTED' THEN 'IN_PROGRESS' END
 WHEN 'CANCEL' THEN CASE WHEN m.current_status IN('PLANNED','IN_PROGRESS') THEN 'CANCELLED' END END;
 IF v_status IS NULL THEN RAISE EXCEPTION 'Milestone transition invalid' USING ERRCODE='23514';END IF;
 UPDATE delivery_milestone SET current_status=v_status,revision=revision+1,planned_date=CASE WHEN p_code='RESCHEDULE' THEN p_date ELSE planned_date END,submitted_by=CASE WHEN p_code='SUBMIT' THEN a ELSE submitted_by END,confirmed_by=CASE WHEN p_code='CONFIRM' THEN a ELSE confirmed_by END WHERE milestone_id=p_id;
 INSERT INTO delivery_milestone_event(event_id,milestone_id,expected_revision,event_code,note,planned_date,previous_planned_date,evidence_refs,actor_user_id) VALUES(v_id,p_id,p_revision,p_code,p_note,p_date,CASE WHEN p_code='RESCHEDULE' THEN m.planned_date END,p_refs,a);RETURN v_id;
END $$;
GRANT SELECT ON hrx.delivery_milestone,hrx.delivery_milestone_event TO hrx_recovery_app;
REVOKE ALL ON FUNCTION hrx.milestone_visible(uuid),hrx.delivery_participants(uuid),hrx.create_milestone(uuid,text,date,uuid),hrx.apply_milestone_event(uuid,integer,text,text,date,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.milestone_visible(uuid),hrx.delivery_participants(uuid),hrx.create_milestone(uuid,text,date,uuid),hrx.apply_milestone_event(uuid,integer,text,text,date,jsonb) TO hrx_recovery_app;

-- Project documents are shared within one authorized project, never moved between parents.
ALTER TABLE hrx.controlled_file ADD COLUMN project_id uuid REFERENCES hrx.business_project;
ALTER TABLE hrx.controlled_file DROP CONSTRAINT one_file_parent;
ALTER TABLE hrx.controlled_file ADD CONSTRAINT one_file_parent CHECK(num_nonnulls(demand_id,purchase_order_id,project_id)=1);
CREATE FUNCTION hrx.project_file_allowed(p_project uuid,p_action text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
 SELECT hrx.allowed(p_project,'project_delivery','read') AND hrx.allowed(p_project,'controlled_file',p_action)
$$;
CREATE OR REPLACE FUNCTION hrx.guard_file() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE previous controlled_file%ROWTYPE;
BEGIN
 IF NEW.uploaded_by IS DISTINCT FROM hrx.current_user_id() OR num_nonnulls(NEW.demand_id,NEW.purchase_order_id,NEW.project_id)<>1
 OR NEW.demand_id IS NOT NULL AND NOT hrx.file_allowed(NEW.demand_id,'create') OR NEW.purchase_order_id IS NOT NULL AND NOT hrx.po_file_allowed(NEW.purchase_order_id,'create') OR NEW.project_id IS NOT NULL AND NOT hrx.project_file_allowed(NEW.project_id,'create') THEN RAISE EXCEPTION 'File upload denied' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(NEW.document_id::text||':version',0));
 SELECT * INTO previous FROM controlled_file WHERE document_id=NEW.document_id ORDER BY version DESC LIMIT 1;
 IF NEW.version<>COALESCE(previous.version,0)+1 THEN RAISE EXCEPTION 'File version changed' USING ERRCODE='40001';END IF;
 IF previous.file_id IS NOT NULL AND (previous.demand_id IS DISTINCT FROM NEW.demand_id OR previous.purchase_order_id IS DISTINCT FROM NEW.purchase_order_id OR previous.project_id IS DISTINCT FROM NEW.project_id) THEN RAISE EXCEPTION 'Cannot move a file between objects' USING ERRCODE='42501';END IF;
 NEW.created_at:=clock_timestamp();RETURN NEW;
END $$;
ALTER POLICY file_read ON hrx.controlled_file USING(demand_id IS NOT NULL AND hrx.file_allowed(demand_id,'read') OR purchase_order_id IS NOT NULL AND hrx.po_file_allowed(purchase_order_id,'read') OR project_id IS NOT NULL AND hrx.project_file_allowed(project_id,'read'));
ALTER POLICY file_append ON hrx.controlled_file WITH CHECK(uploaded_by=hrx.current_user_id() AND (demand_id IS NOT NULL AND hrx.file_allowed(demand_id,'create') OR purchase_order_id IS NOT NULL AND hrx.po_file_allowed(purchase_order_id,'create') OR project_id IS NOT NULL AND hrx.project_file_allowed(project_id,'create')));
REVOKE ALL ON FUNCTION hrx.project_file_allowed(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.project_file_allowed(uuid,text) TO hrx_recovery_app;
