#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  build-configmap-war.sh — place le WAR du chapitre 2 dans un ConfigMap
#
#  Pourquoi : déployer un WAR dans Kubernetes demande normalement de
#  construire une image et de la publier dans un registre. Le WAR de TP pèse
#  quelques kilo-octets : un ConfigMap suffit, et cela évite une dépendance
#  à un registre pendant la formation.
#
#  LIMITE À CONNAÎTRE : un ConfigMap est plafonné à environ 1 Mio. Cette
#  astuce ne vaut QUE pour un artefact minuscule. Pour une application
#  réelle : une image, un registre, et un tag immuable.
#
#  Usage :  ./build-configmap-war.sh [chemin/vers/{{APP_CONTEXT}}.war]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
export KUBECONFIG="{{KUBECONFIG}}"

WAR="${1:-../../02-tomcat/app/{{APP_CONTEXT}}.war}"
NS="{{NAMESPACE}}"

[ -f "$WAR" ] || { echo "[ERREUR] WAR introuvable : $WAR"; echo "         construisez-le : cd ../../02-tomcat/app && ./build-war.sh"; exit 1; }

TAILLE=$(stat -c %s "$WAR")
echo "[i] WAR : $WAR ($(( TAILLE / 1024 )) Kio)"
if [ "$TAILLE" -gt 900000 ]; then
  echo "[ERREUR] trop volumineux pour un ConfigMap (limite ~1 Mio)." >&2
  exit 1
fi

kubectl -n "$NS" create configmap shopflow-war \
  --from-file="{{APP_CONTEXT}}.war=${WAR}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" get configmap shopflow-war \
  -o jsonpath='{.binaryData}' | head -c 80 ; echo " ..."
echo "[OK] ConfigMap shopflow-war créé dans $NS."
