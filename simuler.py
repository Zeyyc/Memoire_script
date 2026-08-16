"""Simule l'execution du script PowerShell contre le mock local,
afin de verifier le flux complet et la forme du rapport produit."""
import json, os, re
from proto import comparer_versions, resoudre_chemin, \
    STATUT_CONFORME, STATUT_NON_CONFORME, STATUT_NON_VERIFIABLE

B = "mock/redfish/v1"

def get(path=""):
    p = os.path.join(B, path.replace("/redfish/v1", "").lstrip("/"), "index.json")
    return json.load(open(p)) if os.path.exists(p) else None

def collection(path):
    c = get(path)
    return [get(m["@odata.id"]) for m in c.get("Members", [])] if c else []

baseline = json.load(open("config/baseline.json"))

# --- collecte
chassis = collection("/redfish/v1/Chassis")
systemes = collection("/redfish/v1/Systems")
svc = get("/redfish/v1/UpdateService")
firmware = collection(svc["FirmwareInventory"]["@odata.id"]) if svc else []

# --- conformite firmware
resultats = []
for comp in baseline["composants"]:
    motif = comp["motif"]
    releve = next((f for f in firmware
                   if re.search(motif, f.get("Name", ""), re.I)
                   or re.search(motif, f.get("Id", ""), re.I)), None)
    if not releve or not releve.get("Version"):
        resultats.append((comp["libelle"], "n/c", comp["version_cible"],
                          STATUT_NON_VERIFIABLE, comp["critique"]))
        continue
    ecart = comparer_versions(releve["Version"], comp["version_cible"])
    statut = STATUT_CONFORME if ecart >= 0 else STATUT_NON_CONFORME
    resultats.append((comp["libelle"], releve["Version"], comp["version_cible"],
                      statut, comp["critique"]))

# --- nomenclature
att = baseline["nomenclature_attendue"]
motif_ic = next(c["motif"] for c in baseline["composants"] if c["cle"] == "VirtualConnect")
nb_ic = sum(1 for f in firmware
            if re.search(motif_ic, f.get("Name", ""), re.I)
            or re.search(motif_ic, f.get("Id", ""), re.I))
nomenclature = [
    ("Chassis", att["chassis"], len(chassis)),
    ("Modules de calcul", att["modules_calcul"], len(systemes)),
    ("Modules interconnexion", att["modules_interconnexion"], nb_ic),
]

# --- sequence
chemins = {k: v for k, v in baseline["chemins_composer"].items() if k != "commentaire"}
cible = next(c["version_cible"] for c in baseline["composants"] if c["cle"] == "Composer")
installee = next((f["Version"] for f in firmware if "composer" in f["Name"].lower()), None)
sequence = resoudre_chemin(installee, cible, chemins) if installee else None

# --- restitution
L = "-" * 62
print(f"\n{L}\n RAPPORT DE PRE-CHECK D'INTERVENTION\n Cible   : http://127.0.0.1:8000")
print(f" Baseline: {baseline['nom']} ({baseline['version']})\n{L}")

print("\n NOMENCLATURE")
for lib, a, c in nomenclature:
    s = STATUT_CONFORME if a == c else (STATUT_NON_VERIFIABLE if c == 0 else STATUT_NON_CONFORME)
    print(f"  {lib:<22} attendu {a:<4} constate {c:<4} {s}")

print("\n CONFORMITE FIRMWARE")
for lib, rel, cib, st, crit in resultats:
    marque = " (critique)" if crit and st == STATUT_NON_CONFORME else ""
    print(f"  {lib:<32} {rel:<10} -> {cib:<10} {st}{marque}")

print("\n SEQUENCE DE MISE A NIVEAU")
if sequence is None:
    print(f"  Aucun chemin connu depuis {installee} vers {cible}.")
elif not sequence:
    print(f"  Le Composer est deja en version cible ({cible}).")
else:
    print(f"  Sequence requise depuis {installee} : " + " puis ".join(sequence))
    print("  L'infrastructure partagee doit suivre le Composer, avant les modules de calcul.")

tous = [r[3] for r in resultats] + [
    STATUT_CONFORME if a == c else (STATUT_NON_VERIFIABLE if c == 0 else STATUT_NON_CONFORME)
    for _, a, c in nomenclature]
print(f"\n SYNTHESE")
print(f"  Conforme       : {tous.count(STATUT_CONFORME)}")
print(f"  Non conforme   : {tous.count(STATUT_NON_CONFORME)}")
print(f"  Non verifiable : {tous.count(STATUT_NON_VERIFIABLE)}")

bloquants = [r for r in resultats if r[4] and r[3] == STATUT_NON_CONFORME]
decision = (f"NON PRET - {len(bloquants)} ecart(s) sur composant critique" if bloquants
            else "PRET SOUS RESERVE - points a traiter avant deplacement"
            if STATUT_NON_CONFORME in tous or STATUT_NON_VERIFIABLE in tous
            else "PRET - aucun ecart detecte")
print(f"\n DECISION : {decision}\n{L}\n")
