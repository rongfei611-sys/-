package com.hrx.recovery;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.*;
@RestController @RequestMapping("/api/v1/me")
public class ProfileController {
 private final JdbcTemplate jdbc;public ProfileController(JdbcTemplate jdbc){this.jdbc=jdbc;}
 @GetMapping("/profile") public Map<String,Object> profile(){return jdbc.queryForMap("SELECT user_id::text,display_name,org_unit_code,job_title FROM hrx.user_account WHERE user_id=hrx.current_user_id()");}
 @GetMapping("/capabilities") public Map<String,Object> capabilities(){Map<String,Map<String,Boolean>> out=new TreeMap<>();jdbc.queryForList("SELECT * FROM hrx.capabilities()").forEach(r->out.computeIfAbsent(r.get("resource_type").toString(),k->new TreeMap<>()).put(r.get("action_code").toString(),true));return Map.of("capabilities",out);}
}
