-- DataWave Industries – Logistics Database (PostgreSQL)
-- Represents operational shipment data for the supply-chain platform.

CREATE SCHEMA IF NOT EXISTS logistics;

-- ── Customers ──────────────────────────────────────────────────────────────────
CREATE TABLE logistics.customers (
    customer_id   SERIAL PRIMARY KEY,
    company_name  VARCHAR(200) NOT NULL,
    country       VARCHAR(100) NOT NULL,
    region        VARCHAR(100),
    contact_email VARCHAR(255),
    credit_card   VARCHAR(19),
    created_at    TIMESTAMPTZ  DEFAULT NOW()
);

-- ── Routes ────────────────────────────────────────────────────────────────────
CREATE TABLE logistics.routes (
    route_id      SERIAL PRIMARY KEY,
    origin        VARCHAR(100) NOT NULL,
    destination   VARCHAR(100) NOT NULL,
    carrier       VARCHAR(100) NOT NULL,
    transit_days  INT          NOT NULL,
    cost_per_kg   NUMERIC(10, 2)
);

-- ── Shipments ─────────────────────────────────────────────────────────────────
CREATE TABLE logistics.shipments (
    shipment_id   SERIAL PRIMARY KEY,
    customer_id   INT          REFERENCES logistics.customers(customer_id),
    route_id      INT          REFERENCES logistics.routes(route_id),
    weight_kg     NUMERIC(10, 2) NOT NULL,
    status        VARCHAR(50)  NOT NULL DEFAULT 'PENDING',
    dispatched_at TIMESTAMPTZ,
    delivered_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ  DEFAULT NOW()
);

-- ── Seed Data ─────────────────────────────────────────────────────────────────
INSERT INTO logistics.customers (company_name, country, region, contact_email, credit_card) VALUES
    ('Acme Corp',        'United States', 'North America', 'ops@acme.com',              '4111-1111-1111-1111'),
    ('Global Trade Ltd', 'Germany',       'Europe',        'trade@globaltrade.de',       '5500-0000-0000-0004'),
    ('Pacific Freight',  'Japan',         'Asia Pacific',  'pf@pacificfreight.jp',       '3714-496353-98431'),
    ('Euro Logistics',   'France',        'Europe',        'contact@eurologistics.fr',   '6011-1111-1111-1117'),
    ('Amazon Basin',     'Brazil',        'South America', 'supply@amazonbasin.br',      '3056-9309-0259-04');

INSERT INTO logistics.routes (origin, destination, carrier, transit_days, cost_per_kg) VALUES
    ('New York',      'Los Angeles',  'FastShip',    3,  1.20),
    ('Hamburg',       'Rotterdam',    'EuroCarrier', 1,  0.80),
    ('Tokyo',         'Seoul',        'AsiaPac',     2,  1.50),
    ('Paris',         'London',       'EuroCarrier', 2,  0.95),
    ('São Paulo',     'Buenos Aires', 'AmeriFreight',4,  1.10),
    ('New York',      'Hamburg',      'OceanLine',   12, 0.45),
    ('Los Angeles',   'Tokyo',        'PacificRoute',14, 0.38);

INSERT INTO logistics.shipments (customer_id, route_id, weight_kg, status, dispatched_at, delivered_at) VALUES
    (1, 1, 120.50, 'DELIVERED', NOW() - INTERVAL '10 days', NOW() - INTERVAL '7 days'),
    (1, 6, 345.00, 'IN_TRANSIT', NOW() - INTERVAL '5 days', NULL),
    (2, 2, 55.75,  'DELIVERED', NOW() - INTERVAL '3 days', NOW() - INTERVAL '2 days'),
    (3, 3, 200.00, 'PENDING',   NULL,                        NULL),
    (4, 4, 88.20,  'DELIVERED', NOW() - INTERVAL '8 days', NOW() - INTERVAL '6 days'),
    (5, 5, 410.00, 'IN_TRANSIT', NOW() - INTERVAL '2 days', NULL),
    (2, 6, 620.00, 'DELIVERED', NOW() - INTERVAL '20 days', NOW() - INTERVAL '8 days'),
    (3, 7, 150.00, 'IN_TRANSIT', NOW() - INTERVAL '6 days', NULL),
    (1, 3, 75.00,  'PENDING',   NULL,                        NULL),
    (4, 1, 300.00, 'DELIVERED', NOW() - INTERVAL '15 days', NOW() - INTERVAL '12 days');
