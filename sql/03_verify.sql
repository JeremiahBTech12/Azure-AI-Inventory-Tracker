-- Run each statement on its own; the portal Query editor shows one result set at a time.

-- Products with their supplier
SELECT p.ProductId, p.ProductName, p.CurrentStock, p.MinimumStock, s.SupplierName
FROM Products p
JOIN Suppliers s ON p.SupplierId = s.SupplierId;

-- After sending a test sale for product 1, quantity 2: Laptop goes 15 -> 13
SELECT ProductName, CurrentStock FROM Products WHERE ProductId = 1;

-- Audit trail written by the Function
SELECT * FROM StockMovements ORDER BY MovedAt DESC;
