#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  install-dashboards.sh — installe les dashboards standards des intégrations
#  (Apache, Tomcat, Kubernetes…) dans l'espace Kibana de chaque candidat.
#
#  Les dashboards d'une intégration ne sont installés que dans l'espace où
#  l'intégration a été installée (souvent Default). Ce script :
#    1. installe le paquet de l'intégration s'il ne l'est pas encore ;
#    2. installe ses assets Kibana (dashboards, visualisations) dans chaque
#       espace « Candidat NN ».
#
#  Chaque candidat ne voit que SES données dans ces dashboards : ils lisent
#  logs-* / metrics-*, et son rôle ne l'autorise qu'à *-studentNN.
#
#  Usage :
#    export KIBANA_PASS='mot-de-passe-elastic'
#    DRY_RUN=1 ./install-dashboards.sh     # simulation
#    ./install-dashboards.sh               # installation
#    PACKAGES="apache" ./install-dashboards.sh   # un seul paquet
#
#  Prérequis : bash, curl, jq ; Kibana 8.17+ (installation multi-espaces).
#  Rejouable sans risque.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

KIBANA_URL="${KIBANA_URL:-https://elk.efi-academy.com}"
KIBANA_USER="${KIBANA_USER:-elastic}"
: "${KIBANA_PASS:?Définissez KIBANA_PASS (mot de passe de ${KIBANA_USER})}"

PACKAGES="${PACKAGES:-apache tomcat kubernetes}"
SPACE_NAME_REGEX="${SPACE_NAME_REGEX:-^Candidat ([0-9]+)$}"
DRY_RUN="${DRY_RUN:-0}"

command -v jq   >/dev/null || { echo "❌ jq est requis (apt install jq)"; exit 1; }
command -v curl >/dev/null || { echo "❌ curl est requis"; exit 1; }

api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -u "${KIBANA_USER}:${KIBANA_PASS}"
              -H 'kbn-xsrf: true' -H 'Content-Type: application/json'
              -X "$method" "${KIBANA_URL}${path}" -w $'\n%{http_code}' --max-time 300)
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}"
}
body() { sed '$d'; }
code() { tail -n1; }
msg()  { jq -r '.message // .error // .' 2>/dev/null <<<"$1" | head -c 300; }

# ─── 1. Paquets : installés ? version ? ──────────────────────────────────────
declare -A VERSION
for pkg in $PACKAGES; do
  resp=$(api GET "/api/fleet/epm/packages/${pkg}")
  if [[ "$(code <<<"$resp")" != "200" ]]; then
    echo "❌ Paquet « ${pkg} » introuvable dans Fleet : $(msg "$(body <<<"$resp")")"; exit 1
  fi
  status=$(body <<<"$resp" | jq -r '.item.status // .response.status')
  version=$(body <<<"$resp" | jq -r '.item.installationInfo.version // .item.version // .response.version')

  if [[ "$status" != "installed" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "🔎 ${pkg} : serait installé (version ${version})"
    else
      echo "📦 ${pkg} : installation du paquet ${version} (peut prendre 1 à 2 min)…"
      resp=$(api POST "/api/fleet/epm/packages/${pkg}/${version}" '{"force": false}')
      if [[ "$(code <<<"$resp")" != "200" ]]; then
        echo "❌ ${pkg} : installation échouée : $(msg "$(body <<<"$resp")")"; exit 1
      fi
    fi
  fi
  VERSION[$pkg]="$version"
  echo "✅ ${pkg} ${version} prêt"
done

# ─── 2. Espaces candidats ───────────────────────────────────────────────────
resp=$(api GET /api/spaces/space)
[[ "$(code <<<"$resp")" == "200" ]] || { echo "❌ Impossible de lister les espaces"; exit 1; }
spaces=$(body <<<"$resp" | jq -r '.[] | [.id, .name] | @tsv' | sort -t$'\t' -k2 -V)

matched=0; failed=0
echo
while IFS=$'\t' read -r space_id space_name; do
  [[ "$space_name" =~ $SPACE_NAME_REGEX ]] || continue
  matched=$((matched + 1))
  echo "── ${space_name}  (espace « ${space_id} »)"
  for pkg in $PACKAGES; do
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "   🔎 ${pkg} : dashboards seraient installés"; continue
    fi
    resp=$(api POST "/s/${space_id}/api/fleet/epm/packages/${pkg}/${VERSION[$pkg]}/kibana_assets" '{}')
    if [[ "$(code <<<"$resp")" == "200" ]]; then
      echo "   ✅ ${pkg} : dashboards installés"
    else
      echo "   ❌ ${pkg} : $(msg "$(body <<<"$resp")")"
      failed=$((failed + 1))
    fi
  done
done <<<"$spaces"

echo
echo "Espaces traités : ${matched}   Échecs : ${failed}"
[[ "$matched" == "0" ]] && echo "⚠️  Aucun espace ne correspond à « ${SPACE_NAME_REGEX} »."
[[ "$failed" == "0" ]]
