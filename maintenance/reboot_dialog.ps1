# reboot_dialog.ps1
# WinForms reboot dialog - runs in the user's interactive session.
# Called by schedule_reboot.ps1 via a scheduled task.
# Writes the desired restart time to a flag file; the SYSTEM watcher task
# in schedule_reboot.ps1 polls the file and issues the actual shutdown.

[void][Reflection.Assembly]::Load('System.Windows.Forms, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
[void][Reflection.Assembly]::Load('System.Drawing, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a')
[System.Windows.Forms.Application]::EnableVisualStyles()

$Win_Heading  = "Neustart erforderlich"
$Win_Body     = "Ihr Computer wird aufgrund von Updates in 30 Minuten neu gestartet. Bitte speichern Sie Ihre offenen Dokumente."
$TotalTime    = 1800  # seconds until auto-restart if no button is clicked (30 min)
$FlagPath     = "C:\Windows\Temp\syncro_reboot_time.flag"
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
        # Countdown expired: write "now" as target so watcher reboots on its next tick
        Set-Content -Path $FlagPath -Value (Get-Date).ToString("o") -Encoding ASCII
        $MainForm.Close()
    } else {
        $lblCd.Text = "{0:00}:{1:00}:{2:00}" -f $span.Hours, $span.Minutes, $span.Seconds
    }
}

# Write target restart time to flag file; SYSTEM watcher issues the actual shutdown
$script:rebooting = $false

$btnNow.add_Click({
    $script:rebooting = $true
    Set-Content -Path $FlagPath -Value (Get-Date).ToString("o") -Encoding ASCII
    $timer.Stop()
    $lblHeading.Text    = "Neustart geplant"
    $lblBody.Text       = "Der Computer wird in den nächsten Minuten automatisch neu gestartet."
    $lblCdLabel.Visible = $false
    $lblCd.Visible      = $false
    $btnNow.Visible     = $false
    $btn6h.Text         = "Schließen"
    $btn6h.Location     = New-Object System.Drawing.Point(155, 20)
    $btn6h.Size         = New-Object System.Drawing.Size(130, 36)
})

$btn6h.add_Click({
    if (-not $script:rebooting) {
        Set-Content -Path $FlagPath -Value (Get-Date).AddHours(6).ToString("o") -Encoding ASCII
    }
    $MainForm.Close()
})

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

# ── Header panel ──────────────────────────────────────────────────────────────
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

# ── Body panel ────────────────────────────────────────────────────────────────
$panelBody.BackColor = $clrWhite
$panelBody.Location  = New-Object System.Drawing.Point(0, 75)
$panelBody.Size      = New-Object System.Drawing.Size(440, 155)

$lblBody.Text      = $Win_Body
$lblBody.Font      = New-Object System.Drawing.Font("Segoe UI", 10)
$lblBody.ForeColor = $clrTextDark
$lblBody.Location  = New-Object System.Drawing.Point(20, 18)
$lblBody.Size      = New-Object System.Drawing.Size(400, 65)
$panelBody.Controls.Add($lblBody)

# Countdown box
$lblCdLabel.Text      = "Automatischer Neustart in"
$lblCdLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lblCdLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$lblCdLabel.Location  = New-Object System.Drawing.Point(20, 100)
$lblCdLabel.AutoSize  = $true
$panelBody.Controls.Add($lblCdLabel)

$lblCd.Text      = "00:30:00"
$lblCd.Font      = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$lblCd.ForeColor = $clrRed
$lblCd.Location  = New-Object System.Drawing.Point(230, 90)
$lblCd.AutoSize  = $true
$panelBody.Controls.Add($lblCd)

# ── Footer panel ──────────────────────────────────────────────────────────────
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
$btnNow.Location  = New-Object System.Drawing.Point(90, 20)
$btnNow.Size      = New-Object System.Drawing.Size(140, 36)
$btnNow.FlatStyle = "Flat"
$btnNow.FlatAppearance.BorderSize = 0
$panelFooter.Controls.Add($btnNow)

$btn6h.Text      = "Verschieben (6 Stunden)"
$btn6h.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$btn6h.ForeColor = $clrTextDark
$btn6h.BackColor = $clrWhite
$btn6h.FlatStyle = "Flat"
$btn6h.FlatAppearance.BorderColor = $clrDarkGray
$btn6h.Location  = New-Object System.Drawing.Point(245, 20)
$btn6h.Size      = New-Object System.Drawing.Size(130, 36)
$panelFooter.Controls.Add($btn6h)

$MainForm.Controls.AddRange(@($panelHeader, $panelBody, $panelFooter))
$MainForm.ShowDialog()
