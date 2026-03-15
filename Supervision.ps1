# ------------------------------------------------------------
# Paramètres par défaut (chemins des fichiers de configuration)
# ------------------------------------------------------------
$cheminScript = Split-Path -Parent $MyInvocation.MyCommand.Path
$fichierServeurs    = Join-Path $cheminScript "serveurs.csv"         
$fichierSeuils      = Join-Path $cheminScript "seuils.csv"            
$fichierSmtp        = Join-Path $cheminScript "smtp_config.csv"      
$fichierDestinataires = Join-Path $cheminScript "destinataires.csv"  
$fichierRapport     = Join-Path $cheminScript "rapport_supervision.csv"
$fichierJournal     = Join-Path $cheminScript "journal_execution.log"

# ------------------------------------------------------------
# Fonctions utilitaires 
# ------------------------------------------------------------

<#
.SYNOPSIS
Écrit un message dans le journal (console + fichier log).
#>
function Ecrire-Journal {
    param(
        [string]$Message,
        [string]$Niveau = "INFO"
    )
    $horodatage = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entreeJournal = "$horodatage [$Niveau] $Message"
    # Affichage console
    Write-Host $entreeJournal
    # Écriture dans le fichier log
    Add-Content -Path $fichierJournal -Value $entreeJournal
}

<#
.SYNOPSIS
Teste la connectivité réseau d'un serveur par ping.
#>
function Tester-Connexion {
    param([string]$NomOrdinateur)
    try {
        $ping = Test-Connection -ComputerName $NomOrdinateur -Count 1 -Quiet -ErrorAction Stop
        return $ping
    }
    catch {
        Ecrire-Journal -Message "Erreur ping pour $NomOrdinateur : $_" -Niveau "WARNING"
        return $false
    }
}

<#
.SYNOPSIS
Récupère les ressources d'un serveur distant via PowerShell Remoting.
#>
function Obtenir-Ressources {
    param([string]$NomOrdinateur)
    
    try {
        Ecrire-Journal "Collecte des ressources sur $NomOrdinateur..." -Niveau "DEBUG"
        
        # Création d'une session distante
        $session = New-PSSession -ComputerName $NomOrdinateur -ErrorAction Stop
        
        $scriptBlock = {
            $resultat = [PSCustomObject]@{
                CPU    = 0
                Memoire = 0
                Disque  = 0
            }
            
            # CPU via Get-Counter
            try {
                $compteurCPU = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $resultat.CPU = [math]::Round($compteurCPU.CounterSamples.CookedValue, 2)
            }
            catch {
                Write-Warning "CPU indisponible : $_"
            }
            
            # Mémoire via Get-CimInstance
            try {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $total = $os.TotalVisibleMemorySize
                $libre  = $os.FreePhysicalMemory
                if ($total -gt 0) {
                    $resultat.Memoire = [math]::Round((($total - $libre) / $total) * 100, 2)
                }
            }
            catch {
                Write-Warning "Mémoire indisponible : $_"
            }
            
            # Disque via Get-CimInstance (ou Get-PSDrive en secours)
            try {
                $disque = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
                if ($disque -and $disque.Size -gt 0) {
                    $resultat.Disque = [math]::Round((($disque.Size - $disque.FreeSpace) / $disque.Size) * 100, 2)
                }
            }
            catch {
                # Fallback sur Get-PSDrive
                try {
                    $lecteur = Get-PSDrive -Name C -ErrorAction Stop
                    if ($lecteur -and $lecteur.Used -ne $null) {
                        $total = $lecteur.Used + $lecteur.Free
                        if ($total -gt 0) {
                            $resultat.Disque = [math]::Round(($lecteur.Used / $total) * 100, 2)
                        }
                    }
                }
                catch {
                    Write-Warning "Disque indisponible : $_"
                }
            }
            
            return $resultat
        }
        
        $ressources = Invoke-Command -Session $session -ScriptBlock $scriptBlock
        Remove-PSSession $session
        
        Ecrire-Journal "Valeurs collectées - CPU:$($ressources.CPU)%, MEM:$($ressources.Memoire)%, DISK:$($ressources.Disque)%" -Niveau "DEBUG"
        return $ressources
    }
    catch {
        Ecrire-Journal "Échec de la collecte des ressources pour $NomOrdinateur : $_" -Niveau "ERROR"
        return $null
    }
}

<#
.SYNOPSIS
Envoie un email d'alerte via le serveur SMTP configuré.
#>
function Envoyer-AlerteMail {
    param(
        [string]$Sujet,
        [string]$Corps,
        [string[]]$Destinataires
    )
    try {
        $configSmtp = Import-Csv $fichierSmtp | Select-Object -First 1
        
        $serveurSmtp = $configSmtp.Server
        $port        = $configSmtp.Port
        $utilisateur = $configSmtp.User
        $motDePasse  = $configSmtp.Password

        $clientSmtp = New-Object Net.Mail.SmtpClient($serveurSmtp, $port)
        $clientSmtp.EnableSsl = $true
        $clientSmtp.Credentials = New-Object System.Net.NetworkCredential($utilisateur, $motDePasse)

        $message = New-Object Net.Mail.MailMessage
        $message.From = $utilisateur
        foreach ($dest in $Destinataires) {
            $message.To.Add($dest)
        }
        $message.Subject = $Sujet
        $message.Body = $Corps
        $message.IsBodyHtml = $false

        $clientSmtp.Send($message)
        Ecrire-Journal -Message "Alerte email envoyée à $($Destinataires -join ', ')" -Niveau "INFO"
    }
    catch {
        Ecrire-Journal -Message "Erreur lors de l'envoi de l'email : $_" -Niveau "ERROR"
    }
}

<#
.SYNOPSIS
Vérifie si une valeur dépasse les seuils et retourne le niveau (OK, WARNING, CRITICAL).
#>
function Obtenir-NiveauSeuil {
    param(
        [double]$Valeur,
        [double]$SeuilAvertissement,
        [double]$SeuilCritique
    )
    if ($Valeur -ge $SeuilCritique) { return "CRITICAL" }
    elseif ($Valeur -ge $SeuilAvertissement) { return "WARNING" }
    else { return "OK" }
}

<#
.SYNOPSIS
Exporte les résultats dans un fichier CSV.
#>
function Exporter-Rapport {
    param([array]$Resultats)
    $Resultats | Export-Csv -Path $fichierRapport -NoTypeInformation -Encoding UTF8
    Ecrire-Journal -Message "Rapport généré : $fichierRapport" -Niveau "INFO"
}

# ------------------------------------------------------------
# Chargement des données d'entrée
# ------------------------------------------------------------
Ecrire-Journal "Début de la supervision"

# Vérification de l'existence des fichiers
$fichiersRequis = @($fichierServeurs, $fichierSeuils, $fichierSmtp, $fichierDestinataires)
foreach ($fichier in $fichiersRequis) {
    if (-not (Test-Path $fichier)) {
        Ecrire-Journal "Fichier manquant : $fichier" -Niveau "ERROR"
        exit 1
    }
}

# Import des listes
$serveurs    = Import-Csv $fichierServeurs      
$seuils      = Import-Csv $fichierSeuils        
$destinataires = Import-Csv $fichierDestinataires 

Ecrire-Journal "$($serveurs.Count) serveurs chargés" -Niveau "INFO"
Ecrire-Journal "$($seuils.Count) seuils chargés" -Niveau "INFO"
Ecrire-Journal "$($destinataires.Count) destinataires chargés" -Niveau "INFO"

# Construction d'une table de seuils pour un accès facile
$tableSeuils = @{}
foreach ($s in $seuils) {
    $tableSeuils[$s.Metric] = @{
        Avertissement = [double]$s.Warning
        Critique      = [double]$s.Critical
    }
}

# Vérification que les seuils requis sont présents
$metriquesRequises = @("CPU", "Memory", "Disk")
foreach ($metrique in $metriquesRequises) {
    if (-not $tableSeuils.ContainsKey($metrique)) {
        Ecrire-Journal "Seuil manquant pour $metrique dans $fichierSeuils" -Niveau "ERROR"
        exit 1
    }
}

# ------------------------------------------------------------
# Boucle principale de supervision
# ------------------------------------------------------------
$resultats = @()
$alertesParServeur = @{} 

foreach ($serveur in $serveurs) {
    $nomServeur = $serveur.Name
    Ecrire-Journal "Traitement du serveur : $nomServeur"

    # 1. Test de connectivité
    $pingOk = Tester-Connexion -NomOrdinateur $nomServeur
    $statut = if ($pingOk) { "OK" } else { "INJOIGNABLE" }

    # Initialisation des métriques
    $cpu = $memoire = $disque = $null
    $niveauCPU = $niveauMemoire = $niveauDisque = "N/A"

    if ($pingOk) {
        # 2. Collecte des ressources
        $ressources = Obtenir-Ressources -NomOrdinateur $nomServeur
        
        if ($ressources) {
            $cpu      = $ressources.CPU
            $memoire  = $ressources.Memoire
            $disque   = $ressources.Disque

            # 3. Comparaison aux seuils
            $niveauCPU     = Obtenir-NiveauSeuil -Valeur $cpu -SeuilAvertissement $tableSeuils["CPU"].Avertissement -SeuilCritique $tableSeuils["CPU"].Critique
            $niveauMemoire = Obtenir-NiveauSeuil -Valeur $memoire -SeuilAvertissement $tableSeuils["Memory"].Avertissement -SeuilCritique $tableSeuils["Memory"].Critique
            $niveauDisque  = Obtenir-NiveauSeuil -Valeur $disque -SeuilAvertissement $tableSeuils["Disk"].Avertissement -SeuilCritique $tableSeuils["Disk"].Critique
        }
        else {
            $statut = "ERREUR_COLLECTE"
            Ecrire-Journal "Échec de collecte des ressources pour $nomServeur" -Niveau "WARNING"
        }
    }

    # 4. Stockage du résultat
    $resultat = [PSCustomObject]@{
        Serveur        = $nomServeur
        Statut         = $statut
        CPU            = if ($cpu -ne $null) { "$cpu%" } else { "-" }
        Memoire        = if ($memoire -ne $null) { "$memoire%" } else { "-" }
        Disque         = if ($disque -ne $null) { "$disque%" } else { "-" }
        Niveau_CPU     = $niveauCPU
        Niveau_Memoire = $niveauMemoire
        Niveau_Disque  = $niveauDisque
        Horodatage     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    $resultats += $resultat

    # 5. Collecte des messages d'alerte pour ce serveur (sans icônes)
    $messagesServeur = @()
    if ($statut -eq "INJOIGNABLE") {
        $messagesServeur += "Serveur $nomServeur injoignable (ping)."
    }
    elseif ($statut -eq "ERREUR_COLLECTE") {
        $messagesServeur += "Impossible de collecter les ressources sur $nomServeur."
    }
    else {
        if ($niveauCPU -eq "CRITICAL")  { $messagesServeur += "CPU CRITIQUE : $cpu% (seuil critique : $($tableSeuils['CPU'].Critique)%)" }
        if ($niveauCPU -eq "WARNING")   { $messagesServeur += "CPU en WARNING : $cpu% (seuil avertissement : $($tableSeuils['CPU'].Avertissement)%)" }
        if ($niveauMemoire -eq "CRITICAL")  { $messagesServeur += "Mémoire CRITIQUE : $memoire% (seuil critique : $($tableSeuils['Memory'].Critique)%)" }
        if ($niveauMemoire -eq "WARNING")   { $messagesServeur += "Mémoire en WARNING : $memoire% (seuil avertissement : $($tableSeuils['Memory'].Avertissement)%)" }
        if ($niveauDisque -eq "CRITICAL") { $messagesServeur += "Disque CRITIQUE : $disque% (seuil critique : $($tableSeuils['Disk'].Critique)%)" }
        if ($niveauDisque -eq "WARNING")  { $messagesServeur += "Disque en WARNING : $disque% (seuil avertissement : $($tableSeuils['Disk'].Avertissement)%)" }
    }

    # Ajouter les messages de ce serveur au dictionnaire global
    if ($messagesServeur.Count -gt 0) {
        $alertesParServeur[$nomServeur] = $messagesServeur
    }
}

# ------------------------------------------------------------
# Envoi d'un email récapitulatif si des alertes ont été générées
# ------------------------------------------------------------
if ($alertesParServeur.Count -gt 0) {
    $sujet = "ALERTE Supervision - Récapitulatif du $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $corps = "Rapport de supervision du $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')`r`n"
    $corps += "=" * 50 + "`r`n"

    # Tri des serveurs par nom pour un affichage ordonné
    foreach ($nom in ($alertesParServeur.Keys | Sort-Object)) {
        $corps += "Serveur $nom :`r`n"
        foreach ($msg in $alertesParServeur[$nom]) {
            $corps += "  - $msg`r`n"
        }
    }

    $corps += "=" * 50 + "`r`n"
    $corps += "Nombre total de serveurs supervisés : $($resultats.Count)`r`n"
    $nbOK = ($resultats | Where-Object { $_.Statut -eq "OK" }).Count
    $corps += "Serveurs OK : $nbOK`r`n"

    # Calcul du nombre total d'alertes (somme des messages de chaque serveur)
    $nbAlertes = ($alertesParServeur.Values | ForEach-Object { $_.Count }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    $corps += "Serveurs avec alertes : $nbAlertes`r`n"  

    Envoyer-AlerteMail -Sujet $sujet -Corps $corps -Destinataires $destinataires.Email
}
else {
    Ecrire-Journal "Aucune alerte détectée, pas d'envoi d'email." -Niveau "INFO"
}

# ------------------------------------------------------------
# Génération du rapport final
# ------------------------------------------------------------
Exporter-Rapport -Resultats $resultats

$total = $resultats.Count
$nbOK = ($resultats | Where-Object { $_.Statut -eq "OK" }).Count
Ecrire-Journal "Supervision terminée - $nbOK serveurs OK sur $total"
