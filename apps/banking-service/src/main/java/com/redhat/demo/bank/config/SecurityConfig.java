package com.redhat.demo.bank.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AuthenticationManagerResolver;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.server.resource.authentication.JwtIssuerAuthenticationManagerResolver;
import org.springframework.security.web.SecurityFilterChain;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.Set;

@Configuration
@EnableWebSecurity
@Profile("!test")
public class SecurityConfig {

    /**
     * Accept JWTs from this spoke's Keycloak and peer spokes (mesh failover).
     * Comma-separated issuer URIs via OIDC_TRUSTED_ISSUERS; falls back to OIDC_ISSUER_URI.
     */
    @Bean
    AuthenticationManagerResolver<HttpServletRequest> authenticationManagerResolver(
            @Value("${OIDC_TRUSTED_ISSUERS:${spring.security.oauth2.resourceserver.jwt.issuer-uri:}}")
            String trustedIssuers) {
        Set<String> issuers = new LinkedHashSet<>();
        if (trustedIssuers != null && !trustedIssuers.isBlank()) {
            Arrays.stream(trustedIssuers.split(","))
                    .map(String::trim)
                    .filter(s -> !s.isEmpty())
                    .forEach(issuers::add);
        }
        if (issuers.isEmpty()) {
            throw new IllegalStateException("Configure OIDC_TRUSTED_ISSUERS or issuer-uri");
        }
        return JwtIssuerAuthenticationManagerResolver.fromTrustedIssuers(issuers);
    }

    @Bean
    SecurityFilterChain securityFilterChain(
            HttpSecurity http,
            AuthenticationManagerResolver<HttpServletRequest> authenticationManagerResolver) throws Exception {
        http
                .csrf(csrf -> csrf.disable())
                .sessionManagement(sm -> sm.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/actuator/health", "/actuator/health/**", "/actuator/info").permitAll()
                        .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                        .anyRequest().authenticated())
                .oauth2ResourceServer(oauth2 -> oauth2.authenticationManagerResolver(authenticationManagerResolver));
        return http.build();
    }
}
