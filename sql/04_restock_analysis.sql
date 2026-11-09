-- Query used by the Logic App every morning. Its result set is sent to Azure OpenAI.
SELECT
    p.ProductName, p.CurrentStock, p.MinimumStock, p.UnitCost,
    s.SupplierName, s.LeadTimeDays,
    ISNULL(SUM(m.Quantity), 0) AS UnitsSoldLast30Days
FROM Products p
JOIN Suppliers s ON p.SupplierId = s.SupplierId
LEFT JOIN StockMovements m
    ON p.ProductId = m.ProductId
    AND m.MovementType = 'SALE'
    AND m.MovedAt >= DATEADD(day, -30, GETUTCDATE())
GROUP BY p.ProductName, p.CurrentStock, p.MinimumStock, p.UnitCost,
         s.SupplierName, s.LeadTimeDays
ORDER BY p.CurrentStock ASC;
