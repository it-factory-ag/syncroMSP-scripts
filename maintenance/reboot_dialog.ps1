# reboot_dialog.ps1
# WinForms reboot dialog - runs in the user's interactive session.
# Called by schedule_reboot.ps1 via a scheduled task.
# Auto-restarts when the countdown reaches zero. Close button is disabled.

[void][Reflection.Assembly]::Load('System.Windows.Forms, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
[void][Reflection.Assembly]::Load('System.Drawing, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a')
[System.Windows.Forms.Application]::EnableVisualStyles()

$Win_Heading  = "Neustart erforderlich"
$Win_Body     = "Ihr Computer muss fuer Sicherheitswartungen neu gestartet werden.`n`nBitte speichern Sie Ihre Arbeit. Der Neustart erfolgt automatisch wenn der Countdown ablaeuft."
$TotalTime    = 1800  # seconds until forced restart if no button is clicked
$LogoUrl      = "https://raw.githubusercontent.com/it-factory-ag/syncroMSP-scripts/main/maintenance/it_factory_logo200x58.png"
$LogoPath     = "C:\Windows\Temp\ifa_logo.png"

$MainForm             = New-Object System.Windows.Forms.Form
$panel1               = New-Object System.Windows.Forms.Panel
$panel2               = New-Object System.Windows.Forms.Panel
$picLogo              = New-Object System.Windows.Forms.PictureBox
$labelHeading         = New-Object System.Windows.Forms.Label
$labelBody            = New-Object System.Windows.Forms.Label
$labelCountdownLabel  = New-Object System.Windows.Forms.Label
$labelCountdown       = New-Object System.Windows.Forms.Label
$btnNow               = New-Object System.Windows.Forms.Button
$btn1h                = New-Object System.Windows.Forms.Button
$btn2h                = New-Object System.Windows.Forms.Button
$btn4h                = New-Object System.Windows.Forms.Button
$btn8h                = New-Object System.Windows.Forms.Button
$timer                = New-Object System.Windows.Forms.Timer

$MainForm_Load = {
    $script:StartTime = (Get-Date).AddSeconds($TotalTime)
    $timer.Start()
}

$timer_Tick = {
    [TimeSpan]$span = $script:StartTime - (Get-Date)
    if ($span.TotalSeconds -le 0) {
        $timer.Stop()
        Restart-Computer -Force
    } else {
        $labelCountdown.Text = "{0:00}:{1:00}:{2:00}" -f $span.Hours, $span.Minutes, $span.Seconds
    }
}

$btnNow.add_Click({ Restart-Computer -Force })
$btn1h.add_Click({ shutdown /r /t 3600 /f; $MainForm.Close() })
$btn2h.add_Click({ shutdown /r /t 7200 /f; $MainForm.Close() })
$btn4h.add_Click({ shutdown /r /t 14400 /f; $MainForm.Close() })
$btn8h.add_Click({ shutdown /r /t 28800 /f; $MainForm.Close() })

$timer.add_Tick($timer_Tick)
$MainForm.add_Load($MainForm_Load)

# Main form
$MainForm.Text                = ""
$MainForm.ClientSize          = New-Object System.Drawing.Size(400, 340)
$MainForm.StartPosition       = "CenterScreen"
$MainForm.TopMost             = $true
$MainForm.MaximizeBox         = $false
$MainForm.MinimizeBox         = $false
$MainForm.ControlBox          = $false
$MainForm.FormBorderStyle     = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$MainForm.BackColor           = [System.Drawing.Color]::White
$MainForm.ShowIcon            = $false
$MainForm.ShowInTaskbar       = $false

# Blue header panel
$panel1.BackColor   = [System.Drawing.Color]::FromArgb(0, 114, 198)
$panel1.Location    = New-Object System.Drawing.Point(0, 0)
$panel1.Size        = New-Object System.Drawing.Size(400, 67)

# Logo (right side of header) - graceful fallback if webp not supported
try {
    (New-Object System.Net.WebClient).DownloadFile($LogoUrl, $LogoPath)
    $picLogo.Image    = [System.Drawing.Image]::FromFile($LogoPath)
    $picLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picLogo.Location = New-Object System.Drawing.Point(188, 5)
    $picLogo.Size     = New-Object System.Drawing.Size(200, 58)
    $picLogo.BackColor = [System.Drawing.Color]::FromArgb(0, 114, 198)
    $panel1.Controls.Add($picLogo)
} catch {}

$labelHeading.Text      = $Win_Heading
$labelHeading.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 12, [System.Drawing.FontStyle]::Regular)
$labelHeading.ForeColor = [System.Drawing.Color]::White
$labelHeading.Location  = New-Object System.Drawing.Point(12, 18)
$labelHeading.Size      = New-Object System.Drawing.Size(175, 30)
$labelHeading.TextAlign = "MiddleLeft"
$panel1.Controls.Add($labelHeading)

# Body text
$labelBody.Text      = $Win_Body
$labelBody.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 9)
$labelBody.Location  = New-Object System.Drawing.Point(12, 80)
$labelBody.Size      = New-Object System.Drawing.Size(375, 75)

# Countdown
$labelCountdownLabel.Text      = "Automatischer Neustart in:"
$labelCountdownLabel.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$labelCountdownLabel.Location  = New-Object System.Drawing.Point(80, 168)
$labelCountdownLabel.Size      = New-Object System.Drawing.Size(180, 20)
$labelCountdownLabel.AutoSize  = $true

$labelCountdown.Text      = "00:30:00"
$labelCountdown.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$labelCountdown.ForeColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
$labelCountdown.Location  = New-Object System.Drawing.Point(270, 168)
$labelCountdown.Size      = New-Object System.Drawing.Size(60, 20)
$labelCountdown.AutoSize  = $true

# Button panel
$panel2.BackColor = [System.Drawing.Color]::FromArgb(236, 236, 236)
$panel2.Location  = New-Object System.Drawing.Point(0, 200)
$panel2.Size      = New-Object System.Drawing.Size(400, 140)

$btnNow.Text      = "Jetzt neu starten"
$btnNow.BackColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
$btnNow.ForeColor = [System.Drawing.Color]::White
$btnNow.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$btnNow.Location  = New-Object System.Drawing.Point(150, 12)
$btnNow.Size      = New-Object System.Drawing.Size(105, 40)
$btnNow.FlatStyle = "Flat"

$btn1h.Text     = "In 1 Stunde"
$btn1h.Location = New-Object System.Drawing.Point(10, 65)
$btn1h.Size     = New-Object System.Drawing.Size(83, 40)

$btn2h.Text     = "In 2 Stunden"
$btn2h.Location = New-Object System.Drawing.Point(103, 65)
$btn2h.Size     = New-Object System.Drawing.Size(83, 40)

$btn4h.Text     = "In 4 Stunden"
$btn4h.Location = New-Object System.Drawing.Point(206, 65)
$btn4h.Size     = New-Object System.Drawing.Size(83, 40)

$btn8h.Text     = "In 8 Stunden"
$btn8h.Location = New-Object System.Drawing.Point(299, 65)
$btn8h.Size     = New-Object System.Drawing.Size(90, 40)

$panel2.Controls.AddRange(@($btnNow, $btn1h, $btn2h, $btn4h, $btn8h))

$MainForm.Controls.AddRange(@($panel1, $labelBody, $labelCountdownLabel, $labelCountdown, $panel2))
$MainForm.ShowDialog()
