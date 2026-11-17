package com.hrx.recovery;
import java.io.IOException;
import jakarta.servlet.*;
import jakarta.servlet.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.*;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingResponseWrapper;
final class TxIdentityFilter extends OncePerRequestFilter {
 private final JdbcTemplate jdbc;private final TransactionTemplate tx;
 TxIdentityFilter(JdbcTemplate jdbc,PlatformTransactionManager manager){this.jdbc=jdbc;this.tx=new TransactionTemplate(manager);}
 @Override protected boolean shouldNotFilter(HttpServletRequest req){String path=req.getServletPath();if(path.isEmpty())path=req.getRequestURI().substring(req.getContextPath().length());return !path.startsWith("/api/");}
 @Override protected void doFilterInternal(HttpServletRequest req,HttpServletResponse res,FilterChain chain) throws ServletException,IOException {
  var authentication=SecurityContextHolder.getContext().getAuthentication();
  if(authentication==null||!authentication.isAuthenticated()||"anonymousUser".equals(authentication.getName())){chain.doFilter(req,res);return;}
  var buffer=new ContentCachingResponseWrapper(res);
  try {
   tx.executeWithoutResult(s->{
    jdbc.queryForObject("SELECT set_config('hrx.oidc_subject',?,true)",String.class,authentication.getName());
    try {
     if(jdbc.queryForObject("SELECT hrx.current_user_id()::text",String.class)==null){buffer.setStatus(403);buffer.setContentType("application/json;charset=UTF-8");buffer.getWriter().write("{\"code\":\"IDENTITY_INACTIVE\",\"message\":\"登录身份未映射到有效员工\"}");}
     else chain.doFilter(req,buffer);
     if(buffer.getStatus()>=400)s.setRollbackOnly();
    }catch(IOException|ServletException e){throw new FilterFailure(e);}
   });
   buffer.copyBodyToResponse();
  }catch(FilterFailure e){if(e.getCause() instanceof IOException io)throw io;if(e.getCause() instanceof ServletException se)throw se;throw e;}
  catch(org.springframework.dao.DataAccessException|TransactionException e){if(res.isCommitted())throw e;res.resetBuffer();res.setStatus(503);res.setContentType("application/json;charset=UTF-8");res.getWriter().write("{\"code\":\"TRANSACTION_FAILED\",\"message\":\"事务未完成，请使用原幂等键重试\"}");}
 }
 private static class FilterFailure extends RuntimeException{FilterFailure(Exception e){super(e);}}
}
