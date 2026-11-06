#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  deploy-war.sh — déploie {{APP_CONTEXT}}.war et suit le déploiement.
#
#  Objectif pédagogique : voir dans les journaux l'ÉVÉNEMENT « déploiement ».
#  Toute dégradation qui commence à la minute d'un déploiement a une cause
#  très probable : ce déploiement.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONTEXT="{{APP_CONTEXT}}"
CATALINA_HOME="{{CATALINA_HOME}}"
LOGS="{{CATALINA_LOGS}}"
PORT="{{TOMCAT_PORT}}"

[ -f "${CONTEXT}.war" ] || { echo "[ERREUR] ${CONTEXT}.war absent : lancez ./build-war.sh"; exit 1; }

echo "== Horodatage du déploiement (à noter dans votre compte rendu) =="
date -u '+%Y-%m-%dT%H:%M:%SZ'

echo "== Copie dans webapps (autoDeploy détecte le nouveau WAR) =="
sudo cp "${CONTEXT}.war" "${CATALINA_HOME}/webapps/"

echo "== Suivi du déploiement : 30 secondes de journal =="
sudo timeout 30 tail -f "${LOGS}/catalina.out" | grep -E --line-buffered \
  'Deploying|Deployment of|has finished|SEVERE|ERROR|Exception' || true

echo
echo "== Vérification =="
curl -s "http://localhost:${PORT}/${CONTEXT}/health" ; echo
curl -s "http://localhost:${PORT}/${CONTEXT}/api/cart" | head -c 160 ; echo

cat <<'FIN'

Ce que vous devez avoir vu dans le journal :
  INFO ... HostConfig.deployWAR  Deploying web application archive [...war]
  INFO ... HostConfig.deployWAR  Deployment of web application archive [...]
                                 has finished in [N] ms
Retenez le « N » : c'est votre durée de déploiement de référence.
FIN
