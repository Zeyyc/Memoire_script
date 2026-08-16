<#
.SYNOPSIS
    Pre-check d'intervention : releve a distance l'etat reel d'un equipement
    via l'interface Redfish et le confronte a une baseline de reference.

.DESCRIPTION
    Ce script interroge un service Redfish en lecture seule afin d'etablir,
    avant tout deplacement sur site :
      - l'inventaire materiel reellement present (chassis, modules, numeros de serie)
      - les versions de firmware embarquees sur chaque composant
      - l'etat de sante des composants
      - la conformite a la baseline cible et la sequence de mise a niveau requise

    Aucune operation de modification n'est effectuee. Les seules requetes non-GET
    sont la creation et la suppression de la session d'authentification.

.PARAMETER RedfishUri
    URI racine du service Redfish (ex : https://192.168.1.50).

.PARAMETER Credential
    Identifiants d'acces. Compte en lecture seule recommande.

.PARAMETER BaselineFile
    Chemin du fichier JSON decrivant la baseline cible et les chemins de mise a niveau.

.PARAMETER OutputPath
    Repertoire de destination des rapports. Defaut : .\rapports

.PARAMETER SkipCertificateCheck
    Ignore la validation du certificat TLS. A reserver aux environnements de test
    et aux equipements portant un certificat auto-signe d'usine.

.EXAMPLE
    .\Invoke-PreCheck.ps1 -RedfishUri https://192.168.1.50 -Credential (Get-Credential) `
                          -BaselineFile .\config\baseline.json

.EXAMPLE
    # Contre un service simule (DMTF Redfish Mockup Server)
    .\Invoke-PreCheck.ps1 -RedfishUri http://127.0.0.1:8000 -BaselineFile .\config\baseline.json

.NOTES
    Auteur  : Mikail SERCE - HPE CDS France
    Contexte: Memoire "Expert en etudes et developpement du SI"
    Requiert: PowerShell 7 ou superieur
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https?://')]
    [string]$RedfishUri,

    [Parameter()]
    [pscredential]$Credential,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$BaselineFile,

    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot 'rapports'),

    [Parameter()]
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ----------------------------------------------------- Constantes

# Trois statuts, et non deux. La distinction entre "non conforme" et
# "non verifiable" est une exigence de conception : un point qui n'a pas pu
# etre controle ne doit jamais etre presente comme un point conforme.
$script:CONFORME       = 'Conforme'
$script:NON_CONFORME   = 'Non conforme'
$script:NON_VERIFIABLE = 'Non verifiable'

$script:Session = @{ Token = $null; Location = $null }

#endregion

#region ----------------------------------------------------- Fonctions utilitaires

function Compare-Version {
    <#
        Compare deux versions de forme 'x.y.z'. Renvoie -1, 0 ou 1.
        Les caracteres non numeriques sont ecartes pour tolerer les suffixes
        constructeur du type '2.68 (03/15/2024)'.
    #>
    [OutputType([int])]
    param([string]$Reference, [string]$Difference)

    function ConvertTo-Segments {
        param([string]$Version)
        $segments = @()
        foreach ($morceau in ($Version -replace '-', '.').Split('.')) {
            $chiffres = ($morceau -replace '\D', '')
            if ($chiffres) { $segments += [int]$chiffres }
        }
        return , $segments
    }

    $a = ConvertTo-Segments $Reference
    $b = ConvertTo-Segments $Difference
    $longueur = [Math]::Max($a.Count, $b.Count)

    for ($i = 0; $i -lt $longueur; $i++) {
        $va = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $vb = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($va -ne $vb) { return $(if ($va -lt $vb) { -1 } else { 1 }) }
    }
    return 0
}

function Resolve-UpgradePath {
    <#
        Determine la sequence de mises a niveau menant de la version installee
        a la version cible, en respectant les chemins admissibles publies par
        le constructeur.

        Parcours en largeur : renvoie le chemin le plus court. Un tableau vide
        signifie que la version cible est deja atteinte ; $null signifie
        qu'aucun chemin n'existe depuis la version installee.

        C'est la fonction qui repond directement au probleme rencontre lors du
        deploiement etudie : une mise a niveau tentee hors chemin admissible
        expose a un etat intermediaire dont la sortie impose une reinstallation.
    #>
    [OutputType([string[]])]
    param(
        [string]$VersionInstallee,
        [string]$VersionCible,
        [hashtable]$Chemins
    )

    if ((Compare-Version $VersionInstallee $VersionCible) -eq 0) { return @() }

    $file = [System.Collections.Generic.Queue[object]]::new()
    $file.Enqueue(@{ Version = $VersionInstallee; Chemin = @() })
    $vus = [System.Collections.Generic.HashSet[string]]::new()
    [void]$vus.Add($VersionInstallee)

    while ($file.Count -gt 0) {
        $courant = $file.Dequeue()
        if (-not $Chemins.ContainsKey($courant.Version)) { continue }

        foreach ($suivant in $Chemins[$courant.Version]) {
            if ($vus.Contains($suivant)) { continue }
            $nouveau = $courant.Chemin + $suivant
            if ((Compare-Version $suivant $VersionCible) -eq 0) { return ,$nouveau }
            [void]$vus.Add($suivant)
            $file.Enqueue(@{ Version = $suivant; Chemin = $nouveau })
        }
    }
    return $null
}

function Write-Etape {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor DarkGray
}

function Format-Paragraphe {
    <#
        Replie un texte long sur une largeur donnee. La restitution console est
        destinee a etre lue sur site : une ligne qui deborde du terminal est une
        ligne qui ne sera pas lue.
    #>
    param([string]$Texte, [int]$Largeur = 70, [string]$Indentation = '  ')

    $lignes = @()
    $courante = ''
    foreach ($mot in $Texte -split '\s+') {
        if ($courante -and ($courante.Length + 1 + $mot.Length) -gt $Largeur) {
            $lignes += $Indentation + $courante
            $courante = $mot
        }
        else {
            $courante = if ($courante) { "$courante $mot" } else { $mot }
        }
    }
    if ($courante) { $lignes += $Indentation + $courante }
    return $lignes
}

#endregion

#region ----------------------------------------------------- Couche d'acces Redfish

function Connect-RedfishService {
    <#
        Ouvre une session Redfish. Le jeton retourne est utilise pour les
        requetes suivantes, evitant de retransmettre les identifiants a chaque
        appel. En l'absence d'identifiants, le service est interroge en anonyme
        (cas d'un service simule).
    #>
    param([string]$BaseUri, [pscredential]$Credential)

    if (-not $Credential) {
        Write-Etape "Aucun identifiant fourni : interrogation anonyme."
        return
    }

    $corps = @{
        UserName = $Credential.UserName
        Password = $Credential.GetNetworkCredential().Password
    } | ConvertTo-Json

    $parametres = @{
        Uri         = "$BaseUri/redfish/v1/SessionService/Sessions"
        Method      = 'POST'
        Body        = $corps
        ContentType = 'application/json'
    }
    if ($SkipCertificateCheck) { $parametres.SkipCertificateCheck = $true }

    try {
        $reponse = Invoke-WebRequest @parametres
        $script:Session.Token    = $reponse.Headers['X-Auth-Token']
        $script:Session.Location = $reponse.Headers['Location']
        Write-Etape "Session ouverte."
    }
    catch {
        throw "Ouverture de session impossible : $($_.Exception.Message)"
    }
    finally {
        # Le mot de passe ne subsiste pas en memoire au-dela du strict necessaire.
        $corps = $null
        [System.GC]::Collect()
    }
}

function Disconnect-RedfishService {
    param([string]$BaseUri)
    if (-not $script:Session.Location) { return }
    try {
        $parametres = @{
            Uri     = "$BaseUri$($script:Session.Location)"
            Method  = 'DELETE'
            Headers = @{ 'X-Auth-Token' = $script:Session.Token }
        }
        if ($SkipCertificateCheck) { $parametres.SkipCertificateCheck = $true }
        Invoke-RestMethod @parametres | Out-Null
        Write-Etape "Session fermee."
    }
    catch {
        Write-Warning "Fermeture de session : $($_.Exception.Message)"
    }
}

function Get-RedfishResource {
    <#
        Recupere une ressource Redfish. Renvoie $null en cas d'echec plutot que
        de lever une exception : une ressource inaccessible doit produire un
        statut "non verifiable" et non interrompre l'ensemble du controle.
    #>
    param([string]$BaseUri, [string]$Path)

    $parametres = @{
        Uri    = "$BaseUri$Path"
        Method = 'GET'
    }
    if ($script:Session.Token) {
        $parametres.Headers = @{ 'X-Auth-Token' = $script:Session.Token }
    }
    elseif ($Credential) {
        $parametres.Authentication = 'Basic'
        $parametres.Credential     = $Credential
    }
    if ($SkipCertificateCheck) { $parametres.SkipCertificateCheck = $true }

    try {
        return Invoke-RestMethod @parametres
    }
    catch {
        Write-Warning "Ressource inaccessible [$Path] : $($_.Exception.Message)"
        return $null
    }
}

function Get-RedfishCollection {
    <#
        Parcourt une collection Redfish et retourne chacun de ses membres.
        Les collections suivent toutes la meme forme : un tableau Members
        contenant des references @odata.id.
    #>
    param([string]$BaseUri, [string]$CollectionPath)

    $collection = Get-RedfishResource -BaseUri $BaseUri -Path $CollectionPath
    if (-not $collection -or -not $collection.PSObject.Properties['Members']) { return @() }

    $membres = @()
    foreach ($reference in $collection.Members) {
        $membre = Get-RedfishResource -BaseUri $BaseUri -Path $reference.'@odata.id'
        if ($membre) { $membres += $membre }
    }
    return ,$membres
}

#endregion

#region ----------------------------------------------------- Collecte

function Get-InventaireMateriel {
    param([string]$BaseUri)

    Write-Etape "Relevé de l'inventaire materiel..."

    $chassis = Get-RedfishCollection -BaseUri $BaseUri -CollectionPath '/redfish/v1/Chassis'
    $systemes = Get-RedfishCollection -BaseUri $BaseUri -CollectionPath '/redfish/v1/Systems'
    $managers = Get-RedfishCollection -BaseUri $BaseUri -CollectionPath '/redfish/v1/Managers'

    return [pscustomobject]@{
        Chassis = @($chassis | ForEach-Object {
            [pscustomobject]@{
                Id           = $_.Id
                Modele       = if ($_.PSObject.Properties['Model']) { $_.Model } else { 'n/c' }
                NumeroSerie  = if ($_.PSObject.Properties['SerialNumber']) { $_.SerialNumber } else { 'n/c' }
                Sante        = if ($_.PSObject.Properties['Status']) { $_.Status.Health } else { 'n/c' }
            }
        })
        ModulesCalcul = @($systemes | ForEach-Object {
            [pscustomobject]@{
                Id           = $_.Id
                Modele       = if ($_.PSObject.Properties['Model']) { $_.Model } else { 'n/c' }
                NumeroSerie  = if ($_.PSObject.Properties['SerialNumber']) { $_.SerialNumber } else { 'n/c' }
                VersionBios  = if ($_.PSObject.Properties['BiosVersion']) { $_.BiosVersion } else { 'n/c' }
                Alimentation = if ($_.PSObject.Properties['PowerState']) { $_.PowerState } else { 'n/c' }
                Sante        = if ($_.PSObject.Properties['Status']) { $_.Status.Health } else { 'n/c' }
            }
        })
        Managers = @($managers | ForEach-Object {
            [pscustomobject]@{
                Id      = $_.Id
                Modele  = if ($_.PSObject.Properties['Model']) { $_.Model } else { 'n/c' }
                Version = if ($_.PSObject.Properties['FirmwareVersion']) { $_.FirmwareVersion } else { 'n/c' }
                Sante   = if ($_.PSObject.Properties['Status']) { $_.Status.Health } else { 'n/c' }
            }
        })
    }
}

function Get-InventaireFirmware {
    param([string]$BaseUri)

    Write-Etape "Relevé des versions de firmware..."

    $service = Get-RedfishResource -BaseUri $BaseUri -Path '/redfish/v1/UpdateService'
    if (-not $service -or -not $service.PSObject.Properties['FirmwareInventory']) {
        Write-Warning "Inventaire firmware indisponible sur ce service."
        return @()
    }

    $membres = Get-RedfishCollection -BaseUri $BaseUri `
                                     -CollectionPath $service.FirmwareInventory.'@odata.id'

    return @($membres | ForEach-Object {
        [pscustomobject]@{
            Id      = $_.Id
            Nom     = if ($_.PSObject.Properties['Name']) { $_.Name } else { $_.Id }
            Version = if ($_.PSObject.Properties['Version']) { $_.Version } else { $null }
            Sante   = if ($_.PSObject.Properties['Status']) { $_.Status.Health } else { 'n/c' }
        }
    })
}

#endregion

#region ----------------------------------------------------- Analyse

function Test-ConformiteFirmware {
    <#
        Confronte les versions relevees a la baseline cible.
        Une version superieure a la cible est consideree conforme : la baseline
        exprime un minimum requis, non une valeur exacte.
    #>
    param($InventaireFirmware, $Baseline)

    Write-Etape "Analyse de conformite..."
    $resultats = @()

    foreach ($composant in $Baseline.composants) {
        # Rapprochement par expression reguliere : les libelles de composants
        # varient d'un equipement et d'un constructeur a l'autre. Le motif est
        # declare dans la baseline, ce qui permet d'adapter le rapprochement
        # sans modifier le code.
        $releve = $InventaireFirmware | Where-Object {
            $_.Nom -match $composant.motif -or $_.Id -match $composant.motif
        } | Select-Object -First 1

        if (-not $releve -or -not $releve.Version) {
            $resultats += [pscustomobject]@{
                Composant       = $composant.libelle
                VersionRelevee  = 'n/c'
                VersionCible    = $composant.version_cible
                Statut          = $script:NON_VERIFIABLE
                Critique        = $composant.critique
                Commentaire     = 'Composant absent de l inventaire ou version non exposee'
            }
            continue
        }

        $ecart = Compare-Version $releve.Version $composant.version_cible
        $resultats += [pscustomobject]@{
            Composant      = $composant.libelle
            VersionRelevee = $releve.Version
            VersionCible   = $composant.version_cible
            Statut         = if ($ecart -ge 0) { $script:CONFORME } else { $script:NON_CONFORME }
            Critique       = $composant.critique
            # L'etat de sante releve est conserve dans le resultat : un composant
            # peut etre a la bonne version et signaler une alerte materielle. Les
            # deux informations sont distinctes et doivent le rester.
            Sante          = $releve.Sante
            Commentaire    = if ($ecart -lt 0) { 'Mise a niveau requise' }
                             elseif ($ecart -gt 0) { 'Version superieure a la cible' }
                             else { '' }
        }
    }
    return ,$resultats
}

function Get-AlertesSante {
    <#
        Recense les composants dont l'etat de sante n'est pas nominal, toutes
        familles confondues. Un composant a la bonne version mais en alerte est
        un motif de report d'intervention au meme titre qu'un ecart de version :
        le releve de conformite seul ne le ferait pas apparaitre.
    #>
    param($Inventaire, $InventaireFirmware)

    Write-Etape "Relevé des alertes materielles..."
    $alertes = @()

    $familles = @(
        @{ Famille = 'Chassis';           Elements = $Inventaire.Chassis }
        @{ Famille = 'Module de calcul';  Elements = $Inventaire.ModulesCalcul }
        @{ Famille = 'Controleur';        Elements = $Inventaire.Managers }
        @{ Famille = 'Firmware';          Elements = $InventaireFirmware }
    )

    foreach ($famille in $familles) {
        foreach ($element in @($famille.Elements)) {
            $sante = $element.Sante
            if ([string]::IsNullOrEmpty($sante) -or $sante -eq 'n/c') {
                $alertes += [pscustomobject]@{
                    Famille = $famille.Famille
                    Element = if ($element.PSObject.Properties['Nom']) { $element.Nom } else { $element.Id }
                    Sante   = 'n/c'
                    Statut  = $script:NON_VERIFIABLE
                }
            }
            elseif ($sante -ne 'OK') {
                $alertes += [pscustomobject]@{
                    Famille = $famille.Famille
                    Element = if ($element.PSObject.Properties['Nom']) { $element.Nom } else { $element.Id }
                    Sante   = $sante
                    Statut  = $script:NON_CONFORME
                }
            }
        }
    }
    return ,$alertes
}

function Test-ConformiteNomenclature {
    <#
        Rapproche le materiel decouvert de la nomenclature attendue.
        Remplace le rapprochement manuel des numeros de serie constate sur site.
    #>
    param($Inventaire, $InventaireFirmware, $Baseline)

    if (-not $Baseline.PSObject.Properties['nomenclature_attendue']) { return @() }
    $attendu = $Baseline.nomenclature_attendue

    # Les modules d'interconnexion ne sont exposes ni comme Chassis ni comme
    # Systems : ils sont denombres a partir des entrees d'inventaire firmware
    # rapprochees par le motif declare dans la baseline. Ce rapprochement est
    # indirect et assume comme tel.
    $motifInterconnexion = ($Baseline.composants | Where-Object { $_.cle -eq 'VirtualConnect' }).motif
    $nbInterconnexion = @($InventaireFirmware | Where-Object {
        $motifInterconnexion -and ($_.Nom -match $motifInterconnexion -or $_.Id -match $motifInterconnexion)
    }).Count

    $controles = @(
        @{ Libelle = 'Chassis';                 Attendu = $attendu.chassis;                 Constate = $Inventaire.Chassis.Count }
        @{ Libelle = 'Modules de calcul';       Attendu = $attendu.modules_calcul;          Constate = $Inventaire.ModulesCalcul.Count }
        @{ Libelle = 'Modules interconnexion';  Attendu = $attendu.modules_interconnexion;  Constate = $nbInterconnexion }
    )

    return @($controles | ForEach-Object {
        [pscustomobject]@{
            Element  = $_.Libelle
            Attendu  = $_.Attendu
            Constate = $_.Constate
            Statut   = if ($_.Constate -eq $_.Attendu) { $script:CONFORME }
                       elseif ($_.Constate -eq 0)      { $script:NON_VERIFIABLE }
                       else                            { $script:NON_CONFORME }
        }
    })
}

function Get-SequenceMiseANiveau {
    <#
        Determine la sequence de mise a niveau du Composer et rappelle l'ordre
        impose pour les composants d'infrastructure partagee.
    #>
    param($InventaireFirmware, $Baseline)

    # Le composant Composer est identifie par le motif declare dans la baseline,
    # et non par une chaine codee en dur : meme principe d'externalisation que
    # pour le rapprochement de conformite, et meme rapprochement sur Nom et Id.
    $composer = $Baseline.composants | Where-Object { $_.cle -eq 'Composer' } | Select-Object -First 1
    $composerCible = $composer.version_cible
    $composerReleve = ($InventaireFirmware | Where-Object {
                           $_.Nom -match $composer.motif -or $_.Id -match $composer.motif
                       } | Select-Object -First 1).Version

    if (-not $composerReleve) {
        return [pscustomobject]@{
            Statut = $script:NON_VERIFIABLE
            Etapes = @()
            Message = 'Version du Composer non relevee : sequence indeterminable.'
        }
    }

    # Conversion de l'objet JSON en table de hachage exploitable.
    $chemins = @{}
    foreach ($propriete in $Baseline.chemins_composer.PSObject.Properties) {
        if ($propriete.Name -eq 'commentaire') { continue }
        $chemins[$propriete.Name] = @($propriete.Value)
    }

    $sequence = Resolve-UpgradePath -VersionInstallee $composerReleve `
                                    -VersionCible $composerCible `
                                    -Chemins $chemins

    if ($null -eq $sequence) {
        return [pscustomobject]@{
            Statut  = $script:NON_CONFORME
            Etapes  = @()
            Message = "Aucun chemin de mise a niveau connu depuis la version $composerReleve " +
                      "vers $composerCible. Consulter la table des chemins constructeur avant intervention."
        }
    }
    if ($sequence.Count -eq 0) {
        return [pscustomobject]@{
            Statut  = $script:CONFORME
            Etapes  = @()
            Message = "Le Composer est deja en version cible ($composerCible)."
        }
    }

    return [pscustomobject]@{
        Statut  = $script:NON_CONFORME
        Etapes  = $sequence
        Message = "Sequence requise depuis $composerReleve : " + ($sequence -join ' puis ') +
                  ". L'infrastructure partagee (Frame Link Modules, modules d'interconnexion) " +
                  "doit etre mise a niveau apres le Composer, avant les modules de calcul."
    }
}

#endregion

#region ----------------------------------------------------- Restitution

function Write-RapportConsole {
    param($Rapport)

    $ligne = '-' * 62
    Write-Host ""
    Write-Host $ligne
    Write-Host " RAPPORT DE PRE-CHECK D'INTERVENTION"
    Write-Host " Cible   : $($Rapport.Cible)"
    Write-Host " Date    : $($Rapport.Date)"
    Write-Host " Baseline: $($Rapport.Baseline)"
    Write-Host $ligne

    Write-Host "`n NOMENCLATURE"
    foreach ($controle in $Rapport.Nomenclature) {
        $couleur = switch ($controle.Statut) {
            $script:CONFORME       { 'Green' }
            $script:NON_CONFORME   { 'Red' }
            default                { 'Yellow' }
        }
        Write-Host ("  {0,-22} attendu {1,-4} constate {2,-4} {3}" -f `
            $controle.Element, $controle.Attendu, $controle.Constate, $controle.Statut) -ForegroundColor $couleur
    }

    Write-Host "`n CONFORMITE FIRMWARE"
    foreach ($resultat in $Rapport.Firmware) {
        $couleur = switch ($resultat.Statut) {
            $script:CONFORME       { 'Green' }
            $script:NON_CONFORME   { if ($resultat.Critique) { 'Red' } else { 'DarkYellow' } }
            default                { 'Yellow' }
        }
        Write-Host ("  {0,-32} {1,-10} -> {2,-10} {3}" -f `
            $resultat.Composant, $resultat.VersionRelevee, $resultat.VersionCible, $resultat.Statut) -ForegroundColor $couleur
    }

    Write-Host "`n ETAT DE SANTE"
    if (@($Rapport.Alertes).Count -eq 0) {
        Write-Host "  Aucune alerte materielle relevee" -ForegroundColor Green
    }
    else {
        foreach ($alerte in $Rapport.Alertes) {
            $couleur = if ($alerte.Statut -eq $script:NON_VERIFIABLE) { 'Yellow' } else { 'Red' }
            Write-Host ("  {0,-18} {1,-32} {2}" -f `
                $alerte.Famille, $alerte.Element, $alerte.Sante) -ForegroundColor $couleur
        }
    }

    Write-Host "`n SEQUENCE DE MISE A NIVEAU"
    foreach ($ligneSequence in (Format-Paragraphe -Texte $Rapport.Sequence.Message -Largeur 68)) {
        Write-Host $ligneSequence
    }

    Write-Host "`n SYNTHESE"
    Write-Host ("  Conforme       : {0}" -f $Rapport.Synthese.Conforme)      -ForegroundColor Green
    Write-Host ("  Non conforme   : {0}" -f $Rapport.Synthese.NonConforme)   -ForegroundColor Red
    Write-Host ("  Non verifiable : {0}" -f $Rapport.Synthese.NonVerifiable) -ForegroundColor Yellow
    Write-Host ""
    Write-Host " DECISION : $($Rapport.Decision)" -ForegroundColor $(
        if ($Rapport.Decision -like 'PRET*') { 'Green' } else { 'Red' })
    Write-Host $ligne
    Write-Host ""
}

function Export-Rapport {
    param($Rapport, [string]$Destination)

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $horodatage = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = Join-Path $Destination "precheck-$horodatage"

    # Format JSON : exploitable par un traitement ulterieur, constitue la trace
    # horodatee qui manquait a la phase de preparation.
    $Rapport | ConvertTo-Json -Depth 6 | Set-Content -Path "$base.json" -Encoding UTF8

    # Format CSV : consolidation de plusieurs pre-checks pour le suivi d'indicateurs.
    $Rapport.Firmware | Export-Csv -Path "$base.csv" -NoTypeInformation -Encoding UTF8

    Write-Etape "Rapports ecrits : $base.json / .csv"
    return "$base.json"
}

#endregion

#region ----------------------------------------------------- Programme principal

try {
    Write-Host "`nPre-check d'intervention - demarrage" -ForegroundColor Cyan

    $baseline = Get-Content -Path $BaselineFile -Raw | ConvertFrom-Json
    Write-Etape "Baseline chargee : $($baseline.nom) ($($baseline.version))"

    $racine = $RedfishUri.TrimEnd('/')
    Connect-RedfishService -BaseUri $racine -Credential $Credential

    $service = Get-RedfishResource -BaseUri $racine -Path '/redfish/v1'
    if (-not $service) { throw "Service Redfish injoignable a l'adresse $racine" }
    Write-Etape "Service Redfish version $($service.RedfishVersion)"

    $inventaire   = Get-InventaireMateriel -BaseUri $racine
    $firmware     = Get-InventaireFirmware -BaseUri $racine
    $conformite   = Test-ConformiteFirmware -InventaireFirmware $firmware -Baseline $baseline
    $nomenclature = Test-ConformiteNomenclature -Inventaire $inventaire -InventaireFirmware $firmware -Baseline $baseline
    $alertes      = Get-AlertesSante -Inventaire $inventaire -InventaireFirmware $firmware
    $sequence     = Get-SequenceMiseANiveau -InventaireFirmware $firmware -Baseline $baseline

    $tous = @($conformite) + @($nomenclature)
    $synthese = [pscustomobject]@{
        Conforme      = @($tous | Where-Object Statut -eq $script:CONFORME).Count
        NonConforme   = @($tous | Where-Object Statut -eq $script:NON_CONFORME).Count
        NonVerifiable = @($tous | Where-Object Statut -eq $script:NON_VERIFIABLE).Count
    }

    # Un ecart sur un composant critique bloque le declenchement du deplacement.
    $bloquants = @($conformite | Where-Object { $_.Critique -and $_.Statut -eq $script:NON_CONFORME })
    $decision = if ($bloquants.Count -gt 0) {
        "NON PRET - $($bloquants.Count) ecart(s) sur composant critique"
    } elseif ($synthese.NonConforme -gt 0 -or $synthese.NonVerifiable -gt 0 -or $alertes.Count -gt 0) {
        "PRET SOUS RESERVE - points a traiter avant deplacement"
    } else {
        "PRET - aucun ecart detecte"
    }

    $rapport = [pscustomobject]@{
        Cible        = $racine
        Date         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Baseline     = "$($baseline.nom) ($($baseline.version))"
        Inventaire   = $inventaire
        Firmware     = $conformite
        Nomenclature = $nomenclature
        Alertes      = $alertes
        Sequence     = $sequence
        Synthese     = $synthese
        Decision     = $decision
    }

    Write-RapportConsole -Rapport $rapport
    $chemin = Export-Rapport -Rapport $rapport -Destination $OutputPath

    # Code de sortie exploitable par un appel automatise.
    exit $(if ($bloquants.Count -gt 0) { 2 }
           elseif ($synthese.NonConforme -gt 0 -or $synthese.NonVerifiable -gt 0 -or $alertes.Count -gt 0) { 1 }
           else { 0 })
}
catch {
    Write-Error "Echec du pre-check : $($_.Exception.Message)"
    exit 3
}
finally {
    if ($script:Session.Location) {
        Disconnect-RedfishService -BaseUri $RedfishUri.TrimEnd('/')
    }
}

#endregion
