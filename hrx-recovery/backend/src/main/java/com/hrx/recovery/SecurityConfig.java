package com.hrx.recovery;
import org.springframework.context.annotation.*;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.server.resource.web.authentication.BearerTokenAuthenticationFilter;
import org.springframework.security.web.SecurityFilterChain;
@Configuration
public class SecurityConfig {
 @Bean TxIdentityFilter identityFilter(JdbcTemplate jdbc,PlatformTransactionManager tx){return new TxIdentityFilter(jdbc,tx);}
 @Bean FilterRegistrationBean<TxIdentityFilter> filterRegistration(TxIdentityFilter filter){var r=new FilterRegistrationBean<>(filter);r.setEnabled(false);return r;}
 @Bean SecurityFilterChain security(HttpSecurity http,TxIdentityFilter filter) throws Exception {
  return http.csrf(c->c.disable()).sessionManagement(c->c.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
   .authorizeHttpRequests(c->c.anyRequest().authenticated()).oauth2ResourceServer(c->c.jwt(j->{}))
   .addFilterAfter(filter,BearerTokenAuthenticationFilter.class).build();
 }
}
