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
  (`DB_POSTGRESDB_SCHEMA: n8n`), les tables métier historiques sont dans `public`. Toute requête depuis un
  node Postgres n8n doit cibler `public` et ne jamais toucher au schéma `n8n`.
- **Le catalogue produit n'est plus géré ici depuis début septembre 2026.** Le dépôt `medusa-golden-market`
  (Medusa v2, admin `/app`) est la source de vérité du catalogue — voir son `ARCHITECTURE.md`. L'agent
  WhatsApp interroge le vrai Store API Medusa via les tools `find_products`/`place_order`, plus en SQL
  direct sur `public.products`. Les tables `products`/`product_images`/`orders` de ce schéma sont des
  reliquats de l'ancienne architecture ("shadow tools"), plus lues ni écrites par le workflow actuel — voir
  section « Base de données » ci-dessous.

## `.env` — deux canaux distincts (source principale de confusion)

- **Injecté dans le conteneur n8n**, lisible via `{{ $env.X }}` dans les nodes Code/HTTP Request :
  `WHATSAPP_*`, `ORANGE_MONEY_*`, `OWNER_WHATSAPP_NUMBER`, `N8N_ORDER_CONFIRMATION_WEBHOOK_SECRET`, et
  depuis début septembre 2026 tout le jeu `MEDUSA_*` (`MEDUSA_ENV`, `MEDUSA_BACKEND_URL[_PRODUCTION]`,
  `MEDUSA_PUBLISHABLE_KEY[_PRODUCTION]`, `MEDUSA_BF_REGION_ID[_PRODUCTION]`,
  `MEDUSA_ADMIN_KEY_STAGING`/`MEDUSA_ADMIN_KEY_PRODUCTION`) — nécessaire pour que `find_products`/
  `place_order` parlent au Store/Admin API Medusa. `MEDUSA_ENV` bascule tous les workflows
  staging/production d'un coup. Ajouter une variable demande de la déclarer **aussi** dans le bloc
  `environment:` du service n8n, puis `docker compose up -d`.
- **Purement documentaire** (saisies comme credentials dans l'UI n8n, jamais injectées) :
  `ANTHROPIC_API_KEY`, Groq, Telegram.
- `.env.example` est en retard sur le compose (il manque `WHATSAPP_APP_SECRET`, `OWNER_WHATSAPP_NUMBER`
  et tout le jeu `MEDUSA_*`/`TAVILY_API_KEY`/`STABILITY_API_KEY`) — le compléter en cas de modification.

## Base de données (`schema.sql`)

- Exécuté **une seule fois** à la création du volume (monté dans `/docker-entrypoint-initdb.d/01-schema.sql`).
  Le modifier ensuite n'a aucun effet tant qu'on ne l'applique pas manuellement (voir Commandes).
- Réexécutable (`IF NOT EXISTS`, `CREATE OR REPLACE`) **sauf le bloc d'INSERT d'exemple** : `products.name`
  n'est pas unique, donc chaque réexécution duplique les produits de test.
- `CREATE EXTENSION pg_trgm` doit rester **avant** l'index GIN trgm (commit `e49f988`).
- **Tables encore actives** : `conversations` (une ligne par `phone_number` E.164, `status`
  `active`/`closed`/`escalated` — `escalated` = reprise humaine) ; `messages` (index unique partiel sur
  `whatsapp_msg_id` = **mécanisme d'idempotence** face aux redéliveries Meta, toute insertion passe par
  cet id ; colonne `seq BIGSERIAL` pour un ordre d'historique fiable — `created_at` seul ne départage pas
  deux lignes du même tour, insérées dans la même transaction). Ces deux tables sont aussi lues en lecture
  seule par l'admin Medusa (`medusa-golden-market`, visualiseur de conversations WhatsApp) via un rôle
  Postgres dédié `medusa_whatsapp_reader`.
- **Tables reliquats, plus utilisées par le workflow actuel** : `orders`, `products`, `product_images`.
  Le vrai catalogue et les vraies commandes vivent dans Medusa (`medusa-golden-market`) depuis début
  septembre 2026 — `place_order` crée un panier/commande directement via le Store API Medusa, il n'écrit
  plus dans `orders` ici. Ne pas s'y fier pour du reporting produit/commande ; ne pas les supprimer sans
  vérifier qu'aucun outil externe n'y lit encore (voir `medusa-golden-market/HANDOFF.md`, entrée du
  2026-09-05).

## Workflow n8n — points non évidents

- **Deux nodes Webhook indépendants** sur le même path `whatsapp` : un `GET` (vérification Meta,
  `hub.challenge`) et un `POST` (messages). Ils ne sont pas reliés. Meta envoie aussi des accusés de
  lecture/livraison sans `messages` — d'où le node `If` en tête de chaîne POST.
- **7 tools actifs**, chacun un sous-workflow séparé (trigger *When Executed by Another Workflow*), appelé
  par son propre node *Call n8n Workflow Tool* sous le AI Agent : `find_products`, `place_order`,
  `get_payment_instructions`, `mark_payment_reported`, `escalate_to_human`, `browse_catalog` (ajouté
  2026-09-15), `search_products_semantic` (ajouté 2026-09-18, voir guide § 2.6). Cascade de recherche
  produit : `find_products` (pg_trgm) → `search_products_semantic` (embeddings pgvector) →
  `browse_catalog` en tout dernier recours. (`check_stock`, `get_price`, `create_order` et l'ancien
  `place_order` supprimés en base le 2026-09-15, cf. « Pièges connus ».)
- Le champ **Description** d'un *Call n8n Workflow Tool* est le texte que le modèle lit pour décider
  d'appeler le tool — c'est du prompt, pas un commentaire.
- **Body des HTTP Request vers Meta : toujours `{{ JSON.stringify({...}) }}`**, jamais du JSON littéral
  avec `{{ }}` inséré — casse dès que la réponse contient un retour à ligne, une apostrophe courbe ou un emoji.
- **⚠️ Anomalie identifiée le 2026-09-15, corrigée puis DÉLIBÉRÉMENT ANNULÉE le jour même : le modèle
  principal du node `AI Agent` est `Groq Chat Model` (`openai/gpt-oss-120b`, branché en index 0),
  Claude Sonnet 5 n'étant que le fallback (index 1)** — c'est l'inverse de l'intention documentée
  historiquement dans le guide (Claude en principal, Groq en secours ponctuel). Un incident déjà
  documenté dans `medusa-golden-market/HANDOFF.md` (2026-09-07) montre Groq boucler sur des
  reformulations fautives d'une recherche produit avant de trouver le bon terme — probable cause
  principale des problèmes de qualité de conversation signalés par le propriétaire. **L'inversion a été
  appliquée en prod puis annulée dans la même session car le propriétaire n'a pas de crédit Anthropic
  disponible pour le moment** (Claude en principal ferait échouer le premier appel à chaque tour). **Ne
  pas réinverser sans vérifier d'abord que du crédit Anthropic est disponible** — voir
  `medusa-golden-market/HANDOFF.md`, entrée du 2026-09-15, pour le détail de la manip (import/export
  CLI + redémarrage du conteneur).
- Mise en production par le bouton **Publish**.
- **⚠️ `onError: "continueErrorOutput"` va au niveau racine du node (sœur de `id`/`name`/`type`),
  PAS dans `parameters`** — mal placé, n8n l'ignore sans avertissement à l'import, et le node se
  comporte comme sans gestion d'erreur (piège trouvé le 2026-09-15 en le faisant, a provoqué un
  vrai crash de tout le node `AI Agent` sur un node du workflow principal — voir guide § 2.6 "Piège
  critique").
- **⚠️ Le template WhatsApp `escalation_alert` n'existait pas du tout sur le compte Meta avant le
  2026-09-15** (créé et approuvé ce jour-là) — cassait silencieusement `escalate_to_human` et
  `mark_payment_reported` en prod depuis le début (aucune gestion d'erreur = le client ne recevait
  alors aucune réponse). Corps du template : voir guide § 1, contrainte Meta sur le placement des
  variables à connaître si on le recrée un jour.

## Tester

- **`curl` avec signature HMAC** (recette dans le guide § 4), jamais de vrais messages WhatsApp rapprochés
  depuis un téléphone (flag spam Meta ~6h). Path prod `/webhook/whatsapp`, test `/webhook-test/whatsapp`.

## Sécurité

- `N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"` est un compromis assumé (pour lire `WHATSAPP_APP_SECRET` dans le
  node de vérification HMAC) : **n'importe quel node Code peut lire toutes les variables d'environnement**,
  y compris `POSTGRES_PASSWORD`. Ne jamais importer/copier un node Code d'un workflow tiers sans relecture
  intégrale. L'éditeur n8n n'est protégé que par Basic Auth.

## Pièges connus (corriger, pas propager)

- **`check_stock`, `get_price`, `create_order` (et l'ancienne version de `place_order`) sont supprimés
  du n8n de prod depuis le 2026-09-15** — remplacés par `find_products`/`place_order`, qui parlent
  directement au Store API Medusa (voir `medusa-golden-market/HANDOFF.md`, entrées 2026-09-04 à
  2026-09-07). Le bug `ILIKE '%%'` sur `product_name` vide n'existe donc plus dans ces tools ; ne pas le
  reproposer comme limite connue. La recherche produit passe maintenant par
  `/store/products-fuzzy-search` (pg_trgm, tolérant aux fautes de frappe/accents/pluriel — pas aux
  synonymes).
- Le **README est périmé** (décrit Caddy et « .gitignore à créer », présente le workflow comme une étape
  future alors qu'il est en production).
- `N8N_PROXY_HOPS: "1"` manque au service n8n (warning `X-Forwarded-For` non bloquant).
- **`guide-golden-market-agent.md` a longtemps décrit une architecture obsolète** (tools SQL directs sur
  `public.products`, base `golden_market`) alors que la prod utilise le Store API Medusa depuis début
  septembre 2026. Réécrit le 2026-09-15 pour refléter l'architecture actuelle — si un futur changement de
  workflow le rend à nouveau périmé, se fier à `medusa-golden-market/HANDOFF.md` en attendant la mise à
  jour du guide, pas à ce dernier seul.

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
