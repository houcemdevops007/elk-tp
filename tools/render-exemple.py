#!/usr/bin/env python3
"""Rend les fichiers de configuration avec des valeurs concretes, pour validation.

Les fichiers du depot contiennent des placeholders {{...}} : ils ne sont donc pas
directement verifiables par yamllint ou kubectl. Ce script applique la meme
substitution que le generateur HTML, avec les valeurs d'exemple declarees dans
chaque generateur.json (cle "exemple"), et ecrit le resultat dans .rendu/.

Usage :
    python3 tools/render-exemple.py            # tous les chapitres
    python3 tools/render-exemple.py 03-kubernetes
"""
import json
import re
import shutil
import sys
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
SORTIE = RACINE / ".rendu"
PLATEFORME = json.loads((RACINE / "tools" / "plateforme.json").read_text(encoding="utf-8"))
MOTIF = re.compile(r"\{\{([A-Z0-9_]+)\}\}")


def echappe_json(v):
    """Une valeur peut contenir des guillemets (clause ES|QL) : injectée telle
    quelle dans un fichier JSON, elle casserait le document."""
    return (str(v).replace("\\", "\\\\").replace('"', '\\"')
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t"))


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
    demandes = sys.argv[1:]
    if SORTIE.exists():
        shutil.rmtree(SORTIE)
    manquants = set()
    for spec_path in sorted(RACINE.glob("*/generateur.json")):
        chapitre = spec_path.parent
        if demandes and chapitre.name not in demandes:
            continue
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        valeurs = dict(PLATEFORME["fixed"], **spec.get("fixed", {}))
        for champ in spec["fields"]:
            valeurs[champ["key"]] = spec.get("exemple", {}).get(
                champ["key"], champ.get("default", ""))
        valeurs = resout(valeurs, spec.get("derived", {}))

        entrees = [e for e in spec.get("files", []) + spec.get("commands", []) if "from" in e]
        for entree in entrees:
            src = chapitre / entree["from"]
            texte = src.read_text(encoding="utf-8")
            manquants.update(m for m in MOTIF.findall(texte) if m not in valeurs)
            json_cible = src.suffix == ".json"

            def remplace(m, json_cible=json_cible):
                if m.group(1) not in valeurs:
                    return m.group(0)
                v = valeurs[m.group(1)]
                return echappe_json(v) if json_cible else v

            rendu = MOTIF.sub(remplace, texte)
            dst = SORTIE / chapitre.name / entree["from"]
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(rendu, encoding="utf-8")
        print(f"[OK] {chapitre.name} : {len(entrees)} fichiers rendus")
    if manquants:
        raise SystemExit("[ERREUR] placeholders sans valeur : " + ", ".join(sorted(manquants)))
    print(f"[OK] sortie : {SORTIE.relative_to(RACINE)}")


if __name__ == "__main__":
    main()
