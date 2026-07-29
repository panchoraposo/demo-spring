package com.redhat.demo.bank.api.dto;

import com.redhat.demo.bank.domain.Customer;
import java.time.Instant;

public record CustomerResponse(
        Long id,
        String firstName,
        String lastName,
        String email,
        String nationalId,
        Instant createdAt
) {
    public static CustomerResponse from(Customer customer) {
        return new CustomerResponse(
                customer.getId(),
                customer.getFirstName(),
                customer.getLastName(),
                customer.getEmail(),
                customer.getNationalId(),
                customer.getCreatedAt()
        );
    }
}
