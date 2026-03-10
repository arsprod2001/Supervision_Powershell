# README — Projet de Supervision Réseau et Serveurs avec PowerShell

> Script de supervision automatisée — Documentation complète

---

## Table des matières

1. [Introduction](#1-introduction)
2. [Objectifs du projet](#2-objectifs-du-projet)
3. [Prérequis techniques](#3-prérequis-techniques)
4. [Architecture du script](#4-architecture-du-script)
5. [Fonctions détaillées](#5-fonctions-détaillées)
   - 5.1 [Write-Log](#51-write-log)
   - 5.2 [Test-ServerConnectivity](#52-test-serverconnectivity)
   - 5.3 [Get-ServerResources](#53-get-serverresources)
   - 5.4 [Send-EmailAlert](#54-send-emailalert)
   - 5.5 [Get-ThresholdLevel](#55-get-thresholdlevel)
   - 5.6 [Export-Report](#56-export-report)
6. [Fichiers de configuration externes](#6-fichiers-de-configuration-externes)
   - 6.1 [serveurs.csv](#61-serveurscsv)
   - 6.2 [seuils.csv](#62-seuilscsv)
   - 6.3 [smtp_config.csv](#63-smtp_configcsv)
   - 6.4 [destinataires.csv](#64-destinatairescsv)
7. [Utilisation du script](#7-utilisation-du-script)
   - 7.1 [Exécution manuelle](#71-exécution-manuelle)
   - 7.2 [Planification avec le Task Scheduler](#72-planification-avec-le-task-scheduler)
8. [Gestion des erreurs et journalisation](#8-gestion-des-erreurs-et-journalisation)
9. [Bonnes pratiques mises en œuvre](#9-bonnes-pratiques-mises-en-œuvre)
10. [Améliorations possibles](#10-améliorations-possibles)
11. [Conclusion](#11-conclusion)

---

## 1. Introduction

Dans le cadre d'un projet de laboratoire, cet outil de supervision permet de surveiller la connectivité réseau et les ressources (CPU, mémoire, disque) d'une liste de serveurs. Le script est modulaire, robuste, et capable d'envoyer des alertes par email en cas de dépassement de seuils ou d'indisponibilité.

Les données d'entrée (liste des serveurs, seuils, paramètres SMTP, destinataires) sont stockées dans des fichiers CSV externes pour une flexibilité maximale. Un journal d'exécution et un rapport CSV sont générés à chaque passage.

---

## 2. Objectifs du projet

- Superviser la connectivité : vérifier par ping si les serveurs sont joignables.
- Collecter les métriques : utilisation CPU, mémoire et espace disque via PowerShell Remoting.
- Comparer aux seuils : définir des niveaux d'alerte (warning, critical) pour chaque métrique.
- Générer un rapport : exporter les résultats dans un fichier CSV.
- Envoyer des alertes email : en cas de serveur injoignable ou de métrique critique.
- Journaliser : tracer toutes les actions et erreurs dans un fichier log.
- Être paramétrable : tous les paramètres sont externalisés dans des CSV.
- Respecter les bonnes pratiques : modularité, gestion d'erreurs, documentation.

---

## 3. Prérequis techniques

### 3.1 PowerShell

- Le script a été développé pour **PowerShell 5.1 ou ultérieur** (PowerShell 7+ fonctionne également).
- Il doit être exécuté sur une machine disposant d'un accès réseau aux serveurs à superviser.

### 3.2 PowerShell Remoting (WinRM)

Pour collecter les ressources des serveurs distants, chaque serveur cible doit avoir PowerShell Remoting activé.

Activez-le sur chaque serveur distant (en tant qu'administrateur) :

```powershell
Enable-PSRemoting -Force
```

Vérifiez que le pare-feu autorise WinRM (ports **5985** HTTP, **5986** HTTPS).

Sur la machine exécutant le script, ajoutez les serveurs aux TrustedHosts si nécessaire :

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.1.10,192.168.1.11" -Force
```

Testez la connexion avec :

```powershell
Test-WsMan
Test-NetConnection -Port 5985
```

### 3.3 Compte SMTP (Gmail recommandé)

Le script utilise un serveur SMTP avec authentification. Pour Gmail :

- Un compte Gmail.
- Un **mot de passe d'application** (si l'authentification à deux facteurs est activée) ou le mot de passe classique.
- Adresse du serveur : `smtp.gmail.com`, port `587`, SSL activé.

### 3.4 Droits d'exécution

- La machine qui lance le script doit avoir les droits pour créer des sessions PowerShell distantes (être dans le groupe « Remote Management Users » sur les cibles, ou administrateur).
- Pour les tests en lab, vous pouvez utiliser des comptes avec privilèges administrateur.

---

## 4. Architecture du script

Le script est structuré en plusieurs parties :

1. **Entête de documentation** (commentaires help)
2. **Définition des chemins** des fichiers de configuration (paramètres par défaut)
3. **Fonctions réutilisables** (log, ping, collecte ressources, email, seuils, export)
4. **Chargement des données d'entrée** (lecture des CSV)
5. **Boucle principale** : pour chaque serveur, on teste la connectivité, collecte les ressources, compare aux seuils, stocke le résultat, et envoie une alerte si nécessaire.
6. **Export du rapport final**
7. **Fin du script**

Cette architecture modulaire facilite la maintenance et l'extension.

---

## 5. Fonctions détaillées

### 5.1 Write-Log

```powershell
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
}
```

**Rôle :** Centraliser l'écriture des messages dans la console et dans un fichier journal.

| Paramètre | Description |
|-----------|-------------|
| `Message` | Le texte à enregistrer. |
| `Level`   | Niveau de gravité : `INFO`, `WARNING`, `ERROR`. Par défaut `INFO`. |

**Fonctionnement :**
- Récupère la date/heure formatée.
- Construit une chaîne `[niveau] message`.
- Affiche à l'écran avec `Write-Host`.
- Ajoute la ligne au fichier log (`$logFile`).

---

### 5.2 Test-ServerConnectivity

```powershell
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
```

**Rôle :** Vérifier si un serveur répond au ping.

- **Paramètre :** `ComputerName` (adresse IP ou nom DNS).
- `Test-Connection` avec un seul paquet (`-Count 1`) et mode silencieux (`-Quiet` retourne `$true` ou `$false`).
- Si une erreur se produit (nom non résolu, timeout), l'exception est capturée, un avertissement est journalisé, et la fonction retourne `$false`.
- **Retour :** booléen.

---

### 5.3 Get-ServerResources

```powershell
function Get-ServerResources {
    param([string]$ComputerName)
    $resources = $null
    try {
        $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
        $scriptBlock = {
            # CPU
            $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' `
                    -SampleInterval 1 -MaxSamples 1).CounterSamples.CookedValue
            # Mémoire
            $mem = Get-WmiObject -Class Win32_OperatingSystem
            $memUsed = ($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) `
                        / $mem.TotalVisibleMemorySize * 100
            # Disque C:
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
```

**Rôle :** Se connecter à un serveur distant via PowerShell Remoting et récupérer les métriques CPU, mémoire, disque.

**Détail des métriques :**

| Métrique | Source | Description |
|----------|--------|-------------|
| CPU      | `\Processor(_Total)\% Processor Time` | % d'utilisation sur 1 seconde d'échantillonnage |
| Memory   | `Win32_OperatingSystem` | % de mémoire utilisée |
| Disk     | `Win32_LogicalDisk` (C:) | % d'espace disque utilisé |

- **Retour :** objet PowerShell avec les propriétés `CPU`, `Memory`, `Disk`, ou `$null` si échec.

---

### 5.4 Send-EmailAlert

```powershell
function Send-EmailAlert {
    param(
        [string]$Subject,
        [string]$Body,
        [string[]]$To
    )
    try {
        $smtpConfig = Import-Csv $smtpFile | Select-Object -First 1
        $smtp = New-Object Net.Mail.SmtpClient($smtpConfig.Server, $smtpConfig.Port)
        $smtp.EnableSsl = $true
        $smtp.Credentials = New-Object System.Net.NetworkCredential(
            $smtpConfig.User, $smtpConfig.Password)
        $mail = New-Object Net.Mail.MailMessage
        $mail.From = $smtpConfig.User
        foreach ($addr in $To) { $mail.To.Add($addr) }
        $mail.Subject = $Subject
        $mail.Body    = $Body
        $smtp.Send($mail)
        Write-Log -Message "Alerte email envoyée à $($To -join ', ')" -Level "INFO"
    }
    catch {
        Write-Log -Message "Erreur lors de l'envoi de l'email : $_" -Level "ERROR"
    }
}
```

**Rôle :** Envoyer un email via le serveur SMTP configuré.

| Paramètre | Description |
|-----------|-------------|
| `Subject` | Objet du message. |
| `Body`    | Corps du message (texte brut). |
| `To`      | Tableau d'adresses email destinataires. |

**Fonctionnement :**
- Lit `smtp_config.csv` pour obtenir les paramètres (serveur, port, identifiants).
- Crée un `SmtpClient` avec SSL activé et les identifiants.
- Construit et envoie un `MailMessage` avec les destinataires.

---

### 5.5 Get-ThresholdLevel

```powershell
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
```

**Rôle :** Comparer une valeur à des seuils et retourner le niveau d'alerte.

| Paramètre  | Description |
|------------|-------------|
| `Value`    | La valeur mesurée (ex: `85.5` pour CPU). |
| `Warning`  | Seuil d'avertissement (ex: `80`). |
| `Critical` | Seuil critique (ex: `90`). |

**Retour :** `"CRITICAL"`, `"WARNING"` ou `"OK"`.

---

### 5.6 Export-Report

```powershell
function Export-Report {
    param([array]$Results)
    $Results | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8
    Write-Log -Message "Rapport généré : $reportFile" -Level "INFO"
}
```

**Rôle :** Exporter la collection de résultats dans un fichier CSV.

- Utilise `Export-Csv` avec `-NoTypeInformation` pour éviter l'en-tête de type.
- Encodage UTF8 pour supporter les accents.
- Journalise la génération du fichier.

---

## 6. Fichiers de configuration externes

Le script lit quatre fichiers CSV situés dans le même répertoire. Le séparateur par défaut est la virgule (`,`). Assurez-vous que ces fichiers existent et sont correctement formatés.

### 6.1 serveurs.csv

Liste des serveurs à superviser.

**Colonnes :** `Name`, `IP`

| Colonne | Description |
|---------|-------------|
| `Name`  | Nom d'hôte ou étiquette (utilisé pour l'affichage). |
| `IP`    | Adresse IP ou nom DNS utilisé pour la connexion. Si vide, le script utilisera `Name`. |

**Exemple :**

```csv
Name,IP
SRV1,192.168.1.10
SRV2,192.168.1.11
SRV3,serveur3.domaine.local
PC1,192.168.1.20
```

---

### 6.2 seuils.csv

Définit les seuils d'alerte pour chaque métrique.

**Colonnes :** `Metric`, `Warning`, `Critical`

| Colonne    | Description |
|------------|-------------|
| `Metric`   | Nom de la métrique : `CPU`, `Memory` ou `Disk`. |
| `Warning`  | Seuil pour le niveau WARNING (en %). |
| `Critical` | Seuil pour le niveau CRITICAL (en %). |

**Exemple :**

```csv
Metric,Warning,Critical
CPU,80,90
Memory,80,90
Disk,85,95
```

---

### 6.3 smtp_config.csv

Paramètres de connexion au serveur SMTP. Un seul serveur est supporté (première ligne lue).

**Colonnes :** `Server`, `Port`, `User`, `Password`

**Exemple :**

```csv
Server,Port,User,Password
smtp.gmail.com,587,votre.email@gmail.com,votre_mot_de_passe
```

> ⚠️ **Sécurité :** Le mot de passe est stocké en clair. Pour un environnement de production, utilisez des variables d'environnement ou un coffre sécurisé (ex: `Export-Clixml`).

---

### 6.4 destinataires.csv

Liste des personnes à alerter par email.

**Colonnes :** `Name`, `Email`

**Exemple :**

```csv
Name,Email
Admin1,admin1@domaine.com
Admin2,admin2@domaine.com
```

---

## 7. Utilisation du script

### 7.1 Exécution manuelle

1. Placez le script PowerShell (`Supervision.ps1`) et les quatre fichiers CSV dans un même dossier.
2. Ouvrez PowerShell **en tant qu'administrateur**.
3. Naviguez vers le dossier :
   ```powershell
   cd C:\chemin\vers\dossier
   ```
4. Exécutez le script :
   ```powershell
   .\Supervision.ps1
   ```

Le journal `journal_execution.log` et le rapport `rapport_supervision.csv` seront créés dans le même dossier.

> **Note :** La première exécution peut être plus lente si les sessions distantes sont établies pour la première fois.

---

### 7.2 Planification avec le Task Scheduler

Pour une supervision automatisée (par exemple toutes les heures) :

1. Ouvrez le **Planificateur de tâches** Windows.
2. Créez une nouvelle tâche.
3. Dans l'onglet **Déclencheur**, définissez la fréquence souhaitée.
4. Dans l'onglet **Actions**, ajoutez une nouvelle action :
   - **Action :** Démarrer un programme
   - **Programme/script :** `powershell.exe`
   - **Arguments :** `-File "C:\chemin\vers\Supervision.ps1" -ExecutionPolicy Bypass`
   - **Démarrer dans :** le répertoire contenant le script (recommandé).
5. Assurez-vous que le compte qui exécute la tâche a les droits suffisants (accès réseau, permissions sur les dossiers).

---

## 8. Gestion des erreurs et journalisation

Le script utilise un mécanisme de `try/catch` à chaque étape critique :

| Étape | Comportement en cas d'erreur |
|-------|------------------------------|
| Ping | Warning loggé, retourne `$false`. |
| Création de session distante | Erreur loggée, retourne `$null`. |
| Exécution des commandes distantes | Erreur capturée et loggée. |
| Envoi d'email | Exception capturée et loggée. |

Le fichier `journal_execution.log` contient une trace horodatée de chaque action. Exemple :

```
2025-03-10 14:30:01 [INFO]    Début de la supervision
2025-03-10 14:30:02 [INFO]    Traitement du serveur : 192.168.1.10
2025-03-10 14:30:03 [INFO]    Alerte email envoyée à admin1@domaine.com
2025-03-10 14:30:05 [ERROR]   Échec de la collecte pour 192.168.1.11 : Connexion refusée
```

---

## 9. Bonnes pratiques mises en œuvre

- **Modularité :** chaque tâche est isolée dans une fonction.
- **Gestion d'erreurs :** utilisation de `try/catch` et messages explicites.
- **Validation des entrées :** vérification de l'existence des fichiers avant lecture.
- **Documentation :** commentaires en français, entête de script avec synopsis et description.
- **Externalisation des paramètres :** tous les réglages sont dans des fichiers CSV, pas de valeurs codées en dur.
- **Performance :** ping unique par serveur, échantillonnage CPU court (1 seconde), fermeture des sessions distantes.
- **Indentation et lisibilité :** code structuré, lignes claires.
- **Journalisation :** suivi des actions et erreurs.

---

## 10. Améliorations possibles

- **Collecte sur plusieurs disques :** interroger tous les disques et appliquer des seuils par disque.
- **Seuils personnalisés par serveur :** permettre des seuils différents par serveur via une colonne dans `serveurs.csv`.
- **Alertes de niveau WARNING :** envoyer des alertes pour les warnings (avec fréquence limitée pour éviter le spam).
- **Fichier de configuration unique :** regrouper tous les paramètres dans un fichier JSON ou XML.
- **Chiffrement du mot de passe SMTP :** utiliser `Export-Clixml` pour stocker les identifiants de manière sécurisée.
- **Support de plusieurs serveurs SMTP** (fallback).
- **Rapport HTML :** générer un rapport plus lisible avec mise en forme conditionnelle.
- **Collecte de métriques supplémentaires :** services critiques, événements Windows, etc.
- **Test de latence réseau :** en plus du ping, mesurer le temps de réponse.
- **Mode parallèle :** utiliser `ForEach-Object -Parallel` (PowerShell 7) pour traiter plusieurs serveurs simultanément.

---

## 11. Conclusion

Ce script PowerShell répond aux exigences du projet : supervision de la connectivité et des ressources, alertes email, journalisation, et flexibilité via des fichiers CSV. Sa structure modulaire et bien documentée permet à chaque membre du groupe de comprendre et de modifier le code selon les besoins.

N'hésitez pas à l'adapter, l'enrichir et le tester dans votre environnement de laboratoire. La pratique est la clé pour maîtriser PowerShell et l'administration système automatisée.

---

*— Fin du document README —*