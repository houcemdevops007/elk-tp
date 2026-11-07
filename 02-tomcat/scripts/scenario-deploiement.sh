#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  scenario-deploiement.sh — échec de déploiement ({{STUDENT_ID}})
#
#  On déploie volontairement un WAR dont le descripteur web.xml est invalide.
#  Objectif : voir l'ÉVÉNEMENT d'échec dans catalina, comprendre que
#  l'application précédente reste ou non en service, et mesurer le temps
#  entre le déploiement et la détection.
#
#  Usage :  ./scenario-deploiement.sh        (puis le script restaure le bon WAR)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

CTX="{{APP_CONTEXT}}"
HOME_T="{{CATALINA_HOME}}"
LOGS="{{CATALINA_LOGS}}"
PORT="{{TOMCAT_PORT}}"
TMP="$(mktemp -d)"

# Le WAR sain est dans ../app, quel que soit le dossier d'où l'on lance le script
APP_DIR="$(cd "$(dirname "$0")/../app" && pwd)"
WAR="${APP_DIR}/${CTX}.war"
[ -f "$WAR" ] || { echo "[ERREUR] $WAR absent : lancez d'abord app/build-war.sh"; exit 1; }
command -v jar >/dev/null || { echo "[ERREUR] commande jar introuvable (JDK requis)"; exit 1; }

echo "== 1. État avant : l'application répond ? =="
curl -s -o /dev/null -w "  /health -> %{http_code}\n" "http://localhost:${PORT}/${CTX}/health"

echo "== 2. Fabrication d'un WAR cassé (web.xml malformé) =="
cp "$WAR" "${TMP}/casse.war"
mkdir -p "${TMP}/patch/WEB-INF"
cat > "${TMP}/patch/WEB-INF/web.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<web-app version="6.0">
  <session-config>
    <session-timeout>15</session-timeout>
  <!-- balise session-config volontairement NON fermee : parse error attendu -->
</web-app>
XML
( cd "${TMP}/patch" && jar --update --file "${TMP}/casse.war" WEB-INF/web.xml )

echo "== 3. Déploiement du WAR cassé =="
date -u '+%Y-%m-%dT%H:%M:%SZ  déploiement du WAR invalide'
sudo cp "${TMP}/casse.war" "${HOME_T}/webapps/${CTX}-casse.war"

echo "== 4. Suivi du journal pendant 30 s =="
sudo timeout 30 tail -f "${LOGS}/catalina.out" | grep -E --line-buffered \
  "Deploying|SEVERE|ERROR|Parse error|Exception|FAIL|${CTX}-casse" || true

echo
echo "== 5. Conséquence sur le service =="
curl -s -o /dev/null -w "  application saine   /health -> %{http_code}\n" \
  "http://localhost:${PORT}/${CTX}/health"
curl -s -o /dev/null -w "  application cassée  /health -> %{http_code}\n" \
  "http://localhost:${PORT}/${CTX}-casse/health"

echo "== 6. Nettoyage =="
sudo rm -f "${HOME_T}/webapps/${CTX}-casse.war"
sudo rm -rf "${HOME_T}/webapps/${CTX}-casse"
rm -rf "$TMP"
echo "  WAR cassé retiré."

cat <<'FIN'

Ce que vous devez relever :
  - la ligne SEVERE de catalina qui nomme le fichier et la cause
    (« Parse error in application web.xml ») ;
  - le fait que l'application SAINE continue de répondre : un échec de
    déploiement n'est pas forcément une panne de service ;
  - le délai entre la copie du WAR et l'apparition de l'erreur ;
  - dans Kibana : le document correspondant, avec log.level = ERROR
    (et non SEVERE, grâce au pipeline de normalisation).

La leçon d'exploitation : un déploiement est un ÉVÉNEMENT. Toute
dégradation qui commence à la minute d'un déploiement a une cause très
probable — ce déploiement. C'est pourquoi on journalise les déploiements
au même endroit que les métriques.
FIN
