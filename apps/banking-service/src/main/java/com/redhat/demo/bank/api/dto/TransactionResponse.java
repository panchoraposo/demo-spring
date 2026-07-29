package com.redhat.demo.bank.api.dto;

import com.redhat.demo.bank.domain.BankTransaction;
import com.redhat.demo.bank.domain.TransactionType;
import java.math.BigDecimal;
import java.time.Instant;

public record TransactionResponse(
        Long id,
        Long accountId,
        Long counterpartyAccountId,
        TransactionType type,
        BigDecimal amount,
        String currency,
        String description,
        Instant createdAt
) {
    public static TransactionResponse from(BankTransaction tx) {
        return new TransactionResponse(
                tx.getId(),
                tx.getAccountId(),
                tx.getCounterpartyAccountId(),
                tx.getType(),
                tx.getAmount(),
                tx.getCurrency(),
                tx.getDescription(),
                tx.getCreatedAt()
        );
    }
}
