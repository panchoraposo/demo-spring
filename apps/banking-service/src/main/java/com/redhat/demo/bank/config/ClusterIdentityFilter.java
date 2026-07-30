package com.redhat.demo.bank.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Exposes which managed cluster served the request (useful for mesh failover demos).
 * Set BANKING_CLUSTER=east|west via the Deployment overlay.
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class ClusterIdentityFilter extends OncePerRequestFilter {

    public static final String HEADER = "X-Banking-Cluster";

    private final String cluster;

    public ClusterIdentityFilter(
            @Value("${BANKING_CLUSTER:${banking.cluster:unknown}}") String cluster) {
        this.cluster = cluster == null || cluster.isBlank() ? "unknown" : cluster.trim();
    }

    @Override
    protected void doFilterInternal(
            HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        response.setHeader(HEADER, cluster);
        filterChain.doFilter(request, response);
    }
}
