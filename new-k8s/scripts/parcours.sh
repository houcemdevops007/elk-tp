#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  parcours.sh — séquence complète du chapitre 3, pour {{STUDENT_ID}}
#  Cluster kubeadm à deux nœuds (1 master + 1 worker), dont vous êtes
#  administrateur. TOUTES ces commandes se lancent SUR LE MASTER.
# ─────────────────────────────────────────────────────────────────────────────

# ÉTAPE 0 — Personnaliser les fichiers du chapitre ---------------------------
bash scripts/remplir-variables.sh {{STUDENT_ID}}              # simulation
bash scripts/remplir-variables.sh {{STUDENT_ID}} --appliquer

# ÉTAPE 1 — Prérequis --------------------------------------------------------
systemctl is-active kubelet containerd           # active / active
export KUBECONFIG={{KUBECONFIG}}
kubectl version 2>/dev/null | head -3
kubectl get nodes -o wide                        # {{MASTER_NAME}} + {{WORKER_NAME}}
kubectl describe nodes | grep -E '^Name:|^Taints:'
kubectl get pods -A -o wide | grep -E 'calico|coredns|metrics-server'
kubectl top nodes 2>/dev/null || echo "(metrics-server absent : sans effet sur ce TP)"

#  CHAQUE NŒUD A SON KUBELET, et chaque agent interroge celui de son propre
#  nœud, sur le port 10250. Vérifiez les deux :
for N in $(kubectl get nodes -o name | cut -d/ -f2); do
  echo "== $N"
  kubectl get --raw "/api/v1/nodes/${N}/proxy/stats/summary" | head -c 200 ; echo
done

#  Les fichiers de log vivent sur le NŒUD QUI EXÉCUTE LE POD : sur le master,
#  /var/log/pods ne contient que le control plane. Vos applications sont sur
#  le worker, et nulle part ailleurs.
sudo ls /var/log/pods | head
ssh {{WORKER_NAME}} 'sudo ls /var/log/pods | head' 2>/dev/null \
  || echo "(pas d'accès SSH au worker : passez par Kibana, c'est justement l'intérêt)"

# ÉTAPE 2 — kube-state-metrics (kubeadm ne le fournit pas) -------------------
kubectl apply -f manifests/10-kube-state-metrics.yaml
kubectl -n kube-system rollout status deploy/kube-state-metrics --timeout=120s
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-state-metrics -o wide

# ÉTAPE 3 — Namespace, quota et limites --------------------------------------
kubectl apply -f manifests/00-namespace.yaml
kubectl describe ns {{NAMESPACE}} | sed -n '/Resource Quotas/,$p'

# ÉTAPE 4 — Agent en DaemonSet -----------------------------------------------
#  Le token n'apparaît JAMAIS dans un manifeste : le fichier remis par le
#  formateur crée le namespace et le Secret, puis vous pouvez le supprimer.
bash ~/installer-agent-k8s-{{STUDENT_ID}}.sh
kubectl apply -f manifests/20-elastic-agent-daemonset.yaml
kubectl -n elastic-agent rollout status ds/elastic-agent --timeout=180s
kubectl -n elastic-agent get ds,pods -o wide

# ✅ Vérification : DEUX pods d'agent, un par nœud, tous Running, et DEUX
#    agents dans Fleet -> Agents, rattachés à la politique {{POLICY_K8S}}.
#    DESIRED 1 au lieu de 2 = la tolérance control-plane manque.
for P in $(kubectl -n elastic-agent get pods -o name); do
  echo "== $P"; kubectl -n elastic-agent logs "$P" --tail=200 | grep -i -m3 'error\|fail'
done

# ÉTAPE 5 — Application de démonstration -------------------------------------
kubectl apply -f manifests/30-shopflow-demo.yaml
kubectl -n {{NAMESPACE}} rollout status deploy/shopflow-worker --timeout=120s
kubectl -n {{NAMESPACE}} logs -l app.kubernetes.io/name=shopflow-worker --tail=5 --prefix

# ✅ Vérification de la collecte
ES_API_KEY='<votre-cle>' ./scripts/verif-k8s.sh

# ÉTAPE 6 — Les six pannes, une par une --------------------------------------
#  Pour chacune : appliquer, qualifier en moins de deux minutes, corriger.
kubectl apply -f scenarios/01-pending.yaml
kubectl apply -f scenarios/02-crashloop-config.yaml
kubectl apply -f scenarios/03-crashloop-probe.yaml
kubectl apply -f scenarios/04-oomkilled.yaml
kubectl apply -f scenarios/05-imagepull.yaml
kubectl apply -f scenarios/06-throttling.yaml

#  Les quatre commandes de qualification, dans l'ordre. POD est le nom du
#  pod à examiner : relevez-le dans la sortie de la premiere commande.
POD="panne-oom-xxxxxxxxx-xxxxx"
kubectl -n {{NAMESPACE}} get pods -o wide
kubectl -n {{NAMESPACE}} describe pod "$POD" | sed -n '/Last State/,/Events/p'
kubectl -n {{NAMESPACE}} logs "$POD" --previous
kubectl -n {{NAMESPACE}} get events --sort-by=.lastTimestamp | tail -20

# ÉTAPE 7 — Nettoyage --------------------------------------------------------
./scripts/reset.sh
