package com.redhat.demo.bank.api.dto;

import java.math.BigDecimal;

public record BalanceResponse(
        Long accountId,
        String iban,
        BigDecimal balance,
        String currency
) {
}
