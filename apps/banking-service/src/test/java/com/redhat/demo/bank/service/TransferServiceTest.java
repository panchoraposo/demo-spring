package com.redhat.demo.bank.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.redhat.demo.bank.api.dto.AccountRequest;
import com.redhat.demo.bank.api.dto.AccountResponse;
import com.redhat.demo.bank.api.dto.CustomerRequest;
import com.redhat.demo.bank.api.dto.CustomerResponse;
import com.redhat.demo.bank.api.dto.TransferRequest;
import com.redhat.demo.bank.config.TestSecurityConfig;
import com.redhat.demo.bank.domain.AccountType;
import java.math.BigDecimal;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest
@ActiveProfiles("test")
@Import(TestSecurityConfig.class)
class TransferServiceTest {

    @Autowired
    private CustomerService customerService;

    @Autowired
    private AccountService accountService;

    @Autowired
    private TransferService transferService;

    @Test
    void transfersFundsBetweenAccounts() {
        CustomerResponse customer = customerService.createCustomer(
                new CustomerRequest("Ada", "Lovelace", "ada+" + System.nanoTime() + "@bank.test", "NID-" + System.nanoTime()));

        AccountResponse from = accountService.openAccount(
                new AccountRequest(customer.id(), AccountType.CHECKING, "USD", new BigDecimal("500.00")));
        AccountResponse to = accountService.openAccount(
                new AccountRequest(customer.id(), AccountType.SAVINGS, "USD", BigDecimal.ZERO));

        transferService.transfer(new TransferRequest(from.id(), to.id(), new BigDecimal("125.50"), "Payroll"));

        assertThat(accountService.getBalance(from.id()).balance()).isEqualByComparingTo("374.50");
        assertThat(accountService.getBalance(to.id()).balance()).isEqualByComparingTo("125.50");
    }

    @Test
    void rejectsInsufficientFunds() {
        CustomerResponse customer = customerService.createCustomer(
                new CustomerRequest("Grace", "Hopper", "grace+" + System.nanoTime() + "@bank.test", "NID-" + System.nanoTime()));

        AccountResponse from = accountService.openAccount(
                new AccountRequest(customer.id(), AccountType.CHECKING, "USD", new BigDecimal("10.00")));
        AccountResponse to = accountService.openAccount(
                new AccountRequest(customer.id(), AccountType.SAVINGS, "USD", BigDecimal.ZERO));

        assertThatThrownBy(() -> transferService.transfer(
                        new TransferRequest(from.id(), to.id(), new BigDecimal("50.00"), "Overdraft attempt")))
                .isInstanceOf(BankingException.class)
                .hasMessageContaining("Insufficient funds");
    }
}
