#!/usr/bin/env python3
"""Ajoute l'intégration « Custom Logs » aux politiques Apache des 20 candidats.

POURQUOI : les politiques efi-studentNN-apache ne portent que deux intégrations
(Apache HTTP Server et System). Il en faut une TROISIÈME, sur le journal JSON
/var/log/apache2/access_json.log, car les formats de journal standards d'Apache
ne contiennent pas la durée de traitement. Sans elle : pas de event.duration,
donc pas de percentiles de latence, pas de scénario « requêtes lentes » et pas
de SLO de latence au projet final — et aucune erreur pour le signaler.

MÉTHODE : le script ne FABRIQUE pas la configuration de l'intégration, il la
CLONE. Vous créez l'intégration UNE fois à la main, proprement, sur une
politique de référence ; le script la relit par l'API et la réplique sur les
autres politiques en changeant seulement le nom, la politique cible et
l'espace de nom. On évite ainsi de deviner un schéma de corps de requête qui
change d'une version de Fleet à l'autre.

MODE PAR DÉFAUT : simulation. Rien n'est écrit tant que --appliquer n'est pas
passé explicitement.

Préparation, une seule fois, dans Kibana :
  Fleet -> Agent policies -> efi-student01-apache -> Ajouter une intégration
  -> « Custom Logs (Filestream) »  [PAS « Custom Logs (Deprecated) »] :
       Nom              custom-logs-efi-student01-apache
       Chemin           /var/log/apache2/access_json.log
       Dataset name     shopflow_apache.access_json
       Espace de nom    student01
       Sortie           efi-elasticsearch

Puis :
  export KIBANA_API_KEY='<cle-api-avec-droits-fleet>'
  python3 tools/ajouter-custom-logs.py --simuler
  python3 tools/ajouter-custom-logs.py --appliquer

Options utiles :
  --kibana URL        par défaut https://172.16.3.53:5601
  --cacert CHEMIN     CA interne (par défaut /etc/efi/pki/ca.crt)
  --reference NOM     politique modèle (par défaut efi-student01-apache)
  --motif MOTIF       politiques cibles (par défaut efi-student{NN}-apache)
  --de 1 --a 20       bornes des numéros de candidat
  --utilisateur / --mot-de-passe   si vous n'avez pas de clé d'API
"""
import argparse
import base64
import getpass
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

# Champs posés par Fleet : il faut les retirer avant de recréer l'objet,
# sinon l'API refuse la création (ou crée un doublon incohérent).
# Deux intégrations portent le titre « Custom Logs » dans le catalogue :
#   filestream -> « Custom Logs (Filestream) », celle qu'il faut utiliser ;
#   log        -> « Custom Logs (Deprecated) », l'ancienne, conservée pour les
#                 politiques existantes.
# Le script accepte les deux et détecte celle de la politique de référence :
# on ne dépend donc pas du nom exact du paquet dans votre version.
PAQUETS_CUSTOM_LOGS = ("filestream", "log")

CHAMPS_EN_LECTURE_SEULE = {
    "id", "version", "revision", "created_at", "created_by",
    "updated_at", "updated_by", "elasticsearch", "spaceIds", "agents",
}


class Fleet:
    def __init__(self, base, entetes, contexte_ssl):
        self.base = base.rstrip("/")
        self.entetes = entetes
        self.ssl = contexte_ssl

    def appel(self, chemin, methode="GET", corps=None):
        url = f"{self.base}{chemin}"
        donnees = json.dumps(corps).encode() if corps is not None else None
        req = urllib.request.Request(url, data=donnees, method=methode)
        for cle, valeur in self.entetes.items():
            req.add_header(cle, valeur)
        try:
            with urllib.request.urlopen(req, timeout=60, context=self.ssl) as rep:
                brut = rep.read().decode()
                return json.loads(brut) if brut else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:600]
            aide = {
                401: "Authentification refusée. La clé d'API doit être la valeur « Encoded »\n"
                     "         (base64) affichée par Kibana à la création, pas l'identifiant seul.\n"
                     "         Repli : --utilisateur <admin> --mot-de-passe.",
                403: "Authentifié, mais droits insuffisants sur Fleet. Créez la clé depuis un\n"
                     "         compte administrateur, SANS restreindre les privilèges : elle hérite\n"
                     "         alors des droits de ce compte.",
                404: "Chemin inconnu. Si vous passez par le reverse proxy, l'URL doit inclure le\n"
                     "         chemin de base, par exemple --kibana https://elk.efi-academy.com/tp",
            }.get(e.code)
            raise SystemExit(f"[ERREUR] {methode} {chemin}\n  HTTP {e.code} : {detail}"
                             + (f"\n\n  [aide] {aide}" if aide else ""))
        except urllib.error.URLError as e:
            raise SystemExit(f"[ERREUR] Kibana injoignable ({url}) : {e.reason}")

    def pagine(self, chemin):
        """Fleet pagine : sans cela, on ne voit que les 20 premiers objets."""
        items, page = [], 1
        while True:
            sep = "&" if "?" in chemin else "?"
            lot = self.appel(f"{chemin}{sep}perPage=100&page={page}")
            items.extend(lot.get("items", []))
            if len(lot.get("items", [])) < 100:
                return items
            page += 1


def politiques_de(paquet, politique_id):
    """Vrai si cette intégration appartient à la politique visée.

    Fleet expose « policy_id » (ancien) et « policy_ids » (récent) : on
    accepte les deux pour ne pas dépendre de la version.
    """
    if paquet.get("policy_id") == politique_id:
        return True
    return politique_id in (paquet.get("policy_ids") or [])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kibana", default=os.environ.get("KIBANA_URL", "https://172.16.3.53:5601"))
    ap.add_argument("--cacert", default=os.environ.get("EFI_CA", "/etc/efi/pki/ca.crt"))
    ap.add_argument("--api-key", default=os.environ.get("KIBANA_API_KEY"))
    ap.add_argument("--utilisateur")
    ap.add_argument("--mot-de-passe")
    ap.add_argument("--reference", default="efi-student01-apache")
    ap.add_argument("--motif", default="efi-student{NN}-apache")
    ap.add_argument("--nom-integration", default="custom-logs-{POLITIQUE}")
    ap.add_argument("--paquet", choices=PAQUETS_CUSTOM_LOGS,
                    help="forcer le paquet ; par défaut, détecté sur la politique de référence")
    ap.add_argument("--de", type=int, default=1)
    ap.add_argument("--a", type=int, default=20)
    ap.add_argument("--verifier", action="store_true",
                    help="n'écrit rien : dresse l'état des intégrations Custom Logs")
    ap.add_argument("--simuler", action="store_true", help="par défaut : simulation")
    ap.add_argument("--appliquer", action="store_true", help="écrit réellement dans Fleet")
    ap.add_argument("--insecure", action="store_true",
                    help="ne pas valider le certificat (lab fermé uniquement)")
    args = ap.parse_args()

    if not args.appliquer and not args.verifier:
        print("[i] SIMULATION — rien ne sera écrit. Ajoutez --appliquer pour exécuter.\n")

    # ── Authentification ────────────────────────────────────────────────────
    entetes = {"Content-Type": "application/json", "kbn-xsrf": "true"}
    if args.api_key:
        entetes["Authorization"] = f"ApiKey {args.api_key}"
    else:
        utilisateur = args.utilisateur or input("Utilisateur Kibana : ")
        mdp = args.mot_de_passe or getpass.getpass("Mot de passe : ")
        jeton = base64.b64encode(f"{utilisateur}:{mdp}".encode()).decode()
        entetes["Authorization"] = f"Basic {jeton}"

    if args.insecure:
        contexte = ssl._create_unverified_context()
        print("[!] Validation TLS désactivée : acceptable en lab fermé, jamais ailleurs.")
    elif os.path.isfile(args.cacert):
        contexte = ssl.create_default_context(cafile=args.cacert)
    else:
        raise SystemExit(f"[ERREUR] CA introuvable : {args.cacert}\n"
                         f"         indiquez --cacert, ou --insecure en lab fermé.")

    fleet = Fleet(args.kibana, entetes, contexte)

    # ── Inventaire ──────────────────────────────────────────────────────────
    politiques = {p["name"]: p for p in fleet.pagine("/api/fleet/agent_policies")}
    print(f"[i] {len(politiques)} politiques d'agent lues sur {args.kibana}")

    paquets_tous = fleet.pagine("/api/fleet/package_policies")

    # ── Mode vérification : état des lieux, sans rien écrire ────────────────
    if args.verifier:
        print(f"[i] état des intégrations « Custom Logs » "
              f"({args.de:02d} à {args.a:02d})\n")
        print(f"  {'politique':<26} {'intégration':<36} {'espace de nom':<14} paquet")
        manquantes = anomalies = 0
        for n in range(args.de, args.a + 1):
            nn = f"{n:02d}"
            nom_politique = args.motif.replace("{NN}", nn)
            cible = politiques.get(nom_politique)
            if not cible:
                print(f"  {nom_politique:<26} POLITIQUE INTROUVABLE")
                manquantes += 1
                continue
            trouvees = [q for q in paquets_tous
                        if politiques_de(q, cible["id"])
                        and q.get("package", {}).get("name") in PAQUETS_CUSTOM_LOGS]
            if not trouvees:
                print(f"  {nom_politique:<26} {'— ABSENTE —':<36}")
                manquantes += 1
                continue
            for q in trouvees:
                ns = q.get("namespace") or ""
                attendu = f"student{nn}"
                marque = "" if ns == attendu else f"  <-- ATTENDU {attendu}"
                if marque:
                    anomalies += 1
                print(f"  {nom_politique:<26} {q['name'][:36]:<36} {ns:<14} "
                      f"{q['package']['name']} v{q['package']['version']}{marque}")
        total = args.a - args.de + 1
        print(f"\n[OK] {total - manquantes}/{total} politique(s) équipée(s), "
              f"{anomalies} espace(s) de nom incorrect(s).")
        if manquantes:
            print("     Relancez sans --verifier pour compléter.")
        return

    if args.reference not in politiques:
        raise SystemExit(f"[ERREUR] politique de référence absente : {args.reference}")

    paquets = paquets_tous
    ref_id = politiques[args.reference]["id"]
    recherches = (args.paquet,) if args.paquet else PAQUETS_CUSTOM_LOGS
    modeles = [q for q in paquets
               if politiques_de(q, ref_id)
               and q.get("package", {}).get("name") in recherches]

    if not modeles:
        raise SystemExit(
            f"[ERREUR] aucune intégration « Custom Logs » dans {args.reference}.\n"
            f"         Paquets recherchés : {', '.join(recherches)}.\n"
            f"         Créez-la d'abord À LA MAIN sur cette politique, en choisissant\n"
            f"         « Custom Logs (Filestream) » et NON « Custom Logs (Deprecated) » :\n"
            f"         c'est elle qui sert de modèle, et cela évite de deviner le format.\n"
            f"         Intégrations présentes : "
            + ", ".join(sorted({q.get('package', {}).get('name', '?') for q in paquets
                                if politiques_de(q, ref_id)})))

    modele = modeles[0]
    paquet = modele["package"]["name"]
    print(f"[i] modèle : « {modele['name']} » (paquet {paquet} "
          f"v{modele['package']['version']}, espace de nom {modele.get('namespace')})")
    if paquet == "log":
        print("[!] Ce modèle utilise « Custom Logs (Deprecated) ». La syntaxe multiligne\n"
              "    du chapitre 2 (parsers: - multiline:) est celle de FILESTREAM et ne\n"
              "    fonctionnera pas avec ce paquet. Recréez le modèle avec\n"
              "    « Custom Logs (Filestream) », puis relancez.")

    # ── Réplication ─────────────────────────────────────────────────────────
    cree = ignore = absent = 0
    for n in range(args.de, args.a + 1):
        nn = f"{n:02d}"
        nom_politique = args.motif.replace("{NN}", nn)
        cible = politiques.get(nom_politique)
        if not cible:
            print(f"  [absent]  {nom_politique} : politique introuvable")
            absent += 1
            continue
        if nom_politique == args.reference:
            print(f"  [modèle]  {nom_politique} : c'est la politique de référence")
            ignore += 1
            continue

        deja = [q for q in paquets
                if politiques_de(q, cible["id"])
                and q.get("package", {}).get("name") in PAQUETS_CUSTOM_LOGS]
        if deja:
            print(f"  [déjà]    {nom_politique} : « {deja[0]['name']} » existe — rien à faire")
            ignore += 1
            continue

        corps = {c: v for c, v in modele.items() if c not in CHAMPS_EN_LECTURE_SEULE}
        corps["name"] = args.nom_integration.replace("{POLITIQUE}", nom_politique)
        corps["policy_id"] = cible["id"]
        if "policy_ids" in corps:
            corps["policy_ids"] = [cible["id"]]
        # L'espace de nom suit le candidat : c'est la cloison des data streams.
        corps["namespace"] = f"student{nn}"
        for entree in corps.get("inputs", []):
            for flux in entree.get("streams", []):
                if "namespace" in flux:
                    flux["namespace"] = f"student{nn}"

        if args.appliquer:
            fleet.appel("/api/fleet/package_policies", "POST", corps)
            print(f"  [créé]    {nom_politique} : « {corps['name']} » "
                  f"(espace de nom {corps['namespace']})")
        else:
            print(f"  [à créer] {nom_politique} : « {corps['name']} » "
                  f"(espace de nom {corps['namespace']})")
        cree += 1

    print(f"\n[OK] {cree} intégration(s) {'créée(s)' if args.appliquer else 'à créer'}, "
          f"{ignore} ignorée(s), {absent} politique(s) introuvable(s).")
    if not args.appliquer and cree:
        print("     Relancez avec --appliquer pour écrire dans Fleet.")
    if args.appliquer and cree:
        print("     Les agents déjà enrôlés reçoivent la nouvelle révision en quelques\n"
              "     secondes, sans réinstallation. Vérifiez ensuite qu'un data stream\n"
              "     logs-shopflow_apache.access_json-studentNN se remplit.")


if __name__ == "__main__":
    main()
