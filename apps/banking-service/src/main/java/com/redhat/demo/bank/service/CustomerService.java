package com.redhat.demo.bank.service;

import com.redhat.demo.bank.api.dto.CustomerRequest;
import com.redhat.demo.bank.api.dto.CustomerResponse;
import com.redhat.demo.bank.domain.Customer;
import com.redhat.demo.bank.repository.CustomerRepository;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class CustomerService {

    private final CustomerRepository customerRepository;

    public CustomerService(CustomerRepository customerRepository) {
        this.customerRepository = customerRepository;
    }

    @Transactional(readOnly = true)
    public List<CustomerResponse> listCustomers() {
        return customerRepository.findAll().stream().map(CustomerResponse::from).toList();
    }

    @Transactional(readOnly = true)
    public CustomerResponse getCustomer(Long id) {
        return CustomerResponse.from(findCustomer(id));
    }

    @Transactional
    public CustomerResponse createCustomer(CustomerRequest request) {
        if (customerRepository.existsByEmail(request.email())) {
            throw new BankingException(HttpStatus.CONFLICT, "Email already registered");
        }
        if (customerRepository.existsByNationalId(request.nationalId())) {
            throw new BankingException(HttpStatus.CONFLICT, "National ID already registered");
        }

        Customer customer = new Customer();
        customer.setFirstName(request.firstName());
        customer.setLastName(request.lastName());
        customer.setEmail(request.email());
        customer.setNationalId(request.nationalId());
        return CustomerResponse.from(customerRepository.save(customer));
    }

    Customer findCustomer(Long id) {
        return customerRepository.findById(id)
                .orElseThrow(() -> new BankingException(HttpStatus.NOT_FOUND, "Customer not found: " + id));
    }
}
