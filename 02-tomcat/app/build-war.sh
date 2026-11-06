#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  build-war.sh — construit {{APP_CONTEXT}}.war sans Maven et sans réseau.
#
#  Seules dépendances : le JDK installé sur la VM et l'API servlet fournie
#  par Tomcat lui-même ({{CATALINA_HOME}}/lib).
#
#  Tomcat 10 et 11 utilisent les paquets « jakarta.servlet » ; Tomcat 9 et
#  antérieurs utilisent « javax.servlet ». Le script détecte le cas et adapte
#  les imports : c'est la cause numéro un des échecs de déploiement en TP.
#
#  Usage :  ./build-war.sh   puis   sudo ./deploy-war.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CATALINA_HOME="{{CATALINA_HOME}}"
CONTEXT="{{APP_CONTEXT}}"
BUILD="$(pwd)/build"

command -v javac >/dev/null || { echo "[ERREUR] JDK absent : sudo apt-get install -y default-jdk"; exit 1; }
javac -version

# ── 1. Trouver l'API servlet livrée avec Tomcat ─────────────────────────────
API_JAR="$(ls "${CATALINA_HOME}"/lib/servlet-api.jar \
              "${CATALINA_HOME}"/lib/jakarta.servlet-api*.jar 2>/dev/null | head -1 || true)"
if [ -z "$API_JAR" ]; then
  echo "[ERREUR] API servlet introuvable dans ${CATALINA_HOME}/lib" >&2
  echo "         vérifiez CATALINA_HOME : ls ${CATALINA_HOME}/lib | grep -i servlet" >&2
  exit 1
fi
echo "[i] API servlet : $API_JAR"

# ── 2. Détecter jakarta ou javax ────────────────────────────────────────────
if unzip -l "$API_JAR" 2>/dev/null | grep -q 'jakarta/servlet/http/HttpServlet.class'; then
  NAMESPACE="jakarta"
else
  NAMESPACE="javax"
fi
echo "[i] espace de noms servlet détecté : ${NAMESPACE}.servlet"

# ── 3. Préparer l'arborescence du WAR ───────────────────────────────────────
rm -rf "$BUILD"
mkdir -p "$BUILD/WEB-INF/classes/com/novacommerce/shopflow"
cp ShopFlowServlet.java "$BUILD/ShopFlowServlet.java"
if [ "$NAMESPACE" = "javax" ]; then
  sed -i 's/jakarta\.servlet/javax.servlet/g' "$BUILD/ShopFlowServlet.java"
  echo "[i] imports réécrits en javax.servlet (Tomcat 9 ou antérieur)"
fi
cp web.xml      "$BUILD/WEB-INF/web.xml"
cp logback.xml  "$BUILD/WEB-INF/classes/logback.xml" 2>/dev/null \
  || echo "[i] logback.xml absent : la journalisation JSON passera par stdout (catalina.out)"

# ── 4. Compiler ─────────────────────────────────────────────────────────────
javac -encoding UTF-8 -cp "$API_JAR" \
      -d "$BUILD/WEB-INF/classes" "$BUILD/ShopFlowServlet.java"
rm -f "$BUILD/ShopFlowServlet.java"

# ── 5. Empaqueter ───────────────────────────────────────────────────────────
( cd "$BUILD" && jar --create --file "../${CONTEXT}.war" . )
ls -lh "${CONTEXT}.war"

cat <<FIN

[OK] ${CONTEXT}.war construit.
Déploiement :
  sudo cp ${CONTEXT}.war {{CATALINA_HOME}}/webapps/
  sudo tail -f {{CATALINA_LOGS}}/catalina.out      # suivre le déploiement
Vérification :
  curl -s http://localhost:{{TOMCAT_PORT}}/${CONTEXT}/health
FIN
