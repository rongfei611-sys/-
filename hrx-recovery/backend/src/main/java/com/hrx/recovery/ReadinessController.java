package com.hrx.recovery;
import java.util.*;
import jakarta.validation.constraints.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.validation.annotation.Validated;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;
@RestController @RequestMapping("/api/v1/supply-chain/readiness") @Validated
public class ReadinessController {
 private final JdbcTemplate jdbc;
 public ReadinessController(JdbcTemplate jdbc){this.jdbc=jdbc;}
 @GetMapping public Map<String,Object> projects(@RequestParam(defaultValue="0") @Min(0) @Max(100000) int page,@RequestParam(defaultValue="20") @Min(1) @Max(100) int size,@RequestParam(defaultValue="") @Size(max=120) String q){
  String where=" WHERE hrx.allowed(p.project_id,'supply_chain','read') AND (p.project_code ILIKE ? OR p.project_name ILIKE ?)",search="%"+q.trim()+"%";
  Long count=jdbc.queryForObject("SELECT count(*) FROM hrx.business_project p"+where,Long.class,search,search);
  String sql="""
   SELECT p.project_id::text,p.project_code,p.project_name,current_date AS business_date,
   count(d.demand_id) AS total_lines,count(d.demand_id) FILTER(WHERE d.current_status='CANCELLED') AS cancelled_lines,
   count(d.demand_id) FILTER(WHERE d.current_status<>'CANCELLED') AS active_lines,
   count(d.demand_id) FILTER(WHERE d.current_status='CLOSED') AS ready_lines,
   count(d.demand_id) FILTER(WHERE d.current_status<>'CANCELLED' AND d.shortage_qty>0) AS shortage_lines,
   count(d.demand_id) FILTER(WHERE d.overdue) AS overdue_lines,
   count(d.demand_id) FILTER(WHERE d.current_status<>'CANCELLED' AND d.critical_path AND d.shortage_qty>0) AS critical_shortage_lines,
   count(d.demand_id) FILTER(WHERE d.pending_iqc_qty>0) AS pending_iqc_lines,
   count(d.demand_id) FILTER(WHERE d.outstanding_rejected_qty>0) AS rejected_lines,
   count(d.demand_id) FILTER(WHERE d.promise_missing) AS promise_missing_lines,
   count(d.demand_id) FILTER(WHERE d.promise_late) AS promise_late_lines,
   count(d.demand_id) FILTER(WHERE d.replacement_pending) AS replacement_lines,
   min(d.required_date) FILTER(WHERE d.current_status<>'CANCELLED' AND d.shortage_qty>0) AS next_required_date
   FROM hrx.business_project p LEFT JOIN hrx.supply_progress d ON d.project_id=p.project_id
   """+where+" GROUP BY p.project_id ORDER BY p.project_code,p.project_id LIMIT ? OFFSET ?";
  return Map.of("items",jdbc.queryForList(sql,search,search,size,page*size),"total",count,"page",page,"size",size);
 }
 @GetMapping("/{project}/demands") public Map<String,Object> demands(@PathVariable UUID project,@RequestParam(defaultValue="ALL") String filter,@RequestParam(defaultValue="0") @Min(0) @Max(100000) int page,@RequestParam(defaultValue="20") @Min(1) @Max(100) int size){
  if(!Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM hrx.business_project WHERE project_id=? AND hrx.allowed(project_id,'supply_chain','read'))",Boolean.class,project)))throw new ResponseStatusException(HttpStatus.NOT_FOUND,"项目不存在或无权访问");
  String condition=switch(filter){case "ALL"->"true";case "SHORTAGE"->"current_status<>'CANCELLED' AND shortage_qty>0";case "READY"->"current_status='CLOSED'";case "OVERDUE"->"overdue";case "CRITICAL"->"current_status<>'CANCELLED' AND critical_path AND shortage_qty>0";case "IQC"->"pending_iqc_qty>0";case "REJECTED"->"outstanding_rejected_qty>0";case "PROMISE_MISSING"->"promise_missing";case "PROMISE_LATE"->"promise_late";case "REPLACEMENT"->"replacement_pending";default->throw new IllegalArgumentException("不支持的齐套筛选条件");};
  String where=" WHERE project_id=? AND ("+condition+")";Long count=jdbc.queryForObject("SELECT count(*) FROM hrx.supply_progress"+where,Long.class,project);
  return Map.of("items",jdbc.queryForList(SupplyController.SELECT+where+" ORDER BY critical_path DESC,required_date,demand_id LIMIT ? OFFSET ?",project,size,page*size),"total",count,"page",page,"size",size);
 }
}
