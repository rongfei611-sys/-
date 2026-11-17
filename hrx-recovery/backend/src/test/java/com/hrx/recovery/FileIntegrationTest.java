package com.hrx.recovery;
import java.util.*;import java.nio.file.*;
import org.junit.jupiter.api.*;import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;import org.springframework.boot.test.context.SpringBootTest;import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;import org.springframework.boot.test.web.server.LocalServerPort;import org.springframework.mock.web.MockMultipartFile;import org.springframework.test.context.*;import org.springframework.test.web.servlet.MockMvc;
import static com.hrx.recovery.TestSupport.*;import static org.junit.jupiter.api.Assertions.*;import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT) @AutoConfigureMockMvc
@EnabledIfEnvironmentVariable(named="HRX_TEST_DB_URL",matches="jdbc:postgresql:.*hrx_test_.*")
@EnabledIfEnvironmentVariable(named="HRX_CLAMSCAN",matches=".+")
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class FileIntegrationTest {
 static final Path ROOT=Path.of("target","private-files-"+UUID.randomUUID()).toAbsolutePath();
 @DynamicPropertySource static void config(DynamicPropertyRegistry r){properties(r);r.add("hrx.files.enabled",()->true);r.add("hrx.files.directory",()->ROOT.toString());r.add("hrx.files.scanner",()->System.getenv("HRX_CLAMSCAN"));r.add("hrx.files.signatures",()->System.getenv("HRX_SIGNATURES"));r.add("hrx.files.revision",()->"TEST-SIGNATURES-ONLY");}
 @LocalServerPort int port;@Autowired MockMvc mvc;
 @BeforeAll void prepare(){fixtures();}
 @AfterAll void cleanup() throws Exception{if(Files.exists(ROOT))try(var paths=Files.walk(ROOT)){for(Path p:paths.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(p);}}
 String create() throws Exception{var r=request(port,1,"/supply-chain/demands",demand(),keyId());assertEquals(200,r.statusCode(),r.body());return JSON.readTree(r.body()).get("demand_id").asText();}
 String upload(String demand,String doc,int version,byte[] bytes,String key,int code) throws Exception{var req=multipart("/api/v1/files").file(new MockMultipartFile("file","TEST evidence.txt","text/plain",bytes)).param("demandId",demand).param("expectedVersion",Integer.toString(version)).header("Authorization","Bearer "+token(1)).header("Idempotency-Key",key);if(doc!=null)req.param("documentId",doc);return mvc.perform(req).andExpect(status().is(code)).andReturn().getResponse().getContentAsString();}
 @Test void realScannerUploadReplayVersionDownloadAndTamper() throws Exception{
  String id=create(),key=keyId();byte[] bytes="TEST clean evidence".getBytes(java.nio.charset.StandardCharsets.UTF_8);var row=JSON.readTree(upload(id,null,0,bytes,key,200));assertEquals("CLEAN",row.get("scan_status").asText());assertEquals(row,JSON.readTree(upload(id,null,0,bytes,key,200)));String file=row.get("file_id").asText(),doc=row.get("document_id").asText();
  mvc.perform(get("/api/v1/files/"+file+"/content").header("Authorization","Bearer "+token(1))).andExpect(status().isOk()).andExpect(content().bytes(bytes)).andExpect(header().string("X-Content-Type-Options","nosniff"));
  assertEquals(2,JSON.readTree(upload(id,doc,1,bytes,keyId(),200)).get("version").asInt());long count;try(var paths=Files.list(ROOT)){count=paths.count();}upload(id,doc,1,bytes,keyId(),409);try(var paths=Files.list(ROOT)){assertEquals(count,paths.count());}
  mvc.perform(get("/api/v1/files/"+file+"/content").header("Authorization","Bearer "+token(5))).andExpect(status().isNotFound());Files.writeString(ROOT.resolve(file+".blob"),"TEST altered");mvc.perform(get("/api/v1/files/"+file+"/content").header("Authorization","Bearer "+token(1))).andExpect(status().isConflict());
 }
 @Test void eicarIsQuarantinedAndCannotBeUsedAsEvidence() throws Exception{
  String id=create();byte[] bytes="X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".getBytes(java.nio.charset.StandardCharsets.US_ASCII);var row=JSON.readTree(upload(id,null,0,bytes,keyId(),200));assertEquals("INFECTED",row.get("scan_status").asText());mvc.perform(get("/api/v1/files/"+row.get("file_id").asText()+"/content").header("Authorization","Bearer "+token(1))).andExpect(status().isConflict());
  var body=new HashMap<>(TestSupport.event(0,"SUBMIT",Map.of()));body.put("evidenceRefs",List.of(row.get("reference").asText()));assertEquals(422,request(port,1,"/supply-chain/demands/"+id+"/events",body,keyId()).statusCode());body.put("evidenceRefs",List.of("hrx-file:"+UUID.randomUUID()));assertEquals(422,request(port,1,"/supply-chain/demands/"+id+"/events",body,keyId()).statusCode());
 }
 @Test void permissionRevocationAndWrongBusinessObject() throws Exception{
  String id=create();byte[] bytes="TEST scoped evidence".getBytes(java.nio.charset.StandardCharsets.UTF_8);var row=JSON.readTree(upload(id,null,0,bytes,keyId(),200));String file=row.get("file_id").asText();mvc.perform(get("/api/v1/files/"+file+"/content").header("Authorization","Bearer "+token(2))).andExpect(status().isOk());admin().update("UPDATE hrx.capability_grant SET enabled=false WHERE user_id=?",user(2));try{mvc.perform(get("/api/v1/files/"+file+"/content").header("Authorization","Bearer "+token(2))).andExpect(status().isNotFound());}finally{admin().update("UPDATE hrx.capability_grant SET enabled=true WHERE user_id=?",user(2));}
  String another=create();upload(another,row.get("document_id").asText(),1,bytes,keyId(),403);var body=new HashMap<>(TestSupport.event(0,"SUBMIT",Map.of()));body.put("evidenceRefs",List.of(row.get("reference").asText()));assertEquals(422,request(port,1,"/supply-chain/demands/"+another+"/events",body,keyId()).statusCode());
 }
 @Test void concurrentFileVersionsHaveOneWinner() throws Exception{
  String demand=create();byte[] bytes="TEST concurrent file version".getBytes(java.nio.charset.StandardCharsets.UTF_8);var first=JSON.readTree(upload(demand,null,0,bytes,keyId(),200));String doc=first.get("document_id").asText();var pool=java.util.concurrent.Executors.newFixedThreadPool(2);var start=new java.util.concurrent.CountDownLatch(1);
  try{java.util.concurrent.Callable<Integer> task=()->{start.await();return mvc.perform(multipart("/api/v1/files").file(new MockMultipartFile("file","TEST evidence.txt","text/plain",bytes)).param("demandId",demand).param("documentId",doc).param("expectedVersion","1").header("Authorization","Bearer "+token(1)).header("Idempotency-Key",keyId())).andReturn().getResponse().getStatus();};var a=pool.submit(task);var b=pool.submit(task);start.countDown();assertEquals(Set.of(200,409),new HashSet<>(List.of(a.get(15,java.util.concurrent.TimeUnit.SECONDS),b.get(15,java.util.concurrent.TimeUnit.SECONDS))));assertEquals(2,admin().queryForObject("SELECT count(*) FROM hrx.controlled_file WHERE document_id=?::uuid",Integer.class,doc));}finally{pool.shutdownNow();}
 }
 String fileEvent(int who,String id,int revision,String code,Map<String,Object> payload,String reference,int expected) throws Exception{
  var body=new HashMap<>(TestSupport.event(revision,code,payload));body.put("evidenceRefs",List.of(reference));var r=request(port,who,"/supply-chain/demands/"+id+"/events",body,keyId());assertEquals(expected,r.statusCode(),r.body());return r.body();
 }
 @Test void returnEventsRequireScopedRealCleanEvidenceWhenFilesEnabled() throws Exception{
  String id=create(),today=TestSupport.today().toString();var clean=JSON.readTree(upload(id,null,0,"TEST real return evidence".getBytes(java.nio.charset.StandardCharsets.UTF_8),keyId(),200));String ref=clean.get("reference").asText();
  fileEvent(1,id,0,"SUBMIT",Map.of(),ref,200);fileEvent(1,id,1,"OPEN_RFQ",Map.of(),ref,200);
  String q=JSON.readTree(fileEvent(1,id,2,"QUOTE",Map.of("supplier","TEST file supplier A","currency","CNY","unitPrice",1),ref,200)).get("event_id").asText();fileEvent(1,id,3,"QUOTE",Map.of("supplier","TEST file supplier B","currency","CNY","unitPrice",2),ref,200);fileEvent(2,id,4,"APPROVE",Map.of("quoteId",q),ref,200);fileEvent(1,id,5,"ISSUE_PO",Map.of("poNumber","TEST FILE PO"),ref,200);
  String receipt=JSON.readTree(fileEvent(3,id,6,"RECEIVE",Map.of("quantity",10,"batch","TEST FILE BATCH","receivedDate",today),ref,200)).get("event_id").asText();String inspection=JSON.readTree(fileEvent(4,id,7,"IQC",Map.of("receiptId",receipt,"acceptedQty",8,"rejectedQty",2),ref,200)).get("event_id").asText();
  byte[] eicar="X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".getBytes(java.nio.charset.StandardCharsets.US_ASCII);String infected=JSON.readTree(upload(id,null,0,eicar,keyId(),200)).get("reference").asText();
  fileEvent(3,id,8,"RETURN_REQUEST",Map.of("inspectionId",inspection),infected,422);fileEvent(3,id,8,"RETURN_REQUEST",Map.of("inspectionId",inspection),"hrx-file:"+UUID.randomUUID(),422);
  String ret=JSON.readTree(fileEvent(3,id,8,"RETURN_REQUEST",Map.of("inspectionId",inspection),ref,200)).get("event_id").asText();fileEvent(2,id,9,"RETURN_APPROVE",Map.of("returnRequestId",ret),ref,200);fileEvent(3,id,10,"RETURN_SHIP",Map.of("returnRequestId",ret,"shipmentNo","TEST FILE SHIP","shippedDate",today),ref,200);
  fileEvent(3,id,11,"RECEIVE",Map.of("quantity",2,"batch","TEST FILE REPLACEMENT","receivedDate",today),infected,422);fileEvent(3,id,11,"RECEIVE",Map.of("quantity",2,"batch","TEST FILE REPLACEMENT","receivedDate",today),ref,200);
 }
 @Test @EnabledIfEnvironmentVariable(named="HRX_BROWSER",matches="true") void browserFileUpload() throws Exception{String id=create(),line=admin().queryForObject("SELECT bom_line FROM hrx.supply_demand WHERE demand_id=?::uuid",String.class,id);BrowserRunner.run(port,"files.mjs",Map.of("user1",token(1)),Map.of("HRX_E2E_SEARCH",line));}
}
