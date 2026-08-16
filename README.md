# Pré-check d'intervention — guide de mise en œuvre

Outil de vérification à distance de l'état d'un équipement avant intervention terrain, développé dans le cadre du mémoire *Expert en études et développement du SI*.

---

## Ce que fait l'outil

Avant tout déplacement, le script interroge l'interface Redfish de l'équipement cible et produit un rapport répondant à quatre questions :

1. Le matériel présent correspond-il à la nomenclature attendue ?
2. Quelles versions de firmware sont réellement embarquées ?
3. Ces versions sont-elles conformes à la baseline retenue pour le chantier ?
4. Un composant signale-t-il une alerte matérielle ?
5. Quelle séquence de mise à niveau permet d'atteindre la version cible ?

Il fonctionne **en lecture seule** : les seules requêtes non-GET sont l'ouverture et la fermeture de la session d'authentification.

---

## Prérequis

- PowerShell 7 ou supérieur (`pwsh`)
- Une connectivité vers l'équipement, ou un service Redfish simulé pour les tests

Vérifier la version installée :

```powershell
$PSVersionTable.PSVersion
```

---

## Mise en place de l'environnement de test

Redfish étant un standard publié par le DMTF, il est possible de développer et de tester sans matériel HPE, contre un service simulé.

### Option 1 — Docker (la plus simple)

```bash
docker run --rm -p 8000:8000 dmtf/redfish-mockup-server:latest
```

### Option 2 — Python

```bash
git clone https://github.com/DMTF/Redfish-Mockup-Server.git
cd Redfish-Mockup-Server
pip install -r requirements.txt
python redfishMockupServer.py -D ../mock -p 8000
```

Le dossier `mock/` fourni avec ce paquet contient une arborescence Redfish représentative d'un environnement Synergy : un châssis, un module de calcul, un Composer et six entrées d'inventaire firmware. Les versions y sont volontairement désalignées, l'une des entrées n'expose pas de version et un composant est en état `Warning`, de manière à produire un rapport contenant les trois statuts et une alerte matérielle.

Vérifier que le service répond :

```bash
curl http://127.0.0.1:8000/redfish/v1
```

---

## Exécution

### Contre le service simulé

```powershell
.\Invoke-PreCheck.ps1 -RedfishUri http://127.0.0.1:8000 -BaselineFile .\config\baseline.json
```

### Contre un équipement réel

```powershell
.\Invoke-PreCheck.ps1 -RedfishUri https://10.0.0.50 `
                      -Credential (Get-Credential) `
                      -BaselineFile .\config\baseline.json `
                      -SkipCertificateCheck
```

`-SkipCertificateCheck` ne doit être employé que pour les équipements portant un certificat auto-signé d'usine. En production, installer un certificat valide et retirer ce paramètre.

---

## Codes de sortie

| Code | Signification |
|---|---|
| 0 | Aucun écart — intervention déclenchable |
| 1 | Écarts non critiques, points non vérifiables ou alertes matérielles — à traiter avant déplacement |
| 2 | Écart sur composant critique — déplacement à suspendre |
| 3 | Échec d'exécution — service injoignable ou erreur |

Ces codes permettent l'appel du script depuis un traitement automatisé.

---

## Fichier de baseline

Le fichier `config/baseline.json` décrit la cible du chantier. Il contient :

- **`composants`** — pour chaque élément : le libellé, la version cible, le caractère critique, et le motif d'expression régulière servant au rapprochement avec le libellé exposé par l'équipement.
- **`chemins_composer`** — la table des versions cibles atteignables depuis chaque version installée, issue de la documentation constructeur.
- **`nomenclature_attendue`** — les quantités attendues pour le rapprochement de livraison : châssis, modules de calcul et modules d'interconnexion. Ces derniers n'étant exposés ni comme `Chassis` ni comme `Systems`, ils sont dénombrés à partir des entrées d'inventaire firmware rapprochées par le motif du composant `VirtualConnect`. Ce rapprochement est indirect et assumé comme tel.

Le motif de rapprochement est déclaré dans la configuration et non dans le code : les libellés varient d'un constructeur à l'autre, et cette séparation permet d'adapter l'outil sans le modifier.

**À faire avant chaque chantier** : renseigner les versions cibles depuis le Custom SPP retenu et vérifier la table des chemins auprès de la documentation constructeur en vigueur.

---

## Les trois statuts

L'outil distingue trois états, et cette distinction est une exigence de conception :

- **Conforme** — vérifié, la version relevée atteint ou dépasse la cible
- **Non conforme** — vérifié, un écart existe
- **Non vérifiable** — le contrôle n'a pas pu être effectué

Un point non vérifiable n'est jamais présenté comme conforme. Un dispositif de vérification qui masque ce qu'il n'a pas pu contrôler produit une confiance mal calibrée, plus dangereuse que l'absence de vérification.

L'état de santé est restitué **séparément** de la conformité de version. Un composant peut être à la version cible et signaler une alerte matérielle : ce sont deux informations distinctes, et les confondre reviendrait à en perdre une.

---

## Structure du paquet

```
precheck/
├── Invoke-PreCheck.ps1      script principal
├── config/
│   └── baseline.json        baseline cible et chemins de mise à niveau
├── mock/                    arborescence Redfish de test
│   └── redfish/v1/...
├── proto.py                 prototype de validation de l'algorithme
├── simuler.py               simulation du flux complet
└── rapports/                rapports produits (créé à l'exécution)
```

Les fichiers `proto.py` et `simuler.py` ont servi à valider l'algorithme de comparaison de versions et de résolution du chemin de mise à niveau avant portage. Ils constituent la trace de la démarche de test et peuvent figurer en annexe du mémoire.
