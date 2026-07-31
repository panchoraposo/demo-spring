# Banking API reference

Base path (via gateway): `/api/v1`  
Auth: `Authorization: Bearer <JWT>`

## Customers

### `GET /api/v1/customers`

List customers.

### `GET /api/v1/customers/{id}`

Get customer by id.

### `POST /api/v1/customers`

```json
{
  "firstName": "Ada",
  "lastName": "Lovelace",
  "email": "ada@bank.demo",
  "nationalId": "NID-001"
}
```

## Accounts

### `GET /api/v1/accounts?customerId=`

List accounts (optional `customerId` filter).

### `GET /api/v1/accounts/{id}`

Account details (IBAN, type, status, balance).

### `GET /api/v1/accounts/{id}/balance`

Balance only.

### `POST /api/v1/accounts`

```json
{
  "customerId": 1,
  "type": "CHECKING",
  "currency": "USD",
  "initialDeposit": 1000.00
}
```

`type`: `CHECKING` | `SAVINGS` | `BUSINESS`

## Transfers

### `POST /api/v1/transfers`

```json
{
  "fromAccountId": 1,
  "toAccountId": 2,
  "amount": 125.50,
  "description": "Payroll"
}
```

Returns debit and credit transaction records. Fails with `422` on insufficient funds.

## Transactions

### `GET /api/v1/transactions?accountId=`

Transaction history (optional account filter). Types: `DEPOSIT`, `WITHDRAWAL`, `TRANSFER_IN`, `TRANSFER_OUT`.

## Errors

```json
{
  "timestamp": "2026-07-29T14:00:00Z",
  "status": 404,
  "error": "Not Found",
  "message": "Account not found: 99",
  "path": "/api/v1/accounts/99"
}
```

## Actuator (not under `/api`)

Unauthenticated endpoints used by kubelet probes and user-workload scrape:

| Path | Purpose |
| --- | --- |
| `GET /actuator/health/liveness` | Liveness / startup probes |
| `GET /actuator/health/readiness` | Readiness (`banking-service` includes DB) |
| `GET /actuator/info` | Build/info |
| `GET /actuator/prometheus` | Micrometer metrics for CMA Prometheus trigger |

Autoscaling: [keda-autoscaling.md](keda-autoscaling.md).
