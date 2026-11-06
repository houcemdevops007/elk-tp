#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  gen-trafic.sh — trafic pédagogique sur la VM de {{STUDENT_ID}}
#
#  AUCUNE action destructive : uniquement des requêtes HTTP vers l'adresse
#  passée en argument. Ne pointez JAMAIS ce script vers une machine qui n'est
#  pas la vôtre : générer de la charge sur un système tiers sans autorisation
#  écrite est une attaque, pas un TP.
#
#  Usage :  ./gen-trafic.sh [url-de-base] [profil] [duree_s]
#           profils : normal | charge | erreurs | lenteur | flood404 | arret
#  Exemple : ./gen-trafic.sh http://localhost charge
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

BASE="${1:-http://localhost}"
PROFIL="${2:-normal}"
DUREE="${3:-120}"
FIN=$(( $(date +%s) + DUREE ))

req() { curl -s -o /dev/null -w "%{http_code}  %{time_total}s  $1\n" "${BASE}$1"; }

echo "== profil=$PROFIL  cible=$BASE  duree=${DUREE}s  candidat={{STUDENT_ID}} =="

case "$PROFIL" in
  normal)
    # Trafic nominal : pages, ressources statiques, API. Sert de référence.
    while [ "$(date +%s)" -lt "$FIN" ]; do
      req "/" >/dev/null
      req "/catalogue.html" >/dev/null
      req "/assets/app.css" >/dev/null
      req "/api/produit/$((RANDOM % 900))" >/dev/null
      [ $((RANDOM % 5)) -eq 0 ] && req "/api/cart" >/dev/null
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
    # 404 (lien mort), 403 (fichier sensible refusé), 500 (erreur applicative).
    while [ "$(date +%s)" -lt "$FIN" ]; do
      req "/produit/inexistant-$RANDOM" >/dev/null
      req "/.env" >/dev/null
      [ $((RANDOM % 4)) -eq 0 ] && req "/api/erreur?type=500" >/dev/null
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
    for ms in 200 500 900 1500 2500 4000; do
      echo "--- $ms ms demandés ---"
      for _ in $(seq 1 6); do req "/api/lent?ms=$ms"; done
    done
    ;;

  arret)
    # Panne franche : Apache s'arrête. Objectif : voir l'alerte d'absence de
    # données se déclencher, et constater que tous les dashboards deviennent
    # CALMES — c'est le piège le plus dangereux de l'observabilité.
    echo "-- arrêt d'Apache pendant 180 s --"
    sudo systemctl stop apache2
    date -u '+%Y-%m-%dT%H:%M:%SZ  arrêt'
    sleep 180
    sudo systemctl start apache2
    date -u '+%Y-%m-%dT%H:%M:%SZ  redémarrage'
    echo "-- vérifiez : l'alerte s'est-elle déclenchée ? en combien de temps ? --"
    ;;

  *) echo "profils : normal | charge | erreurs | lenteur | flood404 | arret"; exit 1 ;;
esac

echo "== Terminé. Attendez 15 à 60 s, puis cherchez dans Kibana Discover. =="
