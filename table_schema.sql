-- 1. Stores
CREATE TABLE stores (
    store_id   INT PRIMARY KEY,
    store_name VARCHAR(255) NOT NULL,
    address    VARCHAR(255),
    city       VARCHAR(100),
    state      VARCHAR(50),
    zip        VARCHAR(20),
    open_date  DATE
);

-- 2. Product Categories
CREATE TABLE product_category (
    category_id   INT PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL
);

-- 3. Products
CREATE TABLE products (
    product_sku   VARCHAR(100) PRIMARY KEY,
    product_name  VARCHAR(100) NOT NULL,
    category_id   INT NOT NULL REFERENCES product_category(category_id)
);

-- 4. Employees
CREATE TABLE employees (
    employee_id       INT PRIMARY KEY,
    first_name        VARCHAR(50) NOT NULL,
    last_name         VARCHAR(50) NOT NULL,
    store_id          INT NOT NULL REFERENCES stores(store_id),
    phone             VARCHAR(50),
    email             VARCHAR(100),
    salary            NUMERIC(12,2),
    start_date        DATE,
    employment_status VARCHAR(50),
    job_title         VARCHAR(100)
);

-- 5. Shifts
CREATE TABLE shifts (
    shift_id       INT PRIMARY KEY,
    employee_id    INT NOT NULL REFERENCES employees(employee_id),
    store_id       INT NOT NULL REFERENCES stores(store_id),
    schedule_start TIME,
    schedule_end   TIME
);

-- 6. Vendors
CREATE TABLE vendors (
    vendor_id     INT PRIMARY KEY,
    vendor_name   VARCHAR(255) NOT NULL,
    vendor_phone  VARCHAR(50),
    vendor_email  VARCHAR(100)
);

-- 7. Vendor Product
CREATE TABLE vendor_product (
    vendor_product_id INT PRIMARY KEY,
    vendor_id         INT NOT NULL REFERENCES vendors(vendor_id),
    product_sku       VARCHAR(100) NOT NULL REFERENCES products(product_sku),
    UNIQUE (vendor_id, product_sku)
);

-- 8. Purchase Orders
CREATE TABLE purchase_order (
    purchase_order_id INT PRIMARY KEY,
    vendor_id         INT NOT NULL REFERENCES vendors(vendor_id),
    store_id          INT NOT NULL REFERENCES stores(store_id),
    order_date        DATE NOT NULL,
    status            VARCHAR(50)
);
CREATE INDEX idx_po_vendor ON purchase_order(vendor_id);
CREATE INDEX idx_po_store  ON purchase_order(store_id);
CREATE INDEX idx_po_date   ON purchase_order(order_date);

-- 9. Purchase Products
CREATE TABLE purchase_product (
    purchase_product_id INT PRIMARY KEY,
    purchase_order_id   INT NOT NULL REFERENCES purchase_order(purchase_order_id),
    vendor_product_id   INT NOT NULL REFERENCES vendor_product(vendor_product_id),
    quantity_purchased  INT NOT NULL CHECK (quantity_purchased > 0),
    actual_unit_cost    NUMERIC(12,2) NOT NULL CHECK (actual_unit_cost >= 0)
);
CREATE INDEX idx_pp_po   ON purchase_product(purchase_order_id);
CREATE INDEX idx_pp_vpid ON purchase_product(vendor_product_id);

-- 10. Inventory Lots 
CREATE TABLE inventory_lot (
    lot_id              INT PRIMARY KEY,
    store_id            INT NOT NULL REFERENCES stores(store_id),
    purchase_product_id INT NOT NULL REFERENCES purchase_product(purchase_product_id),
    quantity            INT NOT NULL CHECK (quantity >= 0),
    expiration_date     DATE,
    received_date       DATE NOT NULL
);
CREATE INDEX idx_lot_store ON inventory_lot(store_id);
CREATE INDEX idx_lot_ppid  ON inventory_lot(purchase_product_id);

-- 11. Inventory
CREATE TABLE inventory (
    store_id           INT NOT NULL REFERENCES stores(store_id),
    product_sku        VARCHAR(100) NOT NULL REFERENCES products(product_sku),
    quantity_in_stock  INT,
    reorder_threshold  INT,
    PRIMARY KEY (store_id, product_sku)
);

-- 12. Payment Methods
CREATE TABLE payment_method (
    payment_method_id INT PRIMARY KEY,
    method_name       VARCHAR(50) NOT NULL
);

-- 13. Transactions
CREATE TABLE transactions (
    transaction_id    INT PRIMARY KEY,
    store_id          INT NOT NULL REFERENCES stores(store_id),
    employee_id       INT NOT NULL REFERENCES employees(employee_id),
    tran_time         TIMESTAMP NOT NULL,
    payment_method_id INT REFERENCES payment_method(payment_method_id)
);

-- 14. Sales Detailed Items
CREATE TABLE sales_detailed_item (
    detailed_id       INT PRIMARY KEY,
    transaction_id    INT NOT NULL REFERENCES transactions(transaction_id),
    product_sku       VARCHAR(100) NOT NULL REFERENCES products(product_sku),
    lot_id            INT NOT NULL REFERENCES inventory_lot(lot_id),
    quantity          INT,
    actual_unit_price NUMERIC(12,2),
    discount_amount   NUMERIC(12,2)
);

-- 15. Refunds
CREATE TABLE refunds (
    refund_id        INT PRIMARY KEY,
    original_tran_id INT NOT NULL REFERENCES transactions(transaction_id),
    refund_time      TIMESTAMP NOT NULL,
    employee_id      INT REFERENCES employees(employee_id),
    reason           TEXT,
    detailed_id      INT NOT NULL REFERENCES sales_detailed_item(detailed_id),
    quantity         DECIMAL(12,3) NOT NULL CHECK (quantity > 0),
    amount           NUMERIC(12,2) NOT NULL CHECK (amount >= 0)
);

-- 16. Operating Expenses
CREATE TABLE operating_expenses (
    expense_id   INT PRIMARY KEY,
    store_id     INT NOT NULL REFERENCES stores(store_id),
    expense_type VARCHAR(100),
    amount       NUMERIC(12,2),
    expense_date DATE
);

-- Resolve SKU from a purchase_product_id
CREATE OR REPLACE FUNCTION _sku_for_pp(pp_id INT)
RETURNS VARCHAR LANGUAGE sql STABLE AS $$
  SELECT vp.product_sku
  FROM purchase_product pp
  JOIN vendor_product vp ON vp.vendor_product_id = pp.vendor_product_id
  WHERE pp.purchase_product_id = pp_id
$$;

-- Upsert into inventory (adds delta to quantity_in_stock)
CREATE OR REPLACE FUNCTION _inv_upsert(p_store INT, p_sku VARCHAR, p_delta INT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO inventory(store_id, product_sku, quantity_in_stock, reorder_threshold)
  VALUES (p_store, p_sku, p_delta, 50)  
  ON CONFLICT (store_id, product_sku)
  DO UPDATE SET quantity_in_stock = inventory.quantity_in_stock + EXCLUDED.quantity_in_stock;
END;
$$;

-- Decrease inventory stock after sale
CREATE OR REPLACE FUNCTION trg_inventory_on_sale_ins()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_store INT; v_sku VARCHAR;
BEGIN
  SELECT il.store_id, _sku_for_pp(il.purchase_product_id)
    INTO v_store, v_sku
  FROM inventory_lot il
  WHERE il.lot_id = NEW.lot_id;

  PERFORM _inv_upsert(v_store, v_sku, -NEW.quantity);
  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_on_sale_ins
AFTER INSERT ON sales_detailed_item
FOR EACH ROW EXECUTE FUNCTION trg_inventory_on_sale_ins();


--  Increase inventory stock after receive from vendor
CREATE OR REPLACE FUNCTION trg_inventory_on_lot_ins()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_sku VARCHAR;
BEGIN
  v_sku := _sku_for_pp(NEW.purchase_product_id);
  PERFORM _inv_upsert(NEW.store_id, v_sku, NEW.quantity);
  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_on_lot_ins
AFTER INSERT ON inventory_lot
FOR EACH ROW EXECUTE FUNCTION trg_inventory_on_lot_ins();

-- Re-add the item quantity to inventory after a refund
CREATE OR REPLACE FUNCTION trg_inventory_on_refund_ins()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_store INT; v_sku VARCHAR; v_lot INT;
BEGIN
  SELECT sdi.lot_id INTO v_lot
  FROM sales_detailed_item sdi
  WHERE sdi.detailed_id = NEW.detailed_id;

  SELECT il.store_id, _sku_for_pp(il.purchase_product_id)
    INTO v_store, v_sku
  FROM inventory_lot il
  WHERE il.lot_id = v_lot;

  -- If all refunds are restocked; if not, add a 'restocked' flag and check it here.
  PERFORM _inv_upsert(v_store, v_sku, NEW.quantity::INT);
  RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_on_refund_ins
AFTER INSERT ON refunds
FOR EACH ROW EXECUTE FUNCTION trg_inventory_on_refund_ins();

-- Prevent negative inventory stock after any update
CREATE OR REPLACE FUNCTION trg_check_lot_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_received INT; v_sold INT; v_ref INT; v_left INT;
BEGIN
  SELECT il.quantity INTO v_received FROM inventory_lot il WHERE il.lot_id = NEW.lot_id;
  SELECT COALESCE(SUM(sdi.quantity),0) INTO v_sold FROM sales_detailed_item sdi WHERE sdi.lot_id = NEW.lot_id;
  SELECT COALESCE(SUM(r.quantity),0)  INTO v_ref
  FROM refunds r
  JOIN sales_detailed_item sdi2 ON sdi2.detailed_id = r.detailed_id
  WHERE sdi2.lot_id = NEW.lot_id;

  v_left := v_received - v_sold + v_ref;
  IF NEW.quantity > v_left THEN
    RAISE EXCEPTION 'Insufficient quantity for lot %, available %, attempted %', NEW.lot_id, v_left, NEW.quantity;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER check_lot_balance_before_sale
BEFORE INSERT ON sales_detailed_item
FOR EACH ROW EXECUTE FUNCTION trg_check_lot_balance();

-- Validate Product Expiry Date
CREATE OR REPLACE FUNCTION validate_expiry_date()
RETURNS TRIGGER AS $$
BEGIN
    -- Block past expiration dates on insert
    IF TG_OP = 'INSERT' AND NEW.expiration_date < CURRENT_DATE THEN
        RAISE EXCEPTION 'Expiration date % for product_sku % is in the past', 
            NEW.expiration_date, NEW.product_sku;
    END IF;

    -- For updates, set quantity to 0 if expired
    IF TG_OP = 'UPDATE' AND NEW.expiration_date <= CURRENT_DATE THEN
        NEW.quantity = 0;
        RAISE NOTICE 'Product_sku % has expired on %, setting quantity to 0', 
            NEW.product_sku, NEW.expiration_date;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_expiry_date
BEFORE INSERT OR UPDATE ON inventory_lot
FOR EACH ROW
EXECUTE FUNCTION validate_expiry_date();











