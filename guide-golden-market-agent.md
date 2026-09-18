# Golden Market — Agent IA WhatsApp — Guide de construction

> **Réécrit le 2026-09-15.** La version précédente décrivait l'architecture initiale
> (tools SQL directs sur `public.products`/`orders` dans la base `golden_market`), remplacée
> en production début septembre 2026 par une intégration directe au Store/Admin API Medusa.
> Ce document reflète l'état réel du workflow n8n de prod à cette date (vérifié par export
> direct : `n8n export:workflow --all` sur le conteneur `golden_market_n8n`, VPS
> `admin@144.91.110.105`). Si un futur changement de workflow le rend à nouveau périmé,
> se fier à `medusa-golden-market/HANDOFF.md` (journal de session à jour en continu) plutôt
> qu'à ce guide seul, et le remettre à jour dans la foulée.

## État actuel ✅

- [x] Stack déployée : Postgres (`golden_market`) + n8n, VPS, Apache en reverse proxy (SSL certbot)
- [x] Webhook GET (vérification Meta) + POST (réception messages, signature HMAC sur le corps brut)
- [x] Historique de conversation (Postgres `conversations`/`messages`) branché à l'AI Agent
- [x] AI Agent configuré (system prompt + modèle Anthropic + fallback Groq)
- [x] **6 tools actifs**, tous testés en production : `find_products`, `browse_catalog`,
      `place_order`, `get_payment_instructions`, `mark_payment_reported`, `escalate_to_human`
- [x] `find_products`/`place_order` parlent directement au **Store API Medusa réel**
      (catalogue, paniers, commandes) — plus de duplication de catalogue en base n8n
- [x] Recherche produit tolérante aux fautes de frappe (`/store/products-fuzzy-search`, pg_trgm)
      **+ recherche sémantique de repli** (`browse_catalog`, § 2.6) quand la recherche floue échoue —
      `browse_catalog` ne liste que les produits **disponibles** (filtre ajouté le 2026-09-15,
      inutile de faire considérer au modèle un produit en rupture qu'il ne peut pas vendre)
- [x] Garde-fou déterministe d'escalade : après 4 échecs `find_products` consécutifs dans la même
      conversation, le système notifie l'équipe et marque la conversation `escalated` sans dépendre
      du jugement du LLM (§ 2.6, colonne `conversations.consecutive_search_misses`)
- [x] **Photo, vidéo et message vocal envoyés par le client tous compris automatiquement** avant que
      l'IA ne lise le message (§ 2.3bis) : photo décrite (OpenAI `gpt-4o-mini`, vision), vidéo décrite
      *son compris* (Google Gemini `gemini-3.6-flash`, comprend nativement l'image et l'audio de la
      vidéo), message vocal transcrit (OpenAI Whisper `whisper-1`) — crédentials déjà existantes dans
      ce n8n, aucune nouvelle à créer. **Déployé, dégradation propre vérifiée en conditions réelles sur
      les 3 types (media id fictif → repli sur le texte de repli existant, jamais de crash), mais
      jamais testé avec un vrai média WhatsApp** (un media id ne peut pas être simulé par webhook
      signé, voir § 2.3bis)
- [x] Paiement : Cash on Delivery (Ouagadougou uniquement), Orange Money, Moov Money — instructions
      générées dynamiquement selon le `provider_id` de la commande Medusa
- [x] Confirmation de commande WhatsApp automatique (workflow séparé, déclenché par un webhook
      sortant du backend Medusa à la création de commande)
- [x] Escalade humaine (template WhatsApp `escalation_alert`) — **template créé et approuvé le
      2026-09-15** (voir Anomalie n°6 : il n'existait pas du tout avant cette date, malgré ce que
      disait ce guide)
- [x] Visualiseur de conversations WhatsApp en lecture seule dans l'admin Medusa
      (`medusa-golden-market`, `/app/whatsapp-conversations`)
- [x] Synchro catalogue Medusa → Meta Commerce Catalog opérationnelle (pubs dynamiques
      Facebook/Instagram, catalogue natif WhatsApp) — voir `medusa-golden-market/HANDOFF.md`

## ⚠️ Anomalies connues (état au 2026-09-15, n°2/3/5/6 corrigées, n°1 délibérément en attente)

1. **Le modèle IA principal de l'AI Agent est Groq (`openai/gpt-oss-120b`), pas Claude — délibérément,
   pour le moment.** Dans le node `AI Agent` du workflow `Golden Market Sales Automation Workflow`
   (`i6KGA9BvK9unjxxj`), la connexion `ai_languageModel` a `Groq Chat Model` en **index 0**
   (principal) et `Anthropic Chat Model` (`claude-sonnet-5`) en **index 1** (fallback) — c'est
   l'inverse de l'intention d'origine (voir § Fallback multi-provider plus bas). Groq est un
   modèle open-weight nettement moins fiable en suivi d'instructions et en reformulation d'appel
   de tool (incident documenté ci-dessous, § Historique des correctifs, 2026-09-07) et probable
   cause principale des retours négatifs sur la qualité de conversation. **Testé en sens inverse le
   2026-09-15 (Claude en principal) puis annulé le jour même : le propriétaire n'avait pas de
   crédit Anthropic disponible, ce qui aurait fait échouer le premier appel à chaque tour.**
   Ne réinverser qu'après avoir vérifié que du crédit Anthropic est disponible — voir
   `medusa-golden-market/HANDOFF.md`, entrée du 2026-09-15, pour la procédure (export/import CLI
   `n8n export:workflow`/`import:workflow` + `update:workflow --active=true` + redémarrage du
   conteneur `golden_market_n8n`, nécessaire pour que le changement s'applique réellement au
   process en cours).
2. ~~Aucune extraction du champ `referral` de Meta.~~ **Corrigé le 2026-09-15.**
   `message_text` (node `Edit Fields`) préfixe maintenant le message avec le contexte
   pub/catalogue (`headline`, `body`, `source_url`) quand `messages[0].referral` est présent —
   voir § 2.3. Vérifié en conditions réelles (webhook signé, contexte bien exploité par l'IA).
3. ~~Recherche produit tolérante aux fautes, pas aux synonymes/écarts lexicaux.~~ **Atténué le
   2026-09-15** par le tool `browse_catalog` (§ 2.6) : quand `find_products` échoue deux fois,
   l'IA parcourt tout le catalogue et fait elle-même le rapprochement sémantique/phonétique. Ça
   reste un pis-aller (le catalogue doit rester petit pour tenir dans un prompt), pas une vraie
   recherche sémantique par embeddings — suffisant pour l'échelle actuelle (~40 produits).
4. ~~L'agent ne traite aucun lien externe (Facebook/Instagram/etc.) partagé par le client.~~
   **Partiellement atténué le 2026-09-15.** Reste un vrai problème sans solution générale pour la
   résolution du lien lui-même : Meta bloque le scraping non authentifié de ses propres contenus,
   donc résoudre un lien organique (pas une pub) n'est pas réalisable de façon fiable. Seul le cas
   d'une pub Click-to-WhatsApp est couvert (via `referral`, anomalie n°2). En revanche, une photo,
   vidéo ou message vocal envoyé directement est maintenant compris (§ 2.3bis) — et le prompt
   système guide maintenant explicitement le client vers ça quand il partage un lien (voir § 2.5,
   règle ajoutée le 2026-09-15) plutôt que de simplement dire "je ne peux pas ouvrir ce lien".
5. ~~Pas de garde-fou déterministe sur l'escalade humaine.~~ **Corrigé le 2026-09-15** : voir
   `conversations.consecutive_search_misses` et le tool `find_products` (§ 2.6). Testé en
   conditions réelles (4 échecs consécutifs simulés) : aucun crash, comportement de repli correct
   tant que le template `escalation_alert` n'était pas encore approuvé (anomalie n°6).
6. **Découverte le 2026-09-15 : le template WhatsApp `escalation_alert` n'existait pas du tout sur
   le compte Meta** (`GET /{waba_id}/message_templates` ne listait que
   `order_confirmation_from_whatsapp`, `order_confirmation_from_website`, `hello_world`), alors que
   ce guide (dans sa version précédente) et le code des tools `escalate_to_human`/
   `mark_payment_reported` le référencaient comme existant depuis le tout début du projet.
   **Conséquence réelle en prod, potentiellement depuis le lancement** : chaque fois qu'un client
   demandait un humain ou signalait un paiement, l'appel à l'API Meta échouait, et comme aucun des
   deux tools n'avait de gestion d'erreur, **le client ne recevait alors AUCUNE réponse** (le node
   `AI Agent` plante entièrement si un de ses tools lève une exception non interceptée — vérifié en
   conditions réelles le 2026-09-15, voir § 2.6 "Piège critique"). Template recréé via l'API Meta
   (`POST /{waba_id}/message_templates`, français) et **approuvé** (reclassé `MARKETING` par Meta,
   demandé en `UTILITY` — sans incidence côté envoi) ; `escalate_to_human` et
   `mark_payment_reported` rendus défensifs (`onError` au bon endroit, voir Piège critique) pour
   qu'une panne similaire ne puisse plus jamais couper la réponse au client, quelle qu'en soit la
   cause future. **Vérifié de bout en bout avec un vrai `wamid.` renvoyé par l'API Meta** (test
   live signé, `escalate_to_human`) — la notification atteint réellement le propriétaire, pas
   seulement "le client reçoit une réponse".

---

## 1. Configuration WhatsApp Cloud API (Meta)

Section inchangée depuis la mise en place initiale — voir la configuration réelle dans
**Meta Business Suite** (compte du propriétaire) plutôt que de la reconstruire ici : app
`Golden Market Bot`, Phone Number ID + WABA + token système permanent (scopes
`whatsapp_business_messaging`, `whatsapp_business_management`, `catalog_management`), webhook
`https://n8n.golden-market.co/webhook/whatsapp` avec champ `messages` souscrit.

Le jeton WhatsApp actuel (`WHATSAPP_ACCESS_TOKEN`, `.env` du VPS) a été régénéré le 2026-09-13
lors de la mise en place de la synchro catalogue Meta — il sert désormais **aussi** de
`META_CATALOG_ACCESS_TOKEN` côté backend Medusa (scopes `whatsapp_business_management` +
`catalog_management` sur le même system user). Toute régénération de ce jeton touche donc les
deux systèmes ; coordonner les deux mises à jour.

Template WhatsApp d'escalade humaine : `escalation_alert` (catégorie Utility, français), utilisé
par `escalate_to_human` et `mark_payment_reported`. **Recréé et approuvé le 2026-09-15** — n'a
existé sur aucun compte Meta avant cette date malgré les versions précédentes de ce guide (voir
Anomalie n°6). Corps actuel : `Golden Market - Intervention requise. Client : {{1}}. Message :
{{2}}. Conversation : {{3}}, merci de verifier des que possible.` — **Meta rejette tout template
dont une variable se trouve en tout début ou en toute fin de corps** (erreur API
`error_subcode: 2388299`) ; un simple point après `{{3}}` ne suffit pas, il faut un texte de
clôture substantiel (quelques mots), confirmé empiriquement le 2026-09-15 après plusieurs essais.
Template de confirmation de commande distinct :
`order_confirmation_from_whatsapp` (sans "Bonjour X", pour les commandes passées via l'agent) vs
`order_confirmation_from_website` (commandes storefront) — le choix se fait côté backend Medusa
selon `order.metadata.source`.

---

## 2. Vue d'ensemble du workflow principal

Workflow n8n : **`Golden Market Sales Automation Workflow`** (id `i6KGA9BvK9unjxxj`).

```
[Webhook GET whatsapp]  → [If verify_token] → [Respond 200 / 403]     (vérification Meta, ponctuel)

[Webhook POST whatsapp, rawBody: true]
        │
        ▼
[Is Real Message] ──(accusé lecture/livraison, pas de messages[])──► [Respond 200 vide]
        │ (vrai message)
        ▼
[Vérifier signature HMAC sur le corps BRUT]
        │
        ▼
[Edit Fields : from / message_text / whatsapp_msg_id]
        │
        ▼
[Postgres : trouver ou créer conversation (SQL_query_1)]
        │
        ▼
[Postgres : récupérer historique messages, ORDER BY seq (SQL_query_2)]
        │
        ▼
[AI Agent (Groq principal / Claude fallback — voir Anomalie n°1)] ◄────────┐
        │                                                                   │
        ├─ find_products ────────────────────────────────────────────────┤
        ├─ place_order ───────────────────────────────────────────────────┤
        ├─ get_payment_instructions ─────────────────────────────────────┤
        ├─ mark_payment_reported ────────────────────────────────────────┤
        └─ escalate_to_human ────────────────────────────────────────────┘
        │
        ▼
[HTTP Request : envoyer réponse via Meta API, preview_url: true]
        │
        ▼
[Postgres : sauvegarder le tour de conversation]
```

Workflow séparé (webhook sortant) : **`Golden Market Order Confirmation from website —
WhatsApp client`** (id `pse4PNU4MF5OMGHB`) — reçoit un POST du backend Medusa à chaque commande
placée (n'importe quelle source : storefront ou WhatsApp), vérifie un secret partagé
(`N8N_ORDER_CONFIRMATION_WEBHOOK_SECRET`), envoie le template WhatsApp de confirmation
correspondant. Généralisé pour accepter `template_name` + `params[]` plutôt que d'être câblé en
dur sur un seul template.

### 2.1 Node Webhook — réception des messages

Deux nodes **Webhook** indépendants sur le même path `whatsapp`, non reliés entre eux :
- **GET** — vérification Meta (`hub.verify_token`/`hub.challenge`), ponctuel.
- **POST** (`rawBody: true`) — messages réels, en continu. `rawBody: true` expose le corps HTTP
  brut en base64 sur `binary.data.data`, **indispensable** pour que la vérification HMAC (§ 2.2)
  corresponde exactement à ce que Meta a signé — `JSON.stringify(body)` sur le JSON déjà parsé ne
  reproduit pas les octets d'origine dès qu'un accent ou un emoji est présent (bug réel corrigé le
  2026-09-07, voir Historique des correctifs).

Meta envoie aussi des accusés de lecture/livraison en POST sans `messages[]` — le node
**`Is Real Message`** (juste après la vérification de signature) ne laisse passer que les
payloads avec un vrai `messages[]`, pour éviter un crash sur `to: null` en aval.

### 2.2 Vérifier la signature (sécurité)

Node **Code**, calcule le HMAC-SHA256 sur le corps brut (`Buffer.from(binary.data.data, 'base64')`,
pas `JSON.stringify`) avec `WHATSAPP_APP_SECRET`, compare à l'en-tête `x-hub-signature-256`, lève
une erreur si ça ne correspond pas.

**Config n8n requise** (`docker-compose.yml`, service `n8n`) :
```yaml
NODE_FUNCTION_ALLOW_BUILTIN: crypto        # autorise l'import du module 'crypto'
N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"      # autorise $env dans les nodes Code
```

⚠️ **Compromis de sécurité assumé** : `N8N_BLOCK_ENV_ACCESS_IN_NODE: false` donne accès à *toutes*
les variables d'environnement (y compris `POSTGRES_PASSWORD`, `MEDUSA_ADMIN_KEY_*`) depuis
n'importe quel node Code, pas seulement `WHATSAPP_APP_SECRET`. Règle : ne jamais copier un node
Code d'un workflow tiers sans relecture intégrale.

### 2.3 Extraire les infos du message

Node **Edit Fields (Set)** — transforme le JSON imbriqué de Meta en champs simples :

| Name | Value |
|---|---|
| `from` | `{{ $json.body.entry[0].changes[0].value.messages[0].from }}` |
| `message_text` | voir ci-dessous |
| `whatsapp_msg_id` | `{{ $json.body.entry[0].changes[0].value.messages[0].id }}` |

`message_text` gère aujourd'hui tous les types de message WhatsApp (bug réel corrigé le
2026-09-15, voir Historique) via une chaîne de fallback :
```js
messages[0].text?.body
  ?? messages[0].interactive?.button_reply?.title
  ?? messages[0].interactive?.list_reply?.title
  ?? (messages[0].image ? "[Image reçue]" : undefined)
  ?? (messages[0].audio ? "[Message vocal reçu]" : undefined)
  ?? (messages[0].sticker ? "[Autocollant reçu]" : undefined)
  ?? (messages[0].video ? "[Vidéo reçue]" : undefined)
  ?? (messages[0].document ? "[Document reçu]" : undefined)
  ?? (messages[0].location ? "[Position reçue]" : undefined)
  ?? "[Message reçu, type non pris en charge]"
```
Avant ce correctif, un message non-texte laissait `message_text = undefined` → `NULL` en base →
violation de contrainte `NOT NULL` sur `messages.content` → crash silencieux, le client ne
recevait **aucune** réponse. **Depuis le 2026-09-15, le cas `image` est enrichi par la branche
vision (§ 2.3bis)** avant d'atteindre ce fallback ; les autres types (audio, sticker, vidéo,
document, position) gardent le texte de repli simple, l'IA n'a aucun moyen de comprendre leur
contenu réel (voir Anomalie n°4 en tête du guide, toujours vraie pour les liens externes).

**Depuis le 2026-09-15**, `message_text` préfixe aussi le contenu avec le contexte publicitaire
Meta quand disponible (expression étendue, même node) :
```js
(referral present ? "[Contexte pub/catalogue Meta : " + headline + " - " + body + " (" + source_url + ")]\n" : "")
  + (chaîne de repli ci-dessus, inchangée)
```
Absent de `referral` → comportement strictement identique à avant. Voir Anomalie n°2 (corrigée)
en tête du guide.

### 2.3bis Photo, message vocal, vidéo envoyés par le client (compréhension multimodale)

Trois branches indépendantes insérées **après** `Edit Fields`, **avant** `SQL_query_1`, chaînées en
cascade de nodes **If** (`Is Image Message` → `Is Audio Message` → `Is Video Message`, chacun
référencé via `$('Webhook1')`, pas `$json`, pour ne pas dépendre de si `Edit Fields` préserve ou non
les champs bruts) :

```
Edit Fields → Is Image Message
                 true  → [branche image, voir plus bas] → SQL_query_1
                 false → Is Audio Message
                            true  → [branche audio, voir plus bas] → SQL_query_1
                            false → Is Video Message
                                       true  → [branche vidéo, voir plus bas] → SQL_query_1
                                       false → SQL_query_1 (connexion directe)
```

Toutes les branches ciblent le même node final (`SQL_query_1`) — pattern natif n8n valide (une seule
branche s'exécute réellement par item), pas besoin de node `Merge`.

**Schéma commun aux trois branches** : `Get Media URL` (`GET
https://graph.facebook.com/v20.0/{{ media.id }}`, Bearer `WHATSAPP_ACCESS_TOKEN`) résout l'id média
WhatsApp en URL de téléchargement temporaire → `Download Media` (`GET {{ $json.url }}`, même Bearer,
`options.response.response.responseFormat: "file"`) télécharge les octets réels (n8n les stocke en
binaire, base64 déjà accessible via `$binary.data.data`) → un node "Describe" spécifique au type de
média (voir ci-dessous) → un node "Override Message Text" (Code) qui remplace `message_text` (celui
calculé par `Edit Fields`) par une description/transcription préfixée. L'IA reçoit ensuite ce texte
**comme si c'était ce que le client avait écrit** — aucun changement nécessaire côté prompt système
ou tools, `find_products`/`browse_catalog` fonctionnent normalement dessus.

- **Branche image** — `Describe Image (Vision)` : `POST
  https://api.openai.com/v1/chat/completions`, `authentication: "predefinedCredentialType"` +
  `nodeCredentialType: "openAiApi"` (credential **"OpenAI account"** déjà existante dans ce n8n,
  utilisée par ailleurs par `AI News Curator`), modèle `gpt-4o-mini`, image en
  `data:{mime_type};base64,{données}`. Préfixe : `"[Photo envoyée par le client — description
  automatique : {description}]"`.
- **Branche audio** — `Transcribe Audio (Whisper)` : `POST
  https://api.openai.com/v1/audio/transcriptions`, même credential OpenAI, `contentType:
  "multipart-form-data"`, `model: "whisper-1"`, fichier envoyé via un paramètre de corps
  `parameterType: "formBinaryData"` référençant la propriété binaire `data`. Réponse `{text: "..."}`.
  Préfixe : `"[Message vocal envoyé par le client — transcription automatique : {transcript}]"`.
- **Branche vidéo** — `Describe Video (Vision)` : `POST
  https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent`,
  `authentication: "predefinedCredentialType"` + `nodeCredentialType: "googlePalmApi"` (credential
  **"Google Gemini(PaLM) Api account"** déjà existante dans ce n8n, jusque-là utilisée seulement par
  des workflows inactifs — **validité reconfirmée en isolation le 2026-09-15** avant de la brancher
  en prod, voir note modèle ci-dessous). Corps : `{contents:[{parts:[{inline_data:{mime_type,
  data}}, {text: "..."}]}]}` — Gemini traite nativement l'image **et la bande son** de la vidéo en un
  seul appel (pas besoin d'extraire une frame ou l'audio séparément, n8n ne peut pas faire tourner
  ffmpeg de toute façon). Réponse : `candidates[0].content.parts[0].text`. Limite Gemini : 20 Mo max
  par requête (payload base64 inclus) — une vidéo WhatsApp plus lourde fait simplement échouer cette
  étape, repli automatique sur `"[Vidéo reçue]"` (voir Défensif ci-dessous), pas un problème bloquant
  mais une vidéo longue/HD ne sera pas comprise. Préfixe : `"[Vidéo envoyée par le client —
  description automatique : {description}]"`.

⚠️ **Nom de modèle Gemini à surveiller** : `gemini-2.5-flash` (choix initial) rejette déjà les
nouveaux appels au 2026-09-15 (`404 - "This model ... is no longer available to new users"`, message
d'erreur de Google recommandant explicitement `gemini-3.6-flash`, confirmé en le testant en
isolation avant déploiement). Les modèles Gemini se déprécient vite — si `Describe Video (Vision)`
se met à échouer systématiquement, vérifier d'abord si le nom de modèle est toujours valide
(`https://ai.google.dev/gemini-api/docs/models`) avant de chercher ailleurs.

**Défensif à chaque étape, dans les trois branches** (`Get Media URL`, `Download Media`, `Describe
*` ont tous `onError: "continueErrorOutput"` **au niveau racine du node**, pas dans `parameters` —
voir "Piège critique" en § 2.6) : toute erreur (media id invalide/expiré, API en panne, timeout,
vidéo trop lourde) route vers **Vision Error Fallback** (node partagé par les trois branches, malgré
son nom hérité de l'implémentation image initiale), qui renvoie simplement
`$('Edit Fields').item.json` intact → le pipeline retombe sur le texte de repli existant
(`"[Image reçue]"` / `"[Message vocal reçu]"` / `"[Vidéo reçue]"`), jamais de crash.

⚠️ **Pas testable de bout en bout par webhook signé** : un id média WhatsApp est une référence
serveur à un vrai fichier uploadé, impossible à simuler avec `curl`. Vérifié pour les trois branches
avec un id fictif → échec dès `Get Media URL`, repli propre confirmé, aucun crash (tests réels du
2026-09-15). Credential Gemini validée séparément en isolation (requête texte simple hors pipeline
client, réponse "OK" reçue) avant d'être branchée en prod. **Jamais vérifié avec un vrai média
WhatsApp** (photo, vidéo ou message vocal réel envoyé par un vrai client) — à faire au premier cas
réel, ou en demandant au propriétaire un test depuis son téléphone pour chacun des trois types.

### 2.4 Postgres — conversation + historique

**SQL_query_1** (upsert conversation) :
```sql
INSERT INTO conversations (phone_number, last_message_at)
VALUES ($1, now())
ON CONFLICT (phone_number)
DO UPDATE SET last_message_at = now()
RETURNING id;
```
⚠️ Le paramètre **doit** être une expression (`={{ $json.from }}`, avec le `=` initial) — un bug
réel (2026-09-05) avait ce champ en texte brut `"from"`, fusionnant toutes les conversations de
tous les numéros en une seule ligne. Vérifier ce `=` en premier si des conversations semblent se
mélanger.

**SQL_query_2** (historique, trié par ordre d'insertion réel) :
```sql
SELECT role, content
FROM messages
WHERE conversation_id = $1
ORDER BY seq ASC
LIMIT 20;
```
`ORDER BY seq` (colonne `BIGSERIAL`), pas `created_at` : la ligne `user` et la ligne `assistant`
d'un même tour sont insérées dans la **même transaction** (`now()` identique), donc `created_at`
seul ne les départage pas de façon fiable (bug réel corrigé le 2026-09-05, avait fait ignorer un
message client par l'agent).

### 2.5 AI Agent node

**Chat Model principal** : `Groq Chat Model` (`openai/gpt-oss-120b`) — voir **Anomalie n°1**,
ce devrait être Claude Sonnet 5 en principal.
**Fallback** : `Anthropic Chat Model` (`claude-sonnet-5`).

**System prompt actuel** (`options.systemMessage` du node `AI Agent`) :

```
Tu es l'assistant commercial de Golden Market, une boutique en ligne au Burkina Faso.
Ton rôle : accueillir les prospects sur WhatsApp, répondre à leurs questions produits,
et les accompagner jusqu'à la commande.

Règles strictes :
- N'invente JAMAIS un prix, un stock, ou une promesse de livraison — utilise toujours find_products, qui interroge le vrai catalogue.
- Si find_products ne retourne aucun résultat, ne conclus PAS immédiatement que le produit n'existe pas : réessaie une fois avec un terme de recherche simplifié (garde uniquement le nom principal de l'objet, essaie le singulier ET le pluriel, retire les adjectifs). Ne dis au client qu'aucun produit n'a été trouvé qu'après ce second essai infructueux.
- N'accorde jamais de remise non prévue.
- Le paiement à la réception (cash) n'est proposé QUE si le client livre à Ouagadougou. Pour toute autre ville, propose uniquement Orange Money ou Moov Money.
- Paiement à la réception : c'est TOUJOURS le client qui remet l'argent en espèces au livreur, jamais l'inverse. Ne dis jamais que le livreur remet ou rend de l'argent au client. Formule toujours ainsi : « vous réglerez / vous remettrez X FCFA en espèces au livreur ».
- WhatsApp n'affiche PAS les tableaux markdown (barres |, tirets ---) : ne les utilise JAMAIS.
- Quand tu présentes des produits trouvés par find_products : pour chaque produit, une ligne avec le nom et le prix, suivie du lien produit fourni par le tool (partage-le tel quel, c'est une URL cliquable), avec une courte phrase descriptive si utile. Jamais de tableau, une entrée par produit.
- L'id variante interne (variant_xxx) fourni par find_products sert UNIQUEMENT à appeler place_order plus tard — ne l'affiche JAMAIS au client, même à côté du lien produit.
- Le niveau de stock (quantité exacte, nombre d'unités) est une information interne strictement confidentielle — ne communique JAMAIS de chiffre de stock au client, même s'il le demande explicitement. Tu peux seulement dire si un produit est disponible ou en rupture de stock.
- Si le client répond par un message qui n'apporte AUCUNE information nouvelle à ce que tu viens de demander (ex : « Ok », « D'accord », « 👍 »), ne reformule PAS et ne redonne PAS la liste complète que tu viens d'envoyer — réponds juste très brievement (ex : « Bien ! Je reste en attente de ces informations. ») et attends sa réponse. Ne redemande la liste complète que si le client semble avoir oublié ce qui lui a été demandé ou le redemande explicitement.
- Le téléphone du client (déjà connu, c'est son numéro WhatsApp) est l'identifiant réel de la commande — ne redemande jamais d'email, ce n'est jamais nécessaire.
- Avant d'appeler place_order, confirme explicitement avec le client : les articles, le prix total, l'adresse de livraison complète, et le moyen de paiement choisi.
- Si le client est mécontent, confus après 2 tentatives, ou demande explicitement un humain → utilise escalate_to_human.
- Pour finaliser une commande : utilise place_order, puis get_payment_instructions.
- Si le client signale avoir payé (référence de transaction ou capture d'écran), utilise mark_payment_reported.
- Ton : chaleureux, professionnel, réponses courtes adaptées à WhatsApp (pas de pavés).
- Langue : français, sauf si le client écrit dans une autre langue.
```

Chaque règle correspond à un incident réel corrigé en production (voir Historique des
correctifs) — ne pas en retirer une sans comprendre quel bug elle empêche de reproduire.

### 2.6 Tools — Call n8n Workflow Tool

Chaque tool est un sous-workflow séparé (trigger *When Executed by Another Workflow*), appelé
par son propre node *Call n8n Workflow Tool* sous le AI Agent — jamais un seul node listant
plusieurs workflows (Claude ne pourrait pas les distinguer). Le champ **Description** de ce node
est lu par le modèle pour décider quand appeler le tool — c'est du prompt, pas un commentaire.

⚠️ **Piège critique découvert le 2026-09-15, à connaître avant de toucher n'importe quel tool** :
`onError: "continueErrorOutput"` doit être une propriété **au niveau racine du node** (sœur de
`id`/`name`/`type`/`position`), **pas** à l'intérieur de `parameters` — placé au mauvais endroit,
n8n l'ignore silencieusement (aucune erreur de validation à l'import) et le node se comporte comme
sans gestion d'erreur du tout. Pour un tool appelé par l'AI Agent (sous-workflow), une exception non
interceptée y est en général absorbée par le wrapper d'exécution de tool de n8n (le modèle reçoit
juste un message d'erreur) — mais **un node du workflow principal lui-même** (ex. la branche vision,
§ 2.3bis) qui lève une exception non interceptée **fait planter tout le node `AI Agent`, et le
client ne reçoit alors aucune réponse**. Vérifié dans les deux sens en conditions réelles le
2026-09-15 (`onError` mal placé → crash confirmé sur un node du workflow principal ; correctif →
dégradation propre confirmée). Référence de bon exemple déjà présente dans le workflow
`Golden Market Order Confirmation from website` (node `Send WhatsApp Template`).

#### Tool `find_products` (id `s6Ef6xBRxBeF6dgW`)

**Input** : `product_name` (String, "Let the model define"), `conversation_id` (fixe,
`{{ $('SQL_query_1').item.json.id }}`), `phone_number` (fixe, `{{ $('Edit Fields').item.json.from
}}`) — ces deux derniers ajoutés le 2026-09-15 pour le garde-fou d'escalade ci-dessous.

**Description côté workflow principal** :
```
Recherche des produits réels Golden Market (prix, stock) via le Store API Medusa.
```

**Node `Search Medusa Products`** (HTTP GET) :
```
{MEDUSA_BACKEND_URL[_PRODUCTION]}/store/products-fuzzy-search?q={{ product_name }}&limit=5
Header: x-publishable-api-key: {MEDUSA_PUBLISHABLE_KEY[_PRODUCTION]}
```
Bascule staging/production automatique selon `$env.MEDUSA_ENV`. Cette route est un endpoint
Medusa dédié (`apps/backend/src/api/store/products-fuzzy-search/route.ts`,
`apps/backend/src/lib/product-fuzzy-search.ts`) — `word_similarity` (`pg_trgm`), seuil `> 0.4`
choisi empiriquement sur le catalogue réel (vraies fautes/variantes scorent 0.6-0.95, produits
sans rapport restent sous 0.35). Tolère fautes de frappe, accents manquants, singulier/pluriel —
**pas** les synonymes ("balai" ne matchera jamais "serpillière", recherche sémantique hors scope,
voir Anomalie n°3). Différent de `/store/products?q=` (matching littéral de Medusa, sans marge
d'erreur — ne pas utiliser pour ce tool).

**Node `Format Result`** — pour chaque produit : titre, prix XOF, disponibilité (`"en stock"` /
`"rupture de stock"` uniquement — **jamais** la quantité exacte, confidentialité assumée après un
incident réel, voir Historique), lien produit storefront
(`{storefrontUrl}/bf/products/{encodeURIComponent(handle)}` — `encodeURIComponent` indispensable,
les handles peuvent contenir des caractères accentués), et l'id de variante interne (pour
`place_order` uniquement, jamais à afficher au client).

**Garde-fou d'escalade déterministe, ajouté le 2026-09-15** — chaîne insérée entre `Search Medusa
Products` et `Format Result` :
```
Search Medusa Products (échec → Search Error Fallback : {products: []}, jamais de crash)
  → Track Search Outcome (Postgres UPDATE conversations SET consecutive_search_misses = CASE
      WHEN était-un-échec THEN +1 ELSE 0 END ... RETURNING consecutive_search_misses, was_miss,
      products  ← products fait le tour via un 3e paramètre $3::jsonb pour rester disponible
      en aval sans référence croisée fragile vers un node antérieur)
  → Check Escalation Threshold (If : was_miss = true ET consecutive_search_misses >= 4)
       true  → Notify Human (template escalation_alert, même format que escalate_to_human)
                 succès → Mark Escalated (conversations.status = 'escalated') → Format Escalated Result
                 échec  → Format Result (repli normal — ne JAMAIS dire au client "un humain va
                          vous aider" si la notification n'est pas confirmée envoyée)
       false → Format Result (inchangé)
```
Seuil `4` choisi empiriquement : le modèle (surtout Groq, moins fiable en tool-calling, voir
Anomalie n°1) peut légitimement appeler `find_products` 2-3 fois pour UNE seule vraie intention
client (retry avec terme simplifié + éventuelles fautes de reformulation, incident du 2026-09-07).
Un seuil trop bas déclencherait des escalades intempestives sur des recherches qui auraient fini
par aboutir. À ajuster avec des données réelles une fois en usage.

Chaque node de cette chaîne a `onError: "continueErrorOutput"` (au niveau racine, voir Piège
critique ci-dessus) — testé en conditions réelles (4 échecs consécutifs simulés, template
`escalation_alert` alors encore en attente d'approbation) : `Notify Human` a échoué comme prévu,
`Check Escalation Threshold` est retombé sur `Format Result`, le client a reçu une réponse normale
à chaque tour, jamais de crash.

#### Tool `browse_catalog` (id variable — recréé le 2026-09-15, l'id dépend de l'import)

**Input** : `hint` (String, optionnel, "Let the model define" — n8n exige au moins un champ
déclaré sur le trigger *When Executed by Another Workflow*, `[]` est rejeté avec l'erreur "At
least 1 field is required" ; ce champ n'est pas exploité par la logique elle-même, il existe pour
satisfaire cette contrainte tout en laissant le modèle indiquer un indice s'il en a un).

**Description côté workflow principal** :
```
Liste tout le catalogue publié (titre, prix, disponibilité). N'utilise ce tool QUE si
find_products a échoué deux fois de suite (recherche initiale + réessai avec terme simplifié)
pour la même demande du client : parcours alors la liste complète et identifie toi-même, avec ton
propre jugement, le produit que le client a probablement voulu dire (faute non couverte par la
recherche floue, synonyme, description approximative, déformation phonétique). Confirme avec le
client avant d'annoncer un produit comme celui qu'il cherche.
```

**Node `Browse Medusa Catalog`** (HTTP GET, défensif — `onError: "continueErrorOutput"` au niveau
racine → `Browse Error Fallback` en cas d'échec) :
```
{MEDUSA_BACKEND_URL[_PRODUCTION]}/store/products-catalog?limit=60
Header: x-publishable-api-key: {MEDUSA_PUBLISHABLE_KEY[_PRODUCTION]}
```
Route Medusa dédiée (`apps/backend/src/api/store/products-catalog/route.ts`, réutilise
`listAllProducts`/`listAllProductIds` de `product-fuzzy-search.ts`, TDD, 132/132 tests backend
verts) : liste tout le catalogue publié, sans filtre de similarité, avec la même logique de
disponibilité/confidentialité de stock que `find_products`. **Mis à jour le 2026-09-18** : ce
tool reste le filet de sécurité de tout dernier recours, mais n'est plus la seule alternative à
`find_products` en cas d'échec — voir `search_products_semantic` ci-dessous, ajouté précisément
pour couvrir le cas où ce choix (dumper tout le catalogue plutôt qu'une vraie recherche
vectorielle) ne scalerait plus si le catalogue grossissait significativement.

**Node `Format Result`** — même format que `find_products` (titre, prix, disponibilité binaire,
lien, id variante), mais pour tout le catalogue.

#### Tool `search_products_semantic` (id `2pOjBE9G1Un877H8`)

Ajouté le 2026-09-18 : troisième niveau de repli, entre `find_products` (pg_trgm) et
`browse_catalog` (dernier recours). Voir
`medusa-golden-market/docs/superpowers/specs/2026-09-17-recherche-semantique-produits-design.md`
pour le contexte complet (pourquoi une vraie recherche vectorielle a été ajoutée alors que
`browse_catalog` avait été délibérément préféré aux embeddings le 2026-09-15 : anticiper la
croissance du catalogue, `browse_catalog` ne scale pas au-delà de quelques centaines de produits).

**Input** : `query` (String, `$fromAI`, "Termes de recherche du client, en langage naturel").

**Description côté workflow principal** :
```
Recherche vectorielle de repli. N'utilise ce tool QUE si find_products a échoué deux fois de
suite (recherche initiale + réessai avec terme simplifié) pour la même demande du client, AVANT
d'essayer browse_catalog : renvoie les produits les plus proches sémantiquement de la demande,
même en cas de synonyme ou de description approximative. Si ce tool ne renvoie rien de pertinent,
essaie alors browse_catalog en tout dernier recours.
```

**Node `Semantic Search Medusa Catalog`** (HTTP GET, défensif — `onError:
"continueErrorOutput"` au niveau racine → `Semantic Search Error Fallback` en cas d'échec) :
```
{MEDUSA_BACKEND_URL[_PRODUCTION]}/store/products-semantic-search?q={{ $json.query }}&limit=8
Header: x-publishable-api-key: {MEDUSA_PUBLISHABLE_KEY[_PRODUCTION]}
```
Route Medusa dédiée (`apps/backend/src/api/store/products-semantic-search/route.ts`) : embed la
requête via l'API OpenAI (`text-embedding-3-small`), cherche les plus proches voisins dans la
table `product_embedding` (pgvector, index HNSW, distance cosinus), même logique de
disponibilité/confidentialité de stock que les autres routes. Pas de seuil de similarité codé en
dur : renvoie toujours le top-8, c'est le modèle IA qui juge de la pertinence parmi les candidats.
Embeddings maintenus à jour par un subscriber Medusa (`product.created`/`product.updated`), pas
par ce workflow.

**Node `Format Result`** — même format que `browse_catalog`, mais uniquement pour les candidats
renvoyés par la recherche vectorielle (pas tout le catalogue).

**Vérifié en conditions réelles (webhook signé, 2026-09-18)** : trois tours de conversation test
envoyés avec des formulations sans recoupement lexical avec les titres produits ("affûter mes
lames de cuisine émoussées" → Aiguiseur de couteaux, "tube de dentifrice qui traîne" → support
roulant) - les deux ont abouti à une réponse produit correcte (prix, lien, stock) sans erreur,
mais résolus par `find_products` seul (le modèle infère souvent un terme de recherche déjà
pertinent avant même d'appeler le tool, donc `find_products` réussit plus souvent qu'attendu en
première intention). Le tool `search_products_semantic` lui-même n'a pas été observé invoqué dans
ces trois tours - la route sous-jacente a été vérifiée directement par `curl` sur staging et
production (`?q=serpilliere` renvoie bien "Seau à roulettes... serpillière" et "Balai-éponge...")
et le câblage n8n (node, connexion `ai_tool`, prompt) est confirmé sans erreur d'exécution sur les
trois tours réels - reste à confirmer l'invocation réelle du tool sur un cas plus difficile
rencontré en production.

#### Tool `place_order` (id `EHll8zkvjwPJRJVz`)

**Input** : `items` (JSON `[{variant_id, quantity}]`), `phone_number` (fixe), `conversation_id`
(fixe, ajouté le 2026-09-18, voir plus bas), `first_name`, `address_1`, `city`, `provider_id`.

**Description** :
```
Crée une vraie commande Medusa (panier → adresse → livraison → paiement → complétion) à partir
des articles, coordonnées et moyen de paiement confirmés par le client.
```

Enchaîne les vrais appels Store API Medusa : `POST /store/carts` (région BF) → `POST
/store/carts/{id}/line-items` (une fois par article, via `Split In Batches`) → si
`provider_id = pp_cash-on-delivery_cash-on-delivery` **et** `city ≠ Ouagadougou`, **rejet
immédiat** (`Check COD Allowed`, node `If`) avec un message demandant Orange/Moov Money — sinon
`POST .../shipping-methods` → `POST /store/payment-collections` → `POST
.../payment-sessions` (`provider_id` fourni par le modèle) → `POST /store/carts/{id}/complete` →
`POST /admin/orders/{id}` (auth Basic avec `MEDUSA_ADMIN_KEY_*`) pour taguer
`metadata.source = "whatsapp"` (utilisé par le backend pour choisir le bon template de
confirmation, voir § 1). **Depuis le 2026-09-18**, une branche parallèle (`Save Order Id`, node
Postgres, `onError: "continueErrorOutput"`, ne bloque jamais la réponse client) écrit aussi
`conversations.last_order_id` — voir l'explication complète sous `mark_payment_reported`.

`provider_id` valides à ce jour : `pp_cash-on-delivery_cash-on-delivery`,
`pp_orange-money-manual_*`, `pp_moov-money-manual_*` (préfixes utilisés par
`get_payment_instructions` pour choisir le message, voir plus bas — vérifier les valeurs exactes
dans l'admin Medusa, Réglages → Régions → Burkina Faso → Fournisseurs de paiement si elles
évoluent).

#### Tool `get_payment_instructions` (id `DKlNw9FbVGWdhToy`)

**Input** : `conversation_id` (fixe, remplace `order_id` depuis le 2026-09-18 — voir plus bas).

Lit `conversations.last_order_id` (node Postgres `Get Last Order Id`) avant d'appeler `GET
/store/orders/{order_id}?fields=display_id,total,currency_code,*payment_collections.payments` —
si `last_order_id` est vide (branche `If Has Last Order` → `No Recent Order`), répond que la
commande est introuvable sans planter. Message final adapté au `provider_id` réel de la commande
(COD Ouagadougou / Orange Money / Moov Money / repli générique).

#### Tool `mark_payment_reported` (id `kBEyWGZdSLcI9EOI`)

**Input** : `conversation_id` (fixe, remplace `order_id` depuis le 2026-09-18), `payment_reference`
(optionnel, `$fromAI`, preuve donnée par le client).

**⚠️ Bug corrigé le 2026-09-18, trouvé en simulant une vraie conversation complète jusqu'à la
commande** : `order_id` était auparavant un paramètre `$fromAI` (comme `get_payment_instructions`).
Or le client ne voit jamais l'`order_id` réel (`order_...`), seulement le `display_id` ("#3"), et
seul le texte final visible au client est sauvegardé dans l'historique de conversation (§ 2.4/2.8)
— le modèle n'avait donc **aucun moyen** de fournir un `order_id` valide sur un tour séparé de
celui où `place_order` avait été appelé, quelle que soit sa fiabilité. Symptôme observé : au lieu
d'appeler `mark_payment_reported`, le modèle relançait tout le flux `find_products` → `place_order`
→ `get_payment_instructions`, créant une **commande en double** à chaque paiement signalé.
**Corrigé en éliminant complètement la dépendance à la mémoire du modèle** : nouvelle colonne
`conversations.last_order_id` (voir `schema.sql`), écrite par `place_order` (`Save Order Id`),
lue par `get_payment_instructions`/`mark_payment_reported` via `conversation_id` — une valeur fixe
comme `phone_number`, jamais fournie par le modèle. Même pattern que
`consecutive_search_misses`/`find_products`. **Prompt système renforcé en même temps** : interdit
explicitement de rappeler `place_order` pour une commande déjà créée dans la conversation.
**Vérifié en conditions réelles** (conversation complète simulée, webhook signé, jusqu'à une vraie
commande annulée après coup) : un seul `place_order` par conversation, `mark_payment_reported`
retrouve et met à jour la bonne commande.

**Limite résiduelle observée, pas corrigée** : Groq (modèle principal, voir Anomalie n°1) a parfois
rappelé `mark_payment_reported` deux fois pour le même message client (comportement de retry déjà
documenté ailleurs, voir HANDOFF.md 2026-09-07) ; le second appel, s'il ne repasse pas
`payment_reference`, écrase la référence enregistrée par `null` dans `metadata.whatsapp_payment_reference`
— la commande reste correctement rattachée (pas de doublon), seule la référence textuelle peut se
perdre. Pas de fix appliqué : la notification `escalation_alert` envoyée au propriétaire contient
déjà la référence au moment de l'appel, donc l'info n'est pas perdue, juste absente de la commande
elle-même si ce cas se présente.

`POST /admin/orders/{order_id}` (Basic Auth admin) pour taguer
`metadata.whatsapp_payment_reference`, puis notification automatique au propriétaire via le
template `escalation_alert` (Option B retenue : la notification humaine est systématique ici,
sans dépendre d'un enchaînement de tools décidé par l'agent). **Node `HTTP Request` (notification)
rendu défensif le 2026-09-15** (`onError: "continueErrorOutput"` au niveau racine, sans suite
connectée — voir Piège critique en tête de § 2.6) : avant ça, si la notification échouait pour
n'importe quelle raison (voir Anomalie n°6, le template lui-même n'a existé qu'à partir de cette
date), tout le tool plantait et **le client ne recevait aucune confirmation d'enregistrement de son
paiement**. La mise à jour de la commande (`Update Order Metadata`), elle, reste bloquante à
dessein : mieux vaut un échec visible que de dire "c'est noté" à tort.

**Description** :
```
Marque une commande comme "paiement signalé par le client" et notifie automatiquement l'équipe
pour vérification. Utilise ce tool quand le client confirme avoir effectué le transfert Mobile
Money.
```

#### Tool `escalate_to_human` (id `ho253xg11t9NVxX7`)

**Input** : `phone_number` (fixe, `{{ $('Edit Fields').item.json.from }}`), `conversation_id`
(fixe), `reason` (Let the model define).

Notification WhatsApp immédiate au propriétaire (template `escalation_alert`, branché
directement après le trigger — préférer `{{ $json.champ }}` à `{{ $('Node').first().json.champ
}}` quand c'est le cas, plus robuste). **Node `HTTP Request` rendu défensif le 2026-09-15**
(même piège et même correctif que `mark_payment_reported` ci-dessus, branche d'erreur reroutée
vers le même `Code in JavaScript` de fin — le client reçoit le message "un humain va prendre le
relais" **que la notification interne ait réussi ou non**, décision assumée : mieux vaut rassurer
le client à tort occasionnellement (rare, l'échec observé était un défaut de configuration
maintenant corrigé) que de le laisser sans réponse à chaque fois).

**Description** :
```
Alerte un humain immédiatement. Utilise ce tool si le client est mécontent, confus après
plusieurs tentatives, demande explicitement de parler à un humain, ou pour toute situation que
tu ne peux pas gérer avec les autres tools.
```
Cette règle reste au jugement du LLM à chaque tour (comme avant) — le garde-fou déterministe ajouté
le 2026-09-15 (voir `find_products` ci-dessus) ne couvre que le cas précis des échecs de recherche
produit répétés, pas toutes les situations où un humain serait utile.

### 2.7 Envoyer la réponse via Meta API

```
POST https://graph.facebook.com/v20.0/{PHONE_NUMBER_ID}/messages
Body : {{ JSON.stringify({
  messaging_product: "whatsapp",
  to: $('Edit Fields').item.json.from,
  type: "text",
  text: { body: $json.output, preview_url: true }
}) }}
```
`preview_url: true` indispensable pour que Meta génère un aperçu de lien quand l'agent partage un
lien produit (bug réel corrigé le 2026-09-07 — sans ce flag, l'aperçu manque même si le lien est
valide). Toujours `JSON.stringify()`, jamais du JSON littéral avec `{{ }}` inséré — casse dès que
la réponse contient un retour à la ligne, une apostrophe courbe ou un emoji.

### 2.8 Sauvegarder le tour de conversation

Node Postgres, insère la ligne `user` et la ligne `assistant` dans la même transaction (`messages`,
colonne `seq` pour l'ordre réel — voir § 2.4).

### Fallback multi-provider (résilience)

Le node **AI Agent** a un second connecteur Chat Model pour la résilience (crédit épuisé, quota,
panne d'un provider) — **intention d'origine : Claude Sonnet 5 en principal, Groq
`openai/gpt-oss-120b` en secours ponctuel seulement** (moins fiable en suivi d'instructions/
tool-calling, acceptable en fallback, pas comme modèle principal). **État réel en prod au
2026-09-15 : inversé, voir Anomalie n°1.**

---

## 3. Historique des correctifs réels (pour comprendre le *pourquoi* de chaque règle)

Détail complet dans `medusa-golden-market/HANDOFF.md` (journal de session, tenu à jour en
continu — plus fiable que ce guide en cas de divergence). Résumé chronologique des incidents
production ayant façonné le workflow actuel :

- **2026-09-05** — conversations de tous les clients fusionnées (`=` manquant sur un paramètre
  SQL) ; sens du paiement à la réception inversé par l'IA ; tableaux markdown + id technique
  exposés au client (→ ajout du lien produit dans `find_products`) ; accusés de statut WhatsApp
  traités comme de vrais messages ; historique de conversation parfois dans le désordre (→ colonne
  `seq`).
- **2026-09-07** — signature HMAC cassait sur accent/emoji (→ `rawBody: true`) ; aperçu de lien
  produit absent (→ `preview_url: true` + `encodeURIComponent(handle)`) ; fuite du stock exact au
  client (→ disponibilité binaire uniquement, interdiction explicite dans le prompt) ; recherche
  produit non tolérante aux fautes (→ retry avec terme simplifié dans le prompt + nouvelle route
  `/store/products-fuzzy-search`, branchée sur `find_products` une fois déployée).
- **2026-09-13/14** — synchro catalogue Medusa → Meta Commerce Catalog mise en place et vérifiée
  bout en bout (404 d'infra Apache corrigé, jeton WhatsApp régénéré avec le scope
  `catalog_management`) ; Pixel Meta + Conversions API ajoutés par-dessus.
- **2026-09-15** — crash sur message non-texte (`message_text` NULL) corrigé (→ chaîne de repli
  par type de message, § 2.3) ; audit de fond identifiant l'inversion Groq/Claude (Anomalie n°1,
  laissée en l'état, voir plus bas) et l'absence d'extraction du `referral` Meta (→ corrigé, § 2.3) ;
  ménage n8n (suppression des 4 workflows `check_stock`/`get_price`/`create_order`/ancien
  `place_order`, obsolètes depuis le passage au Store API Medusa) ; **suite du même audit, même
  journée** : recherche sémantique de repli (`browse_catalog`, § 2.6) ; garde-fou d'escalade
  déterministe (`find_products` + colonne `conversations.consecutive_search_misses`, § 2.6) ;
  vision sur photo envoyée par le client (§ 2.3bis) ; tentative d'inversion Groq/Claude appliquée
  puis annulée dans la foulée (pas de crédit Anthropic disponible) ; **découverte que le template
  `escalation_alert` n'existait pas du tout sur le compte Meta** (créé et approuvé le jour même) et
  que ça cassait silencieusement `escalate_to_human`/`mark_payment_reported` en prod depuis le
  début — les deux rendus défensifs ; **piège général découvert en le corrigeant** : `onError` doit
  être au niveau racine du node, pas dans `parameters`, sans quoi n8n l'ignore sans avertissement
  (voir Piège critique en tête de § 2.6) — plusieurs des correctifs du jour ont dû être redéployés
  une deuxième fois une fois ce piège compris.

---

## 4. Tester de bout en bout

### `curl` avec signature HMAC plutôt que de vrais messages WhatsApp

⚠️ Envoyer beaucoup de messages de test rapprochés depuis un vrai téléphone vers le même contact
peut faire flaguer ce numéro comme spam par WhatsApp (restriction temporaire ~6h). Réserver les
vrais messages WhatsApp aux tests finaux de bout en bout.

```bash
BODY='{"entry":[{"changes":[{"value":{"messages":[{"from":"TON_NUMERO","id":"wamid.TEST'$(date +%s)'","text":{"body":"Bonjour, avez-vous ce produit ?"}}]}}]}]}'
SECRET="ta_valeur_WHATSAPP_APP_SECRET"
SIGNATURE=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')

curl -X POST https://n8n.golden-market.co/webhook/whatsapp \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: sha256=$SIGNATURE" \
  -d "$BODY"
```
Path prod `/webhook/whatsapp` (workflow publié) ; `/webhook-test/whatsapp` en mode "Listen for
test event".

**Attention avec ce `curl` simplifié** : le corps signé ici n'est pas byte-identique à ce que
produirait un vrai client WhatsApp si le message contient des accents/emoji (voir § 2.2, `rawBody:
true`) — pour tester spécifiquement la vérification de signature avec des caractères spéciaux,
reproduire le corps exact octet pour octet, pas juste le JSON logique.

### Étapes

1. Publier le workflow (**Publish**, pas de toggle "Active" classique dans cette version de n8n) ;
   un triangle rouge sur un node bloque la publication.
2. Envoyer un message (`curl` ou vrai WhatsApp).
3. Vérifier l'onglet **Executions** (déclenchement sans erreur).
4. Vérifier en base : `docker compose exec postgres psql -U <user> -d golden_market -c "SELECT *
   FROM messages ORDER BY seq DESC LIMIT 5;"`.
5. Tester un scénario de commande complet (jusqu'à `place_order` + `get_payment_instructions`), un
   scénario `mark_payment_reported`, et un scénario d'escalade.

### En mode développement Meta (avant App Review)

Cloud API n'autorise l'envoi qu'aux numéros testeurs explicitement ajoutés (jusqu'à 5) tant que
l'app Meta n'a pas été passée en review — **App Dashboard → WhatsApp → API Setup → "Manage phone
number list"**.

---

## 5. Checklist sécurité

- [x] Signature Meta vérifiée sur le corps brut de chaque requête entrante (§ 2.2)
- [x] `.env` toujours hors Git
- [x] Basic Auth actif sur l'éditeur n8n
- [ ] ⚠️ `N8N_BLOCK_ENV_ACCESS_IN_NODE: false` reste un compromis assumé — ne jamais importer de
      node Code tiers sans relecture complète
- [ ] Sauvegardes régulières du volume Postgres (`pg_dump` planifié) — à vérifier, pas documenté
      comme fait
- [x] Limite claire dans le system prompt sur ce que l'agent peut promettre (prix, stock, délais,
      remises)
- [x] Templates WhatsApp (`escalation_alert`, `order_confirmation_from_whatsapp`) approuvés par
      Meta
