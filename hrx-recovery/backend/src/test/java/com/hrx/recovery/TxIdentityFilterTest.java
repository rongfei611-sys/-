package com.hrx.recovery;
import java.util.List;
import org.junit.jupiter.api.*;import org.springframework.mock.web.*;import org.springframework.jdbc.core.JdbcTemplate;import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;import org.springframework.security.core.context.SecurityContextHolder;import org.springframework.transaction.*;import org.springframework.transaction.support.SimpleTransactionStatus;
import static org.junit.jupiter.api.Assertions.*;import static org.mockito.Mockito.*;import static org.mockito.ArgumentMatchers.any;
class TxIdentityFilterTest {
 JdbcTemplate jdbc=mock(JdbcTemplate.class);PlatformTransactionManager manager=mock(PlatformTransactionManager.class);SimpleTransactionStatus status=new SimpleTransactionStatus();TxIdentityFilter filter=new TxIdentityFilter(jdbc,manager);MockHttpServletRequest req=new MockHttpServletRequest("POST","/api/v1/test");MockHttpServletResponse res=new MockHttpServletResponse();
 @BeforeEach void prepare(){when(manager.getTransaction(any())).thenReturn(status);when(jdbc.queryForObject("SELECT hrx.current_user_id()::text",String.class)).thenReturn("TEST-subject");SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("TEST-subject",null,List.of()));}
 @AfterEach void clear(){SecurityContextHolder.clearContext();}
 @Test void handledErrorMarksRollback() throws Exception{filter.doFilter(req,res,(a,b)->{((jakarta.servlet.http.HttpServletResponse)b).setStatus(422);b.getWriter().write("TEST validation");});assertTrue(status.isRollbackOnly());assertEquals(422,res.getStatus());}
 @Test void bodyIsSentOnlyAfterCommit() throws Exception{doAnswer(c->{assertEquals("",res.getContentAsString());return null;}).when(manager).commit(any());filter.doFilter(req,res,(a,b)->b.getWriter().write("TEST saved"));assertEquals("TEST saved",res.getContentAsString());}
 @Test void commitFailureCannotReturnSuccessBody() throws Exception{doThrow(new TransactionSystemException("TEST failure")).when(manager).commit(any());filter.doFilter(req,res,(a,b)->b.getWriter().write("TEST saved"));assertEquals(503,res.getStatus());assertFalse(res.getContentAsString().contains("saved"));assertTrue(res.getContentAsString().contains("TRANSACTION_FAILED"));}
}
