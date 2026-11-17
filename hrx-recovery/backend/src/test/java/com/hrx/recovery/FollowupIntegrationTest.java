package com.hrx.recovery;
import java.util.*;import java.util.concurrent.*;
import org.junit.jupiter.api.*;import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;import org.springframework.beans.factory.annotation.Autowired;import org.springframework.boot.test.context.SpringBootTest;import org.springframework.boot.test.web.server.LocalServerPort;import org.springframework.jdbc.core.JdbcTemplate;import org.springframework.test.context.*;
import static org.junit.jupiter.api.Assertions.*;import static com.hrx.recovery.TestSupport.*;
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT)
@EnabledIfEnvironmentVariable(named="HRX_TEST_DB_URL",matches="jdbc:postgresql:.*hrx_test_.*")
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class FollowupIntegrationTest {
 @LocalServerPort int port;@Autowired JdbcTemplate runtime;
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){properties(r);}
 @BeforeAll void prepare(){fixtures();}
 String demandId(int requester) throws Exception{var r=request(port,requester,"/supply-chain/demands",demand(),keyId());assertEquals(200,r.statusCode(),r.body());return JSON.readTree(r.body()).get("demand_id").asText();}
 Map<String,Object> body(String id){return Map.of("demandId",id,"title","TEST followup "+keyId(),"dueDate",today().minusDays(1).toString());}
 String create(int actor,Map<String,Object> b,String key,int code) throws Exception{var r=request(port,actor,"/supply-chain/followups",b,key);assertEquals(code,r.statusCode(),r.body());return JSON.readTree(r.body()).path("task_id").asText();}
 Map<String,Object> change(int rev,String code){return new HashMap<>(Map.of("expectedRevision",rev,"eventCode",code,"note","TEST followup "+code,"evidenceRefs",List.of()));}
 void event(int actor,String id,Map<String,Object> b,int code) throws Exception{var r=request(port,actor,"/supply-chain/followups/"+id+"/events",b,keyId());assertEquals(code,r.statusCode(),r.body());}
 @Test void ownershipHistoryReschedulingAndCompletionNeverChangeDemand() throws Exception{
  String d=demandId(2),key=keyId();var b=body(d);String id=create(2,b,key,200);assertEquals(id,create(2,b,key,200));var changed=new HashMap<>(b);changed.put("title","TEST altered");create(2,changed,key,409);create(3,b,keyId(),403);create(6,b,keyId(),403);create(5,b,keyId(),403);
  var t=JSON.readTree(request(port,1,"/supply-chain/followups/"+id,null,null).body());assertEquals(user(1).toString(),t.get("assigned_to").asText());assertTrue(t.get("overdue").asBoolean());assertEquals(404,request(port,5,"/supply-chain/followups/"+id,null,null).statusCode());
  event(2,id,change(0,"COMPLETE"),403);event(3,id,change(0,"NOTE"),403);event(2,id,change(0,"NOTE"),200);var reschedule=change(1,"RESCHEDULE");reschedule.put("dueDate",today().plusDays(3).toString());event(2,id,reschedule,403);event(1,id,reschedule,200);event(1,id,change(1,"COMPLETE"),409);event(1,id,change(2,"COMPLETE"),200);event(1,id,change(3,"NOTE"),422);
  var finished=JSON.readTree(request(port,6,"/supply-chain/followups/"+id,null,null).body());assertEquals("DONE",finished.get("current_status").asText());assertFalse(finished.get("overdue").asBoolean());var history=JSON.readTree(request(port,1,"/supply-chain/followups/"+id+"/events",null,null).body());assertEquals(3,history.size());assertEquals(today().minusDays(1).toString(),history.get(1).get("previous_due_date").asText());assertEquals(today().plusDays(3).toString(),history.get(1).get("due_date").asText());var demandRow=JSON.readTree(request(port,1,"/supply-chain/demands/"+d,null,null).body());assertEquals(0,demandRow.get("revision").asInt());assertEquals("DRAFT",demandRow.get("current_status").asText());assertEquals(4,admin().queryForObject("SELECT count(*) FROM hrx.audit_event WHERE resource_id=?::uuid",Integer.class,id));
 }
 @Test void cancellationScopeFiltersAndRevocationRemainEnforced() throws Exception{
  String d=demandId(2),id=create(2,body(d),keyId(),200);event(1,id,change(0,"CANCEL"),403);var invalid=change(0,"NOTE");invalid.put("dueDate",today().toString());event(1,id,invalid,422);event(1,id,change(0,"RESCHEDULE"),422);event(2,id,change(0,"CANCEL"),200);event(2,id,change(1,"NOTE"),422);
  var cancelled=JSON.readTree(request(port,1,"/supply-chain/followups?state=CANCELLED&demandId="+d,null,null).body());assertEquals(1,cancelled.get("total").asInt());assertEquals(0,JSON.readTree(request(port,2,"/supply-chain/followups?state=ALL&mine=true&demandId="+d,null,null).body()).get("total").asInt());assertEquals(400,request(port,1,"/supply-chain/followups?state=INVALID",null,null).statusCode());assertEquals(0,JSON.readTree(request(port,5,"/supply-chain/followups?state=ALL",null,null).body()).get("total").asInt());
  admin().update("UPDATE hrx.capability_grant SET enabled=false WHERE user_id=? AND resource_type='supply_chain' AND action_code='read'",user(1));try{assertEquals(404,request(port,1,"/supply-chain/followups/"+id,null,null).statusCode());assertEquals(0,JSON.readTree(request(port,1,"/supply-chain/followups?state=ALL&demandId="+d,null,null).body()).get("total").asInt());}finally{admin().update("UPDATE hrx.capability_grant SET enabled=true WHERE user_id=? AND resource_type='supply_chain' AND action_code='read'",user(1));}
  assertThrows(org.springframework.dao.DataAccessException.class,()->runtime.update("UPDATE hrx.supply_followup SET current_status='DONE'"));assertThrows(org.springframework.dao.DataAccessException.class,()->runtime.update("DELETE FROM hrx.supply_followup_event"));assertTrue(runtime.queryForList("SELECT * FROM hrx.supply_followup").isEmpty());
 }
 @Test void concurrentCompletionHasOneWinnerAndReplayIsStable() throws Exception{
  String d=demandId(1),id=create(1,body(d),keyId(),200);var b=change(0,"COMPLETE");var pool=Executors.newFixedThreadPool(2);try{Callable<Integer> complete=()->request(port,1,"/supply-chain/followups/"+id+"/events",b,keyId()).statusCode();var x=pool.submit(complete);var y=pool.submit(complete);assertEquals(Set.of(200,409),new HashSet<>(List.of(x.get(15,TimeUnit.SECONDS),y.get(15,TimeUnit.SECONDS))));}finally{pool.shutdownNow();}
  String other=create(1,body(d),keyId(),200),key=keyId();var r=request(port,1,"/supply-chain/followups/"+other+"/events",b,key);assertEquals(200,r.statusCode(),r.body());var replay=request(port,1,"/supply-chain/followups/"+other+"/events",b,key);assertEquals(200,replay.statusCode(),replay.body());assertEquals(JSON.readTree(r.body()),JSON.readTree(replay.body()));
  String pending=create(1,body(d),keyId(),200);var closed=TestSupport.event(0,"CANCEL",Map.of());assertEquals(200,request(port,1,"/supply-chain/demands/"+d+"/events",closed,keyId()).statusCode());create(1,body(d),keyId(),422);event(1,pending,change(0,"COMPLETE"),200);
 }
 @Test @EnabledIfEnvironmentVariable(named="HRX_BROWSER",matches="true") void browserFollowup() throws Exception{
  String id=demandId(1),line=admin().queryForObject("SELECT bom_line FROM hrx.supply_demand WHERE demand_id=?::uuid",String.class,id);BrowserRunner.run(port,"followups.mjs",Map.of("user1",token(1),"user6",token(6)),Map.of("HRX_E2E_LINE",line));
 }
}
