# reboot_dialog.ps1
# WinForms reboot dialog - runs in the user's interactive session.
# Called by schedule_reboot.ps1 via a scheduled task.
# Auto-restarts when the countdown reaches zero. Close button is disabled.

[void][Reflection.Assembly]::Load('System.Windows.Forms, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
[void][Reflection.Assembly]::Load('System.Drawing, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a')
[System.Windows.Forms.Application]::EnableVisualStyles()

$Win_Heading  = "Neustart erforderlich"
$Win_Body     = "Ihr Computer muss aufgrund von Updates neu gestartet werden. Bitte speichern Sie offene Dokumente bevor der Computer heruntergefahren wird."
$TotalTime    = 1800  # seconds until forced restart if no button is clicked
$LogoUrl      = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/it_factory_logo200x58.png"
$LogoPath     = "C:\Windows\Temp\ifa_logo.png"

# Colors
$clrBlue      = [System.Drawing.Color]::FromArgb(0, 114, 198)
$clrRed       = [System.Drawing.Color]::FromArgb(210, 43, 43)
$clrGray      = [System.Drawing.Color]::FromArgb(245, 245, 245)
$clrDarkGray  = [System.Drawing.Color]::FromArgb(200, 200, 200)
$clrTextDark  = [System.Drawing.Color]::FromArgb(40, 40, 40)
$clrWhite     = [System.Drawing.Color]::White

# Controls
$MainForm    = New-Object System.Windows.Forms.Form
$panelHeader = New-Object System.Windows.Forms.Panel
$panelBody   = New-Object System.Windows.Forms.Panel
$panelFooter = New-Object System.Windows.Forms.Panel
$picLogo     = New-Object System.Windows.Forms.PictureBox
$lblHeading  = New-Object System.Windows.Forms.Label
$lblBody     = New-Object System.Windows.Forms.Label
$lblCdLabel  = New-Object System.Windows.Forms.Label
$lblCd       = New-Object System.Windows.Forms.Label
$btnNow      = New-Object System.Windows.Forms.Button
$btn6h       = New-Object System.Windows.Forms.Button
$timer       = New-Object System.Windows.Forms.Timer

# Timer / load
$MainForm_Load = {
    $script:StartTime = (Get-Date).AddSeconds($TotalTime)
    $timer.Start()
}

$timer_Tick = {
    [TimeSpan]$span = $script:StartTime - (Get-Date)
    if ($span.TotalSeconds -le 0) {
        $timer.Stop()
        (Get-WmiObject -Class Win32_OperatingSystem -EnableAllPrivileges).Win32Shutdown(6)
        $MainForm.Close()
    } else {
        $lblCd.Text = "{0:00}:{1:00}:{2:00}" -f $span.Hours, $span.Minutes, $span.Seconds
    }
}

$btnNow.add_Click({
    (Get-WmiObject -Class Win32_OperatingSystem -EnableAllPrivileges).Win32Shutdown(6)
    $MainForm.Close()
})
# "In 6 Stunden": just close - the SYSTEM-scheduled fallback in schedule_reboot.ps1 handles the 6h reboot
$btn6h.add_Click({ $MainForm.Close() })

$timer.Interval = 1000
$timer.add_Tick($timer_Tick)
$MainForm.add_Load($MainForm_Load)

# ── Main form ─────────────────────────────────────────────────────────────────
$MainForm.Text            = ""
$MainForm.ClientSize      = New-Object System.Drawing.Size(440, 310)
$MainForm.StartPosition   = "CenterScreen"
$MainForm.TopMost         = $true
$MainForm.MaximizeBox     = $false
$MainForm.MinimizeBox     = $false
$MainForm.ControlBox      = $false
$MainForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$MainForm.BackColor       = $clrWhite
$MainForm.ShowIcon        = $false
$MainForm.ShowInTaskbar   = $false

# ── Header panel (blue) ───────────────────────────────────────────────────────
$panelHeader.BackColor = $clrWhite
$panelHeader.Location  = New-Object System.Drawing.Point(0, 0)
$panelHeader.Size      = New-Object System.Drawing.Size(440, 75)

$lblHeading.Text      = $Win_Heading
$lblHeading.Font      = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Regular)
$lblHeading.ForeColor = $clrTextDark
$lblHeading.Location  = New-Object System.Drawing.Point(16, 22)
$lblHeading.Size      = New-Object System.Drawing.Size(210, 30)
$lblHeading.TextAlign = "MiddleLeft"
$panelHeader.Controls.Add($lblHeading)

try {
    (New-Object System.Net.WebClient).DownloadFile($LogoUrl, $LogoPath)
    $picLogo.Image    = [System.Drawing.Image]::FromFile($LogoPath)
    $picLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picLogo.Location = New-Object System.Drawing.Point(225, 9)
    $picLogo.Size     = New-Object System.Drawing.Size(200, 58)
    $picLogo.BackColor = $clrWhite
    $panelHeader.Controls.Add($picLogo)
} catch {}

# ── Body panel (white) ────────────────────────────────────────────────────────
$panelBody.BackColor = $clrWhite
$panelBody.Location  = New-Object System.Drawing.Point(0, 75)
$panelBody.Size      = New-Object System.Drawing.Size(440, 155)

$lblBody.Text      = $Win_Body
$lblBody.Font      = New-Object System.Drawing.Font("Segoe UI", 10)
$lblBody.ForeColor = $clrTextDark
$lblBody.Location  = New-Object System.Drawing.Point(20, 18)
$lblBody.Size      = New-Object System.Drawing.Size(400, 55)
$panelBody.Controls.Add($lblBody)

# Countdown box
$lblCdLabel.Text      = "Automatischer Neustart in"
$lblCdLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblCdLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$lblCdLabel.Location  = New-Object System.Drawing.Point(20, 88)
$lblCdLabel.AutoSize  = $true
$panelBody.Controls.Add($lblCdLabel)

$lblCd.Text      = "00:30:00"
$lblCd.Font      = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$lblCd.ForeColor = $clrRed
$lblCd.Location  = New-Object System.Drawing.Point(230, 78)
$lblCd.AutoSize  = $true
$panelBody.Controls.Add($lblCd)

# ── Footer panel (light gray) ─────────────────────────────────────────────────
$panelFooter.BackColor = $clrGray
$panelFooter.Location  = New-Object System.Drawing.Point(0, 230)
$panelFooter.Size      = New-Object System.Drawing.Size(440, 80)

$borderLine = New-Object System.Windows.Forms.Label
$borderLine.BackColor = $clrDarkGray
$borderLine.Location  = New-Object System.Drawing.Point(0, 0)
$borderLine.Size      = New-Object System.Drawing.Size(440, 1)
$panelFooter.Controls.Add($borderLine)

$btnNow.Text      = "Jetzt neu starten"
$btnNow.BackColor = $clrRed
$btnNow.ForeColor = $clrWhite
$btnNow.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnNow.Location  = New-Object System.Drawing.Point(100, 20)
$btnNow.Size      = New-Object System.Drawing.Size(145, 36)
$btnNow.FlatStyle = "Flat"
$btnNow.FlatAppearance.BorderSize = 0
$panelFooter.Controls.Add($btnNow)

$btn6h.Text      = "In 6 Stunden"
$btn6h.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$btn6h.ForeColor = $clrTextDark
$btn6h.BackColor = $clrWhite
$btn6h.FlatStyle = "Flat"
$btn6h.FlatAppearance.BorderColor = $clrDarkGray
$btn6h.Location  = New-Object System.Drawing.Point(255, 20)
$btn6h.Size      = New-Object System.Drawing.Size(130, 36)
$panelFooter.Controls.Add($btn6h)

$MainForm.Controls.AddRange(@($panelHeader, $panelBody, $panelFooter))
$MainForm.ShowDialog()
