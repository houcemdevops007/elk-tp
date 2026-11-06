#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  reset.sh — remet le namespace {{NAMESPACE}} dans un état sain
#
#  Supprime les déploiements de panne, laisse l'application de démonstration
#  et la chaîne de collecte en place.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="{{KUBECONFIG}}"
NS="{{NAMESPACE}}"

echo "== Suppression des déploiements de scénario =="
kubectl -n "$NS" delete deploy -l 'efi.formation/scenario' --ignore-not-found

echo "== État après nettoyage =="
kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -5

echo "== Rétablissement de l'application de démonstration =="
kubectl -n "$NS" rollout restart deploy/shopflow-worker 2>/dev/null || true
kubectl -n "$NS" rollout status deploy/shopflow-worker --timeout=90s 2>/dev/null || true

cat <<'FIN'

À faire à la main, en fin de formation :
  - désactiver vos règles d'alerte dans Kibana (une règle oubliée continue
    de s'exécuter indéfiniment sur le cluster partagé) ;
  - conserver vos dashboards : ce sont des livrables ;
  - NE PAS supprimer le DaemonSet : le chapitre 4 s'appuie dessus.
Pour tout supprimer malgré tout :
  kubectl delete ns {{NAMESPACE}} elastic-agent
FIN
