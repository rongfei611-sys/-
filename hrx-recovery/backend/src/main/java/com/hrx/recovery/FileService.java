package com.hrx.recovery;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.TimeUnit;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.*;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.server.ResponseStatusException;
@Service
public class FileService {
 private final JdbcTemplate jdbc;private final ApiSupport api;private final IdempotencyService keys;private final boolean enabled;private final Path root;private final String scanner,signatures,revision;
 public FileService(JdbcTemplate jdbc,ApiSupport api,IdempotencyService keys,@Value("${hrx.files.enabled:false}") boolean enabled,@Value("${hrx.files.directory:}") String directory,@Value("${hrx.files.scanner:}") String scanner,@Value("${hrx.files.signatures:}") String signatures,@Value("${hrx.files.revision:}") String revision){
  this.jdbc=jdbc;this.api=api;this.keys=keys;this.enabled=enabled;this.root=directory.isBlank()?null:Path.of(directory).normalize();this.scanner=scanner;this.signatures=signatures;this.revision=revision;
  if(root!=null&&(!root.isAbsolute()||root.getParent()==null))throw new IllegalArgumentException("File storage must be a dedicated absolute path");
 }
 public boolean configured(){return enabled&&root!=null&&!scanner.isBlank()&&Path.of(scanner).isAbsolute()&&Files.isExecutable(Path.of(scanner))&&!signatures.isBlank()&&Files.isDirectory(Path.of(signatures))&&!revision.isBlank()&&revision.length()<=240;}
 private void ready(){if(!configured())throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,"私有文件存储或扫描服务尚未配置");}
 private record Target(UUID id,String column,String function){
  static Target of(UUID demand,UUID order){return of(demand,order,null);}
  static Target of(UUID demand,UUID order,UUID project){if((demand==null?0:1)+(order==null?0:1)+(project==null?0:1)!=1)throw new IllegalArgumentException("选择且只能选择一个文件归属对象");return project!=null?new Target(project,"project_id","hrx.project_file_allowed"):order!=null?new Target(order,"purchase_order_id","hrx.po_file_allowed"):new Target(demand,"demand_id","hrx.file_allowed");}
 }
 private void allowed(Target target,String action){if(!Boolean.TRUE.equals(jdbc.queryForObject("SELECT "+target.function()+"(?,?)",Boolean.class,target.id(),action)))throw new ResponseStatusException(HttpStatus.FORBIDDEN,"文件权限或关联业务对象权限不足");}
 public List<Map<String,Object>> list(UUID demand){return list(demand,null,null);}
 public List<Map<String,Object>> list(UUID demand,UUID order){return list(demand,order,null);}
 public List<Map<String,Object>> list(UUID demand,UUID order,UUID project){Target target=Target.of(demand,order,project);allowed(target,"read");return jdbc.queryForList("SELECT file_id::text,document_id::text,version,original_name,byte_size,scan_status,sha256,scanner_revision,created_at FROM hrx.controlled_file WHERE "+target.column()+"=? ORDER BY created_at DESC LIMIT 100",target.id());}
 static String hash(byte[] bytes){try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));}catch(Exception e){throw new IllegalStateException(e);}}
 public Map<String,Object> upload(UUID demand,UUID document,int expectedVersion,MultipartFile file,String key){return upload(demand,null,document,expectedVersion,file,key);}
 public Map<String,Object> upload(UUID demand,UUID order,UUID document,int expectedVersion,MultipartFile file,String key){
  return upload(demand,order,null,document,expectedVersion,file,key);
 }
 public Map<String,Object> upload(UUID demand,UUID order,UUID project,UUID document,int expectedVersion,MultipartFile file,String key){
  Target parent=Target.of(demand,order,project);
  ready();allowed(parent,"create");allowed(parent,"read");if(expectedVersion<0||expectedVersion==Integer.MAX_VALUE||(document==null&&expectedVersion!=0)||file.getSize()>10485760)throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"文件大小或版本不符合要求");
  byte[] bytes;try{bytes=file.getBytes();}catch(Exception e){throw new IllegalArgumentException("无法读取上传文件");}
  if(bytes.length>10485760)throw new IllegalArgumentException("文件超过10MB");
  String original=Optional.ofNullable(file.getOriginalFilename()).orElse("file").replace('\\','/');original=original.substring(original.lastIndexOf('/')+1).replaceAll("[\\p{Cntrl}]","_");if(original.isBlank()||original.length()>240)throw new IllegalArgumentException("文件名不符合要求");
  String name=original,digest=hash(bytes);UUID actor=api.actor();var fingerprint=new TreeMap<String,Object>();fingerprint.put("demand",demand);fingerprint.put("document",document);fingerprint.put("version",expectedVersion);fingerprint.put("name",name);fingerprint.put("sha256",digest);if(order!=null)fingerprint.put("purchaseOrder",order);if(project!=null)fingerprint.put("project",project);
  return keys.execute(actor,"file.upload",key,fingerprint,()->{
   UUID id=UUID.randomUUID(),doc=document==null?id:document;Path target=root.resolve(id+".blob");
   try{if(Files.isSymbolicLink(root))throw new java.io.IOException();Files.createDirectories(root);if(Files.getFileStore(root).supportsFileAttributeView("posix"))Files.setPosixFilePermissions(root,PosixFilePermissions.fromString("rwx------"));Files.write(target,bytes,StandardOpenOption.CREATE_NEW);if(Files.getFileStore(root).supportsFileAttributeView("posix"))Files.setPosixFilePermissions(target,PosixFilePermissions.fromString("rw-------"));}
   catch(Exception e){remove(target);throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,"私有存储不可写入");}
   if(!TransactionSynchronizationManager.isSynchronizationActive()){remove(target);throw new IllegalStateException("Upload requires a transaction");}
   TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization(){@Override public void afterCompletion(int status){if(status!=STATUS_COMMITTED)remove(target);}});
   String scan=scan(target);jdbc.update("INSERT INTO hrx.controlled_file(file_id,document_id,version,demand_id,purchase_order_id,project_id,original_name,byte_size,sha256,scan_status,scanner_revision,uploaded_by) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",id,doc,expectedVersion+1,demand,order,project,name,bytes.length,digest,scan,revision,actor);
   api.audit(actor,"file.upload",id,Map.of("scanStatus",scan,"sha256",digest));return Map.of("file_id",id.toString(),"document_id",doc.toString(),"version",expectedVersion+1,"scan_status",scan,"reference","hrx-file:"+id);
  });
 }
 private String scan(Path file){try{var p=new ProcessBuilder(scanner,"--no-summary","--database="+signatures,"--",file.toString()).redirectOutput(ProcessBuilder.Redirect.DISCARD).redirectError(ProcessBuilder.Redirect.DISCARD).start();if(!p.waitFor(30,TimeUnit.SECONDS)){p.destroyForcibly();return "SCAN_FAILED";}return switch(p.exitValue()){case 0->"CLEAN";case 1->"INFECTED";default->"SCAN_FAILED";};}catch(Exception e){if(e instanceof InterruptedException)Thread.currentThread().interrupt();return "SCAN_FAILED";}}
 private byte[] verified(UUID id,String digest){Path path=root.resolve(id+".blob");byte[] bytes;try{if(!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)||Files.size(path)>10485760)throw new java.io.IOException();try(var in=Files.newInputStream(path,StandardOpenOption.READ,LinkOption.NOFOLLOW_LINKS)){bytes=in.readNBytes(10485761);}if(bytes.length>10485760)throw new java.io.IOException();}catch(Exception e){throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,"文件缺失或不可读取");}if(!hash(bytes).equals(digest))throw new ResponseStatusException(HttpStatus.CONFLICT,"文件完整性校验失败");return bytes;}
 public record Download(String name,byte[] bytes){}
 public Download download(UUID id){ready();var rows=jdbc.queryForList("SELECT original_name,sha256,scan_status FROM hrx.controlled_file WHERE file_id=?",id);if(rows.isEmpty())throw new ResponseStatusException(HttpStatus.NOT_FOUND,"文件不存在或无权访问");var row=rows.getFirst();if(!"CLEAN".equals(row.get("scan_status")))throw new ResponseStatusException(HttpStatus.CONFLICT,"文件未通过安全扫描");byte[] bytes=verified(id,(String)row.get("sha256"));api.audit(api.actor(),"file.download",id,Map.of());return new Download((String)row.get("original_name"),bytes);}
 public void requireEvidence(UUID demand,List<String> refs){requireEvidence(Target.of(demand,null),refs);}
 public void requireOrderEvidence(UUID order,List<String> refs){requireEvidence(Target.of(null,order),refs);}
 public void requireProjectEvidence(UUID project,List<String> refs){requireEvidence(Target.of(null,null,project),refs);}
 private void requireEvidence(Target target,List<String> refs){if(!enabled)return;ready();for(String ref:refs){UUID id;try{if(!ref.startsWith("hrx-file:"))throw new IllegalArgumentException();id=UUID.fromString(ref.substring(9));}catch(Exception e){throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,"证据必须来自已上传的受控文件");}var rows=jdbc.queryForList("SELECT sha256 FROM hrx.controlled_file WHERE file_id=? AND "+target.column()+"=? AND scan_status='CLEAN'",id,target.id());if(rows.isEmpty())throw new ResponseStatusException(HttpStatus.UNPROCESSABLE_ENTITY,"证据不存在、未通过扫描或不属于当前业务对象");verified(id,(String)rows.getFirst().get("sha256"));}}
 private static void remove(Path p){try{Files.deleteIfExists(p);}catch(Exception ignored){}}
}
