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
  -> Custom Logs :
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
            raise SystemExit(f"[ERREUR] {methode} {chemin}\n  HTTP {e.code} : {detail}")
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
    ap.add_argument("--de", type=int, default=1)
    ap.add_argument("--a", type=int, default=20)
    ap.add_argument("--simuler", action="store_true", help="par défaut : simulation")
    ap.add_argument("--appliquer", action="store_true", help="écrit réellement dans Fleet")
    ap.add_argument("--insecure", action="store_true",
                    help="ne pas valider le certificat (lab fermé uniquement)")
    args = ap.parse_args()

    if not args.appliquer:
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

    if args.reference not in politiques:
        raise SystemExit(f"[ERREUR] politique de référence absente : {args.reference}")

    paquets = fleet.pagine("/api/fleet/package_policies")
    ref_id = politiques[args.reference]["id"]
    modeles = [q for q in paquets
               if politiques_de(q, ref_id) and q.get("package", {}).get("name") == "log"]

    if not modeles:
        raise SystemExit(
            f"[ERREUR] aucune intégration « Custom Logs » (paquet « log ») dans "
            f"{args.reference}.\n"
            f"         Créez-la d'abord À LA MAIN sur cette politique : c'est elle qui\n"
            f"         sert de modèle, et cela évite de deviner le format attendu.\n"
            f"         Intégrations présentes : "
            + ", ".join(sorted({q.get('package', {}).get('name', '?') for q in paquets
                                if politiques_de(q, ref_id)})))
    modele = modeles[0]
    print(f"[i] modèle : « {modele['name']} » (paquet {modele['package']['name']} "
          f"v{modele['package']['version']}, espace de nom {modele.get('namespace')})")

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
                if politiques_de(q, cible["id"]) and q.get("package", {}).get("name") == "log"]
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
