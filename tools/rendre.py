#!/usr/bin/env python3
"""Rend les fichiers d'un chapitre avec VOS valeurs, en ligne de commande.

Les fichiers de `configs/`, `manifests/`, `scripts/` et `alertes/` sont des
MODÈLES : ils portent des placeholders `{{MAJUSCULES}}`. Copiés tels quels sur
une VM, Apache refuse de démarrer sur
« Cannot access directory '/etc/apache2/{{APACHE_LOG_DIR}}/' ».

Le générateur HTML fait cette substitution dans le navigateur. Ce script fait
la même chose dans un terminal, à partir de la MÊME source de vérité : les
champs déclarés dans generateur.json et les valeurs fixes de plateforme.json.

Usage :
    python3 tools/rendre.py 01-apache --liste
    python3 tools/rendre.py 01-apache --NUM 20 --STUDENT_HOST vault \\
        --STUDENT_IP 172.16.20.20 --sortie ~/rendu-student20
    python3 tools/rendre.py 01-apache --NUM 20 --interactif
"""
import argparse
import json
import os
import re
import sys

RACINE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOTIF = re.compile(r"\{\{([A-Z0-9_]+)\}\}")


def resout(valeurs, derived):
    out = dict(valeurs)
    for _ in range(6):
        change = False
        for cle, gabarit in derived.items():
            v = MOTIF.sub(lambda m: out.get(m.group(1), m.group(0)), gabarit)
            if out.get(cle) != v:
                out[cle], change = v, True
        if not change:
            break
    return out


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("chapitre", nargs="?", help="01-apache, 02-tomcat, 03-kubernetes…")
    ap.add_argument("--sortie", default="./rendu")
    ap.add_argument("--liste", action="store_true", help="affiche les champs attendus")
    ap.add_argument("--interactif", action="store_true", help="demande les champs manquants")
    ap.add_argument("-h", "--help", action="store_true")
    args, inconnus = ap.parse_known_args()

    if args.help or not args.chapitre:
        print(__doc__)
        chapitres = sorted(d for d in os.listdir(RACINE)
                           if os.path.isfile(os.path.join(RACINE, d, "generateur.json")))
        print("Chapitres disponibles : " + ", ".join(chapitres))
        return

    dossier = os.path.join(RACINE, args.chapitre)
    spec_path = os.path.join(dossier, "generateur.json")
    if not os.path.isfile(spec_path):
        raise SystemExit(f"[ERREUR] chapitre inconnu : {args.chapitre}")
    spec = json.load(open(spec_path, encoding="utf-8"))
    plateforme = json.load(open(os.path.join(RACINE, "tools", "plateforme.json"),
                                encoding="utf-8"))

    if args.liste:
        print(f"Champs attendus pour {args.chapitre} :\n")
        for f in spec["fields"]:
            obligatoire = "OBLIGATOIRE" if f.get("required") else "facultatif"
            defaut = f.get("default", "")
            print(f"  --{f['key']:<18} {obligatoire:<12} défaut: {defaut or '(aucun)'}")
            if f.get("help"):
                print(f"      {f['help'][:100]}")
        return

    # Valeurs passées en --CLE valeur
    fournies = {}
    i = 0
    while i < len(inconnus):
        if inconnus[i].startswith("--") and i + 1 < len(inconnus):
            fournies[inconnus[i][2:]] = inconnus[i + 1]
            i += 2
        else:
            raise SystemExit(f"[ERREUR] argument non reconnu : {inconnus[i]}")

    valeurs = dict(plateforme["fixed"], **spec.get("fixed", {}))
    manquants, secrets_vides = [], []
    for f in spec["fields"]:
        cle = f["key"]
        v = fournies.get(cle, f.get("default", ""))
        # Un secret ne se passe pas en ligne de commande : il resterait dans
        # l'historique du shell. On rend une valeur vide, et les scripts
        # concernés le réclament à l'exécution (argument ou variable).
        if not v and f.get("type") == "password":
            secrets_vides.append(cle)
            valeurs[cle] = ""
            continue
        if not v and f.get("required"):
            if args.interactif:
                v = input(f"{cle} ({f.get('help','')[:60]}) : ").strip()
            else:
                manquants.append(cle)
        if v and f.get("pattern") and not re.match(f["pattern"], v):
            raise SystemExit(f"[ERREUR] {cle} = « {v} » : {f.get('error', 'format invalide')}")
        valeurs[cle] = v
    if manquants:
        raise SystemExit("[ERREUR] champs obligatoires manquants : "
                         + ", ".join("--" + m for m in manquants)
                         + f"\n         (liste complète : python3 tools/rendre.py {args.chapitre} --liste)")

    valeurs = resout(valeurs, spec.get("derived", {}))
    os.makedirs(args.sortie, exist_ok=True)
    if secrets_vides:
        print("[i] secrets laissés vides (à fournir à l'exécution) : "
              + ", ".join(secrets_vides))

    print(f"[i] chapitre {args.chapitre}  ->  {args.sortie}")
    for cle in spec.get("recap", []):
        if valeurs.get(cle):
            print(f"    {cle:<16} = {valeurs[cle]}")
    print()

    secret = {f["key"] for f in spec["fields"] if f.get("type") == "password"}
    ecrits = 0
    for entree in spec.get("files", []) + spec.get("commands", []):
        if "from" not in entree:
            continue
        src = os.path.join(dossier, entree["from"])
        texte = open(src, encoding="utf-8").read()
        json_cible = src.endswith(".json")

        def remplace(m, json_cible=json_cible):
            if m.group(1) not in valeurs:
                return m.group(0)
            v = valeurs[m.group(1)]
            if json_cible:
                v = (v.replace("\\", "\\\\").replace('"', '\\"')
                      .replace("\n", "\\n").replace("\t", "\\t"))
            return v

        rendu = MOTIF.sub(remplace, texte)
        cible = os.path.join(args.sortie, entree["name"])
        # Un fichier contenant un secret ne doit pas être lisible par tous.
        contient_secret = any(valeurs.get(s) and valeurs[s] in rendu for s in secret)
        mode = 0o600 if contient_secret else 0o644
        with open(os.open(cible, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, mode),
                  "w", encoding="utf-8") as fh:
            fh.write(rendu)
        if entree["from"].startswith("scripts/") or entree["name"].endswith(".sh"):
            os.chmod(cible, mode | 0o111)
        ecrits += 1
        destination = MOTIF.sub(lambda m: valeurs.get(m.group(1), m.group(0)),
                                entree.get("path", ""))
        marque = "  [600]" if contient_secret else ""
        print(f"    {entree['name']:<38} {destination[:60]}{marque}")

    restants = sorted({m for f in os.listdir(args.sortie)
                       for m in MOTIF.findall(open(os.path.join(args.sortie, f),
                                                   encoding="utf-8", errors="ignore").read())})
    print(f"\n[OK] {ecrits} fichier(s) rendu(s) dans {args.sortie}")
    if restants:
        print(f"[!] placeholders NON résolus : {', '.join(restants)}")
        sys.exit(1)
    print("    aucun placeholder résiduel : les fichiers sont utilisables tels quels.")


if __name__ == "__main__":
    main()
