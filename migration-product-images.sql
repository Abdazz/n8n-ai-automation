-- Migration : passage de "une image par produit" à "plusieurs images par produit"
-- À exécuter une seule fois sur la base existante.

CREATE TABLE IF NOT EXISTS product_images (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id  UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    image_url   TEXT NOT NULL,
    is_primary  BOOLEAN NOT NULL DEFAULT FALSE,
    position    INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_product_images_product ON product_images (product_id, position);

CREATE UNIQUE INDEX IF NOT EXISTS idx_product_images_one_primary
    ON product_images (product_id)
    WHERE is_primary = TRUE;

-- Si la colonne image_url existait déjà sur products (schéma initial), on la retire
-- après ce point, une fois que tu as confirmé que product_images est en place.
-- ALTER TABLE products DROP COLUMN IF EXISTS image_url;
