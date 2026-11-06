#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  parcours.sh — séquence complète du chapitre 3, pour {{STUDENT_ID}}
#  Cluster k3s local, dont vous êtes administrateur.
# ─────────────────────────────────────────────────────────────────────────────

# ÉTAPE 1 — Prérequis --------------------------------------------------------
sudo systemctl status k3s --no-pager | head -5
export KUBECONFIG={{KUBECONFIG}}
kubectl version --short 2>/dev/null || kubectl version
kubectl get nodes -o wide
kubectl top nodes 2>/dev/null || echo "(metrics-server absent : sans effet sur ce TP)"

#  Le kubelet expose ses métriques sur le port 10250 : l'agent y accède avec
#  le jeton de son ServiceAccount. Vérification de la lisibilité :
kubectl get --raw "/api/v1/nodes/$(kubectl get node -o jsonpath='{.items[0].metadata.name}')/proxy/stats/summary" \
  | head -c 300 ; echo

#  Les fichiers de log des conteneurs, sur le NŒUD :
sudo ls /var/log/pods | head
sudo ls /var/log/containers | head -3

# ÉTAPE 2 — kube-state-metrics (k3s ne le fournit pas) -----------------------
kubectl apply -f manifests/10-kube-state-metrics.yaml
kubectl -n kube-system rollout status deploy/kube-state-metrics --timeout=120s
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-state-metrics

# ÉTAPE 3 — Namespace, quota et limites --------------------------------------
kubectl apply -f manifests/00-namespace.yaml
kubectl describe ns {{NAMESPACE}} | sed -n '/Resource Quotas/,$p'

# ÉTAPE 4 — Agent en DaemonSet -----------------------------------------------
kubectl create namespace elastic-agent --dry-run=client -o yaml | kubectl apply -f -
#  Le token n'apparaît JAMAIS dans un manifeste : il va dans un Secret.
kubectl -n elastic-agent create secret generic elastic-agent-creds \
  --from-literal=enrollment-token='<votre-token-k8s>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n elastic-agent create secret generic elastic-agent-ca \
  --from-file=ca.crt={{CA_PATH}} \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/20-elastic-agent-daemonset.yaml
kubectl -n elastic-agent rollout status ds/elastic-agent --timeout=180s
kubectl -n elastic-agent get ds,pods -o wide

# ✅ Vérification : un pod par nœud, tous Running, et l'agent visible dans
#    Fleet -> Agents, rattaché à la politique {{POLICY_K8S}}.
kubectl -n elastic-agent logs ds/elastic-agent --tail=30

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
