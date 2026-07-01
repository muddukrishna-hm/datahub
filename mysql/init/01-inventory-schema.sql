-- DataWave Industries – Inventory Database (MySQL)
-- Represents warehouse and inventory data for the supply-chain platform.

CREATE DATABASE IF NOT EXISTS inventory;
USE inventory;

-- ── Warehouses ────────────────────────────────────────────────────────────────
CREATE TABLE warehouses (
    warehouse_id   INT AUTO_INCREMENT PRIMARY KEY,
    warehouse_name VARCHAR(200) NOT NULL,
    city           VARCHAR(100) NOT NULL,
    country        VARCHAR(100) NOT NULL,
    capacity_m3    INT          NOT NULL,
    created_at     DATETIME     DEFAULT CURRENT_TIMESTAMP
);

-- ── Suppliers ─────────────────────────────────────────────────────────────────
CREATE TABLE suppliers (
    supplier_id   INT AUTO_INCREMENT PRIMARY KEY,
    supplier_name VARCHAR(200) NOT NULL,
    country       VARCHAR(100) NOT NULL,
    lead_time_days INT         NOT NULL,
    reliability   DECIMAL(3,2) NOT NULL COMMENT 'Score 0.00-1.00',
    contact_email VARCHAR(255)
);

-- ── Inventory ─────────────────────────────────────────────────────────────────
CREATE TABLE inventory (
    inventory_id  INT AUTO_INCREMENT PRIMARY KEY,
    warehouse_id  INT            NOT NULL,
    supplier_id   INT            NOT NULL,
    sku           VARCHAR(50)    NOT NULL,
    product_name  VARCHAR(200)   NOT NULL,
    quantity      INT            NOT NULL DEFAULT 0,
    unit_weight   DECIMAL(10,3)  NOT NULL COMMENT 'Weight in kg',
    reorder_level INT            NOT NULL DEFAULT 50,
    last_restocked DATETIME,
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(warehouse_id),
    FOREIGN KEY (supplier_id)  REFERENCES suppliers(supplier_id)
);

-- ── Seed Data ─────────────────────────────────────────────────────────────────
INSERT INTO warehouses (warehouse_name, city, country, capacity_m3) VALUES
    ('Northeast Hub',   'New York',       'United States', 50000),
    ('West Coast DC',   'Los Angeles',    'United States', 65000),
    ('Central Europe',  'Frankfurt',      'Germany',       80000),
    ('Asia Pacific Hub','Tokyo',          'Japan',         45000),
    ('LATAM Depot',     'São Paulo',      'Brazil',        30000);

INSERT INTO suppliers (supplier_name, country, lead_time_days, reliability, contact_email) VALUES
    ('TechParts Inc',     'United States', 5,  0.97, 'supply@techparts.com'),
    ('Euro Components',   'Germany',       7,  0.95, 'orders@eurocomp.de'),
    ('Asia Manufactures', 'China',         14, 0.88, 'sales@asiamanuf.cn'),
    ('FastPack SA',       'France',        3,  0.99, 'logistics@fastpack.fr'),
    ('South Supply Co',   'Brazil',        6,  0.92, 'contact@southsupply.br');

INSERT INTO inventory (warehouse_id, supplier_id, sku, product_name, quantity, unit_weight, reorder_level, last_restocked) VALUES
    (1, 1, 'ELC-001', 'Electronic Sensors',   1200, 0.250,  200, NOW() - INTERVAL 5 DAY),
    (1, 4, 'PKG-010', 'Packaging Foam Rolls',   60, 2.500,  100, NOW() - INTERVAL 45 DAY),
    (2, 1, 'ELC-002', 'GPS Trackers',            80, 0.150,  150, NOW() - INTERVAL 60 DAY),
    (2, 3, 'HWD-005', 'Steel Brackets',        3000, 1.200,  500, NOW() - INTERVAL 20 DAY),
    (3, 2, 'ELC-003', 'RFID Tags (bulk)',      5000, 0.010, 1000, NOW() - INTERVAL 7 DAY),
    (3, 2, 'IND-020', 'Industrial Cables',       25, 5.000,   50, NOW() - INTERVAL 90 DAY),
    (4, 3, 'ELC-004', 'Barcode Scanners',        40, 0.400,   80, NOW() - INTERVAL 55 DAY),
    (4, 3, 'PKG-011', 'Stretch Film Rolls',     600, 8.000,  100, NOW() - INTERVAL 12 DAY),
    (5, 5, 'HWD-006', 'Pallet Jacks',            45, 75.000,  10, NOW() - INTERVAL 30 DAY),
    (5, 5, 'ELC-005', 'Temperature Loggers',    120, 0.100,  200, NOW() - INTERVAL 75 DAY);
