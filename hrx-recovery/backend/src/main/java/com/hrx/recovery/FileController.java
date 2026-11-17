package com.hrx.recovery;
import java.util.*;
import java.nio.charset.StandardCharsets;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;
@RestController @RequestMapping("/api/v1/files")
public class FileController {
 private final FileService service;public FileController(FileService service){this.service=service;}
 @GetMapping("/status") public Map<String,Object> status(){return Map.of("enabled",service.configured());}
 @GetMapping public List<Map<String,Object>> list(@RequestParam(required=false) UUID demandId,@RequestParam(required=false) UUID purchaseOrderId){return service.list(demandId,purchaseOrderId);}
 @PostMapping(consumes=MediaType.MULTIPART_FORM_DATA_VALUE) public Map<String,Object> upload(@RequestParam(required=false) UUID demandId,@RequestParam(required=false) UUID purchaseOrderId,@RequestParam(required=false) UUID documentId,@RequestParam int expectedVersion,@RequestPart MultipartFile file,@RequestHeader("Idempotency-Key") String key){return service.upload(demandId,purchaseOrderId,documentId,expectedVersion,file,key);}
 @GetMapping("/{id}/content") public ResponseEntity<byte[]> download(@PathVariable UUID id){var f=service.download(id);return ResponseEntity.ok().contentType(MediaType.APPLICATION_OCTET_STREAM).header("X-Content-Type-Options","nosniff").header("Cache-Control","no-store").header("Content-Disposition",ContentDisposition.attachment().filename(f.name(),StandardCharsets.UTF_8).build().toString()).body(f.bytes());}
}
