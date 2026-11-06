# Corrigé formateur — Projet final ShopFlow

> **⚠️ PAGE FORMATEUR — à passer en brouillon non visible dans l'éditeur EFILearn avant d'ouvrir le tutoriel à une promotion.** Elle contient les réponses, la nature des trois incidents et les réponses attendues aux questions de diagnostic.

## 1. Préparation de la session

| Élément | À faire | Quand |
|---|---|---|
| Politiques d'agent | Déjà créées : `efi-studentXX-apache`, `efi-studentXX-tomcat` et `efi-studentXX-k8s`, espace de nom `studentXX`, sortie `efi-elasticsearch` | Fait |
| **Troisième intégration Apache** | Ajouter **Custom Logs (Filestream)**, et non la version dépréciée (`/var/log/apache2/access_json.log`, dataset `shopflow_apache.access_json`) à chaque `efi-studentXX-apache`. **Sans elle, aucune mesure de latence n'est possible** : ni percentiles, ni scénario « requêtes lentes », ni SLO de latence du projet | **Avant J1** |
| Intégrations Tomcat | Un agent n'appartient qu'à une politique : sur une VM unique, les ajouter à `efi-studentXX-apache` et non à `efi-studentXX-tomcat`, qui ne sert qu'au cas d'une VM dédiée | Avant J2 |
| Tokens d'enrôlement | Un par politique, transmis **individuellement** | Avant J1 |
| Espaces Kibana | Un espace `studentXX` par candidat | Avant J1 |
| Clés d'API | Une par candidat, restreinte à ses data streams | Avant J1 |
| Intégrations | Vérifier au catalogue : Apache HTTP Server, System, Custom Logs, Kubernetes, PostgreSQL, Jolokia, Apache Tomcat | Avant J1 |
| Licence | Relever le niveau et le communiquer : il conditionne les SLO natifs et les connecteurs d'alerte | Avant J1 |
| Images | Pré-charger `httpd`, `tomcat`, `postgres`, `busybox`, `kube-state-metrics`, `elastic-agent` sur les VM, ou fournir un miroir | Avant J4 |
| CA interne | Déposer `/etc/efi/pki/ca.crt` sur chaque VM | Avant J1 |
| Rétention ILM | Vérifier qu'elle couvre la durée de la formation ; sinon prévenir que les SLO sur 7 jours porteront sur moins de données | Avant J1 |
| Cette page et le corrigé | Passer en brouillon non visible | Avant J1 |

> **Point de vigilance** — Les SLO du projet sont calculés sur **7 jours**. Si la formation dure deux jours, la fenêtre réelle est de deux jours : faites-le dire explicitement aux candidats plutôt que de les laisser annoncer un chiffre sur une fenêtre qu'ils n'ont pas. C'est exactement le genre d'honnêteté de mesure que le projet évalue.

## 2. Les trois incidents : mécanisme, signature, réponses attendues

Déclenchez **un seul** incident par candidat ou par binôme, sans annoncer lequel. Les trois sont réversibles et ne détruisent aucune donnée.

### Incident 1 — Base de données indisponible

`./incidents/01-db-indisponible.sh 600` — le StatefulSet est réduit à zéro réplica.

| Tier | Signature attendue |
|---|---|
| 1 — frontal | `/health` répond **toujours 200** (il ne traverse pas le backend) ; `/api/*` renvoie des **503** ; la latence **BAISSE** |
| 2 — backend | `log.level: ERROR`, message « base de donnees injoignable » ; le pod reste **Ready** |
| 3 — base | Zéro pod, event « Scaled down », **aucune** erreur applicative |

**Cause racine attendue, en une phrase** : le StatefulSet de la base a été réduit à zéro réplica ; le backend ne peut plus ouvrir de connexion TCP vers `shopflow-db:5432` et renvoie 503, que le frontal propage.

**Les trois questions de diagnostic, et leurs réponses :**

1. *Pourquoi la latence BAISSE-t-elle pendant une panne ?* Parce qu'un échec rapide est plus rapide qu'un succès : le backend renvoie 503 en quelques millisecondes au lieu de traiter la requête. Conséquence opérationnelle : **une alerte fondée sur la seule latence ne verrait rien**. C'est la démonstration qu'il faut un SLO de disponibilité **et** un SLO de latence.
2. *Pourquoi le pod du backend reste-t-il `Ready` ?* Parce que sa readiness probe interroge `/health`, qui ne teste pas la base. C'est un choix défendable — il évite que toute la chaîne disparaisse du Service — mais il doit être **documenté**, sinon on croit à tort que « tout est vert ».
3. *Pourquoi `/health` du frontal répond-il 200 ?* Même raison, un niveau plus haut. Un bon candidat en déduit la règle : une sonde locale dit « ce composant fonctionne », elle ne dit **jamais** « le service fonctionne ».

**Pièges fréquents à corriger** : conclure « la base est tombée » sans le prouver (il faut montrer les 0 réplicas **et** l'erreur côté backend) ; annoncer un impact qualitatif au lieu de compter les requêtes en 503.

### Incident 2 — Backend lent, sans aucune erreur

`./incidents/02-backend-lent.sh AB 600` — requête non bornée **et** limite CPU abaissée à 50 m.

| Tier | Signature attendue |
|---|---|
| 1 — frontal | P95 et P99 qui montent, P50 moins ; puis apparition de **504** quand la durée dépasse `ProxyTimeout` (10 s) ; taille des réponses en forte hausse |
| 2 — backend | `cpu.usage.limit.pct` en **plateau** près de 1 ; **aucun** redémarrage ; pods `Ready` ; log WARN « chargement du panier anormalement long » |
| 3 — base | Saine, latence normale |

**Cause racine attendue** : deux causes cumulées — une requête non bornée côté application (142 000 articles chargés, réponse de 180 Ko) et un throttling CPU dû à une limite de 50 millicœurs. Un très bon candidat les distingue : la première explique la taille des réponses, la seconde le plateau de CPU.

**Les réponses attendues :**

1. *Quel SLO est violé le premier ?* Celui de **latence**, avant celui de disponibilité. Au début, il n'y a aucune erreur : le service « répond ».
2. *Pourquoi le 504 apparaît-il après la lenteur ?* Parce que la lenteur du backend devient une **erreur du frontal** quand elle dépasse `ProxyTimeout`. Une seule cause, deux symptômes successifs, deux tiers différents.
3. *Comment écarter l'infrastructure ?* Mémoire, GC et redémarrages sains, base saine : la conclusion « l'infrastructure est innocente » est **positive** et oriente vers le code. C'est une des compétences les plus utiles en astreinte.

**Piège fréquent** : augmenter les réplicas du backend. Avec une limite CPU de 50 m par pod, cela ajoute des pods tous throttlés : le débit augmente un peu, la latence unitaire ne s'améliore pas. À faire remarquer.

### Incident 3 — Cascade de 5xx

`./incidents/03-cascade-5xx.sh 600` — la limite mémoire du backend passe à 160 Mi, alors que la JVM réclame une heap de 384 Mo.

| Tier | Signature attendue |
|---|---|
| 1 — frontal | **502** puis **503** ; `error.log` avec `AH01114 failed to make connection to backend` ; latence courte |
| 2 — backend | Pods en boucle de redémarrage ; `last_terminated_reason = OOMKilled` ; exit code **137** ; **aucune** `OutOfMemoryError` dans les logs Java |
| 3 — base | Parfaitement saine : la preuve que la cause est au deuxième tier |

**Cause racine attendue** : la limite mémoire du conteneur (160 Mi) est inférieure à la mémoire totale réclamée par la JVM (heap de 384 Mo + metaspace + code cache + piles de threads) ; le noyau tue donc le conteneur à chaque démarrage.

**Les réponses attendues :**

1. *Pourquoi aucune `OutOfMemoryError` dans les logs Java ?* Parce que ce n'est **pas** la JVM qui manque de mémoire : c'est le **noyau** qui tue le processus parce que le cgroup dépasse sa limite. La JVM n'a pas le temps d'écrire quoi que ce soit. D'où l'importance de `last_terminated_reason`, donc de kube-state-metrics.
2. *Pourquoi 502 puis 503 ?* 502 quand un backend coupe en cours de réponse ; 503 quand il n'y a plus **aucun** pod prêt dans le Service. Deux étapes de la même panne.
3. *Quelle est la bonne correction ?* Rétablir une limite cohérente (768 Mi pour une heap de 384 Mo, soit une heap à 50 % de la limite). Augmenter la heap serait exactement le contraire de ce qu'il faut faire.

**Piège fréquent** : conclure « fuite mémoire ». Non : la courbe de working set ne montre aucune croissance lente, le pod meurt **au démarrage**. Le critère qui tranche est l'instant de la mort, pas la mémoire elle-même.

## 3. Réponses attendues sur les SLO

### Les cinq décisions, et les réponses défendables

| Décision | Réponse attendue | Pourquoi |
|---|---|---|
| Les 4xx comptent-elles comme des échecs ? | **Non** | Un scan externe générant 10 000 404 ferait exploser le taux sans aucune défaillance de notre part. À documenter, car c'est contestable pour un 404 sur un lien interne |
| Les sondes sont-elles dans le dénominateur ? | **Non**, exclues du numérateur **et** du dénominateur | Une sonde interrogée toutes les 10 s peut représenter la majorité des requêtes et rendre le taux d'erreur artificiellement excellent |
| Quel point de mesure ? | Le **frontal** | C'est ce que l'utilisateur subit. Une erreur du backend rattrapée par le frontal n'est pas un échec pour le client |
| Les requêtes sans durée ? | Exclues des éligibles, **mais leur part est mesurée** | Un SLI de latence qui porte sur 80 % du trafic sans le dire est faux. Seuil d'acceptation : > 99 % de couverture |
| Un échec rapide est-il « bon » ? | **Non** | Une requête qui échoue en 30 ms est rapide et inutilisable. Un SLO de latence qui ignore les erreurs **s'améliore quand le service tombe** |

### Ordres de grandeur attendus

Sur deux jours de formation avec `charge.sh` à 4 req/s, un candidat qui a subi un seul incident de dix minutes doit trouver :

| Mesure | Ordre de grandeur |
|---|---|
| Requêtes éligibles sur le tunnel | 100 000 à 200 000 |
| Budget d'erreur total (SLO 99,5 %) | 500 à 1 000 requêtes |
| Mauvaises requêtes pendant l'incident 1 (10 min) | 1 000 à 2 500 |
| Budget consommé | **100 % ou plus** — le budget de 7 jours est épuisé par un seul incident de 10 minutes |
| Burn rate pendant l'incident | très supérieur à 14,4 |

> **Point pédagogique majeur** — Que le budget soit entièrement consommé par un incident de dix minutes n'est **pas** une erreur de calcul : c'est la leçon du chapitre. Un SLO à 99,5 % sur 7 jours autorise environ 50 minutes d'indisponibilité ; dix minutes en consomment un cinquième, et bien davantage si le trafic de la période est dense. Le candidat qui s'étonne de son résultat a compris quelque chose ; celui qui l'annonce sans réagir n'a pas lu son propre chiffre.

## 4. Correction de la partie 1 — points de contrôle rapides

```bash
# Unité de durée : DOIT donner un ordre de grandeur plausible (ms, pas µs ni s)
# Comparer avec curl -w "%{time_total}" au même instant.
FROM logs-kubernetes.container_logs-studentXX
| WHERE shopflow.tier == "web" AND event.duration IS NOT NULL
| STATS p50 = PERCENTILE(event.duration, 50), max = MAX(event.duration)
| EVAL p50_ms = ROUND(p50 / 1000000.0, 1), max_ms = ROUND(max / 1000000.0, 1)

# Documents en erreur de parsing : DOIT valoir 0
FROM logs-kubernetes.container_logs-studentXX
| WHERE error.message IS NOT NULL
| STATS en_erreur = COUNT(*)

# Couverture du champ de durée : DOIT dépasser 99 %
# (requête fournie dans requetes/slo.esql)

# Les trois tiers sont-ils tous collectés ? DOIT renvoyer 3 lignes
FROM logs-kubernetes.container_logs-studentXX
| WHERE @timestamp > NOW() - 1 hours
| STATS documents = COUNT(*) BY kubernetes.labels.app_kubernetes_io/component
```

## 5. Les trois erreurs à corriger collectivement

En fin de projet, reprenez ces trois points devant toute la promotion. Ce sont ceux qui coûtent le plus cher en production, et ils produisent tous des dashboards qui **fonctionnent** tout en étant faux — ce qui est plus dangereux qu'une absence de dashboard.

1. **L'unité de durée.** `%D` vaut des microsecondes dans Apache httpd et des millisecondes dans Tomcat. Facteur 1 000. Le symptôme : des percentiles flatteurs et des alertes qui ne se déclenchent jamais.
2. **Le trafic de supervision dans le dénominateur.** Une sonde toutes les 10 secondes dilue le taux d'erreur. Le symptôme : un service en panne affiché à 99,98 % de disponibilité.
3. **L'alerte d'absence de données jamais testée.** Le symptôme : le jour où la collecte tombe, les dashboards deviennent calmes, les autres alertes se taisent, et tout le monde conclut que tout va bien.

> **Pour clore la session** — Posez cette question : « votre dispositif aurait-il détecté l'incident que vous venez de vivre, **avant** qu'un client n'appelle ? » Puis demandez la preuve : le délai de détection mesuré. C'est la seule question qui compte, et c'est celle qu'on leur posera en entretien.
