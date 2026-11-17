package com.hrx.recovery;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.*;
import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.function.Supplier;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.*;
import org.springframework.stereotype.Service;
import org.springframework.web.server.ResponseStatusException;
@Service
public class IdempotencyService {
 private final JdbcTemplate jdbc;private final ObjectMapper json;
 public IdempotencyService(JdbcTemplate jdbc,ObjectMapper json){this.jdbc=jdbc;this.json=json;}
 public Map<String,Object> execute(UUID actor,String operation,String key,Object body,Supplier<Map<String,Object>> action){
  if(key==null||!key.matches("[A-Za-z0-9._:-]{8,128}"))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"幂等键必须为8至128位安全字符");
  String hash;try{String data=json.writer().with(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS).writeValueAsString(body);hash=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data.getBytes(StandardCharsets.UTF_8)));}catch(Exception e){throw new IllegalArgumentException("请求无法规范化");}
  jdbc.execute((ConnectionCallback<Void>)c->{try(var s=c.prepareStatement("SELECT pg_advisory_xact_lock(hashtextextended(?,0))")){s.setString(1,actor+":"+operation+":"+key);s.execute();}return null;});
  var rows=jdbc.queryForList("SELECT request_hash,response_body::text response_body FROM hrx.api_idempotency WHERE actor_user_id=? AND operation=? AND idempotency_key=?",actor,operation,key);
  if(!rows.isEmpty()){
   var row=rows.getFirst();if(!hash.equals(row.get("request_hash")))throw new ResponseStatusException(HttpStatus.CONFLICT,"幂等键已用于其他请求");
   try{return json.readValue((String)row.get("response_body"),new TypeReference<Map<String,Object>>(){});}catch(Exception e){throw new IllegalStateException("幂等记录损坏");}
  }
  var response=action.get();try{jdbc.update("INSERT INTO hrx.api_idempotency(actor_user_id,operation,idempotency_key,request_hash,response_body) VALUES (?,?,?,?,?::jsonb)",actor,operation,key,hash,json.writeValueAsString(response));}catch(com.fasterxml.jackson.core.JsonProcessingException e){throw new IllegalStateException(e);}return response;
 }
}
