#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  verifier-acces-kibana.sh — pourquoi « curl ... | head -1 » ne renvoie rien
#
#  Avec -s, curl masque ses erreurs : une sortie vide peut être un fichier de
#  CA introuvable, un port fermé, un certificat refusé ou un nom d'hôte qui ne
#  correspond pas. Ce script déroule les causes dans l'ordre et conclut.
#
#  Usage :  ./verifier-acces-kibana.sh [url-kibana] [chemin-ca]
#  Exemple : ./verifier-acces-kibana.sh https://172.16.3.53:5601 /etc/efi/pki/ca.crt
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

URL="${1:-https://172.16.3.53:5601}"
CA="${2:-/etc/efi/pki/ca.crt}"
HOTE=$(echo "$URL" | sed -E 's#^https?://##; s#[:/].*$##')
PORT=$(echo "$URL" | sed -nE 's#^https?://[^:/]+:([0-9]+).*#\1#p'); PORT="${PORT:-5601}"

echo "═══ Cible : $URL   (hôte $HOTE, port $PORT) ═══"
echo

echo "── 1. Le fichier de CA existe-t-il ? ──"
if [ -f "$CA" ]; then
  echo "   [OK] $CA"
  openssl x509 -in "$CA" -noout -subject -dates 2>/dev/null | sed 's/^/        /' \
    || echo "        [!] ce fichier n'est pas un certificat lisible"
else
  echo "   [ÉCHEC] $CA : fichier introuvable."
  echo "           C'est la cause n°1 d'une sortie vide : curl sort en code 77"
  echo "           sans rien afficher quand on utilise -s."
  echo "           Cherchez la vraie CA :"
  echo "             find ~ /etc /opt -name '*ca*.crt' -o -name '*ca*.pem' 2>/dev/null | head"
fi
echo

echo "── 2. Le port répond-il ? (couche réseau, avant tout TLS) ──"
if command -v nc >/dev/null 2>&1; then
  if nc -z -w 5 "$HOTE" "$PORT" 2>/dev/null; then
    echo "   [OK] $HOTE:$PORT accepte les connexions"
  else
    echo "   [ÉCHEC] $HOTE:$PORT injoignable — pare-feu, routage, ou service arrêté."
    echo "           Sur elk-kibana0 : sudo ss -lntp | grep $PORT"
  fi
else
  timeout 5 bash -c "</dev/tcp/$HOTE/$PORT" 2>/dev/null \
    && echo "   [OK] $HOTE:$PORT accepte les connexions" \
    || echo "   [ÉCHEC] $HOTE:$PORT injoignable"
fi
echo

echo "── 3. Est-ce bien du TLS, et par qui est-il signé ? ──"
PREUVE=$(echo | timeout 8 openssl s_client -connect "$HOTE:$PORT" -servername "$HOTE" 2>/dev/null)
if [ -n "$PREUVE" ]; then
  echo "$PREUVE" | openssl x509 -noout -subject -issuer -dates 2>/dev/null | sed 's/^/   /' \
    || echo "   [!] réponse TLS illisible"
  echo "$PREUVE" | grep -E '^ *(DNS|IP Address):' | head -3 | sed 's/^/   SAN /'
else
  echo "   [ÉCHEC] pas de réponse TLS. Kibana écoute peut-être en HTTP simple :"
  echo "           curl -I http://$HOTE:$PORT/api/status"
fi
echo

echo "── 4. curl, SANS -s, avec le code de sortie ──"
curl -sS -I --max-time 10 --cacert "$CA" "$URL/api/status" 2>&1 | head -3 | sed 's/^/   /'
CODE=${PIPESTATUS[0]}
echo "   code de sortie curl : $CODE"
case "$CODE" in
  0)  echo "   [OK] Kibana répond et le certificat est validé." ;;
  6)  echo "   [DNS] nom d'hôte non résolu." ;;
  7)  echo "   [RÉSEAU] connexion refusée : service arrêté ou port fermé." ;;
  28) echo "   [RÉSEAU] délai dépassé : pare-feu ou routage." ;;
  35) echo "   [TLS] échec de la négociation : le port parle peut-être en clair." ;;
  51|60) echo "   [TLS] certificat refusé : mauvaise CA, ou nom d'hôte absent des SAN."
         echo "         Diagnostic : relancez avec -k. Si ça passe, c'est bien la CA."
         echo "         N'utilisez -k que pour DIAGNOSTIQUER, jamais dans vos scripts." ;;
  77) echo "   [CA] fichier de CA illisible ou introuvable : $CA" ;;
  *)  echo "   [?] voir « man curl », section EXIT CODES." ;;
esac
echo

echo "── 5. Contre-épreuve sans validation (diagnostic uniquement) ──"
curl -sS -I -k --max-time 10 "$URL/api/status" 2>&1 | head -2 | sed 's/^/   /'
echo "   code de sortie : ${PIPESTATUS[0]}"
echo
echo "   Si l'étape 5 répond alors que l'étape 4 échoue : le service va bien,"
echo "   c'est uniquement le certificat qui n'est pas validable avec $CA."
