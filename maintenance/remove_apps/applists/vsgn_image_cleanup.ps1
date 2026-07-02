# AppX / Windows Store packages to remove.
# Use the package family name (without version suffix).
$AppxPackages = @(
    'Microsoft.GamingApp'
    'Microsoft.XboxApp'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.Xbox.TCUI'
    'Microsoft.SkypeApp'
)

# Processes to kill before running Win32 uninstallers (e.g. apps that block their own uninstall).
$PreKillProcesses = @(
    'pCloud'
)

# Win32 / MSI apps to remove, matched by display name.
# Use the exact name shown in Windows Settings > Apps > Installed apps.
$Win32Apps = @(
    'Brave'
    'Mozilla Thunderbird (x86 en-US)'
    'Dropbox'
    'Dropbox Update Helper'
    'pCloud Drive'          # process killed before uninstall — see $PreKillProcesses below
    'GIMP 2.10.38'
    'GIMP 3.2.2'
    'Brother CanvasWorkspace'
    'CodeTwo QR Code Desktop Reader & Generator'
    'Advanced IP Scanner 2.5.1'
    'TightReceiverPro 1.2.1'
    'WebWeaver® Desktop 6'
    'TeamViewer'
    'UltraVNC'
    'KeePass Password Safe 2.57'
    'Logitech Presentation'
    'Avidemux VC++ 64bits'
    'Eclipse Temurin JRE*'
)
