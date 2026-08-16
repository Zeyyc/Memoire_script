# Tutoriel — faire tourner le pré-check sur ton poste

Objectif : avoir le script qui s'exécute et affiche un rapport, sans matériel HPE.
Compte environ 30 minutes la première fois.

Le principe : on installe PowerShell 7, on lance un **faux serveur Redfish** sur ton poste (qui simule un équipement), et le script vient l'interroger comme s'il s'agissait d'un vrai Composer.

---

## Étape 1 — Récupérer les fichiers

Télécharge le dossier `precheck` que je t'ai fourni et place-le quelque part de simple, par exemple :

```
C:\memoire\precheck\
```

Tu dois y trouver :

```
precheck\
├── Invoke-PreCheck.ps1
├── README.md
├── config\
│   └── baseline.json
├── mock\
│   └── redfish\v1\...
├── proto.py
└── simuler.py
```

Si le dossier `mock` est vide ou incomplet, dis-le-moi, je te le régénère.

---

## Étape 2 — Installer PowerShell 7

Le PowerShell installé d'origine sur Windows est la version 5.1. Le script a besoin de la **version 7**, qui s'installe à côté sans rien casser.

Ouvre une invite de commandes et tape :

```
winget install --id Microsoft.PowerShell --source winget
```

Si `winget` n'est pas disponible, télécharge l'installeur `.msi` depuis :
https://github.com/PowerShell/PowerShell/releases

Une fois installé, tu as une nouvelle application dans le menu Démarrer : **PowerShell 7** (icône noire, à ne pas confondre avec « Windows PowerShell » en bleu).

Ouvre **PowerShell 7** et vérifie :

```powershell
$PSVersionTable.PSVersion
```

Tu dois voir un numéro commençant par 7. Si tu vois 5.1, tu as ouvert la mauvaise application.

---

## Étape 3 — Autoriser l'exécution du script

Par défaut Windows bloque les scripts non signés. Dans PowerShell 7 :

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Réponds `O` (ou `Y`) à la confirmation.

Cette commande n'autorise que ton compte utilisateur, et seulement les scripts locaux. C'est le réglage recommandé par Microsoft pour un poste de développement.

**Si le script refuse quand même de démarrer**, c'est que Windows l'a marqué comme « téléchargé depuis Internet ». Débloque-le :

```powershell
Unblock-File -Path C:\memoire\precheck\Invoke-PreCheck.ps1
```

---

## Étape 4 — Lancer le faux serveur Redfish

C'est ce qui va simuler l'équipement. Deux méthodes, prends celle qui te va.

### Méthode A — avec Python (recommandée, plus légère)

Vérifie d'abord que Python est installé :

```powershell
python --version
```

Si ce n'est pas le cas : `winget install --id Python.Python.3.12`

Ensuite, dans une fenêtre PowerShell 7 :

```powershell
cd C:\memoire
git clone https://github.com/DMTF/Redfish-Mockup-Server.git
cd Redfish-Mockup-Server
pip install -r requirements.txt
python redfishMockupServer.py -D C:\memoire\precheck\mock -p 8000
```

Si tu n'as pas `git`, télécharge le dépôt en ZIP depuis la page GitHub et dézippe-le.

### Méthode B — avec Docker

Si Docker Desktop est installé :

```powershell
docker run --rm -p 8000:8000 -v C:\memoire\precheck\mock:/mockup dmtf/redfish-mockup-server:latest -D /mockup
```

### Dans les deux cas

**Laisse cette fenêtre ouverte.** Le serveur tourne tant qu'elle est ouverte. Tu dois voir apparaître quelque chose comme `Serving Redfish mockup on port: 8000`.

Ouvre ton navigateur sur `http://127.0.0.1:8000/redfish/v1` — tu dois voir du JSON s'afficher. Si oui, le serveur fonctionne.

---

## Étape 5 — Exécuter le pré-check

Ouvre une **deuxième fenêtre PowerShell 7** (la première est occupée par le serveur).

```powershell
cd C:\memoire\precheck
.\Invoke-PreCheck.ps1 -RedfishUri http://127.0.0.1:8000 -BaselineFile .\config\baseline.json
```

Tu dois obtenir un rapport de ce type :

```
 NOMENCLATURE
  Chassis                attendu 8    constate 1    Non conforme
  Modules de calcul      attendu 80   constate 1    Non conforme
  Modules interconnexion attendu 4    constate 1    Non conforme

 CONFORMITE FIRMWARE
  HPE Synergy Composer (OneView)   7.20.00  -> 8.30.01   Non conforme
  Frame Link Module                1.24.00  -> 1.24.00   Conforme
  Module Virtual Connect           5.20.00  -> 5.20.00   Conforme
  BIOS module de calcul            2.68     -> 2.68      Conforme
  Controleur iLO                   2.90     -> 2.98      Non conforme
  Adaptateur d'entree-sortie       n/c      -> 12.25.10  Non verifiable

 ETAT DE SANTE
  Firmware           iLO 5                            Warning

 SEQUENCE DE MISE A NIVEAU
  Sequence requise depuis 7.20.00 : 8.00.01 puis 8.30.01.
  L'infrastructure partagee (Frame Link Modules, modules
  d'interconnexion) doit etre mise a niveau apres le Composer, avant
  les modules de calcul.

 SYNTHESE
  Conforme       : 3
  Non conforme   : 5
  Non verifiable : 1

 DECISION : NON PRET - 1 ecart(s) sur composant critique
```

Les trois écarts de nomenclature sont normaux : le service simulé ne reproduit qu'un châssis, un module de calcul et un module d'interconnexion, alors que la baseline en déclare huit, quatre-vingts et quatre. Ils montrent que le rapprochement fonctionne.

Les rapports JSON et CSV sont écrits dans `C:\memoire\precheck\rapports\`.

---

## Étape 6 — Jouer avec pour comprendre

C'est l'étape la plus importante pour la soutenance. Modifie des valeurs et observe ce qui change.

### Faire passer un composant en conforme

Ouvre `mock\redfish\v1\UpdateService\FirmwareInventory\iLO-1\index.json` et remplace `"Version": "2.90"` par `"Version": "2.98"`. Relance le script : le contrôleur iLO passe en vert.

### Voir la séquence se raccourcir

C'est **la démonstration la plus parlante pour le jury**. Le Composer est en `7.20.00` face à une cible en `8.30.01` : la séquence affiche `8.00.01 puis 8.30.01`, parce qu'on ne peut pas sauter directement à la version cible.

Mets maintenant `"Version": "8.00.01"` dans `Composer-1\index.json` et relance : la séquence tombe à une seule étape. C'est exactement l'information qui a manqué sur le chantier étudié.

### Comprendre le statut « non vérifiable »

L'entrée `IOA-1` est présente dans la collection mais n'expose pas de champ `Version` : le composant est classé « Non vérifiable » et non « Conforme ». Ajoute-lui `"Version": "12.25.10"` et relance : il passe en conforme. C'est la distinction qui compte — un point qu'on n'a pas pu contrôler ne doit jamais être présenté comme un point vérifié.

### Séparer la santé de la version

L'entrée `iLO-1` est en `"Health": "Warning"`. Le bloc `ETAT DE SANTE` la signale même quand la version est à jour : un composant peut être parfaitement aligné et sur le point de tomber en panne.

### Modifier la cible

Ouvre `config\baseline.json` et change une `version_cible`. C'est ce que tu ferais avant un vrai chantier, en fonction du Custom SPP retenu.

---

## Si ça ne marche pas

Je n'ai pas pu exécuter le script PowerShell dans mon environnement — il n'y a pas d'interpréteur PowerShell là où je travaille. J'ai validé l'algorithme en Python (les 14 tests de `proto.py` passent) et j'ai vérifié le flux complet, mais **une erreur de syntaxe PowerShell reste possible**. C'est précisément pour ça qu'il faut que tu le lances.

Si tu as une erreur, copie-moi le message complet, y compris les lignes qui commencent par `At C:\...` — je corrige.

### Erreurs fréquentes et leur cause

| Message | Cause | Solution |
|---|---|---|
| `n'est pas reconnu comme nom d'applet` | Tu es dans PowerShell 5.1 | Ouvre PowerShell 7 (icône noire) |
| `L'exécution de scripts est désactivée` | Politique d'exécution | Refais l'étape 3 |
| `Impossible de se connecter au serveur distant` | Le mockup ne tourne pas | Vérifie la fenêtre du serveur, teste l'URL dans le navigateur |
| `Ressource inaccessible [/redfish/v1/...]` | Chemin du mock incorrect | Vérifie le `-D` passé au serveur |
| Caractères accentués mal affichés | Encodage de la console | Sans gravité, ou lance `chcp 65001` avant |

---

## Vérifier au passage l'algorithme en Python

Indépendamment de PowerShell, tu peux lancer les tests unitaires :

```powershell
cd C:\memoire\precheck
python proto.py
```

Tu dois voir `14 tests reussis, 0 en echec`.

Et la simulation du flux complet :

```powershell
python simuler.py
```

Ces deux fichiers sont utiles au mémoire : ils prouvent que tu as testé ta logique avant de l'implémenter, ce qui est une démarche d'ingénieur. Ils ont leur place en annexe.

---

## Ce qu'il faut retenir pour l'oral

Trois choses que le jury peut te demander :

**Pourquoi un environnement simulé plutôt qu'un vrai équipement ?**
Parce que Redfish est un standard ouvert du DMTF, pas une technologie HPE. Développer contre le standard plutôt que contre un équipement particulier rend l'outil portable au multivendeur — ce qui correspond au positionnement de CDS. L'implémentation HPE, c'est iLO ; il en existe d'autres chez Dell, Lenovo ou Supermicro.

**Comment as-tu testé ?**
Par des tests unitaires sur la logique de comparaison de versions et de résolution du chemin de mise à niveau, puis par une simulation du flux complet contre un service Redfish de test. Un défaut a d'ailleurs été trouvé de cette manière : le rapprochement entre les libellés de la baseline et ceux exposés par l'équipement échouait, ce qui faisait apparaître à tort des composants comme non vérifiables. La correction a consisté à externaliser le motif de rapprochement dans le fichier de configuration.

**Pourquoi trois statuts et pas deux ?**
Parce qu'un point qui n'a pas pu être vérifié n'est pas un point conforme. Un outil qui masque ce qu'il n'a pas contrôlé produit une confiance injustifiée, ce qui est plus dangereux que l'absence d'outil.
