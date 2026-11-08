# Chapitre 1 — Logs et métriques Apache HTTP Server

| Niveau | Durée estimée | Prérequis |
|---|---|---|
| Débutant + | 3 h 00 (dont 2 h de manipulation) | Introduction lue. VM attribuée avec accès `sudo`. Espace Kibana accessible. Token d'enrôlement reçu du formateur. |

Les logs d'un serveur web sont la source d'observabilité la plus riche et la plus mal exploitée. Riche, parce qu'une seule ligne contient le client, la ressource, le résultat, le volume et — si on le configure — la durée. Mal exploitée, parce qu'on s'en sert en général pour un `grep ERROR` et rien d'autre.

Ce chapitre met en place la chaîne complète sur **votre** VM : Apache produit, l'Elastic Agent collecte, Elasticsearch stocke, Kibana montre. Puis vous cassez le service, volontairement, pour voir ce que la chaîne vous dit.

## Objectifs

À la fin de ce chapitre, vous savez :

1. Configurer la journalisation d'Apache pour qu'elle soit **exploitable** : format JSON, durée de traitement, exclusion des sondes.
2. Sécuriser `mod_status` et expliquer pourquoi son exposition est une fuite d'information.
3. Créer votre politique d'agent dans Fleet et y ajouter l'intégration Apache.
4. Installer et enrôler l'Elastic Agent avec la CA interne, puis prouver que la donnée arrive.
5. Écrire des requêtes KQL qui répondent à une question d'exploitation.
6. Construire un dashboard dont les taux sont des ratios et les latences des percentiles.
7. Créer quatre règles d'alerte calibrées, dont une alerte d'absence de données **testée**.
8. Diagnostiquer les pannes classiques de la chaîne, dans l'ordre.

> **À retenir** — Tout ce chapitre tient dans une phrase : une donnée n'existe pour vous que si vous pouvez la **montrer dans Kibana** et **dire ce qu'elle signifie**. « La commande est passée » n'est pas un résultat.

---

## Étape 1 — Prérequis sur la VM

### 1.1 Relever l'état initial

Avant de modifier quoi que ce soit, on photographie l'existant. Sans référence, aucun écart n'est interprétable.

```bash
# Version d'Apache et modules actifs
apache2 -v
apache2ctl -M | grep -E 'mpm|status|proxy|unique|headers'

# Quel MPM ? prefork (1 processus par connexion), worker ou event (threads)
apache2ctl -V | grep -i 'Server MPM'

# Les limites configurées : ce sont elles qui produiront les 503
grep -rh -A8 'IfModule mpm' /etc/apache2/mods-available/mpm_*.conf | grep -E 'MaxRequestWorkers|ThreadsPerChild|ServerLimit'
grep -rh 'KeepAliveTimeout' /etc/apache2/apache2.conf

# Journaux existants et leur volume
ls -l /var/log/apache2/
hostname ; hostname -I
```

> **⚠️ Piège fréquent** — Sur RHEL, Rocky et Alma, rien de tout cela ne fonctionne : la configuration est dans `/etc/httpd/`, les journaux dans `/var/log/httpd/`, le service s'appelle `httpd`, et les commandes `a2enmod` / `a2enconf` n'existent pas. Ce chapitre suit Debian et Ubuntu. Si votre VM est en RHEL, adaptez les chemins dans le générateur — et notez-le dans votre compte rendu.

### 1.2 Activer les modules nécessaires et poser le contenu de ShopFlow

```bash
sudo a2enmod status unique_id headers
sudo mkdir -p /var/www/shopflow/assets

# La sonde de supervision : une réponse locale, sans backend
echo '{"status":"UP","service":"shopflow-web","student":"studentXX"}' \
  | sudo tee /var/www/shopflow/health.json >/dev/null

# Une page et une feuille de style, pour avoir du trafic réaliste
printf '<!doctype html><title>ShopFlow</title><h1>ShopFlow — NovaCommerce</h1>\n' \
  | sudo tee /var/www/shopflow/catalogue.html >/dev/null
printf 'body{font-family:sans-serif}\n' \
  | sudo tee /var/www/shopflow/assets/app.css >/dev/null
```

### 1.3 Les trois fichiers de configuration

> **⚠️ Piège fréquent** — Les fichiers du dépôt sont des **modèles** : ils contiennent des
> marqueurs `{{MAJUSCULES}}` à la place de vos valeurs. Copiés tels quels sur la VM, Apache
> refuse de démarrer avec `Cannot access directory '/etc/apache2/{{APACHE_LOG_DIR}}/'`.
> Passez **toujours** par le générateur, ou par son équivalent en ligne de commande :
>
> ```bash
> python3 tools/rendre.py 01-apache --NUM 20 --STUDENT_HOST vm-student20 \
>     --STUDENT_IP 172.16.20.20 --sortie ~/rendu
> ```
>
> `python3 tools/rendre.py 01-apache --liste` affiche les champs attendus. Le script
> refuse de produire un fichier qui contiendrait encore un marqueur.

Le générateur du chapitre produit, avec vos valeurs :

| Fichier | Destination | Rôle |
|---|---|---|
| `shopflow-logs.conf` | `/etc/apache2/conf-available/` | Les deux formats de journal, l'`ErrorLog`, l'identifiant de corrélation |
| `server-status.conf` | `/etc/apache2/conf-available/` | `mod_status`, restreint à la boucle locale |
| `shopflow.conf` | `/etc/apache2/sites-available/` | Le vhost ShopFlow (le bloc reverse proxy servira au chapitre 2) |
| `apache2` | `/etc/logrotate.d/` | La rotation, avec `delaycompress` |

```bash
sudo install -m 644 shopflow-logs.conf  /etc/apache2/conf-available/
sudo install -m 644 server-status.conf  /etc/apache2/conf-available/
sudo install -m 644 shopflow-vhost.conf /etc/apache2/sites-available/shopflow.conf
sudo install -m 644 logrotate-apache    /etc/logrotate.d/apache2

sudo a2enconf shopflow-logs server-status
sudo a2ensite shopflow
sudo a2dissite 000-default

sudo apachectl configtest        # DOIT afficher : Syntax OK
sudo systemctl reload apache2    # reload = pas de coupure
```

> **⚠️ Piège fréquent** — Un `systemctl restart apache2` sur une configuration invalide laisse le service **arrêté**. Un `reload` sur configuration invalide échoue mais laisse l'ancienne configuration en place et le service debout. Avec `configtest` d'abord, puis `reload`, vous ne coupez jamais le service par erreur.

### 1.4 Pourquoi deux journaux : la question de la durée

C'est le point technique le plus important du chapitre, et la cause numéro un des dashboards de latence vides.

Les formats standards (`common`, `combined`) **ne contiennent pas la durée de traitement**. L'intégration Apache d'Elastic sait parser ces formats standards. Donc, par défaut, vous n'avez aucun champ de durée, et aucun percentile de latence n'est calculable.

| Stratégie | Principe | Avantage | Risque |
|---|---|---|---|
| **A — journal JSON séparé** (retenue) | `access.log` reste en `combined` pour l'intégration officielle ; `access_json.log` porte `%D` et est lu par une intégration *Custom Logs (Filestream)* | Parsing JSON déterministe, aucun risque de casser l'intégration, noms de champs ECS maîtrisés | Double écriture sur disque, un data stream de plus |
| B — ajouter `%D` au format `combined` | Un seul journal, champ récupéré dans un pipeline `@custom` | Un seul data stream | Le motif de parsing de l'intégration peut rejeter la ligne : documents en erreur, ou champ ignoré |

> **À retenir** — Un journal partiellement rejeté est **pire** qu'un journal sans durée, parce qu'il fausse tous les comptages sans rien signaler. C'est pourquoi ce chapitre retient la stratégie A, et pourquoi l'étape 4 vous fait compter les documents en erreur de parsing.

Les directives à connaître dans le `LogFormat` :

| Directive | Signification | Piège |
|---|---|---|
| `%h` / `%a` | Hôte distant / IP de la connexion | Derrière un proxy, c'est l'IP du proxy : voir `%{X-Forwarded-For}i` |
| `%>s` | Code de statut **final** | `%s` donne le statut initial : différent après une redirection interne |
| `%b` | Octets du corps, `-` si vide | Le tiret casse les agrégations numériques |
| `%B` / `%O` | Octets du corps (0 si vide) / octets totaux | **À préférer** pour toute exploitation chiffrée |
| `%D` | Durée en **microsecondes** | Absent des formats standards : c'est pour cela que les percentiles manquent |
| `%{ms}T` / `%T` | Durée en millisecondes / en secondes | `%T` est trop grossier pour des percentiles |
| `%X` | État de la connexion en fin de requête | `X` = client parti avant la fin : indice de lenteur |
| `%{UNIQUE_ID}e` | Identifiant unique de requête | Le pont vers les logs Tomcat (chapitre 2) |

**✅ Vérification de l'étape 1**

```bash
curl -s -o /dev/null http://localhost/catalogue.html
sudo tail -1 /var/log/apache2/access.log
sudo tail -1 /var/log/apache2/access_json.log | python3 -m json.tool
```

Vous devez voir une ligne `combined` classique **et** un objet JSON valide contenant `shopflow.duration_us`. Si le JSON est invalide, la cause est presque toujours une barre oblique inverse manquante en fin de ligne dans le `LogFormat`.

---

## Étape 2 — Sécuriser et vérifier `mod_status`

`mod_status` expose l'état interne d'Apache. Deux rendus :

| URL | Rendu | Destinataire |
|---|---|---|
| `/server-status` | Page HTML avec les requêtes en cours | Un humain, en diagnostic ponctuel |
| `/server-status?auto` | Texte brut, une métrique par ligne | Une machine : **c'est ce format que lit l'intégration Elastic** |

> **⚠️ Piège fréquent** — `/server-status` accessible publiquement est une **fuite d'information** : la page HTML montre les URL en cours de traitement, les adresses IP des clients et les vhosts servis. C'est une cartographie de votre application offerte à qui la demande. Le contrôle d'accès n'est pas une option, et son absence est éliminatoire dans l'évaluation du projet final.

```bash
# Depuis la VM : doit répondre
curl -s "http://localhost/server-status?auto" | head -9

# Depuis votre poste : DOIT être refusé (403)
curl -I http://172.16.X.Y/server-status
```

### Lire la sortie machine

```text
Total Accesses: 184213          # compteur cumulé depuis le démarrage
Total kBytes: 1048576
CPULoad: 2.41                   # part de CPU consommée par Apache
Uptime: 86234                   # secondes depuis le démarrage
ReqPerSec: 2.1364               # MOYENNE depuis le démarrage, pas l'instantané
BytesPerSec: 12452.3
BytesPerReq: 5828.1
BusyWorkers: 7                  # workers en train de traiter
IdleWorkers: 18                 # la RÉSERVE : l'indicateur clé
Scoreboard: _W_K.K__W_RW......
```

Le scoreboard, caractère par caractère :

```text
  _  slot libre, prêt à servir           ← réserve saine
  .  slot non encore alloué              ← marge de croissance
  W  traite et répond                    ← travail réel
  K  connexion keepalive au repos        ← occupe un slot sans travailler
  R  lit la requête       L  écrit le journal      C  ferme la connexion
  D  résolution DNS en cours             ← anormal dans un chemin de requête
  S  démarrage            G  arrêt en douceur      I  nettoyage

  beaucoup de _ et de .  → serveur au repos, marge confortable
  aucun _ ni .           → SATURATION : les requêtes attendent
  majorité de K          → slots mangés par le keepalive (MPM event préférable)
```

> **À retenir** — `ReqPerSec` est une moyenne **depuis le démarrage du serveur**. Si Apache tourne depuis 24 heures, un pic de 10 minutes y est totalement dilué. Ne l'utilisez jamais comme indicateur de charge instantanée : comptez les documents de logs par minute, c'est exact et c'est immédiat.

**✅ Vérification de l'étape 2** — `?auto` répond en local, l'accès distant renvoie 403, et la sortie contient bien une ligne `Scoreboard:` (sinon `ExtendedStatus` n'est pas actif).

---

## Étape 3 — Créer la politique d'agent et les intégrations

Cette étape se fait dans **Kibana → Fleet**. Sur la plateforme EFI, les politiques sont **déjà créées** : une par candidat et par rôle de machine. Vous n'en créez aucune — vous lisez la vôtre, vous vérifiez ce qu'elle contient, et vous demandez l'ajout de ce qui manque.

> **🔒 Formateur / administrateur** — Les politiques `efi-studentXX-apache`, `efi-studentXX-tomcat` et `efi-studentXX-k8s` existent pour les vingt candidats, avec l'espace de nom `studentXX` et la sortie `efi-elasticsearch`. Trois actions restent à faire **avant** la séance : **(1)** ajouter à chaque `efi-studentXX-apache` la troisième intégration **Custom Logs** décrite en 3.3 — sans elle, aucune mesure de latence n'est possible dans tout le manuel ; **(2)** vérifier les chemins de journaux de l'intégration Apache ; **(3)** transmettre à chaque candidat, **individuellement**, le token d'enrôlement de sa politique.

### 3.1 Ce que contient déjà votre politique

Ouvrez **Fleet → Agent policies → `efi-studentXX-apache`**. Vous devez y voir deux intégrations :

| Intégration | Rôle | Espace de nom | Sortie |
|---|---|---|---|
| **Apache HTTP Server** | `access.log`, `error.log`, métriques `mod_status` | `studentXX` | `efi-elasticsearch` |
| **System** | CPU, mémoire, disque, réseau de la VM | `studentXX` | `efi-elasticsearch` |

Et, dans l'onglet **Paramètres**, deux réglages qui vous concernent :

| Élément | Valeur attendue | Pourquoi |
|---|---|---|
| Espace de nom | `studentXX` | Troisième segment du nom de data stream : c'est votre cloison sur le cluster partagé |
| Sortie | `efi-elasticsearch` | Destination des données |
| Agent monitoring | activé | La seule visibilité le jour où la collecte tombe |

> **⚠️ Piège fréquent** — Deux intégrations ne suffisent pas. Il en faut une **troisième**, et son absence ne produit aucune erreur : la collecte fonctionnera, les dashboards se rempliront, et il manquera simplement la durée des requêtes — donc les percentiles, le scénario « requêtes lentes » et le SLO de latence du projet final. Vérifiez-le maintenant, pas au chapitre 4.

### 3.2 L'intégration Apache HTTP Server

Trois jeux de données à activer, avec vos chemins :

| Jeu de données | Paramètre à renseigner | Data stream produit |
|---|---|---|
| Access logs | `/var/log/apache2/access.log` | `logs-apache.access-studentXX` |
| Error logs | `/var/log/apache2/error.log` | `logs-apache.error-studentXX` |
| Status metrics | `http://localhost/server-status`, période 10 s | `metrics-apache.status-studentXX` |

### 3.3 La troisième intégration : Custom Logs — celle qui apporte la durée

C'est l'intégration que votre politique n'a pas encore, et c'est la plus importante du chapitre.

**Pourquoi elle est indispensable.** Les formats de journal standards d'Apache (`common`, `combined`) ne contiennent **pas** la durée de traitement. L'intégration Apache officielle sait parser ces formats standards — et rien d'autre. Sans un second journal, vous n'avez donc aucun champ de durée, et il devient impossible de calculer un percentile de latence. Ce n'est pas un détail de confort : c'est ce qui bloque le TP 4.3, le scénario « requêtes lentes » du chapitre 1, la courbe P50/P95/P99 du dashboard, et le SLO de latence du projet final.

**Comment l'ajouter**, dans `efi-studentXX-apache` :

1. **Fleet → Agent policies → `efi-studentXX-apache` → Ajouter une intégration**.
2. Chercher « Custom Logs ». **Deux entrées portent ce nom** : choisissez **Custom Logs (Filestream)**, et surtout pas **Custom Logs (Deprecated)**.
3. Renseigner. Le formulaire s'intitule **Custom Filestream Logs** une fois l'intégration choisie :

| Paramètre | Valeur | Pourquoi |
|---|---|---|
| Nom de l'intégration | `custom-logs-efi-studentXX-apache` | Convention : on retrouve la politique dans le nom |
| **Espace de nom** | `studentXX` | **Le réglage le plus important** : il décide du troisième segment du data stream. Laissé à `default`, toutes vos requêtes du manuel tomberont à côté |
| Paths | `/var/log/apache2/access_json.log` | Le journal JSON créé à l'étape 1 |
| Use the « logs.ecs » data stream | **désactivé** | Activé, il **ignore** le *Dataset name* **et** l'*Ingest Pipeline* : vous perdriez les deux réglages qui comptent |
| Dataset name | `shopflow_apache.access_json` | Donne `logs-shopflow_apache.access_json-studentXX` |
| Créer un modèle d'index dédié | **activé** | Mappings corrects pour un dataset personnalisé |
| Parsers | **laisser vide** | Le JSON est décodé **dans Elasticsearch** par le pipeline, pas par l'agent. Un parser `ndjson` ici remonterait les champs à la racine et ferait échouer le pipeline |
| Exclude Files | `\.gz$` (valeur par défaut) | Évite de relire les journaux compressés par la rotation |
| Type de flux de données | `Logs` | |
| Sortie | `efi-elasticsearch` | |

> **⚠️ Piège fréquent** — Le champ **Parsers** du formulaire propose un exemple commenté (`#- ndjson:`, `#- multiline:`). Laissez-le tel quel pour **cette** intégration : ici, c'est le pipeline d'ingestion qui parse. Le bloc `parsers: - multiline:` du chapitre 2 concerne une **autre** intégration, celle des journaux Tomcat, où il est indispensable.

#### Le champ « Ingest Pipeline » : à trancher par la mesure

La convention `<type>-<dataset>@custom` fait appeler votre pipeline **automatiquement** — à condition que le modèle d'index créé pour ce dataset personnalisé le câble. Selon les versions, ce n'est pas garanti. Plutôt que de supposer, mesurez :

1. Laissez d'abord le champ **Ingest Pipeline vide**, enregistrez, générez du trafic.
2. Dans Discover, sur `logs-shopflow_apache.access_json-studentXX`, regardez si `event.duration` existe.
3. **S'il existe** : le pipeline est bien appelé, ne touchez à rien.
4. **S'il n'existe pas** : rouvrez l'intégration et saisissez `logs-shopflow_apache.access_json@custom` dans **Ingest Pipeline**.

On peut aussi lire le câblage directement :

```text
GET logs-shopflow_apache.access_json-studentXX/_settings?filter_path=**.default_pipeline
```

> **⚠️ Piège fréquent** — Ne renseignez pas le champ « à tout hasard » sans vérifier. Si le pipeline finissait par s'exécuter **deux fois**, le second passage ne trouverait plus le champ `message` — supprimé par le premier — et poserait `error.message` sur **chaque** document. Le contrôle qualité « zéro `error.message` » de l'étape 4 détecte exactement cela.

4. Enregistrer. La politique passe à **3 intégrations** et sa révision augmente ; les agents déjà enrôlés reçoivent le changement en quelques secondes, sans réinstallation.

> **⚠️ Piège fréquent** — Le catalogue propose **Custom Logs (Deprecated)** et **Custom Logs (Filestream)**. La première est l'ancien paquet `log`, conservé pour les politiques déjà en place. Les deux collectent bien un fichier, mais elles n'attendent **pas la même configuration avancée** : le traitement multiligne du chapitre 2 s'écrit `parsers: - multiline:` pour `filestream`, et `multiline.pattern` à plat pour l'ancien. Si vous prenez la dépréciée ici, la configuration multiligne du chapitre 2 sera silencieusement ignorée — et une exception Java produira quarante documents au lieu d'un.

Le data stream produit sera `logs-shopflow_apache.access_json-studentXX`, et le pipeline personnalisé qu'il appellera s'appelle `logs-shopflow_apache.access_json@custom`. Cette convention `<type>-<dataset>@custom` n'est pas négociable : c'est elle qui fait que votre pipeline est appelé automatiquement.

**✅ Vérification de l'étape 3.3** — la politique affiche bien trois intégrations, et après quelques requêtes :

```bash
curl -s --cacert /etc/efi/pki/ca.crt -H "Authorization: ApiKey $ES_API_KEY" \
  "https://172.16.3.50:9200/logs-shopflow_apache.access_json-studentXX/_count?pretty"
```

Un compte supérieur à zéro signifie que la troisième intégration fonctionne. Un data stream inexistant signifie qu'elle n'a pas été ajoutée, ou que le chemin du fichier ne correspond pas à celui écrit par Apache.

### 3.4 Créer le pipeline `@custom` — avant la première donnée

**Où est la Console** : menu ☰ en haut à gauche → tout en bas, section **Management** → **Dev Tools**. Plus rapide : tapez `Dev Tools` dans la barre de recherche du haut. En accès direct : `.../app/dev_tools#/console`. On y colle le verbe, le chemin et le corps, puis on exécute avec ▶ ou `Ctrl + Entrée`.

Le générateur produit **`pipeline-access-json.a-coller.json`** : ce fichier contient la requête complète, verbe compris, **à copier d'un bloc dans la Console**. Rien à retoucher.

> **⚠️ Piège fréquent** — N'utilisez pas `pipeline-access-json.json` pour le collage : il commence par deux clés de documentation, `_source` et `_requete`, qui rappellent où le coller mais qu'Elasticsearch **refuse** (`unknown field`). C'est la version `.a-coller.json` qui est faite pour la Console.

Ce pipeline est **unique pour les vingt candidats** : son nom ne dépend que du dataset, pas de l'espace de nom. On le crée **une fois**, il sert à tout le monde — raison pour laquelle il ne contient aucune valeur propre à un candidat. Le champ `service.environment` est rempli à l'ingestion depuis `{{{data_stream.namespace}}}`, c'est-à-dire `studentXX` pour chacun.

Ce que fait chaque processeur :

| Processeur | Rôle | Pourquoi c'est nécessaire |
|---|---|---|
| `json` | Parse `message` et remonte les clés à la racine | La ligne lue par l'agent est une chaîne : sans ce processeur, rien n'est requêtable |
| `dot_expander` | Éclate `a.b.c` en objets imbriqués | **Indispensable** : voir l'encadré ci-dessous |
| `date` | Normalise l'horodatage ISO 8601 | Garantit que `@timestamp` est de type `date`, pas une chaîne |
| `convert` | Force `shopflow.duration_us` en entier | Un champ arrivé en chaîne interdit tout percentile |
| `script` (durée) | Multiplie par 1 000 | **ECS impose les nanosecondes** pour `event.duration` |
| `script` (famille) | Calcule `shopflow.status_class` (`2xx`, `5xx`…) | Calculé une fois à l'ingestion plutôt qu'à chaque requête |
| `set` | Pose `service.name`, `event.module`, `event.dataset` | Permet de corréler avec Tomcat au chapitre 2, par `service.name` |
| `user_agent` | Décompose la chaîne du navigateur | Segmentation par navigateur et par OS |
| `convert` (ip) | Type `ip` | Autorise les recherches par plage CIDR |
| `set` (`event.outcome`) | `failure` si ≥ 500, `success` si < 400 | Champ directement réutilisable comme SLI (chapitre 5) |
| `remove` | Supprime `message` devenu redondant | Réduit le volume stocké d'environ un tiers |
| `on_failure` | Capture l'erreur dans `error.message` | Sans cela, un document en échec est rejeté **silencieusement** |

> **⚠️ Piège fréquent — celui qui coûte le plus cher ici** — Le processeur `json` avec `add_to_root` pose les clés **telles quelles** : votre journal contient `"http.response.status_code"`, et Elasticsearch crée un champ dont le **nom contient des points**, pas un objet imbriqué. Or tous les processeurs suivants adressent `ctx.http.response.status_code`, c'est-à-dire un chemin imbriqué : ils ne trouvent rien. Et comme ils portent `ignore_failure` ou une condition, **ils échouent en silence** — pas d'erreur, pas de tag, juste des champs manquants. Le `dot_expander` rétablit la structure. Sans lui, vous obtenez un document qui a l'air correct mais sans `event.duration`, sans `shopflow.status_class`, sans `event.outcome` et sans `source.ip`. C'est exactement ce que le test `_simulate` de l'étape suivante doit vous faire voir.

> **À retenir** — `event.outcome` traite ici les 4xx comme **ni succès ni échec**, volontairement : une erreur 404 provoquée par un scan externe n'est pas une défaillance de votre service. Cette décision a des conséquences directes sur le calcul du SLI au chapitre 5. Un SRE assume ce genre de choix et le documente.

**✅ Vérification de l'étape 3** — testez le pipeline **avant** d'ingérer, avec le contenu de `pipeline-simulate.json` :

```text
POST _ingest/pipeline/logs-shopflow_apache.access_json@custom/_simulate
```

Dans la réponse, vous devez lire exactement :

- `event.duration` : `4102311000` — soit 4,102 s en nanosecondes ;
- `shopflow.status_class` : `2xx` pour le premier document, `5xx` pour le deuxième ;
- `event.outcome` : `success`, puis `failure` ;
- le troisième document porte le tag `json_parse_failed` : la gestion d'erreur fonctionne.

> **⚠️ Piège fréquent** — Si `event.duration` vaut `4102311` au lieu de `4102311000`, la multiplication par 1 000 ne s'est pas faite : vos latences seront mille fois trop faibles et votre dashboard dira que tout va bien. Une erreur d'unité produit un résultat **plausible et faux** : c'est le pire des cas.

---

## Étape 4 — Installer et enrôler l'Elastic Agent

La commande de référence est celle affichée par **Fleet → Agents → Add agent** : elle correspond à la version réellement déployée. Le script `install-agent.sh` du générateur en est la version commentée.

```bash
sudo ./install-agent.sh '<votre-token-d-enrolement>'
```

Ce qu'il fait, dans l'ordre : il vérifie la présence de la CA interne, il teste la connectivité vers `172.16.3.55:8220`, il télécharge l'agent **9.5.6**, puis il installe et enrôle avec la CA et deux étiquettes (`studentXX`, `tp-apache`).

| Option | Rôle | Remarque |
|---|---|---|
| `--url` | Adresse de **Fleet Server** | C'est bien Fleet, pas Kibana ni Elasticsearch |
| `--enrollment-token` | Token lié à la politique | Détermine ce que l'agent va collecter |
| `--certificate-authorities` | CA interne EFI | La bonne pratique en TLS correctement déployé |
| `--tag` | Étiquettes libres | Ce qui permet de retrouver votre agent parmi vingt |
| `--insecure` | Désactive la validation TLS | **À éviter** : le symptôme disparaît, pas le problème |

> **⚠️ Piège fréquent** — La version de l'agent doit être **identique ou inférieure** à celle du cluster, jamais supérieure. Installer un agent plus récent que la stack est une cause classique d'état `unhealthy` difficile à diagnostiquer. Ici, la stack est en 9.5.6 : l'agent est en 9.5.6. <!-- À VÉRIFIER : confirmer que l'artefact elastic-agent-9.5.6-linux-x86_64.tar.gz existe bien sur artifacts.elastic.co, et relever la version exacte dans Kibana → Stack Management. -->

### Les états d'un agent

| État dans Fleet | Signification | Première action |
|---|---|---|
| `Healthy` | L'agent communique, tous ses collecteurs fonctionnent | Rien |
| `Degraded` | Il communique, mais **au moins un collecteur échoue** | `status --output=full` : lire l'unité fautive |
| `Unhealthy` | Erreur bloquante : output injoignable, certificat, politique invalide | Vérifier output, CA, identifiants |
| `Offline` | Plus de contact depuis le délai configuré | Machine, service, port 8220 |
| `Updating` | Mise à jour en cours | Attendre le retour en `Healthy` |

> **À retenir** — `Degraded` est l'état le plus instructif et le plus souvent ignoré : l'agent va bien, mais une de vos intégrations ne collecte rien. Un dashboard vide avec un agent « vert » vient très souvent d'un agent en réalité `degraded` dont personne n'a lu le détail.

**✅ Vérification de l'étape 4** — les quatre points de contrôle, dans l'ordre, en s'arrêtant au premier qui échoue :

```bash
ES_API_KEY='<votre-cle>' ./verif-ingestion.sh
```

| Point de contrôle | Ce qu'on vérifie | Si ça échoue |
|---|---|---|
| 1. La source produit | `tail` sur les deux journaux, `curl` sur `?auto` | Ce n'est pas un problème Elastic : c'est Apache ou son trafic |
| 2. L'agent lit | `elastic-agent status --output=full`, `inspect` | Chemin incorrect dans l'intégration, ou droits de lecture |
| 3. L'agent envoie | Logs de l'agent, Agent monitoring dans Kibana | Output injoignable, certificat, authentification |
| 4. Elasticsearch a reçu | `_count` sur les quatre data streams | Mauvais namespace, ou document rejeté par le pipeline |

Le script affiche en plus les deux contrôles qualité qui comptent : **zéro** document avec `error.message`, et une part marginale de documents sans `event.duration`.

---

## Étape 5 — Chercher : KQL, de la question à la requête

Dans **Kibana → Stack Management → Data Views**, créez `apache-studentXX` sur le motif `logs-shopflow_apache.access_json-studentXX` avec le champ temporel `@timestamp`. Puis ouvrez **Discover**.

> **⚠️ Piège fréquent** — « Il n'y a aucune donnée » est, neuf fois sur dix, une mauvaise **fenêtre temporelle** ou un mauvais motif d'index. Vérifiez-le avant toute autre hypothèse. La rétention de la plateforme est courte par conception : des données d'il y a un mois ont normalement disparu (ILM).

### Progression de requêtes

```text
# ── Niveau 1 : un champ, une valeur ────────────────────────────────────────
http.response.status_code : 404                     # un code exact
http.response.status_code >= 500                    # toutes les erreurs serveur
http.response.status_code : (500 or 502 or 503 or 504)

# ── Niveau 2 : combiner ────────────────────────────────────────────────────
http.response.status_code >= 500 and url.path : "/api/*"
(http.request.method : (POST or PUT or DELETE)) and http.response.status_code >= 400
source.ip : "198.51.100.7" and not url.path : "/assets/*"
user_agent.name : "Chrome" and http.response.status_code : 200

# ── Niveau 3 : la base de tout comptage honnête ────────────────────────────
not url.path : ("/health" or "/server-status*")

# ── Niveau 4 : existence et absence de champ ───────────────────────────────
event.duration : *                 # la durée a bien été collectée
not event.duration : *             # révèle un problème de pipeline ou de format
error.message : *                  # DOIT rester vide
tags : "json_parse_failed"         # DOIT rester vide

# ── Niveau 5 : plages (event.duration est en NANOSECONDES) ─────────────────
event.duration > 1000000000                              # plus d'une seconde
event.duration >= 500000000 and event.duration <= 2000000000
http.response.body.bytes > 100000 and http.response.status_code : 200

# ── Niveau 6 : signature d'un scan ─────────────────────────────────────────
url.path : (*wp-login* or *xmlrpc* or *.env or *phpmyadmin*)
shopflow.status_class : "4xx" and source.ip : "192.0.2.0/24"

# ── Niveau 7 : sur le journal d'erreurs Apache ─────────────────────────────
#   (data view sur logs-apache.error-studentXX)
message : "AH00485"                      # scoreboard is full : saturation
message : "failed to make connection"    # backend injoignable
```

> **⚠️ Piège fréquent** — `event.duration` est en **nanosecondes** : une requête d'une seconde vaut `1000000000`. Chercher `event.duration > 1000` sélectionne tout ce qui dépasse une microseconde, c'est-à-dire tout — et fait conclure que « tout est lent ».

### Lire un document, en exploitant

```json
{
  "@timestamp": "2026-11-06T13:13:02.455Z",
  "event":    { "module": "apache", "dataset": "shopflow_apache.access_json",
                "duration": 4102311000, "outcome": "success" },
  "http":     { "request": { "method": "GET" },
                "response": { "status_code": 200, "body": { "bytes": 184320 } } },
  "url":      { "original": "/api/cart", "path": "/api/cart" },
  "source":   { "address": "203.0.113.45", "ip": "203.0.113.45" },
  "user_agent": { "name": "Chrome", "os": { "name": "Linux" } },
  "host":     { "name": "vm-studentXX" },
  "service":  { "name": "shopflow-web", "environment": "studentXX" },
  "shopflow": { "status_class": "2xx", "duration_us": 4102311 },
  "data_stream": { "type": "logs", "dataset": "shopflow_apache.access_json",
                   "namespace": "studentXX" }
}
```

> **À retenir** — Ce document est le cœur du métier : un statut **200** avec une durée de **4,1 secondes** et une réponse de 180 Ko. Aucun code d'erreur, aucune alerte de disponibilité — et pourtant l'utilisateur subit une page inutilisable. C'est la démonstration qu'un service « qui répond » n'est pas un service « qui fonctionne ».

**✅ Vérification de l'étape 5** — vous savez répondre, chiffre à l'appui : combien de requêtes sur la dernière heure hors sondes, quel pourcentage de 4xx et de 5xx, quelle est l'URL la plus lente, et combien de documents sont en erreur de parsing (zéro).

---

## Étape 6 — Montrer : le dashboard

### 6.1 Le dashboard de l'intégration

L'intégration Apache installe ses propres dashboards. Cherchez « Apache » dans **Dashboards**, ouvrez-en un, filtrez sur votre `host.name`. Ils sont utiles et gratuits — mais ils ne connaissent pas votre journal JSON, donc **aucune latence** n'y figure. C'est précisément la raison du dashboard suivant.

### 6.2 Votre dashboard Lens : partir des questions

| Ordre | Question que l'on se pose en situation réelle | Panneau qui y répond |
|---|---|---|
| 1 | Est-ce que ça va, maintenant ? | 5 indicateurs : requêtes, taux 5xx, taux 4xx, P95, P99 |
| 2 | Depuis quand est-ce anormal ? | Trafic par minute, empilé par famille de code |
| 3 | Qu'est-ce qui échoue ? | Répartition des codes, puis journal des 5xx |
| 4 | Est-ce lent, et pour quelles pages ? | P50/P95/P99 dans le temps, Top URL par P95 |
| 5 | Le serveur est-il saturé ? | Workers busy / idle dans le temps |
| 6 | Qui est concerné ? | Top 10 des IP clientes |

Les formules Lens à connaître — ce sont elles qui font la différence entre un graphique et une mesure :

```text
# Taux d'erreur 5xx : un RATIO, jamais un nombre absolu.
# 100 erreurs sur 1 000 requêtes est une catastrophe ;
# 100 erreurs sur 10 millions est un bruit de fond.
count(kql='http.response.status_code >= 500') / count() * 100

# Variante rigoureuse : le trafic de supervision sort AUSSI du dénominateur
count(kql='http.response.status_code >= 500 and not url.path : ("/health" or "/server-status*")')
  / count(kql='not url.path : ("/health" or "/server-status*")') * 100

# Latence P95, affichée en millisecondes (le champ est en nanosecondes)
percentile(event.duration, percentile=95) / 1000000

# P95 des seules routes d'API : le chiffre réellement pertinent pour le métier
percentile(event.duration, percentile=95, kql='url.path : "/api/*"') / 1000000

# Débit réel, par minute (et non ReqPerSec de mod_status)
count(kql='not url.path : ("/health" or "/server-status*")')
```

Les trois Top 10 d'URL, parce qu'un seul ne sert à rien :

| Tableau | Trié par | Question |
|---|---|---|
| URL par volume | `count()` | Où va le trafic ? Qu'est-ce qui mérite un cache ? |
| URL les plus lentes | `percentile(event.duration, 95)` | Quoi optimiser en priorité ? |
| URL en 404 | `count()` filtré sur 404 | Lien mort interne, ou scan externe ? |

> **⚠️ Piège fréquent** — Trois erreurs de construction qui rendent un dashboard flatteur et faux : laisser `/health` et `/server-status` dans le dénominateur (le taux d'erreur paraît excellent) ; calculer le P95 sur tout le trafic, ressources statiques incluses (des milliers de CSS servies en 2 ms diluent la mesure) ; utiliser `url.original` dans un Top 10 (les paramètres de requête créent des milliers de valeurs uniques — utilisez `url.path`).

> **À retenir** — L'écart entre P50 et P99 est une information en soi : il mesure la **variabilité** de l'expérience. P50 = 100 ms et P99 = 150 ms : service prévisible. P50 = 100 ms et P99 = 8 s : loterie — et c'est exactement ce que vos utilisateurs décrivent quand ils disent « c'est aléatoire ».

### 6.3 Les réglages qui font la différence

- Nommez le dashboard `apache-overview-studentXX` (convention obligatoire sur une plateforme mutualisée).
- Fixez les couleurs des familles de code : vert `2xx`, orange `4xx`, rouge `5xx`. En incident, la lecture doit être instantanée.
- Ajoutez des contrôles : `host.name`, `shopflow.status_class`, `user_agent.name`.
- Ajoutez un panneau Markdown : objectif, sources, **limites connues** (« le P95 exclut les ressources statiques »). Six mois plus tard, c'est ce texte qui évitera une mauvaise interprétation.
- Intégrez la recherche sauvegardée `erreurs-5xx-studentXX` (colonnes `@timestamp`, `url.path`, `http.response.status_code`, `event.duration`, `source.ip`) : elle hérite des filtres du dashboard, ce qui rend le passage de l'agrégat au détail immédiat.

**✅ Vérification de l'étape 6** — depuis le pic rouge du graphique de trafic, vous atteignez les lignes de log correspondantes **en trois clics**. Si ce chemin n'existe pas, le dashboard ne servira pas pendant un incident.

---

## Étape 7 — Alerter

Quatre règles, fournies par le générateur, à créer dans **Observability → Alerts → Manage rules**.

| Règle | Niveau | Fenêtre | Seuil | Réaction attendue |
|---|---|---|---|---|
| `taux-5xx-apache-studentXX` | 1 — impact | 5 min | > 5 % des requêtes `/api/`, minimum 20 requêtes | Astreinte |
| `pic-trafic-apache-studentXX` | 2 — symptôme | 5 min | > 1 500 requêtes, **à calibrer** | Ticket |
| `workers-reserve-basse-studentXX` | 3 — saturation | 10 min | `workers.idle` ≤ 2 en moyenne | Ticket |
| `apache-absent-studentXX` | 4 — observabilité | 10 min | moins de 5 documents | Alerte |

### 7.1 Les trois réglages qui évitent la fatigue d'alerte

1. **Le ratio, pas le nombre.** Un taux d'erreur se construit comme événements mauvais / événements éligibles. C'est déjà la définition d'un SLI (chapitre 5).
2. **Le garde-fou de volume.** Sans minimum d'événements, une seule erreur à 4 h du matin sur trois requêtes déclenche l'alerte. Chaque règle fondée sur un ratio porte un `WHERE total >= 20`.
3. **La fréquence d'action.** « À chaque exécution » sur une règle d'une minute envoie 60 messages par heure pour **un seul** problème. Réglez « au changement d'état » et configurez l'action de rétablissement : savoir qu'un problème est terminé a autant de valeur que savoir qu'il a commencé.

> **⚠️ Piège fréquent** — Alerter sur le CPU est l'erreur fondatrice de la fatigue d'alerte. Un CPU à 85 % peut être parfaitement sain — c'est même le signe d'une infrastructure bien dimensionnée. Et un service peut être totalement hors service avec un CPU à 5 %. Le CPU a sa place sur un dashboard, pas dans une notification nocturne.

### 7.2 La règle d'absence de données : construite à l'envers

Une alerte classique se déclenche quand une valeur dépasse un seuil. Celle-ci se déclenche quand **rien** n'arrive.

1. Mesurez d'abord, sur sept jours, le volume **minimal** observé par tranche de 10 minutes, nuit comprise.
2. Posez le seuil nettement sous ce minimum.
3. Prenez une fenêtre d'au moins trois fois la période de collecte, pour ne pas alerter sur un simple retard.
4. **Testez-la en coupant la source.** Une alerte d'absence de données jamais testée ne vaut rien : on ne sait pas si elle se déclencherait.

> **À retenir** — Cette règle est la plus souvent absente et la plus importante. Sans elle, une panne de votre chaîne d'observabilité vous rend aveugle **silencieusement** : les dashboards deviennent calmes, les autres alertes se taisent, et vous en concluez que tout va bien.

<!-- À VÉRIFIER : disponibilité du type de règle « Elasticsearch query » en variante ES|QL sur la 9.5.6 et sur la licence de la plateforme, et comportement de la fenêtre temporelle (si Kibana applique sa propre fenêtre, retirer la ligne `WHERE @timestamp > NOW() - N minutes` des requêtes fournies). Les connecteurs Slack, courriel et webhook relèvent d'une licence commerciale ; le connecteur Index est gratuit. -->

**✅ Vérification de l'étape 7** — pour chaque règle, vous avez mesuré deux délais : le **délai de détection** (début du problème → déclenchement) et le **délai d'extinction** (retour à la normale → état `recovered`). Et l'index d'alertes contient un nombre de documents cohérent avec le nombre d'incidents réels.

---

## Étape 8 — Les scénarios

C'est ici que le chapitre prend son sens. Pour chaque scénario : la commande, ce que vous devez observer, l'alerte attendue.

> **⚠️ Attention** — Tous ces scénarios ne se lancent que sur **votre** VM. Générer de la charge sur un système dont vous n'êtes pas responsable n'est pas un exercice, c'est une attaque.

### Scénario 1 — Montée en charge

```bash
./gen-trafic.sh http://localhost charge
# équivalent manuel, palier par palier :
#   ab -n 400  -c 10 http://localhost/catalogue.html
#   ab -n 1200 -c 30 http://localhost/catalogue.html
#   ab -n 2400 -c 60 http://localhost/catalogue.html
```

| Ce qu'on observe | Où | Lecture |
|---|---|---|
| `workers.busy` monte, `workers.idle` fond | Dashboard, courbe workers | Charge réelle de traitement |
| Débit (requêtes/min) croît avec la concurrence | Panneau trafic | Le serveur absorbe |
| P95 stable ou en hausse proportionnelle | Courbe percentiles | Montée en charge **saine** |
| Débit qui **plafonne** alors que la demande monte, P95 qui explose, 503, `AH00485` | Tous | **Saturation** |

**Alerte attendue** : `pic-trafic` au palier 60, éventuellement `workers-reserve-basse`.

> **À retenir** — Le signe décisif de la saturation n'est ni le CPU ni le nombre de workers occupés : c'est le **plafonnement du débit alors que la demande augmente**, accompagné d'une explosion de la latence. Un serveur à 90 % de workers occupés qui tient son débit fonctionne bien. Un serveur à 60 % de workers occupés dont le débit s'effondre a un problème **ailleurs** — très souvent dans le backend.

Lire la sortie d'ApacheBench :

```text
Concurrency Level:      30
Time taken for tests:   4.218 s
Complete requests:      1200
Failed requests:        0           # toute valeur > 0 est à expliquer
Requests per second:    284.5 [#/sec]        # le DÉBIT obtenu
Percentage of the requests served within a certain time (ms)
  50%     92        # P50
  95%    204        # c'est CETTE valeur que l'on compare à un objectif
  99%    511
```

ApacheBench mesure depuis le client ; votre journal mesure depuis le serveur. L'écart, c'est le réseau et la mise en file d'attente. Comparer les deux est ce qui apprend **où** le temps est perdu.

### Scénario 2 — Flood de 404

```bash
./gen-trafic.sh http://localhost flood404
```

| Ce qu'on observe | Lecture |
|---|---|
| Pic orange (`4xx`) sur le graphique de trafic | Erreurs clientes, pas de défaillance du service |
| Top 10 des 404 : `/wp-login.php`, `/xmlrpc.php`, `/.git/config` | ShopFlow est en Java : ce sont des **scans**, pas des liens morts |
| Une IP, beaucoup d'URL distinctes, beaucoup de 404 | Signature d'un scanner, pas d'un client |
| `/.env` renvoie **403** | Bonne nouvelle : la règle de refus fonctionne |
| Le taux de **5xx** ne bouge pas | Les 404 ne doivent pas compter comme un échec de service |

**Alerte attendue** : **aucune**. Et c'est le point de l'exercice. Si votre règle de taux d'erreur se déclenche sur un flood de 404, elle est mal construite : elle compte les 4xx.

### Scénario 3 — Erreurs 500

```bash
./gen-trafic.sh http://localhost erreurs 90
```

| Ce qu'on observe | Où |
|---|---|
| Taux de 5xx qui dépasse 5 % | Indicateur chiffré du dashboard |
| Les lignes correspondantes dans `logs-apache.error-studentXX` | Même seconde, cause immédiate |
| `AH01114: failed to make connection to backend` | Si la cible est `/api/` sans Tomcat derrière |

**Alerte attendue** : `taux-5xx-apache-studentXX`, en moins de 2 minutes.

> **À retenir** — `access.log` donne le symptôme et son ampleur ; `error.log` donne la cause immédiate. On les lit **ensemble**. Et 502, 503, 504 désignent trois problèmes différents : backend qui répond n'importe quoi, plus aucune ressource disponible, backend trop lent. Trois diagnostics, trois actions.

### Scénario 4 — Requêtes lentes, sans aucune erreur

```bash
./gen-trafic.sh http://localhost lenteur
```

| Ce qu'on observe | Lecture |
|---|---|
| P95 et P99 qui montent, P50 stable | Une **minorité** de requêtes est touchée |
| Aucun code d'erreur, aucune alerte de disponibilité | Le service « répond » |
| `/api/lent` en tête du Top 10 par P95 | La route responsable est identifiée |

**Alerte attendue** : **aucune** avec les quatre règles de ce chapitre. C'est volontaire : la détection de la lenteur passe par un objectif de latence, donc par un SLO (chapitre 5).

### Scénario 5 — Arrêt d'Apache

```bash
./gen-trafic.sh http://localhost arret      # stop 180 s, puis start
```

| Ce qu'on observe | Lecture |
|---|---|
| Tous les panneaux deviennent **vides et calmes** | Le piège le plus dangereux de l'observabilité |
| Taux de 5xx = 0 % | Il n'y a plus de requête du tout : 0/0 |
| L'agent reste `Healthy` | Il va bien : c'est la **source** qui s'est tue |
| `metrics-apache.status` s'arrête aussi | `mod_status` n'est plus joignable |

**Alerte attendue** : `apache-absent-studentXX`, dans les 10 à 12 minutes. Notez le délai réel : c'est votre MTTD sur cette panne.

### Tableau de synthèse des scénarios

| Scénario | Commande | Signature | Alerte |
|---|---|---|---|
| Montée en charge | `gen-trafic.sh … charge` | Réserve de workers qui fond, débit qui plafonne | `pic-trafic`, `workers-reserve-basse` |
| Flood de 404 | `gen-trafic.sh … flood404` | Pic de `4xx`, URL de scan, 5xx inchangé | **aucune** (test de non-régression) |
| Erreurs 500 | `gen-trafic.sh … erreurs` | Taux de 5xx > 5 %, `error.log` parlant | `taux-5xx` |
| Lenteur | `gen-trafic.sh … lenteur` | P95/P99 qui montent, P50 stable, zéro erreur | **aucune** → il faut un SLO |
| Arrêt d'Apache | `gen-trafic.sh … arret` | Tout devient calme | `apache-absent` |

---

## Dépannage

| Symptôme | Cause la plus probable | Correction |
|---|---|---|
| Aucun document Apache dans Discover | Mauvaise fenêtre temporelle, mauvais motif de data view, ou mauvais namespace | Élargir à 24 h ; comparer le nom exact du data stream dans Index Management |
| Agent `degraded` juste après l'installation | Chemin de journal inexistant, ou droit de lecture manquant | `elastic-agent status --output=full` donne l'unité fautive et son message |
| `x509: certificate signed by unknown authority` | CA interne absente de la machine ou chemin erroné | Déposer la CA, vérifier le chemin, contrôler la date de la VM (`timedatectl`) |
| Erreurs 401 / 403 dans les logs de l'agent | Clé d'API de l'output invalide ou révoquée | Opération formateur : régénérer l'output dans Fleet → Settings |
| Documents présents mais `event.duration` absent | Journal JSON non collecté, ou pipeline mal **nommé** | Le nom doit être exactement `logs-shopflow_apache.access_json@custom` |
| Percentiles absurdes | Erreur d'unité (µs stockées comme ns) | Vérifier la multiplication par 1 000 ; comparer à `curl -w "%{time_total}"` |
| Beaucoup de documents avec `error.message` | Format de journal non reconnu par le pipeline | Tester avec `_simulate` sur une ligne réelle avant d'ingérer |
| `/server-status` renvoie 404 | Module ou configuration non activés | `a2enmod status`, `a2enconf server-status`, `configtest`, `reload` |
| Métriques présentes mais pas de scoreboard | `ExtendedStatus` désactivé | Le déclarer explicitement et recharger |
| Trous réguliers dans les données, chaque nuit | Rotation sans `delaycompress` | Rétablir l'option, vérifier avec `logrotate -f` |
| Impossible de faire un Top 10 des URL | Champ de type `text` | Utiliser `url.path`, ou le sous-champ `.keyword` |
| Le taux d'erreur semble anormalement bas | Sondes de supervision dans le dénominateur | Les exclure du numérateur **et** du dénominateur |

### Nettoyage de fin de chapitre

```bash
./nettoyage.sh
```

Il rétablit Apache, vérifie l'agent, force une rotation des journaux locaux. Dans Kibana, en fin de formation : **désactivez vos règles d'alerte** (une règle oubliée continue de s'exécuter indéfiniment sur le cluster partagé) et conservez vos dashboards, qui font partie de vos livrables. Ne désinstallez pas l'agent : les chapitres 2 à 4 s'appuient dessus.

---

## Livrables du chapitre

1. Les quatre fichiers de configuration, commentés, tels que posés sur votre VM.
2. La réponse de `_simulate` montrant `event.duration` en nanosecondes.
3. La preuve du refus d'accès distant à `/server-status` (code HTTP).
4. Une capture de Discover avec les colonnes `@timestamp`, `url.path`, `http.response.status_code`, `event.duration`.
5. Le dashboard `apache-overview-studentXX` et les formules utilisées.
6. Les quatre règles d'alerte, avec les délais de détection et d'extinction **mesurés**.
7. Le tableau des cinq scénarios : ce que vous avez observé, et quelle alerte s'est déclenchée — ou pourquoi aucune.

> **À retenir** — Deux scénarios sur cinq ne déclenchent **aucune** alerte, volontairement. Savoir expliquer pourquoi vaut mieux que d'avoir vingt règles qui sonnent pour rien.

---

**➡️ Chapitre suivant** : Tomcat — journaux applicatifs, JVM et pannes mémoire.
