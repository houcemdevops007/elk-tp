# TP Elastic Observability — Apache, Tomcat, Kubernetes

Supports de travaux pratiques et **tous les fichiers nécessaires aux TP** : configurations,
manifestes Kubernetes, scripts de scénario, règles d'alerte, requêtes ES\|QL et générateurs
de configuration.

Support de TP pour la plateforme EFILearn. Condensé d'un manuel de 24 chapitres en **une introduction et cinq chapitres**, centrés sur ce que le candidat doit savoir **faire** : collecter les logs et les métriques d'Apache, de Tomcat et de Kubernetes, les lire, alerter, puis diagnostiquer une panne qu'on ne lui a pas annoncée.

Fil rouge : la boutique fictive **ShopFlow**, éditée par la société fictive **NovaCommerce**.

## 1. Plan

| Page | Contenu | Durée | Mots |
|---|---|---|---|
| `00-introduction.md` | Architecture EFI en détail, rôle de chaque composant, data streams, ECS, ILM, parcours d'une donnée, vérification d'accès | 1 h 30 | ~4 000 |
| `01-apache/chapitre.md` | Logs et métriques Apache : journal JSON avec durée, `mod_status`, agent, KQL, dashboard, 4 alertes, 5 scénarios | 3 h 00 | ~6 100 |
| `02-tomcat/chapitre.md` | Journaux Tomcat, multiligne, piège d'unité, WAR ShopFlow, JVM, 3 scénarios | 2 h 30 | ~4 700 |
| `03-kubernetes/chapitre.md` | k3s : DaemonSet, kube-state-metrics, tableau de diagnostic, 6 pannes | 3 h 00 | ~5 200 |
| `04-projet-final/` | Projet noté sur 100 : ShopFlow 3 tiers, SLO, alertes, incident non annoncé | 4 h 00 | ~5 300 |
| `05-sre-incident/chapitre.md` | SLI, SLO, SLA, error budget, burn rate, gravité, postmortem | 1 h 30 | ~2 800 |

**Volume : environ 14 heures de formation, ~28 000 mots.**

## 2. Arborescence

```text
tp-elk/                           (racine de ce dépôt)
├── README.md                     ce fichier
├── LICENSE
├── page-principale.md            page d'accueil du tutoriel sur EFIlearn
├── 00-introduction.md            architecture + concepts + verification d'acces
├── 00-introduction.mermaid-1.svg diagramme d'architecture pre-rendu
├── .yamllint                     configuration de validation YAML
│
├── 01-apache/
│   ├── chapitre.md
│   ├── configs/                  shopflow-logs.conf, server-status.conf,
│   │                             shopflow-vhost.conf, logrotate-apache,
│   │                             pipeline-access-json.json, pipeline-simulate.json
│   ├── scripts/                  parcours.sh, install-agent.sh, gen-trafic.sh,
│   │                             verif-ingestion.sh, nettoyage.sh
│   ├── alertes/                  4 regles (5xx, pic de trafic, absence de
│   │                             donnees, reserve de workers)
│   ├── generateur.json           declaration du generateur
│   └── generateur.html           GENERATEUR AUTONOME (a integrer dans EFILearn)
│
├── 02-tomcat/
│   ├── chapitre.md
│   ├── app/                      ShopFlowServlet.java, web.xml,
│   │                             build-war.sh, deploy-war.sh
│   ├── configs/                  server-xml-host.xml, setenv.sh,
│   │                             logging.properties.extrait, logrotate-tomcat,
│   │                             custom-logs-multiline.yml, jolokia-mappings.yml,
│   │                             logback.xml, 3 pipelines JSON
│   ├── scripts/                  parcours.sh, verif-tomcat.sh,
│   │                             scenario-fuite.sh, scenario-lenteur.sh,
│   │                             scenario-deploiement.sh
│   ├── alertes/                  4 regles (heap, latence, OOM, deploiement)
│   ├── generateur.json
│   └── generateur.html
│
├── 03-kubernetes/
│   ├── chapitre.md
│   ├── manifests/                namespace+quota, kube-state-metrics,
│   │                             elastic-agent DaemonSet, application de demo
│   ├── scenarios/                6 manifestes de panne
│   ├── scripts/                  parcours.sh, verif-k8s.sh, reset.sh
│   ├── alertes/                  4 regles (redemarrages, pods non prets,
│   │                             OOMKilled, noeud sous pression + throttling)
│   ├── generateur.json
│   └── generateur.html
│
├── 04-projet-final/
│   ├── enonce.md                 l'enonce remis au candidat
│   ├── enonce.mermaid-1.svg      diagramme des 3 tiers, pre-rendu
│   ├── grille.md                 grille de notation /100 (a communiquer AVANT)
│   ├── corrige.md                CORRIGE FORMATEUR - a masquer
│   ├── manifests/                3 tiers : configmaps, secret, postgres,
│   │                             tomcat, apache, build-configmap-war.sh
│   ├── incidents/                charge.sh + 3 incidents a injecter
│   ├── requetes/                 slo.esql : 3 SLO + controle de couverture
│   ├── alertes/                  3 regles (burn rate, cascade, base injoignable)
│   ├── generateur.json
│   └── generateur.html
│
├── 05-sre-incident/
│   ├── chapitre.md
│   ├── requetes/                 error-budget.esql : 6 requetes
│   ├── alertes/                  burn-rate-double-fenetre.json
│   ├── modeles/                  fiche-slo.md, rapport-incident.md
│   ├── generateur.json
│   └── generateur.html
│
└── tools/
    ├── plateforme.json           VALEURS FIXES de la plateforme EFI
    ├── generateur.tpl.html        gabarit commun aux 5 generateurs
    ├── build-generateurs.py       construit les generateur.html
    ├── render-exemple.py          rend les fichiers avec des valeurs concretes
    ├── mermaid-to-svg.cjs         pre-rend les diagrammes Mermaid en SVG
    ├── verifier-acces-kibana.sh   ADMIN : diagnostique l'acces a Kibana
    └── ajouter-custom-logs.py     ADMIN : replique l'integration Custom Logs
                                   sur les 20 politiques efi-studentNN-apache

Publication (dans le depot principal) :
    scripts/tutorials/md_to_tiptap.py              Markdown -> TipTap
    scripts/tutorials/push_elk_condense_tutorial.py  publication via l'API
```

## 3. Les générateurs de configuration

Chaque chapitre a un fichier **`generateur.html` autonome** : HTML, CSS et JavaScript vanilla, **aucune dépendance externe, aucun appel réseau, aucune donnée enregistrée** (ni cookie, ni stockage local). Le candidat saisit les paramètres de sa VM, clique sur **Générer**, et obtient ses fichiers de configuration et ses commandes, avec coloration, bouton **Copier** et bouton **Télécharger** pour chacun.

| Générateur | Champs | Produit |
|---|---|---|
| `01-apache` | n° étudiant, hôte, IP, `ServerName`, répertoire des logs, CA, port et contexte Tomcat, token, clé d'API | 10 fichiers + 5 blocs de commandes |
| `02-tomcat` | `CATALINA_HOME`, répertoire des logs, compte système, ports, contexte, heap, JMX, Jolokia, fuseau | 16 fichiers + 7 blocs |
| `03-kubernetes` | cluster k3s, kubeconfig, nœud, image de démo, version de kube-state-metrics, CA, token k8s | 14 fichiers + 3 blocs |
| `04-projet-final` | NodePort, contexte, heap, tags d'images, version PostgreSQL, StorageClass, mot de passe de la base | 9 fichiers + 5 blocs |
| `05-sre-incident` | service, data stream, périmètre, objectif de SLO, fenêtre, seuils de latence | 4 fichiers |

### Une seule source de vérité

Les fichiers de `configs/`, `manifests/`, `scripts/` et `alertes/` contiennent des placeholders `{{MAJUSCULES}}`. Le script de construction **lit ces fichiers tels quels** et les injecte dans le gabarit commun. Un générateur ne peut donc **jamais** divergir du fichier publié dans le chapitre.

```bash
# Reconstruire les cinq générateurs après toute modification d'un fichier de config
python3 tools/build-generateurs.py

# Un seul chapitre
python3 tools/build-generateurs.py 03-kubernetes
```

Les valeurs fixes de la plateforme (IP, ports, version **9.5.5**, nom du cluster) sont centralisées dans `tools/plateforme.json` : **un seul endroit à modifier** si la plateforme change.

### Vérifier avant publication

Les fichiers du dépôt contiennent des placeholders : ils ne sont donc pas directement validables. Le script `render-exemple.py` applique la même substitution que le générateur, avec des valeurs d'exemple, et écrit le résultat dans `.rendu/`.

```bash
python3 tools/render-exemple.py                       # tous les chapitres
yamllint -c .yamllint .rendu/*/manifests/*.yaml .rendu/*/scenarios/*.yaml .rendu/*/configs/*.yml
for f in .rendu/*/manifests/*.yaml .rendu/*/scenarios/*.yaml; do kubectl apply --dry-run=client -f "$f"; done
for f in .rendu/*/scripts/*.sh .rendu/*/incidents/*.sh .rendu/*/app/*.sh; do bash -n "$f"; done
```

## 4. Publier le tutoriel dans EFIlearn

La publication est scriptée. Les deux scripts vivent dans le dépôt **EFIlearn**, sous
`scripts/tutorials/`, car ils s'appuient sur son DSL maison (`tiptap.py`) et sur sa logique
d'appel d'API (`push_common.py`) :

| Script | Rôle |
|---|---|
| `md_to_tiptap.py` | Convertit les pages Markdown de CE dépôt en contenu TipTap |
| `push_elk_condense_tutorial.py` | Crée les 14 pages du tutoriel via l'API EFIlearn |

Le second attend le contenu dans `tuto-elk-condense/`, à la racine du dépôt EFIlearn :
clonez ce dépôt-ci à cet emplacement, ou ajustez la constante `RACINE` du script.

```bash
cd <depot-efilearn>/scripts/tutorials

# 1. Aperçu local, aucun appel API : produit elk_condense_tutorial_preview.json
python3 push_elk_condense_tutorial.py --dry-run

# 2. Publication en brouillon non visible (recommandé pour une première fois)
python3 push_elk_condense_tutorial.py --user-id <votre-uuid> --draft

# 3. Mise à jour après correction d'un .md (conserve les pages et leur id)
python3 push_elk_condense_tutorial.py --user-id <votre-uuid> --update
```

Le contenu vient **des fichiers Markdown de ce dépôt** : il n'existe qu'une source de vérité. Toute correction se fait dans le `.md`, puis `--update`.

### Les 14 pages créées

| Page | Source |
|---|---|
| 🔭 Elastic Observability — manuel de TP condensé | `page-principale.md` |
| 🏗️ Introduction — l'architecture en détail | `00-introduction.md` |
| 📄 Chapitre 1 — Logs et métriques Apache | `01-apache/chapitre.md` |
| 🧰 Générateur — Chapitre 1 | `01-apache/generateur.html` |
| ☕ Chapitre 2 — Tomcat : journaux et JVM | `02-tomcat/chapitre.md` |
| 🧰 Générateur — Chapitre 2 | `02-tomcat/generateur.html` |
| ☸️ Chapitre 3 — Kubernetes (k3s) | `03-kubernetes/chapitre.md` |
| 🧰 Générateur — Chapitre 3 | `03-kubernetes/generateur.html` |
| 🏁 Chapitre 4 — Projet final | `04-projet-final/enonce.md` |
| 🧰 Générateur — Chapitre 4 | `04-projet-final/generateur.html` |
| 📊 Grille d'évaluation du projet final | `04-projet-final/grille.md` |
| 🎯 Chapitre 5 — SRE et gestion d'incident | `05-sre-incident/chapitre.md` |
| 🧰 Générateur — Chapitre 5 | `05-sre-incident/generateur.html` |
| 🔑 Corrigé formateur — projet final | `04-projet-final/corrige.md` |

`--generateurs inline` place chaque générateur **à la fin de son chapitre** plutôt que sur une page dédiée ; `--generateurs aucun` ne publie que le texte.

### Pourquoi les générateurs passent par une iframe

Mesuré dans Chromium, sur un rendu identique à celui de la page publique :

| Voie | Résultat |
|---|---|
| HTML du générateur collé **directement** dans un bloc HTML | **Inutilisable** : le CSS s'applique, mais le `<script>` n'est **jamais** exécuté — 0 champ affiché |
| Générateur encapsulé dans une **iframe `srcdoc`** | **Fonctionne** : formulaire rendu, validation active, génération complète, bouton « Copier » opérationnel |

La raison est dans le code de la plateforme : `HtmlBlockView.jsx` rend le bloc avec `dangerouslySetInnerHTML`, et le HTML inséré par `innerHTML` n'exécute jamais ses balises `<script>` — c'est une règle du langage, pas un filtrage. Une iframe, elle, fait analyser son document par le navigateur : le script s'y exécute normalement.

Le bac à sable de l'iframe n'autorise que le nécessaire : `allow-scripts` (faire fonctionner le générateur), `allow-downloads` (bouton Télécharger), `allow-same-origin` (API presse-papier du bouton Copier, qui dispose par ailleurs d'une solution de repli).

### Les diagrammes Mermaid

Le frontend ne charge pas Mermaid : un bloc ` ```mermaid ` s'afficherait en code source. Les diagrammes sont donc **pré-rendus en SVG**, qui s'affiche nativement dans l'éditeur, sur la page publique et dans les exports.

```bash
# Prérequis, une seule fois :  npm install mermaid playwright
node tools/mermaid-to-svg.cjs 00-introduction.md 04-projet-final/enonce.md
```

Le Markdown reste la source : le SVG est déposé à côté (`<page>.mermaid-<n>.svg`) et repris automatiquement par le script de publication, qui retombe sur le bloc de code si le SVG est absent.

### Après la publication — trois gestes dans l'éditeur

1. Passer **« 🔑 Corrigé formateur — projet final »** en **brouillon non visible** : il contient la nature des trois incidents.
2. Laisser **« 📊 Grille d'évaluation »** visible : une grille connue à l'avance oriente le travail vers ce qui compte.
3. Vérifier qu'un générateur s'affiche bien et réagit au clic sur **Générer** (navigateur d'entreprise : certains bloquent les cadres intégrés — le repli est alors de distribuer le fichier `generateur.html`, qui s'ouvre seul dans un onglet).

## 5. Outil d'administration : ajouter Custom Logs aux 20 politiques

Les politiques `efi-studentNN-apache` de la plateforme ne portent que deux intégrations
(Apache HTTP Server et System). Il en faut une **troisième**, sur le journal JSON — c'est
elle qui apporte la durée des requêtes. `tools/ajouter-custom-logs.py` la réplique sur les
vingt politiques.

Le script ne **fabrique** pas la configuration, il la **clone** : vous créez l'intégration
une fois à la main, proprement, sur une politique de référence, et il la réplique en
changeant le nom, la politique cible et l'espace de nom. On évite ainsi de dépendre d'un
format de corps de requête qui change d'une version de Fleet à l'autre.

**Étape 1 — créer le modèle à la main**, dans Kibana → Fleet → `efi-student01-apache` →
Ajouter une intégration → **Custom Logs (Filestream)** — et non *Custom Logs (Deprecated)* :

| Paramètre | Valeur |
|---|---|
| Intégration | **Custom Logs (Filestream)** — le formulaire s'intitule *Custom Filestream Logs* |
| Nom | `custom-logs-efi-student01-apache` |
| Espace de nom | `student01` — **le réglage le plus important** |
| Paths | `/var/log/apache2/access_json.log` |
| Use the « logs.ecs » data stream | **désactivé** (sinon dataset et pipeline sont ignorés) |
| Dataset name | `shopflow_apache.access_json` |
| Créer un modèle d'index dédié | activé |
| Parsers | laisser vide : le JSON est parsé par le pipeline, pas par l'agent |
| Ingest Pipeline | à laisser vide d'abord, puis à renseigner seulement si `event.duration` est absent (voir chapitre 1, § 3.3) |
| Sortie | `efi-elasticsearch` |

**Étape 2 — où exécuter le script.** Il n'a besoin que de trois choses : Python 3, la CA
interne, et un accès HTTPS à **Kibana** (port 5601 — pas Elasticsearch).

| Machine | Convient ? |
|---|---|
| Votre poste d'administration, là où vous avez cloné ce dépôt | **Oui, le plus simple** — vérifiez la route vers `172.16.3.53:5601` |
| `elk-kibana0` (172.16.3.53) | Oui — accès garanti, mais il faut y copier le script |
| Une VM de candidat `studentNN` | **Non** — le script exige des droits d'administration sur Fleet, qu'un candidat ne doit pas avoir |

Test d'accès avant toute chose :

```bash
./tools/verifier-acces-kibana.sh https://172.16.3.53:5601 ~/efi-elk-platform/pki/ca.crt
```

Le script déroule les causes dans l'ordre — fichier de CA, port, TLS, validation du
certificat — et conclut. Il existe parce que `curl -s` **masque ses erreurs** : une
commande qui ne renvoie rien peut aussi bien signifier « CA introuvable » que « port
fermé », et on ne peut pas le deviner.

Si le port direct n'est pas routé depuis votre poste, passez par le reverse proxy en
incluant le chemin de base : `--kibana https://elk.efi-academy.com/tp`.

**Étape 3 — obtenir la clé d'API Kibana.** Dans Kibana, connecté avec un compte
**administrateur** : **Stack Management → Security → API keys → Create API key**.

| Champ | Valeur |
|---|---|
| Nom | `fleet-custom-logs` |
| Contrôler les privilèges de sécurité | **laissé désactivé** — la clé hérite alors des droits de votre compte, ce qui évite d'écrire un descripteur de rôle |
| Expiration | quelques jours suffisent |

Copiez la valeur **Encoded** (base64) : c'est elle qu'attend l'en-tête `Authorization: ApiKey`.
Elle n'est affichée **qu'une fois**.

Vérifiez-la avant de lancer le script :

```bash
curl -s --cacert ~/efi-elk-platform/pki/ca.crt -H "Authorization: ApiKey $KIBANA_API_KEY" -H 'kbn-xsrf: true' "https://172.16.3.53:5601/api/fleet/agent_policies?perPage=1"
```

Du JSON contenant `items` : c'est bon. `401` : ce n'est pas la valeur *Encoded*. `403` :
le compte n'a pas les droits Fleet. Sans clé d'API, le script accepte
`--utilisateur` et `--mot-de-passe`.

**Étape 4 — répliquer.** Le script simule par défaut : rien n'est écrit sans `--appliquer`.

```bash
export KIBANA_API_KEY='<cle-api-avec-droits-fleet>'
python3 tools/ajouter-custom-logs.py --cacert ~/efi-elk-platform/pki/ca.crt --simuler
```

```bash
python3 tools/ajouter-custom-logs.py --cacert ~/efi-elk-platform/pki/ca.crt --appliquer
```

| Garde-fou | Comportement |
|---|---|
| Simulation par défaut | Affiche ce qui serait créé, n'écrit rien |
| Idempotence | Une politique qui a déjà l'intégration est ignorée, pas dupliquée |
| Politique de référence | Jamais modifiée |
| Politique absente | Signalée, le script continue |
| Champs en lecture seule | `id`, `revision`, `created_at`… retirés avant envoi, sinon Fleet refuse |
| Espace de nom | Ajusté au candidat **et** dans chaque flux de l'intégration |

Options : `--kibana`, `--cacert` (CA interne), `--reference`, `--motif`, `--de`/`--a`,
`--utilisateur`/`--mot-de-passe` si vous n'avez pas de clé d'API, `--insecure` en lab fermé.

Après application, les agents déjà enrôlés reçoivent la nouvelle révision en quelques
secondes, sans réinstallation. Vérification :

```bash
curl -s --cacert /etc/efi/pki/ca.crt -H "Authorization: ApiKey $ES_API_KEY" "https://172.16.3.50:9200/logs-shopflow_apache.access_json-student01/_count?pretty"
```

## 6. Ce que le formateur doit préparer

| Élément | Détail |
|---|---|
| Politiques d'agent | Trois par candidat : `efi-studentXX-apache`, `efi-studentXX-tomcat`, `efi-studentXX-k8s` — espace de nom `studentXX`, sortie `efi-elasticsearch` |
| **Intégration Custom Logs (Filestream)** | À ajouter à chaque `efi-studentXX-apache` : `/var/log/apache2/access_json.log`, dataset `shopflow_apache.access_json`. **C'est elle qui apporte la durée des requêtes** — sans elle, pas de percentiles ni de SLO de latence |
| Un agent, une politique | Apache et Tomcat sur la même VM : les intégrations Tomcat s'ajoutent à `efi-studentXX-apache`. `efi-studentXX-tomcat` ne sert que si le backend a sa propre VM |
| Tokens d'enrôlement | Un par politique, transmis **individuellement** |
| Espaces Kibana | Un espace `studentXX` par candidat |
| Clés d'API | Une par candidat, restreinte à ses data streams |
| CA interne — poste d'administration | `~/efi-elk-platform/pki/ca.crt` sur l'hôte `Infra` (vérifié) : c'est celle qu'utilisent les scripts `tools/` |
| CA interne — VM des candidats | **À déployer sur chaque VM** et à reporter dans le champ « Autorité de certification » des générateurs. Sans elle, l'enrôlement de l'agent échoue sur `x509: certificate signed by unknown authority` |
| VM | Apache, Tomcat, k3s, JDK (`javac`), au moins 4 Go de RAM |
| Images conteneur | `httpd`, `tomcat`, `postgres`, `busybox`, `kube-state-metrics`, `elastic-agent` pré-chargées ou miroir interne |
| Agent Jolokia | `jolokia-jvm-agent.jar` déposé sur les VM (sinon, voie de repli `jcmd`/`jstat` documentée) |
| Licence | Niveau relevé et communiqué : il conditionne les SLO natifs et plusieurs connecteurs d'alerte |
| Rétention ILM | Vérifiée : les SLO du projet portent sur 7 jours |

## 7. Points marqués à vérifier

Le support signale par un commentaire `<!-- À VÉRIFIER -->` chaque point qui dépend de la version ou de la licence réellement installées, plutôt que d'affirmer une valeur. Les principaux :

| Point | Où | Pourquoi |
|---|---|---|
| Existence de l'artefact `elastic-agent-9.5.5-linux-x86_64.tar.gz` | ch. 1 | La version doit être relevée dans Kibana |
| Périmètre de l'intégration **Apache Tomcat**, et dépendance à Jolokia pour les métriques | ch. 2 | Voie de repli Custom Logs + Jolokia fournie |
| Noms des options de l'intégration **Jolokia** (`jmx.mappings`) | ch. 2 | À comparer avec l'interface de Fleet |
| Activation des **hints d'autodiscover** (`co.elastic.logs/*`) | ch. 3 et 4 | Réglage côté agent, opération formateur |
| Nom du champ de **throttling CPU** et casse des valeurs de `phase` | ch. 3 | À relever dans Discover avant toute règle |
| Type de règle **« Elasticsearch query » en variante ES\|QL** et gestion de la fenêtre temporelle | tous | Si Kibana applique sa propre fenêtre, retirer la clause `WHERE @timestamp` |
| **SLO natifs** et connecteurs d'alerte sous licence commerciale | ch. 4 et 5 | Voie de repli ES\|QL + connecteur Index fournie partout |

---

**Khlifi Houcem — Formateur DevSecOps et Cloud** · Plateforme **EFILearn**
