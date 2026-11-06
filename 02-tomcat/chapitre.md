# Chapitre 2 — Tomcat : journaux applicatifs et JVM

| Niveau | Durée estimée | Prérequis |
|---|---|---|
| Intermédiaire | 2 h 30 (dont 1 h 45 de manipulation) | Chapitre 1 terminé, agent `Healthy`. Tomcat installé sur la même VM, accès `sudo`. Un JDK présent (`javac`). |

Avec Tomcat, on quitte le confort du format standardisé. Un serveur d'applications Java produit **plusieurs journaux de natures différentes**, dont certains contiennent des événements qui tiennent sur quarante lignes. C'est la situation réelle de la plupart des applications d'entreprise.

Ce chapitre ne fait pas un cours sur la JVM. Il vous donne **juste ce qu'il faut** pour lire un dashboard et trancher trois questions : la mémoire fuit-elle, les threads sont-ils bloqués, et la lenteur vient-elle de l'infrastructure ou du code ?

## Objectifs

À la fin de ce chapitre, vous savez :

1. Dire quel journal Tomcat consulter selon le symptôme.
2. Configurer l'`AccessLogValve` avec la durée et l'identifiant de corrélation venu d'Apache.
3. Traiter correctement le **multiligne** : une exception Java doit devenir **un** document.
4. Convertir la durée Tomcat sans erreur d'unité — c'est le piège central du chapitre.
5. Déployer un WAR et lire le journal de déploiement.
6. Lire quatre indicateurs JVM : heap après GC, temps en GC, threads occupés, sessions.
7. Reconnaître une fuite mémoire, une application lente et un échec de déploiement.

> **À retenir** — Une application Java ne tombe presque jamais d'un coup : elle se dégrade. La mémoire se remplit, le ramasse-miettes travaille de plus en plus, les requêtes ralentissent — jusqu'à ce que quelque chose casse. Tout l'enjeu est de lire cette dégradation **avant** l'erreur 500.

---

## Étape 1 — Prérequis et les cinq journaux

```bash
sudo systemctl status tomcat --no-pager | head -5
ls /opt/tomcat/{bin,conf,logs,webapps}
ls /opt/tomcat/lib | grep -i servlet     # jakarta (Tomcat 10+) ou javax (Tomcat 9)
java -version 2>&1 | head -1
javac -version                            # nécessaire pour construire le WAR
id tomcat
df -h /opt/tomcat/logs | tail -1          # un dump mémoire pèse autant que la heap
```

| Journal | Produit par | Contenu | On y va pour… |
|---|---|---|---|
| `localhost_access_log.<date>.txt` | `AccessLogValve` | Une ligne par requête HTTP | Compter, mesurer la latence, voir les codes |
| `catalina.out` | Sortie standard de la JVM | Tout ce qui est écrit sur `stdout`/`stderr` : démarrage, piles d'appels non capturées, `System.out` | Les erreurs de démarrage et les plantages violents |
| `catalina.<date>.log` | JULI | Événements du conteneur | Déploiements, arrêts, erreurs de configuration |
| `localhost.<date>.log` | JULI | Événements des applications passant par JULI | Erreurs applicatives sur le host |
| `shopflow-app.json` | Journalisation applicative | Logs métier structurés en JSON ECS | L'enquête applicative — le journal le plus exploitable |

Dans ce TP, l'application écrit elle-même du **JSON ECS sur la sortie standard**. Ce JSON arrive donc dans `catalina.out` et ne demande aucun parsing. C'est la bonne pratique quand on maîtrise le code : plus de `grok` à maintenir, et `service.name` identique à celui des logs Apache, ce qui rend la corrélation immédiate.

> **⚠️ Piège fréquent** — `catalina.out` n'est **pas** rotaté par Tomcat : c'est une simple redirection de la sortie standard. Sur un serveur oublié, ce fichier atteint couramment plusieurs gigaoctets et finit par remplir le disque. Le fichier `logrotate` fourni utilise `copytruncate`, **obligatoire** ici : le processus Java garde le descripteur de fichier ouvert et n'en rouvrirait pas un nouveau après un simple renommage.

### Dix lignes à savoir reconnaître

```text
① ACCESS LOG — cas nominal
127.0.0.1 - - [06/Nov/2026:14:02:11 +0100] "GET /shopflow-api/api/cart HTTP/1.1" 200 1842 37 12 http-nio-8080-exec-3 "abc123"
   37 = duree en MILLISECONDES (%D de Tomcat). 12 = delai avant le premier
   octet (%F). http-nio-8080-exec-3 = le thread, utile pour relier a une pile.

② ACCESS LOG — requete lente, succes fonctionnel
127.0.0.1 - - [06/Nov/2026:14:13:02 +0100] "GET /shopflow-api/api/cart HTTP/1.1" 200 184320 4102 15 http-nio-8080-exec-5 "def456"
   4 102 ms, code 200 : INVISIBLE pour une supervision par code de statut.

③ ACCESS LOG — erreur serveur
127.0.0.1 - - [06/Nov/2026:14:05:33 +0100] "GET /shopflow-api/api/erreur HTTP/1.1" 500 1044 892 8 http-nio-8080-exec-7 "ghi789"
   L'erreur 500 vue par Apache au chapitre 1 a donc bien ete produite ICI.

④ CATALINA — demarrage
06-Nov-2026 09:14:02.118 INFO [main] org.apache.catalina.startup.Catalina.start
  Server startup in [8 214] milliseconds
   Repere temporel essentiel : tout ce qui precede est du demarrage.

⑤ CATALINA — deploiement
06-Nov-2026 09:14:01.004 INFO [main] org.apache.catalina.startup.HostConfig.deployWAR
  Deployment of web application archive [/opt/tomcat/webapps/shopflow-api.war]
  has finished in [6 102] ms
   Date ET duree de deploiement : a correler avec toute degradation.

⑥ CATALINA — pool de connexions epuise
06-Nov-2026 14:07:12.431 WARN [http-nio-8080-exec-14] com.zaxxer.hikari.pool.HikariPool
  HikariPool-1 - Connection is not available, request timed out after 30000ms
   Cause frequente : des requetes lentes gardent les connexions.

⑦ CATALINA — exception applicative (UNE erreur, CINQ lignes)
06-Nov-2026 14:12:03.411 SEVERE [http-nio-8080-exec-7] org.apache.catalina.core.StandardWrapperValve.invoke
  Servlet.service() for servlet [ShopFlowServlet] threw exception
        java.lang.NullPointerException: Cannot invoke "String.length()" because "nul" is null
                at com.novacommerce.shopflow.ShopFlowServlet.erreur(ShopFlowServlet.java:188)
                at com.novacommerce.shopflow.ShopFlowServlet.doGet(ShopFlowServlet.java:131)
                ... 47 more
   Sans traitement multiligne : 5 documents inutiles au lieu d'un seul utile.

⑧ CATALINA — OutOfMemoryError
06-Nov-2026 14:12:44.902 SEVERE [http-nio-8080-exec-9] org.apache.catalina.core.ContainerBase
  java.lang.OutOfMemoryError: GC overhead limit exceeded
   La JVM passe l'essentiel de son temps en GC sans rien liberer.

⑨ CATALINA — plus de thread disponible
06-Nov-2026 14:14:20.004 WARN [http-nio-8080-Acceptor] org.apache.tomcat.util.net.NioEndpoint
  Socket processing request was rejected for [...]: too many open connections
   Equivalent Tomcat du « scoreboard is full » d'Apache (chapitre 1).

⑩ CATALINA — arret propre
06-Nov-2026 18:02:10.771 INFO [main] org.apache.catalina.core.StandardService.stopInternal
  Stopping service [Catalina]
   Un arret SANS cette ligne = arret brutal (OOM killer, kill -9, coupure).
   Information capitale pour un diagnostic post-mortem.
```

> **À retenir** — Tomcat utilise `SEVERE` et `WARNING`, les applications Java utilisent presque toujours `ERROR` et `WARN`. Si vous ne normalisez pas, une requête `log.level : "ERROR"` **manquera toutes les erreurs du conteneur**. C'est exactement ce que fait le processeur `script` du pipeline fourni — et c'est le genre de détail qui fait la différence entre une collecte qui a l'air de marcher et une collecte exploitable.

| Niveau JULI | Équivalent usuel | Valeur ECS après normalisation |
|---|---|---|
| `SEVERE` | ERROR | `ERROR` |
| `WARNING` | WARN | `WARN` |
| `INFO`, `CONFIG` | INFO | `INFO` |
| `FINE`, `FINER`, `FINEST` | DEBUG, TRACE | `DEBUG` |

**✅ Vérification de l'étape 1** — vous savez dire, sans hésiter, dans quel fichier chercher : une erreur au démarrage, une exception pendant une requête, la durée d'une requête, et la trace d'un déploiement.

---

## Étape 2 — Configurer les journaux et la JVM

### 2.1 L'AccessLogValve

Sauvegardez, puis reportez le bloc `<Valve>` du fichier `server-xml-host.xml` **à l'intérieur** de votre `<Host name="localhost">` existant.

```bash
sudo cp /opt/tomcat/conf/server.xml{,.avant-tp}
sudo cp /opt/tomcat/conf/logging.properties{,.avant-tp}
sudo nano /opt/tomcat/conf/server.xml      # coller le bloc <Valve>
```

Le motif retenu : `%h %l %u %t "%r" %s %b %D %F %I "%{X-Request-Id}i"`

| Élément | Rôle |
|---|---|
| `%D` | Durée en **millisecondes** |
| `%F` | Délai avant le premier octet de réponse : distingue traitement et transfert |
| `%I` | Nom du thread : relie une requête à une pile d'appels du même thread |
| `%{X-Request-Id}i` | L'en-tête injecté par Apache au chapitre 1 : le pont entre les deux journaux |
| `requestAttributesEnabled="true"` | Permet d'obtenir l'IP réelle du client transmise par le proxy, au lieu de `127.0.0.1` |

> **⚠️ Piège fréquent — le piège central du chapitre** — `%D` vaut des **microsecondes** dans Apache httpd et des **millisecondes** dans Tomcat. Si vous recopiez le pipeline du chapitre 1 sans adapter le facteur, vos latences Tomcat seront **mille fois trop faibles** — et vos percentiles diront que tout va bien. Le facteur est `× 1 000 000` ici, contre `× 1 000` au chapitre 1. Vérifiez toujours en comparant à une valeur connue : `curl -w "%{time_total}"`.

### 2.2 Les options JVM, dans `setenv.sh`

`setenv.sh` est **le** fichier où l'on met les options JVM. Jamais `catalina.sh`, qui est écrasé à chaque mise à jour.

```bash
sudo install -m 750 -o tomcat -g tomcat setenv.sh /opt/tomcat/bin/setenv.sh
sudo install -m 644 logrotate-tomcat /etc/logrotate.d/tomcat
sudo systemctl restart tomcat
```

| Option | Pourquoi |
|---|---|
| `-Xms` = `-Xmx` | Évite les redimensionnements et rend les courbes lisibles |
| `-Xmx512m` en TP | Une heap petite rend la fuite observable en minutes, pas en heures |
| `-XX:+UseG1GC -XX:MaxGCPauseMillis=200` | Objectif de pause explicite |
| `-Xlog:gc*:file=…:filecount=5,filesize=20M` | Journal de GC **borné** : gratuit, et indispensable le jour de l'incident |
| `-XX:+HeapDumpOnOutOfMemoryError` | Le dump est la **seule** façon d'analyser une fuite après coup |
| `-XX:+ExitOnOutOfMemoryError` | Laisse systemd relancer proprement, au lieu de garder une JVM incohérente |
| `-javaagent:…jolokia-jvm-agent.jar` | Expose JMX en HTTP/JSON pour la collecte Elastic |

> **⚠️ Piège fréquent** — JMX sans authentification est une **vulnérabilité d'exécution de code à distance**. La configuration fournie n'est acceptable que parce qu'elle est restreinte à `127.0.0.1` et que le collecteur tourne sur la machine elle-même. Ne reproduisez jamais ces options sur une interface joignable depuis l'extérieur.

**✅ Vérification de l'étape 2**

```bash
PID=$(pgrep -f catalina | head -1)
sudo -u tomcat jcmd "$PID" VM.flags | tr ' ' '\n' | grep -E 'HeapSize|UseG1GC|HeapDump'
sudo tail -5 /opt/tomcat/logs/gc.log
sudo tail -3 /opt/tomcat/logs/localhost_access_log.*.txt
curl -s http://127.0.0.1:8778/jolokia/read/java.lang:type=Memory/HeapMemoryUsage | head -c 200
```

La valeur de `MaxHeapSize` doit correspondre à ce que vous avez demandé. Si elle n'y correspond pas, `setenv.sh` n'est pas pris en compte : vérifiez son emplacement, ses droits et le compte propriétaire.

---

## Étape 3 — Déployer l'application ShopFlow

```bash
cd app
./build-war.sh          # javac + jar : ni Maven, ni réseau
sudo ./deploy-war.sh    # copie dans webapps et suit le journal 30 s
```

`build-war.sh` détecte l'espace de noms des servlets dans les bibliothèques de votre Tomcat : `jakarta.servlet` pour Tomcat 10 et 11, `javax.servlet` pour Tomcat 9 et antérieurs, et réécrit les imports en conséquence.

> **⚠️ Piège fréquent** — Le passage de `javax` à `jakarta` entre Tomcat 9 et Tomcat 10 est la cause numéro un des échecs de déploiement. Le symptôme est trompeur : le WAR se déploie « sans erreur » mais toutes les requêtes renvoient 404, parce qu'aucun servlet n'a été reconnu. Si cela vous arrive, lisez `catalina.out` au moment du déploiement : la cause y est écrite.

Les routes de l'application, utilisées dans tout le reste du manuel :

| Route | Comportement |
|---|---|
| `/health` | Sonde de supervision — à exclure des mesures |
| `/api/cart` | Panier. `?scenario=degrade` : 142 000 articles, ~4 s, ~180 Ko, **code 200** |
| `/api/produit/{id}` | Fiche produit, 10 à 40 ms |
| `/api/lent?ms=N` | Réponse temporisée de N millisecondes |
| `/api/erreur?type=npe\|sql\|500` | Exception avec pile d'appels réelle, ou 500 simple |
| `/api/fuite?mo=N` | Retient N Mo **non libérés** — la fuite volontaire |
| `/api/reset` | Libère la mémoire retenue et désactive le mode dégradé |

**✅ Vérification de l'étape 3** — dans le journal de déploiement, vous avez relevé :

```text
INFO [main] org.apache.catalina.startup.HostConfig.deployWAR
  Deploying web application archive [/opt/tomcat/webapps/shopflow-api.war]
INFO [main] org.apache.catalina.startup.HostConfig.deployWAR
  Deployment of web application archive [...] has finished in [N] ms
```

Notez le `N` : c'est votre **durée de déploiement de référence**. Et notez l'horodatage : il vous servira à superposer déploiements et courbes de latence.

```bash
curl -s http://localhost:8080/shopflow-api/health
curl -s http://localhost:8080/shopflow-api/api/cart | head -c 120
```

---

## Étape 4 — Collecter : intégration, multiligne, pipelines

### 4.1 Dans quelle politique ? — un agent n'en a qu'une

C'est la première question, et elle se tranche avant de toucher à Fleet.

**Un Elastic Agent appartient à une seule politique.** Sur la VM de ce manuel, Apache et Tomcat tournent sur la **même machine**, donc il n'y a qu'un agent d'hôte — celui que vous avez enrôlé au chapitre 1 dans `efi-studentXX-apache`. Les intégrations Tomcat vont donc **dans cette même politique**.

| Votre situation | Politique à utiliser | Geste dans Fleet |
|---|---|---|
| Apache et Tomcat sur la **même VM** (cas de ce manuel) | `efi-studentXX-apache` | Ajouter les intégrations Tomcat à la politique existante : l'agent les reçoit en quelques secondes, sans réinstallation |
| Tomcat sur une **VM dédiée** | `efi-studentXX-tomcat` | Enrôler cette seconde VM avec le token de cette politique |

> **⚠️ Piège fréquent** — Tenter d'enrôler une deuxième fois la même machine avec le token de `efi-studentXX-tomcat` ne « double » pas la collecte : au mieux l'installation échoue parce qu'un agent est déjà installé, au pire vous remplacez la politique précédente et **la collecte Apache s'arrête** — sans aucune erreur visible, puisque l'agent reste `Healthy`. Si vous voyez les données Apache se tarir au chapitre 2, c'est la première chose à vérifier.

> **🔒 Formateur / administrateur** — Les politiques `efi-studentXX-tomcat` existent déjà sur la plateforme, prévues pour le cas d'une VM dédiée. Dans le montage à une seule VM, elles restent inutilisées : ajoutez les intégrations Tomcat à `efi-studentXX-apache`, et pensez à mettre à jour sa description.

### 4.2 Deux voies, et comment choisir

| Voie | Quand la choisir | Ce qu'il faut savoir |
|---|---|---|
| **A — intégration Apache Tomcat** | Si elle existe dans votre catalogue Fleet | Parsing et dashboards prêts à l'emploi, mais périmètre à vérifier et peu adaptée aux journaux maison |
| **B — Custom Logs (Filestream) + pipeline `@custom`** | Cas général, voie retenue ici | Contrôle total, fonctionne avec n'importe quel format ; vous écrivez et maintenez le parsing |

> **⚠️ À vérifier sur votre plateforme** — Ouvrez **Fleet → Integrations** et cherchez « Tomcat ». Si l'intégration existe, utilisez-la pour les journaux standards et réservez la voie B à votre journal applicatif. Si elle n'existe pas, la voie B couvre tout. N'inventez pas la présence d'une intégration : vérifiez. <!-- À VÉRIFIER : périmètre exact de l'intégration « Apache Tomcat » en 9.5.5 (jeux de données logs et métriques) et dépendance éventuelle à Jolokia pour les métriques. -->

Un **dataset par nature de journal**, et non un dataset fourre-tout :

| Chemin | Dataset | Pourquoi séparé |
|---|---|---|
| `/opt/tomcat/logs/localhost_access_log.*.txt` | `shopflow_tomcat.access` | Volume élevé, format fixe, rétention courte suffisante |
| `/opt/tomcat/logs/catalina.out` | `shopflow_tomcat.catalina` | Multiligne, volume faible, rétention plus longue utile |
| `/opt/tomcat/logs/catalina.*.log` | `shopflow_tomcat.catalina` | Même nature |
| `/opt/tomcat/logs/localhost.*.log` | `shopflow_tomcat.localhost` | Erreurs applicatives via JULI |

> **⚠️ Piège fréquent** — Les noms de fichiers contiennent la date : `catalina.2026-11-06.log`. Les jokers sont donc **indispensables** dans les chemins déclarés. Un chemin sans joker collecte le fichier du jour de la configuration, puis plus rien — et personne ne s'en aperçoit avant plusieurs jours.

### 4.3 Le multiligne : une exception = un document

C'est le point technique central. Collez `custom-logs-multiline.yml` dans le champ **Custom configurations** de l'entrée filestream.

| Paramètre | Rôle | Erreur classique |
|---|---|---|
| `pattern` | Reconnaît le **début** d'un événement (une date) | Un motif qui correspond aussi aux lignes de continuation |
| `negate: true` | Les lignes qui ne correspondent **pas** sont des continuations | Oublier `negate` : plus rien n'est regroupé |
| `match: after` | Rattache la continuation à l'événement précédent | `before` décalerait tous les messages |
| `max_lines: 200` | Plafond par événement | Sans plafond, une pile pathologique produit un document énorme |
| `timeout: 5s` | Ferme l'événement en l'absence de nouvelle ligne | Sans délai, la **dernière erreur avant un silence** reste bloquée et n'est jamais indexée |

Deux stratégies de motif existent : reconnaître le début d'un événement (une date), ou reconnaître les continuations (lignes commençant par un espace, `at `, `Caused by:`). La première est plus robuste, parce qu'elle ne dépend pas du style d'indentation de la JVM.

### 4.4 Les deux pipelines

Créez-les dans **Dev Tools → Console** (menu ☰ → Management → Dev Tools) avant d'activer la collecte. Comme au chapitre 1, ne collez pas les clés de documentation `_requete`, `_but` et `_le_piege` : Elasticsearch les refuse.

```text
PUT  _ingest/pipeline/logs-shopflow_tomcat.access@custom      <- pipeline-tomcat-access.json
PUT  _ingest/pipeline/logs-shopflow_tomcat.catalina@custom    <- pipeline-tomcat-catalina.json
POST _ingest/pipeline/logs-shopflow_tomcat.access@custom/_simulate
```

Ce que fait le pipeline du journal d'accès :

| Processeur | Rôle |
|---|---|
| `grok` | Découpe la ligne : IP, date, méthode, URL, statut, octets, `%D`, `%F`, thread, `X-Request-Id` |
| `date` | Parse l'horodatage, qui contient son fuseau (`+0100`) |
| `script` | **Millisecondes → nanosecondes** : facteur 1 000 000 |
| `script` | `shopflow.ttfb_ns` : le délai avant premier octet |
| `script` | `shopflow.status_class` : `2xx`, `4xx`, `5xx` |
| `set` | `service.name = shopflow-api` — différent du `shopflow-web` d'Apache : deux services, un seul parcours |
| `set` | `event.outcome` : `failure` si ≥ 500, `success` si < 400 |

Ce que fait le pipeline de `catalina` :

| Processeur | Rôle |
|---|---|
| `grok` | Date, niveau, thread, logger, puis `GREEDYMULTILINE` qui capture la **pile complète** |
| `date` | Reconstitue l'horodatage **avec un fuseau explicite** |
| `script` | `SEVERE → ERROR`, `WARNING → WARN`, `FINE* → DEBUG` |
| `grok` | Extrait `error.type` et `error.message` : permet de **grouper les erreurs par type d'exception** |
| `set` | `event.outcome = failure` si `log.level = ERROR` |

> **⚠️ Piège fréquent** — Le fuseau horaire est la cause la plus fréquente de « mes logs sont décalés de deux heures ». Le format de date de `catalina` ne contient **aucune** indication de fuseau : le processeur `date` doit se le faire préciser. Et comme Elasticsearch stocke toujours en UTC, c'est Kibana qui réaffiche dans votre fuseau — un décalage constant signale un `timezone` absent ou faux dans le pipeline.

### 4.5 Les métriques JVM

Il n'y a pas d'agent APM dans ce manuel : les métriques JVM viennent de **JMX via Jolokia**. Ajoutez l'intégration **Jolokia** à votre politique avec les mappings de `jolokia-mappings.yml`. Vous y définissez vous-même les noms de champs cibles : gardez-les stables, vos dashboards en dépendent.

| MBean | Ce qu'il donne | Pourquoi c'est là |
|---|---|---|
| `java.lang:type=Memory` | `HeapMemoryUsage`, `NonHeapMemoryUsage` | La mémoire, et la part **hors** heap |
| `java.lang:type=GarbageCollector,name=*` | `CollectionCount`, `CollectionTime` | Le **temps** en GC, pas seulement le nombre |
| `java.lang:type=Threading` | `ThreadCount`, `PeakThreadCount` | Une croissance monotone est une fuite de threads |
| `Catalina:type=ThreadPool,name="http-nio-8080"` | `currentThreadsBusy`, `maxThreads` | La saturation du pool, **avant** les erreurs |
| `Catalina:type=GlobalRequestProcessor,…` | `requestCount`, `errorCount`, `maxTime` | Compteurs du connecteur |
| `Catalina:type=Manager,…,context=/shopflow-api` | `activeSessions`, `expiredSessions` | Les sessions : cause classique de fuite |

> **⚠️ Voie de repli** — Si l'agent Jolokia n'est pas disponible sur votre VM, commentez la ligne `-javaagent` de `setenv.sh`. Vous lirez alors la JVM en ligne de commande avec `jcmd` et `jstat` — ce qui est de toute façon à savoir faire — et la collecte Elastic se limitera aux journaux. Les scénarios du chapitre restent tous réalisables.

```bash
PID=$(pgrep -f catalina | head -1)
sudo -u tomcat jcmd "$PID" GC.heap_info          # état des zones
sudo -u tomcat jcmd "$PID" Thread.print > /tmp/threads.txt
sudo -u tomcat jstat -gcutil "$PID" 1000 30      # 30 mesures, 1 par seconde
```

Les colonnes de `jstat -gcutil` qui servent : `O` occupation de l'Old en %, `E` l'Eden, `M` le Metaspace, `FGC` le nombre de **full** GC, `GCT` le **temps total** passé en GC.

**✅ Vérification de l'étape 4**

```bash
ES_API_KEY='<votre-cle>' ./scripts/verif-tomcat.sh
```

Le script fait le **contrôle d'unité** qui compte : il affiche le `max(event.duration)` vu par Elasticsearch et, juste après, la durée mesurée par `curl` sur `/api/lent?ms=1500`. Les deux doivent être du même ordre. Si Elastic affiche mille fois moins, le facteur de conversion est faux.

---

## Étape 5 — Lire la JVM : quatre indicateurs suffisent

Pas besoin d'un cours sur les générations mémoire pour exploiter. Quatre panneaux, et ce qu'ils disent :

| Panneau | Calcul | Ce que vous en concluez |
|---|---|---|
| **Heap après GC** | `min(jvm.memory.heap.used)` par minute | **Le panneau le plus important.** Un plancher qui monte = fuite. Un plancher stable = sain |
| **Temps en GC par minute** | dérivée de `jvm.gc.time_ms` | Au-delà de quelques secondes par minute, la latence est touchée |
| **Threads occupés du connecteur** | `tomcat.threads.busy` sur `tomcat.threads.max` | La saturation du pool apparaît ici **avant** d'apparaître dans les erreurs |
| **Sessions actives** | `tomcat.sessions.active` | Chute brutale = redémarrage. Croissance sans fin = sessions non expirées |

> **À retenir** — Trois faits, et vous saurez lire n'importe quelle courbe JVM. **Un** : la seule courbe qui permette de conclure est la heap **après** GC, c'est-à-dire le plancher des dents de scie — la heap instantanée oscille en permanence et ne prouve rien. **Deux** : ce qui compte, c'est le **temps** passé en GC par unité de temps, pas le nombre de GC ; 500 collectes totalisant 300 ms par minute, c'est sain, 3 collectes totalisant 40 s, c'est une application à l'arrêt. **Trois** : `-Xmx` ne borne **que** la heap — la mémoire réelle du processus vaut heap + metaspace + code cache + piles de threads + buffers natifs, soit couramment 30 à 50 % de plus.

Quatre signatures de courbe de heap, à reconnaître d'un coup d'œil :

```text
A) SAIN — dents de scie, plancher CONSTANT
   le GC libere bien -> rien a faire

B) FUITE — dents de scie, plancher CROISSANT
   chaque GC libere moins -> OutOfMemoryError a terme
   chercher une collection qui grossit sans fin (cache sans eviction,
   liste statique, sessions jamais expirees)

C) SOUS-DIMENSIONNEE — plancher HAUT et plat, proche du Xmx
   GC permanent, CPU eleve sans travail utile
   -> « GC overhead limit exceeded » a la fin

D) PIC PONCTUEL — une bosse isolee
   un export, un batch, une requete sans LIMIT
   -> trouver LA requete
```

> **Bonne pratique** — Posez le temps en GC et la latence P95 de l'application sur le **même** graphique, avec deux axes. C'est la visualisation qui convainc une équipe de développement : on y voit la latence suivre le GC pic pour pic, et la discussion cesse d'être une affaire d'opinion.

Nommez le dashboard `tomcat-jvm-overview-studentXX`, avec en plus : P50/P95/P99 de `event.duration` sur le journal d'accès, le taux de 5xx par route, et une recherche sauvegardée des documents `log.level : "ERROR"`.

**✅ Vérification de l'étape 5** — vous avez consigné un **tableau de référence au repos et sous charge nominale** pour ces quatre indicateurs. Sans référence, aucun écart n'est interprétable — et les scénarios de l'étape 6 n'auront aucun sens.

---

## Étape 6 — Les scénarios

> **⚠️ Attention** — Ces scénarios consomment délibérément la mémoire de votre JVM jusqu'à la faire tomber. Ils ne se lancent que sur **votre** instance, jamais sur une instance partagée.

### Scénario 1 — Fuite mémoire jusqu'à l'OutOfMemoryError

```bash
./scripts/scenario-fuite.sh 10 10      # 10 Mo toutes les 10 secondes
```

Le script appelle `/api/fuite` en boucle et affiche, à chaque passe, l'occupation de l'Old, de l'Eden, du Metaspace, le nombre de full GC et le temps total en GC. Il s'arrête de lui-même quand l'OOM apparaît.

| Symptôme | Où le voir | Lecture |
|---|---|---|
| Heap après GC : plancher croissant | Dashboard JVM, `min` par minute | La signature de la fuite |
| `FGC` et `GCT` qui s'envolent | Sortie du script, `jstat` | La JVM se bat pour rien |
| Latence P95 qui se dégrade progressivement | Journal d'accès | Les pauses GC sont payées par l'utilisateur |
| `java.lang.OutOfMemoryError: Java heap space` | `catalina.out`, Kibana | La fin |
| Un fichier `heapdump.hprof` de la taille de la heap | `/opt/tomcat/logs/` | La seule façon d'analyser après coup |

**Alerte attendue** : `heap-saturee-studentXX` (niveau 3, ticket) **puis** `exception-critique-studentXX` (niveau 2, alerte).

> **À retenir** — Les cinq messages d'`OutOfMemoryError` ne désignent pas le même problème. `Java heap space` : la heap est pleine. `GC overhead limit exceeded` : la JVM n'arrive plus à libérer de mémoire utile, presque toujours une fuite avancée. `Metaspace` : trop de classes chargées, typiquement des redéploiements à chaud répétés. `unable to create new native thread` et `Direct buffer memory` n'ont **rien à voir avec la heap** : augmenter `-Xmx` dans ces deux cas est contre-productif, car cela réduit la mémoire disponible pour les threads et les buffers natifs.

Remise en état :

```bash
sudo systemctl restart tomcat
curl -s http://localhost:8080/shopflow-api/api/reset
sudo rm -f /opt/tomcat/logs/heapdump.hprof   # un dump peut contenir des données
```

### Scénario 2 — Application lente, sans aucune erreur

```bash
./scripts/scenario-lenteur.sh B 180    # la requête non bornée du fil rouge
./scripts/scenario-lenteur.sh A        # paliers de latence maîtrisée
```

| Symptôme | Où le voir | Lecture |
|---|---|---|
| P95 et P99 montent, P50 bouge peu | Courbe des percentiles | Une **minorité** de requêtes est touchée |
| Aucun code d'erreur, 200 partout | Taux de 5xx | Le service « répond » |
| Taille des réponses qui augmente | `http.response.body.bytes` | Une requête non bornée |
| Heap, GC et threads **normaux** | Dashboard JVM | **Conclusion positive** : l'infrastructure est innocente |
| Côté Apache : workers occupés plus longtemps, parfois des 504 | Chapitre 1 | La lenteur du backend se propage au frontal |

**Alerte attendue** : `latence-p95-tomcat-studentXX`. Et c'est le point de l'exercice : sans règle de latence, cette dégradation est **invisible**.

> **À retenir** — Quand la heap, le GC et les threads sont sains et que la latence se dégrade quand même, vous venez d'écarter l'infrastructure. C'est une des conclusions les plus utiles en astreinte : elle évite des heures passées à redimensionner des serveurs qui n'ont aucun problème, et elle oriente immédiatement vers le code ou une dépendance.

### Scénario 3 — Échec de déploiement

```bash
./scripts/scenario-deploiement.sh
```

Le script fabrique un WAR dont le `web.xml` est volontairement malformé, le déploie, suit le journal, puis nettoie.

| Symptôme | Où le voir | Lecture |
|---|---|---|
| `SEVERE … Parse error in application web.xml` | `catalina.out`, Kibana | La cause est nommée dans le message |
| `log.level : "ERROR"` dans Kibana | Discover | La normalisation `SEVERE → ERROR` fonctionne |
| L'application **saine** répond toujours 200 | `curl /health` | Un échec de déploiement n'est pas forcément une panne de service |
| Le contexte cassé renvoie 404 | `curl` | Il n'a jamais démarré |

**Alerte attendue** : `deploiement-echec-studentXX`, vers l'équipe qui déploie — **pas** vers l'astreinte.

### Tableau de synthèse

| Scénario | Symptôme dans les logs | Symptôme dans les métriques | Alerte |
|---|---|---|---|
| Fuite mémoire | `OutOfMemoryError`, piles d'appels | Heap après GC croissante, `GCT` qui s'envole | `heap-saturee` puis `exception-critique` |
| Application lente | **Rien** — code 200 partout | Heap et GC **normaux**, durée en hausse | `latence-p95-tomcat` |
| Échec de déploiement | `SEVERE … Parse error` | Aucun impact | `deploiement-echec` |

---

## Dépannage

| Symptôme | Cause la plus probable | Correction |
|---|---|---|
| Une exception produit 5 documents au lieu d'un | Multiligne absent ou mal configuré | Vérifier `negate: true` et `match: after`, tester sur un extrait réel |
| Logs décalés de deux heures | `timezone` absent du processeur `date` | Le format `catalina` ne contient pas de fuseau : le préciser |
| Latences mille fois trop faibles | Facteur d'unité du chapitre 1 recopié tel quel | `%D` de Tomcat est en **ms** : facteur 1 000 000 |
| `grok_tomcat_access_failed` sur tous les documents | Le motif de l'`AccessLogValve` ne correspond pas au `grok` | Comparer champ par champ la ligne réelle et le motif |
| Aucun document du journal d'accès | Chemin sans joker, alors que le nom contient la date | `localhost_access_log.*.txt` |
| `MaxHeapSize` ne correspond pas à `-Xmx` | `setenv.sh` non pris en compte | Emplacement (`$CATALINA_HOME/bin`), droits, propriétaire |
| Le WAR se déploie mais tout renvoie 404 | Mauvais espace de noms servlet (`javax` / `jakarta`) | `build-war.sh` le détecte ; sinon lire `catalina.out` au déploiement |
| Aucune métrique JVM | Jolokia non chargé, ou mappings erronés | `curl http://127.0.0.1:8778/jolokia/read/java.lang:type=Memory/HeapMemoryUsage` |
| Conclusion erronée de fuite mémoire | Lecture de la heap **instantanée** | Afficher le `min` par intervalle, observer sur des heures |
| `-Xmx` augmenté et l'OOM persiste | Le message était `native thread` ou `Direct buffer memory` | Lire le **message exact** : ce n'est pas la heap |
| Le dump ne se crée pas sur OOM | Espace disque insuffisant, ou droits | Il faut la taille de la heap, et les droits du compte `tomcat` |
| `catalina.out` de plusieurs gigaoctets | Rotation absente, ou sans `copytruncate` | Poser le fichier `logrotate` fourni |

### Nettoyage de fin de chapitre

```bash
curl -s http://localhost:8080/shopflow-api/api/reset
sudo logrotate -f /etc/logrotate.d/tomcat
sudo rm -f /opt/tomcat/logs/heapdump.hprof
sudo cp /opt/tomcat/conf/server.xml.avant-tp /opt/tomcat/conf/server.xml  # si besoin
```

> **⚠️ Piège fréquent** — Un dump mémoire contient **tout** ce qu'avait l'application en mémoire : identifiants de session, contenus de panier, parfois des données personnelles. Ne le transmettez jamais à un tiers sans précaution, et supprimez-le après analyse.

---

## Livrables du chapitre

1. Le bloc `<Valve>` et le `setenv.sh` posés, commentés.
2. La sortie de `jcmd VM.flags` montrant la heap réellement appliquée.
3. La réponse de `_simulate` sur le journal d'accès : `event.duration` en nanosecondes, du bon ordre de grandeur.
4. Une capture de Discover montrant **une** exception Java complète dans **un seul** document.
5. Le tableau de référence des quatre indicateurs JVM, au repos et sous charge.
6. La courbe de heap après GC du scénario de fuite, avec le moment de bascule identifié et le message d'OOM exact.
7. Pour le scénario de lenteur : la démonstration écrite que l'infrastructure est innocente.
8. Les quatre règles d'alerte, avec les délais mesurés.

---

**➡️ Chapitre suivant** : Kubernetes — collecte par DaemonSet et diagnostic des six pannes classiques.
