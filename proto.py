"""Prototype de validation de l'algorithme de pre-check.
Objectif : eprouver la comparaison de versions et la resolution du chemin
de mise a niveau avant portage en PowerShell.
"""
import json
from itertools import count

STATUT_CONFORME = "Conforme"
STATUT_NON_CONFORME = "Non conforme"
STATUT_NON_VERIFIABLE = "Non verifiable"


def comparer_versions(a, b):
    """Compare deux versions de forme 'x.y.z'. Renvoie -1, 0 ou 1.
    Les segments non numeriques sont ignores pour rester tolerant aux
    suffixes constructeur (ex : '2.68 (03/15/2024)')."""
    def decouper(v):
        segments = []
        for morceau in str(v).replace("-", ".").split("."):
            chiffres = "".join(c for c in morceau if c.isdigit())
            if chiffres:
                segments.append(int(chiffres))
        return segments

    sa, sb = decouper(a), decouper(b)
    for i in range(max(len(sa), len(sb))):
        va = sa[i] if i < len(sa) else 0
        vb = sb[i] if i < len(sb) else 0
        if va != vb:
            return -1 if va < vb else 1
    return 0


def resoudre_chemin(version_installee, version_cible, chemins):
    """Determine la sequence de mises a niveau menant de la version installee
    a la version cible. Parcours en largeur : renvoie le chemin le plus court,
    ou None si la cible est inatteignable."""
    if comparer_versions(version_installee, version_cible) == 0:
        return []

    file = [(version_installee, [])]
    vus = {version_installee}
    while file:
        courant, chemin = file.pop(0)
        for suivant in chemins.get(courant, []):
            if suivant in vus:
                continue
            nouveau = chemin + [suivant]
            if comparer_versions(suivant, version_cible) == 0:
                return nouveau
            vus.add(suivant)
            file.append((suivant, nouveau))
    return None


def evaluer_composant(releve, cible):
    """Renvoie le statut d'un composant au regard de sa version cible."""
    if releve is None:
        return STATUT_NON_VERIFIABLE
    return STATUT_CONFORME if comparer_versions(releve, cible) >= 0 else STATUT_NON_CONFORME


# ---------------------------------------------------------------- jeux d'essai

def tester():
    ok = count()
    ko = []

    def verifier(libelle, obtenu, attendu):
        if obtenu == attendu:
            next(ok)
        else:
            ko.append(f"{libelle} : obtenu {obtenu!r}, attendu {attendu!r}")

    # Comparaison de versions
    verifier("egalite", comparer_versions("8.30.01", "8.30.01"), 0)
    verifier("inferieur", comparer_versions("8.00.01", "8.30.01"), -1)
    verifier("superieur", comparer_versions("8.50.01", "8.30.01"), 1)
    verifier("longueurs inegales", comparer_versions("2.68", "2.68.0"), 0)
    verifier("suffixe constructeur", comparer_versions("2.68 (03/15/2024)", "2.68"), 1)
    verifier("segment a deux chiffres", comparer_versions("1.9.0", "1.10.0"), -1)

    # Resolution du chemin de mise a niveau
    chemins = json.load(open("config/baseline.json"))["chemins_composer"]
    verifier("chemin direct", resoudre_chemin("8.00.01", "8.30.01", chemins), ["8.30.01"])
    verifier("chemin en deux sauts", resoudre_chemin("7.20.00", "8.30.01", chemins), ["8.00.01", "8.30.01"])
    verifier("deja a jour", resoudre_chemin("8.30.01", "8.30.01", chemins), [])
    verifier("cible inatteignable", resoudre_chemin("6.00.00", "8.30.01", chemins), None)

    # Evaluation de statut
    verifier("statut conforme", evaluer_composant("8.30.01", "8.30.01"), STATUT_CONFORME)
    verifier("statut non conforme", evaluer_composant("8.00.01", "8.30.01"), STATUT_NON_CONFORME)
    verifier("statut non verifiable", evaluer_composant(None, "8.30.01"), STATUT_NON_VERIFIABLE)
    verifier("version superieure acceptee", evaluer_composant("8.50.01", "8.30.01"), STATUT_CONFORME)

    total = next(ok)
    print(f"{total} tests reussis, {len(ko)} en echec")
    for echec in ko:
        print("  ECHEC :", echec)
    return not ko


if __name__ == "__main__":
    import sys
    sys.exit(0 if tester() else 1)
