#TODO - MAKE SURE YOU SETUP YOUR ASSET CUSTOM FIELD CALLED "Bitlocker_Key_<drive>" for each drive as a "Text Field" on your 
# Syncro Device asset type. Assets -> Manage Types -> Syncro Device -> New Field
# Based on the Syncro Staff product keys script.

Import-Module $env:SyncroModule

#Creates temp directory if it does not exist
New-Item -ItemType Directory -Force -Path C:\Temp
Set-Location C:\Temp
Del Bitlocker_Key_C.txt
Del Bitlocker_Key_D.txt
Del Bitlocker_Key_E.txt

#Sets Bitlocker_active field based on C: drive protection status
$blStatus = (Get-BitLockerVolume -MountPoint C -ErrorAction SilentlyContinue).ProtectionStatus
Set-Asset-Field -Name "Bitlocker_active" -Value $(if ($blStatus -eq "On") { "Yes" } else { "No" })

#Puts keys into text files
(Get-BitLockerVolume -MountPoint C).KeyProtector.recoverypassword > C:\Temp\Bitlocker_Key_C.txt
(Get-BitLockerVolume -MountPoint D).KeyProtector.recoverypassword > C:\Temp\Bitlocker_Key_D.txt
(Get-BitLockerVolume -MountPoint E).KeyProtector.recoverypassword > C:\Temp\Bitlocker_Key_E.txt

Start-Sleep -Seconds 15

#Gets keys from text files
[string] $textc = Get-Content C:\Temp\Bitlocker_Key_C.txt -raw
[string] $textd = Get-Content C:\Temp\Bitlocker_Key_D.txt -raw
[string] $texte = Get-Content C:\Temp\Bitlocker_Key_E.txt -raw


#Adds keys to Syncro
Set-Asset-Field -Name "Bitlocker_Key_C" -Value $textc
Set-Asset-Field -Name "Bitlocker_Key_D" -Value $textd
Set-Asset-Field -Name "Bitlocker_Key_E" -Value $texte


#Removes text files with keys from PC for security
Set-Location C:\Temp
Del Bitlocker_Key_C.txt
Del Bitlocker_Key_D.txt
Del Bitlocker_Key_E.txt