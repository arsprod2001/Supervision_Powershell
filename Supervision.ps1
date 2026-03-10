<#
.SYNOPSIS
Script de supervision de la connectivité réseau et des ressources serveur.

.DESCRIPTION
Ce script vérifie la disponibilité (ping) des serveurs listés, collecte l'utilisation du CPU, de la mémoire et de l'espace disque via PowerShell Remoting, compare aux seuils définis, génère un rapport CSV, envoie des alertes par email et journalise l'exécution.

.NOTES
Auteur  : Groupe de 5 personnes
Version : 1.0
Date    : $(Get-Date -Format 'dd/MM/yyyy')
#>

# ------------------------------------------------------------
# Paramètres par défaut (chemins des fichiers de configuration)
# ------------------------------------------------------------
$configPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$serversFile    = Join-Path $configPath "serveurs.csv"          # Liste des serveurs (Name, IP)
$thresholdsFile = Join-Path $configPath "seuils.csv"            # Seuils par défaut (Metric, Warning, Critical)
$smtpFile       = Join-Path $configPath "smtp_config.csv"       # Paramètres SMTP (Server, Port, User, Password)
$recipientsFile = Join-Path $configPath "destinataires.csv"     # Emails des destinataires (Name, Email)

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
Retourne un objet avec CPU, Mémoire, Disque.
#>
function Get-ServerResources {
    param([string]$ComputerName)
    $resources = $null
    try {
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        $scriptBlock = {
            # CPU : charge moyenne sur 5 secondes (pourcentage)
            $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue
            # Mémoire : pourcentage d'utilisation
            $mem = Get-WmiObject -Class Win32_OperatingSystem
            $memUsed = ($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize * 100
            # Disque : pourcentage d'utilisation du volume système (C:)
            $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'"
            $diskUsed = 100 - ($disk.FreeSpace / $disk.Size * 100)
            [PSCustomObject]@{
                CPU    = [math]::Round($cpu, 2)
                Memory = [math]::Round($memUsed, 2)
                Disk   = [math]::Round($diskUsed, 2)
            }
        }
        $resources = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ErrorAction Stop
        Remove-PSSession $session
    }
    catch {
        Write-Log -Message "Échec de la collecte des ressources pour $ComputerName : $_" -Level "ERROR"
    }
    return $resources
}

<#
.SYNOPSIS
Envoie un email d'alerte via le serveur SMTP configuré.
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

        $smtp = New-Object Net.Mail.SmtpClient($smtpServer, $port)
        $smtp.EnableSsl = $true
        $smtp.Credentials = New-Object System.Net.NetworkCredential($user, $pass)

        $mail = New-Object Net.Mail.MailMessage
        $mail.From = $user
        foreach ($addr in $To) { $mail.To.Add($addr) }
        $mail.Subject = $Subject
        $mail.Body = $Body
        $mail.IsBodyHtml = $false

        $smtp.Send($mail)
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
$servers      = Import-Csv $serversFile      # Colonnes : Name, IP (ou Name seul si DNS)
$thresholds   = Import-Csv $thresholdsFile   # Colonnes : Metric, Warning, Critical
$recipients   = Import-Csv $recipientsFile   # Colonnes : Name, Email
$smtpSettings = Import-Csv $smtpFile | Select-Object -First 1

# Construire une table de seuils pour un accès facile
$thresholdTable = @{}
foreach ($t in $thresholds) {
    $thresholdTable[$t.Metric] = @{
        Warning  = [double]$t.Warning
        Critical = [double]$t.Critical
    }
}

# ------------------------------------------------------------
# Boucle principale de supervision
# ------------------------------------------------------------
$results = @()
$alertRecipients = $recipients.Email -join ';'  # pour envoi groupé

foreach ($server in $servers) {
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

    # 5. Alerte si dépassement critique ou injoignable
    $alertMessages = @()
    if ($status -eq "INJOIGNABLE") {
        $alertMessages += "Serveur $computerName injoignable (ping)."
    }
    elseif ($status -eq "ERREUR_COLLECTE") {
        $alertMessages += "Impossible de collecter les ressources sur $computerName."
    }
    else {
        if ($cpuLevel -eq "CRITICAL")  { $alertMessages += "CPU critique sur $computerName : $cpu%" }
        if ($memLevel -eq "CRITICAL")  { $alertMessages += "Mémoire critique sur $computerName : $mem%" }
        if ($diskLevel -eq "CRITICAL") { $alertMessages += "Disque critique sur $computerName : $disk%" }
        # On pourrait aussi alerter en WARNING, selon les besoins
    }

    if ($alertMessages.Count -gt 0) {
        $subject = "ALERTE Supervision - $computerName"
        $body = "Des anomalies ont été détectées :`r`n" + ($alertMessages -join "`r`n")
        Send-EmailAlert -Subject $subject -Body $body -To $recipients.Email
    }
}

# ------------------------------------------------------------
# Génération du rapport final
# ------------------------------------------------------------
Export-Report -Results $results

Write-Log "Supervision terminée"