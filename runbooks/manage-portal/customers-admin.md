<!--
Authoritative runtime document.
If it’s not described here, it’s not supported.
-->

# Customers – Admin Management (Manage Portal)

## Scope
This runbook covers **customer management via the Manage Portal admin UI**, including:
- Viewing customers
- Adding new customers
- Editing existing customers

It explicitly **does not** cover:
- Historical imported customer data
- PBX or Trunk management (see related runbooks)

---

## Authoritative Data Model

### Tables
- `public.customers`    Authoritative customer records (cleaned, active only)

- `manage_cfg.customer_halo_map`    One-to-one mapping of customer → Halo Customer ID

### Key Rules
- Exactly **one active customer record per business**
- `customer_slug`:
  - lowercase
  - letters, numbers, hyphens only
  - **must not contain underscores**
- Halo Customer ID:
  - required on creation
  - **immutable after creation**

---

## Admin UI – Customers Page

### URL
```
/admin/customers
```

### Behaviour
- Displays active, authoritative customers only
- Shows:
  - Display Name
  - Halo ID
  - Status
  - PBX / Trunk indicators
- Provides:
  - **Add Customer** action
  - **Edit** action per customer

---

## Add Customer

### URL
```
/admin/customers/new
```

### Required Fields
- Display Name
- Halo Customer ID

### System Behaviour
- `customer_slug` is auto-generated from Display Name
- Slug uniqueness is enforced
- Halo ID uniqueness is enforced
- New customers are created with `status = active`

---

## Edit Customer

### URL
```
/admin/customers/{customer_slug}
```

### Editable Fields
- Display Name ✅

### Locked Fields
- Customer Slug ❌
- Halo Customer ID ❌ (read-only)

### Enforcement
- Halo ID immutability is enforced:
  - In the UI (read-only field)
  - Server-side (POST tampering is rejected)

---

## Customer Deletion (Database Only)

⚠️ **No UI delete is provided.**

### Safe Delete Conditions
A customer may be deleted from the database **only if**:
- It has no PBX systems
- It has no Trunks
- It is not referenced by admin mapping tables

### Deletion Order
1. `manage_cfg.customer_halo_map`
2. `public.customers`

Refer to the *Database – Customer Cleanup & Repair* runbook for SQL examples.

---

## Related Runbooks
- PBX – Admin Management
- Trunks – Admin Management
- Database – Customer Cleanup & Repair
