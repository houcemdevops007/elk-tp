#!/usr/bin/env python3
"""Récupère les jetons d'enrôlement des candidats et produit leur fiche d'installation.

CE QU'IL FAUT SAVOIR D'ABORD : Fleet crée automatiquement un jeton
d'enrôlement pour CHAQUE politique d'agent, au moment où la politique est
créée. Il n'y a donc en général rien à générer — il faut les RÉCUPÉRER et les
distribuer. L'option --creer-si-absent ne sert qu'aux politiques qui n'en
auraient pas.

Le script produit, par candidat, un fichier contenant ses jetons et les
commandes d'installation prêtes à copier, avec l'URL de Fleet Server, la CA
interne et les étiquettes. Les fichiers sont écrits en 600 : ce sont des
secrets.

Usage :
    export KIBANA_API_KEY='<cle>'          # ou --utilisateur elastic
    python3 tools/generer-jetons.py --cacert ~/efi-elk-platform/pki/ca.crt
    python3 tools/generer-jetons.py --cacert ... --sortie ./jetons --ecrire

Options utiles :
    --de 1 --a 20          bornes des numéros de candidat
    --roles apache,k8s     rôles à traiter (par défaut : apache,tomcat,k8s)
    --version-agent 9.5.6  version de l'agent à installer
    --arch x86_64|arm64    architecture des VM candidates
    --ca-vm CHEMIN         chemin de la CA SUR LA VM DU CANDIDAT
    --creer-si-absent      crée le jeton quand la politique n'en a pas
    --masquer              n'affiche pas les jetons à l'écran
"""
import argparse
import base64
import getpass
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

ROLES_CONNUS = ("apache", "tomcat", "k8s")
ETIQUETTES = {"apache": "tp-apache", "tomcat": "tp-tomcat", "k8s": "tp-k8s"}


def appel(base, chemin, entetes, contexte, methode="GET", corps=None):
    url = f"{base.rstrip('/')}{chemin}"
    d = json.dumps(corps).encode() if corps is not None else None
    req = urllib.request.Request(url, data=d, method=methode)
    for k, v in entetes.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=60, context=contexte) as rep:
            brut = rep.read().decode()
            return json.loads(brut) if brut else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:400]
        aide = {401: "la clé doit être la valeur « encoded » ; sinon --utilisateur",
                403: "droits Fleet insuffisants : créez la clé depuis un compte admin"}.get(e.code, "")
        raise SystemExit(f"[ERREUR] {methode} {chemin} -> HTTP {e.code} : {detail}"
                         + (f"\n  [aide] {aide}" if aide else ""))
    except urllib.error.URLError as e:
        raise SystemExit(f"[ERREUR] Kibana injoignable ({url}) : {e.reason}")


def pagine(base, chemin, entetes, contexte):
    items, page = [], 1
    while True:
        sep = "&" if "?" in chemin else "?"
        lot = appel(base, f"{chemin}{sep}perPage=100&page={page}", entetes, contexte)
        items.extend(lot.get("items", []))
        if len(lot.get("items", [])) < 100:
            return items
        page += 1


def fiche(nn, jetons, args):
    """Fiche d'installation d'un candidat : ce qu'on lui transmet."""
    lignes = [
        f"FICHE D'INSTALLATION — student{nn}",
        "=" * 64,
        "",
        "CES JETONS SONT DES SECRETS.",
        "Ils ne vont ni dans un dépôt Git, ni dans un canal de discussion,",
        "ni dans une capture d'écran. Transmission individuelle uniquement.",
        "",
        f"Fleet Server : {args.fleet_url}",
        f"Kibana       : {args.kibana_public}",
        f"Namespace    : student{nn}",
        f"Agent        : {args.version_agent} ({args.arch})",
        "",
    ]
    for role, jeton, politique in jetons:
        archive = f"elastic-agent-{args.version_agent}-linux-{args.arch}"
        cible = {"apache": "la VM du candidat (Apache, puis Tomcat au chapitre 2)",
                 "tomcat": "la VM du backend, SI Tomcat a sa propre machine",
                 "k8s": "le cluster k3s, via un Secret — PAS en ligne de commande"}[role]
        lignes += [
            "-" * 64,
            f"[{role}]  politique : {politique}",
            f"         à utiliser sur : {cible}",
            f"         jeton : {jeton if not args.masquer else '(masqué)'}",
            "",
        ]
        if role == "k8s":
            lignes += [
                "  kubectl create namespace elastic-agent",
                "  kubectl -n elastic-agent create secret generic elastic-agent-creds \\",
                f"    --from-literal=enrollment-token='{jeton if not args.masquer else '<jeton>'}'",
                f"  kubectl -n elastic-agent create secret generic elastic-agent-ca \\",
                f"    --from-file=ca.crt={args.ca_vm}",
                "  kubectl apply -f 03-kubernetes/manifests/20-elastic-agent-daemonset.yaml",
                "",
            ]
        else:
            lignes += [
                f"  curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/{archive}.tar.gz",
                f"  tar xzf {archive}.tar.gz && cd {archive}",
                "  sudo ./elastic-agent install \\",
                f"    --url={args.fleet_url} \\",
                f"    --enrollment-token='{jeton if not args.masquer else '<jeton>'}' \\",
                f"    --certificate-authorities={args.ca_vm} \\",
                f"    --tag student{nn} --tag {ETIQUETTES[role]} \\",
                "    --non-interactive",
                "",
                "  Vérification :",
                "    sudo elastic-agent status --output=full",
                "",
            ]
    lignes += ["=" * 64,
               "Si l'enrôlement échoue sur « x509: certificate signed by unknown",
               "authority », c'est que la CA n'est pas à l'emplacement indiqué",
               f"ci-dessus ({args.ca_vm}) sur la VM.", ""]
    return "\n".join(lignes)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kibana", default=os.environ.get("KIBANA_URL", "https://172.16.3.53:5601"))
    ap.add_argument("--kibana-public", default="https://elk.efi-academy.com/tp/")
    ap.add_argument("--fleet-url", default="https://172.16.3.55:8220")
    ap.add_argument("--cacert", default=os.environ.get("EFI_CA", "/etc/efi/pki/ca.crt"))
    ap.add_argument("--ca-vm", default="/etc/efi/pki/ca.crt",
                    help="chemin de la CA SUR LA VM DU CANDIDAT")
    ap.add_argument("--api-key", default=os.environ.get("KIBANA_API_KEY"))
    ap.add_argument("--utilisateur")
    ap.add_argument("--mot-de-passe")
    ap.add_argument("--motif", default="efi-student{NN}-{ROLE}")
    ap.add_argument("--roles", default="apache,tomcat,k8s")
    ap.add_argument("--de", type=int, default=1)
    ap.add_argument("--a", type=int, default=20)
    ap.add_argument("--version-agent", default="9.5.5")
    ap.add_argument("--arch", default="x86_64", choices=["x86_64", "arm64"])
    ap.add_argument("--sortie", default="./jetons")
    ap.add_argument("--ecrire", action="store_true", help="écrit les fiches sur le disque")
    ap.add_argument("--creer-si-absent", action="store_true")
    ap.add_argument("--masquer", action="store_true")
    ap.add_argument("--insecure", action="store_true")
    args = ap.parse_args()

    roles = [r.strip() for r in args.roles.split(",") if r.strip()]
    for r in roles:
        if r not in ROLES_CONNUS:
            raise SystemExit(f"[ERREUR] rôle inconnu : {r} (connus : {', '.join(ROLES_CONNUS)})")

    entetes = {"Content-Type": "application/json", "kbn-xsrf": "true"}
    if args.api_key:
        entetes["Authorization"] = f"ApiKey {args.api_key}"
    else:
        u = args.utilisateur or input("Utilisateur Kibana : ")
        mdp = args.mot_de_passe or getpass.getpass("Mot de passe : ")
        entetes["Authorization"] = "Basic " + base64.b64encode(f"{u}:{mdp}".encode()).decode()

    if args.insecure:
        contexte = ssl._create_unverified_context()
    elif os.path.isfile(args.cacert):
        contexte = ssl.create_default_context(cafile=args.cacert)
    else:
        raise SystemExit(f"[ERREUR] CA introuvable : {args.cacert}")

    politiques = {p["name"]: p for p in pagine(args.kibana, "/api/fleet/agent_policies",
                                               entetes, contexte)}
    jetons_tous = pagine(args.kibana, "/api/fleet/enrollment_api_keys", entetes, contexte)
    par_politique = {}
    for j in jetons_tous:
        if j.get("active", True):
            par_politique.setdefault(j.get("policy_id"), []).append(j)

    print(f"[i] {len(politiques)} politiques, {len(jetons_tous)} jeton(s) d'enrôlement\n")

    total = crees = absents = 0
    for n in range(args.de, args.a + 1):
        nn = f"{n:02d}"
        fiches = []
        for role in roles:
            nom = args.motif.replace("{NN}", nn).replace("{ROLE}", role)
            pol = politiques.get(nom)
            if not pol:
                print(f"  [absent]  {nom}")
                absents += 1
                continue
            liste = par_politique.get(pol["id"], [])
            if not liste and args.creer_si_absent:
                r = appel(args.kibana, "/api/fleet/enrollment_api_keys", entetes, contexte,
                          "POST", {"policy_id": pol["id"], "name": f"jeton-{nom}"})
                liste = [r["item"]]
                crees += 1
                print(f"  [créé]    {nom}")
            if not liste:
                print(f"  [SANS JETON] {nom} — relancez avec --creer-si-absent")
                absents += 1
                continue
            fiches.append((role, liste[0].get("api_key", ""), nom))
        if not fiches:
            continue
        total += 1
        texte = fiche(nn, fiches, args)
        if args.ecrire:
            os.makedirs(args.sortie, exist_ok=True)
            chemin = os.path.join(args.sortie, f"student{nn}.txt")
            with open(os.open(chemin, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600),
                      "w", encoding="utf-8") as fh:
                fh.write(texte)
            print(f"  [fiche]   {chemin}  ({len(fiches)} jeton(s))")
        else:
            print(texte)

    print(f"\n[OK] {total} fiche(s), {crees} jeton(s) créé(s), {absents} manquant(s).")
    if args.ecrire:
        print(f"     Fiches dans {args.sortie}/ en droits 600. Transmission INDIVIDUELLE.")
        print(f"     À supprimer après distribution : shred -u {args.sortie}/*.txt")
    else:
        print("     Ajoutez --ecrire pour produire un fichier par candidat.")


if __name__ == "__main__":
    main()
