package com.hrx.recovery;
import java.sql.SQLException;
import java.util.*;
import org.springframework.http.*;
import org.springframework.dao.DataAccessException;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;
@RestControllerAdvice
public class ApiExceptionHandler {
 private Map<String,Object> error(String code,String message){return Map.of("code",code,"message",message,"correlationId",UUID.randomUUID().toString());}
 @ExceptionHandler(ResponseStatusException.class) ResponseEntity<?> status(ResponseStatusException e){return ResponseEntity.status(e.getStatusCode()).body(error("REQUEST_REJECTED",e.getReason()==null?"操作未完成":e.getReason()));}
 @ExceptionHandler(DataAccessException.class) ResponseEntity<?> database(DataAccessException e){Throwable root=org.springframework.core.NestedExceptionUtils.getMostSpecificCause(e);String s=root instanceof SQLException sql?sql.getSQLState():"";
  int code=switch(s){case "40001","23505","40P01"->409;case "42501"->403;case "23514","23503","23502","22P02","22007","22008","22003","22001"->422;default->500;};
  return ResponseEntity.status(code).body(error("DATABASE_REJECTED",switch(code){case 409->"记录或版本冲突，请刷新后重试";case 403->"权限或职责分离校验未通过";case 422->"业务规则、数量或证据校验未通过";default->"数据服务暂时无法完成操作";}));
 }
 @ExceptionHandler({org.springframework.web.bind.MethodArgumentNotValidException.class,jakarta.validation.ConstraintViolationException.class,
 org.springframework.http.converter.HttpMessageNotReadableException.class,org.springframework.web.bind.MissingRequestHeaderException.class,
 org.springframework.web.bind.MissingServletRequestParameterException.class,org.springframework.web.method.annotation.MethodArgumentTypeMismatchException.class,
 org.springframework.web.multipart.support.MissingServletRequestPartException.class,org.springframework.web.multipart.MaxUploadSizeExceededException.class,IllegalArgumentException.class})
 ResponseEntity<?> invalid(Exception e){return ResponseEntity.badRequest().body(error("INVALID_REQUEST","请求字段不符合接口要求"));}
 @ExceptionHandler(Exception.class) ResponseEntity<?> unknown(Exception e){return ResponseEntity.internalServerError().body(error("INTERNAL_ERROR","操作未完成，请联系管理员查看关联日志"));}
}
