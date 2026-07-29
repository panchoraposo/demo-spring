package com.redhat.demo.bank.service;

import com.redhat.demo.bank.api.dto.AccountRequest;
import com.redhat.demo.bank.api.dto.AccountResponse;
import com.redhat.demo.bank.api.dto.BalanceResponse;
import com.redhat.demo.bank.domain.Account;
import com.redhat.demo.bank.domain.AccountStatus;
import com.redhat.demo.bank.domain.BankTransaction;
import com.redhat.demo.bank.domain.TransactionType;
import com.redhat.demo.bank.repository.AccountRepository;
import com.redhat.demo.bank.repository.TransactionRepository;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class AccountService {

    private final AccountRepository accountRepository;
    private final TransactionRepository transactionRepository;
    private final CustomerService customerService;

    public AccountService(
            AccountRepository accountRepository,
            TransactionRepository transactionRepository,
            CustomerService customerService) {
        this.accountRepository = accountRepository;
        this.transactionRepository = transactionRepository;
        this.customerService = customerService;
    }

    @Transactional(readOnly = true)
    public List<AccountResponse> listAccounts(Long customerId) {
        if (customerId != null) {
            customerService.findCustomer(customerId);
            return accountRepository.findByCustomerId(customerId).stream().map(AccountResponse::from).toList();
        }
        return accountRepository.findAll().stream().map(AccountResponse::from).toList();
    }

    @Transactional(readOnly = true)
    public AccountResponse getAccount(Long id) {
        return AccountResponse.from(findAccount(id));
    }

    @Transactional(readOnly = true)
    public BalanceResponse getBalance(Long id) {
        Account account = findAccount(id);
        return new BalanceResponse(account.getId(), account.getIban(), account.getBalance(), account.getCurrency());
    }

    @Transactional
    public AccountResponse openAccount(AccountRequest request) {
        customerService.findCustomer(request.customerId());

        BigDecimal initial = request.initialDeposit() != null ? request.initialDeposit() : BigDecimal.ZERO;
        String currency = request.currency() != null ? request.currency().toUpperCase() : "USD";

        Account account = new Account();
        account.setIban(generateIban());
        account.setCustomerId(request.customerId());
        account.setType(request.type());
        account.setStatus(AccountStatus.ACTIVE);
        account.setBalance(initial);
        account.setCurrency(currency);
        Account saved = accountRepository.save(account);

        if (initial.compareTo(BigDecimal.ZERO) > 0) {
            BankTransaction deposit = new BankTransaction();
            deposit.setAccountId(saved.getId());
            deposit.setType(TransactionType.DEPOSIT);
            deposit.setAmount(initial);
            deposit.setCurrency(currency);
            deposit.setDescription("Initial deposit");
            transactionRepository.save(deposit);
        }

        return AccountResponse.from(saved);
    }

    Account findAccount(Long id) {
        return accountRepository.findById(id)
                .orElseThrow(() -> new BankingException(HttpStatus.NOT_FOUND, "Account not found: " + id));
    }

    private String generateIban() {
        String base = "US" + UUID.randomUUID().toString().replace("-", "").substring(0, 18).toUpperCase();
        return base;
    }
}
