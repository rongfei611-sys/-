-- Edges are fixed at creation and point only to existing milestones: no edit API or cycles.
ALTER TABLE hrx.delivery_milestone ADD CONSTRAINT milestone_project_key UNIQUE(milestone_id,project_id);
CREATE TABLE hrx.milestone_dependency (
 milestone_id uuid NOT NULL,predecessor_id uuid NOT NULL,project_id uuid NOT NULL,
 PRIMARY KEY(milestone_id,predecessor_id),CHECK(milestone_id<>predecessor_id),
 FOREIGN KEY(milestone_id,project_id) REFERENCES hrx.delivery_milestone(milestone_id,project_id),
 FOREIGN KEY(predecessor_id,project_id) REFERENCES hrx.delivery_milestone(milestone_id,project_id)
);
CREATE INDEX dependency_successors ON hrx.milestone_dependency(predecessor_id,milestone_id);
ALTER TABLE hrx.milestone_dependency ENABLE ROW LEVEL SECURITY;
CREATE POLICY dependency_read ON hrx.milestone_dependency FOR SELECT USING(hrx.milestone_visible(milestone_id) AND hrx.milestone_visible(predecessor_id));
GRANT SELECT ON hrx.milestone_dependency TO hrx_recovery_app;
CREATE VIEW hrx.delivery_milestone_progress WITH(security_invoker=true) AS
 SELECT m.*,
 (SELECT count(*) FROM hrx.milestone_dependency d WHERE d.milestone_id=m.milestone_id) predecessor_count,
 (SELECT count(*) FROM hrx.milestone_dependency d JOIN hrx.delivery_milestone p ON p.milestone_id=d.predecessor_id WHERE d.milestone_id=m.milestone_id AND p.current_status<>'CONFIRMED') unconfirmed_predecessors,
 (SELECT count(*) FROM hrx.milestone_dependency d JOIN hrx.delivery_milestone n ON n.milestone_id=d.milestone_id WHERE d.predecessor_id=m.milestone_id AND n.current_status<>'CANCELLED') active_successors,
 (SELECT count(*) FROM hrx.milestone_dependency d JOIN hrx.delivery_milestone p ON p.milestone_id=d.predecessor_id WHERE d.milestone_id=m.milestone_id AND p.planned_date>m.planned_date) late_predecessor_dates,
 m.current_status='PLANNED' AND EXISTS(SELECT 1 FROM hrx.milestone_dependency d JOIN hrx.delivery_milestone p ON p.milestone_id=d.predecessor_id WHERE d.milestone_id=m.milestone_id AND p.current_status<>'CONFIRMED') blocked
 FROM hrx.delivery_milestone m;
GRANT SELECT ON hrx.delivery_milestone_progress TO hrx_recovery_app;
CREATE FUNCTION hrx.create_milestone_with_dependencies(p_project uuid,p_title text,p_date date,p_owner uuid,p_predecessors jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
DECLARE v_id uuid;r record;p delivery_milestone%ROWTYPE;
BEGIN
 IF jsonb_typeof(p_predecessors) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Predecessor list required' USING ERRCODE='23514';END IF;
 IF jsonb_array_length(p_predecessors)>30 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_predecessors) e WHERE jsonb_typeof(e)<>'string') THEN RAISE EXCEPTION 'Predecessor list invalid' USING ERRCODE='23514';END IF;
 IF (SELECT count(DISTINCT value::uuid) FROM jsonb_array_elements_text(p_predecessors))<>jsonb_array_length(p_predecessors) THEN RAISE EXCEPTION 'Duplicate predecessor' USING ERRCODE='23514';END IF;
 v_id:=hrx.create_milestone(p_project,p_title,p_date,p_owner);
 FOR r IN SELECT value::uuid id FROM jsonb_array_elements_text(p_predecessors) ORDER BY id LOOP
  SELECT * INTO p FROM delivery_milestone WHERE milestone_id=r.id FOR UPDATE;
  IF NOT FOUND OR p.project_id<>p_project OR NOT hrx.milestone_visible(p.milestone_id) THEN RAISE EXCEPTION 'Predecessor scope denied' USING ERRCODE='42501';END IF;
  IF p.current_status='CANCELLED' THEN RAISE EXCEPTION 'Cancelled predecessor unavailable' USING ERRCODE='40001';END IF;
  INSERT INTO milestone_dependency(milestone_id,predecessor_id,project_id) VALUES(v_id,p.milestone_id,p_project);
 END LOOP;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION hrx.create_milestone_with_dependencies(uuid,text,date,uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hrx.create_milestone_with_dependencies(uuid,text,date,uuid,jsonb) TO hrx_recovery_app;

CREATE OR REPLACE FUNCTION hrx.apply_milestone_event(p_id uuid,p_revision integer,p_code text,p_note text,p_date date,p_refs jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=hrx,pg_temp AS $$
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
 IF p_code IN ('START','SUBMIT','CONFIRM') AND EXISTS(SELECT 1 FROM milestone_dependency x JOIN delivery_milestone prev ON prev.milestone_id=x.predecessor_id WHERE x.milestone_id=p_id AND prev.current_status<>'CONFIRMED') THEN RAISE EXCEPTION 'Predecessors must be independently confirmed' USING ERRCODE='40001';END IF;
 IF p_code='CANCEL' AND EXISTS(SELECT 1 FROM milestone_dependency x JOIN delivery_milestone next ON next.milestone_id=x.milestone_id WHERE x.predecessor_id=p_id AND next.current_status<>'CANCELLED') THEN RAISE EXCEPTION 'Active successors prevent cancellation' USING ERRCODE='40001';END IF;
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
