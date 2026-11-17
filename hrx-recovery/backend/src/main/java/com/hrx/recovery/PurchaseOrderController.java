package com.hrx.recovery;
import java.util.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;
@RestController @RequestMapping("/api/v1/purchase-orders") @Validated
public class PurchaseOrderController {
 private final JdbcTemplate jdbc;private final ApiSupport api;private final IdempotencyService keys;private final FileService files;
 public PurchaseOrderController(JdbcTemplate jdbc,ApiSupport api,IdempotencyService keys,FileService files){this.jdbc=jdbc;this.api=api;this.keys=keys;this.files=files;}
 @GetMapping public Map<String,Object> list(@RequestParam(defaultValue="0") @Min(0) @Max(100000) int page,@RequestParam(defaultValue="20") @Min(1) @Max(100) int size,@RequestParam(required=false) @Size(max=120) String q){
  String where=" WHERE 1=1";var args=new ArrayList<Object>();if(q!=null&&!q.isBlank()){where+=" AND (order_no ILIKE ? OR supplier ILIKE ? OR project_code ILIKE ?)";for(int n=0;n<3;n++)args.add("%"+q.trim()+"%");}
  Long count=jdbc.queryForObject("SELECT count(*) FROM hrx.purchase_orders()"+where,Long.class,args.toArray());args.add(size);args.add(page*size);
  return Map.of("items",jdbc.queryForList("SELECT * FROM hrx.purchase_orders()"+where+" ORDER BY created_at DESC,order_id LIMIT ? OFFSET ?",args.toArray()),"total",count,"page",page,"size",size);
 }
 @GetMapping("/candidates") public List<Map<String,Object>> candidates(){return jdbc.queryForList("SELECT * FROM hrx.purchase_order_candidates()");}
 @GetMapping("/{id}") public Map<String,Object> get(@PathVariable UUID id){var rows=jdbc.queryForList("SELECT * FROM hrx.purchase_orders() WHERE order_id=?",id);if(rows.isEmpty())throw new ResponseStatusException(HttpStatus.NOT_FOUND,"采购订单不存在或无权访问");return rows.getFirst();}
 @GetMapping(value="/{id}/fulfillment",produces="application/json") public org.springframework.http.ResponseEntity<String> fulfillment(@PathVariable UUID id){get(id);String result=jdbc.queryForObject("SELECT hrx.purchase_order_fulfillment(?)::text",String.class,id);if(result==null)throw new ResponseStatusException(HttpStatus.NOT_FOUND,"采购订单不存在或无权访问");return org.springframework.http.ResponseEntity.ok().contentType(org.springframework.http.MediaType.APPLICATION_JSON).body(result);}
 @GetMapping("/{id}/actions") public List<String> actions(@PathVariable UUID id){get(id);return jdbc.queryForList("SELECT event_code FROM hrx.purchase_order_actions(?)",String.class,id);}
 @GetMapping("/{id}/lines") public List<Map<String,Object>> lines(@PathVariable UUID id){get(id);return jdbc.queryForList("SELECT * FROM hrx.purchase_order_lines(?)",id);}
 @GetMapping("/{id}/events") public List<Map<String,Object>> events(@PathVariable UUID id){get(id);return jdbc.queryForList("SELECT event_id::text,event_code,expected_revision,note,evidence_refs::text,actor_user_id::text,occurred_at FROM hrx.purchase_order_event WHERE order_id=? ORDER BY expected_revision",id);}
 @PostMapping public Map<String,Object> create(@Valid @RequestBody CreateOrder req,@RequestHeader("Idempotency-Key") String key){UUID actor=api.actor();return keys.execute(actor,"purchase_order.create",key,req,()->{
  UUID id=jdbc.queryForObject("SELECT hrx.create_purchase_order(?,?,?::jsonb)",UUID.class,req.orderNo(),req.note(),api.encode(req.lines()));api.audit(actor,"purchase_order.create",id,Map.of("lineCount",req.lines().size()));return Map.of("order_id",id.toString(),"revision",0,"current_status","PENDING_APPROVAL");
 });}
 @PostMapping("/{id}/events") public Map<String,Object> append(@PathVariable UUID id,@Valid @RequestBody OrderEvent req,@RequestHeader("Idempotency-Key") String key){UUID actor=api.actor();return keys.execute(actor,"purchase_order.event."+id,key,req,()->{
  get(id);files.requireOrderEvidence(id,req.evidenceRefs());UUID event=jdbc.queryForObject("SELECT hrx.apply_purchase_order_event(?,?,?, ?,?::jsonb)",UUID.class,id,req.expectedRevision(),req.eventCode(),req.note(),api.encode(req.evidenceRefs()));api.audit(actor,"purchase_order."+req.eventCode(),id,Map.of("eventId",event.toString()));return Map.of("event_id",event.toString(),"revision",req.expectedRevision()+1);
 });}
 public record DemandRef(@NotNull UUID demandId,@NotNull @Min(0) Integer expectedRevision){}
 public record CreateOrder(@NotBlank @Size(max=100) String orderNo,@NotBlank @Size(min=2,max=4000) String note,@NotNull @Size(min=1,max=100) List<@NotNull @Valid DemandRef> lines){}
 public record OrderEvent(@NotNull @Min(0) Integer expectedRevision,@NotNull @Pattern(regexp="APPROVED|REJECTED|ISSUED|CANCELLED") String eventCode,@NotBlank @Size(min=2,max=4000) String note,@NotNull @Size(max=50) List<@NotNull @Pattern(regexp="hrx-file:[A-Za-z0-9][A-Za-z0-9/_-]{0,500}") String> evidenceRefs){}
}
