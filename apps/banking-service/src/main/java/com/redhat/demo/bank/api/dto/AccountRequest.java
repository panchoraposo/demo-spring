package com.redhat.demo.bank.api.dto;

import com.redhat.demo.bank.domain.AccountType;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;

public record AccountRequest(
        @NotNull Long customerId,
        @NotNull AccountType type,
        @Size(min = 3, max = 3) String currency,
        @Positive BigDecimal initialDeposit
) {
}
