<#
.SYNOPSIS
Script de supervision de la connectivité réseau et des ressources serveur.

.DESCRIPTION
Ce script vérifie la disponibilité (ping) des serveurs listés, collecte l'utilisation du CPU, de la mémoire et de l'espace disque via PowerShell Remoting, compare aux seuils définis, génère un rapport CSV, envoie un email récapitulatif si des seuils sont dépassés ou des serveurs injoignables, et journalise l'exécution.

.NOTES
Auteur  : Groupe de 5 personnes
Version : 1.1 (avec email récapitulatif)
Date    : 2026-03-15
#>

# ------------------------------------------------------------
# Paramètres par défaut (chemins des fichiers de configuration)
# ------------------------------------------------------------
$configPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$serversFile    = Join-Path $configPath "serveurs.csv"          # Liste des serveurs (Name, [IP])
$thresholdsFile = Join-Path $configPath "seuils.csv"            # Seuils (Metric, Warning, Critical)
$smtpFile       = Join-Path $configPath "smtp_config.csv"       # Paramètres SMTP (Server, Port, User, Password)
$recipientsFile = Join-Path $configPath "destinataires.csv"     # Emails (Name, Email)

$reportFile     = Join-Path $configPath "rapport_supervision.csv"
$logFile        = Join-Path $configPath "journal_execution.log"

# ------------------------------------------------------------
# Fonctions utilitaires
# ------------------------------------------------------------

<#
.SYNOPSIS
Écrit un message dans le journal (console + fichier log).
#>
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] $Message"
    # Affichage console
    Write-Host $logEntry
    # Écriture dans le fichier log
    Add-Content -Path $logFile -Value $logEntry
}

<#
.SYNOPSIS
Teste la connectivité réseau d'un serveur par ping.
#>
function Test-ServerConnectivity {
    param([string]$ComputerName)
    try {
        $ping = Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction Stop
        return $ping
    }
    catch {
        Write-Log -Message "Erreur ping pour $ComputerName : $_" -Level "WARNING"
        return $false
    }
}

<#
.SYNOPSIS
Récupère les ressources d'un serveur distant via PowerShell Remoting.
Utilise les commandes qui ont été validées (Get-Counter, Get-CimInstance).
#>
function Get-ServerResources {
    param([string]$ComputerName)
    
    try {
        Write-Log "Collecte des ressources sur $ComputerName..." -Level "DEBUG"
        
        # Création d'une session distante (comme dans le cours)
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        
        $scriptBlock = {
            $result = [PSCustomObject]@{
                CPU    = 0
                Memory = 0
                Disk   = 0
            }
            
            # CPU via Get-Counter
            try {
                $cpuCounter = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $result.CPU = [math]::Round($cpuCounter.CounterSamples.CookedValue, 2)
            }
            catch {
                Write-Warning "CPU indisponible : $_"
            }
            
            # Mémoire via Get-CimInstance
            try {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $total = $os.TotalVisibleMemorySize
                $free  = $os.FreePhysicalMemory
                if ($total -gt 0) {
                    $result.Memory = [math]::Round((($total - $free) / $total) * 100, 2)
                }
            }
            catch {
                Write-Warning "Mémoire indisponible : $_"
            }
            
            # Disque via Get-CimInstance (ou Get-PSDrive en secours)
            try {
                $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
                if ($disk -and $disk.Size -gt 0) {
                    $result.Disk = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 2)
                }
            }
            catch {
                # Fallback sur Get-PSDrive
                try {
                    $drive = Get-PSDrive -Name C -ErrorAction Stop
                    if ($drive -and $drive.Used -ne $null) {
                        $total = $drive.Used + $drive.Free
                        if ($total -gt 0) {
                            $result.Disk = [math]::Round(($drive.Used / $total) * 100, 2)
                        }
                    }
                }
                catch {
                    Write-Warning "Disque indisponible : $_"
                }
            }
            
            return $result
        }
        
        $resources = Invoke-Command -Session $session -ScriptBlock $scriptBlock
        Remove-PSSession $session
        
        Write-Log "Valeurs collectées - CPU:$($resources.CPU)%, MEM:$($resources.Memory)%, DISK:$($resources.Disk)%" -Level "DEBUG"
        return $resources
    }
    catch {
        Write-Log "Échec de la collecte des ressources pour $ComputerName : $_" -Level "ERROR"
        return $null
    }
}

<#
.SYNOPSIS
Envoie un email d'alerte via le serveur SMTP configuré (modèle du cours).
#>
function Send-EmailAlert {
    param(
        [string]$Subject,
        [string]$Body,
        [string[]]$To
    )
    try {
        $smtpConfig = Import-Csv $smtpFile | Select-Object -First 1
        
        $smtpServer = $smtpConfig.Server
        $port       = $smtpConfig.Port
        $user       = $smtpConfig.User
        $pass       = $smtpConfig.Password

        $smtpClient = New-Object Net.Mail.SmtpClient($smtpServer, $port)
        $smtpClient.EnableSsl = $true
        $smtpClient.Credentials = New-Object System.Net.NetworkCredential($user, $pass)

        $mail = New-Object Net.Mail.MailMessage
        $mail.From = $user
        foreach ($addr in $To) {
            $mail.To.Add($addr)
        }
        $mail.Subject = $Subject
        $mail.Body = $Body
        $mail.IsBodyHtml = $false

        $smtpClient.Send($mail)
        Write-Log -Message "Alerte email envoyée à $($To -join ', ')" -Level "INFO"
    }
    catch {
        Write-Log -Message "Erreur lors de l'envoi de l'email : $_" -Level "ERROR"
    }
}

<#
.SYNOPSIS
Vérifie si une valeur dépasse les seuils et retourne le niveau (OK, WARNING, CRITICAL).
#>
function Get-ThresholdLevel {
    param(
        [double]$Value,
        [double]$Warning,
        [double]$Critical
    )
    if ($Value -ge $Critical) { return "CRITICAL" }
    elseif ($Value -ge $Warning) { return "WARNING" }
    else { return "OK" }
}

<#
.SYNOPSIS
Exporte les résultats dans un fichier CSV.
#>
function Export-Report {
    param([array]$Results)
    $Results | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8
    Write-Log -Message "Rapport généré : $reportFile" -Level "INFO"
}

# ------------------------------------------------------------
# Chargement des données d'entrée
# ------------------------------------------------------------
Write-Log "Début de la supervision"

# Vérification de l'existence des fichiers
$requiredFiles = @($serversFile, $thresholdsFile, $smtpFile, $recipientsFile)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path $file)) {
        Write-Log "Fichier manquant : $file" -Level "ERROR"
        exit 1
    }
}

# Import des listes
$servers    = Import-Csv $serversFile      # Colonnes : Name (et éventuellement IP)
$thresholds = Import-Csv $thresholdsFile   # Colonnes : Metric, Warning, Critical
$recipients = Import-Csv $recipientsFile   # Colonnes : Name, Email

Write-Log "$($servers.Count) serveurs chargés" -Level "INFO"
Write-Log "$($thresholds.Count) seuils chargés" -Level "INFO"
Write-Log "$($recipients.Count) destinataires chargés" -Level "INFO"

# Construction d'une table de seuils pour un accès facile
$thresholdTable = @{}
foreach ($t in $thresholds) {
    $thresholdTable[$t.Metric] = @{
        Warning  = [double]$t.Warning
        Critical = [double]$t.Critical
    }
}

# Vérification que les seuils requis sont présents
$requiredMetrics = @("CPU", "Memory", "Disk")
foreach ($metric in $requiredMetrics) {
    if (-not $thresholdTable.ContainsKey($metric)) {
        Write-Log "Seuil manquant pour $metric dans $thresholdsFile" -Level "ERROR"
        exit 1
    }
}

# ------------------------------------------------------------
# Boucle principale de supervision
# ------------------------------------------------------------
$results = @()
$globalAlertMessages = @()  # Pour accumuler les messages d'alerte

foreach ($server in $servers) {
    # Utilisation du nom (ou IP si fournie)
    $computerName = if ($server.IP) { $server.IP } else { $server.Name }
    Write-Log "Traitement du serveur : $computerName"

    # 1. Test de connectivité
    $pingOk = Test-ServerConnectivity -ComputerName $computerName
    $status = if ($pingOk) { "OK" } else { "INJOIGNABLE" }

    # Initialisation des métriques
    $cpu = $mem = $disk = $null
    $cpuLevel = $memLevel = $diskLevel = "N/A"

    if ($pingOk) {
        # 2. Collecte des ressources
        $resources = Get-ServerResources -ComputerName $computerName
        
        if ($resources) {
            $cpu  = $resources.CPU
            $mem  = $resources.Memory
            $disk = $resources.Disk

            # 3. Comparaison aux seuils
            $cpuLevel  = Get-ThresholdLevel -Value $cpu  -Warning $thresholdTable["CPU"].Warning  -Critical $thresholdTable["CPU"].Critical
            $memLevel  = Get-ThresholdLevel -Value $mem  -Warning $thresholdTable["Memory"].Warning -Critical $thresholdTable["Memory"].Critical
            $diskLevel = Get-ThresholdLevel -Value $disk -Warning $thresholdTable["Disk"].Warning  -Critical $thresholdTable["Disk"].Critical
        }
        else {
            $status = "ERREUR_COLLECTE"
            Write-Log "Échec de collecte des ressources pour $computerName" -Level "WARNING"
        }
    }

    # 4. Stockage du résultat
    $result = [PSCustomObject]@{
        Server        = $computerName
        Status        = $status
        CPU           = if ($cpu -ne $null) { "$cpu%" } else { "-" }
        Memory        = if ($mem -ne $null) { "$mem%" } else { "-" }
        Disk          = if ($disk -ne $null) { "$disk%" } else { "-" }
        CPU_Level     = $cpuLevel
        Memory_Level  = $memLevel
        Disk_Level    = $diskLevel
        Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    $results += $result

    # 5. Collecte des messages d'alerte pour ce serveur
    $serverAlertMessages = @()
    if ($status -eq "INJOIGNABLE") {
        $serverAlertMessages += "❌ Serveur $computerName injoignable (ping)."
    }
    elseif ($status -eq "ERREUR_COLLECTE") {
        $serverAlertMessages += "❌ Impossible de collecter les ressources sur $computerName."
    }
    else {
        if ($cpuLevel -eq "CRITICAL")  { $serverAlertMessages += "🚨 CPU CRITIQUE sur $computerName : $cpu% (seuil critique : $($thresholdTable['CPU'].Critical)%)" }
        if ($cpuLevel -eq "WARNING")   { $serverAlertMessages += "⚠️ CPU en WARNING sur $computerName : $cpu% (seuil avertissement : $($thresholdTable['CPU'].Warning)%)" }
        if ($memLevel -eq "CRITICAL")  { $serverAlertMessages += "🚨 Mémoire CRITIQUE sur $computerName : $mem% (seuil critique : $($thresholdTable['Memory'].Critical)%)" }
        if ($memLevel -eq "WARNING")   { $serverAlertMessages += "⚠️ Mémoire en WARNING sur $computerName : $mem% (seuil avertissement : $($thresholdTable['Memory'].Warning)%)" }
        if ($diskLevel -eq "CRITICAL") { $serverAlertMessages += "🚨 Disque CRITIQUE sur $computerName : $disk% (seuil critique : $($thresholdTable['Disk'].Critical)%)" }
        if ($diskLevel -eq "WARNING")  { $serverAlertMessages += "⚠️ Disque en WARNING sur $computerName : $disk% (seuil avertissement : $($thresholdTable['Disk'].Warning)%)" }
    }

    # Ajouter les messages de ce serveur au global
    if ($serverAlertMessages.Count -gt 0) {
        $globalAlertMessages += $serverAlertMessages
    }
}

# ------------------------------------------------------------
# Envoi d'un email récapitulatif si des alertes ont été générées
# ------------------------------------------------------------
if ($globalAlertMessages.Count -gt 0) {
    $subject = "ALERTE Supervision - Récapitulatif du $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $body = "Rapport de supervision du $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')`r`n"
    $body += "=" * 50 + "`r`n"
    $body += ($globalAlertMessages -join "`r`n`r`n")
    $body += "`r`n" + "=" * 50 + "`r`n"
    $body += "Nombre total de serveurs supervisés : $($results.Count)`r`n"
    $okCount = ($results | Where-Object { $_.Status -eq "OK" }).Count
    $body += "Serveurs OK : $okCount`r`n"
    $body += "Serveurs avec alertes : $($globalAlertMessages.Count)`r`n"
    
    Send-EmailAlert -Subject $subject -Body $body -To $recipients.Email
}
else {
    Write-Log "Aucune alerte détectée, pas d'envoi d'email." -Level "INFO"
}

# ------------------------------------------------------------
# Génération du rapport final
# ------------------------------------------------------------
Export-Report -Results $results

$totalCount = $results.Count
Write-Log "Supervision terminée - $okCount serveurs OK sur $totalCount"
