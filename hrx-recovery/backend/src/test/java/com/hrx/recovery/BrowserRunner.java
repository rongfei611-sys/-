package com.hrx.recovery;
import java.util.*;import java.net.*;import java.net.http.*;import java.nio.file.*;import java.util.concurrent.TimeUnit;
import static org.junit.jupiter.api.Assertions.*;
final class BrowserRunner {
 static void run(int apiPort,String script,Map<String,String> tokens,Map<String,String> extra) throws Exception{
  Path temp=Path.of("target","private-e2e-"+UUID.randomUUID()).toAbsolutePath();Files.createDirectories(temp);int port;try(var s=new java.net.ServerSocket(0,0,InetAddress.getLoopbackAddress())){port=s.getLocalPort();}Process vite=null,browser=null;
  try{Path file=temp.resolve("tokens.json");Files.writeString(file,TestSupport.JSON.writeValueAsString(tokens));var frontend=Path.of("../frontend").toAbsolutePath().normalize();var launch=new ProcessBuilder("npm","run","dev","--","--port",Integer.toString(port),"--strictPort").directory(frontend.toFile()).redirectErrorStream(true).redirectOutput(temp.resolve("vite.log").toFile());launch.environment().put("HRX_API_TARGET","http://127.0.0.1:"+apiPort);vite=launch.start();String base="http://127.0.0.1:"+port;boolean ready=false;
   for(int n=0;n<80&&vite.isAlive();n++){try{if(TestSupport.HTTP.send(HttpRequest.newBuilder(URI.create(base)).timeout(java.time.Duration.ofSeconds(1)).build(),HttpResponse.BodyHandlers.discarding()).statusCode()==200){ready=true;break;}}catch(Exception ignored){}Thread.sleep(100);}assertTrue(ready,Files.readString(temp.resolve("vite.log")));
   Path log=Path.of("target",script+".log");var p=new ProcessBuilder("node","e2e/"+script).directory(frontend.toFile()).redirectErrorStream(true).redirectOutput(log.toFile());p.environment().putAll(extra);p.environment().put("HRX_E2E_TOKENS",file.toString());p.environment().put("HRX_E2E_BASE",base);p.environment().put("HRX_E2E_EVIDENCE",Path.of("target/screenshots").toAbsolutePath().toString());browser=p.start();assertTrue(browser.waitFor(90,TimeUnit.SECONDS),"Browser timeout");assertEquals(0,browser.exitValue(),Files.readString(log));
  }finally{for(Process p:new Process[]{browser,vite})if(p!=null){p.descendants().forEach(ProcessHandle::destroy);p.destroy();}try(var files=Files.walk(temp)){for(Path p:files.sorted(Comparator.reverseOrder()).toList())Files.deleteIfExists(p);}}
 }
}
