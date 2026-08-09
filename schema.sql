-- Golden Market — schéma applicatif (schema "public" du même Postgres que n8n)
-- n8n utilise son propre schema "n8n" (voir DB_POSTGRESDB_SCHEMA dans docker-compose.yml),
-- donc pas de conflit avec ces tables.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- PRODUCTS — catalogue
-- ============================================================
CREATE TABLE IF NOT EXISTS products (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        TEXT NOT NULL,
    description TEXT,
    price       NUMERIC(12,2) NOT NULL,       -- en FCFA
    currency    TEXT NOT NULL DEFAULT 'XOF',
    stock_qty   INTEGER NOT NULL DEFAULT 0,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    image_url   TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_products_active ON products (is_active);

-- Nécessaire pour la recherche floue par nom (opérateur gin_trgm_ops) :
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_products_name_trgm ON products USING gin (name gin_trgm_ops);

-- ============================================================
-- CONVERSATIONS — une par numéro de téléphone WhatsApp
-- ============================================================
CREATE TABLE IF NOT EXISTS conversations (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    phone_number    TEXT NOT NULL UNIQUE,       -- format E.164, ex: +22670000000
    customer_name   TEXT,
    status          TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'closed', 'escalated')),
    last_message_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_conversations_phone ON conversations (phone_number);

-- ============================================================
-- MESSAGES — historique complet, utilisé pour reconstruire le contexte de l'agent
-- ============================================================
CREATE TABLE IF NOT EXISTS messages (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    conversation_id  UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role             TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content          TEXT NOT NULL,
    whatsapp_msg_id  TEXT,                      -- id du message côté Meta, pour idempotence
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages (conversation_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_whatsapp_id ON messages (whatsapp_msg_id)
    WHERE whatsapp_msg_id IS NOT NULL;

-- ============================================================
-- ORDERS — commandes en cours / passées
-- ============================================================
CREATE TABLE IF NOT EXISTS orders (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    conversation_id     UUID NOT NULL REFERENCES conversations(id),
    phone_number        TEXT NOT NULL,
    items               JSONB NOT NULL,          -- [{product_id, name, qty, unit_price}, ...]
    total_amount        NUMERIC(12,2) NOT NULL,
    currency            TEXT NOT NULL DEFAULT 'XOF',
    status              TEXT NOT NULL DEFAULT 'pending_payment'
                            CHECK (status IN (
                                'pending_payment',   -- créée, en attente que le client transfère
                                'payment_reported',  -- client dit avoir payé, attente vérif humaine
                                'paid',               -- confirmé par toi manuellement
                                'cancelled'
                            )),
    payment_reference   TEXT,                    -- ex: numéro de transaction Mobile Money donné par le client
    delivery_address    TEXT,
    notes                TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_phone ON orders (phone_number);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);

-- ============================================================
-- Trigger générique pour maintenir updated_at à jour
-- ============================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_products_updated_at ON products;
CREATE TRIGGER trg_products_updated_at
    BEFORE UPDATE ON products
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_orders_updated_at ON orders;
CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- Exemple de données pour tester (à supprimer une fois le vrai catalogue en place)
-- ============================================================
INSERT INTO products (name, description, price, stock_qty) VALUES
    ('Exemple Produit 1', 'Description du produit 1', 15000, 10),
    ('Exemple Produit 2', 'Description du produit 2', 25000, 5)
ON CONFLICT DO NOTHING;
