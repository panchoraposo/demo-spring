package com.redhat.demo.bank.api.dto;

import com.redhat.demo.bank.domain.Account;
import com.redhat.demo.bank.domain.AccountStatus;
import com.redhat.demo.bank.domain.AccountType;
import java.math.BigDecimal;
import java.time.Instant;

public record AccountResponse(
        Long id,
        String iban,
        Long customerId,
        AccountType type,
        AccountStatus status,
        BigDecimal balance,
        String currency,
        Instant openedAt
) {
    public static AccountResponse from(Account account) {
        return new AccountResponse(
                account.getId(),
                account.getIban(),
                account.getCustomerId(),
                account.getType(),
                account.getStatus(),
                account.getBalance(),
                account.getCurrency(),
                account.getOpenedAt()
        );
    }
}
