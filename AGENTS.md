# AGENTS.md

Dépôt **d'infrastructure uniquement** : `docker-compose.yml`, `schema.sql`, `apache-*.conf`. Aucun code
applicatif, aucun build, aucun test, aucun gestionnaire de paquets. Tout est en français (README, guide,
commentaires SQL et compose) — **garder cette convention**. Messages de commit en français aussi.

## Où vit la logique métier ?

Pas ici. Les workflows n8n sont créés via l'éditeur web et stockés dans le volume Docker `n8n_data`.

- **`guide-golden-market-agent.md` est la source de vérité** sur le workflow : structure des nodes, SQL de
  chaque tool, prompts, pièges et solutions retenues. Toute question « comment marche l'agent ? » se répond
  là. Tout changement de workflow doit le tenir à jour.
- `nodes_exports/` = exports JSON locaux de sauvegarde, **gitignorés** (ne pas les versionner).
- `.env` contient des secrets réels — ne jamais l'afficher, le committer ni le recopier.

## Architecture

Stack : WhatsApp Cloud API (Meta) → webhook n8n → agent Anthropic → Postgres, sur VPS.
Golden Market, vente WhatsApp au Burkina Faso (XOF, TZ `Africa/Ouagadougou`).

- Deux services Docker, aucun port exposé publiquement : `postgres` (réseau `golden_market_net` uniquement)
  et `n8n` (bind `127.0.0.1:5678`). Le HTTPS public est fait par **Apache sur l'hôte** (hors Docker,
  certbot) — pas Caddy (retiré au commit `7b0dbb3`). `apache-n8n.conf` est un gabarit *avant* certbot
  (vhost `*:80` uniquement, `ServerName` en dur) ; les règles `RewriteCond`/`RewriteRule` websocket sont
  indispensables à l'éditeur temps réel, ne pas les retirer.
- **Une seule base Postgres (`golden_market`), deux schémas** : n8n utilise `n8n`
  (`DB_POSTGRESDB_SCHEMA: n8n`), les tables métier sont dans `public`. Toute requête depuis un node
  Postgres n8n doit cibler `public` et ne jamais toucher au schéma `n8n`.
- **Pas d'interface d'admin du catalogue** : saisie des produits en SQL via `psql`. Ne pas introduire un
  outil d'admin sans en parler au préalable (décision produit, écrite en tête du guide).

## `.env` — deux canaux distincts (source principale de confusion)

- **Injecté dans le conteneur n8n**, lisible via `{{ $env.X }}` dans les nodes Code/HTTP Request :
  `WHATSAPP_*`, `ORANGE_MONEY_*`, `OWNER_WHATSAPP_NUMBER`. Ajouter une variable demande de la déclarer
  **aussi** dans le bloc `environment:` du service n8n, puis `docker compose up -d`.
- **Purement documentaire** (saisies comme credentials dans l'UI n8n, jamais injectées) :
  `ANTHROPIC_API_KEY`, Groq, Telegram.
- `.env.example` est en retard sur le compose (il manque `WHATSAPP_APP_SECRET` et
  `OWNER_WHATSAPP_NUMBER`, requis) — le compléter en cas de modification.

## Base de données (`schema.sql`)

- Exécuté **une seule fois** à la création du volume (monté dans `/docker-entrypoint-initdb.d/01-schema.sql`).
  Le modifier ensuite n'a aucun effet tant qu'on ne l'applique pas manuellement (voir Commandes).
- Réexécutable (`IF NOT EXISTS`, `CREATE OR REPLACE`) **sauf le bloc d'INSERT d'exemple** : `products.name`
  n'est pas unique, donc chaque réexécution duplique les produits de test.
- `CREATE EXTENSION pg_trgm` doit rester **avant** l'index GIN trgm (commit `e49f988`).
- Modèle : `conversations` (une ligne par `phone_number` E.164, `status` `active`/`closed`/`escalated` —
  `escalated` = reprise humaine) ; `messages` (index unique partiel sur `whatsapp_msg_id` = **mécanisme
  d'idempotence** face aux redéliveries Meta, toute insertion passe par cet id) ; `orders` (`items` JSONB,
  flux de paiement **manuel** : `pending_payment` → `payment_reported` → `paid`/`cancelled`, aucune API
  Mobile Money) ; `product_images` (une image principale max par produit via index unique partiel, migration
  one-shot déjà appliquée : `migration-product-images.sql`). **Pas de colonne `image_url` sur `products`.**

## Workflow n8n — points non évidents

- **Deux nodes Webhook indépendants** sur le même path `whatsapp` : un `GET` (vérification Meta,
  `hub.challenge`) et un `POST` (messages). Ils ne sont pas reliés. Meta envoie aussi des accusés de
  lecture/livraison sans `messages` — d'où le node `If` en tête de chaîne POST.
- **Les 6 tools sont des sous-workflows séparés** (trigger *When Executed by Another Workflow*), chacun
  appelé par son propre node *Call n8n Workflow Tool* sous le AI Agent : `check_stock`, `get_price`,
  `create_order`, `get_payment_instructions`, `mark_payment_reported`, `escalate_to_human`.
- Le champ **Description** d'un *Call n8n Workflow Tool* est le texte que le modèle lit pour décider
  d'appeler le tool — c'est du prompt, pas un commentaire.
- **Body des HTTP Request vers Meta : toujours `{{ JSON.stringify({...}) }}`**, jamais du JSON littéral
  avec `{{ }}` inséré — casse dès que la réponse contient un retour à ligne, une apostrophe courbe ou un emoji.
- Fallback Groq `openai/gpt-oss-120b` si Anthropic échoue. Mise en production par le bouton **Publish**.

## Tester

- **`curl` avec signature HMAC** (recette dans le guide § 4), jamais de vrais messages WhatsApp rapprochés
  depuis un téléphone (flag spam Meta ~6h). Path prod `/webhook/whatsapp`, test `/webhook-test/whatsapp`.

## Sécurité

- `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` est un compromis assumé (pour lire `WHATSAPP_APP_SECRET` dans le
  node de vérification HMAC) : **n'importe quel node Code peut lire toutes les variables d'environnement**,
  y compris `POSTGRES_PASSWORD`. Ne jamais importer/copier un node Code d'un workflow tiers sans relecture
  intégrale. L'éditeur n8n n'est protégé que par Basic Auth.

## Pièges connus (corriger, pas propager)

- `check_stock` et `get_price` font `name ILIKE '%' || $1 || '%'` : `product_name` vide retourne tout le
  catalogue au lieu de rien (bug non corrigé).
- Le **README est périmé** (décrit Caddy et « .gitignore à créer », présente le workflow comme une étape
  future alors qu'il est en production).
- `N8N_PROXY_HOPS: "1"` manque au service n8n (warning `X-Forwarded-For` non bloquant).

## Commandes

```bash
docker compose up -d                 # démarrer (n8n attend le healthcheck postgres)
docker compose logs -f n8n

# Réappliquer schema.sql après modification (le script d'init ne rejoue pas)
docker compose exec -T postgres psql -U golden_market_admin -d golden_market < schema.sql

# psql interactif (user/db = POSTGRES_USER / POSTGRES_DB du .env)
docker compose exec postgres psql -U golden_market_admin -d golden_market

# Repartir de zéro (DÉTRUIT données ET workflows n8n)
docker compose down -v && docker compose up -d
```
