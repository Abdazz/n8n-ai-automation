# Golden Market — Stack n8n + Postgres

## Prérequis sur le VPS
- Docker + Docker Compose installés
- Un nom de domaine (ou sous-domaine) pointant vers l'IP du VPS, ex: `n8n.tondomaine.com`
- Ports 80 et 443 ouverts (Caddy gère le certificat HTTPS automatiquement via Let's Encrypt)

## Installation

```bash
git clone <ce-repo> golden-market-agent
cd golden-market-agent

cp .env.example .env
nano .env   # remplir POSTGRES_PASSWORD, N8N_HOST, N8N_BASIC_AUTH_PASSWORD, etc.

docker compose up -d
```

Vérifier que tout tourne :

```bash
docker compose ps
docker compose logs -f n8n
```

Le schéma SQL (`schema.sql`) est exécuté automatiquement au premier démarrage de Postgres
(via `docker-entrypoint-initdb.d`). Si tu modifies `schema.sql` après coup, il faudra
appliquer les changements manuellement (`docker compose exec postgres psql -U ... -d ...`)
— le script d'init ne tourne qu'à la création du volume.

## Accès

- Éditeur n8n : `https://n8n.tondomaine.com` (protégé par Basic Auth, identifiants dans `.env`)
- Postgres : accessible uniquement depuis le réseau Docker interne (pas exposé publiquement)

## Prochaine étape

Une fois la stack en ligne, on construit le workflow n8n :
1. Créer les credentials n8n (Anthropic API key, Meta WhatsApp Cloud API token, Postgres).
2. Configurer le webhook Meta pour pointer vers `https://n8n.tondomaine.com/webhook/whatsapp`.
3. Construire le workflow (Webhook → lecture historique → AI Agent avec tools → réponse → sauvegarde).

## Sécurité — à ne pas oublier avant la prod

- Change tous les mots de passe par défaut dans `.env`.
- N'expose jamais `.env` (déjà dans `.gitignore` à créer).
- Vérifie la signature `X-Hub-Signature-256` des webhooks Meta dans le workflow n8n.
- Limite l'accès à l'éditeur n8n (Basic Auth minimum, idéal : VPN ou IP whitelist en plus).
