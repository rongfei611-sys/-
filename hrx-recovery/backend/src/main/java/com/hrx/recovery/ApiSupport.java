package com.hrx.recovery;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;
@Component
public class ApiSupport {
 private final JdbcTemplate jdbc;private final ObjectMapper json;
 public ApiSupport(JdbcTemplate jdbc,ObjectMapper json){this.jdbc=jdbc;this.json=json;}
 public UUID actor(){UUID id=jdbc.queryForObject("SELECT hrx.current_user_id()",UUID.class);if(id==null)throw new ResponseStatusException(HttpStatus.FORBIDDEN,"身份无效");return id;}
 public String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw new IllegalArgumentException("无法编码请求");}}
 public void audit(UUID actor,String action,UUID id,Map<String,Object> metadata){jdbc.update("INSERT INTO hrx.audit_event(actor_user_id,action_code,resource_id,metadata) VALUES (?,?,?,?::jsonb)",actor,action,id,encode(metadata));}
}
