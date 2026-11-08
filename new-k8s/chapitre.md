# Chapitre 3 — Kubernetes (cluster kubeadm à 2 nœuds)

| Niveau | Durée estimée | Prérequis |
|---|---|---|
| Intermédiaire + | 3 h 00 (dont 2 h de manipulation) | Chapitres 1 et 2 terminés. Votre cluster kubeadm (un master + un worker), dont vous êtes administrateur. `kubectl` fonctionnel sur le master. Notions de pod, deployment, service, namespace. Fichier `installer-agent-k8s-studentXX.sh` remis par le formateur. |

Dans Kubernetes, un pod est éphémère **par conception**. Il peut disparaître avec ses logs à tout instant : après une mise à jour, un `OOMKilled`, une éviction. Centraliser les logs n'est donc pas un confort, c'est la seule façon de pouvoir enquêter sur quelque chose qui n'existe plus.

Ce chapitre met en place la collecte sur votre cluster Kubernetes, puis vous fait provoquer et diagnostiquer les **six pannes** que vous rencontrerez réellement en production.

## Objectifs

À la fin de ce chapitre, vous savez :

1. Décrire le chemin d'une ligne de log, du `echo` au document Elasticsearch.
2. Expliquer pourquoi la collecte se fait par DaemonSet et ce qu'il monte depuis le nœud.
3. Déployer kube-state-metrics et dire ce qu'il apporte que le kubelet n'apporte pas.
4. Distinguer rigoureusement métriques de **consommation**, d'**état** et de **capacité**.
5. Construire le tableau de diagnostic qui qualifie un incident en une ligne par pod.
6. Diagnostiquer `Pending`, `CrashLoopBackOff` (deux causes), `OOMKilled`, `ImagePullBackOff` et le throttling CPU.
7. Alerter sur ce qui compte, dont les pods « vivants mais hors service ».

> **À retenir** — Un agent de plus, mais un changement de nature : sur une VM, vous collectez **une** machine que vous connaissez. Dans Kubernetes, vous collectez un système qui crée et détruit ses propres composants sans vous demander votre avis. Ce qui remplace la connaissance de l'inventaire, ce sont les **métadonnées** : namespace, pod, conteneur, nœud, labels.

---

## Étape 1 — Prérequis

### 1.1 Le cluster

Chaque candidat administre son propre cluster, installé avec **kubeadm** : un nœud **master** (le control plane : etcd, kube-apiserver, scheduler…) et un nœud **worker**, qui exécute vos applications. Vous avez les droits de créer des namespaces et de déployer dans `kube-system`, ce qui ne serait pas le cas sur un cluster mutualisé.

Toutes les commandes du chapitre se lancent **sur le master**, avec l'utilisateur `efi`, dans le dossier du chapitre. Commencez par personnaliser les fichiers, comme au chapitre 2 :

```bash
cd ~/tp-elk/03-kubernetes
bash scripts/remplir-variables.sh studentXX              # simulation : vérifiez les valeurs
bash scripts/remplir-variables.sh studentXX --appliquer
```

Puis vérifiez le cluster :

```bash
systemctl is-active kubelet containerd           # active / active
kubectl get nodes -o wide
kubectl describe nodes | grep -E '^Name:|^Taints:'
kubectl get pods -A -o wide | grep -E 'calico|coredns|metrics-server'
```

Attendu, par exemple pour le cluster du formateur :

```text
NAME                 STATUS   ROLES           VERSION    INTERNAL-IP    CONTAINER-RUNTIME
kube-master-g34-m1   Ready    control-plane   v1.32.13   172.16.34.80   containerd://1.6.20
kube-worker-g34-m1   Ready    <none>          v1.32.13   172.16.34.90   containerd://1.6.20

Name:    kube-master-g34-m1
Taints:  node-role.kubernetes.io/control-plane:NoSchedule
Name:    kube-worker-g34-m1
Taints:  <none>
```

| Élément | Sur votre cluster | Conséquence pour ce chapitre |
|---|---|---|
| Installation | kubeadm | kube-state-metrics **n'est pas** installé : vous le déployez (1.3) |
| Nœuds | 1 master + 1 worker | **Deux** agents Elastic : un par nœud (étape 2) |
| Taint du master | `control-plane:NoSchedule` | Vos applications tournent **toutes sur le worker** ; l'agent doit **tolérer** cette taint pour aller aussi sur le master |
| Runtime | containerd | Logs au format CRI dans `/var/log/pods` **du nœud qui exécute le pod** |
| Réseau | Calico | Rien à faire : l'agent passe par le réseau du nœud (`hostNetwork`) |
| metrics-server | Installé | Sert `kubectl top` : vue instantanée, **sans historique** |
| kubeconfig | `~/.kube/config` (copie de `/etc/kubernetes/admin.conf`) | `kubectl` fonctionne sans `sudo` |

> **⚠️ Piège fréquent** — Si `kubectl` répond « connection refused » ou « permission denied », ce n'est presque jamais le cluster : c'est le kubeconfig. Vérifiez que `~/.kube/config` existe et vous appartient (`ls -l ~/.kube/config`). L'original, `/etc/kubernetes/admin.conf`, appartient à `root` : ne lancez pas `kubectl` avec `sudo` pour contourner le problème.

### 1.2 L'accès au kubelet

Le kubelet expose les métriques de consommation (via cAdvisor) sur le port 10250. L'agent y accède avec le jeton de son `ServiceAccount` : ce sont les droits `nodes/stats` et `nodes/metrics` du `ClusterRole` fourni.

Chaque nœud a **son** kubelet. Vérifiez les deux :

```bash
for N in $(kubectl get nodes -o name | cut -d/ -f2); do
  echo "== $N"
  kubectl get --raw "/api/v1/nodes/${N}/proxy/stats/summary" | head -c 200 ; echo
done
```

Si chaque nœud renvoie du JSON, les agents pourront collecter les métriques de consommation : chaque agent interroge **le kubelet de son propre nœud**.

### 1.3 kube-state-metrics : kubeadm ne le fournit pas

C'est le prérequis que tout le monde oublie, et sans lequel la moitié du chapitre est impossible.

```bash
kubectl apply -f manifests/10-kube-state-metrics.yaml
kubectl -n kube-system rollout status deploy/kube-state-metrics --timeout=120s
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-state-metrics -o wide   # sur le worker
```

| Source | Ce qu'elle fait | Ce qu'elle produit |
|---|---|---|
| **kubelet + cAdvisor** | **MESURE** la consommation réelle, depuis les cgroups | « ce pod consomme 340 millicœurs et 712 Mio » |
| **kube-state-metrics** | **DÉCLARE** l'état, lu depuis l'API — ne mesure rien | « ce conteneur a redémarré 7 fois, demande 200m de CPU, et son dernier arrêt est un `OOMKilled` » |
| Composants du control plane | Santé du cluster lui-même | Latence des appels API, file du scheduler |
| `metrics-server` | Sert `kubectl top` et l'autoscaling | **Aucun historique** : ce n'est pas une source d'observabilité |

> **À retenir** — **cAdvisor mesure, kube-state-metrics déclare.** « Ce pod utilise 340 millicœurs » vient de cAdvisor. « Ce pod a redémarré 7 fois et son dernier arrêt est un OOMKilled » vient de kube-state-metrics. La première phrase décrit la réalité, la seconde l'intention et l'état. **Il faut les deux pour conclure** — et c'est exactement pour cela qu'un `OOMKilled` est invisible sans kube-state-metrics.

> **⚠️ Piège fréquent** — « On a déjà les métriques, `metrics-server` est installé. » C'est le cas sur votre cluster, et `kubectl top nodes` répond. Mais non : `metrics-server` ne conserve **aucun** historique. Il alimente `kubectl top` et l'autoscaling horizontal. Demandez à qui vous dit cela de vous montrer la consommation d'hier soir.

### 1.4 Le chemin d'une ligne de log

```text
  ① Le processus dans le conteneur écrit sur stdout / stderr
        echo "{\"log.level\":\"INFO\",\"message\":\"commande traitee\"}"

  ② Le container runtime (containerd) capture ces flux et les écrit dans
     un fichier sur le SYSTÈME DE FICHIERS DU NŒUD QUI EXÉCUTE LE POD :

        /var/log/pods/<namespace>_<pod>_<uid>/<conteneur>/0.log

     Format CRI, une ligne :
        2026-11-06T13:13:02.455123456Z stdout F {"log.level":"INFO",...}
        │                              │      │ │
        │                              │      │ └─ le message de l'application
        │                              │      └─ F = ligne complète, P = partielle
        │                              └─ flux d'origine : stdout ou stderr
        └─ horodatage ajouté par le runtime, en UTC, à la nanoseconde

  ③ Des liens symboliques normalisés sont créés dans /var/log/containers/

  ④ L'Elastic Agent DE CE NŒUD (DaemonSet : un par nœud) monte /var/log
     en LECTURE SEULE et lit

  ⑤ Il interroge l'API Kubernetes pour ENRICHIR : namespace, pod, conteneur,
     nœud, deployment, labels, image...

  ⑥ Envoi vers logs-kubernetes.container_logs-studentXX

  ⑦ Le kubelet limite la taille et le nombre de fichiers de log.
     AU-DELÀ, LES LIGNES SONT PERDUES sur le nœud.
```

> **À retenir** — Deux conséquences majeures. **Un** : l'application n'a **rien** à faire pour que ses logs soient collectés — écrire sur la sortie standard suffit. C'est pourquoi on n'écrit jamais dans un fichier depuis un conteneur. **Deux** : les logs du nœud sont rotatés et perdus. `kubectl logs` est une vue à court terme ; Kibana est la mémoire.

> **À retenir** — Sur un cluster à plusieurs nœuds, **les logs d'un pod sont sur le nœud qui l'exécute, et nulle part ailleurs**. Sur le master, `/var/log/pods` ne contient que etcd, kube-apiserver, CoreDNS, Calico… Les logs de ShopFlow sont sur le **worker**. C'est précisément pour cela qu'il faut un agent par nœud.

**✅ Vérification de l'étape 1**

```bash
sudo ls /var/log/pods | head                     # sur le master : pods du control plane
ssh <votre-worker> 'sudo ls /var/log/pods | head'  # sur le worker : vos applications
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-state-metrics -o wide
```

---

## Étape 2 — Déployer l'agent en DaemonSet

### 2.1 Pourquoi un DaemonSet

Les fichiers de log vivent sur le système de fichiers du nœud. Il faut donc un collecteur **par nœud**, qui monte `/var/log` : c'est la définition même d'un DaemonSet. Sur votre cluster, il y aura **deux** pods d'agent : un sur le master, un sur le worker. Si vous ajoutez un troisième nœud demain, Kubernetes y placera automatiquement un troisième agent.

| Alternative | Principe | Pourquoi on ne la retient pas |
|---|---|---|
| **DaemonSet** (retenue) | Un agent par nœud lit les fichiers du nœud | C'est la méthode standard : aucune modification des applications |
| Sidecar par pod | Un conteneur collecteur dans chaque pod | Multiplie la consommation par le nombre de pods ; justifié seulement si l'application écrit dans un fichier |
| Envoi direct depuis l'application | La bibliothèque de log écrit vers Elasticsearch | Couple l'application à la plateforme, perd les logs si elle est indisponible |

### 2.2 Le token ne va jamais dans un manifeste

Le formateur vous remet un fichier `installer-agent-k8s-studentXX.sh`. Copiez-le sur votre **master** (dans votre dossier personnel), puis :

```bash
bash ~/installer-agent-k8s-studentXX.sh          # crée le namespace et le Secret
kubectl apply -f manifests/20-elastic-agent-daemonset.yaml
kubectl -n elastic-agent rollout status ds/elastic-agent --timeout=180s
```

Ce que fait le fichier du formateur, et rien de plus :

```bash
kubectl create namespace elastic-agent
kubectl -n elastic-agent create secret generic elastic-agent-creds \
  --from-literal=fleet-url='https://…' \
  --from-literal=enrollment-token='…'
```

Le manifeste du DaemonSet lit ces deux valeurs dans le Secret (`secretKeyRef`) : il ne contient **aucun secret** et peut donc être publié dans Git.

> **⚠️ Piège fréquent** — Ce token est celui de la politique `efi-studentXX-k8s`, **et pas** celui des chapitres 1 et 2. Un token est lié à **une** politique, et la politique détermine ce qui est collecté. Si vous enrôlez le DaemonSet avec le token de la VM Tomcat, les agents démarreront, seront `Healthy`… et ne collecteront rien de Kubernetes. Aucune erreur ne vous le signalera.

> **⚠️ Ne partagez pas ce fichier** et ne le commitez pas : le token permet d'enrôler n'importe quelle machine dans votre politique. Une fois le Secret créé, vous pouvez le supprimer : `rm ~/installer-agent-k8s-studentXX.sh`.

### 2.3 Ce que l'agent monte, et pourquoi

| Montage | Usage | Si absent |
|---|---|---|
| `/var/log` (lecture seule) | Lire les fichiers de logs des conteneurs | Aucun log collecté |
| `/proc` | Métriques système du nœud | Pas de métriques d'hôte |
| `/sys/fs/cgroup` | Métriques CPU et mémoire des conteneurs | Pas de métriques de conteneur |
| Accès à l'API Kubernetes (RBAC) | Enrichir avec les métadonnées | Des logs **sans nom de pod** : inexploitables |
| `/var/lib/elastic-agent-managed/…/state` (hostPath) | Conserver l'identité Fleet de l'agent **sur le nœud** | Chaque redémarrage du pod crée un **nouvel** agent dans Fleet, l'ancien reste « Offline » |
| `/etc/machine-id` | Identifiant stable du nœud | Métadonnées d'hôte incomplètes |
| Secret de la CA (facultatif) | Valider le certificat de Fleet Server s'il vient d'une CA privée | Échec d'enrôlement `x509` |

Deux points du manifeste méritent attention :

- `tolerations` sur `node-role.kubernetes.io/control-plane` : kubeadm pose sur le master la taint `control-plane:NoSchedule`, qui en interdit l'accès aux pods ordinaires. Sans cette tolérance, le DaemonSet n'a **qu'un pod**, sur le worker : vos applications sont collectées, mais **pas** les logs du control plane (etcd, kube-apiserver, CoreDNS) ni les métriques du master. Et aucune erreur ne le signale : `kubectl get ds` affiche simplement `DESIRED 1`.
- `requests` et `limits` sur le DaemonSet : un collecteur non borné peut provoquer l'éviction de pods applicatifs. L'outil d'observation deviendrait la cause de l'incident.

**✅ Vérification de l'étape 2** — **deux** pods d'agent (un par nœud), tous `Running`, et **deux** agents visibles dans **Fleet → Agents**, rattachés à `efi-studentXX-k8s` et nommés d'après les nœuds.

```bash
kubectl -n elastic-agent get ds,pods -o wide
```

```text
NAME           DESIRED   CURRENT   READY   ...
elastic-agent  2         2         2       ...

NAME                  READY   STATUS    NODE
elastic-agent-4x7kq   1/1     Running   kube-master-g34-m1
elastic-agent-p2mnd   1/1     Running   kube-worker-g34-m1
```

```bash
kubectl -n elastic-agent logs ds/elastic-agent --tail=30   # (un seul des deux pods)
for P in $(kubectl -n elastic-agent get pods -o name); do
  echo "== $P"; kubectl -n elastic-agent logs "$P" --tail=200 | grep -i -m3 'error\|fail'
done
```

> **💡 Qui collecte quoi ?** Les deux agents ne font pas tout à fait le même travail. **Chacun** lit les logs et interroge le kubelet de **son** nœud. Les données de niveau **cluster** (kube-state-metrics, events) ne sont collectées que par **un seul** agent, élu « leader » grâce à un objet `Lease`. Sans cette élection, tout serait en double. Si le leader disparaît, l'autre agent prend le relais.

---

## Étape 3 — Ce qui est collecté

### 3.1 Les data streams

| Data stream | Source | Contenu |
|---|---|---|
| `logs-kubernetes.container_logs-studentXX` | Fichiers du nœud | `stdout`/`stderr` de tous les conteneurs |
| `metrics-kubernetes.container-studentXX` | kubelet / cAdvisor | CPU, mémoire, I/O **mesurés** par conteneur |
| `metrics-kubernetes.pod-studentXX` | kubelet | CPU, mémoire, réseau au niveau du pod |
| `metrics-kubernetes.node-studentXX` | kubelet | CPU, mémoire, système de fichiers du nœud |
| `metrics-kubernetes.state_pod-studentXX` | kube-state-metrics | Phase, conditions, nœud d'affectation |
| `metrics-kubernetes.state_container-studentXX` | kube-state-metrics | Redémarrages, `ready`, requests/limits **déclarés**, **raison du dernier arrêt** |
| `metrics-kubernetes.state_deployment-studentXX` | kube-state-metrics | Réplicas désirés, disponibles |
| `metrics-kubernetes.state_node-studentXX` | kube-state-metrics | Conditions, capacité, allocatable |
| `metrics-kubernetes.event-studentXX` | API Kubernetes | `FailedScheduling`, `BackOff`, `Killing`, `Unhealthy` |

> **⚠️ À vérifier sur votre plateforme** — La liste réellement collectée dépend de ce qui a été activé dans l'intégration et des droits de l'agent. Les jeux de données `state_*` exigent kube-state-metrics dans le cluster. Commencez par inventorier dans **Index Management → Data streams** : ce qui manque s'explique, ce qui est supposé présent se vérifie.

> **💡 Deux nœuds dans les données** — Les data streams `node`, `container`, `pod` et `container_logs` contiennent les données **des deux nœuds** : filtrez par `kubernetes.node.name` pour comparer le master et le worker. `state_node` vous donne leurs conditions (`Ready`, `MemoryPressure`…) et leur capacité allouable.

### 3.2 Requests, limits, et leurs conséquences

```text
  requests.cpu     = RÉSERVATION pour l'ordonnancement. Le scheduler ne
                     place le pod que sur un nœud ayant cette capacité
                     LIBRE (réservée, pas utilisée).
                     -> requests trop élevés = pods Pending alors que le
                        cluster semble vide.

  limits.cpu       = PLAFOND. Au-delà, le conteneur est THROTTLÉ : il n'est
                     pas tué, il est RALENTI.
                     -> latence en hausse, AUCUNE erreur.

  limits.memory    = PLAFOND STRICT. Au-delà : OOMKILLED immédiat, sans
                     préavis, sans trace dans les logs applicatifs.
                     La mémoire n'est pas compressible : on ne peut pas
                     « ralentir » un dépassement mémoire.

  Classes de QoS, déduites de vos requests/limits :
    Guaranteed  requests == limits partout   -> évincé en DERNIER
    Burstable   requests < limits            -> évincé ensuite
    BestEffort  ni requests ni limits        -> ÉVINCÉ EN PREMIER
```

| Situation | Symptôme côté application | Métrique qui le révèle |
|---|---|---|
| Throttling CPU | Latence en hausse, **aucune** erreur, aucun redémarrage | CPU plafonnant au niveau de la limite |
| OOMKilled | Coupure brutale, redémarrage | Compteur de redémarrages + **raison du dernier arrêt** |
| Requests surévalués | Pods `Pending` alors que les nœuds semblent vides | Somme des requests comparée à l'allocatable |
| Requests sous-évalués | Pods évincés sous tension | Classe de QoS, conditions de pression du nœud |
| Aucune limite | Un pod peut consommer tout le nœud | Absence du champ de limite dans les métriques d'état |

> **Bonne pratique** — Le dimensionnement correct est **séquentiel, et il commence par la mesure** : déployer sans limite serrée dans un environnement contrôlé, mesurer la consommation réelle sous charge représentative, poser `requests` au niveau du P50 observé et `limits` au P99 majoré d'une marge. Des valeurs « au cas où », sans aucune mesure, produisent les deux pathologies opposées : capacité gelée et throttling permanent.

### 3.3 Les champs à connaître, classés

| Champ | Catégorie | Signification |
|---|---|---|
| `kubernetes.container.cpu.usage.nanocores` | **consommation** | CPU consommé (1 cœur = 10⁹ nanocores) |
| `kubernetes.container.cpu.usage.limit.pct` | consommation / capacité | Part de la limite CPU : proche de 1 = throttling probable |
| `kubernetes.container.memory.usage.bytes` | consommation | Mémoire utilisée, **cache de pages inclus** |
| `kubernetes.container.memory.workingset.bytes` | consommation | Mémoire **active** : c'est elle que le noyau compare à la limite |
| `kubernetes.container.memory.limit.bytes` | **capacité** | Limite déclarée dans le manifeste |
| `kubernetes.container.status.restarts` | **état** | Nombre de redémarrages (compteur **cumulé**) |
| `kubernetes.container.status.last_terminated_reason` | état | `OOMKilled`, `Error`, `Completed` — **le champ décisif** |
| `kubernetes.container.status.ready` | état | Le conteneur passe-t-il sa readiness probe |
| `kubernetes.pod.status.phase` | état | `Pending`, `Running`, `Succeeded`, `Failed`, `Unknown` |
| `kubernetes.pod.status.ready` | état | Le pod reçoit-il du trafic |
| `kubernetes.node.memory.allocatable.bytes` | capacité | Mémoire réellement allouable aux pods |
| `kubernetes.event.reason` | état | `OOMKilling`, `FailedScheduling`, `BackOff` |

> **⚠️ Piège fréquent** — Deux mesures de mémoire coexistent et ne sont **pas** interchangeables. `memory.usage.bytes` inclut le cache de pages, qui est récupérable : une valeur élevée n'est pas forcément un problème. `memory.workingset.bytes` est la mémoire active, et c'est **celle que le noyau compare à la limite** pour décider d'un OOMKill. Pour diagnostiquer un `OOMKilled`, raisonnez sur le working set.

> **À retenir** — `Running` n'est pas `Ready`. Un pod peut être `Running` tout en échouant sa readiness probe : il ne reçoit alors **aucun trafic** du Service, mais il apparaît « vivant » dans un décompte naïf. Un dashboard qui compte les pods `Running` sans regarder `Ready` peut afficher « 2/2 pods en marche » pendant que le service est totalement indisponible.

---

## Étape 4 — Déployer l'application et chercher

```bash
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/30-shopflow-demo.yaml
kubectl -n studentXX rollout status deploy/shopflow-worker --timeout=120s
kubectl -n studentXX logs -l app.kubernetes.io/name=shopflow-worker --tail=5 --prefix
```

L'application écrit du JSON ECS sur `stdout`. Aucune image à construire, aucun parsing à écrire : les annotations `co.elastic.logs/json.*` du manifeste demandent le décodage JSON **pour ce pod uniquement**, sans toucher à la politique globale.

> **⚠️ À vérifier sur votre plateforme** — Ces annotations ne sont prises en compte que si les « hints » d'autodiscover sont activés dans la configuration de l'agent. Si vos champs restent dans `message` au lieu d'être décomposés, c'est la première chose à vérifier — avant de conclure que vos annotations sont fausses. <!-- À VÉRIFIER : activation des hints d'autodiscover dans l'intégration Kubernetes en 9.5.5, et nom exact de l'option côté Fleet. -->

### 4.1 Les métadonnées, c'est-à-dire la valeur ajoutée

| Champ | Usage typique |
|---|---|
| `kubernetes.namespace` | Cloisonner les recherches |
| `kubernetes.pod.name` | Identifier une instance précise |
| `kubernetes.pod.uid` | Distinguer deux pods homonymes successifs |
| `kubernetes.container.name` | Isoler un conteneur d'un pod multi-conteneurs |
| `kubernetes.node.name` | Tester l'hypothèse « c'est ce nœud » |
| `kubernetes.deployment.name` | Regrouper toutes les générations d'un déploiement |
| `kubernetes.labels.*` | **Vos dimensions d'analyse** : application, composant, version |
| `container.image.name` | Rattacher une erreur à une version d'image |

> **Bonne pratique** — Adoptez dès le départ les labels recommandés — `app.kubernetes.io/name`, `app.kubernetes.io/component`, `app.kubernetes.io/version` — et vous pourrez segmenter n'importe quel dashboard par application, composant et version sans travail supplémentaire. Des labels anarchiques produisent des dashboards impossibles à construire.

### 4.2 `kubectl` ou Kibana ?

| Besoin | Outil | Pourquoi |
|---|---|---|
| Voir ce que fait un pod **maintenant** | `kubectl logs -f` | Immédiat, sans délai d'ingestion |
| Comprendre pourquoi un pod ne démarre pas | `kubectl describe pod` | Donne les conditions et les events, que les logs ne contiennent pas |
| Lire les logs d'un pod disparu il y a trois jours | **Kibana** | Le fichier du nœud n'existe plus |
| Compter les erreurs par version d'image sur une semaine | **Kibana** | Agrégation impossible avec `kubectl` |
| Corréler une erreur applicative avec un pic de CPU | **Kibana** | Métriques et logs dans le même outil |
| Prouver un incident à un tiers | **Kibana** | Historique stable, partageable par URL |

> **À retenir** — Le réflexe professionnel n'est ni « tout dans Kibana » ni « `kubectl` suffit ». C'est : `kubectl` pour l'immédiat et l'état du cluster, Kibana pour l'historique, l'agrégation et la corrélation. Un exploitant qui ne sait faire que l'un des deux perd du temps dans la moitié des situations.

### 4.3 Requêtes KQL

```text
# ── Logs ───────────────────────────────────────────────────────────────────
kubernetes.namespace : "studentXX"
kubernetes.deployment.name : "shopflow-worker"
kubernetes.labels.app_kubernetes_io/name : "shopflow-worker"
kubernetes.namespace : "studentXX" and log.level : "ERROR"
message : ("Exception" or "OutOfMemoryError" or "timeout")
kubernetes.node.name : "kube-worker-*"           # vos applications
kubernetes.node.name : "kube-master-*" and kubernetes.namespace : "kube-system"
container.image.name : "*busybox*"
error.message : * or tags : "_json_parse_failure"        # DOIT rester vide

# ── Métriques : état ───────────────────────────────────────────────────────
kubernetes.container.status.restarts > 0
kubernetes.container.status.last_terminated_reason : "OOMKilled"
kubernetes.pod.status.phase : "pending"
kubernetes.pod.status.phase : "running" and kubernetes.pod.status.ready : false
kubernetes.event.reason : ("FailedScheduling" or "BackOff" or "OOMKilling" or "Unhealthy")

# ── Métriques : consommation contre capacité ───────────────────────────────
kubernetes.container.memory.usage.limit.pct > 0.9
kubernetes.container.cpu.usage.limit.pct > 0.95
not kubernetes.container.memory.limit.bytes : *     # conteneurs sans limite

# ── Nœud ───────────────────────────────────────────────────────────────────
kubernetes.node.status.ready : false
  or kubernetes.node.status.memory_pressure : true
  or kubernetes.node.status.disk_pressure : true
```

> **⚠️ Piège fréquent** — Les valeurs de `kubernetes.pod.status.phase` peuvent être en minuscules (`running`) ou en capitales (`Running`) selon la version de l'intégration. Une comparaison qui ne correspond à rien ne déclenche **jamais**, et c'est silencieux. Relevez la valeur réelle dans Discover avant d'écrire une requête ou une règle d'alerte.

**✅ Vérification de l'étape 4**

```bash
ES_API_KEY='<votre-cle>' ./scripts/verif-k8s.sh
```

Le script vérifie les quatre points de contrôle, liste les data streams avec leur volume, affiche les métadonnées d'un document réel, et construit le tableau de diagnostic directement depuis Elasticsearch.

---

## Étape 5 — Le dashboard et le tableau de diagnostic

Quatre niveaux de lecture, parce que les questions d'un exploitant de cluster et celles d'une équipe applicative n'ont rien en commun. Sur votre cluster à deux nœuds, `k8s-nodes` devient intéressant : le master et le worker n'ont **pas du tout** la même charge, puisque toutes vos applications sont sur le worker. Le troisième dashboard reste celui que vous utiliserez tous les jours.

| Dashboard | Question principale | Panneaux essentiels |
|---|---|---|
| `k8s-cluster-studentXX` | Le cluster est-il sain ? | Nœuds prêts, pods par phase, **pods non prêts**, CPU utilisé contre réservé, redémarrages par pod, events par raison |
| `k8s-nodes-studentXX` | Un nœud est-il en difficulté ? | CPU, mémoire, disque par nœud, conditions, pods par nœud |
| `k8s-pods-studentXX` | Mon application va-t-elle bien ? | CPU et mémoire **en % de la limite**, **tableau de diagnostic**, logs d'erreur |
| `k8s-namespaces-studentXX` | Qui consomme quoi ? | CPU, mémoire, pods et quota par namespace |

Les formules qui comptent :

```text
# CPU en pourcentage de la LIMITE : le prédicteur de throttling
average(kubernetes.container.cpu.usage.limit.pct) * 100

# Variante si ce champ n'existe pas sur votre version
average(kubernetes.container.cpu.usage.nanocores)
  / (average(kubernetes.container.cpu.limit.cores) * 1000000000) * 100

# Mémoire en pourcentage de la limite : le prédicteur d'OOMKill
# (working set, et non usage : c'est le working set que le noyau compare)
average(kubernetes.container.memory.workingset.bytes)
  / average(kubernetes.container.memory.limit.bytes) * 100

# Redémarrages SUR LA FENÊTRE (le champ est un compteur cumulé)
max(kubernetes.container.status.restarts) - min(kubernetes.container.status.restarts)

# Capacité GELÉE : réservée mais non utilisée
sum(kubernetes.container.cpu.request.cores) - sum(kubernetes.container.cpu.usage.nanocores) / 1000000000
```

> **À retenir** — Le panneau « CPU utilisé contre CPU réservé » est le plus utile et le plus souvent absent. Il répond à une question que tout le monde se pose et que personne ne sait mesurer : « pourquoi mon cluster est-il plein alors qu'il ne fait rien ? ». L'écart entre les deux courbes, c'est de la capacité **gelée** par des requests surévalués.

### Le tableau de diagnostic : six colonnes qui remplacent dix graphiques

1. Lens → **Table**, data view `metrics-kubernetes.*`.
2. Lignes : `kubernetes.pod.name`, Top 50, trié par les redémarrages.
3. Colonne 1 : `max(kubernetes.container.status.restarts)` → « Redémarrages ».
4. Colonne 2 : `last_value(kubernetes.container.status.last_terminated_reason)` → « Raison du dernier arrêt ».
5. Colonne 3 : CPU en % de la limite → « CPU % limite ».
6. Colonne 4 : mémoire (working set) en % de la limite → « Mém % limite ».
7. Colonne 5 : `last_value(kubernetes.pod.status.phase)` → « Phase ».
8. Colonne 6 : `last_value(kubernetes.container.status.ready)` → « Prêt ».
9. Mise en forme conditionnelle : rouge au-delà de 90 % de limite, rouge dès qu'il y a un redémarrage.

> **Bonne pratique** — Ce tableau seul qualifie la majorité des incidents Kubernetes. Un pod à `OOMKilled` avec 98 % de mémoire : diagnostic posé. Un pod à 99 % de CPU limite sans redémarrage : throttling. Un pod `Running` mais non prêt : sonde en échec. Trois colonnes bien choisies remplacent dix graphiques.

**✅ Vérification de l'étape 5** — depuis le dashboard cluster, vous atteignez les logs d'un pod problématique **en trois clics**. Et chaque dashboard porte un panneau Markdown : objectif, public, sources, limites connues.

---

## Étape 6 — Les six pannes

### L'arbre de diagnostic

```text
                       kubernetes.pod.status.phase ?
                                   │
        ┌──────────────────────┬───┴────────────┬──────────────────────┐
     PENDING                RUNNING          FAILED              aucun pod
        │                      │                │                     │
 event FailedScheduling   status.ready       restarts ↑          Deployment
 ou « exceeded quota »     = false ?            │                absent ou
        │                      │                │                replicas = 0
 ┌──────┴──────┐        ┌──────┴──────┐   last_terminated_reason ?
 │             │        │             │          │
Insufficient  nodeSelector  sonde en  CrashLoop  ├── OOMKilled ──► mémoire :
cpu/memory    ou taint     échec        │        │                 limite basse
 │             sans                     │        │                 ou fuite
requests vs    toleration               │        ├── Error ──────► logs applicatifs
allocatable                             │        │                 code de sortie
                                        │        └── Completed ───► normal (Job)
                                        │
                                        └── ImagePullBackOff ──► nom, tag,
                                            ErrImagePull          droits, secret

           PAS DE REDÉMARRAGE, PAS D'ERREUR, MAIS C'EST LENT ?
                                   │
                      cpu.usage.limit.pct proche de 1 ?
                      ┌────────────┴────────────┐
                    OUI                        NON
                     │                          │
            THROTTLING CPU            l'infrastructure est innocente :
            augmenter la limite       chercher dans le code, une
                                      dépendance, ou le nœud
```

Les quatre commandes de qualification, dans l'ordre :

```bash
kubectl -n studentXX get pods -o wide
kubectl -n studentXX describe pod "$POD" | sed -n '/Last State/,/Events/p'
kubectl -n studentXX logs "$POD" --previous
kubectl -n studentXX get events --sort-by=.lastTimestamp | tail -20
```

> **⚠️ Piège fréquent** — Par défaut, les **events** du cluster ne sont conservés qu'environ une heure. C'est l'argument décisif de leur collecte dans Elasticsearch : un `FailedScheduling` d'hier soir n'existe plus dans `kubectl get events`, mais il est toujours dans `metrics-kubernetes.event-studentXX`.

### Panne 1 — Pod Pending

```bash
kubectl apply -f scenarios/01-pending.yaml
```

| Signature | Valeur |
|---|---|
| Phase | `Pending` |
| Event déterminant | `FailedScheduling` |
| Message | « 0/2 nodes are available: 1 node(s) didn't match Pod's node affinity/selector, 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: } » |
| Métrique | `kubernetes.pod.status.phase : "pending"` |

Le message donne **une raison par nœud** : le scheduler a écarté le worker parce qu'il ne porte pas le label demandé, et le master à cause de sa taint. Avec deux nœuds, lisez toujours le message **en entier**.

Trois variantes à essayer (le détail est en commentaire dans `scenarios/01-pending.yaml`), et c'est le message qui donne la cause :

| Manifeste | Ce qu'on observe | Message | Cause réelle |
|---|---|---|---|
| `nodeSelector` inexistant | Pod `Pending` | didn't match node affinity/selector **+** untolerated taint | Aucun nœud ne correspond |
| `nodeSelector` sur le master (`node-role.kubernetes.io/control-plane: ""`) | Pod `Pending` | **untolerated taint** {control-plane} | Le master a de la place, mais sa taint l'interdit |
| 3 réplicas à `requests.memory: 900Mi` | 2 pods `Running`, le 3ᵉ **n'existe pas** | **exceeded quota**, dans les events du **ReplicaSet** | Le `ResourceQuota` (2Gi) refuse **avant** l'ordonnancement |

> **⚠️ Piège fréquent** — Dans la troisième variante, il n'y a **aucun** pod `Pending` : le pod refusé par le quota n'est jamais créé. `kubectl get pods` affiche 2 pods sains, et seul `kubectl describe rs -l app.kubernetes.io/name=panne-pending` explique le troisième manquant. C'est le genre de panne qu'une alerte sur les pods `Pending` ne verra jamais : seule la comparaison « réplicas désirés / disponibles » (`state_deployment`) la détecte.

> **À retenir** — Le scheduler raisonne sur les **requests déclarés**, pas sur la consommation mesurée. Si les pods existants réservent 90 % de la mémoire allouable en n'en utilisant que 30 %, il ne reste rien à réserver. C'est l'illustration la plus nette de la distinction consommation / capacité — et la raison pour laquelle « le cluster est vide » n'est pas un argument.

### Panne 2 — CrashLoopBackOff par configuration

```bash
kubectl apply -f scenarios/02-crashloop-config.yaml
```

| Signature | Valeur |
|---|---|
| Phase | `Running` puis `CrashLoopBackOff` |
| `Exit Code` | **1** |
| `Reason` | `Error` |
| Logs `--previous` | « variable obligatoire absente: DB_PASSWORD » |
| Métrique | `restarts` croissant, `last_terminated_reason : "Error"` |

Causes réelles, par ordre de fréquence : variable d'environnement ou secret manquant, dépendance indisponible au démarrage, limite mémoire trop basse, sonde trop agressive, commande erronée dans l'image.

### Panne 3 — CrashLoopBackOff fabriqué par une sonde

```bash
kubectl apply -f scenarios/03-crashloop-probe.yaml
```

L'application est **saine** : elle met 40 secondes à démarrer. La liveness probe la déclare morte au bout de 2 secondes, Kubernetes la tue, elle redémarre, et le cycle se répète indéfiniment.

| Signature | Panne 2 (configuration) | Panne 3 (sonde) |
|---|---|---|
| `Exit Code` | **1** | **137** (SIGKILL) |
| `Reason` | `Error` | `Error`, mais précédé d'un event `Unhealthy` |
| Logs applicatifs | **Un message d'erreur explicite** | **Aucune erreur** — l'application démarrait |
| Events | `BackOff` | **`Liveness probe failed`** puis `Killing` |

> **À retenir** — C'est la panne la plus instructive du chapitre : l'application n'a aucun problème, c'est la **supervision** qui la tue. Avant d'accuser une application de redémarrer en boucle, vérifiez `initialDelaySeconds`, `periodSeconds` et `failureThreshold` — et préférez une `startupProbe` pour les démarrages lents, comme dans le bloc de correction du manifeste.

### Panne 4 — OOMKilled

```bash
kubectl apply -f scenarios/04-oomkilled.yaml
```

| Signature | Valeur |
|---|---|
| `Last State` | `Terminated`, `Reason: OOMKilled`, `Exit Code: 137` |
| Métrique décisive | `kubernetes.container.status.last_terminated_reason : "OOMKilled"` |
| Courbe | Working set qui monte puis est **coupé net** — jamais de descente |
| Logs applicatifs | **Rien** |

> **À retenir** — La courbe en dents de scie **tronquées** est la signature visuelle de l'OOMKill : contrairement à un ramasse-miettes, la mémoire ne redescend jamais d'elle-même, elle est coupée. Et il n'y a **aucune** trace dans les logs : le noyau tue le processus immédiatement, sans lui laisser le temps d'écrire. C'est pourquoi `last_terminated_reason` — donc kube-state-metrics — est indispensable.

Pour une JVM (chapitre 2), posez-vous **toujours** la question de l'écart entre `-Xmx` et `limits.memory` : `-Xmx` ne borne que la heap, alors que le conteneur est tué sur la mémoire **totale** du processus. Un conteneur avec `limits.memory = 1Gi` et `-Xmx1g` est condamné à être tué, sans aucune `OutOfMemoryError` dans les logs Java. Visez une heap de 50 à 70 % de la limite.

### Panne 5 — ImagePullBackOff

```bash
kubectl apply -f scenarios/05-imagepull.yaml
```

| Signature | Valeur |
|---|---|
| Phase | `Pending`, conteneur `Waiting` |
| Raison | `ErrImagePull` puis `ImagePullBackOff` |
| Message | « manifest unknown » ou « not found » |

Causes : faute de frappe dans le nom ou le tag, tag supprimé, registre privé sans `imagePullSecrets`, registre injoignable depuis les nœuds, architecture d'image incompatible.

C'est la panne la plus rapide à qualifier — moins de 30 secondes si l'on sait où regarder. **Chronométrez-vous** : c'est l'objectif de l'exercice.

### Panne 6 — Throttling CPU

```bash
kubectl apply -f scenarios/06-throttling.yaml
```

| Signature | Valeur |
|---|---|
| Redémarrages | **0** |
| Erreurs | **0** |
| Pod | `Running` **et** `Ready` |
| Métrique décisive | `cpu.usage.limit.pct` en **plateau** juste sous 1 |
| Symptôme applicatif | Le temps annoncé par le conteneur (`event.duration`) augmente nettement |

Puis corrigez et comparez :

```bash
kubectl -n studentXX set resources deploy/panne-throttling --limits=cpu=1
kubectl -n studentXX logs -l app.kubernetes.io/name=panne-throttling --tail=5
```

> **À retenir** — Le throttling CPU est le problème le plus difficile à diagnostiquer de Kubernetes **parce qu'il ne produit aucune erreur**. Le conteneur fonctionne, ne redémarre pas, ne journalise rien d'anormal : il est simplement ralenti par le noyau. Le seul symptôme visible côté application est une latence dégradée — attribuée neuf fois sur dix à la base de données ou au réseau. Et **aucune alerte de disponibilité ne sonnerait** : tous les indicateurs restent au vert.

### Tableau de synthèse des six pannes

| Panne | Phase | Event déterminant | Métrique déterminante | Le seul indicateur qui suffisait |
|---|---|---|---|---|
| 1. Pending | `Pending` | `FailedScheduling` | `pod.status.phase` | Le **message** de l'event |
| 2. CrashLoop config | `CrashLoopBackOff` | `BackOff` | `restarts`, `reason: Error` | Les logs `--previous` |
| 3. CrashLoop sonde | `CrashLoopBackOff` | **`Liveness probe failed`** | `restarts`, exit 137 | L'**absence** de log d'erreur |
| 4. OOMKilled | `Running` cyclique | `OOMKilling` | **`last_terminated_reason`** | `last_terminated_reason` |
| 5. ImagePullBackOff | `Pending` | `Failed` / `BackOff` | `container.status.phase: waiting` | Le message « manifest unknown » |
| 6. Throttling | `Running`, `Ready` | **aucun** | **`cpu.usage.limit.pct`** | Le plateau à 1 de `limit.pct` |

### Les quatre règles d'alerte

| Règle | Niveau | Ce qu'elle détecte |
|---|---|---|
| `pods-redemarrages-studentXX` | 2 | Plus de 3 **nouveaux** redémarrages en 15 min (`max − min`, car le champ est cumulé) |
| `pods-non-prets-studentXX` | **1** | Pods `running` mais **non `ready`** de façon durable : la règle la plus oubliée |
| `oomkilled-studentXX` | 2 | `last_terminated_reason = OOMKilled` |
| `node-sous-pression-studentXX` | 3 | Nœud non prêt, `MemoryPressure`, `DiskPressure` (+ variante **throttling**) |

---

## Dépannage

| Symptôme | Cause la plus probable | Correction |
|---|---|---|
| `DESIRED 1` au lieu de 2 : pas d'agent sur le master | Tolérance `control-plane` absente | Les `tolerations` du manifeste fourni |
| Pod d'agent en `CreateContainerConfigError` | Secret `elastic-agent-creds` absent ou clé mal nommée | Relancer `installer-agent-k8s-studentXX.sh`, puis `kubectl -n elastic-agent get secret elastic-agent-creds -o yaml` (clés `fleet-url` et `enrollment-token`) |
| Plusieurs agents « Offline » en double dans Fleet | Pod recréé sans état persistant | Le volume `agent-state` du manifeste fourni ; supprimer les doublons dans Fleet |
| Pas de métriques `node`/`pod`/`container`, erreur `no such host` vers `:10250` dans les logs de l'agent | Le nom du nœud n'est pas résolu par le DNS | 🔒 Formateur : hôte kubelet de l'intégration = `https://${env.NODE_IP}:10250` |
| Pas de `state_*`, erreur vers `kube-state-metrics:8080` | L'agent est dans `elastic-agent`, kube-state-metrics dans `kube-system` | 🔒 Formateur : hôte = `kube-state-metrics.kube-system.svc:8080` |
| `ssh` vers le worker refusé pour lire `/var/log/pods` | Pas d'accès SSH entre les nœuds | Passer par Kibana : c'est justement ce que la collecte apporte |
| Agent `Healthy` mais aucune donnée Kubernetes | Enrôlé avec le token de la politique **de l'hôte** | Utiliser le token de `efi-studentXX-k8s` |
| Logs sans nom de pod ni namespace | RBAC insuffisant : l'agent ne peut pas lire l'API | Appliquer `ClusterRole` et `ClusterRoleBinding` |
| Aucun data stream `state_*` | kube-state-metrics absent ou non collecté | Le déployer, puis vérifier le jeu de données dans l'intégration |
| `x509` à l'enrôlement du DaemonSet | Fleet Server signé par une CA privée | Demander au formateur le Secret `elastic-agent-ca` et la variable `FLEET_CA` |
| Champs JSON non décomposés, tout dans `message` | Hints d'autodiscover non activés | Opération formateur ; repli : décodage global ou pipeline `@custom` |
| `kubectl logs --previous` répond « not found » | Fichier rotaté par le kubelet | Passer par Kibana : c'est exactement son intérêt |
| Pods `Pending` au lieu de démarrer | `ResourceQuota` atteint | `kubectl describe ns studentXX`, section quotas |
| Une requête sur `phase` ne renvoie jamais rien | Casse de la valeur (`running` / `Running`) | Relever la valeur réelle dans Discover |
| Métrique de throttling introuvable | Nom non stable selon la version | Repli : `cpu.usage.nanocores` sur `cpu.limit.cores` |
| L'agent consomme beaucoup sur le nœud | Pas de `limits` sur le DaemonSet | Les poser : l'observateur ne doit pas déstabiliser l'observé |
| Image non téléchargeable depuis le worker | Registre public inaccessible | Demander l'image pré-chargée ou le miroir interne. C'est le **worker** qui télécharge les images de vos pods (et le master celle de l'agent) |

### Nettoyage

```bash
./scripts/reset.sh      # supprime les déploiements de panne, garde la collecte
```

Ne supprimez **pas** le DaemonSet : le chapitre 4 s'appuie dessus.

---

## Livrables du chapitre

1. La sortie de `kubectl -n elastic-agent get ds,pods -o wide` : **deux** agents, un par nœud, et la capture de Fleet montrant les deux.
2. Un document de `logs-kubernetes.container_logs-studentXX` en vue JSON, avec les métadonnées commentées.
3. Le classement de dix champs en **consommation / état / capacité**.
4. Le dashboard `k8s-pods-studentXX` avec son **tableau de diagnostic** à six colonnes.
5. Le tableau des six pannes : phase, event, métrique, temps mis pour conclure, et l'indicateur qui suffisait.
6. La réponse argumentée sur la distinction entre les pannes 2 et 3, sur des éléments **observables**.
7. Pour la panne 6 : la démonstration qu'aucune alerte de disponibilité n'aurait sonné.
8. Une fiche d'astreinte d'une page : l'arbre de diagnostic, avec la commande ou la requête exacte à chaque branche.

---

**➡️ Chapitre suivant** : Projet final — supervision d'une application trois tiers sur Kubernetes.
