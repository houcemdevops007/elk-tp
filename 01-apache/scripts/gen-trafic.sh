#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  gen-trafic.sh — trafic pédagogique sur la VM du candidat
#
#  AUCUNE action destructive, à l'exception du profil « arret » qui arrête
#  puis relance Apache sur VOTRE VM. Uniquement des requêtes HTTP vers
#  l'adresse passée en argument. Ne pointez JAMAIS ce script vers une machine
#  qui n'est pas la vôtre : générer de la charge sur un système tiers sans
#  autorisation écrite est une attaque, pas un TP.
#
#  Usage :  ./gen-trafic.sh [url-de-base] [profil] [duree_s]
#           profils : normal | charge | erreurs | lenteur | flood404 | arret
#  Exemple : ./gen-trafic.sh http://localhost charge
#
#  Chapitre (variable CHAPITRE, 1 par défaut) :
#    CHAPITRE=1  lenteur et erreurs via /cgi-bin/lent et /cgi-bin/erreur
#                (installés par install-cgi-chapitre1.sh) ; pas d'appels /api/
#    CHAPITRE=2  lenteur et erreurs via l'API Tomcat (/api/lent, /api/erreur)
#
#  Profil arret : durée d'arrêt = 3e argument (240 s par défaut). Elle doit
#  dépasser la fenêtre de la règle apache-absent (3 min recommandées).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

BASE="${1:-http://localhost}"
PROFIL="${2:-normal}"
CHAPITRE="${CHAPITRE:-1}"

# Identifiant du candidat : remplacé par le générateur, sinon nom de la machine
STUDENT="{{STUDENT_ID}}"
[[ "$STUDENT" == *"{{"* ]] && STUDENT="${STUDENT_ID:-$(hostname -s)}"

if [[ "$CHAPITRE" == "2" ]]; then
  LENT="/api/lent";       ERREUR="/api/erreur"
else
  LENT="/cgi-bin/lent";   ERREUR="/cgi-bin/erreur"
fi

if [[ "$PROFIL" == "arret" ]]; then DUREE="${3:-240}"; else DUREE="${3:-120}"; fi
FIN=$(( $(date +%s) + DUREE ))

req() { curl -s -o /dev/null -m 10 -w "%{http_code}  %{time_total}s  $1\n" "${BASE}$1"; }

# Vérifie qu'un endpoint existe avant de lancer un profil qui en dépend
exige() {
  local code
  code=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "${BASE}$1")
  if [[ "$code" == "404" || "$code" == "000" ]]; then
    echo "❌ ${BASE}$1 répond ${code}."
    if [[ "$CHAPITRE" == "2" ]]; then
      echo "   Vérifiez le ProxyPass /api/ vers Tomcat (chapitre 2)."
    else
      echo "   Lancez d'abord : sudo ./install-cgi-chapitre1.sh"
    fi
    exit 1
  fi
}

echo "== profil=$PROFIL  cible=$BASE  duree=${DUREE}s  chapitre=$CHAPITRE  candidat=$STUDENT =="

case "$PROFIL" in
  normal)
    # Trafic nominal : pages et ressources statiques (+ API au chapitre 2).
    # Sert de référence : quasiment que des 200, latence faible.
    while [ "$(date +%s)" -lt "$FIN" ]; do
      req "/" >/dev/null
      req "/catalogue.html" >/dev/null
      req "/assets/app.css" >/dev/null
      if [[ "$CHAPITRE" == "2" ]]; then
        req "/api/produit/$((RANDOM % 900))" >/dev/null
        [ $((RANDOM % 5)) -eq 0 ] && req "/api/cart" >/dev/null
      fi
      sleep 0.4
    done
    ;;

  charge)
    # Montée en charge par paliers. Observez la RÉSERVE de workers (idle),
    # la latence P95 et le DÉBIT : c'est le plafonnement du débit sous
    # demande croissante qui définit la saturation, pas le nombre de workers.
    command -v ab >/dev/null || { echo "ApacheBench absent : sudo apt-get install -y apache2-utils"; exit 1; }
    for c in 10 30 60; do
      echo "--- palier : concurrence $c ---"
      ab -n $((c * 40)) -c "$c" "${BASE}/catalogue.html" 2>/dev/null \
        | grep -E 'Requests per second|Time per request|Failed requests|^  50%|^  95%|^  99%'
      echo "    (laissez 60 s de calme avant le palier suivant pour lire les métriques)"
      sleep 60
    done
    ;;

  erreurs)
    # 404 (lien mort), 403 (fichier sensible refusé), 5xx (erreur serveur).
    exige "${ERREUR}?type=500"
    while [ "$(date +%s)" -lt "$FIN" ]; do
      req "/produit/inexistant-$RANDOM" >/dev/null
      req "/.env" >/dev/null
      req "/catalogue.html" >/dev/null
      # Appel réussi sur le même chemin applicatif que les erreurs : sans lui,
      # le taux d'erreur de l'« application » serait toujours de 100 %.
      req "${LENT}?ms=10" >/dev/null
      if [ $((RANDOM % 3)) -eq 0 ]; then
        codes=(500 502 503 504)
        req "${ERREUR}?type=${codes[$((RANDOM % 4))]}" >/dev/null
      fi
      sleep 0.6
    done
    ;;

  flood404)
    # Signature d'un scan automatisé : beaucoup d'URL distinctes, beaucoup de
    # 404, sur des chemins qui n'ont rien à voir avec l'application.
    echo "-- 200 requêtes sur des chemins de scan --"
    for i in $(seq 1 40); do
      for u in /wp-login.php /xmlrpc.php /admin/config.php /.git/config /phpmyadmin/; do
        req "$u" >/dev/null
      done
    done
    echo "-- terminé : cherchez le Top 10 des URL en 404 dans Kibana --"
    ;;

  lenteur)
    # Requêtes volontairement lentes : aucune erreur, aucun code 5xx,
    # et pourtant l'utilisateur subit. C'est l'argument central du chapitre.
    exige "${LENT}?ms=1"
    for ms in 200 500 900 1500 2500 4000; do
      echo "--- $ms ms demandés ---"
      for _ in $(seq 1 6); do req "${LENT}?ms=$ms"; done
    done
    ;;

  arret)
    # Panne franche : Apache s'arrête. Objectif : voir l'alerte d'absence de
    # données se déclencher, et constater que tous les dashboards deviennent
    # CALMES — c'est le piège le plus dangereux de l'observabilité.
    echo "-- arrêt d'Apache pendant ${DUREE} s --"
    echo "   (la durée doit dépasser la fenêtre de la règle apache-absent)"
    sudo systemctl stop apache2
    date -u '+%Y-%m-%dT%H:%M:%SZ  arrêt'
    sleep "$DUREE"
    sudo systemctl start apache2
    date -u '+%Y-%m-%dT%H:%M:%SZ  redémarrage'
    echo "-- vérifiez : l'alerte s'est-elle déclenchée ? en combien de temps ? --"
    echo "-- puis, 1 à 2 min plus tard : est-elle passée à « Récupérée » ? --"
    ;;

  *) echo "profils : normal | charge | erreurs | lenteur | flood404 | arret"; exit 1 ;;
esac

echo "== Terminé. Attendez 15 à 60 s, puis cherchez dans Kibana Discover. =="
