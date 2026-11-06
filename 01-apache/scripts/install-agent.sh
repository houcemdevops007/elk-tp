#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  install-agent.sh — installe et enrôle l'Elastic Agent sur la VM de {{STUDENT_ID}}
#
#  Politique visée : {{POLICY}}        Fleet Server : {{FLEET_URL}}
#  Version imposée : {{ES_VERSION}}    (identique à celle du cluster {{ES_CLUSTER}})
#
#  La commande de référence reste celle affichée par Kibana dans
#  Fleet -> Agents -> Add agent : elle correspond à la version réellement
#  déployée. Ce script en est la version commentée et reproductible.
#
#  Usage :  sudo ./install-agent.sh '<token-d-enrolement>'
#           (le token peut aussi être passé par la variable ENROLL_TOKEN)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="{{ES_VERSION}}"
FLEET_URL="{{FLEET_URL}}"
CA_PATH="{{CA_PATH}}"
TOKEN="${1:-${ENROLL_TOKEN:-}}"
ARCHIVE="elastic-agent-${VERSION}-linux-x86_64"

if [ -z "$TOKEN" ]; then
  echo "[ERREUR] token d'enrôlement manquant." >&2
  echo "         usage : sudo $0 '<token>'" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERREUR] à lancer avec sudo." >&2
  exit 1
fi

echo "== 1. Prérequis : l'autorité de certification interne EFI =="
#  Sans la CA, l'enrôlement échoue sur « x509: certificate signed by unknown
#  authority ». --insecure ferait disparaître le symptôme, pas le problème :
#  la connexion resterait chiffrée mais ne serait plus authentifiée.
if [ ! -f "$CA_PATH" ]; then
  echo "[ERREUR] autorité de certification absente : $CA_PATH" >&2
  echo "         demandez-la au formateur et déposez-la à cet emplacement." >&2
  exit 1
fi
openssl x509 -in "$CA_PATH" -noout -subject -dates

echo "== 2. Connectivité vers Fleet Server =="
#  Une réponse HTTP, MÊME une erreur, prouve que le port répond et que le
#  chemin réseau existe. Un dépassement de délai prouve l'inverse.
curl -sS -I --max-time 5 --cacert "$CA_PATH" "$FLEET_URL" | head -1 \
  || { echo "[ERREUR] {{FLEET_IP}}:8220 injoignable depuis cette VM." >&2; exit 1; }

echo "== 3. Téléchargement de l'agent $VERSION =="
cd /tmp
if [ ! -d "$ARCHIVE" ]; then
  curl -fL -O "https://artifacts.elastic.co/downloads/beats/elastic-agent/${ARCHIVE}.tar.gz"
  tar xzf "${ARCHIVE}.tar.gz"
fi
cd "$ARCHIVE"

echo "== 4. Installation et enrôlement =="
#  --certificate-authorities : valide le certificat de Fleet Server
#  --tag                     : permet de retrouver l'agent parmi vingt autres
./elastic-agent install \
  --non-interactive \
  --url="$FLEET_URL" \
  --enrollment-token="$TOKEN" \
  --certificate-authorities="$CA_PATH" \
  --tag "{{STUDENT_ID}}" --tag "tp-apache"

echo "== 5. Vérification =="
sleep 15
elastic-agent status --output=full || true
systemctl is-active elastic-agent
elastic-agent version

cat <<'FIN'

== Terminé ==
À vérifier maintenant, dans cet ordre :
  1. Fleet -> Agents : l'agent apparaît et passe en « Healthy ».
  2. elastic-agent status --output=full : aucune unité en « degraded ».
  3. Discover : les premiers documents filtrés sur votre host.name.
Si l'état reste « degraded », lisez le message de l'unité fautive : c'est
presque toujours un chemin de journal inexistant ou un droit de lecture.
FIN
