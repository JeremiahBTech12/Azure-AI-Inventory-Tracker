-- InventoryDB schema. Run once in the Azure portal Query editor (or sqlcmd / Azure Data Studio).

CREATE TABLE Suppliers (
    SupplierId   INT IDENTITY(1,1) PRIMARY KEY,
    SupplierName NVARCHAR(200) NOT NULL,
    ContactEmail NVARCHAR(200),
    LeadTimeDays INT DEFAULT 3
);

CREATE TABLE Products (
    ProductId    INT IDENTITY(1,1) PRIMARY KEY,
    ProductName  NVARCHAR(200) NOT NULL,
    SKU          NVARCHAR(50) UNIQUE,
    CurrentStock INT DEFAULT 0,
    MinimumStock INT DEFAULT 10,
    UnitCost     DECIMAL(10,2),
    SupplierId   INT,
    LastSaleDate DATETIME2,
    CreatedAt    DATETIME2 DEFAULT GETUTCDATE()
);

-- Append-only audit trail: every sale, restock or adjustment is recorded here.
CREATE TABLE StockMovements (
    MovementId   INT IDENTITY(1,1) PRIMARY KEY,
    ProductId    INT REFERENCES Products(ProductId),
    MovementType NVARCHAR(20),  -- SALE | RESTOCK | ADJUSTMENT
    Quantity     INT NOT NULL,
    Reference    NVARCHAR(100), -- e.g. the sale_id from the POS event
    MovedAt      DATETIME2 DEFAULT GETUTCDATE()
);
