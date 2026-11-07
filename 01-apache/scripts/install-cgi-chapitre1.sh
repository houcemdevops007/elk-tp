#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  install-cgi-chapitre1.sh — endpoints de démonstration pour le chapitre 1
#
#  Sans Tomcat (chapitre 2), Apache ne sait produire ni lenteur ni erreur 5xx.
#  Ce script installe deux petits CGI, HORS de /api/ (réservé au chapitre 2) :
#
#    /cgi-bin/lent?ms=900          répond 200 après 900 ms (max 5000)
#    /cgi-bin/erreur?type=500      répond 500 (ou 502, 503, 504)
#
#  Usage : sudo ./install-cgi-chapitre1.sh
#  Rejouable sans risque.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo"; exit 1; }

CGI_DIR=/usr/lib/cgi-bin
mkdir -p "$CGI_DIR"

# ─── /cgi-bin/lent : lenteur sans erreur ─────────────────────────────────────
cat > "$CGI_DIR/lent" <<'EOF'
#!/bin/bash
# Répond 200 après ms millisecondes (paramètre ms, 200 par défaut, 5000 max).
ms=$(sed -n 's/.*ms=\([0-9]\{1,5\}\).*/\1/p' <<<"${QUERY_STRING:-}")
ms=${ms:-200}
(( ms > 5000 )) && ms=5000
sleep "$(awk -v m="$ms" 'BEGIN{printf "%.3f", m/1000}')"
printf 'Content-Type: text/plain\r\n\r\nok %s ms\n' "$ms"
EOF

# ─── /cgi-bin/erreur : erreur serveur contrôlée ─────────────────────────────
cat > "$CGI_DIR/erreur" <<'EOF'
#!/bin/bash
# Répond avec le code demandé (type=500|502|503|504, 500 par défaut).
code=$(sed -n 's/.*type=\(50[0234]\).*/\1/p' <<<"${QUERY_STRING:-}")
code=${code:-500}
case $code in
  500) txt="Internal Server Error" ;;
  502) txt="Bad Gateway" ;;
  503) txt="Service Unavailable" ;;
  504) txt="Gateway Timeout" ;;
esac
printf 'Status: %s %s\r\nContent-Type: text/plain\r\n\r\nerreur simulee %s\n' "$code" "$txt" "$code"
EOF

chmod 755 "$CGI_DIR/lent" "$CGI_DIR/erreur"

# ─── Modules et configuration CGI (fournie par Debian, globale à tous les vhosts)
a2enmod -q cgid
a2enconf -q serve-cgi-bin
apachectl configtest
systemctl restart apache2
sleep 1

# ─── Vérification ───────────────────────────────────────────────────────────
echo
echo "Vérification :"
curl -s -o /dev/null -w "  /cgi-bin/lent?ms=900       → HTTP %{http_code} en %{time_total}s (attendu : 200, ≈ 0.9 s)\n" \
     "http://localhost/cgi-bin/lent?ms=900"
curl -s -o /dev/null -w "  /cgi-bin/erreur?type=500   → HTTP %{http_code} (attendu : 500)\n" \
     "http://localhost/cgi-bin/erreur?type=500"
