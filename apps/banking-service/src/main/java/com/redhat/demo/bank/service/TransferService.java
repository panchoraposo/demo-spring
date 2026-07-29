package com.redhat.demo.bank.service;

import com.redhat.demo.bank.api.dto.TransactionResponse;
import com.redhat.demo.bank.api.dto.TransferRequest;
import com.redhat.demo.bank.domain.Account;
import com.redhat.demo.bank.domain.AccountStatus;
import com.redhat.demo.bank.domain.BankTransaction;
import com.redhat.demo.bank.domain.TransactionType;
import com.redhat.demo.bank.repository.AccountRepository;
import com.redhat.demo.bank.repository.TransactionRepository;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class TransferService {

    private final AccountRepository accountRepository;
    private final TransactionRepository transactionRepository;
    private final AccountService accountService;

    public TransferService(
            AccountRepository accountRepository,
            TransactionRepository transactionRepository,
            AccountService accountService) {
        this.accountRepository = accountRepository;
        this.transactionRepository = transactionRepository;
        this.accountService = accountService;
    }

    @Transactional
    public List<TransactionResponse> transfer(TransferRequest request) {
        if (request.fromAccountId().equals(request.toAccountId())) {
            throw new BankingException(HttpStatus.BAD_REQUEST, "Source and destination accounts must differ");
        }

        Account from = accountService.findAccount(request.fromAccountId());
        Account to = accountService.findAccount(request.toAccountId());

        assertActive(from);
        assertActive(to);

        if (!from.getCurrency().equals(to.getCurrency())) {
            throw new BankingException(HttpStatus.BAD_REQUEST, "Currency mismatch between accounts");
        }
        if (from.getBalance().compareTo(request.amount()) < 0) {
            throw new BankingException(HttpStatus.UNPROCESSABLE_ENTITY, "Insufficient funds");
        }

        from.setBalance(from.getBalance().subtract(request.amount()));
        to.setBalance(to.getBalance().add(request.amount()));
        accountRepository.save(from);
        accountRepository.save(to);

        String description = request.description() != null ? request.description() : "Account transfer";

        BankTransaction debit = new BankTransaction();
        debit.setAccountId(from.getId());
        debit.setCounterpartyAccountId(to.getId());
        debit.setType(TransactionType.TRANSFER_OUT);
        debit.setAmount(request.amount());
        debit.setCurrency(from.getCurrency());
        debit.setDescription(description);

        BankTransaction credit = new BankTransaction();
        credit.setAccountId(to.getId());
        credit.setCounterpartyAccountId(from.getId());
        credit.setType(TransactionType.TRANSFER_IN);
        credit.setAmount(request.amount());
        credit.setCurrency(to.getCurrency());
        credit.setDescription(description);

        return List.of(
                TransactionResponse.from(transactionRepository.save(debit)),
                TransactionResponse.from(transactionRepository.save(credit))
        );
    }

    @Transactional(readOnly = true)
    public List<TransactionResponse> listTransactions(Long accountId) {
        if (accountId != null) {
            accountService.findAccount(accountId);
            return transactionRepository.findByAccountIdOrderByCreatedAtDesc(accountId).stream()
                    .map(TransactionResponse::from)
                    .toList();
        }
        return transactionRepository.findAll().stream().map(TransactionResponse::from).toList();
    }

    private void assertActive(Account account) {
        if (account.getStatus() != AccountStatus.ACTIVE) {
            throw new BankingException(HttpStatus.CONFLICT, "Account is not active: " + account.getId());
        }
    }
}
