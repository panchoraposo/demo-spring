package com.redhat.demo.bank.service;

import org.springframework.http.HttpStatus;

public class BankingException extends RuntimeException {

    private final HttpStatus status;

    public BankingException(HttpStatus status, String message) {
        super(message);
        this.status = status;
    }

    public HttpStatus getStatus() {
        return status;
    }
}
