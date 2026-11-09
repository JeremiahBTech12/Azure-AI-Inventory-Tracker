-- Test data. Run ONCE: re-running duplicates the suppliers and fails on the unique SKUs.

INSERT INTO Suppliers (SupplierName, ContactEmail, LeadTimeDays)
VALUES ('Primary Supplier Co', 'orders@supplier.example', 3),
       ('Backup Supplier Inc', 'supply@backup.example',   7);

INSERT INTO Products (ProductName, SKU, CurrentStock, MinimumStock, UnitCost, SupplierId)
VALUES ('Laptop',         'LAP-001', 15,  5, 899.99, 1),
       ('Wireless Mouse', 'MSE-001',  8, 10,  29.99, 1),
       ('USB-C Hub',      'HUB-001',  3, 10,  49.99, 2),
       ('Monitor',        'MON-001', 12,  5, 299.99, 1),
       ('Keyboard',       'KEY-001', 20,  8,  79.99, 1);
