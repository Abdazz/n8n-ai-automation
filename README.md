# Golden Market — Agent WhatsApp (n8n + Postgres)

Stack self-hosted qui fait tourner un agent conversationnel WhatsApp pour **Golden Market**, un
commerce en ligne au Burkina Faso. Un client écrit sur WhatsApp, un agent IA (Claude, via n8n)
répond en s'appuyant sur un catalogue produits et un historique de conversation stockés en
Postgres — recherche produit, prix, création de commande, instructions de paiement Mobile Money,
et escalade vers un humain quand l'agent ne peut pas traiter la demande.

## Aperçu de l'architecture

```
WhatsApp (client)
      │
      ▼
WhatsApp Cloud API (Meta)
      │  webhook HTTPS
      ▼
Apache (hôte, reverse proxy + TLS)
      │
      ▼
n8n  ──────────────►  Agent Anthropic (Claude) ──► tools (sous-workflows n8n)
      │                                                   │
      └──────────────────► Postgres  ◄────────────────────┘
           (conversations, messages, produits, commandes)
```

- **n8n** héberge le workflow : réception des messages WhatsApp, reconstruction du contexte de
  conversation, appel du modèle, exécution des tools, envoi de la réponse et journalisation.
- **Postgres** est la seule base de données, utilisée à la fois par n8n (son propre schéma) et par
  le workflow métier (schéma `public`).
- **Apache**, installé sur l'hôte (hors Docker), termine le HTTPS public et proxy vers n8n en
  local. Certificat géré par Certbot / Let's Encrypt.
- Aucune interface d'administration : le catalogue produit se gère en SQL via `psql`.

Le détail complet du workflow (structure des nodes, SQL de chaque tool, prompts, pièges connus)
vit dans `guide-golden-market-agent.md`, qui fait foi sur tout ce qui touche à l'agent n8n.

## Stack technique

| Composant | Rôle |
|---|---|
| [n8n](https://n8n.io/) (self-hosted, Community) | Orchestration du workflow, agent IA, tools |
| [PostgreSQL 16](https://www.postgresql.org/) | Catalogue produits, conversations, commandes, données internes n8n |
| [Anthropic Claude](https://www.anthropic.com/) | Modèle de l'agent conversationnel (fallback Groq en cas d'échec) |
| [WhatsApp Cloud API](https://developers.facebook.com/docs/whatsapp/cloud-api) (Meta) | Canal de messagerie client |
| Apache (sur l'hôte) + Certbot | Reverse proxy HTTPS public vers n8n |
| Docker Compose | Déploiement de n8n et Postgres |

## Prérequis

- Un VPS Linux avec Docker et Docker Compose installés.
- Apache installé **sur l'hôte** (pas dans Docker), avec les modules `proxy`, `proxy_http`,
  `proxy_wstunnel`, `rewrite` activés.
- Un nom de domaine (ou sous-domaine) pointant vers l'IP du VPS, ex : `n8n.tondomaine.com`.
- Ports 80 et 443 ouverts (Certbot y génère et renouvelle le certificat HTTPS).
- Un compte Meta Developer avec une app WhatsApp Cloud API configurée.
- Une clé API Anthropic (et optionnellement Groq, utilisé en fallback).

## Installation

```bash
git clone <url-de-ce-repo> golden-market-agent
cd golden-market-agent

cp .env.example .env
nano .env   # voir "Configuration" ci-dessous

docker compose up -d
```

Vérifier que tout tourne :

```bash
docker compose ps
docker compose logs -f n8n
```

Le schéma SQL (`schema.sql`) s'exécute automatiquement **au premier démarrage** de Postgres, via
`docker-entrypoint-initdb.d`. Il ne se rejoue pas ensuite : toute modification ultérieure de
`schema.sql` doit être appliquée à la main :

```bash
docker compose exec -T postgres psql -U golden_market_admin -d golden_market < schema.sql
```

### Reverse proxy Apache

Le HTTPS public n'est pas géré par Docker. Sur l'hôte :

```bash
cp apache-n8n.conf /etc/apache2/sites-available/n8n.conf
# adapter ServerName si besoin
a2ensite n8n
systemctl reload apache2
certbot --apache -d n8n.tondomaine.com
```

## Configuration (`.env`)

Le `.env` alimente deux choses distinctes :

1. **Injecté dans le conteneur n8n** (déclaré dans `docker-compose.yml`, lisible via `{{ $env.X }}`
   dans les nodes du workflow) : identifiants Postgres, config n8n, `WHATSAPP_*`,
   `ORANGE_MONEY_*`, `OWNER_WHATSAPP_NUMBER`. Ajouter une variable ici demande de la déclarer
   aussi dans `docker-compose.yml`, puis de relancer `docker compose up -d`.
2. **Purement documentaire** : clés d'API (Anthropic, Groq, Telegram...) qui se saisissent comme
   *credentials* directement dans l'éditeur n8n, pas dans `.env`.

Ne jamais committer le vrai `.env` (il est dans `.gitignore`).

## Construire le workflow

Une fois la stack en ligne :

1. Créer les credentials n8n (clé API Anthropic, token WhatsApp Cloud API, connexion Postgres).
2. Configurer le webhook Meta pour pointer vers `https://n8n.tondomaine.com/webhook/whatsapp`.
3. Publier le workflow dans l'éditeur n8n (bouton **Publish**).

Voir `guide-golden-market-agent.md` pour la structure détaillée (nodes, tools, prompts).

## Modèle de données

Schéma Postgres (`schema.sql`), résumé :

- `conversations` — une ligne par client (numéro WhatsApp), avec un statut (`active` / `closed` /
  `escalated`).
- `messages` — historique complet des échanges, utilisé pour reconstruire le contexte de l'agent.
- `products` / `product_images` — catalogue, recherche floue par nom (`pg_trgm`).
- `orders` — commandes, paiement suivi manuellement (Mobile Money, pas d'API de paiement).

## Sécurité

- `.env` contient des secrets réels : ne jamais l'afficher, le committer ni le dupliquer ailleurs.
- Postgres n'est joignable que depuis le réseau Docker interne, jamais exposé publiquement.
- n8n n'est bindé qu'en local (`127.0.0.1:5678`) ; seul Apache l'expose en HTTPS.
- Les webhooks WhatsApp entrants sont vérifiés par signature HMAC (`X-Hub-Signature-256`).
- L'éditeur n8n n'est protégé que par Basic Auth — envisager un VPN ou une whitelist IP en
  complément avant une mise en production sérieuse.
- Changer tous les mots de passe par défaut avant tout déploiement réel.

## Limites connues

- Pas d'interface d'administration du catalogue : la saisie produit se fait en SQL.
- Le paiement Mobile Money est entièrement déclaratif (le client signale qu'il a payé, un humain
  confirme) — aucune intégration API Mobile Money.
- `check_stock` et `get_price` retournent tout le catalogue si le nom de produit recherché est vide.

## Licence

Distribué sous licence MIT — voir [`LICENSE`](./LICENSE).
