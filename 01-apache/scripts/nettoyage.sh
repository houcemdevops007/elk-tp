#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  nettoyage.sh — remise en état de la VM du candidat en fin de chapitre
#
#  Ce script NE supprime AUCUNE donnée dans Elasticsearch : la rétention est
#  gérée par l'ILM de la plateforme (opération formateur). Il remet seulement
#  la VM dans un état propre et vérifie qu'elle est prête pour le chapitre 2.
#
#  Il ne touche PAS aux pages /cgi-bin/lent et /cgi-bin/erreur : elles restent
#  utiles jusqu'au chapitre 2.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# Identifiant du candidat : remplacé par le générateur, sinon nom de la machine
STUDENT="{{STUDENT_ID}}"
[[ "$STUDENT" == *"{{"* ]] && STUDENT="${STUDENT_ID:-$(hostname -s)}"

# Les journaux ShopFlow sont écrits en chemin absolu dans /var/log/apache2
LOG_DIR="/var/log/apache2"

ok()   { echo "   ✅ $*"; }
warn() { echo "   ⚠️  $*"; ATTENTION=1; }
ATTENTION=0

echo "== Nettoyage de fin de chapitre — ${STUDENT} =="

echo
echo "== 1. Arrêter un éventuel scénario encore en cours =="
if pgrep -f "gen-trafic.sh" >/dev/null || pgrep -x ab >/dev/null; then
  sudo pkill -f "gen-trafic.sh" 2>/dev/null
  sudo pkill -x ab 2>/dev/null
  ok "scénario en cours arrêté"
else
  ok "aucun scénario en cours"
fi

echo
echo "== 2. Rétablir Apache dans un état sain =="
if ! sudo apachectl configtest 2>/dev/null; then
  sudo apachectl configtest
  warn "configuration Apache invalide : corrigez l'erreur ci-dessus avant de continuer"
  exit 1
fi
ok "configuration valide"

# Après un scénario « arret » interrompu, Apache peut être arrêté :
# un reload échouerait, il faut un start.
if sudo systemctl is-active --quiet apache2; then
  sudo systemctl reload apache2 && ok "Apache rechargé"
else
  sudo systemctl start apache2 && ok "Apache était arrêté : redémarré"
fi
sleep 1
sudo systemctl is-active --quiet apache2 || warn "Apache ne démarre pas : sudo journalctl -u apache2 -n 30"

code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" http://localhost/catalogue.html)
[[ "$code" == "200" ]] && ok "ShopFlow répond (HTTP 200)" \
                       || warn "ShopFlow répond HTTP ${code} : vérifiez apache2ctl -S"

curl -s -m 5 "http://127.0.0.1/server-status?auto" | grep -q "^IdleWorkers" \
  && ok "/server-status répond (métriques Fleet)" \
  || warn "/server-status ne répond pas : les métriques Apache ne remonteront plus"

echo
echo "== 3. Vérifier que l'agent est sain avant de partir =="
if sudo systemctl is-active --quiet elastic-agent \
   && sudo elastic-agent status 2>/dev/null | grep -qi "healthy" \
   && ! sudo elastic-agent status 2>/dev/null | grep -qiE "degraded|failed|unhealthy"; then
  ok "Elastic Agent sain"
else
  sudo elastic-agent status || true
  warn "agent non sain : vérifiez la sortie ci-dessus (sudo systemctl restart elastic-agent)"
fi

echo
echo "== 4. Libérer l'espace des journaux locaux (forcer une rotation) =="
if [[ -f /etc/logrotate.d/apache2 ]]; then
  sudo logrotate -f /etc/logrotate.d/apache2 && ok "rotation effectuée"
else
  warn "/etc/logrotate.d/apache2 absent : rotation ignorée"
fi
sudo du -sh "$LOG_DIR"

# La rotation recrée les fichiers : vérifier qu'Apache écrit bien dans les nouveaux
curl -s -o /dev/null http://localhost/catalogue.html; sleep 1
if [[ -s "$LOG_DIR/access_json.log" ]]; then
  ok "access_json.log est de nouveau alimenté"
else
  warn "access_json.log vide après rotation : sudo systemctl reload apache2"
fi

echo
echo "== 5. Pages de démonstration du chapitre 1 (conservées) =="
for p in lent erreur; do
  [[ -x "/usr/lib/cgi-bin/$p" ]] && ok "/cgi-bin/$p présent" \
                                 || warn "/cgi-bin/$p absent : sudo ./install-cgi-chapitre1.sh"
done

echo
echo "== 6. À FAIRE À LA MAIN dans Kibana =="
cat <<'FIN'
  Dès maintenant :
  - Remettre les seuils de test à leur valeur réelle :
      pic-trafic           → EST SUPÉRIEUR À 1500
      workers-reserve-basse → EST INFÉRIEUR OU ÉGAL À 2
      taux-5xx             → >= 500 (et non >= 400)
  - Vérifier qu'aucune alerte de test n'est restée active
    (Observability → Alertes, filtre Statut : active).

  En fin de formation :
  - Désactiver vos règles d'alerte : une règle oubliée continue de s'exécuter
    indéfiniment sur le cluster partagé, et d'envoyer des messages Slack et
    des e-mails.
  - Conserver vos dashboards : ils font partie de vos livrables.
  - Ne PAS désinstaller l'agent : les chapitres 2 à 4 s'appuient dessus.
    (désenrôlement éventuel, en toute fin : sudo elastic-agent uninstall)
FIN

echo
if [[ "$ATTENTION" == "0" ]]; then
  echo "== ✅ VM propre et prête pour le chapitre 2 =="
else
  echo "== ⚠️  Nettoyage terminé avec des points à vérifier (voir ci-dessus) =="
  exit 1
fi
