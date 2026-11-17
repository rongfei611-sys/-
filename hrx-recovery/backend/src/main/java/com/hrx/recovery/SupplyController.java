package com.hrx.recovery;
import java.util.*;
import java.math.BigDecimal;
import java.time.LocalDate;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.validation.annotation.Validated;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;
@RestController @RequestMapping("/api/v1/supply-chain") @Validated
public class SupplyController {
 private final JdbcTemplate jdbc;private final ApiSupport api;private final IdempotencyService keys;private final FileService files;
 public SupplyController(JdbcTemplate jdbc,ApiSupport api,IdempotencyService keys,FileService files){this.jdbc=jdbc;this.api=api;this.keys=keys;this.files=files;}
 @GetMapping("/projects") public List<Map<String,Object>> projects(){return jdbc.queryForList("SELECT project_id::text,project_code,project_name FROM hrx.business_project ORDER BY project_code LIMIT 300");}
 @GetMapping("/projects/{id}/participants") public List<Map<String,Object>> buyers(@PathVariable UUID id){return jdbc.queryForList("SELECT * FROM hrx.supply_buyers(?)",id);}
 static final String SELECT="""
 SELECT d.*,(quantity-accepted_qty) shortage_qty,(received_qty-accepted_qty-rejected_qty) pending_iqc_qty,
 CASE WHEN current_status='CANCELLED' THEN 'CANCELLED' WHEN accepted_qty=quantity THEN 'READY' WHEN rejected_qty>0 THEN 'IQC_REJECTED'
 WHEN required_date<current_date THEN 'OVERDUE' WHEN current_status IN ('ORDERED','PART_RECEIVED','RECEIVED') AND promised_date IS NULL THEN 'PROMISE_MISSING'
 WHEN promised_date>required_date THEN 'PROMISE_LATE' WHEN current_status IN ('DRAFT','SUBMITTED','SOURCING','APPROVED') AND current_date>=required_date-lead_time_days THEN 'LEAD_TIME_RISK'
 WHEN received_qty>accepted_qty+rejected_qty THEN 'IQC_PENDING' ELSE 'IN_PROGRESS' END risk_code FROM hrx.supply_demand d
 """;
 @GetMapping("/demands") public Map<String,Object> list(@RequestParam(defaultValue="0") @Min(0) @Max(100000) int page,@RequestParam(defaultValue="20") @Min(1) @Max(100) int size,@RequestParam(required=false) @Size(max=120) String q){
  String where=" WHERE 1=1";var args=new ArrayList<Object>();if(q!=null&&!q.isBlank()){where+=" AND (bom_line ILIKE ? OR material_code ILIKE ? OR description ILIKE ?)";for(int i=0;i<3;i++)args.add("%"+q.trim()+"%");}
  Long count=jdbc.queryForObject("SELECT count(*) FROM hrx.supply_demand"+where,Long.class,args.toArray());args.add(size);args.add(page*size);
  return Map.of("items",jdbc.queryForList(SELECT+where+" ORDER BY required_date,demand_id LIMIT ? OFFSET ?",args.toArray()),"total",count,"page",page,"size",size);
 }
 @GetMapping("/demands/{id}") public Map<String,Object> get(@PathVariable UUID id){var rows=jdbc.queryForList(SELECT+" WHERE demand_id=?",id);if(rows.isEmpty())throw new ResponseStatusException(HttpStatus.NOT_FOUND,"需求不存在或无权访问");return rows.getFirst();}
 @GetMapping("/demands/{id}/events") public List<Map<String,Object>> events(@PathVariable UUID id){get(id);return jdbc.queryForList("SELECT * FROM hrx.supply_events(?)",id);}
 @GetMapping("/supplier-delivery") public List<Map<String,Object>> delivery(){return jdbc.queryForList("SELECT * FROM hrx.supplier_delivery()");}
 @PostMapping("/demands") public Map<String,Object> create(@Valid @RequestBody Demand req,@RequestHeader("Idempotency-Key") String key){UUID actor=api.actor();return keys.execute(actor,"demand.create",key,req,()->{
  UUID id=jdbc.queryForObject("INSERT INTO hrx.supply_demand(project_id,bom_line,material_code,description,unit,quantity,required_date,lead_time_days,critical_path,requested_by,buyer_user_id) VALUES (?,?,?,?,?,?,?,?,?,?,?) RETURNING demand_id",UUID.class,req.projectId(),req.bomLine().trim(),req.materialCode().trim(),req.description().trim(),req.unit().trim(),req.quantity(),req.requiredDate(),req.leadTimeDays(),req.criticalPath(),actor,req.buyerUserId());
  api.audit(actor,"demand.create",id,Map.of("projectId",req.projectId().toString()));return Map.of("demand_id",id.toString(),"revision",0,"current_status","DRAFT");
 });}
 @PostMapping("/demands/{id}/events") public Map<String,Object> append(@PathVariable UUID id,@Valid @RequestBody Event req,@RequestHeader("Idempotency-Key") String key){UUID actor=api.actor();return keys.execute(actor,"event."+id,key,req,()->{
  get(id);files.requireEvidence(id,req.evidenceRefs());
  UUID event=jdbc.queryForObject("INSERT INTO hrx.supply_event(demand_id,expected_revision,event_code,note,payload,evidence_refs,actor_user_id) VALUES (?,?,?,?,?::jsonb,?::jsonb,?) RETURNING event_id",UUID.class,id,req.expectedRevision(),req.eventCode(),req.note(),api.encode(req.payload()),api.encode(req.evidenceRefs()),actor);
  api.audit(actor,req.eventCode(),id,Map.of("eventId",event.toString()));return Map.of("event_id",event.toString(),"revision",req.expectedRevision()+1);
 });}
 public record Demand(@NotNull UUID projectId,@NotBlank @Size(max=80) String bomLine,@NotBlank @Size(max=120) String materialCode,@NotBlank @Size(min=2,max=1000) String description,@NotBlank @Size(max=20) String unit,@NotNull @DecimalMin(value="0",inclusive=false) @Digits(integer=14,fraction=4) BigDecimal quantity,@NotNull LocalDate requiredDate,@Min(0) @Max(3650) int leadTimeDays,boolean criticalPath,@NotNull UUID buyerUserId){}
 public record Event(@NotNull @Min(0) Integer expectedRevision,@NotNull @Pattern(regexp="SUBMIT|OPEN_RFQ|QUOTE|APPROVE|REJECT|ISSUE_PO|PROMISE|RECEIVE|IQC|CANCEL") String eventCode,@NotBlank @Size(min=2,max=4000) String note,@NotNull @Size(max=20) Map<String,Object> payload,@NotNull @Size(max=50) List<@NotNull @Pattern(regexp="hrx-file:[A-Za-z0-9][A-Za-z0-9/_-]{0,500}") String> evidenceRefs){}
}
