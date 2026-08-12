# Golden Market — Agent IA WhatsApp — Guide de construction

## État actuel ✅

- [x] VPS avec Docker + Docker Compose
- [x] Stack déployée : Postgres + n8n (Apache en reverse proxy, SSL via certbot)
- [x] Accès à l'éditeur n8n sur `https://n8n.golden-market.co`
- [x] Schéma SQL en place (`products`, `conversations`, `messages`, `orders`)
- [x] Credential Postgres créé et testé dans n8n
- [x] Credential Anthropic créé dans n8n
- [x] Webhook GET (vérification Meta) + POST (réception messages) construits
- [x] Extraction des données + vérification de signature Meta
- [x] Historique de conversation (lecture Postgres) branché à l'AI Agent
- [x] AI Agent configuré (System Prompt + Chat Model Anthropic)
- [x] Les 6 tools construits et testés : `check_stock`, `get_price`, `create_order`, `get_payment_instructions`, `mark_payment_reported`, `escalate_to_human`
- [x] Notification WhatsApp d'escalade humaine confirmée fonctionnelle (message reçu en réel)
- [x] Envoi de la réponse au client (3.6) + sauvegarde du tour de conversation (3.7)
- [x] Fallback Groq (`openai/gpt-oss-120b`) configuré sur le AI Agent
- [x] **Workflow publié et testé de bout en bout avec un vrai message WhatsApp — réponse reçue avec succès** 🎉
- [x] Support multi-images en base via la table `product_images` (migration appliquée en prod)

## Ce qu'il reste à faire

1. **Question ouverte — gestion du catalogue produits.** Aucun outil d'admin ne la gère à ce jour : la
   saisie et la mise à jour des produits (`products`, `product_images`) se font en SQL via `psql`.
   À trancher : outil d'admin, formulaires n8n, ou on reste en SQL.
2. Remplacer les produits d'exemple par le vrai catalogue Golden Market
3. Passer en revue la checklist sécurité avant mise en prod (section 5)
4. Corriger le warning `X-Forwarded-For` / `trust proxy` (ajouter `N8N_PROXY_HOPS: "1"` au service n8n) — non bloquant mais à faire
5. Envisager l'App Review Meta si besoin de contacter des numéros au-delà des 5 testeurs autorisés en mode développement
6. Limite connue non corrigée : `check_stock`/`get_price` avec `product_name` vide retournent tous les produits (`ILIKE '%%'`) — à corriger si des faux positifs apparaissent en usage réel

---

## 1. Configuration WhatsApp Cloud API (Meta)

### 1.1 Créer le compte développeur et l'app

1. Va sur [developers.facebook.com](https://developers.facebook.com) et connecte-toi/inscris-toi.
2. **My Apps → Create App → Business** (choisis le type "Business").
3. Donne un nom (ex: `Golden Market Bot`), associe-le à ton **Meta Business Account** (crée-en un si tu n'en as pas — vérification d'identité peut prendre 1 à 3 jours).
4. Dans le dashboard de l'app, ajoute le produit **WhatsApp**.

### 1.2 Récupérer les identifiants

Dans **WhatsApp → API Setup** :

| Élément | Où le trouver | À noter |
|---|---|---|
| **Phone Number ID** | Section "Send and receive messages" | ex: `123456789012345` |
| **WhatsApp Business Account ID (WABA)** | Même section | ex: `987654321098765` |
| **Token temporaire** | Bouton "Generate access token" | valable 24h — à remplacer par un token permanent (étape suivante) |

### 1.3 Générer un token permanent (System User Token)

Le token temporaire expire en 24h — inutilisable en prod.

1. Va dans **Meta Business Suite → Paramètres de l'entreprise → Utilisateurs → Utilisateurs système**.
2. Crée un utilisateur système (rôle **Admin**).
3. **Ajouter des actifs** → sélectionne ton app WhatsApp → coche les permissions.
4. **Générer un nouveau token** :
   - Sélectionne l'app
   - Coche les scopes : `whatsapp_business_messaging`, `whatsapp_business_management`
   - Durée : **Never expire** si disponible, sinon note la date d'expiration pour renouveler à temps
5. Copie ce token — **il ne sera affiché qu'une seule fois**.

### 1.4 Enregistrer ton numéro WhatsApp Business

- Si ton numéro est déjà actif sur l'app WhatsApp Business classique, tu devras le **migrer** vers Cloud API (Meta te guide dans l'interface — attention, ça déconnecte l'app mobile classique de ce numéro).
- Vérifie le numéro par SMS/appel dans l'interface **API Setup**.

### 1.5 Configurer le Verify Token (webhook)

Invente une chaîne secrète quelconque, ex : `golden_market_verify_2026_xK9pL`. Note-la — tu en auras besoin à l'étape 1.6 et dans n8n.

### 1.6 Configurer le Webhook dans Meta

Dans **WhatsApp → Configuration → Webhook** :

- **Callback URL** : `https://n8n.golden-market.co/webhook/whatsapp` *(l'URL exacte dépendra du nom que tu donnes au node Webhook dans n8n — on la crée à l'étape 3)*
- **Verify Token** : la chaîne choisie en 1.5
- **Champs à souscrire (Webhook fields)** : coche au minimum `messages`

⚠️ Tu ne pourras valider cette étape qu'**après** avoir créé le node Webhook dans n8n (étape 3.1) — Meta envoie une requête `GET` de vérification que ton workflow doit savoir répondre.

### 1.7 Ajouter les valeurs dans ton `.env`

```bash
WHATSAPP_PHONE_NUMBER_ID=123456789012345
WHATSAPP_ACCESS_TOKEN=<ton_token_permanent>
WHATSAPP_VERIFY_TOKEN=golden_market_verify_2026_xK9pL
WHATSAPP_BUSINESS_ACCOUNT_ID=987654321098765
```

Puis redémarre la stack pour que n8n les ait en variables d'environnement si tu comptes les référencer via `{{$env.WHATSAPP_ACCESS_TOKEN}}` :
```bash
docker compose down && docker compose up -d
```

Alternative plus propre : crée plutôt un **credential "Header Auth"** dans n8n pour le token WhatsApp (Name: `Authorization`, Value: `Bearer <token>`), à utiliser dans les nodes HTTP Request — évite d'exposer le token dans les variables d'env visibles par tous les workflows.

---

## 2. Template WhatsApp pour l'escalade humaine

Dans **Meta Business Suite → WhatsApp Manager → Message Templates → Create Template** :

- **Nom** : `escalation_alert`
- **Catégorie** : `Utility`
- **Langue** : Français
- **Corps** :
```
🔔 Golden Market - Intervention requise
Client : {{1}}
Message : {{2}}
Voir la conversation : {{3}}
```
- Soumets pour approbation (généralement rapide pour un template utilitaire simple).

Une fois approuvé, tu l'utiliseras dans le tool `escalate_to_human` (voir section 3.5).

---

## 3. Construction du workflow n8n

### Vue d'ensemble du workflow

```
[Webhook: réception]
        │
        ▼
[Vérifier signature Meta] ──(invalide)──► [Répondre 403]
        │ (valide)
        ▼
[Extraire message + numéro]
        │
        ▼
[Postgres: trouver ou créer conversation]
        │
        ▼
[Postgres: récupérer historique messages]
        │
        ▼
[AI Agent (Claude) avec tools] ◄────────┐
        │                                │
        ├─ check_stock ──────────────────┤
        ├─ get_price ─────────────────────┤
        ├─ create_order ──────────────────┤
        ├─ get_payment_instructions ──────┤
        ├─ mark_payment_reported ─────────┤
        └─ escalate_to_human ─────────────┘
        │
        ▼
[HTTP Request: envoyer réponse via Meta API]
        │
        ▼
[Postgres: sauvegarder le tour de conversation]
```

### 3.1 Node Webhook — réception des messages

⚠️ Il faut **deux nodes Webhook séparés et indépendants** sur le canvas (chacun est un trigger à part entière, pas besoin de les relier entre eux) :

**Webhook #1 — vérification Meta (une seule fois, au moment de la config du webhook côté Meta)**
1. **Add node → Webhook**
2. **HTTP Method** : `GET`
3. **Path** : `whatsapp`
4. **Respond** : `Using 'Respond to Webhook' Node`
5. Connecte-le à un node **If**, condition :
   - `{{ $json.query["hub.verify_token"] }}` **is equal to** `<ta valeur WHATSAPP_VERIFY_TOKEN>`
6. Branche **true** → node **Respond to Webhook** :
   - Respond With : `Text`
   - Response Body : `{{ $json.query["hub.challenge"] }}`
   - Response Code : `200`
7. Branche **false** → autre node **Respond to Webhook** :
   - Response Code : `403`
   - Response Body : `Verification failed`

**Webhook #2 — réception des vrais messages (en continu, une fois la vérification passée)**
1. **Add node → Webhook** (nouveau node séparé, pas connecté au premier)
2. **HTTP Method** : `POST`
3. **Path** : `whatsapp` (le même chemin — n8n distingue GET et POST automatiquement)
4. C'est le point de départ de toute la suite du workflow (sections 3.2 et suivantes).

⚠️ **Le workflow doit être activé** (toggle "Active" en haut à droite de l'éditeur) pour que l'URL de production réponde. Sans ça, la vérification Meta échoue avec une erreur du type *"Impossible de valider l'URL de rappel"*.

Ton canvas ressemble à deux branches indépendantes :
```
[Webhook GET]  → [If] → [Respond 200 / 403]        (vérification Meta, ponctuel)

[Webhook POST] → [If: messages existe ?] → ...      (messages réels, en continu)
```

### 3.2 Vérifier la signature (sécurité)

Sur les requêtes POST entrantes, Meta signe le payload avec `X-Hub-Signature-256` (HMAC-SHA256 avec ton App Secret). Ajoute un node **Code** juste après le Webhook :

```javascript
const crypto = require('crypto');

const appSecret = $env.WHATSAPP_APP_SECRET; // récupéré depuis Meta → App Settings → Basic
const signature = $input.item.json.headers['x-hub-signature-256'];
const body = JSON.stringify($input.item.json.body);

const expectedSignature = 'sha256=' + crypto
  .createHmac('sha256', appSecret)
  .update(body)
  .digest('hex');

if (signature !== expectedSignature) {
  throw new Error('Signature invalide — requête rejetée');
}

return $input.item;
```

Ajoute `WHATSAPP_APP_SECRET` (trouvable dans **App Settings → Basic** sur Meta) à ton `.env`.

**Config n8n requise** — ajoute ces variables au service `n8n` dans `docker-compose.yml` :
```yaml
NODE_FUNCTION_ALLOW_BUILTIN: crypto        # autorise l'import du module 'crypto'
N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"      # autorise $env dans les nodes Code
```

⚠️ **Compromis de sécurité assumé** : `N8N_BLOCK_ENV_ACCESS_IN_NODE: false` donne accès à *toutes* les variables d'environnement (y compris `POSTGRES_PASSWORD`, `ANTHROPIC_API_KEY`, etc.) depuis n'importe quel node Code, pas seulement `WHATSAPP_APP_SECRET`. L'alternative propre (n8n Custom Variables, `$vars`) n'est disponible que sur les plans Enterprise/Pro, pas en Community self-hosted. Décision prise pour ce projet : rester sur `$env`, en s'imposant la règle de ne jamais copier un node Code depuis un workflow tiers sans relecture complète.

### 3.3 Extraire les infos du message

Le payload que Meta envoie en POST est un JSON imbriqué :
```json
{
  "body": {
    "entry": [{
      "changes": [{
        "value": {
          "messages": [{
            "from": "22670000000",
            "id": "wamid.HBg...",
            "text": { "body": "Bonjour, avez-vous..." }
          }]
        }
      }]
    }]
  }
}
```

⚠️ Meta envoie aussi des webhooks POST pour d'autres événements (accusés de lecture/livraison), qui n'ont pas de `messages`. Ajoute d'abord un node **If** juste après le Webhook POST :
- Condition : `{{ $json.body.entry[0].changes[0].value.messages }}` **is not empty**
- Branche **false** → **Respond to Webhook** (code `200`, corps vide) — on ignore silencieusement
- Branche **true** → continue vers le node suivant

Puis, sur la branche **true**, ajoute un node **Edit Fields (Set)** pour transformer ce JSON imbriqué en champs simples et nommés, réutilisables partout ensuite via `{{ $json.from }}` etc. Clique sur **"Add Field"** trois fois et remplis :

| Name | Type | Value |
|---|---|---|
| `from` | String | `{{ $json.body.entry[0].changes[0].value.messages[0].from }}` |
| `message_text` | String | `{{ $json.body.entry[0].changes[0].value.messages[0].text.body }}` |
| `whatsapp_msg_id` | String | `{{ $json.body.entry[0].changes[0].value.messages[0].id }}` |

**Astuce** : dans le panneau de données d'entrée à droite du node, tu peux cliquer-glisser directement un champ du JSON reçu (ex: `from`) vers le champ Value — n8n génère l'expression correcte pour toi, pas besoin de la taper à la main.

Ton flow complet jusqu'ici :
```
[Webhook POST] → [If: messages existe ?]
                     ├─ true  → [Edit Fields] → [Vérifier signature] → ...
                     └─ false → [Respond 200 vide]
```

### 3.4 Postgres — conversation + historique

**Node Postgres #1** (Execute Query) — trouver ou créer la conversation :
```sql
INSERT INTO conversations (phone_number, last_message_at)
VALUES ($1, now())
ON CONFLICT (phone_number)
DO UPDATE SET last_message_at = now()
RETURNING id;
```
Paramètre `$1` = numéro extrait à l'étape 3.3.

**Node Postgres #2** — récupérer l'historique (les 20 derniers messages par ex.) :
```sql
SELECT role, content
FROM messages
WHERE conversation_id = $1
ORDER BY created_at ASC
LIMIT 20;
```

### 3.5 AI Agent node — le cœur de l'agent

1. **Add node → AI Agent**
2. **Chat Model** : sélectionne le credential Anthropic, modèle Claude (Sonnet recommandé pour ce cas d'usage — bon équilibre coût/qualité).
3. **System Prompt** — exemple de structure :

```
Tu es l'assistant commercial de Golden Market, une boutique en ligne au Burkina Faso.
Ton rôle : accueillir les prospects sur WhatsApp, répondre à leurs questions produits,
et les accompagner jusqu'à la commande.

Règles strictes :
- N'invente JAMAIS un prix, un stock, ou une promesse de livraison — utilise toujours les tools.
- N'accorde jamais de remise non prévue.
- Si le client est mécontent, confus après 2 tentatives, ou demande explicitement un humain → utilise escalate_to_human.
- Pour finaliser une commande : utilise create_order, puis get_payment_instructions.
- Le paiement se fait par transfert Mobile Money manuel — explique clairement le numéro et le montant exact, et demande une preuve de transfert.
- Ton : chaleureux, professionnel, réponses courtes adaptées à WhatsApp (pas de pavés).
- Langue : français, sauf si le client écrit dans une autre langue.
```

4. **Tools** — chaque tool est un sous-workflow n8n séparé, avec un trigger **"When Executed by Another Workflow"**, appelé depuis le AI Agent via **"Call n8n Workflow Tool"**.

**Configuration du node "Call n8n Workflow Tool"** (côté workflow principal, sous-node ajouté via `+` sous **Tool** du node AI Agent) — champs à renseigner :
- **Workflow** : sélectionne le sous-workflow correspondant (ex: `Tool - check_stock`).
- **Description** : champ texte juste en dessous du champ Workflow. **C'est le texte que Claude lit pour décider quand appeler ce tool** — pas une note pour toi. Sois précis sur le *quand* l'utiliser, pas juste le *quoi* (voir exemples de description pour chaque tool ci-dessous).
- **Input Fields** : une fois le Workflow sélectionné, n8n affiche automatiquement la liste des champs définis dans le trigger du sous-workflow (`product_name`, `items`, etc.), chacun avec un switch pour choisir le mode de remplissage.

**Principe du mapping des Input Fields** :
- Champs que seul le client peut préciser (ex: nom de produit, quantité, adresse) → mode **"Let the model define"**.
- Champs déjà connus avec certitude par le workflow (ex: `phone_number`, `conversation_id`) → mode **valeur fixe/expression**, référencée depuis les nodes du workflow principal (ex: `{{ $('Edit Fields').item.json.from }}`).

#### Tool `check_stock`

**Trigger — Input Fields** : `product_name` (String)

**Node Postgres** :
```sql
SELECT name, stock_qty, is_active
FROM products
WHERE name ILIKE '%' || $1 || '%'
  AND is_active = true
LIMIT 5;
```
Query Parameters : `{{ [$json.product_name] }}`

**Node Code (retour)** :
```javascript
const results = $input.all().map(item => item.json);

if (results.length === 0) {
  return { json: { result: "Aucun produit trouvé avec ce nom." } };
}

const summary = results.map(p =>
  `${p.name} : ${p.stock_qty > 0 ? `${p.stock_qty} en stock` : 'rupture de stock'}`
).join('\n');

return { json: { result: summary } };
```

**Tool Description** (côté workflow principal) :
```
Vérifie la disponibilité en stock d'un produit à partir de son nom. Utilise ce tool avant d'affirmer qu'un produit est disponible ou non.
```

⚠️ **Limite connue** : si `product_name` est une chaîne vide, `ILIKE '%%'` matche tous les produits. Non corrigé pour l'instant (le System Prompt guide l'agent à toujours fournir une vraie valeur) — à corriger plus tard avec un node If si des faux positifs apparaissent en usage réel.

#### Tool `get_price`

Même structure que `check_stock`.

**Node Postgres** :
```sql
SELECT name, price, currency
FROM products
WHERE name ILIKE '%' || $1 || '%'
  AND is_active = true
LIMIT 5;
```
Query Parameters : `{{ [$json.product_name] }}`

**Node Code (retour)** :
```javascript
const results = $input.all().map(item => item.json);

if (results.length === 0) {
  return { json: { result: "Aucun produit trouvé avec ce nom." } };
}

const summary = results.map(p =>
  `${p.name} : ${p.price} ${p.currency}`
).join('\n');

return { json: { result: summary } };
```

**Tool Description** :
```
Retourne le prix d'un produit à partir de son nom. Utilise ce tool avant d'annoncer un prix à un client.
```

#### Tool `create_order`

**Trigger — Input Fields** :
| Field Name | Type | Mode (côté workflow principal) |
|---|---|---|
| `items` | String — JSON, ex: `[{"product_name":"...","quantity":2}]` | Let the model define |
| `phone_number` | String | Fixe : `{{ $('Edit Fields').item.json.from }}` |
| `conversation_id` | String (UUID) | Fixe : `{{ $('Postgres #1').item.json.id }}` |
| `delivery_address` | String | Let the model define |

⚠️ **Point technique important** : `$('When Executed by Another Workflow').item.json...` peut casser après un node Postgres avec `WITH`/`JOIN` (problème de "pairing" observé en pratique) — les champs reviennent `null`. **Solution retenue** : faire transiter `phone_number`, `conversation_id`, `delivery_address` directement à travers la requête SQL elle-même (en paramètres constants `$2`, `$3`, `$4`), plutôt que d'aller les rechercher dans un node externe au node suivant.

**Node Postgres (calcul des sous-totaux + passage des infos client)** :
```sql
WITH item_data AS (
  SELECT
    (elem->>'product_name') AS product_name,
    (elem->>'quantity')::int AS quantity
  FROM jsonb_array_elements($1::jsonb) AS elem
)
SELECT
  p.id,
  p.name,
  p.price,
  id.quantity,
  (p.price * id.quantity) AS subtotal,
  $2::text AS phone_number,
  $3::uuid AS conversation_id,
  $4::text AS delivery_address
FROM item_data id
JOIN products p ON p.name ILIKE id.product_name AND p.is_active = true;
```
Query Parameters :
```
{{ [ typeof $json.items === 'string' ? $json.items : JSON.stringify($json.items), $json.phone_number, $json.conversation_id, $json.delivery_address ] }}
```

**Node Code (agrégation)** :
```javascript
const rows = $input.all().map(item => item.json);

if (rows.length === 0) {
  return { json: { result: "Aucun des produits demandés n'a été trouvé. Vérifie les noms." } };
}

const items = rows.map(r => ({
  product_id: r.id,
  name: r.name,
  qty: r.quantity,
  unit_price: r.price
}));

const total = rows.reduce((sum, r) => sum + Number(r.subtotal), 0);

return {
  json: {
    items_json: JSON.stringify(items),
    total_amount: total,
    phone_number: rows[0].phone_number,
    conversation_id: rows[0].conversation_id,
    delivery_address: rows[0].delivery_address
  }
};
```

**Node Postgres (insertion)** :
```sql
INSERT INTO orders (conversation_id, phone_number, items, total_amount, delivery_address, status)
VALUES ($1, $2, $3::jsonb, $4, $5, 'pending_payment')
RETURNING id, total_amount;
```
Query Parameters :
```
{{ [$json.conversation_id, $json.phone_number, $json.items_json, $json.total_amount, $json.delivery_address] }}
```

**Node Code (retour formaté)** :
```javascript
const order = $json;
return {
  json: {
    result: `Commande créée (ID: ${order.id}). Montant total : ${order.total_amount} XOF. Utilise get_payment_instructions pour indiquer au client comment payer.`
  }
};
```

**Tool Description** :
```
Crée une commande à partir d'une liste d'articles (nom du produit + quantité). Utilise ce tool uniquement quand le client a confirmé exactement ce qu'il veut commander.
```

#### Tool `get_payment_instructions`

**Trigger — Input Fields** :
| Field Name | Type | Mode (côté workflow principal) |
|---|---|---|
| `order_id` | String (UUID) | Let the model define — Claude le reprend depuis le résultat du tool `create_order` |

**Node Postgres** :
```sql
SELECT id, total_amount, currency, status
FROM orders
WHERE id = $1::uuid;
```
Query Parameters : `{{ [$json.order_id] }}`

**Node Code (formatage)** :
```javascript
const order = $input.first().json;

if (!order) {
  return { json: { result: "Commande introuvable. Vérifie l'ID de commande." } };
}

const orangeMoneyNumber = $env.ORANGE_MONEY_NUMBER;
const orangeMoneyName = $env.ORANGE_MONEY_NAME || "Golden Market";

const message = `Pour finaliser ta commande, effectue un transfert Orange Money de ${order.total_amount} ${order.currency} au numéro ${orangeMoneyNumber} (${orangeMoneyName}).

Une fois le transfert effectué, envoie-moi une capture d'écran ou le numéro de transaction pour confirmation.`;

return { json: { result: message } };
```

**Config requise** — ajoute à `.env` et au bloc `environment` du service `n8n` dans `docker-compose.yml` :
```bash
ORANGE_MONEY_NUMBER=+226XXXXXXXX
ORANGE_MONEY_NAME=Golden Market
```

**Tool Description** :
```
Retourne les instructions de paiement Mobile Money pour une commande précise. Utilise ce tool juste après avoir créé une commande avec create_order.
```

#### Tool `mark_payment_reported`

**Trigger — Input Fields** :
| Field Name | Type | Mode (côté workflow principal) |
|---|---|---|
| `order_id` | String (UUID) | Let the model define |
| `payment_reference` | String — optionnel (preuve donnée par le client) | Let the model define |

**Node Postgres (mise à jour du statut)**, nommé `Format Result`-compatible — donne un nom explicite au node Code suivant pour fiabiliser les références :
```sql
UPDATE orders
SET status = 'payment_reported',
    payment_reference = $2
WHERE id = $1::uuid
RETURNING id, total_amount, phone_number, status;
```
Query Parameters : `{{ [$json.order_id, $json.payment_reference || null] }}`

**Node Code — renomme-le `Format Result`** (retour convivial pour l'agent) :
```javascript
const order = $input.first().json;

if (!order) {
  return { json: { result: "Commande introuvable — impossible de marquer le paiement." } };
}

return {
  json: {
    result: `C'est noté, merci ! Ta commande (${order.id}) est marquée comme en attente de vérification. Un membre de notre équipe va confirmer la réception du paiement sous peu.`,
    order_id: order.id,
    phone_number: order.phone_number,
    total_amount: order.total_amount
  }
};
```

**Node HTTP Request — notification automatique (Option B retenue)** — la notification humaine est déclenchée systématiquement ici, sans dépendre d'un enchaînement de tools décidé par l'agent :
```
POST https://graph.facebook.com/v20.0/{{ $env.WHATSAPP_PHONE_NUMBER_ID }}/messages

Headers:
  Authorization: Bearer {{ $env.WHATSAPP_ACCESS_TOKEN }}
  Content-Type: application/json

Body (JSON, mode "Send Body" activé, "Specify Body" = "Using JSON") :
{
  "messaging_product": "whatsapp",
  "to": "{{ $env.OWNER_WHATSAPP_NUMBER }}",
  "type": "template",
  "template": {
    "name": "escalation_alert",
    "language": { "code": "fr" },
    "components": [
      {
        "type": "body",
        "parameters": [
          { "type": "text", "text": "{{ $('Format Result').first().json.phone_number }}" },
          { "type": "text", "text": "Paiement signalé pour la commande {{ $('Format Result').first().json.order_id }} — montant {{ $('Format Result').first().json.total_amount }} XOF" },
          { "type": "text", "text": "{{ $('Format Result').first().json.order_id }}" }
        ]
      }
    ]
  }
}
```

**Node Code final (retour agent)** — on repasse le message convivial, pas l'accusé technique de l'API Meta :
```javascript
return {
  json: {
    result: $('Format Result').first().json.result
  }
};
```

**Config requise** — ajoute à `.env` et au `docker-compose.yml` :
```bash
OWNER_WHATSAPP_NUMBER=+226XXXXXXXX
```

**Tool Description** :
```
Marque une commande comme "paiement signalé par le client" et notifie automatiquement l'équipe pour vérification. Utilise ce tool quand le client confirme avoir effectué le transfert Mobile Money.
```

#### Tool `escalate_to_human`

**Trigger — Input Fields** :
| Field Name | Type | Mode (côté workflow principal) |
|---|---|---|
| `phone_number` | String | Fixe : `{{ $('Edit Fields').item.json.from }}` |
| `reason` | String | Let the model define |
| `conversation_id` | String (UUID) | Fixe : `{{ $('Postgres #1').item.json.id }}` |

**Node HTTP Request** — branché directement après le trigger :
```
POST https://graph.facebook.com/v20.0/{{ $env.WHATSAPP_PHONE_NUMBER_ID }}/messages

Headers:
  Authorization: Bearer {{ $env.WHATSAPP_ACCESS_TOKEN }}
  Content-Type: application/json

Body (JSON) :
{
  "messaging_product": "whatsapp",
  "to": "{{ $env.OWNER_WHATSAPP_NUMBER }}",
  "type": "template",
  "template": {
    "name": "escalation_alert",
    "language": { "code": "fr" },
    "components": [
      {
        "type": "body",
        "parameters": [
          { "type": "text", "text": "{{ $json.phone_number }}" },
          { "type": "text", "text": "{{ $json.reason }}" },
          { "type": "text", "text": "{{ $json.conversation_id }}" }
        ]
      }
    ]
  }
}
```
⚠️ **Astuce fiabilité** : quand le node HTTP Request est branché **directement** après le trigger (pas de node intermédiaire), préfère `{{ $json.champ }}` à `{{ $('Nom du node').first().json.champ }}` — plus court, et évite tout risque lié à un nom de node mal orthographié ou contenant des guillemets typographiques copiés-collés.

**Node Code final (retour agent)** :
```javascript
return {
  json: {
    result: "Un membre de notre équipe va prendre le relais très rapidement. Merci de patienter un instant."
  }
};
```

**Tool Description** :
```
Alerte un humain immédiatement. Utilise ce tool si le client est mécontent, confus après plusieurs tentatives, demande explicitement de parler à un humain, ou pour toute situation que tu ne peux pas gérer avec les autres tools.
```

---

**Astuce générale de test** : pour tester un sous-workflow indépendamment, ajoute temporairement un node **Edit Fields (Set)** juste après le trigger avec des valeurs de test (types corrects : String pour les UUID/numéros de téléphone, pas Number), exécute la chaîne, puis retire ce node avant la mise en prod.

**⚠️ Rappel structurel important** : chaque tool doit être un node **"Call n8n Workflow Tool" séparé** sous le AI Agent (un par sous-workflow), jamais un seul node listant plusieurs workflows — sinon Claude ne peut pas les distinguer clairement.

### 3.6 Envoyer la réponse via Meta API

Node **HTTP Request**, branché après le node **AI Agent**.

⚠️ **Piège rencontré et corrigé** : écrire le Body comme un texte JSON statique avec `{{ }}` insérés dedans casse dès que la réponse de l'IA contient un retour à la ligne, un emoji, ou une apostrophe courbe (ce que les modèles produisent naturellement). **Solution retenue** : construire le Body via `JSON.stringify()` sur un objet JS, qui échappe automatiquement tous les caractères spéciaux.

```
POST https://graph.facebook.com/v20.0/{{ $env.WHATSAPP_PHONE_NUMBER_ID }}/messages

Headers:
  Authorization: Bearer {{ $env.WHATSAPP_ACCESS_TOKEN }}
  Content-Type: application/json

Body (JSON, "Send Body" activé, "Specify Body" = "Using JSON") :
{{ JSON.stringify({
  messaging_product: "whatsapp",
  to: $('Edit Fields').item.json.from,
  type: "text",
  text: { body: $json.output }
}) }}
```

⚠️ Vérifie le nom exact du champ de sortie de l'AI Agent (généralement `output`) en cliquant sur le node après une exécution test.

### 3.7 Sauvegarder le tour de conversation

Node **Postgres**, branché après le HTTP Request :

```sql
INSERT INTO messages (conversation_id, role, content, whatsapp_msg_id)
VALUES
  ($1, 'user', $2, $3),
  ($1, 'assistant', $4, NULL);
```

**Query Parameters** :
```
{{ [ $('Postgres #1').item.json.id, $('Edit Fields').item.json.message_text, $('Edit Fields').item.json.whatsapp_msg_id, $('AI Agent').item.json.output ] }}
```
*(adapte les noms de nodes entre parenthèses à ceux réellement utilisés — préfère `$json.champ` sans référence de node quand le node est branché directement en amont, plus robuste, voir le souci de "pairing" rencontré sur `create_order`)*

### Fallback multi-provider (résilience)

Pour éviter qu'un souci ponctuel chez un provider IA (crédit épuisé, quota, panne) ne bloque tout le bot, le node **AI Agent** supporte un modèle de secours :
1. Node AI Agent → **Options** → active **"Enable Fallback Model"**.
2. Un second connecteur "Chat Model" apparaît — branche-y un second provider (ex: **Groq Chat Model**, avec son propre credential).
3. **Modèle recommandé sur Groq pour ce cas d'usage** : `openai/gpt-oss-120b` (meilleur compromis raisonnement/tool-calling actuellement disponible chez Groq ; `openai/gpt-oss-20b` en alternative plus rapide/moins chère si la qualité du fallback importe moins que la latence).
4. Si Claude échoue, n8n bascule automatiquement sur Groq sans que le client ne remarque d'interruption.

⚠️ Les modèles Groq sont open-weight, avec un raisonnement/suivi d'instructions en retrait par rapport à Claude — acceptable en fallback ponctuel, pas recommandé comme modèle principal.

---

## 4. Tester de bout en bout

### Méthode recommandée pour les tests répétés : `curl` plutôt que de vrais messages WhatsApp

⚠️ **Piège rencontré** : envoyer beaucoup de messages de test rapprochés depuis un vrai téléphone WhatsApp vers le même contact peut faire flaguer ce numéro personnel comme spam/automatisé par WhatsApp (restriction temporaire ~6h, compte toujours utilisable en réception). **Réserve les vrais messages WhatsApp aux tests finaux de bout en bout** ; utilise `curl` pour toutes les itérations de debug.

```bash
BODY='{"entry":[{"changes":[{"value":{"messages":[{"from":"TON_NUMERO","id":"wamid.TEST'$(date +%s)'","text":{"body":"Bonjour, avez-vous ce produit ?"}}]}}]}]}'
SECRET="ta_valeur_WHATSAPP_APP_SECRET"
SIGNATURE=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')

curl -X POST https://n8n.golden-market.co/webhook/whatsapp \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=$SIGNATURE" \
  -d "$BODY"
```
*(URL de production `/webhook/whatsapp` une fois le workflow publié ; `/webhook-test/whatsapp` en mode "Listen for test event")*

### Étapes

1. **Publie le workflow** — dans cette version de n8n, il n'y a pas de toggle "Active" classique : utilise le bouton **"Publish"** en haut à droite de l'éditeur. Un triangle rouge sur un node bloque la publication — clique dessus pour voir l'erreur exacte à corriger avant de pouvoir publier.
2. Envoie un message (via `curl` ou un vrai message WhatsApp).
3. Vérifie dans l'onglet **"Executions"** (à côté de "Editor") que le workflow s'est déclenché sans erreur.
4. Vérifie en base que la conversation/les messages sont bien enregistrés :
   ```bash
   docker compose exec postgres psql -U <user> -d golden_market -c "SELECT * FROM messages ORDER BY created_at DESC LIMIT 5;"
   ```
5. Teste un scénario de commande complet, puis un scénario d'escalade.

### En mode développement Meta (avant App Review)

Tant que l'app Meta n'a pas été publiée/passée en review, Cloud API n'autorise l'envoi qu'aux numéros explicitement ajoutés comme testeurs : **App Dashboard → WhatsApp → API Setup → champ "To" → "Manage phone number list"**, ajoute le(s) numéro(s) destinataire(s) (jusqu'à 5), vérifie-les via le code reçu. Pas besoin de publier l'app pour tester avec ces numéros.

### Pièges rencontrés à surveiller si l'envoi de messages échoue

- **`Object with ID ... does not exist, cannot be loaded due to missing permissions`** → le WABA (`WHATSAPP_BUSINESS_ACCOUNT_ID`) n'est probablement pas assigné à l'utilisateur système utilisé pour générer le token, en plus de l'app elle-même. Dans **Paramètres de l'entreprise → Utilisateurs système → Ajouter des actifs**, assigne explicitement le **compte WhatsApp Business (WABA)**, pas seulement l'app — puis régénère le token après coup.
- Test de vérification rapide (isole le problème hors n8n) :
  ```bash
  docker compose exec n8n sh -c 'curl -s "https://graph.facebook.com/v20.0/${WHATSAPP_PHONE_NUMBER_ID}?access_token=${WHATSAPP_ACCESS_TOKEN}"'
  ```



---

## 5. Checklist sécurité avant mise en prod

- [ ] Signature Meta vérifiée sur chaque requête entrante (section 3.2)
- [ ] Token WhatsApp stocké en credential n8n, pas en clair dans un node
- [ ] ⚠️ `N8N_BLOCK_ENV_ACCESS_IN_NODE: false` activé (compromis assumé, voir section 3.2) — ne jamais importer de workflow/node Code tiers sans relecture complète
- [ ] `.env` toujours hors Git (`.gitignore` en place)
- [ ] Basic Auth actif sur l'éditeur n8n (déjà fait)
- [ ] Sauvegardes régulières du volume Postgres (`pg_dump` planifié)
- [ ] Limite claire dans le system prompt + les tools sur ce que l'agent peut promettre (prix, stock, délais)
- [ ] Template `escalation_alert` approuvé par Meta
- [ ] Tout outil d'admin ajouté plus tard (accès direct à la base) : mot de passe fort + accès restreint (IP whitelist / VPN)

---

## Prochaine étape immédiate

Une fois ce guide en main : commence par la **section 1** (config Meta) puisque c'est un prérequis bloquant pour tout le reste — la vérification d'identité business peut prendre 1 à 3 jours, autant la lancer tout de suite pendant qu'on construit le workflow en parallèle.
