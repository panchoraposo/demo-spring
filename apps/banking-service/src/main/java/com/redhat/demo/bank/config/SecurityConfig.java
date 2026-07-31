package com.redhat.demo.bank.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.AuthenticationManagerResolver;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationProvider;
import org.springframework.security.oauth2.server.resource.authentication.JwtIssuerAuthenticationManagerResolver;
import org.springframework.security.web.SecurityFilterChain;

import jakarta.servlet.http.HttpServletRequest;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

@Configuration
@EnableWebSecurity
@Profile("!test")
public class SecurityConfig {

    /**
     * Trust JWTs from this spoke and peer Keycloaks (mesh failover).
     * Issuers: OIDC_TRUSTED_ISSUERS (comma-separated).
     * JWKS is fetched over HTTPS even when iss is http:// (OpenShift Routes).
     */
    @Bean
    AuthenticationManagerResolver<HttpServletRequest> authenticationManagerResolver(
            @Value("${OIDC_TRUSTED_ISSUERS:${spring.security.oauth2.resourceserver.jwt.issuer-uri:}}")
            String trustedIssuers) {
        Map<String, AuthenticationManager> managers = new LinkedHashMap<>();
        Arrays.stream(trustedIssuers.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .forEach(issuer -> managers.put(issuer, authenticationManagerForIssuer(issuer)));
        if (managers.isEmpty()) {
            throw new IllegalStateException("Configure OIDC_TRUSTED_ISSUERS or issuer-uri");
        }
        return new JwtIssuerAuthenticationManagerResolver(managers::get);
    }

    private static AuthenticationManager authenticationManagerForIssuer(String issuer) {
        String jwkSetUri = issuer.replace("http://", "https://") + "/protocol/openid-connect/certs";
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(jwkSetUri).build();
        decoder.setJwtValidator(JwtValidators.createDefaultWithIssuer(issuer));
        JwtAuthenticationProvider provider = new JwtAuthenticationProvider(decoder);
        return provider::authenticate;
    }

    @Bean
    SecurityFilterChain securityFilterChain(
            HttpSecurity http,
            AuthenticationManagerResolver<HttpServletRequest> authenticationManagerResolver) throws Exception {
        http
                .csrf(csrf -> csrf.disable())
                .sessionManagement(sm -> sm.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers(
                                "/actuator/health",
                                "/actuator/health/**",
                                "/actuator/info",
                                "/actuator/prometheus").permitAll()
                        .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                        .anyRequest().authenticated())
                .oauth2ResourceServer(oauth2 -> oauth2.authenticationManagerResolver(authenticationManagerResolver));
        return http.build();
    }
}
