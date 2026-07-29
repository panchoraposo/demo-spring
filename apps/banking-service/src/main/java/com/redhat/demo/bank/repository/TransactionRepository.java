package com.redhat.demo.bank.repository;

import com.redhat.demo.bank.domain.BankTransaction;
import java.util.List;
import org.springframework.data.jpa.repository.JpaRepository;

public interface TransactionRepository extends JpaRepository<BankTransaction, Long> {
    List<BankTransaction> findByAccountIdOrderByCreatedAtDesc(Long accountId);
}
