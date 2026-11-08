#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  INCIDENT 1 — La base de données devient indisponible ({{STUDENT_ID}})
#
#  À LANCER PAR LE FORMATEUR, ou par le candidat en auto-évaluation APRÈS
#  avoir rendu sa copie : la nature de l'incident ne doit pas être connue
#  à l'avance.
#
#  Mécanisme : le StatefulSet de la base est réduit à zéro réplica. Les
#  données ne sont PAS détruites (le volume persiste) : l'incident est
#  réversible.
#
#  Usage :  ./01-db-indisponible.sh [duree_s]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="{{KUBECONFIG}}"
NS="{{NAMESPACE}}"
DUREE="${1:-600}"

echo "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') · début de l'incident 1 =="
kubectl -n "$NS" scale statefulset/shopflow-db --replicas=0
kubectl -n "$NS" get pods -l app.kubernetes.io/component=database

echo "== génération de trafic pendant ${DUREE}s (dans un autre terminal) =="
cat <<'FIN'
  ./charge.sh 600 &
Ce que le candidat doit observer, dans cet ordre :
  1. frontal   : /health répond toujours 200 (il ne traverse pas le backend)
  2. frontal   : /api/* renvoie des 503, la latence CHUTE (échec rapide)
  3. backend   : log ERROR « base de donnees injoignable »
  4. backend   : le pod reste Ready — son /health ne teste pas la base
  5. base      : 0 pod, event « Scaled down », PAS d'erreur applicative
  6. SLO       : le budget d'erreur du tunnel de commande s'effondre
La question de diagnostic : pourquoi la latence BAISSE-t-elle pendant une
panne ? Parce qu'un échec rapide est plus rapide qu'un succès. Une alerte
construite sur la seule latence ne verrait donc RIEN.
FIN

sleep "$DUREE"

echo "== $(date -u '+%Y-%m-%dT%H:%M:%SZ') · rétablissement =="
kubectl -n "$NS" scale statefulset/shopflow-db --replicas=1
kubectl -n "$NS" rollout status statefulset/shopflow-db --timeout=180s
curl -s "http://localhost:{{NODE_PORT}}/api/db" ; echo
echo "== incident 1 terminé =="
